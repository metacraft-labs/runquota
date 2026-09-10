## `kill -TERM` must reach the orderly shutdown, not step over it.
##
## THE DEFECT THIS EXISTS FOR. `serve`'s `finally` -- the block that joins
## the connection workers, lets the aggregate publisher publish its last
## keys, stops the ambient sampler and the retention sweeper, drains the
## observation writer and closes the published table -- runs ONLY when the
## accept loop breaks. Nothing in `apps/` or `libs/runquota_daemon/`
## installed a signal handler, so SIGTERM took its default disposition and
## ended the process where it stood: threads unjoined, queues undrained, the
## observations of everything that had just finished lost.
##
## That is not an exotic path. It is how every supervisor stops a daemon,
## how `systemd` stops one, and how every integration test in this tree
## stops one -- `Process.terminate` sends exactly this signal.
##
## WHAT THE TEST ASSERTS, and why each clause is decisive:
##
##   1. **The daemon exits 0.** A process killed by SIGTERM reports 143
##      (128 + `SIGTERM`) through `waitForExit`; a `serve` that returned
##      normally reports 0. There is no way to produce 0 without having run
##      the `finally`.
##   2. **Every execution reported before the signal is IN THE STORE.** The
##      completions are a burst timed to be shorter than the writer's 25 ms
##      drain cadence, so rows are certainly still queued when the signal
##      arrives; a daemon that dies where it stands loses them. This is the
##      clause that would fail on a daemon which trapped the signal and then
##      exited without draining -- clause 1 alone would not.
##   3. **It exits promptly.** An orderly shutdown that never finishes is a
##      hang, which is a worse failure than the one being fixed, so the
##      window is bounded and the bound is asserted rather than assumed.
##
## NO MOCKS. The real `runquotad` binary, a real socket, the shipped client,
## a real signal, and the database file the daemon left behind.

import std/[os, osproc, posix, streams, strutils, times, unittest]

from runquota_ipc import endpointDirectoryPermissions
import runquota_client
import runquota_core
import runquota_observation_store
import runquota_protocol
import daemon_binary

const
  MiB = 1024'u64 * 1024'u64
  StatsKey = "sigterm-drain"
  Completions = 120
    ## Enough that the burst cannot fit between two of the writer's 25 ms
    ## drains, so some of it is certainly still queued when the signal
    ## lands, and small enough that the burst itself stays well under one.
  ShutdownBudgetMillis = 15_000
    ## Generous: the shutdown joins a worker pool, lets the publisher take
    ## one more pass and drains two SQLite writers, each of which spawns a
    ## child. The clause is "it finishes", not "it finishes fast".

proc scratchRoot(name: string): string =
  # Short on purpose: `Sockaddr_un_path_length` is 92 on macOS.
  result = getTempDir() / ("rq-sig-" & $getCurrentProcessId() & "-" & name)
  removeDir(result)
  createDir(result)

proc rendezvousDir(root: string): string =
  result = root / "ep"
  createDir(result)
  setFilePermissions(result, endpointDirectoryPermissions())

proc hostStateDir(root: string): string =
  result = root / "state"
  createDir(result)
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc socketIsBound(path: string): bool =
  var info: Stat
  lstat(path.cstring, info) == 0 and S_ISSOCK(info.st_mode)

proc startDaemon(socketPath, stateDir: string): Process =
  result = startProcess(daemonPath(),
    args = ["--socket", socketPath,
            "--host-identity-file", stateDir / "host-id",
            "--ambient-sample-interval-millis", "0"],
    options = {poStdErrToStdOut})
  for _ in 0 ..< 400:
    if socketIsBound(socketPath): break
    sleep(25)
  # EXACTLY THREE STARTUP LINES, consumed by count.
  for _ in 0 ..< 3:
    discard result.outputStream.readLine()

proc completeOne(session: var RunQuotaSession; peakBytes: uint64) =
  var request = resourceRequest("sigterm-drain", milliCpu(100),
    bytes(1'u64 * MiB))
  request.commandStatsId = StatsKey
  var lease = session.requestLease(request)
  doAssert lease.active
  lease.markStarting()
  lease.markRunning(childProcessId = uint64(getCurrentProcessId()))
  lease.finish(outcome = succeeded(), peakMemoryBytes = peakBytes,
    processCount = 1'u32)
  lease.release()

suite "sigterm_drains_before_exit":

  test "a TERMed daemon runs its shutdown and keeps what was reported":
    let root = scratchRoot("drain")
    let socketPath = rendezvousDir(root) / "d.sock"
    let state = hostStateDir(root)
    let expectedDb = state / "observations.sqlite3"
    require fileExists(daemonPath())

    putEnv("RUNQUOTA_SOCKET", socketPath)
    var daemon = startDaemon(socketPath, state)
    var exitCode = -1
    var elapsedMillis = 0.0
    try:
      var client = connectDefault()
      var session = client.registerSession("sigterm-drain", "0.1.0")
      # THE BURST. Nothing waits for the store between these and the signal,
      # which is the whole point: what is still queued is what a daemon that
      # dies where it stands would lose.
      for i in 0 ..< Completions:
        completeOne(session, uint64(8 + i) * MiB)
      session.closeSession()
      client.close()

      let start = epochTime()
      doAssert kill(Pid(daemon.processID), SIGTERM) == 0,
        "could not send SIGTERM to the daemon"
      exitCode = daemon.waitForExit(ShutdownBudgetMillis)
      elapsedMillis = (epochTime() - start) * 1000.0
    finally:
      if daemon.running:
        daemon.kill()
        discard daemon.waitForExit(5000)
      daemon.close()
      delEnv("RUNQUOTA_SOCKET")

    echo "  sigterm: exit=", exitCode, " after ",
      elapsedMillis.formatFloat(ffDecimal, 1), " ms"

    # CLAUSE 1. 143 is "killed by SIGTERM"; 0 is "`serve` returned".
    check exitCode == 0
    # CLAUSE 3.
    check elapsedMillis < float(ShutdownBudgetMillis)

    # CLAUSE 2. Read out of the file the daemon left behind, by a process
    # that had nothing to do with writing it.
    check fileExists(expectedDb)
    let store = openObservationStore(expectedDb)
    check store.captureEnabled
    let executions = store.readExecutions()
    echo "  sigterm: executions in the store = ", executions.len,
      " of ", Completions
    check executions.len == Completions

    removeDir(root)
