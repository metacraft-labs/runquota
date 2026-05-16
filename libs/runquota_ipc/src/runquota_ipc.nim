import std/[net, nativesockets, os]

when defined(posix):
  import std/posix
  when defined(macosx) or defined(freebsd) or defined(openbsd):
    proc getpeereid(socket: SocketHandle; euid: ptr Uid; egid: ptr Gid): cint {.
      importc, header: "<unistd.h>".}
  when defined(linux):
    type
      LinuxPeerCred {.importc: "struct ucred", header: "<sys/socket.h>", bycopy.} = object
        pid {.importc: "pid".}: Pid
        uid {.importc: "uid".}: Uid
        gid {.importc: "gid".}: Gid

    const SoPeerCred = cint(17)

import runquota_ipc/types as ipcTypes
import runquota_core
import runquota_protocol

export ipcTypes

const libraryName* = "runquota_ipc"

proc libraryInfo*(): ipcTypes.LibraryInfo =
  ipcTypes.LibraryInfo(name: libraryName)

proc unixEndpoint*(path: string): Endpoint =
  Endpoint(kind: endpointUnixSocket, path: path)

proc defaultEndpoint*(): Endpoint =
  let overridePath = getEnv("RUNQUOTA_SOCKET")
  if overridePath.len > 0:
    return unixEndpoint(overridePath)
  when defined(posix):
    let base = getEnv("XDG_RUNTIME_DIR", getEnv("TMPDIR", getTempDir()))
    let dir = base / ("runquota-" & $getuid())
    unixEndpoint(dir / "runquotad.sock")
  else:
    Endpoint(kind: endpointUnsupported, path: "")

proc ensureEndpointDir*(endpoint: Endpoint) =
  if endpoint.path.len > 0:
    createDir(parentDir(endpoint.path))

proc connectEndpoint*(endpoint: Endpoint): LocalConnection =
  if endpoint.kind != endpointUnixSocket:
    raise newException(OSError, "unsupported RunQuota endpoint")
  var socket = newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_NONE)
  socket.connectUnix(endpoint.path)
  LocalConnection(socket: socket, endpoint: endpoint)

proc connectDefault*(): LocalConnection =
  connectEndpoint(defaultEndpoint())

proc bindEndpoint*(endpoint: Endpoint): LocalListener =
  if endpoint.kind != endpointUnixSocket:
    raise newException(OSError, "unsupported RunQuota endpoint")
  ensureEndpointDir(endpoint)
  if fileExists(endpoint.path):
    removeFile(endpoint.path)
  var socket = newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_NONE)
  socket.bindUnix(endpoint.path)
  socket.listen()
  LocalListener(socket: socket, endpoint: endpoint)

proc acceptConnection*(listener: var LocalListener): LocalConnection =
  var client: owned(Socket)
  listener.socket.accept(client)
  LocalConnection(socket: client, endpoint: listener.endpoint)

proc acceptNativeConnection*(listener: var LocalListener): AcceptedConnection =
  let accepted = nativesockets.accept(listener.socket.getFd())
  if accepted[0] == osInvalidSocket:
    raiseOSError(osLastError())
  AcceptedConnection(handle: accepted[0])

proc localConnection*(accepted: AcceptedConnection): LocalConnection =
  LocalConnection(
    socket: newSocket(accepted.handle, AF_UNIX, SOCK_STREAM, IPPROTO_NONE),
    endpoint: Endpoint(kind: endpointUnixSocket, path: "")
  )

proc peerIdentity*(connection: LocalConnection): PeerIdentity =
  when defined(macosx) or defined(freebsd) or defined(openbsd):
    var uid: Uid
    var gid: Gid
    if getpeereid(connection.socket.getFd(), addr uid, addr gid) == 0:
      return PeerIdentity(
        kind: peerIdentityUser,
        processId: 0'u64,
        userId: uint64(uid),
        groupId: uint64(gid)
      )
  elif defined(linux):
    var credentials: LinuxPeerCred
    var credentialsLen = SockLen(sizeof(credentials))
    if getsockopt(
      connection.socket.getFd(),
      SOL_SOCKET,
      SoPeerCred,
      addr credentials,
      addr credentialsLen
    ) == 0:
      return PeerIdentity(
        kind: peerIdentityProcess,
        processId: uint64(credentials.pid),
        userId: uint64(credentials.uid),
        groupId: uint64(credentials.gid)
      )
  PeerIdentity(
    kind: peerIdentityUnavailable,
    processId: 0'u64,
    userId: 0'u64,
    groupId: 0'u64
  )

proc close*(connection: var LocalConnection) =
  if connection.socket != nil:
    connection.socket.close()
    connection.socket = nil

proc close*(listener: var LocalListener) =
  if listener.socket != nil:
    listener.socket.close()
  if listener.endpoint.kind == endpointUnixSocket and fileExists(listener.endpoint.path):
    removeFile(listener.endpoint.path)

proc readExact(socket: Socket; size: int; data: var string): bool =
  data.setLen(0)
  var remaining = size
  while remaining > 0:
    let part = socket.recv(remaining)
    if part.len == 0:
      return false
    data.add(part)
    remaining -= part.len
  true

proc sendFrame*(connection: var LocalConnection; frame: string) =
  connection.socket.send(frame)

proc receiveFrame*(connection: var LocalConnection; frame: var RqspFrame;
                   frameDiagnostic: var Diagnostic): bool =
  frameDiagnostic = okDiagnostic()
  var headerBytes: string
  if not readExact(connection.socket, int(RqspHeaderLen), headerBytes):
    return false
  var header: FrameHeader
  if not decodeFrameHeader(headerBytes, header):
    frameDiagnostic = diagnostic(diagProtocol, "invalid RQSP frame header")
    return false
  if header.payloadLen > DefaultMaxFrameBytes:
    frame = RqspFrame(header: header, payload: "")
    frameDiagnostic = diagnostic(
      diagProtocol,
      "RQSP frame exceeds negotiated flow-control limit",
      "max_frame_bytes=" & $DefaultMaxFrameBytes
    )
    return false
  var payload: string
  if not readExact(connection.socket, int(header.payloadLen), payload):
    return false
  frame = RqspFrame(header: header, payload: payload)
  true

proc receiveFrame*(connection: var LocalConnection; frame: var RqspFrame): bool =
  var frameDiagnostic = okDiagnostic()
  connection.receiveFrame(frame, frameDiagnostic)
