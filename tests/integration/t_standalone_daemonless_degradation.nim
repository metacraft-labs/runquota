## M14 gate: standalone / daemonless degradation.
##
## With no daemon running, a build and a test run both SUCCEED and report
## no error. Observations are BUFFERED and then either flushed once at exit
## (long-lived client) or dropped (short-lived); ``capture_completeness``
## marks the window INCOMPLETE rather than complete; cross-invocation
## aggregation and learned-estimate serving are reported as UNAVAILABLE
## rather than faked. And -- the control that decides this gate -- NO
## per-execution database write occurs anywhere on the hot path in this
## mode.
##
## NO MOCKS. The build is a real `nim c` producing a real binary that is
## then executed and its output checked. The test run is a real compiled
## test binary, executed repeatedly by a real long-lived client process
## built from the shipped library. The daemon, where one appears, is the
## real `runquotad` binary from `build/bin` -- M10's record and M11's
## mutation both say the same thing, that daemon-side behaviour has to be
## exercised through the binary on disk, because a mutation that only
## recompiles the test reports green while the code under test never runs.
##
## ---------------------------------------------------------------------
## THE HARD PART, AND HOW IT IS MADE FALSIFIABLE
## ---------------------------------------------------------------------
##
## "No per-execution database write occurs on the hot path" is an
## assertion that NOTHING HAPPENED, and such an assertion passes trivially
## in a run where nothing would have written anyway. Asserting it against
## the shipped code and observing zero proves only that the code under
## test was reached at all -- if that.
##
## So this file does not observe a correct implementation. It CATCHES A
## VIOLATING ONE. Two things make that possible:
##
## 1. THE DETECTOR IS AT THE TOOL BOUNDARY, not at the source boundary.
##    Every database access this repository makes goes through the
##    `sqlite3` command-line tool (`runquota_observation_store/sqlite_cli`
##    says why), so a shim first on `PATH` that logs each invocation and
##    then execs the real tool counts database operations WHEREVER they
##    happen -- in the client, in a library it links, or in a helper it
##    spawns. A source-level rule would only see the first of those, and
##    the repository already has one (`t_observation_store_reader_boundary`).
##
## 2. THE VIOLATING IMPLEMENTATION IS REAL AND IS RUN. `runViolatorRole`
##    below is the obvious wrong answer to this milestone, written the way
##    somebody would really write it: no daemon, so open the store and
##    write the row yourself, per execution. It is driven through the
##    identical harness, and the first test in the suite requires the
##    detector to CATCH it. Without that arm, "the counter was zero" would
##    be a statement about the counter. This is M12's repair applied
##    again: prove the forbidden statement actually executed, rather than
##    that a guard exists.
##
## The violator also SUCCEEDS -- correct rows, no failures, faster than a
## round trip -- which is exactly why the milestone warns that the obvious
## implementation is the wrong one. What is wrong with it is not visible in
## its results; it is visible only in the counter.

import std/[json, options, os, osproc, streams, strutils, unittest]

from runquota_ipc import endpointDirectoryPermissions, endpointForPath,
  sendFrame
import runquota_client
import runquota_core
import runquota_observation_store
import runquota_process
import runquota_protocol

const
  HonestRoleEnv = "RUNQUOTA_M14_HONEST_ROLE"
  ViolatorRoleEnv = "RUNQUOTA_M14_VIOLATOR_ROLE"
  RoleRunsEnv = "RUNQUOTA_M14_RUNS"
  RoleCommandEnv = "RUNQUOTA_M14_CMD"
  RoleReportEnv = "RUNQUOTA_M14_REPORT"
  RoleStoreEnv = "RUNQUOTA_M14_STORE"
  RoleProbeLogEnv = "RUNQUOTA_M14_PROBE_LOG"
  RoleTool = "m14-standalone-runner"

# ---------------------------------------------------------------------------
# The two client roles, each a separate real process
# ---------------------------------------------------------------------------
#
# SEPARATE PROCESSES ON PURPOSE. A long-lived client's single flush happens
# WHEN IT EXITS, and "at exit" is not a state the test process can enter
# without ending itself. The roles are re-executions of this binary, the
# same shape `t_observation_socket_write_path` uses for its crash client.

proc runExecutions(command: string; runs: int):
    seq[tuple[startedAt, finishedAt: uint64; completion: ProcessCompletion]] =
  ## The work itself, identical in both roles so that the ONLY difference
  ## between them is what each does with the observation afterwards.
  for _ in 0 ..< runs:
    let startedAt = uint64(max(0'i64, unixMillisNow()))
    var child = launchProcess(commandSpec(@[command]))
    let completion = child.waitForCompletion()
    child.close()
    result.add((startedAt, uint64(max(0'i64, unixMillisNow())), completion))

proc writeRoleReport(path: string; lines: openArray[string]) =
  writeFile(path, lines.join("\n") & "\n")

proc runHonestRole(socketPath: string) =
  ## THE SHIPPED DEGRADATION. A long-lived client with no daemon: run the
  ## work, buffer each observation in memory, and make ONE best-effort
  ## flush over the socket on the way out.
  let runs = parseInt(getEnv(RoleRunsEnv))
  let command = getEnv(RoleCommandEnv)
  var capture = initStandaloneCapture(RoleTool, "0.1.0", "standalone",
    clLongLived)
  var failures = 0
  for execution in runExecutions(command, runs):
    if not execution.completion.exited or execution.completion.exitCode != 0:
      inc failures
    capture.record(deferredRecord(
      label = "m14-execution",
      commandStatsId = "m14-stats-key",
      startedAtUnixMillis = execution.startedAt,
      finishedAtUnixMillis = execution.finishedAt,
      outcome = leaseFinishSucceeded,
      exitStatus = uint32(max(execution.completion.exitCode, 0)),
      signal = 0'u32,
      peakRssBytes = execution.completion.peakResidentMemoryBytes,
      processCount = execution.completion.processCount))
  let bufferedBeforeExit = capture.bufferedCount
  let reason = capture.flushStandaloneAtExit(endpointForPath(socketPath))
  writeRoleReport(getEnv(RoleReportEnv), [
    "failures=" & $failures,
    "buffered_before_exit=" & $bufferedBeforeExit,
    "completeness=" & $capture.completeness(),
    "flush_reason=" & $reason,
    "flush_attempts=" & $capture.flushAttempts,
    "delivered=" & $capture.deliveredRecords,
    "dropped=" & $capture.droppedObservations,
    "buffered_after_exit=" & $capture.bufferedCount])

proc runViolatorRole() =
  ## THE FORBIDDEN IMPLEMENTATION, and the reason the arm above can be
  ## believed.
  ##
  ## This is what M14 says the obvious answer looks like: there is no
  ## daemon, so the client opens the store and writes the execution row
  ## itself, once per execution. Notice how reasonable it is. The rows are
  ## correct and complete, nothing is buffered and nothing is lost, and it
  ## needs no round trip. It is forbidden anyway, because it puts a
  ## database write on the per-execution path the whole design exists to
  ## keep clear.
  ##
  ## It is here to be CAUGHT. The first test in the suite runs it and
  ## requires the detector to see what it did; a detector that could not
  ## would make every "no write occurred" assertion below vacuous.
  let runs = parseInt(getEnv(RoleRunsEnv))
  let command = getEnv(RoleCommandEnv)
  let store = openObservationStore(getEnv(RoleStoreEnv))
  doAssert store.captureEnabled, store.report
  doAssert store.insertHost(HostRow(hostId: "m14-host",
    createdAtUnixMillis: unixMillisNow(), lastBootId: "m14-boot"))
  let runId = "m14-run"
  doAssert store.insertRun(RunRow(runId: runId, hostId: "m14-host",
    tool: RoleTool, toolVersion: "0.1.0", invocationKind: "direct",
    startedAtUnixMillis: unixMillisNow(), captureCompleteness: ccComplete))
  # THE COUNTER IS ZEROED HERE, AFTER SETUP AND BEFORE THE FIRST EXECUTION,
  # because the gate is about the HOT PATH and not about the store having
  # been used at all. Opening the store, migrating it and inserting the
  # `hosts` and `runs` rows costs nine `sqlite3` invocations on this host --
  # already more than ``Runs`` -- so a count taken over the whole role
  # process is satisfied by a violator that sets the store up once and never
  # writes per execution, which is the very implementation this arm has to
  # be able to tell apart. From here the count is exactly the per-execution
  # traffic.
  let probeLog = getEnv(RoleProbeLogEnv)
  if probeLog.len > 0:
    writeFile(probeLog, "")
  var index = 0
  for execution in runExecutions(command, runs):
    # THE PER-EXECUTION DATABASE WRITE. One `sqlite3` invocation, on the
    # path that just finished a piece of work.
    doAssert store.appendBatch([], [ExecutionRow(
      executionId: "m14-exec-" & $index,
      hostId: "m14-host",
      runId: runId,
      commandStatsId: "m14-stats-key",
      startedAtUnixMillis: int64(execution.startedAt),
      finishedAtUnixMillis: int64(execution.finishedAt),
      durationMillis: int64(execution.finishedAt - execution.startedAt),
      exitStatus: int64(max(execution.completion.exitCode, 0)),
      termination: tExited,
      attempt: 1,
      peakRssBytes: int64(execution.completion.peakResidentMemoryBytes),
      maxProcesses: int64(execution.completion.processCount),
      majorPageFaults: 0,
      captureCompleteness: ccComplete)])
    inc index
  writeRoleReport(getEnv(RoleReportEnv), ["failures=0", "wrote=" & $index])

when isMainModule:
  let honest = getEnv(HonestRoleEnv)
  if honest.len > 0:
    runHonestRole(honest)
    quit 0
  if getEnv(ViolatorRoleEnv).len > 0:
    runViolatorRole()
    quit 0

# ---------------------------------------------------------------------------
# Fixture plumbing
# ---------------------------------------------------------------------------

proc scratchRoot(name: string): string =
  # Short on purpose: Nim's `Sockaddr_un_path_length` is 92 on macOS and
  # `toSockAddr` refuses a path at or past it, so 91 characters is the
  # entire budget and a plain macOS `TMPDIR` is 49 of them on its own.
  result = getTempDir() / ("rq-m14-" & $getCurrentProcessId() & "-" & name)
  removeDir(result)
  createDir(result)

proc rendezvousDir(root: string): string =
  result = root / "ep"
  createDir(result)
  setFilePermissions(result, endpointDirectoryPermissions())

proc cliPath(): string = getCurrentDir() / "build" / "bin" / "runquota"
proc daemonPath(): string = getCurrentDir() / "build" / "bin" / "runquotad"
proc selfPath(): string = getAppFilename()

# ---------------------------------------------------------------------------
# The detector: every `sqlite3` invocation, counted at the tool boundary
# ---------------------------------------------------------------------------

type SqliteProbe = object
  shimDir: string
  logPath: string
  savedPath: string

proc installSqliteProbe(root: string): SqliteProbe =
  ## A shim first on `PATH` that records each invocation and then execs the
  ## real tool.
  ##
  ## AT THE TOOL BOUNDARY RATHER THAN AT THE SOURCE BOUNDARY, which is what
  ## makes it worth having. The store reaches SQLite by running `sqlite3`
  ## with `poUsePath`, so this sees a database access made by the client,
  ## by any library the client links, and by any helper the client spawns
  ## -- including one that does not exist yet. It also cannot be satisfied
  ## by a client that merely avoided the store's own entry points.
  let real = findExe("sqlite3")
  doAssert real.len > 0, "the probe needs a real sqlite3 to delegate to"
  result = SqliteProbe(
    shimDir: root / "shim",
    logPath: root / "sqlite-calls.log",
    savedPath: getEnv("PATH"))
  createDir(result.shimDir)
  writeFile(result.logPath, "")
  let shim = result.shimDir / "sqlite3"
  writeFile(shim, "#!/bin/sh\n" &
    "printf '%s\\n' \"$*\" >> " & quoteShell(result.logPath) & "\n" &
    "exec " & quoteShell(real) & " \"$@\"\n")
  setFilePermissions(shim, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc arm(probe: SqliteProbe) =
  ## Put the shim in front for everything launched from here on.
  putEnv("PATH", probe.shimDir & ":" & probe.savedPath)

proc disarm(probe: SqliteProbe) =
  putEnv("PATH", probe.savedPath)

proc calls(probe: SqliteProbe): int =
  for line in readFile(probe.logPath).splitLines():
    if line.len > 0:
      inc result

proc resetCalls(probe: SqliteProbe) =
  writeFile(probe.logPath, "")

proc databaseFilesUnder(root: string; probe: SqliteProbe): seq[string] =
  ## The second half of the detector, and it is not redundant.
  ##
  ## The counter above sees a database reached through the `sqlite3` tool,
  ## which is how this repository reaches one. A violating implementation
  ## that linked a SQLite library directly would leave the counter at zero
  ## and a database file on the disk, so the file system is checked too.
  ##
  ## THE PROBE'S OWN ARTEFACTS ARE EXCLUDED BY IDENTITY, NOT BY NAME, and
  ## the first version of this proc had no exclusion at all -- which made
  ## it useless in both directions at once. The shim must be called
  ## `sqlite3` for `PATH` interception to work, and the log is
  ## `sqlite-calls.log`, so a pattern matching "sqlite" matched the
  ## instrument: `== 0` was unsatisfiable in the honest arms, and `> 0` was
  ## satisfied in the violating arm whether or not a violation occurred.
  ##
  ## Excluding by the paths the probe reports, rather than by a name
  ## pattern, is what keeps this honest if the probe is ever renamed.
  for path in walkDirRec(root):
    if path == probe.logPath or path.isRelativeTo(probe.shimDir):
      continue
    let name = path.extractFilename
    if "sqlite" in name or name.endsWith(".db"):
      result.add(path)

# ---------------------------------------------------------------------------
# Real work for the client to run
# ---------------------------------------------------------------------------

proc compileFixture(root, name, source: string): string =
  ## A real Nim compile producing a real binary.
  result = root / name
  let sourcePath = root / (name & ".nim")
  writeFile(sourcePath, source)
  var args = @["c", "--hints:off", "--verbosity:0",
    "--nimcache:" & (root / ("nimcache-" & name)), "--out:" & result]
  # THE INNER COMPILE INHERITS THIS FILE'S BUILD MODE. M13b's record: a
  # test that builds something with a hardcoded argument list cannot reach
  # the configuration a mutation was reported red in, so the clause is
  # vacuous however honestly the mutation was run.
  when defined(release):
    args.add("-d:release")
  args.add(sourcePath)
  let output = execProcess(findExe("nim"), args = args, env = nil,
    options = {poStdErrToStdOut})
  if not fileExists(result):
    echo output
  doAssert fileExists(result), "fixture " & name & " did not compile"

const PassingTestSource = """
import std/unittest

suite "m14_fixture":
  test "a real test that really passes":
    check 2 + 2 == 4
"""

const HelloSource = "echo \"m14-build-ok\"\n"

proc runProcess(program: string; args: openArray[string]):
    tuple[exitCode: int; output: string] =
  let process = startProcess(program, args = @args,
    options = {poStdErrToStdOut})
  let output = process.outputStream.readAll()
  let code = process.waitForExit()
  process.close()
  (code, output)

proc roleReport(path: string): seq[tuple[key, value: string]] =
  for line in readFile(path).splitLines():
    if line.len == 0: continue
    let parts = line.split('=', 1)
    result.add((parts[0], parts[1]))

proc reportValue(report: seq[tuple[key, value: string]]; key: string): string =
  for entry in report:
    if entry.key == key:
      return entry.value
  ""

# ---------------------------------------------------------------------------
# The daemon, for the arms that need one
# ---------------------------------------------------------------------------

type DaemonHandle = object
  process: Process
  startupLines: seq[string]

proc startDaemon(socketPath, dbPath, identityFile: string): DaemonHandle =
  let process = startProcess(daemonPath(),
    args = ["--socket", socketPath, "--observation-db", dbPath,
            "--host-identity-file", identityFile],
    options = {poStdErrToStdOut})
  for _ in 0 ..< 400:
    if fileExists(socketPath): break
    sleep(25)
  var lines: seq[string] = @[]
  for _ in 0 ..< 3:
    lines.add(process.outputStream.readLine())
  DaemonHandle(process: process, startupLines: lines)

proc stop(handle: var DaemonHandle) =
  if handle.process.running:
    handle.process.terminate()
    discard handle.process.waitForExit(5000)
  handle.process.close()

proc waitForExecutionRows(path: string; atLeast: int): int =
  for _ in 0 ..< 100:
    let store = openObservationStore(path)
    if store.captureEnabled:
      result = store.readExecutions().len
      if result >= atLeast:
        return
    sleep(100)

proc observationsJson(socketPath: string): JsonNode =
  putEnv("RUNQUOTA_SOCKET", socketPath)
  var client = connectDefault()
  defer: client.close()
  parseJson(client.inspectionJson("observations"))["observations"]

# ---------------------------------------------------------------------------

const Runs = 4

suite "standalone_daemonless_degradation":

  # -------------------------------------------------------------------------
  # 1. The detector, proven against the implementation this gate forbids
  # -------------------------------------------------------------------------

  test "the detector catches a client that writes the store per execution":
    let root = scratchRoot("v")
    defer: removeDir(root)
    let probe = installSqliteProbe(root)
    defer: probe.disarm()
    let fixture = compileFixture(root, "passing", PassingTestSource)
    let report = root / "violator-report"
    let storePath = root / "violator.sqlite3"

    putEnv(ViolatorRoleEnv, "1")
    putEnv(RoleRunsEnv, $Runs)
    putEnv(RoleCommandEnv, fixture)
    putEnv(RoleReportEnv, report)
    putEnv(RoleStoreEnv, storePath)
    putEnv(RoleProbeLogEnv, probe.logPath)
    defer:
      delEnv(ViolatorRoleEnv)
      delEnv(RoleStoreEnv)
      delEnv(RoleProbeLogEnv)
    probe.arm()
    probe.resetCalls()
    let run = runProcess(selfPath(), [])
    probe.disarm()
    if run.exitCode != 0:
      echo run.output

    # THE DETECTOR IS READ BEFORE THIS TEST TOUCHES THE STORE ITSELF, and
    # the order is the whole of it. ``openObservationStore`` below CREATES
    # the database file, so a file-system check made after it is satisfied
    # by the harness's own verification whatever the violator did -- the
    # instrument answering its own positive control, which is the defect
    # this file exists to keep out of the arms below.
    let seen = probe.calls()
    let leftBehind = databaseFilesUnder(root, probe)
    # AND THE DETECTOR SEES IT. At least one database operation per
    # execution, on the path that had just finished a piece of work: the
    # role zeroed this counter after its one-time setup, so what is counted
    # here is the per-execution traffic and nothing else.
    check seen >= Runs
    check leftBehind.len > 0
    echo "  [probe] violating implementation: " & $seen &
      " sqlite3 invocations for " & $Runs & " executions"

    # IT WORKS, which is the trap this milestone is about. Correct rows,
    # no failures, no round trip -- and forbidden anyway.
    check run.exitCode == 0
    check reportValue(roleReport(report), "wrote") == $Runs
    let store = openObservationStore(storePath)
    check store.captureEnabled
    check store.readExecutions().len == Runs

  # -------------------------------------------------------------------------
  # 2. A build, with no daemon
  # -------------------------------------------------------------------------

  test "a build with no daemon succeeds, reports no error, and writes no database":
    let root = scratchRoot("b")
    defer: removeDir(root)
    let probe = installSqliteProbe(root)
    defer: probe.disarm()
    check fileExists(cliPath())

    # A rendezvous directory with NO DAEMON IN IT. Not a bogus path: the
    # directory is real and correctly permissioned, and the only thing
    # missing is the daemon -- which is the situation the milestone is
    # about, and a harsher one than an unreachable path, because every
    # earlier layer looks healthy.
    let socketPath = rendezvousDir(root) / "runquotad.sock"
    putEnv("RUNQUOTA_SOCKET", socketPath)
    check not fileExists(socketPath)

    let source = root / "hello.nim"
    writeFile(source, HelloSource)
    let binary = root / "hello.bin"

    probe.arm()
    probe.resetCalls()
    let build = runProcess(cliPath(), [
      "acquire", "--cpu", "1000", "--mem", "512MB",
      "--label", "m14-build", "--",
      findExe("nim"), "c", "--hints:off", "--verbosity:0",
      "--nimcache:" & (root / "nimcache"), "--out:" & binary, source])
    probe.disarm()
    if build.exitCode != 0:
      echo build.output

    # THE WORK SUCCEEDED. A real compiler produced a real binary that
    # really runs.
    check build.exitCode == 0
    check fileExists(binary)
    check execProcess(binary).strip() == "m14-build-ok"

    # AND NOTHING WAS REPORTED AS AN ERROR. §"Standalone mode": a missing
    # daemon MUST NOT be reported as an error.
    let lower = build.output.toLowerAscii()
    check "runquotaclienterror" notin lower
    check "connection refused" notin lower
    check "no such file" notin lower
    check "daemon" notin lower

    # AND NO DATABASE WAS WRITTEN, by the same detector that caught the
    # violator above.
    check probe.calls() == 0
    check databaseFilesUnder(root, probe).len == 0

  # -------------------------------------------------------------------------
  # 3. A test run, with no daemon
  # -------------------------------------------------------------------------

  test "a test run with no daemon succeeds, buffers, and writes no database":
    let root = scratchRoot("t")
    defer: removeDir(root)
    let probe = installSqliteProbe(root)
    defer: probe.disarm()
    let fixture = compileFixture(root, "passing", PassingTestSource)
    let report = root / "honest-report"
    let socketPath = rendezvousDir(root) / "runquotad.sock"

    putEnv(HonestRoleEnv, socketPath)
    putEnv(RoleRunsEnv, $Runs)
    putEnv(RoleCommandEnv, fixture)
    putEnv(RoleReportEnv, report)
    defer: delEnv(HonestRoleEnv)
    probe.arm()
    probe.resetCalls()
    let run = runProcess(selfPath(), [])
    probe.disarm()
    if run.exitCode != 0:
      echo run.output

    check run.exitCode == 0
    let values = roleReport(report)
    # The work ran, all of it, and none of it failed.
    check reportValue(values, "failures") == "0"
    check reportValue(values, "buffered_before_exit") == $Runs

    # BUFFERED, then a single attempt that found nothing, so DROPPED.
    check reportValue(values, "flush_reason") == "sfAttempted"
    check reportValue(values, "flush_attempts") == "1"
    check reportValue(values, "delivered") == "0"
    check reportValue(values, "dropped") == $Runs
    check reportValue(values, "buffered_after_exit") == "0"

    # INCOMPLETE, not complete.
    check reportValue(values, "completeness") == $ccDegraded
    check reportValue(values, "completeness") != $ccComplete

    check probe.calls() == 0
    check databaseFilesUnder(root, probe).len == 0

  # -------------------------------------------------------------------------
  # 4. The single flush, when a daemon happens to be there at exit
  # -------------------------------------------------------------------------

  test "the one exit flush lands, and its rows say the window was incomplete":
    let root = scratchRoot("f")
    defer: removeDir(root)
    let probe = installSqliteProbe(root)
    defer: probe.disarm()
    let fixture = compileFixture(root, "passing", PassingTestSource)
    let report = root / "honest-report"
    let socketPath = rendezvousDir(root) / "d.sock"
    let dbPath = root / "observations.sqlite3"
    check fileExists(daemonPath())

    # THE DAEMON STARTS WITHOUT THE SHIM ON `PATH`, deliberately. It is
    # the sanctioned writer and it really does write; counting its
    # `sqlite3` calls together with the client's would make the client's
    # zero unreadable.
    var daemon = startDaemon(socketPath, dbPath, root / "host-id")
    try:
      check daemon.startupLines[1].contains("capture enabled")

      putEnv(HonestRoleEnv, socketPath)
      putEnv(RoleRunsEnv, $Runs)
      putEnv(RoleCommandEnv, fixture)
      putEnv(RoleReportEnv, report)
      defer: delEnv(HonestRoleEnv)
      probe.arm()
      probe.resetCalls()
      let run = runProcess(selfPath(), [])
      probe.disarm()
      if run.exitCode != 0:
        echo run.output
      check run.exitCode == 0

      let values = roleReport(report)
      check reportValue(values, "flush_attempts") == "1"
      check reportValue(values, "delivered") == $Runs
      check reportValue(values, "dropped") == "0"

      # THE CLIENT STILL WROTE NO DATABASE. This is the arm where the
      # rows really do land, so it is the arm where a client that had
      # written them itself would be hardest to tell apart by looking at
      # the store.
      check probe.calls() == 0

      check waitForExecutionRows(dbPath, Runs) >= Runs
      let store = openObservationStore(dbPath)
      check store.captureEnabled

      var flushedRun: RunRow
      var found = false
      for row in store.readRuns():
        if row.tool == RoleTool:
          flushedRun = row
          found = true
      check found
      if found:
        # THE COLUMN THIS CLAUSE IS ABOUT.
        check flushedRun.captureCompleteness == ccDegraded
        check flushedRun.captureCompleteness != ccComplete
        check flushedRun.invocationKind == "standalone"
        check flushedRun.hostId.len > 0

        var flushed: seq[ExecutionRow] = @[]
        for row in store.readExecutions():
          if row.runId == flushedRun.runId:
            flushed.add(row)
        check flushed.len == Runs
        for row in flushed:
          # PER-ROW as well as per-run: a reader that filtered executions
          # without joining `runs` would otherwise see nothing saying the
          # window these came from was not whole.
          check row.captureCompleteness == ccDegraded
          # NO LEASE. Nothing admitted these executions, and a
          # synthesised id would be an invention every later join went
          # through.
          check row.leaseId.isNone
          check row.commandStatsId == "m14-stats-key"
          check row.durationMillis >= 0
    finally:
      daemon.stop()

  # -------------------------------------------------------------------------
  # 5. The verdict the daemon will not take on trust
  # -------------------------------------------------------------------------

  test "a flush claiming a complete window is refused, and a degraded one is not":
    # A FIXTURE A WELL-BEHAVED CLIENT CANNOT PRODUCE. `StandaloneCapture`
    # has no path that emits `ccComplete`, so this frame is hand-built and
    # written straight to the socket -- a real dishonest client, not a
    # stand-in for one.
    let root = scratchRoot("r")
    defer: removeDir(root)
    let socketPath = rendezvousDir(root) / "d.sock"
    let dbPath = root / "observations.sqlite3"
    var daemon = startDaemon(socketPath, dbPath, root / "host-id")
    try:
      check daemon.startupLines[1].contains("capture enabled")

      proc sendBatch(completeness: CaptureCompleteness; label: string) =
        putEnv("RUNQUOTA_SOCKET", socketPath)
        var client = connectDefault()
        defer: client.close()
        let msg = DeferredObservationsMessage(
          tool: label, toolVersion: "0.1.0", invocationKind: "standalone",
          completeness: completeness, droppedObservations: 2'u32,
          records: @[deferredRecord(
            label = label, commandStatsId = "m14-refusal-key",
            startedAtUnixMillis = uint64(max(0'i64, unixMillisNow())),
            finishedAtUnixMillis = uint64(max(0'i64, unixMillisNow())),
            outcome = leaseFinishSucceeded, exitStatus = 0'u32,
            signal = 0'u32, peakRssBytes = 1_000_000'u64,
            processCount = 1'u32)])
        client.connection.sendFrame(encodeFrame(rqDeferredObservations,
          FrameFlagRequest, 9_000'u64, encodeDeferredObservations(msg)))
        # One-way: nothing is acknowledged, so the send has to be given
        # time to be processed before the counters are read.
        sleep(300)

      let before = observationsJson(socketPath)
      check before["deferred_batches_accepted"].getInt == 0
      check before["deferred_batches_refused"].getInt == 0

      sendBatch(ccComplete, "m14-liar")
      let afterLie = observationsJson(socketPath)
      check afterLie["deferred_batches_refused"].getInt == 1
      check afterLie["deferred_batches_accepted"].getInt == 0
      check afterLie["deferred_executions_recorded"].getInt == 0

      # THE CONVERSE, without which the refusal above is satisfied by a
      # daemon that refuses every batch it is ever sent.
      sendBatch(ccDegraded, "m14-honest")
      let afterTruth = observationsJson(socketPath)
      check afterTruth["deferred_batches_accepted"].getInt == 1
      check afterTruth["deferred_batches_refused"].getInt == 1
      check afterTruth["deferred_executions_recorded"].getInt == 1

      check waitForExecutionRows(dbPath, 1) >= 1
      let store = openObservationStore(dbPath)
      var tools: seq[string] = @[]
      for row in store.readRuns():
        tools.add(row.tool)
      check "m14-honest" in tools
      check "m14-liar" notin tools
    finally:
      daemon.stop()

  # -------------------------------------------------------------------------
  # 6. Unavailable rather than faked
  # -------------------------------------------------------------------------

  test "with no daemon, aggregation and learned estimates are unavailable":
    let root = scratchRoot("s")
    defer: removeDir(root)
    let socketPath = rendezvousDir(root) / "runquotad.sock"
    putEnv("RUNQUOTA_SOCKET", socketPath)
    check not fileExists(socketPath)

    let query = runProcess(cliPath(), ["stats-table", "m14-unknown-key"])
    check query.exitCode == 0
    check "unavailable" in query.output
    # AND NO NUMBER FOR THE KEY. The failure this guards against is not a
    # crash, it is a plausible figure: a default, a previous run's value,
    # or the request's own reservation, offered in a column whose entire
    # purpose is to hold something somebody measured.
    check "m14-unknown-key: " notin query.output
    check "bytes over" notin query.output

    # A standalone run that ASKS for an estimate still succeeds, still
    # supplies none, and says so.
    let probeDir = root / "work"
    createDir(probeDir)
    putEnv("RUNQUOTA_REPORT_STANDALONE", "1")
    defer: delEnv("RUNQUOTA_REPORT_STANDALONE")
    let acquire = runProcess(cliPath(), [
      "acquire", "--cpu", "1000", "--mem", "128MB",
      "--stats-key", "m14-unknown-key", "--",
      "/bin/sh", "-c", "exit 0"])
    check acquire.exitCode == 0
    check "unavailable" in acquire.output
    check "degraded" in acquire.output

    # AND IT DROPPED RATHER THAN ATTEMPTING, asserted on THE SHIPPED
    # SHORT-LIVED CLIENT and not merely on a buffer constructed to be one.
    # "a short-lived client drops them" is half of the gate's flush clause,
    # and `runquota acquire` is the only short-lived standalone client in
    # the tree; declaring itself long-lived here would make every wrapped
    # command pay a connect attempt for a daemon that is not there, and
    # nothing else in this suite would notice.
    check "flush " & $sfShortLivedDrop in acquire.output
    check "flush " & $sfAttempted notin acquire.output

  test "the same command with a daemon does NOT report unavailable":
    # THE CONTROL. Without it, "unavailable" is what this command says
    # everywhere, and clause 6 is satisfied by a CLI that never answers.
    let root = scratchRoot("c")
    defer: removeDir(root)
    let socketPath = rendezvousDir(root) / "d.sock"
    var daemon = startDaemon(socketPath, root / "observations.sqlite3",
      root / "host-id")
    try:
      putEnv("RUNQUOTA_SOCKET", socketPath)
      let query = runProcess(cliPath(), ["stats-table", "m14-unknown-key"])
      check query.exitCode == 0
      check "unavailable" notin query.output
      check "m14-unknown-key" in query.output
    finally:
      daemon.stop()
