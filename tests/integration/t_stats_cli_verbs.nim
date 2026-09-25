## `runquota stats` end to end: the real CLI binary, the real daemon, the
## real socket, the real SQLite store.
##
## NO MOCKS, AND NOTHING SUBSTITUTED. Every arm starts `build/bin/runquotad`
## as a process, and every answer asserted on was produced by running
## `build/bin/runquota` as a process and reading its stdout, its stderr and
## its EXIT STATUS. Nothing here calls the rendering functions in-process:
## the point of this surface is what an operator or an agent sees at a
## terminal, and a test that called the renderer directly would pass with
## the verb unwired from `runThinApp`.
##
## WHY ROWS ARE ALSO WRITTEN DIRECTLY, the same justification
## `t_observation_query_interface` gives, because it is the same fixture
## problem. Three states under test are states no well-behaved client can
## produce: a store holding two hardware profiles (one machine has one
## current profile), a row owned by another uid (one test process runs
## under one uid), and a row whose termination is `oom_killed` and whose
## capture grade is `degraded` (this test is not going to arrange an OOM
## kill). Those rows are inserted through the store library — the same
## insert path the daemon uses — and are the FIXTURE. Everything ASSERTED
## came back out of the CLI process.
##
## TWO CLAUSES THIS FILE EXISTS FOR:
##
## 1. An empty result must never look like a healthy one. Written as a
##    DISCRIMINATION rather than an assertion about one run — the same
##    command is run against a capture-off daemon, an empty one and a
##    populated one, and the three must differ in status, in text and in
##    exit code. A gate that only checked the capture-off arm would pass
##    against a CLI that printed "capture-off" unconditionally.
##
## 2. `stats export` writes NOTHING but JSON to stdout, on every path
##    including the failing ones. That is what makes `stats export | jq`
##    safe to write, and the error paths are precisely the ones a caller
##    has not tried yet.

import std/[json, options, os, osproc, streams, strutils, unittest]


from runquota_ipc import endpointDirectoryPermissions
import runquota_client
import runquota_core
from runquota_ipc import resolveOwnerName
import runquota_observation_store
import runquota_protocol
import daemon_binary
import daemon_endpoint
import owner_uid
from runquota_core/child_process import runCapturedProcess
import scratch_root

const
  SeedKey = "cli/seed-suite"
  OtherKey = "cli/owned-by-someone-else"
  OomKey = "cli/oom-victim"
  NeverKey = "cli/never-recorded"
  OtherUid = 4043'i64
  OtherOwnerName = "fixture-other-owner"
  MiB = 1024'u64 * 1024'u64

# ---------------------------------------------------------------------------
# Fixture plumbing
# ---------------------------------------------------------------------------

proc scratchRoot(name: string): string =
  result = getTempDir() / ("rq-cli-" & $getCurrentProcessId() & "-" & name)
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

proc startDaemon(socketPath: string; extraArgs: openArray[string]):
    DaemonHandle =
  var args = @["--socket", socketPath]
  for arg in extraArgs:
    args.add(arg)
  let process = startProcess(daemonPath(), args = args,
    options = {poStdErrToStdOut})
  for _ in 0 ..< 400:
    if endpointIsBound(socketPath): break
    sleep(25)
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

type CliResult = object
  outText: string
  errText: string
  code: int

proc runCli(args: varargs[string]): CliResult =
  ## The SHIPPED binary, as a process, with stdout and stderr kept APART.
  ## Keeping them apart is the assertion, not a convenience: `stats
  ## export` promises stdout is nothing but JSON, and a test that merged
  ## the streams could not tell a violation from a pass.
  var argv: seq[string] = @[]
  for arg in args:
    argv.add(arg)
  #
  # `runCapturedProcess` keeps them apart itself; this used to redirect them
  # into two files through `/bin/sh -c`, which is not a path on Windows.
  let captured = runCapturedProcess(cliPath(), argv, options = {})
  doAssert captured.failure.len == 0, captured.failure
  result = CliResult(outText: captured.output, errText: captured.error,
    code: captured.exitCode)

proc completeOneExecution(client: var RunQuotaClient; statsKey: string;
                          sleepMillis: int) =
  var session = client.registerSession("cli-stats", "0.1.0")
  var request = resourceRequest(statsKey, milliCpu(1000), bytes(64'u64 * MiB))
  request.commandStatsId = statsKey
  var lease = session.requestLease(request)
  doAssert lease.active
  lease.markStarting()
  lease.markRunning(childProcessId = uint64(getCurrentProcessId()))
  sleep(sleepMillis)
  lease.finish(outcome = succeeded(), peakMemoryBytes = 5_000_000'u64,
    processCount = 1'u32, majorPageFaults = 0'u64)
  lease.release()
  session.closeSession()

proc waitForExecutions(path: string; atLeast: int): seq[ExecutionRow] =
  ## A QUERY FIRST, THEN THE FILE. The daemon flushes its observation
  ## writer before answering any stats query, so asking once turns "wait
  ## for a background drain that ticks every 25ms" into "wait for
  ## nothing". Polling the file alone loses that race on a loaded host --
  ## observed returning 1 of 3 rows after a full ten-second budget at load
  ## 114, which reports a fixture's timing as the product's failure.
  for _ in 0 ..< 200:
    discard runCli("stats", "capture", "--json")
    let store = openObservationStore(path)
    if store.captureEnabled:
      result = store.readExecutions()
      if result.len >= atLeast:
        return
    sleep(50)

type SyntheticRow = object
  suffix: string
  statsKey: string
  profileId: string
  ownerUid: Option[int64]
  durationMillis: int64
  termination: Termination
  exitStatus: int64
  completeness: CaptureCompleteness

proc insertSynthetic(store: ObservationStore; hostId, runId: string;
                     rows: openArray[SyntheticRow]) =
  for index, row in rows:
    doAssert store.insertExecution(ExecutionRow(
      executionId: "exec-cli-" & row.suffix & "-" & $index,
      hostId: hostId,
      hostProfileId: some(row.profileId),
      runId: runId,
      commandStatsId: row.statsKey,
      leaseId: none(int64),
      startedAtUnixMillis: 30_000 + int64(index),
      finishedAtUnixMillis: 30_000 + int64(index) + row.durationMillis,
      durationMillis: row.durationMillis,
      exitStatus: row.exitStatus,
      termination: row.termination,
      attempt: 1,
      retryOf: none(string),
      peakRssBytes: 1_000 + int64(index),
      cpuUserMillis: none(int64),
      cpuSysMillis: none(int64),
      maxProcesses: 1,
      majorPageFaults: 0,
      ioReadBytes: none(int64),
      ioWriteBytes: none(int64),
      captureCompleteness: row.completeness,
      droppedObservations: 0,
      ownerUid: row.ownerUid)), store.lastError

proc syntheticProfile(hostId, profileId: string): HostProfileRow =
  let hardware = HardwareProfile(
    cpuModel: "CLI Retired Builder 64", physicalCores: 64,
    logicalCores: 64, ramBytes: 256_000_000_000'i64, swapBytes: 0,
    diskClass: dcNvme, fsType: "ext4", arch: "x86_64", os: "linux",
    osVersion: "6.0", kernelVersion: "6.0", virtualization: "none",
    cpuShareGroup: "")
  HostProfileRow(
    hostId: hostId, profileId: profileId,
    profileHash: profileHash(hardware),
    validFromUnixMillis: 1, validToUnixMillis: some(2'i64),
    cpuModel: hardware.cpuModel, physicalCores: hardware.physicalCores,
    logicalCores: hardware.logicalCores, ramBytes: hardware.ramBytes,
    swapBytes: hardware.swapBytes, diskClass: hardware.diskClass,
    fsType: hardware.fsType, arch: hardware.arch, os: hardware.os,
    osVersion: hardware.osVersion, kernelVersion: hardware.kernelVersion,
    virtualization: hardware.virtualization,
    cpuShareGroup: hardware.cpuShareGroup)

proc ndjson(answer: CliResult): seq[JsonNode] =
  for line in answer.outText.splitLines():
    if line.len > 0:
      result.add(parseJson(line))

suite "stats_cli_verbs":

  # -------------------------------------------------------------------------
  # CLAUSE 1: capture-off, empty and populated are three different answers.
  # -------------------------------------------------------------------------

  test "capture-off, empty and populated are three different answers":
    let offRoot = scratchRoot("off")
    let onRoot = scratchRoot("on")
    defer: removeScratchRoot(offRoot)
    defer: removeScratchRoot(onRoot)
    check fileExists(cliPath())

    # ---- capture OFF -----------------------------------------------------
    let offSocket = rendezvousDir(offRoot) / "d.sock"
    let offState = hostStateDir(offRoot)
    putEnv("RUNQUOTA_SOCKET", offSocket)
    var offDaemon = startDaemon(offSocket,
      ["--host-identity-file", offState / "host-id",
       "--ambient-sample-interval-millis", "0",
       "--no-write-stats"])
    var offExport, offTop, offCapture: CliResult
    try:
      offExport = runCli("stats", "export")
      offTop = runCli("stats", "top", "--json")
      offCapture = runCli("stats", "capture", "--json")
    finally:
      offDaemon.stop()

    # NOT AN EMPTY TABLE AND NOT A ZERO. stdout is empty, so a `jq` pipe
    # sees nothing -- and the EXIT CODE is what stops that nothing from
    # being read as good news.
    check offExport.code == 4
    check offExport.outText.len == 0
    check "capture: OFF" in offExport.errText
    check "capture-off" in offExport.errText
    check "NOT an empty result" in offExport.errText
    check offTop.code == 4
    check offCapture.code == 4
    let offTopJson = parseJson(offTop.outText)
    check offTopJson["status"].getStr == "capture-off"
    check offTopJson["capture_enabled"].getBool == false
    check offTopJson["exit_code"].getInt == 4

    # ---- capture ON, store empty ----------------------------------------
    let onSocket = rendezvousDir(onRoot) / "d.sock"
    let onState = hostStateDir(onRoot)
    let dbPath = onState / "observations.sqlite3"
    putEnv("RUNQUOTA_SOCKET", onSocket)
    var onDaemon = startDaemon(onSocket,
      ["--host-identity-file", onState / "host-id",
       "--ambient-sample-interval-millis", "0"])
    try:
      let emptyExport = runCli("stats", "export")
      let emptyCapture = runCli("stats", "capture", "--json")
      check emptyCapture.code == 0
      check parseJson(emptyCapture.outText)["capture_enabled"].getBool

      # CAPTURE IS ON HERE, and that is the whole difference. The store is
      # as empty as the one above and the answer is a different one.
      check emptyExport.code == 3
      check emptyExport.outText.len == 0
      check "capture: ON" in emptyExport.errText
      check "no-data" in emptyExport.errText

      # NON-VACUITY FOR THE CAPTURE-OFF ARM: the same command answers
      # differently here, so that assertion discriminates.
      check emptyExport.code != offExport.code
      check emptyExport.errText != offExport.errText

      # ---- capture ON, populated ----------------------------------------
      var client = connectDefault()
      client.completeOneExecution(SeedKey, 30)
      client.completeOneExecution(SeedKey, 15)
      check waitForExecutions(dbPath, 2).len >= 2
      client.close()

      let liveExport = runCli("stats", "export")
      check liveExport.code == 0
      let rows = liveExport.ndjson
      check rows.len >= 2
      check "status: ok" in liveExport.errText

      # THREE STATES, THREE EXIT CODES, in one assertion so that a CLI
      # which collapsed any two of them fails here.
      check offExport.code == 4
      check emptyExport.code == 3
      check liveExport.code == 0
    finally:
      onDaemon.stop()

  # -------------------------------------------------------------------------
  # CLAUSE 2: stdout is JSON and nothing else, on every path.
  # -------------------------------------------------------------------------

  test "stats export writes only JSON to stdout, including when it fails":
    let root = scratchRoot("stream")
    defer: removeScratchRoot(root)
    let socketPath = rendezvousDir(root) / "d.sock"
    let state = hostStateDir(root)
    let dbPath = state / "observations.sqlite3"
    putEnv("RUNQUOTA_SOCKET", socketPath)
    var daemon = startDaemon(socketPath,
      ["--host-identity-file", state / "host-id",
       "--ambient-sample-interval-millis", "0"])
    try:
      var client = connectDefault()
      client.completeOneExecution(SeedKey, 10)
      check waitForExecutions(dbPath, 1).len >= 1
      client.close()

      # Every row parses as JSON on its own -- which is what NDJSON means
      # and what makes `| jq` work without buffering.
      let good = runCli("stats", "export")
      check good.code == 0
      check good.ndjson.len >= 1

      # A REFUSED INVOCATION PUTS NOTHING ON STDOUT. The usage text is
      # help, and help in the data stream is corruption.
      let refused = runCli("stats", "export", "--limit", "999999")
      check refused.code == 2
      check refused.outText.len == 0
      check refused.errText.len > 0

      let misspelt = runCli("stats", "exprot")
      check misspelt.code == 2
      check misspelt.outText.len == 0

      # An unknown key is a status, not a row, and still no stdout.
      let absent = runCli("stats", "export", NeverKey)
      check absent.code == 3
      check absent.outText.len == 0
      check "unknown-key" in absent.errText
    finally:
      daemon.stop()

  # -------------------------------------------------------------------------
  # Scope, hardware and the facts a row carries.
  # -------------------------------------------------------------------------

  test "an exported row is self-describing and scoped to the caller":
    let root = scratchRoot("rows")
    defer: removeScratchRoot(root)
    let socketPath = rendezvousDir(root) / "d.sock"
    let state = hostStateDir(root)
    let dbPath = state / "observations.sqlite3"
    putEnv("RUNQUOTA_SOCKET", socketPath)
    var daemon = startDaemon(socketPath,
      ["--host-identity-file", state / "host-id",
       "--ambient-sample-interval-millis", "0"])
    try:
      var client = connectDefault()
      client.completeOneExecution(SeedKey, 20)
      let realRows = waitForExecutions(dbPath, 1)
      check realRows.len >= 1
      let hostId = realRows[0].hostId
      let liveProfileId = realRows[0].hostProfileId.get
      let runId = realRows[0].runId
      client.close()

      let store = openObservationStore(dbPath)
      check store.captureEnabled
      let retiredProfileId = "profile-cli-retired"
      check store.insertHostProfile(syntheticProfile(hostId,
        retiredProfileId))
      # The other owner is a fixture and needs its `users` row before an
      # execution may name it (schema version 6); the caller's was recorded
      # by the daemon from the connection above.
      check store.recordUser(OtherUid, pkUid, $OtherUid,
        some(OtherOwnerName))
      store.insertSynthetic(hostId, runId, [
        SyntheticRow(suffix: "other", statsKey: OtherKey,
          profileId: liveProfileId, ownerUid: some(OtherUid),
          durationMillis: 500, termination: tExited, exitStatus: 0,
          completeness: ccComplete),
        SyntheticRow(suffix: "oom", statsKey: OomKey,
          profileId: liveProfileId, ownerUid: some(callerOwnerUid()),
          durationMillis: 700, termination: tOomKilled, exitStatus: 0,
          completeness: ccDegraded),
        SyntheticRow(suffix: "retired", statsKey: SeedKey,
          profileId: retiredProfileId, ownerUid: some(callerOwnerUid()),
          durationMillis: 100, termination: tExited, exitStatus: 0,
          completeness: ccComplete)])

      # SELF-DESCRIBING: the row carries the opaque stats key AND the
      # context that explains it. A caller cannot join to `runs` or
      # `host_profiles` themselves -- the daemon is the only reader -- so
      # a row that carried only ids would be unusable.
      let oom = runCli("stats", "export", OomKey).ndjson
      check oom.len == 1
      let row = oom[0]
      check row["command_stats_id"].getStr == OomKey
      check row["run_tool"].getStr.len > 0
      check row["cpu_model"].getStr.len > 0
      check row["logical_cores"].getInt > 0
      check row["os"].getStr.len > 0
      check row["host_profile_id"].getStr == liveProfileId

      # THE TERMINATION IS THE ANSWER TO "WAS THAT AN OOM", and it is not
      # inferable from the exit status, which is 0 on this row.
      check row["termination"].getStr == "oom_killed"
      check row["exit_status"].getInt == 0
      check row["capture_completeness"].getStr == "degraded"

      # NUMBERS ARE NUMBERS. If these came back as JSON strings every jq
      # comparison against them would silently be a string comparison.
      check row["duration_millis"].kind == JInt
      check row["peak_rss_bytes"].kind == JInt

      # THE UNWRITTEN COLUMNS ARE PRESENT AND NULL -- not absent, which
      # would send a reader looking for a flag that produces them, and not
      # zero, which would be a measurement nobody took.
      check row["cpu_user_millis"].kind == JNull
      check row["cpu_sys_millis"].kind == JNull
      check row["io_read_bytes"].kind == JNull
      check row["io_write_bytes"].kind == JNull

      # WHO THE OWNER IS travels with the row, from `users`: the caller's
      # name is whatever the daemon resolved for the principal the peer
      # credentials named -- the login name, or the Windows DOMAIN and
      # account -- and NULL, not absent, where the account does not resolve.
      check row["owner_uid"].getInt == int(callerOwnerUid())
      check row.hasKey("owner_name")
      let expectedName = resolveOwnerName(callerOwnerPrincipal())
      if expectedName.isSome:
        check row["owner_name"].kind == JString
        check row["owner_name"].getStr == expectedName.get
      else:
        check row["owner_name"].kind == JNull

      # SCOPED TO THE CALLER, from peer credentials. The other uid's row
      # really is in the store, which is what makes its absence a
      # statement about scoping rather than about an empty table.
      let mine = runCli("stats", "export", OtherKey)
      check mine.code == 3
      check mine.outText.len == 0
      check "no-rows-in-scope" in mine.errText
      let widened = runCli("stats", "export", OtherKey, "--all-users")
      check widened.code == 0
      check widened.ndjson.len == 1
      check widened.ndjson[0]["owner_uid"].getInt == int(OtherUid)
      check widened.ndjson[0]["owner_name"].getStr == OtherOwnerName

      # PROFILE SCOPING: the retired profile's row is reachable only by
      # widening, and when it comes back it names its own hardware.
      let narrow = runCli("stats", "export", SeedKey)
      var narrowProfiles: seq[string] = @[]
      for entry in narrow.ndjson:
        if entry["host_profile_id"].getStr notin narrowProfiles:
          narrowProfiles.add(entry["host_profile_id"].getStr)
      check narrowProfiles == @[liveProfileId]
      let wide = runCli("stats", "export", SeedKey, "--all-profiles")
      var wideProfiles: seq[string] = @[]
      for entry in wide.ndjson:
        if entry["host_profile_id"].getStr notin wideProfiles:
          wideProfiles.add(entry["host_profile_id"].getStr)
      check retiredProfileId in wideProfiles
      check liveProfileId in wideProfiles
      # And the hardware travels with the row, so the two are visibly not
      # the same measurement.
      for entry in wide.ndjson:
        if entry["host_profile_id"].getStr == retiredProfileId:
          check entry["cpu_model"].getStr == "CLI Retired Builder 64"
    finally:
      daemon.stop()

  # -------------------------------------------------------------------------
  # `top` still ranks within a profile and never across one.
  # -------------------------------------------------------------------------

  test "top ranks within a hardware profile and never pools two":
    let root = scratchRoot("top")
    defer: removeScratchRoot(root)
    let socketPath = rendezvousDir(root) / "d.sock"
    let state = hostStateDir(root)
    let dbPath = state / "observations.sqlite3"
    putEnv("RUNQUOTA_SOCKET", socketPath)
    var daemon = startDaemon(socketPath,
      ["--host-identity-file", state / "host-id",
       "--ambient-sample-interval-millis", "0"])
    try:
      var client = connectDefault()
      client.completeOneExecution(SeedKey, 20)
      let realRows = waitForExecutions(dbPath, 1)
      check realRows.len >= 1
      let hostId = realRows[0].hostId
      let liveProfileId = realRows[0].hostProfileId.get
      let runId = realRows[0].runId
      client.close()

      let store = openObservationStore(dbPath)
      let retiredProfileId = "profile-cli-retired"
      check store.insertHostProfile(syntheticProfile(hostId,
        retiredProfileId))
      store.insertSynthetic(hostId, runId, [
        SyntheticRow(suffix: "r1", statsKey: SeedKey,
          profileId: retiredProfileId, ownerUid: some(callerOwnerUid()),
          durationMillis: 100, termination: tExited, exitStatus: 0,
          completeness: ccComplete),
        SyntheticRow(suffix: "r2", statsKey: SeedKey,
          profileId: retiredProfileId, ownerUid: some(callerOwnerUid()),
          durationMillis: 120, termination: tExited, exitStatus: 0,
          completeness: ccComplete)])

      let wide = runCli("stats", "top", SeedKey, "--all-profiles", "--json")
      check wide.code == 0
      let parsed = parseJson(wide.outText)
      # TWO ANSWERS, NOT ONE BIGGER ONE, nested under the profile they
      # were measured on so pooling is something the reader has to write.
      check parsed["profiles"].len == 2
      var total = 0
      for group in parsed["profiles"]:
        for entry in group["rankings"]:
          # The blended answer -- 1 live + 2 retired for this key --
          # appears in NEITHER group.
          check entry["sample_count"].getInt != 3
          total += entry["sample_count"].getInt
      check total == 3
      check "never combined" in wide.outText
    finally:
      daemon.stop()
