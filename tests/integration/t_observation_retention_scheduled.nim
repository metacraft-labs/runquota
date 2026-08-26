## The gap M15 named and left open: **nothing scheduled retention.** The
## bounds, the cascade and the crash-safe prune were all built and the only
## occurrence of ``applyRetention`` outside the tests was its own
## definition, so a long-lived ``runquotad`` grew its store forever. This
## file is the daemon-side half of closing that.
##
## NO MOCKS, AND NOTHING SUBSTITUTED. Every arm runs the real ``runquotad``
## binary from ``build/bin``, a real Unix-domain socket, the real RQSP
## client library, and a real SQLite store on the real filesystem. The rows
## asserted on are read back out of the database file the daemon pruned.
##
## WHY THE DAEMON BINARY RATHER THAN ``initDaemon`` IN PROCESS. M10's
## record and M11's mutation both say the same thing, and M13 repeats it:
## ``build/bin/runquotad`` is an INPUT to these tests and not an output of
## compiling them, so a mutation that recompiles only the test reports
## green while the code under test never executes. ``scripts/run_tests.sh``
## builds the apps first; an ad-hoc ``nim c -r`` of this file does not.
##
## THE CLAUSE THIS FILE EXISTS FOR, and the one M15 could not state:
## §"Retention" says pruning "MUST NOT hold the write path", and until
## something scheduled a pass there was nothing to assert that against. In
## ``runquotad`` it is not a figure of speech — every request is handled
## under one daemon-wide lock — so the test below takes a lease and records
## an observation over the socket WHILE A PRUNE IS IN FLIGHT, and pins the
## ordering with timestamps the daemon itself records: the pass had started
## before the requests were issued, and it had not finished when they were
## answered. Both endpoints are MEASURED, not sampled, which is the defect
## class M15's own crash test had to repair.

import std/[algorithm, json, options, os, osproc, posix, streams, strutils,
  unittest]

from runquota_ipc import endpointDirectoryPermissions
import runquota_client
import runquota_core
import runquota_observation_store
import runquota_protocol
import daemon_binary

const
  probeExtension = "m15sched_probe"
  seededExecutions = 60_000
    ## Enough rows that the pass they are pruned in has a MIDDLE to issue
    ## requests inside. The figure is not taken on trust: the test prints
    ## the window it measured and asserts it was at least 300 ms, so a
    ## host on which this stopped being enough says so rather than quietly
    ## asserting nothing. Measured on an aarch64 macOS host: 30,000 rows
    ## gave 469 ms — only a 1.6x margin over that floor — and 60,000 give
    ## 646-713 ms. The window grows sublinearly in the seed, so buying
    ## margin this way gets expensive quickly; this is the knee.
    ##
    ## IT IS ALSO BOUNDED FROM ABOVE, and by something real: the
    ## observation writer waits on SQLite's five-second busy timeout
    ## behind the pass, so a seed large enough to push a pass past five
    ## seconds would start dropping observations and the last assertions
    ## here would be measuring the timeout instead of the prune.

# ---------------------------------------------------------------------------
# Fixture plumbing
# ---------------------------------------------------------------------------

proc scratchRoot(name: string): string =
  # Short on purpose: `Sockaddr_un_path_length` is 92 on macOS and
  # `toSockAddr` refuses a path at or past it.
  result = getTempDir() / ("rq-m15r-" & $getCurrentProcessId() & "-" & name)
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
  startupLines: seq[string]

proc startDaemon(socketPath: string; extraArgs: openArray[string]):
    DaemonHandle =
  var args = @["--socket", socketPath]
  for arg in extraArgs:
    args.add(arg)
  let process = startProcess(daemonPath(), args = args,
    options = {poStdErrToStdOut})
  for _ in 0 ..< 400:
    if socketIsBound(socketPath): break
    sleep(25)
  # EXACTLY THREE STARTUP LINES, ALWAYS. Reading precisely three is itself
  # an assertion: retention is reported by APPENDING to the identity line
  # rather than by announcing itself on a fourth, because the startup
  # output is consumed by count and a fourth line leaves every reader of
  # the third one blocked or misaligned.
  var lines: seq[string] = @[]
  for _ in 0 ..< 3:
    lines.add(process.outputStream.readLine())
  DaemonHandle(process: process, startupLines: lines)

proc stop(handle: var DaemonHandle) =
  if handle.process.running:
    handle.process.terminate()
    discard handle.process.waitForExit(5000)
  if handle.process.running:
    handle.process.kill()
    discard handle.process.waitForExit(5000)
  handle.process.close()

proc observations(client: var RunQuotaClient): JsonNode =
  parseJson(client.inspectionJson("observations"))["observations"]

proc retention(client: var RunQuotaClient): JsonNode =
  client.observations()["retention"]

proc completeOneExecution(client: var RunQuotaClient; label: string) =
  ## One whole execution over the socket, the way a supervising client
  ## drives it.
  var session = client.registerSession("m15r-" & label, "0.2.0")
  var lease = session.requestLease(resourceRequest(
    label, milliCpu(1000), bytes(256'u64 * 1024'u64 * 1024'u64)))
  doAssert lease.active
  lease.markStarting()
  lease.markRunning(childProcessId = uint64(getCurrentProcessId()))
  lease.finish(outcome = leaseFinishSucceeded, exitCode = 0'u32,
    peakMemoryBytes = 1_234_567'u64, processCount = 3'u32,
    majorPageFaults = 11'u64)
  lease.release()
  session.closeSession()

proc waitForExecutions(path: string; atLeast: int): seq[ExecutionRow] =
  for _ in 0 ..< 240:
    let store = openObservationStore(path)
    if store.captureEnabled:
      result = store.readExecutions()
      if result.len >= atLeast:
        return
    sleep(50)

proc waitForRecordedExecution(path: string): seq[ExecutionRow] =
  ## Polls until a row that is NOT one of the seeded ones appears.
  ##
  ## NOT A ROW COUNT, and the difference is the point: the sweeper is
  ## still running, so the table is being pruned back to its bound
  ## underneath this loop and "seeded + 1" is a total that may never be
  ## observable. What must be true is that the execution recorded during
  ## the pass is IN there, named.
  for _ in 0 ..< 240:
    let store = openObservationStore(path)
    if store.captureEnabled:
      result = store.readExecutions()
      for row in result:
        if not row.executionId.startsWith("seed-"):
          return
    sleep(50)

proc executionCount(path: string): int =
  ## Counted in SQL rather than by reading every row back: the seeded
  ## store below holds tens of thousands, and `readExecutions` renders all
  ## of them through the CLI.
  let outcome = runSqlite(path, "select count(*) from executions;")
  if not outcome.ok:
    return -1
  try:
    parseInt(outcome.output.strip())
  except ValueError:
    -1

proc byStart(rows: seq[ExecutionRow]): seq[ExecutionRow] =
  result = rows
  result.sort(proc (a, b: ExecutionRow): int =
    cmp(a.startedAtUnixMillis, b.startedAtUnixMillis))

# ---------------------------------------------------------------------------
# Seeding a store the daemon will adopt
# ---------------------------------------------------------------------------

proc mintIdentity(identityFile: string): string =
  ## The identity file the daemon will read, written before it starts, so
  ## the rows seeded below belong to the host the daemon will call itself.
  result = opaqueId("host-")
  writeFile(identityFile, result & "\n")

proc extensionDdl(): string =
  "create table " & extensionTableName(probeExtension) & " (\n" &
  "  host_id text not null,\n" &
  "  execution_id text not null,\n" &
  "  probe_payload text not null,\n" &
  "  primary key (host_id, execution_id),\n" &
  "  foreign key (host_id, execution_id)\n" &
  "    references executions(host_id, execution_id)\n);"

proc seedStore(path, hostId: string; executions: int; firstStartedAt: int64;
               withExtension = true) =
  let store = openObservationStore(path)
  doAssert store.captureEnabled, store.report
  doAssert store.insertHost(HostRow(hostId: hostId,
    createdAtUnixMillis: 1_000, lastBootId: "boot"))
  doAssert store.insertHostProfile(HostProfileRow(hostId: hostId,
    profileId: "seeded", profileHash: "sha256:seeded",
    validFromUnixMillis: 1_000,
    cpuModel: "synthetic", physicalCores: 4, logicalCores: 8,
    ramBytes: 1 shl 34, swapBytes: 0, diskClass: dcSsd, fsType: "apfs",
    arch: "arm64", os: "macos", osVersion: "15", kernelVersion: "24",
    virtualization: "none", cpuShareGroup: "default"))
  doAssert store.insertRun(RunRow(runId: "seed-run", hostId: hostId,
    tool: "t", toolVersion: "v", invocationKind: "build",
    startedAtUnixMillis: 1_000, captureCompleteness: ccComplete))
  if withExtension:
    doAssert store.declareExtension(ExtensionDeclaration(
      extensionId: probeExtension, owner: "runquota-m15r", schemaVersion: 1,
      migrations: @[extensionDdl()])) == eoCreated

  var sql = "begin immediate;\n"
  for i in 0 ..< executions:
    let id = "seed-" & align($i, 7, '0')
    sql.add("insert into executions (execution_id, host_id, host_profile_id," &
      " run_id, command_stats_id, started_at_unix_millis, " &
      "finished_at_unix_millis, duration_millis, exit_status, termination, " &
      "attempt, peak_rss_bytes, max_processes, major_page_faults, " &
      "capture_completeness) values (" & encodeText(id) & ", " &
      encodeText(hostId) & ", 'seeded', 'seed-run', 'c', " &
      $(firstStartedAt + int64(i)) & ", " & $(firstStartedAt + int64(i) + 1) &
      ", 1, 0, 'exited', 1, 0, 1, 0, 'complete');\n")
    if withExtension:
      sql.add("insert into " & extensionTableName(probeExtension) &
        " values (" & encodeText(hostId) & ", " & encodeText(id) & ", " &
        encodeText("payload-" & $i) & ");\n")
  sql.add("commit;\n")
  doAssert store.runStatement(sql), store.lastError

suite "observation_retention_scheduled":

  # -------------------------------------------------------------------------
  # THE GATE: a running daemon bounds its own store, unasked
  # -------------------------------------------------------------------------

  test "a daemon prunes its own store on a cadence nobody asked it to run":
    let root = scratchRoot("gate")
    defer: removeDir(root)
    let socketPath = rendezvousDir(root) / "d.sock"
    let state = hostStateDir(root)
    let identityFile = state / "host-id"
    let expectedDb = state / "observations.sqlite3"
    check fileExists(daemonPath())

    putEnv("RUNQUOTA_SOCKET", socketPath)
    var daemon = startDaemon(socketPath,
      ["--host-identity-file", identityFile,
       "--retention-max-executions", "2",
       "--retention-max-execution-age-millis", "-1",
       "--retention-sweep-interval-millis", "1000"])
    var before: seq[ExecutionRow] = @[]
    var reported: JsonNode = nil
    var removed = 0
    try:
      # THE POLICY IS ON THE STARTUP LINE, appended to the identity report
      # rather than announced on a fourth line of its own.
      check daemon.startupLines[2].contains("retention every 1000ms")
      check daemon.startupLines[2].contains("max_executions=2")

      var client = connectDefault()
      check client.retention()["active"].getBool()

      # SIX REAL EXECUTIONS over the socket. Nothing here mentions
      # retention; this is an ordinary client doing ordinary work.
      #
      # SPACED SO THEIR START INSTANTS DIFFER. The count bound orders by
      # `started_at` and breaks ties on an OPAQUE execution id, so six
      # executions inside one millisecond would make "the newest two" a
      # question with no stable answer and the assertion below a coin
      # toss rather than a check.
      for i in 1 .. 6:
        client.completeOneExecution("gate-" & $i)
        sleep(20)

      # THEY EXISTED FIRST, AND THEY WERE ALL THERE. Without this the
      # assertions below are satisfied by rows that were never written.
      before = waitForExecutions(expectedDb, 6)
      check before.len == 6

      # NOBODY ASKS FOR THE PRUNE. The client is idle from here; a tick
      # fires and the bound is enforced.
      for _ in 0 ..< 400:
        removed = client.retention()["executions_removed"].getInt()
        if removed >= 4: break
        sleep(50)
      reported = client.retention()
      client.close()
    finally:
      daemon.stop()

    check removed == 4
    check reported != nil
    check reported["sweeps_finished"].getInt() >= 1
    check reported["failures"].getInt() == 0

    let after = openObservationStore(expectedDb)
    let kept = byStart(after.readExecutions())
    check kept.len == 2
    # THE NEWEST TWO, NAMED. A bound that kept the wrong end of the table
    # satisfies a count and throws away the only rows a reader wants.
    let ordered = byStart(before)
    check kept[0].executionId == ordered[4].executionId
    check kept[1].executionId == ordered[5].executionId
    # AND THE HARDWARE DIMENSION SURVIVED THE PRUNE.
    check after.readHosts().len == 1
    check after.readHostProfiles().len >= 1
    check kept[0].hostProfileId.isSome
    let orphanage = after.orphanReport()
    check orphanage.checked
    check orphanage.orphans == 0

  # -------------------------------------------------------------------------
  # THE CLAUSE M15 COULD NOT STATE: retention must not hold the write path
  # -------------------------------------------------------------------------

  test "a lease is granted and an observation recorded while a prune runs":
    # A FIXTURE THE HAPPY PATH CANNOT CONSTRUCT: a prune long enough to
    # drive a client through it. It needs a store with a year's worth of
    # rows in it before the daemon ever starts, which is why the store is
    # seeded and the host identity is written by hand first.
    #
    # WHAT IS ASSERTED INSIDE THE WINDOW, AND WHY EXACTLY THIS. "Recording
    # an observation" is admission plus an in-memory append: a lease
    # request reads only the daemon's private learned table, and
    # `rqLeaseObservation` is one-way and lands in the writer's queue. Both
    # are asserted to complete strictly inside the prune's window, because
    # a prune reached from a request handler -- or from anything holding
    # the daemon-wide lock -- would stop both dead.
    #
    # `LeaseFinished` IS DELIBERATELY NOT IN THE WINDOW ASSERTION, and
    # saying so is the honest part. M13b publishes the aggregate on that
    # path and flushes the writer synchronously first, so a finish landing
    # mid-prune waits on SQLite's busy timeout for the pass to commit. That
    # is a real cost and it is bounded twice over: the sweeper defers while
    # any lease is live, so the overlap needs work to arrive DURING a pass;
    # and `.timeout 5000` is what keeps the wait from becoming a dropped
    # observation.
    #
    # WHAT `droppedAfter == 0` BELOW ACTUALLY PINS, STATED HONESTLY: that
    # this execution survived this pass, and NOT that the busy timeout is
    # what saved it. Measured, not assumed — rebuilding with `.timeout 0`
    # leaves this arm GREEN, because the writer's 25 ms background drain
    # wins the race against a pass this test can afford to make. The
    # timeout's contribution is only reachable by a pass longer than five
    # seconds, which is above this fixture's ceiling for the reason given
    # at `seededExecutions`; when it IS exhausted the whole batch is
    # dropped and counted, which is OS-2-honest and the trade OS-1 asks
    # for, and no assertion here covers it.
    let root = scratchRoot("hold")
    defer: removeDir(root)
    let socketPath = rendezvousDir(root) / "d.sock"
    let state = hostStateDir(root)
    let identityFile = state / "host-id"
    let dbPath = state / "observations.sqlite3"
    let hostId = mintIdentity(identityFile)
    seedStore(dbPath, hostId, seededExecutions, unixMillisNow() - 400_000)
    check executionCount(dbPath) == seededExecutions

    putEnv("RUNQUOTA_SOCKET", socketPath)
    var daemon = startDaemon(socketPath,
      ["--host-identity-file", identityFile,
       "--retention-max-executions", "100",
       "--retention-max-execution-age-millis", "-1",
       "--retention-sweep-interval-millis", "1000"])
    var sawPassInFlight = false
    var admissionIssuedAt = 0'i64
    var admissionAnsweredAt = 0'i64
    var observationAcceptedAt = 0'i64
    var accepted = 0
    var passStartedAt = 0'i64
    var passFinishedAt = 0'i64
    var droppedAfter = -1
    var rows: seq[ExecutionRow] = @[]
    try:
      var client = connectDefault()

      # THE DAEMON ANSWERS WHILE THE PASS RUNS, and this loop is the first
      # half of the evidence: a daemon that pruned under its own lock
      # would not answer this request at all until the prune was over, so
      # `sweeps_started >= 1` with `sweeps_finished == 0` would never be
      # observed and the check below fails rather than hangs.
      for _ in 0 ..< 4_000:
        let snapshot = client.retention()
        if snapshot["sweeps_started"].getInt() >= 1:
          if snapshot["sweeps_finished"].getInt() == 0:
            sawPassInFlight = true
          break
        sleep(5)
      check sawPassInFlight

      # ADMISSION AND RECORDING, ISSUED INSIDE THE WINDOW.
      admissionIssuedAt = unixMillisNow()
      var session = client.registerSession("m15r-during-prune", "0.2.0")
      var lease = session.requestLease(resourceRequest(
        "during-prune", milliCpu(1000),
        bytes(256'u64 * 1024'u64 * 1024'u64)))
      check lease.active
      lease.markStarting()
      lease.markRunning(childProcessId = uint64(getCurrentProcessId()))
      lease.reportObservation(9_500'u32, 2_250_000_000'u64,
        uint64(unixMillisNow()))
      admissionAnsweredAt = unixMillisNow()

      # `rqLeaseObservation` is ONE-WAY, so the client is never told the
      # report landed. The counter is, and reading it is a second request
      # the daemon has to answer inside the same window.
      for _ in 0 ..< 2_000:
        accepted = client.observations()["accepted"].getInt()
        if accepted >= 1: break
        sleep(5)
      observationAcceptedAt = unixMillisNow()
      check accepted == 1

      # AND ONLY NOW THE FINISH, which is allowed to wait: see the note
      # above on M13b's synchronous flush.
      lease.finish(outcome = leaseFinishSucceeded, exitCode = 0'u32,
        peakMemoryBytes = 1_234_567'u64, processCount = 3'u32,
        majorPageFaults = 11'u64)
      lease.release()
      session.closeSession()

      var settled: JsonNode = nil
      for _ in 0 ..< 1_200:
        settled = client.retention()
        if settled["sweeps_finished"].getInt() >= 1: break
        sleep(50)
      check settled != nil
      check settled["sweeps_finished"].getInt() >= 1
      passStartedAt = settled["last_pass_started_at_unix_millis"].getBiggestInt()
      passFinishedAt =
        settled["last_pass_finished_at_unix_millis"].getBiggestInt()

      # AND THE OBSERVATION WAS NOT LOST. The record path is an in-memory
      # append and the drain waits on SQLite's busy timeout, so an
      # execution that overlapped a prune must still land, and no
      # observation may be dropped for it.
      rows = waitForRecordedExecution(dbPath)
      droppedAfter = client.observations()["dropped"].getInt()
      client.close()
    finally:
      daemon.stop()

    echo "  prune window: " & $(passFinishedAt - passStartedAt) &
      " ms; admission " & $(admissionIssuedAt - passStartedAt) & ".." &
      $(admissionAnsweredAt - passStartedAt) &
      " ms into it; report counted at " &
      $(observationAcceptedAt - passStartedAt) & " ms"

    # THE ORDERING, PINNED BY MEASURED ENDPOINTS AND NO THRESHOLD. The
    # daemon stamps the pass; the client stamps its own requests; both read
    # the same wall clock on the same host.
    check passStartedAt > 0
    check passFinishedAt > 0
    check passStartedAt <= admissionIssuedAt
    check admissionAnsweredAt <= passFinishedAt
    check observationAcceptedAt <= passFinishedAt
    # A WINDOW NOBODY CAN AIM AT IS NOT A WINDOW. If the pass were fast
    # enough that the lines above held by accident, this says so rather
    # than letting them pass vacuously.
    check passFinishedAt - passStartedAt >= 300

    # THE OBSERVATION WAS NOT LOST, AND IT IS NAMED RATHER THAN COUNTED.
    var recorded = 0
    for row in rows:
      if not row.executionId.startsWith("seed-"):
        inc recorded
    check recorded == 1
    check droppedAfter == 0

    # THE BOUND WAS ENFORCED, AND THE NEW ROW SURVIVED IT. 30,000 seeded
    # rows are gone; the one recorded inside the pass is the newest thing
    # left.
    let after = openObservationStore(dbPath)
    let kept = byStart(after.readExecutions())
    check kept.len >= 100
    check kept.len <= 101
    check not kept[^1].executionId.startsWith("seed-")
    check after.orphanReport().orphans == 0

  # -------------------------------------------------------------------------
  # REFUSAL: the operator turned retention off
  # -------------------------------------------------------------------------

  test "a zero sweep interval leaves every row where it is":
    let root = scratchRoot("off")
    defer: removeDir(root)
    let socketPath = rendezvousDir(root) / "d.sock"
    let state = hostStateDir(root)
    let identityFile = state / "host-id"
    let dbPath = state / "observations.sqlite3"
    let hostId = mintIdentity(identityFile)
    seedStore(dbPath, hostId, 40, unixMillisNow() - 40)
    check executionCount(dbPath) == 40

    putEnv("RUNQUOTA_SOCKET", socketPath)
    var daemon = startDaemon(socketPath,
      ["--host-identity-file", identityFile,
       "--retention-max-executions", "1",
       "--retention-sweep-interval-millis", "0"])
    var reported: JsonNode = nil
    var status = DaemonStatusMessage()
    try:
      # NAMED AS THE OPERATOR'S DECISION on the line they already read.
      check daemon.startupLines[2].contains("retention off")

      var client = connectDefault()
      # A bound of one execution is configured and would empty this store
      # in a single pass, so "40 rows are still there" is a statement
      # about the switch and not about a policy that had nothing to do.
      sleep(2_000)
      client.completeOneExecution("off")
      reported = client.retention()
      status = client.daemonStatus()
      client.close()
    finally:
      daemon.stop()

    check reported != nil
    check reported["active"].getBool() == false
    check reported["sweeps_started"].getInt() == 0
    check reported["executions_removed"].getInt() == 0
    check executionCount(dbPath) >= 40
    # And admission never noticed.
    check status.totalFinished >= 1'u64

  test "a bound of zero keeps nothing, and is not the absence of a bound":
    # THE OTHER HALF OF THE OFF SWITCH, and the half a well-behaved client
    # never exercises. `--retention-...` spells "this bound does not apply"
    # as a NEGATIVE value, so zero has to survive the flag as a REAL bound
    # of zero rows. `none` and `some(0)` are different instructions and the
    # parser is the only place they can be confused: the library's own
    # `some(0)` behaviour is gated by M15's unit test, which constructs the
    # policy directly and therefore cannot see a flag that turned zero into
    # `none`. Verified by mutation — spelling the parser `value <= 0` left
    # every other arm in this file green.
    let root = scratchRoot("zero")
    defer: removeDir(root)
    let socketPath = rendezvousDir(root) / "d.sock"
    let state = hostStateDir(root)
    let identityFile = state / "host-id"
    let dbPath = state / "observations.sqlite3"
    let hostId = mintIdentity(identityFile)
    seedStore(dbPath, hostId, 40, unixMillisNow() - 40)
    check executionCount(dbPath) == 40

    putEnv("RUNQUOTA_SOCKET", socketPath)
    var daemon = startDaemon(socketPath,
      ["--host-identity-file", identityFile,
       "--retention-max-executions", "0",
       "--retention-max-execution-age-millis", "-1",
       "--retention-sweep-interval-millis", "500"])
    var removed = 0
    var status = DaemonStatusMessage()
    try:
      # NAMED AS A LIMIT ON THE STARTUP LINE. A bound of zero must print as
      # `0` and not as `off`; the two are the operator's two different
      # answers and a line that spells them the same way is a line that
      # cannot be read.
      check daemon.startupLines[2].contains("max_executions=0")
      check not daemon.startupLines[2].contains("max_executions=off")
      # And the age bound beside it IS off, so the arm distinguishes the
      # two spellings on one line rather than asserting one of them alone.
      check daemon.startupLines[2].contains("max_execution_age_millis=off")

      var client = connectDefault()
      # ADMISSION NEVER NOTICES a policy that deletes everything, and the
      # execution goes in FIRST so the wait below covers it. A whole
      # execution over the socket, so this is a statement about work
      # completing rather than about a process being alive — and 41 rather
      # than 40 is what makes "the store was emptied" a statement about a
      # live daemon's own row too, not only about the seeded ones.
      client.completeOneExecution("zero")
      status = client.daemonStatus()
      for _ in 0 ..< 400:
        removed = client.retention()["executions_removed"].getInt()
        if removed >= 41: break
        sleep(50)
      check client.retention()["failures"].getInt() == 0
      client.close()
    finally:
      daemon.stop()

    check removed >= 41
    # KEEPS NOTHING, and the store is still a store: an emptied spine must
    # leave the hardware dimension resolvable, exactly as a partial prune
    # does.
    let after = openObservationStore(dbPath)
    check after.captureEnabled
    check after.readExecutions().len == 0
    check after.readHosts().len == 1
    check after.readHostProfiles().len >= 1
    let orphanage = after.orphanReport()
    check orphanage.checked
    check orphanage.orphans == 0
    check status.totalGranted >= 1'u64
    check status.totalFinished >= 1'u64

  test "--no-write-stats leaves no store to sweep and no sweeper to do it":
    let root = scratchRoot("nostats")
    defer: removeDir(root)
    let socketPath = rendezvousDir(root) / "d.sock"
    let state = hostStateDir(root)
    let identityFile = state / "host-id"
    let defaultDb = state / "observations.sqlite3"

    putEnv("RUNQUOTA_SOCKET", socketPath)
    var daemon = startDaemon(socketPath,
      ["--host-identity-file", identityFile, "--no-write-stats"])
    var reported: JsonNode = nil
    try:
      var client = connectDefault()
      client.completeOneExecution("nostats")
      reported = client.retention()
      client.close()
    finally:
      daemon.stop()

    check reported != nil
    check reported["active"].getBool() == false
    check reported["sweeps_started"].getInt() == 0
    check not fileExists(defaultDb)

  test "a corrupt store leaves no sweeper and a daemon that still grants leases":
    # OS-4's third named failure, beside a missing daemon and a full disk.
    # A store that will not open has nothing to prune and no schema to
    # prune it with, so a sweeper started against one would spend the
    # daemon's whole life failing on a cadence — and the daemon itself
    # must go on granting leases, because an advisory subsystem may not
    # take out a machine's build capacity.
    let root = scratchRoot("corrupt")
    defer: removeDir(root)
    let socketPath = rendezvousDir(root) / "d.sock"
    let state = hostStateDir(root)
    let identityFile = state / "host-id"
    let dbPath = state / "observations.sqlite3"
    # A FILE THAT IS NOT A DATABASE, and big enough that `quick_check`
    # reads a header rather than an empty file — an empty path is the
    # "create it" case and is not this one.
    writeFile(dbPath, "SQLite format 3\x00" & repeat("\xa5", 4096))
    let untouched = readFile(dbPath)

    putEnv("RUNQUOTA_SOCKET", socketPath)
    var daemon = startDaemon(socketPath,
      ["--host-identity-file", identityFile,
       "--retention-sweep-interval-millis", "100"])
    var reported: JsonNode = nil
    var status = DaemonStatusMessage()
    try:
      # The store was refused, and refused as CORRUPT rather than as the
      # operator's off switch.
      check daemon.startupLines[1].contains("corrupt")
      check daemon.startupLines[1].contains("capture disabled")

      var client = connectDefault()
      # A whole execution, so "the daemon still serves" is a statement
      # about work completing rather than about a process being alive.
      client.completeOneExecution("corrupt")
      sleep(600)
      reported = client.retention()
      status = client.daemonStatus()
      client.close()
    finally:
      daemon.stop()

    check reported != nil
    # NO SWEEPER AT ALL — not one that runs and fails. Six cadences have
    # passed by now, so "started nothing" is a finding rather than an
    # absence of looking.
    check reported["active"].getBool() == false
    check reported["sweeps_started"].getInt() == 0
    check reported["failures"].getInt() == 0
    # AND THE FILE WAS LEFT EXACTLY AS IT WAS. A prune against a corrupt
    # store is the one operation that could make an unreadable file worse.
    check readFile(dbPath) == untouched
    # AND ADMISSION NEVER NOTICED.
    check status.totalGranted >= 1'u64
    check status.totalFinished >= 1'u64

  # -------------------------------------------------------------------------
  # DEGRADATION: the store stops accepting writes underneath the sweeper
  # -------------------------------------------------------------------------

  test "a store that turns unwritable mid-flight costs pruning and nothing else":
    # OS-4 AND OS-1 TOGETHER. Retention failing must degrade, never fail a
    # build: the daemon has to keep granting leases with nobody telling
    # the client anything went wrong.
    let root = scratchRoot("ro")
    let state = hostStateDir(root)
    let dbPath = state / "observations.sqlite3"
    defer:
      setFilePermissions(state, {fpUserRead, fpUserWrite, fpUserExec})
      for suffix in ["", "-wal", "-shm"]:
        if fileExists(dbPath & suffix):
          setFilePermissions(dbPath & suffix, {fpUserRead, fpUserWrite})
      removeDir(root)
    let socketPath = rendezvousDir(root) / "d.sock"
    let identityFile = state / "host-id"
    let hostId = mintIdentity(identityFile)
    seedStore(dbPath, hostId, 300, unixMillisNow() - 300)
    check executionCount(dbPath) == 300

    putEnv("RUNQUOTA_SOCKET", socketPath)
    var daemon = startDaemon(socketPath,
      ["--host-identity-file", identityFile,
       "--retention-max-executions", "50",
       "--retention-max-execution-age-millis", "-1",
       "--retention-sweep-interval-millis", "300"])
    var healthyRemoved = 0
    var failures = 0
    var moreFailures = 0
    var status = DaemonStatusMessage()
    var daemonStillUp = false
    try:
      var client = connectDefault()
      # HEALTHY FIRST, so what follows is a change of state rather than a
      # sweeper that never worked.
      for _ in 0 ..< 200:
        healthyRemoved = client.retention()["executions_removed"].getInt()
        if healthyRemoved >= 250: break
        sleep(50)
      check healthyRemoved == 250
      check client.retention()["failures"].getInt() == 0

      # THE STORE STOPS ACCEPTING WRITES.
      for suffix in ["", "-wal", "-shm"]:
        if fileExists(dbPath & suffix):
          setFilePermissions(dbPath & suffix, {fpUserRead})
      setFilePermissions(state, {fpUserRead, fpUserExec})

      # THE DAEMON'S LIVENESS IS CHECKED BEFORE EVERY REQUEST FROM HERE ON,
      # and that is not defensive tidying. A daemon that treated a failed
      # prune as fatal would exit somewhere inside these loops, and RQSP
      # has no deadline on a response it is waiting for — so the next
      # request would block forever and the assertions below would never be
      # reached. Checking first turns "the daemon died" from a HANG into
      # `daemonStillUp == false`, which is a failure a reader can diagnose.
      for _ in 0 ..< 400:
        if not daemon.process.running: break
        failures = client.retention()["failures"].getInt()
        if failures >= 1: break
        sleep(50)
      check daemon.process.running
      check failures >= 1

      # AND THE SWEEPER KEPT ITS CADENCE rather than dying on the first
      # failure — a daemon that silently stopped bounding its store is the
      # exact state this whole change exists to end.
      for _ in 0 ..< 400:
        if not daemon.process.running: break
        moreFailures = client.retention()["failures"].getInt()
        if moreFailures > failures: break
        sleep(50)
      check daemon.process.running
      check moreFailures > failures

      # THE CLIENT MUST NOT NOTICE. Every call below raises on any error
      # the daemon reports, so completing at all is the assertion — and
      # `status` stays at its zero default if they do not run, which is
      # what the totals below are checked against.
      #
      # GUARDED ON THE DAEMON BEING THERE, and that guard costs the
      # assertion nothing. Under an implementation that treats a failed
      # prune as fatal the two checks above have already gone red; issuing
      # another request would then block FOREVER, because RQSP puts no
      # deadline on a response it is waiting for. A red that hangs the
      # suite is a worse red than one that finishes, and an unguarded call
      # here turns this whole arm from a failure into a timeout.
      if daemon.process.running:
        client.completeOneExecution("degraded-one")
        client.completeOneExecution("degraded-two")
        status = client.daemonStatus()
      client.close()
      daemonStillUp = daemon.process.running
    finally:
      setFilePermissions(state, {fpUserRead, fpUserWrite, fpUserExec})
      for suffix in ["", "-wal", "-shm"]:
        if fileExists(dbPath & suffix):
          setFilePermissions(dbPath & suffix, {fpUserRead, fpUserWrite})
      daemon.stop()

    check daemonStillUp
    check status.totalGranted >= 2'u64
    check status.totalFinished >= 2'u64
    # AND THE ROWS RETENTION HAD ALREADY KEPT ARE STILL THERE AND STILL
    # RIGHT. A failing prune loses pruning; it must not damage the store.
    let after = openObservationStore(dbPath)
    check after.captureEnabled
    check after.readExecutions().len >= 50
    check after.orphanReport().orphans == 0
