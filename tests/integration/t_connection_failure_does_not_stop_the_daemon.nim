## A SINGLE CONNECTION MUST NOT BE ABLE TO STOP THE HOST'S LEASE AUTHORITY.
##
## No mocks. A real `runquotad` binary from `build/bin`, a real Unix-domain
## socket, real peer processes connecting to it, and a real lease taken over
## the real client library afterwards to prove the daemon is still doing its
## job rather than merely still having a pid.
##
## THE DEFECT THIS EXISTS FOR, found while measuring M1 and reproduced before
## it was repaired. `connectionWorker` called `handleSharedConnection` bare.
## An unhandled exception on a Nim thread terminates the PROCESS, and
## `runquotad` is host-wide -- ONE PER MACHINE, serving every user -- so any
## client that provoked one ended every build on the box.
##
## AND IT DID NOT TAKE A MALICIOUS CLIENT, which is why this is a test and
## not a note. A peer that connects and closes before the daemon finishes
## accepting makes `newSocket`'s `setsockopt` fail with EINVAL. That is a race
## any port scanner, health probe, or cancelled build wins by accident. The
## observed symptom was not a crash report -- it was a `repro build` that
## hung, because the authority it was waiting on had gone.
##
## WHY THE ASSERTION IS "STILL SERVES" AND NOT "STILL RUNNING". A daemon that
## survived by refusing everything afterwards would satisfy the weaker
## sentence and be just as useless. The lease round trip below is what makes
## the claim mean something, and it is taken AFTER the abusive connections,
## through the ordinary client library, on the same socket.
##
## THE DESCRIPTOR HALF IS NOT DECORATION. Isolating the failure without
## releasing the accepted handle would convert "one client kills the daemon"
## into "a thousand clients kill the daemon", which is the same outcome
## reached more slowly. Descriptors are exactly the resource an accept loop
## cannot run out of, and a wide build ran this host out of them while M1 was
## being measured -- so the leak is checked against the daemon's real open-fd
## count rather than argued from the source.

import std/[json, nativesockets, os, osproc, posix, streams, strutils, unittest]

import runquota_client
import runquota_core
import runquota_ipc
import runquota_protocol
import daemon_binary

const MiB = 1024'u64 * 1024'u64

proc socketIsBound(path: string): bool =
  var info: Stat
  lstat(path.cstring, info) == 0 and S_ISSOCK(info.st_mode)

type DaemonHandle = object
  process: Process

proc startDaemon(socketPath: string): DaemonHandle =
  let process = startProcess(daemonPath(), args = ["--socket", socketPath],
    options = {poStdErrToStdOut})
  for _ in 0 ..< 400:
    if socketIsBound(socketPath): break
    sleep(25)
  # Exactly three startup lines, as the rest of this suite asserts: reading
  # them keeps the pipe from filling and wedging the daemon on a write
  # nobody is draining.
  for _ in 0 ..< 3:
    discard process.outputStream.readLine()
  DaemonHandle(process: process)

proc stop(handle: var DaemonHandle) =
  if handle.process.running:
    handle.process.terminate()
    discard handle.process.waitForExit(5000)
  if handle.process.running:
    handle.process.kill()
    discard handle.process.waitForExit(5000)
  handle.process.close()

proc scratchRoot(tag: string): string =
  # SHORT ON PURPOSE. `sun_path` is 104 bytes on this platform and the
  # session scratch directory alone overruns it, which fails as
  # "socket path too long" from inside `bindUnix` rather than anywhere
  # informative.
  result = "/tmp/rq-" & tag & "-" & $getCurrentProcessId()
  removeDir(result)
  createDir(result)
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})

proc connectThenCloseWithoutHello(socketPath: string) =
  ## The three lines of Python that used to kill the daemon, in Nim: open a
  ## connection and drop it without ever sending `Hello`.
  let handle = createNativeSocket(AF_UNIX, SOCK_STREAM, cint(0))
  doAssert handle != osInvalidSocket
  var address: Sockaddr_un
  address.sun_family = uint8(AF_UNIX)
  let path = socketPath
  doAssert path.len < sizeof(address.sun_path)
  copyMem(addr address.sun_path[0], unsafeAddr path[0], path.len)
  address.sun_path[path.len] = '\0'
  discard connect(SocketHandle(handle), cast[ptr SockAddr](addr address),
    SockLen(sizeof(address)))
  discard posix.close(cint(handle))

proc openDescriptorCount(pid: int): int =
  ## The daemon's real open-descriptor count, read from the OS rather than
  ## inferred. Returns -1 when it cannot be determined, which the caller
  ## treats as "do not assert" rather than as zero.
  let probe = execCmdEx("lsof -p " & $pid & " 2>/dev/null | wc -l")
  if probe.exitCode != 0:
    return -1
  try:
    result = parseInt(probe.output.strip())
  except ValueError:
    result = -1

proc failedConnectionCount(socketPath: string): int =
  let probe = execCmdEx("RUNQUOTA_SOCKET=" & socketPath & " " &
    cliPath() & " observations --json")
  doAssert probe.exitCode == 0, "observations query failed: " & probe.output
  let doc = parseJson(probe.output)
  doc["observations"]["connections_failed"].getInt

suite "connection_failure_does_not_stop_the_daemon":

  test "a peer that connects and vanishes cannot take the daemon with it":
    const AbortedConnections = 50

    let root = scratchRoot("connfail")
    defer: removeDir(root)
    let socketPath = root / "d.sock"

    var daemon = startDaemon(socketPath)
    defer: daemon.stop()
    check socketIsBound(socketPath)

    let pid = daemon.process.processID
    let descriptorsBefore = openDescriptorCount(pid)

    for _ in 0 ..< AbortedConnections:
      connectThenCloseWithoutHello(socketPath)
    sleep(250)

    # ---------------------------------------------------------------------
    # STILL ALIVE
    # ---------------------------------------------------------------------
    check daemon.process.running

    # ---------------------------------------------------------------------
    # STILL SERVING, which is the claim that matters. A real lease, taken
    # through the ordinary client library on the same socket the abuse
    # arrived on.
    # ---------------------------------------------------------------------
    var client = connect(Endpoint(kind: endpointUnixSocket, path: socketPath))
    var session = client.registerSession("connfail", "0.1.0")
    var request = resourceRequest("connfail-probe", milliCpu(1000),
      bytes(64'u64 * MiB))
    var lease = session.requestLease(request)
    check lease.active
    lease.markStarting()
    lease.markRunning(childProcessId = uint64(getCurrentProcessId()))
    lease.finish(outcome = succeeded(), processCount = 1'u32)

    # ---------------------------------------------------------------------
    # AND IT COUNTED THEM. A daemon that survived by silently swallowing the
    # failures would leave an operator with no way to see a genuinely broken
    # connection path.
    # ---------------------------------------------------------------------
    check failedConnectionCount(socketPath) == AbortedConnections

    # ---------------------------------------------------------------------
    # WITHOUT LEAKING A DESCRIPTOR PER ABORTED CONNECTION. Skipped rather
    # than guessed where `lsof` is unavailable.
    # ---------------------------------------------------------------------
    let descriptorsAfter = openDescriptorCount(pid)
    if descriptorsBefore >= 0 and descriptorsAfter >= 0:
      # A generous bound: the assertion is about 50 descriptors never being
      # released, not about the daemon holding a fixed number. The live
      # client above legitimately holds one.
      check descriptorsAfter - descriptorsBefore < AbortedConnections div 2
