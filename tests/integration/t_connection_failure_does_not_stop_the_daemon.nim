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

import std/[envvars, json, os, osproc, streams, strtabs, strutils, unittest]

when defined(windows):
  import std/[oserrors, winlean]
else:
  import std/[nativesockets, posix]

import runquota_client
import runquota_core
import runquota_core/child_process
import runquota_ipc
import runquota_protocol
import daemon_binary
import daemon_endpoint
import scratch_root

const MiB = 1024'u64 * 1024'u64

type DaemonHandle = object
  process: Process

proc startDaemon(socketPath: string): DaemonHandle =
  let process = startProcess(daemonPath(), args = ["--socket", socketPath,
      # The host state in the scratch directory, never the machine's.
      "--host-identity-file", socketPath.parentDir / "host-id"],
    options = {poStdErrToStdOut})
  for _ in 0 ..< 400:
    if endpointIsBound(socketPath): break
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
  # SHORT ON PURPOSE on POSIX. `sun_path` is 104 bytes on this platform and
  # the session scratch directory alone overruns it, which fails as
  # "socket path too long" from inside `bindUnix` rather than anywhere
  # informative. Windows has no such limit and no `/tmp`: `--socket` names a
  # pipe there (see `endpointForPath`), and the directory only holds files.
  let base =
    when defined(windows): getTempDir()
    else: "/tmp"
  result = base / ("rq-" & tag & "-" & $getCurrentProcessId())
  removeDir(result)
  createDir(result)
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})

when defined(windows):
  proc createFileW(name: WideCString; access, share: int32; security: pointer;
                   disposition, flags: int32; templateFile: Handle): Handle
    {.stdcall, dynlib: "kernel32.dll", importc: "CreateFileW".}
  proc getProcessHandleCount(process: Handle; count: ptr int32): WINBOOL
    {.stdcall, dynlib: "kernel32.dll", importc: "GetProcessHandleCount".}

  proc connectThenCloseWithoutHello(socketPath: string) =
    ## The same abuse over the transport Windows serves: open the daemon's
    ## pipe and drop it without ever sending `Hello`.
    const
      GenericReadWrite = cast[int32](0xC0000000'u32)
      OpenExisting = 3'i32
    let pipeName = endpointForPath(socketPath).path
    var handle = INVALID_HANDLE_VALUE
    for _ in 0 ..< 50:
      handle = createFileW(newWideCString(pipeName), GenericReadWrite, 0,
        nil, OpenExisting, 0, Handle(0))
      if handle != INVALID_HANDLE_VALUE:
        break
      # Every instance busy: the daemon pre-creates the next one after it
      # hands the last to a worker, so the next attempt finds it.
      sleep(10)
    doAssert handle != INVALID_HANDLE_VALUE,
      "could not open the daemon's pipe " & pipeName & " (Windows error " &
        $osLastError().int32 & ")"
    discard closeHandle(handle)

  proc openDescriptorCount(pid: int): int =
    ## The daemon's real open-HANDLE count, which is what a leaked accepted
    ## pipe instance would grow, read from the OS. -1 when it cannot be
    ## read, which the caller treats as "do not assert" rather than as zero.
    const ProcessQueryLimitedInformation = 0x1000'i32
    let process = openProcess(ProcessQueryLimitedInformation, 0, int32(pid))
    if process == 0:
      return -1
    defer: discard closeHandle(process)
    var count = 0'i32
    if getProcessHandleCount(process, addr count) == 0:
      return -1
    int(count)
else:
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
  ## `RUNQUOTA_SOCKET` goes in through the child's environment rather than
  ## as a `VAR=value cmd` shell prefix, which only a POSIX shell parses.
  let env = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    env[key] = value
  env["RUNQUOTA_SOCKET"] = socketPath
  let probe = runCapturedProcess(cliPath(), ["observations", "--json"],
    env = env, options = {})
  doAssert probe.ok, "observations query failed: " & probe.output &
    probe.error & probe.failure
  let doc = parseJson(probe.output)
  doc["observations"]["connections_failed"].getInt

suite "connection_failure_does_not_stop_the_daemon":

  test "a peer that connects and vanishes cannot take the daemon with it":
    const AbortedConnections = 50

    let root = scratchRoot("connfail")
    defer: removeScratchRoot(root)
    let socketPath = root / "d.sock"

    var daemon = startDaemon(socketPath)
    defer: daemon.stop()
    check endpointIsBound(socketPath)

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
    var client = connect(endpointForPath(socketPath))
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

  test "a peer refused at Hello is counted too, and the daemon keeps serving":
    ## THE OTHER PRE-HELLO EXIT. A connection can also end before a session
    ## exists by being REFUSED: the daemon answers the opening frame with a
    ## diagnostic and closes. Like the vanishing peer above, that path raises
    ## nothing, so a counter fed only from `except` arms reads zero through it
    ## as well -- and unlike the vanishing peer, this one is a client that is
    ## still there to be told, which is exactly the case an operator chasing
    ## "why is nothing connecting" needs to see counted.
    ##
    ## The refusal is provoked the cheapest honest way: a well-formed frame
    ## that is not a `Hello`. `handleHello`'s first branch rejects it, which
    ## is the same arm every other refusal below it returns through.
    const RefusedConnections = 7

    let root = scratchRoot("connrefuse")
    defer: removeScratchRoot(root)
    let socketPath = root / "d.sock"

    var daemon = startDaemon(socketPath)
    defer: daemon.stop()
    check endpointIsBound(socketPath)

    for i in 0 ..< RefusedConnections:
      var connection = connectEndpoint(endpointForPath(socketPath))
      connection.sendFrame(encodeFrame(rqStatusRequest, 0'u16,
        uint64(i + 1), ""))
      # The daemon's diagnostic is read rather than ignored: leaving it
      # unread would close this end while the daemon is still writing, and
      # the test would then be measuring an EPIPE it created itself.
      var response: RqspFrame
      var diagnostic = okDiagnostic()
      discard connection.receiveFrame(response, diagnostic)
      connection.close()
    sleep(250)

    check daemon.process.running
    check failedConnectionCount(socketPath) == RefusedConnections

    # STILL SERVING, on the same socket, after the refusals.
    var client = connect(endpointForPath(socketPath))
    var session = client.registerSession("connrefuse", "0.1.0")
    var request = resourceRequest("connrefuse-probe", milliCpu(1000),
      bytes(64'u64 * MiB))
    var lease = session.requestLease(request)
    check lease.active
    lease.markStarting()
    lease.markRunning(childProcessId = uint64(getCurrentProcessId()))
    lease.finish(outcome = succeeded(), processCount = 1'u32)
