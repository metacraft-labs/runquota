## A learned-estimate store that is dropping every batch must be READABLE as
## such, not merely mentioned once on stdout.
##
## THE GAP THIS CLOSES. `noteEstimateWriteFailure` already counts a dropped
## batch and already prints the first one; `estimateWriteFailures()` and
## `estimateWriteFailedRows()` already exist. What did not exist was a
## consumer: nothing outside `runquota_persistence` and its own unit tests
## ever read either counter, so an operator got ONE line of stdout, printed
## at the first failure, for a store that may have been dropping every batch
## since — while `connections_failed`, a smaller loss on a neighbouring path,
## was in the status JSON all along.
##
## THE POLICY IS UNCHANGED, deliberately. Not raising is correct (OS-4): a
## daemon must not stop granting leases because it forgot how much memory a
## command used last time, and a learned estimate is a cache. "Said once" is
## unchanged too — an unbounded log for a store that fails on every batch is
## an outage of its own. What changes is only that the COUNT can now be
## retrieved.
##
## NO MOCKS. The real `runquotad` binary, a real socket, the shipped client,
## and the daemon's own inspection subject.
##
## HOW THE FAILURE IS PROVOKED: `--estimate-db` is pointed at a path that is
## a DIRECTORY. `sqlite3` cannot open a directory as a database, so every
## batch the writer sends fails at the tool, which is exactly the shape of
## the real fault (a store on a full or read-only filesystem) and needs no
## privileges to arrange.

import std/[json, os, osproc, streams, strutils, times, unittest]

from runquota_ipc import endpointDirectoryPermissions
import runquota_client
import runquota_core
import runquota_protocol
import daemon_binary
import daemon_endpoint
import scratch_root

const
  MiB = 1024'u64 * 1024'u64
  StatsKey = "estimate-write-failure-visibility"
  Completions = 6
    ## Each keyed completion queues one row. More than one so that
    ## "rows" and "batches" can be told apart.

proc scratchRoot(name: string): string =
  # Short on purpose: `Sockaddr_un_path_length` is 92 on macOS.
  result = getTempDir() / ("rq-ewf-" & $getCurrentProcessId() & "-" & name)
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

type DaemonHandle = object
  process: Process

proc startDaemon(socketPath, stateDir, estimateDb: string): DaemonHandle =
  let process = startProcess(daemonPath(),
    args = ["--socket", socketPath,
            "--host-identity-file", stateDir / "host-id",
            "--estimate-db", estimateDb,
            "--ambient-sample-interval-millis", "0"],
    options = {poStdErrToStdOut})
  for _ in 0 ..< 400:
    if endpointIsBound(socketPath): break
    sleep(25)
  # EXACTLY THREE STARTUP LINES, consumed by count.
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

proc completeOne(session: var RunQuotaSession; peakBytes: uint64) =
  ## A keyed completion with a non-zero peak, which is what
  ## `updateEstimateFromFinish` requires before it queues a row at all.
  var request = resourceRequest("estimate-write-failure", milliCpu(100),
    bytes(1'u64 * MiB))
  request.commandStatsId = StatsKey
  var lease = session.requestLease(request)
  doAssert lease.active
  lease.markStarting()
  lease.markRunning(childProcessId = uint64(getCurrentProcessId()))
  lease.finish(outcome = succeeded(), peakMemoryBytes = peakBytes,
    processCount = 1'u32)
  lease.release()

proc estimateCounters(client: var RunQuotaClient):
    tuple[failures, rows: int] =
  let node = parseJson(client.inspectionJson("observations"))
  let observations = node["observations"]
  # `hasKey` rather than a bare lookup: an absent key is the defect this
  # file exists for, and a `KeyError` traceback says it far less clearly
  # than a failed check.
  doAssert observations.hasKey("estimate_write_failures"),
    "the status JSON does not report estimate_write_failures"
  doAssert observations.hasKey("estimate_write_failed_rows"),
    "the status JSON does not report estimate_write_failed_rows"
  (failures: observations["estimate_write_failures"].getInt(),
   rows: observations["estimate_write_failed_rows"].getInt())

proc waitForFailures(client: var RunQuotaClient; timeoutMs: int):
    tuple[failures, rows: int] =
  ## The writer drains on a 50 ms cadence, so a snapshot taken the instant
  ## the last completion is acknowledged would report zero for the trivial
  ## reason that the batch had not been attempted yet.
  let deadline = epochTime() + float(timeoutMs) / 1000.0
  while true:
    result = estimateCounters(client)
    if result.failures > 0 or epochTime() > deadline:
      return
    sleep(25)

suite "estimate_write_failures_are_visible":

  test "a store that cannot be written reports its dropped batches and rows":
    let root = scratchRoot("bad")
    # NOT `removeDir`. This case points `--estimate-db` at a directory so
    # that every batch the writer sends FAILS at the tool, which means a
    # `sqlite3` child is being spawned and dying for the whole of the test
    # -- exactly the population that can still be touching the scratch tree
    # when `daemon.stop()` returns. See `tests/support/scratch_root`.
    defer: removeScratchRoot(root)
    let socketPath = rendezvousDir(root) / "d.sock"
    let state = hostStateDir(root)
    # A DIRECTORY, which `sqlite3` cannot open as a database. Every batch
    # the writer sends therefore fails at the tool.
    let estimateDb = root / "estimates-as-a-directory"
    createDir(estimateDb)
    require fileExists(daemonPath())

    putEnv("RUNQUOTA_SOCKET", socketPath)
    var daemon = startDaemon(socketPath, state, estimateDb)
    try:
      var client = connectDefault()
      var session = client.registerSession("estimate-write-failure", "0.1.0")

      # Nothing has been queued yet, so the counters must READ ZERO rather
      # than be absent: "absent" and "zero" are the two states this test
      # has to tell apart.
      let before = estimateCounters(client)
      check before.failures == 0
      check before.rows == 0

      for i in 0 ..< Completions:
        completeOne(session, uint64(8 + i) * MiB)

      let after = waitForFailures(client, 20_000)
      echo "  estimate write failures: batches=", after.failures,
        " rows=", after.rows
      # THE DAEMON IS STILL SERVING, which is the half of OS-4 the policy
      # is built around: a store that cannot be written must not stop a
      # lease being granted.
      completeOne(session, 99'u64 * MiB)

      check after.failures > 0
      # One dropped batch is not one dropped estimate, which is why the two
      # counters exist separately. A batch always carries at least one row,
      # so rows can never be below batches; how far above depends on how the
      # 50 ms drain cadence happened to slice this run's completions, which
      # is not something to pin.
      check after.rows >= after.failures
      check after.rows > 0

      session.closeSession()
      client.close()
    finally:
      daemon.stop()
      delEnv("RUNQUOTA_SOCKET")

  test "a healthy store reports zero, so a non-zero count means something":
    let root = scratchRoot("good")
    defer: removeScratchRoot(root)
    let socketPath = rendezvousDir(root) / "d.sock"
    let state = hostStateDir(root)
    let estimateDb = root / "estimates.sqlite3"
    require fileExists(daemonPath())

    putEnv("RUNQUOTA_SOCKET", socketPath)
    var daemon = startDaemon(socketPath, state, estimateDb)
    try:
      var client = connectDefault()
      var session = client.registerSession("estimate-write-ok", "0.1.0")
      for i in 0 ..< Completions:
        completeOne(session, uint64(8 + i) * MiB)
      # Long enough for several drain passes to have come and gone.
      sleep(500)
      let counters = estimateCounters(client)
      check counters.failures == 0
      check counters.rows == 0
      # ...and the store really was written, so the zero is a report about
      # work that happened rather than about work that never started.
      check fileExists(estimateDb)
      session.closeSession()
      client.close()
    finally:
      daemon.stop()
      delEnv("RUNQUOTA_SOCKET")
