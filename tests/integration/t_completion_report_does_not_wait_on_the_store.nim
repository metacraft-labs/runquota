## OS-1 AT THE COMPLETION REPORT: finishing a lease must not wait on the
## observation store.
##
## THE DEFECT THIS EXISTS FOR. M13b published a stats key's aggregate from
## inside ``LeaseFinished``. Publishing means a SYNCHRONOUS DRAIN of the
## observation writer's queue followed by ``estimateFor`` — three ``sqlite3``
## subprocess spawns — and all of it ran under the daemon-wide lock every
## other connection worker is waiting on. ``flushObservationWriter``'s own
## contract says "for the read path, never for the write path", and a
## completion report is the write path. It cost 21.9 ms per finished action
## in the M1 wide-build measurement, 2.4 s of a 92 s build, and 95.2% of
## everything RunQuota's socket cost that build.
##
## IT WAS INVISIBLE, AND THAT IS THE HARDER HALF. Every functional assertion
## in this suite passed throughout: the right rows were written, the right
## aggregate was published, the published figure equalled the socket's. The
## defect showed up only as latency, the M13 benchmark that was supposed to
## catch it never set a stats key so the expensive branch never ran for it,
## and a bare latency bound on a workstation is a flake generator. So the
## clauses below are built to be decisive without being timing-sensitive.
##
## THREE CLAUSES, EACH FAILING FOR ITS OWN REASON:
##
##   1. **Synchronous drains do not scale with completed work.** The writer
##      counts every drain taken on a caller's thread and the daemon reports
##      the count. One drain per query and one per publication BATCH are
##      expected and allowed; one per finished lease is the defect, and
##      forty completions that produce fewer than forty drains cannot be
##      produced by a completion path that flushes.
##   2. **A keyed completion costs what a keyless one costs**, measured
##      against a live control on the SAME daemon in the SAME run. This is
##      not a latency bound: it is a paired comparison whose two arms differ
##      only in whether ``commandStatsId`` is set, which is the exact switch
##      that used to select tens of milliseconds of store IO. The slack is
##      enormous — three orders of magnitude below the defect — so drift on
##      a busy host cannot reach it.
##      *(The keyless arm is also what the M13 benchmark measured for the
##      whole of its life, believing it was measuring the other one.)*
##   3. **Deferring publication did not make it stale.** The aggregate
##      published after the last completion still includes that completion —
##      the property the old synchronous flush existed to buy, asserted on a
##      figure that could only have come from the final run.
##
##      **STATED HONESTLY: this clause does not discriminate the publisher's
##      own flush.** Deleting `flushObservationWriter` from the publication
##      thread leaves this clause passing, and that was checked rather than
##      assumed. The reason is that the writer's drain thread runs on the
##      same 25 ms cadence and lands the row anyway, so the flush is
##      insurance against a stalled writer rather than the mechanism. What
##      the clause does catch is the larger shortcut — publishing an
##      aggregate computed before the run that dirtied the key, which is what
##      "defer it and accept one-run staleness" would produce.
##
## NO MOCKS. The real ``runquotad`` binary from ``build/bin``, a real
## Unix-domain socket, the shipped client library, the daemon's own
## inspection subject, and the segment the daemon really wrote.

import std/[json, os, osproc, posix, streams, strutils, times, unittest]

from runquota_ipc import endpointDirectoryPermissions
import runquota_client
import runquota_core
import runquota_protocol
import runquota_stats_table
import daemon_binary

const
  MiB = 1024'u64 * 1024'u64
  KeyedStatsKey = "completion-latency-keyed"
  Completions = 40
    ## Enough that "one drain per completion" and "a few drains in total"
    ## cannot be confused for one another, and small enough that the run
    ## stays under a second even when the defect is present.
  WarmupCompletions = 10
  LatencySlackMillis = 2.0
    ## THE SLACK IS DELIBERATELY HUGE. The defect adds 20-70 ms per keyed
    ## completion; a keyless completion costs about 0.05 ms. Two
    ## milliseconds is forty times the quantity being compared and a
    ## thirtieth of the smallest defect ever measured, so this clause
    ## cannot flake into failure and cannot pass with the defect present.

proc scratchRoot(name: string): string =
  # Short on purpose: `Sockaddr_un_path_length` is 92 on macOS.
  result = getTempDir() / ("rq-l-" & $getCurrentProcessId() & "-" & name)
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

proc timeOneCompletion(session: var RunQuotaSession; statsKey: string;
                       peakBytes: uint64): float =
  ## The whole lifecycle, timed. `LeaseFinished` is the round trip under
  ## test and the rest is shared by both arms, so a difference between the
  ## arms is a difference in what the completion did.
  var request = resourceRequest("completion-latency", milliCpu(100),
    bytes(1'u64 * MiB))
  request.commandStatsId = statsKey
  let start = epochTime()
  var lease = session.requestLease(request)
  doAssert lease.active
  lease.markStarting()
  lease.markRunning(childProcessId = uint64(getCurrentProcessId()))
  lease.finish(outcome = succeeded(), peakMemoryBytes = peakBytes,
    processCount = 1'u32)
  lease.release()
  result = (epochTime() - start) * 1000.0

proc median(values: seq[float]): float =
  doAssert values.len > 0
  var sorted = values
  for i in 1 ..< sorted.len:
    let v = sorted[i]
    var j = i - 1
    while j >= 0 and sorted[j] > v:
      sorted[j + 1] = sorted[j]
      dec j
    sorted[j + 1] = v
  sorted[sorted.len div 2]

proc publicationCounters(client: var RunQuotaClient):
    tuple[drains, published, requested, coalesced: int] =
  ## FROM THE DAEMON'S OWN INSPECTION SUBJECT, not from anything this test
  ## maintains. `inspectionJson` is a plain request/response and does NOT
  ## flush the writer — only `queryStats` does — so reading the count does
  ## not perturb the count.
  let node = parseJson(client.inspectionJson("observations"))
  let publication = node["observations"]["aggregate_publication"]
  (drains: publication["synchronous_drains"].getInt(),
   published: publication["published"].getInt(),
   requested: publication["requested"].getInt(),
   coalesced: publication["coalesced"].getInt())

proc waitForPublicationsBeyond(client: var RunQuotaClient; mark: int;
                               timeoutMs: int):
    tuple[drains, published, requested, coalesced: int] =
  ## WAITING IS PART OF THE MEASUREMENT, not a nicety. The publisher is
  ## asynchronous now, which is the whole point, so a snapshot taken the
  ## instant the last completion is acknowledged would report zero
  ## publications and zero drains for the trivial reason that neither had
  ## happened yet — a bound that passes because nothing ran is exactly the
  ## check-that-cannot-fail this file exists to avoid. The window therefore
  ## closes only once the work it is counting has been done.
  let deadline = epochTime() + float(timeoutMs) / 1000.0
  while true:
    result = publicationCounters(client)
    if result.published > mark or epochTime() > deadline:
      return
    sleep(25)

proc waitForPublished(path, statsKey: string; timeoutMs: int;
                      estimate: var PublishedEstimate): bool =
  let deadline = epochTime() + float(timeoutMs) / 1000.0
  while epochTime() < deadline:
    var table = openStatsTable(path)
    if table.available:
      let verdict = table.lookupEstimate(statsKey, estimate)
      table.close()
      if verdict == stlHit: return true
    else:
      table.close()
    sleep(25)
  false

suite "completion_report_does_not_wait_on_the_store":

  test "a completion report does not drain the writer, and costs what a keyless one costs":
    let root = scratchRoot("lat")
    defer: removeDir(root)
    let endpointDir = rendezvousDir(root)
    let socketPath = endpointDir / "d.sock"
    let state = hostStateDir(root)
    require fileExists(daemonPath())

    putEnv("RUNQUOTA_SOCKET", socketPath)
    var daemon = startDaemon(socketPath, state)
    try:
      let tablePath = endpointDir / "stats-table"
      check fileExists(tablePath)

      var client = connectDefault()
      var session = client.registerSession("completion-latency", "0.1.0")

      # Warm both arms. The first completions of a run pay for a cold
      # SQLite file and a page cache that has not seen the store.
      for _ in 0 ..< WarmupCompletions:
        discard timeOneCompletion(session, KeyedStatsKey, 8'u64 * MiB)
        discard timeOneCompletion(session, "", 8'u64 * MiB)
      # ...and the warm-up's own publication is allowed to land before the
      # window opens, so its drain is not counted against the window.
      let before = waitForPublicationsBeyond(client, 0, 20_000)
      check before.published > 0

      var keyed: seq[float] = @[]
      var keyless: seq[float] = @[]
      for i in 0 ..< Completions:
        # ORDER ALTERNATES so neither arm is systematically first.
        if (i and 1) == 0:
          keyed.add(timeOneCompletion(session, KeyedStatsKey, 8'u64 * MiB))
          keyless.add(timeOneCompletion(session, "", 8'u64 * MiB))
        else:
          keyless.add(timeOneCompletion(session, "", 8'u64 * MiB))
          keyed.add(timeOneCompletion(session, KeyedStatsKey, 8'u64 * MiB))

      let after = waitForPublicationsBeyond(client, before.published, 20_000)

      # ---------------------------------------------------------------
      # THE FIXTURE MUST BE REAL. Every clause below is about what the
      # completion path did NOT do, and a run in which nothing was
      # published would satisfy all of them for the wrong reason.
      # ---------------------------------------------------------------
      check after.requested - before.requested == Completions
      check after.published > before.published

      # ---------------------------------------------------------------
      # CLAUSE 1: synchronous drains do not scale with completed work.
      # ---------------------------------------------------------------
      let drains = after.drains - before.drains
      echo "  drains: " & $drains & " for " & $Completions & " completions" &
        " (published " & $(after.published - before.published) &
        ", coalesced " & $(after.coalesced - before.coalesced) & ")"
      # A completion path that flushes produces one drain PER COMPLETION.
      # The publisher's thread produces at most one per batch, and it
      # batches by a 25 ms interval, so a burst this size is a handful.
      check drains < Completions div 2

      # ...and the coalescing that bound is made of is itself asserted,
      # because "few drains" could also be produced by a publisher that
      # simply stopped running.
      check after.coalesced > before.coalesced

      # ---------------------------------------------------------------
      # CLAUSE 2: the paired latency comparison.
      # ---------------------------------------------------------------
      let keyedMedian = median(keyed)
      let keylessMedian = median(keyless)
      echo "  keyed p50 " & keyedMedian.formatFloat(ffDecimal, 4) &
        " ms vs keyless p50 " & keylessMedian.formatFloat(ffDecimal, 4) & " ms"
      check keyedMedian <= keylessMedian + LatencySlackMillis
      # The control has to be a control: a keyless completion that itself
      # took milliseconds would make the comparison above vacuous.
      check keylessMedian < LatencySlackMillis

      # ---------------------------------------------------------------
      # CLAUSE 3: deferring publication did not make it stale.
      # ---------------------------------------------------------------
      # One last completion, with a peak larger than every earlier one, so
      # "the published aggregate includes the run that dirtied the key" is
      # a statement about a specific number rather than about a number that
      # was already there.
      const FinalPeakBytes = 777'u64 * MiB
      discard timeOneCompletion(session, KeyedStatsKey, FinalPeakBytes)
      var published: PublishedEstimate
      check waitForPublished(tablePath, KeyedStatsKey, 10_000, published)
      let deadline = epochTime() + 10.0
      while published.memoryBytes != FinalPeakBytes and epochTime() < deadline:
        sleep(25)
        discard waitForPublished(tablePath, KeyedStatsKey, 1_000, published)
      check published.knowledge == statsTableKnown
      check published.memoryBytes == FinalPeakBytes

      # AND IT IS STILL THE SOCKET'S OWN NUMBER, which is the property that
      # makes the table a cache. Deferring changed WHEN a figure appears,
      # never WHAT appears.
      var overSocket = 0'u64
      let answer = client.queryStats(statsSubjectDistribution,
        statsKey = KeyedStatsKey)
      for entry in answer.distributions:
        if entry.knowledge == statsKnowledgeWireKnown:
          overSocket = entry.peakRssBytesMax
      check overSocket == FinalPeakBytes
      check published.memoryBytes == overSocket

      session.closeSession()
      client.close()
    finally:
      daemon.stop()
      delEnv("RUNQUOTA_SOCKET")
