## A daemon from another build makes way: `RetireDaemon` and
## `runquota daemon stop` against a real `runquotad`.
##
## WHY THIS EXISTS. On Windows `runquotad` serves the per-user pipe and is
## left running for every invocation that adopts it, so when an installer
## replaced the bundle it came from, it kept serving the new `repro` from the
## old image and nothing could stop it short of killing it -- which ends the
## leases it holds (reprobuild-pm issue
## 2026-10-26-windows-runquotad-from-a-replaced-bundle-keeps-serving-the-new-repro).
## The decision (reprobuild-specs/RunQuota-Host-Configuration.md, "A daemon
## from another build makes way"):
##
## * a retiring daemon keeps serving every client it has, and admits new
##   ones, until no client connection is open; then it exits 0 through the
##   orderly shutdown and FREES ITS ENDPOINT, so the next daemon can bind it;
## * a request that names the image the daemon runs leaves it running;
## * `runquota daemon stop` asks unconditionally, and `--wait` reports a
##   daemon that clients still hold open (exit 3) rather than hanging.
##
## Each clause is observed from outside: the daemon's exit status and its
## log, whether its endpoint still exists, whether a second daemon can bind
## the same endpoint, and whether a lease taken before the stop is still
## served after it. Stop counting admitted connections and the drain case
## fails (the daemon exits under a live lease); stop unlinking the socket the
## listener bound and the idle case fails on POSIX (the endpoint outlives the
## daemon); compare no digest and the same-image case fails (the daemon
## exits). Not covered: that a retiring daemon frees its endpoint BEFORE the
## rest of its shutdown -- the drain after the decision is too short to
## observe from outside without a timing race.
##
## A PRIVATE DAEMON, ALWAYS: `--socket` on a scratch endpoint, reached through
## `RUNQUOTA_SOCKET`. Nothing here talks to the host's daemon, which a stop
## would end for every workspace on the machine.
##
## NO MOCKS. The shipped `runquota` and `runquotad` binaries, a real
## endpoint, the real client library.

import private_broker_owner
import std/[os, osproc, streams, strutils, unittest]

from runquota_ipc import endpointDirectoryPermissions, endpointForPath
import runquota_client
import runquota_core
import runquota_core/image_digest
import runquota_protocol
import daemon_binary
import daemon_endpoint
from runquota_core/child_process import runCapturedProcess
import scratch_root

const
  MiB = 1024'u64 * 1024'u64
  ExitBudgetMillis = 15_000
    ## Generous: the exit joins a worker pool and drains the publisher. The
    ## clause is "it exits", not "it exits fast".

proc scratchRoot(name: string): string =
  # Short on purpose: `Sockaddr_un_path_length` is 92 on macOS.
  result = getTempDir() / ("rq-ret-" & $getCurrentProcessId() & "-" & name)
  removeDir(result)
  createDir(result)

proc rendezvousDir(root: string;
                   fixturePolicy: var PrivateBrokerCallerPolicyBinding): string =
  result = root / "ep"
  createDir(result)
  fixturePolicy = bindPrivateBrokerPolicyToCaller(privateEndpointGroup(result))
  setFilePermissions(result, endpointDirectoryPermissions())

proc hostStateDir(root: string): string =
  result = root / "state"
  createDir(result)
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc startDaemon(socketPath, stateDir: string): Process =
  result = startProcess(daemonPath(),
    args = ["--socket", socketPath,
            "--host-config", stateDir / "runquotad.toml",
            "--host-identity-file", stateDir / "host-id",
            "--ambient-sample-interval-millis", "0", "--no-write-stats",
            "--memory-bytes", $(8'u64 * 1024'u64 * MiB),
            "--memory-pressure-source", "unavailable"],
    options = {poStdErrToStdOut})
  for _ in 0 ..< 400:
    if endpointIsBound(socketPath): break
    sleep(25)
  doAssert endpointIsBound(socketPath), "runquotad did not bind " & socketPath
  discard readRequiredStartupLines(result, 3, "t_daemon_retirement")

proc reap(daemon: var Process): int =
  ## The daemon's exit status, waiting at most `ExitBudgetMillis`; -1 when it
  ## is still running then (it is killed, so the suite does not leak it).
  result = daemon.waitForExit(ExitBudgetMillis)
  if daemon.running:
    daemon.kill()
    discard daemon.waitForExit(5000)
    result = -1

proc restOfLog(daemon: Process): string =
  ## What the daemon printed after its startup lines; read once it has exited.
  try:
    daemon.outputStream.readAll()
  except IOError, OSError:
    ""

type CliResult = object
  output: string
  code: int

proc runCli(args: varargs[string]): CliResult =
  var argv: seq[string] = @[]
  for arg in args:
    argv.add(arg)
  let captured = runCapturedProcess(cliPath(), argv, options = {})
  doAssert captured.failure.len == 0, captured.failure
  result = CliResult(output: captured.output & captured.error,
    code: captured.exitCode)
  checkpoint "runquota " & argv.join(" ") & " -> " & $result.code & "\n" &
    result.output

proc takeLease(session: var RunQuotaSession; label: string): RunQuotaLease =
  result = session.requestLease(resourceRequest(label, milliCpu(100),
    bytes(1'u64 * MiB)))
  doAssert result.active, "lease " & label & " was not granted"

suite "daemon retirement":

  test "an idle daemon stops on request and frees its endpoint for the next":
    let privateOwner = bindPrivateBrokerOwnerToCaller()
    defer: restorePrivateBrokerOwner(privateOwner)
    let root = scratchRoot("idle")
    defer: removeScratchRoot(root)
    var policy: PrivateBrokerCallerPolicyBinding
    defer: restorePrivateBrokerPolicy(policy)
    let socket = rendezvousDir(root, policy) / "d.sock"
    let state = hostStateDir(root)
    putEnv("RUNQUOTA_SOCKET", socket)
    defer: delEnv("RUNQUOTA_SOCKET")

    var first = startDaemon(socket, state)
    let stop = runCli("daemon", "stop", "--wait", "--timeout", "15")
    check stop.code == 0
    check "runquotad (pid " & $first.processID & ") is stopping" in stop.output
    check "has stopped" in stop.output
    # `serve` returned: an exit through the orderly shutdown, not a kill.
    check first.reap() == 0
    let log = first.restOfLog()
    checkpoint "first daemon's log:\n" & log
    check "RetireDaemon from pid " in log
    check "(runquota daemon stop)" in log
    check "runquotad: retiring now: no client connection remains" in log
    first.close()
    # THE ENDPOINT IS FREE, which is what the next client needs.
    check not endpointIsBound(socket)

    # And a second daemon binds the same endpoint and serves it.
    var second = startDaemon(socket, state)
    var client = connect(endpointForPath(socket))
    var session = client.registerSession("after", "1")
    var lease = session.takeLease("after-retirement")
    lease.release()
    session.closeSession()
    client.close()
    check runCli("daemon", "stop", "--wait", "--timeout", "15").code == 0
    check second.reap() == 0
    second.close()

  test "a stop drains: clients are served, new ones admitted, exit after the last":
    let privateOwner = bindPrivateBrokerOwnerToCaller()
    defer: restorePrivateBrokerOwner(privateOwner)
    let root = scratchRoot("drain")
    defer: removeScratchRoot(root)
    var policy: PrivateBrokerCallerPolicyBinding
    defer: restorePrivateBrokerPolicy(policy)
    let socket = rendezvousDir(root, policy) / "d.sock"
    let state = hostStateDir(root)
    putEnv("RUNQUOTA_SOCKET", socket)
    defer: delEnv("RUNQUOTA_SOCKET")

    var daemon = startDaemon(socket, state)
    var holder = connect(endpointForPath(socket))
    var held = holder.registerSession("holder", "1")
    var before = held.takeLease("before-stop")

    let stop = runCli("daemon", "stop")
    check stop.code == 0
    check "is stopping once its 1 other client connection(s) close" in
      stop.output

    # STILL SERVING. A build in flight is not cut off: its lease stands, and
    # it can take another.
    sleep(300)
    check daemon.running
    var after = held.takeLease("after-stop")
    let status = holder.daemonStatus()
    check status.activeLeases == 2'u32
    after.release()

    # A NEW CLIENT IS ADMITTED while clients remain: refusing it would fail
    # whoever arrives during somebody else's build.
    var late = connect(endpointForPath(socket))
    var lateSession = late.registerSession("late", "1")
    var lateLease = lateSession.takeLease("late")
    lateLease.release()

    # `--wait` with clients still connected reports it instead of hanging.
    let waited = runCli("daemon", "stop", "--wait", "--timeout", "1")
    check waited.code == 3
    check "still answers after 1s" in waited.output

    lateSession.closeSession()
    late.close()
    sleep(300)
    check daemon.running   # the holder is still connected

    before.release()
    held.closeSession()
    holder.close()
    check daemon.reap() == 0
    let log = daemon.restOfLog()
    checkpoint "daemon's log:\n" & log
    check "runquotad: retiring now: no client connection remains" in log
    daemon.close()
    check not endpointIsBound(socket)

  test "a request naming the running image leaves the daemon running":
    let privateOwner = bindPrivateBrokerOwnerToCaller()
    defer: restorePrivateBrokerOwner(privateOwner)
    let root = scratchRoot("same")
    defer: removeScratchRoot(root)
    var policy: PrivateBrokerCallerPolicyBinding
    defer: restorePrivateBrokerPolicy(policy)
    let socket = rendezvousDir(root, policy) / "d.sock"
    let state = hostStateDir(root)
    putEnv("RUNQUOTA_SOCKET", socket)
    defer: delEnv("RUNQUOTA_SOCKET")

    var daemon = startDaemon(socket, state)
    # The digest the daemon took of ITSELF at start is the digest of the file
    # this suite started: the identity a client compares is real.
    let image = imageDigestOf(daemonPath())
    require image.startsWith(ImageDigestPrefix)

    var asker = connect(endpointForPath(socket))
    check asker.supportsRetirement()
    let same = asker.retireDaemon(expectedImageDigest = image,
      reason = "same build")
    check same.decision == retirementCurrent
    check same.daemonImageDigest == image
    check same.daemonProcessId == uint64(daemon.processID)
    asker.close()
    sleep(300)
    check daemon.running
    check daemonReachable(endpointForPath(socket))

    # Another image retires it, and with nobody else connected it goes as
    # soon as the asker hangs up.
    var other = connect(endpointForPath(socket))
    let differs = other.retireDaemon(
      expectedImageDigest = ImageDigestPrefix & repeat('0', 64),
      reason = "another build")
    check differs.decision == retirementRetiring
    check differs.otherConnections == 0'u32
    check differs.daemonImageDigest == image
    other.close()
    check daemon.reap() == 0
    daemon.close()
    check not endpointIsBound(socket)

  test "stop with no daemon is success, and bad arguments are refused":
    let root = scratchRoot("none")
    defer: removeScratchRoot(root)
    putEnv("RUNQUOTA_SOCKET", root / "absent.sock")
    defer: delEnv("RUNQUOTA_SOCKET")
    let none = runCli("daemon", "stop", "--wait")
    check none.code == 0
    check "nothing to stop" in none.output
    check runCli("daemon", "stop", "--timeout").code == 2
    check runCli("daemon", "stop", "--timeout", "soon").code == 2
    check runCli("daemon", "stop", "--timeout", "-1").code == 2
    check runCli("daemon", "stop", "--force").code == 2
