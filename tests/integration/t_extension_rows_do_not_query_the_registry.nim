## OS-1 ON THE EXTENSION ROW PATH: attaching a row to an execution must not
## ask the database anything.
##
## THE DEFECT THIS EXISTS FOR. ``admitExtensionRow`` read
## ``extension_registry`` out of the store for EVERY row, to learn two
## things — that the extension is registered, and what schema version the
## registry carries. The observation store is driven through the ``sqlite3``
## COMMAND LINE, so that read is a subprocess spawn; a row arrives once per
## observed execution; and all of it ran on the daemon thread under the
## daemon-wide lock every other connection is waiting on. Measured on the
## development host at 21 ms per row, 1.4 s for a 64-action build.
##
## IT WAS INVISIBLE FROM THE ONE PLACE ANYBODY WAS LOOKING, and that is the
## harder half. ``rqExtensionRow`` is ONE-WAY: the sender is never
## acknowledged, so the spawn appears in no round-trip latency and in no
## per-message percentile. The M1 socket baseline priced 268 per-execution
## round trips per build at 4.3 ms and reported the remaining cost as
## belonging to ``CloseSession`` — 51 ms, twice a build, in a handler that
## touches no store at all. It was the backlog: a build sends its rows at
## the END, when it finally knows its output sizes, and ``CloseSession`` is
## simply the next request on that connection. The defect was read as
## session-scoped and as not scaling with build width. It was neither.
##
## FOUR CLAUSES, EACH FAILING FOR ITS OWN REASON:
##
##   1. **Registry reads do not scale with rows.** The store counts every
##      read it issues to the database and the daemon reports the count.
##      One read per DECLARATION is the design — it is the authoritative
##      read that makes answering the row path from memory sound — and a
##      burst of rows that produces none of its own cannot have been
##      served by a path that reads per row.
##   2. **A miss still asks the database.** A row naming an extension
##      nobody declared is still refused, and asking cost a read. Without
##      this, clause 1 could be satisfied by a memo that never falls
##      through, which would accept rows for extensions that do not exist.
##   3. **The version comparison served from memory is a real comparison.**
##      A row declaring a version NEWER than the registry carries is still
##      refused. A memo consulted but not compared against would write it.
##   4. **A burst drains in a time no spawning implementation can reach.**
##      This one IS a stopwatch and is a cross-check rather than the
##      verdict, which is why clause 1 exists. Its bound was calibrated
##      against the defect rather than guessed: see ``SlackMillisPerRow``.
##
## NO MOCKS. The real ``runquotad`` binary from ``build/bin``, a real
## Unix-domain socket, the shipped client library, the daemon's own
## inspection subject, and the SQLite file the daemon really wrote.

import std/[json, os, osproc, posix, streams, strutils, times, unittest]

from runquota_ipc import endpointDirectoryPermissions
import runquota_client
import runquota_core
import runquota_observation_store
import runquota_protocol
import daemon_binary

const
  ProbeExtension = "regreads_probe"
  UndeclaredExtension = "regreads_absent"
  ProbeKey = "regreads-write-path"
  probeDdl = """
create table ext_regreads_probe (
  host_id text not null,
  execution_id text not null,
  probe_label text,
  primary key (host_id, execution_id),
  foreign key (host_id, execution_id)
    references executions(host_id, execution_id)
);
"""
  MiB = 1024'u64 * 1024'u64
  BurstRows = 40
    ## Enough that "one read per row" and "no reads at all" cannot be
    ## confused for one another, and small enough that the arm finishes in
    ## about a second even with the defect present.
  SlackMillisPerRow = 2.0
    ## THE SLACK IS DELIBERATELY HUGE, AND IT WAS CHECKED AGAINST THE
    ## DEFECT RATHER THAN CHOSEN. With the row path reading the registry,
    ## this burst measured 837 ms — 21 ms per row, which is what a
    ## ``sqlite3`` spawn costs on the development host. Without it, 0.065 ms
    ## for the whole burst. Two milliseconds per row is a thousand times
    ## above the fixed figure and ten times below the defect, so no amount
    ## of load on a healthy host can reach it and no spawning
    ## implementation can duck under it.

proc scratchRoot(name: string): string =
  # Short on purpose: `Sockaddr_un_path_length` is 92 on macOS.
  result = getTempDir() / ("rq-rr-" & $getCurrentProcessId() & "-" & name)
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

type DaemonHandle = object
  process: Process

proc startDaemon(socketPath, stateDir: string): DaemonHandle =
  let process = startProcess(daemonPath(),
    args = ["--socket", socketPath,
            "--host-identity-file", stateDir / "host-id",
            # The ambient sampler is off so that nothing but this test's own
            # traffic can touch the store while the counters are being read.
            "--ambient-sample-interval-millis", "0"],
    options = {poStdErrToStdOut})
  for _ in 0 ..< 400:
    if socketIsBound(socketPath): break
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

type RowCounters = object
  registryReads: int
  accepted: int
  refused: int

proc rowCounters(client: var RunQuotaClient): RowCounters =
  ## FROM THE DAEMON'S OWN INSPECTION SUBJECT. `inspectionJson` is a plain
  ## request/response that reads in-memory fields, so asking for the count
  ## does not move the count.
  let node = parseJson(client.inspectionJson("observations"))["observations"]
  RowCounters(
    registryReads: node["extension_registry_reads"].getInt(),
    accepted: node["extension_rows"].getInt(),
    refused: node["extension_rows_refused"].getInt())

proc completeOneExecution(session: var RunQuotaSession): uint64 =
  var request = resourceRequest(ProbeKey, milliCpu(100), bytes(1'u64 * MiB))
  request.commandStatsId = ProbeKey
  var lease = session.requestLease(request)
  doAssert lease.active
  result = lease.id.value
  lease.markStarting()
  lease.markRunning(childProcessId = uint64(getCurrentProcessId()))
  lease.finish(outcome = succeeded(), peakMemoryBytes = 1_000_000'u64,
    processCount = 1'u32)
  lease.release()

proc waitForProbeRows(path: string; atLeast: int64): int64 =
  for _ in 0 ..< 200:
    let store = openObservationStore(path)
    if store.captureEnabled:
      result = store.extensionRowCount(ProbeExtension)
      if result >= atLeast:
        return
    sleep(50)

suite "extension_rows_do_not_query_the_registry":

  test "a burst of extension rows reads the registry no more than a declaration does":
    let root = scratchRoot("rows")
    defer: removeDir(root)
    let socketPath = rendezvousDir(root) / "d.sock"
    let state = hostStateDir(root)
    let dbPath = state / "observations.sqlite3"
    require fileExists(daemonPath())

    putEnv("RUNQUOTA_SOCKET", socketPath)
    var daemon = startDaemon(socketPath, state)
    try:
      var client = connectDefault()
      var session = client.registerSession("regreads", "0.1.0")

      # ---------------------------------------------------------------
      # THE DECLARATION, AND ITS READ. The registry must be read here or
      # nothing below has an authoritative answer to serve from.
      # ---------------------------------------------------------------
      let beforeDeclare = rowCounters(client)
      check session.declareExtension(ProbeExtension, "regreads-test", 1,
        [probeDdl]) == ""
      let afterDeclare = rowCounters(client)
      check afterDeclare.registryReads > beforeDeclare.registryReads

      # Executions first, so the burst below is rows and nothing else.
      var leaseIds: seq[uint64] = @[]
      for _ in 0 ..< BurstRows:
        leaseIds.add(completeOneExecution(session))

      # ---------------------------------------------------------------
      # THE BURST. Sent the way a build sends them -- all at the end, one
      # per execution, one-way -- and then a trivial round trip, which is
      # what a real client's `CloseSession` was unknowingly measuring.
      # ---------------------------------------------------------------
      let before = rowCounters(client)
      let burstStart = epochTime()
      for id in leaseIds:
        session.recordExtensionRow(id, ProbeExtension, 1,
          ["probe_label"], [wireText("row")])
      # THE ROUND TRIP IS PART OF THE MEASUREMENT. The rows are one-way, so
      # the loop above returns before the daemon has looked at any of them;
      # a stopwatch stopped there would time the client's own writes and
      # nothing else. This request is answered only once the backlog in
      # front of it has been.
      let afterBurst = rowCounters(client)
      let burstMillis = (epochTime() - burstStart) * 1000.0

      # ---------------------------------------------------------------
      # THE FIXTURE MUST BE REAL. Every clause below is about what the row
      # path did NOT do, and a burst in which nothing was accepted would
      # satisfy all of them for the wrong reason.
      # ---------------------------------------------------------------
      check afterBurst.accepted - before.accepted == BurstRows
      check afterBurst.refused == before.refused
      check waitForProbeRows(dbPath, BurstRows) == BurstRows

      # ---------------------------------------------------------------
      # CLAUSE 1: registry reads do not scale with rows.
      # ---------------------------------------------------------------
      let reads = afterBurst.registryReads - before.registryReads
      echo "  registry reads: " & $reads & " for " & $BurstRows & " rows"
      # Exact rather than bounded, and it can be: the declaration is over,
      # the ambient sampler is off, the retention sweeper drives a store of
      # its own addressed by path, and nothing else on the daemon thread
      # touches the registry. A row path that reads produces BurstRows of
      # them; one that does not produces none.
      check reads == 0

      # ---------------------------------------------------------------
      # CLAUSE 4: the burst drains faster than spawning could manage.
      # ---------------------------------------------------------------
      echo "  burst of " & $BurstRows & " rows drained in " &
        burstMillis.formatFloat(ffDecimal, 3) & " ms"
      check burstMillis < SlackMillisPerRow * float(BurstRows)

      session.closeSession()
      client.close()
    finally:
      daemon.stop()
      delEnv("RUNQUOTA_SOCKET")

  test "an undeclared extension still costs a read and is still refused":
    # CLAUSE 2. Answering the row path from memory is only sound because a
    # MISS falls through to the database. Without the fallthrough, "this
    # process has not heard of that extension" and "this store has no such
    # extension" become the same answer, and the first one is wrong for
    # every extension registered before this daemon started.
    let root = scratchRoot("miss")
    defer: removeDir(root)
    let socketPath = rendezvousDir(root) / "d.sock"
    let state = hostStateDir(root)
    require fileExists(daemonPath())

    putEnv("RUNQUOTA_SOCKET", socketPath)
    var daemon = startDaemon(socketPath, state)
    try:
      var client = connectDefault()
      var session = client.registerSession("regreads-miss", "0.1.0")
      check session.declareExtension(ProbeExtension, "regreads-test", 1,
        [probeDdl]) == ""

      let leaseId = completeOneExecution(session)
      let before = rowCounters(client)
      session.recordExtensionRow(leaseId, UndeclaredExtension, 1,
        ["probe_label"], [wireText("nowhere")])
      let after = rowCounters(client)

      check after.refused - before.refused == 1
      check after.accepted == before.accepted
      # AND IT WENT TO THE DATABASE TO FIND OUT. A refusal reached without
      # a read would be a refusal reached by assumption.
      check after.registryReads > before.registryReads

      session.closeSession()
      client.close()
    finally:
      daemon.stop()
      delEnv("RUNQUOTA_SOCKET")

  test "a row claiming a version the registry does not carry is still refused":
    # CLAUSE 3. The remembered entry is compared, not merely found. A memo
    # that returned "registered" without its schema version would write a
    # row shaped for columns this database does not have, and the row would
    # read back afterwards as a complete observation of an older schema.
    let root = scratchRoot("ver")
    defer: removeDir(root)
    let socketPath = rendezvousDir(root) / "d.sock"
    let state = hostStateDir(root)
    require fileExists(daemonPath())

    putEnv("RUNQUOTA_SOCKET", socketPath)
    var daemon = startDaemon(socketPath, state)
    try:
      var client = connectDefault()
      var session = client.registerSession("regreads-ver", "0.1.0")
      check session.declareExtension(ProbeExtension, "regreads-test", 1,
        [probeDdl]) == ""

      let leaseId = completeOneExecution(session)
      let before = rowCounters(client)
      # Version 2 against a registry that carries version 1.
      session.recordExtensionRow(leaseId, ProbeExtension, 2,
        ["probe_label"], [wireText("too-new")])
      let refusedOnce = rowCounters(client)
      check refusedOnce.refused - before.refused == 1
      check refusedOnce.accepted == before.accepted

      # NON-VACUITY: the same row at the version the registry carries is
      # accepted, so the refusal above is about the version and not about
      # the row.
      session.recordExtensionRow(leaseId, ProbeExtension, 1,
        ["probe_label"], [wireText("just-right")])
      let accepted = rowCounters(client)
      check accepted.accepted - refusedOnce.accepted == 1

      session.closeSession()
      client.close()
    finally:
      daemon.stop()
      delEnv("RUNQUOTA_SOCKET")
