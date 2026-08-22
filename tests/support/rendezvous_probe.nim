## A rendezvous prober that is meant to be run AS A DIFFERENT UID from the
## one that started the daemon.
##
## WHY A SEPARATE BINARY. The M13d gate is a SECOND UID, and single-uid runs
## of it prove nothing. This host has no root and no `sudo`, so the only
## real second uid available is a Nix build user -- and a Nix builder runs a
## command, not a Nim `unittest` suite. So the clause's client half lives
## here, prints its findings as key=value lines, and
## `tests/integration/t_shared_endpoint_second_uid.nim` reads them back.
##
## THE ORDER OF WHAT IT DOES IS THE POINT. It runs the APPLICATION-level
## trust check FIRST and reports the answer, then attempts a RAW
## `connect(2)` and reports the raw errno. That is what makes "which layer
## refused the non-member" an observation rather than an assumption: if the
## application check comes back `trustOk` and the kernel returns `EACCES`,
## the boundary under test is the filesystem's, which is what the gate
## requires. An application-level check that happened to fire first would
## leave the real boundary untested, and this binary would say so.
##
## Nothing here is mocked; the socket is a real socket and the errno is the
## kernel's.

import std/[nativesockets, net, os, posix, strutils]

import runquota_core
import runquota_ipc
import runquota_protocol

proc groupList(): string =
  var buffer: array[0 .. 255, Gid]
  let count = getgroups(cint(buffer.len), addr buffer)
  var parts: seq[string] = @[]
  for i in 0 ..< max(0, int(count)):
    parts.add($int64(buffer[i]))
  parts.join(",")

proc rawConnect(path: string): tuple[fd: SocketHandle; code: cint] =
  ## `connect(2)` with nothing of ours in front of it.
  let fd = socket(cint(AF_UNIX), cint(SOCK_STREAM), 0.cint)
  if fd == SocketHandle(-1):
    return (fd, errno)
  var address: Sockaddr_un
  address.sun_family = TSa_Family(AF_UNIX)
  if path.len >= Sockaddr_un_path_length:
    discard posix.close(cint(fd))
    return (SocketHandle(-1), ENAMETOOLONG)
  copyMem(addr address.sun_path[0], path.cstring, path.len + 1)
  if connect(fd, cast[ptr SockAddr](addr address),
             SockLen(sizeof(address))) == 0:
    return (fd, 0.cint)
  let code = errno
  discard posix.close(cint(fd))
  (SocketHandle(-1), code)

proc errnoName(code: cint): string =
  if code == EACCES: "EACCES"
  elif code == EPERM: "EPERM"
  elif code == ENOENT: "ENOENT"
  elif code == ECONNREFUSED: "ECONNREFUSED"
  elif code == ENOTDIR: "ENOTDIR"
  elif code == 0: "OK"
  else: "errno" & $code

when isMainModule:
  let args = commandLineParams()
  if args.len < 1:
    echo "usage: rendezvous_probe SOCKET [DECLARED_UID]"
    quit 2
  let socketPath = args[0]
  let declaredUid =
    if args.len >= 2 and args[1].len > 0: uint64(parseBiggestUInt(args[1]))
    else: uint64(getuid())

  echo "uid=" & $int64(getuid())
  echo "gid=" & $int64(getgid())
  echo "groups=" & groupList()
  echo "socket=" & socketPath

  # THE APPLICATION-LEVEL ANSWER, taken before anything is attempted.
  let trust = endpointDirectoryTrust(unixEndpoint(socketPath))
  echo "app_trust=" & $trust.reason
  echo "app_owner=" & $trust.ownerUid
  echo "app_group=" & $trust.groupGid
  echo "app_mode=" & modeText(trust.mode)
  echo "app_message=" & trust.message.replace("\n", " ")

  # THE KERNEL'S ANSWER.
  let (fd, code) = rawConnect(socketPath)
  echo "connect=" & errnoName(code)
  echo "connect_errno=" & $int(code)
  if code != 0:
    echo "hello=not-attempted"
    quit 0

  var connection = LocalConnection(
    kind: endpointUnixSocket,
    socket: newSocket(fd, AF_UNIX, SOCK_STREAM, IPPROTO_NONE),
    endpoint: unixEndpoint(socketPath)
  )
  try:
    connection.sendFrame(encodeFrame(rqHello, FrameFlagRequest, 1'u64,
      encodeHello(HelloMessage(
        clientName: "m13d-second-uid-probe",
        clientVersion: "0.0.0",
        minProtocolMajor: RqspProtocolMajor,
        maxProtocolMajor: RqspProtocolMajor,
        processId: uint64(getCurrentProcessId()),
        userId: declaredUid,
        desiredCapabilities: "m1-lease"
      ))))
    echo "declared_uid=" & $declaredUid
    var frame: RqspFrame
    var frameDiagnostic = okDiagnostic()
    if not connection.receiveFrame(frame, frameDiagnostic, 5000):
      echo "hello=no-reply"
    elif frame.header.messageKind == rqError:
      var error: ProtocolErrorMessage
      if decodeProtocolError(frame.payload, error):
        echo "hello=error"
        echo "hello_code=" & $error.diagnostic.code
        echo "hello_message=" & error.diagnostic.message.replace("\n", " ")
      else:
        echo "hello=undecodable-error"
    elif frame.header.messageKind == rqHelloOk:
      echo "hello=ok"
    else:
      echo "hello=" & $frame.header.messageKind
  finally:
    connection.close()
