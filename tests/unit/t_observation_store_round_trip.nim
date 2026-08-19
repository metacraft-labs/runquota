## M9 gate, clause 1: write and read every spine table.
##
## No mocks. The store under test is a real SQLite database in a temporary
## directory, written and read through the same code the daemon uses, so
## the encoding, the constraints and the reader all have to agree for these
## assertions to hold.
##
## The values are deliberately hostile: text carrying the column separator,
## a newline, an apostrophe and non-ASCII bytes, plus every nullable column
## exercised in both its present and its absent form. A field-order slip in
## either the insert or the select shows up as a mismatched value rather
## than as a silently plausible row.

import std/[options, os, strutils, times, unittest]

import runquota_observation_store

proc scratchDir(name: string): string =
  result = getTempDir() / ("runquota-obs-" & name & "-" &
    $getCurrentProcessId() & "-" & $epochTime())
  removeDir(result)
  createDir(result)

const hostileText = "a|b'c\"d\ne\\f\tg é中 ~ x"

suite "observation_store_round_trip":
  test "every spine table round trips through a real database":
    let dir = scratchDir("roundtrip")
    defer: removeDir(dir)
    let store = openObservationStore(dir / "observations.sqlite")
    check store.status == ssOpen
    check store.captureEnabled
    check store.schemaVersion == spineSchemaVersion

    let host = HostRow(
      hostId: "host-" & hostileText,
      createdAtUnixMillis: 1_700_000_000_123'i64,
      lastBootId: "boot-" & hostileText)
    check store.insertHost(host)

    let profile = HostProfileRow(
      hostId: host.hostId,
      profileId: "profile-1",
      profileHash: "sha256:deadbeef",
      validFromUnixMillis: 1_700_000_000_000'i64,
      validToUnixMillis: none(int64),
      cpuModel: "Apple M-series " & hostileText,
      physicalCores: 12,
      logicalCores: 16,
      ramBytes: 68_719_476_736'i64,
      swapBytes: 0,
      diskClass: dcNvme,
      fsType: "apfs",
      arch: "arm64",
      os: "darwin",
      osVersion: "25.5",
      kernelVersion: "Darwin Kernel 25.5.0",
      virtualization: "bare-metal",
      cpuShareGroup: "host")
    check store.insertHostProfile(profile)

    let retiredProfile = HostProfileRow(
      hostId: host.hostId,
      profileId: "profile-0",
      profileHash: "sha256:0",
      validFromUnixMillis: 1_600_000_000_000'i64,
      validToUnixMillis: some(1_700_000_000_000'i64),
      cpuModel: "older",
      physicalCores: 8,
      logicalCores: 8,
      ramBytes: 34_359_738_368'i64,
      swapBytes: 1024,
      diskClass: dcSsd,
      fsType: "apfs",
      arch: "arm64",
      os: "darwin",
      osVersion: "24.0",
      kernelVersion: "Darwin Kernel 24.0.0",
      virtualization: "bare-metal",
      cpuShareGroup: "host")
    check store.insertHostProfile(retiredProfile)

    let fullRun = RunRow(
      runId: "run-full",
      hostId: host.hostId,
      tool: "repro-build",
      toolVersion: "0.1.0",
      invocationKind: "build",
      startedAtUnixMillis: 1_700_000_001_000'i64,
      finishedAtUnixMillis: some(1_700_000_009_000'i64),
      exitStatus: some(0'i64),
      workspaceId: some("workspace-" & hostileText),
      profile: some("release"),
      gitCommit: some("9d2c3522c0d5cae541f23282133ee4c905fec33e"),
      gitBranch: some("dev"),
      captureCompleteness: ccComplete,
      droppedObservations: 0)
    check store.insertRun(fullRun)

    let bareRun = RunRow(
      runId: "run-bare",
      hostId: host.hostId,
      tool: "ct-test-runner",
      toolVersion: "0.2.0",
      invocationKind: "test",
      startedAtUnixMillis: 1_700_000_002_000'i64,
      finishedAtUnixMillis: none(int64),
      exitStatus: none(int64),
      workspaceId: none(string),
      profile: none(string),
      gitCommit: none(string),
      gitBranch: none(string),
      captureCompleteness: ccDegraded,
      droppedObservations: 17)
    check store.insertRun(bareRun)

    let fullExecution = ExecutionRow(
      executionId: "exec-full",
      hostId: host.hostId,
      hostProfileId: some(profile.profileId),
      runId: fullRun.runId,
      commandStatsId: "stats-" & repeat("x", 32),
      leaseId: some(42'i64),
      startedAtUnixMillis: 1_700_000_003_000'i64,
      finishedAtUnixMillis: 1_700_000_004_500'i64,
      durationMillis: 1500,
      exitStatus: 0,
      termination: tExited,
      attempt: 1,
      retryOf: none(string),
      peakRssBytes: 1_073_741_824'i64,
      cpuUserMillis: some(900'i64),
      cpuSysMillis: some(120'i64),
      maxProcesses: 7,
      majorPageFaults: 3,
      ioReadBytes: some(4096'i64),
      ioWriteBytes: some(8192'i64),
      captureCompleteness: ccComplete,
      droppedObservations: 0)
    check store.insertExecution(fullExecution)

    let retryExecution = ExecutionRow(
      executionId: "exec-retry",
      hostId: host.hostId,
      hostProfileId: none(string),
      runId: bareRun.runId,
      commandStatsId: "",
      leaseId: none(int64),
      startedAtUnixMillis: 1_700_000_005_000'i64,
      finishedAtUnixMillis: 1_700_000_005_050'i64,
      durationMillis: 50,
      exitStatus: 137,
      termination: tOomKilled,
      attempt: 2,
      retryOf: some(fullExecution.executionId),
      peakRssBytes: 2_147_483_648'i64,
      cpuUserMillis: none(int64),
      cpuSysMillis: none(int64),
      maxProcesses: 1,
      majorPageFaults: 0,
      ioReadBytes: none(int64),
      ioWriteBytes: none(int64),
      captureCompleteness: ccSampled,
      droppedObservations: 5)
    check store.insertExecution(retryExecution)

    let sample = AmbientSampleRow(
      hostId: host.hostId,
      sampledAtUnixMillis: 1_700_000_003_500'i64,
      cpuBusyPct: 87.25,
      memAvailableBytes: 8_589_934_592'i64,
      swapInRate: 0.1,
      ioQueueDepth: 2.5,
      loadAvg1m: 19.375,
      selfCpuPct: 61.5,
      selfRssBytes: 3_221_225_472'i64,
      foreignCpuPct: 25.75,
      foreignRssBytes: 1_073_741_824'i64)
    check store.insertAmbientSample(sample)

    let extension = ExtensionRegistryRow(
      extensionId: "test_execution",
      schemaVersion: 1,
      owner: "runquota",
      tableName: "ext_test_execution",
      registeredAtUnixMillis: 1_700_000_000_500'i64)
    check store.registerExtension(extension)

    # ---- read every table back -------------------------------------------
    let hosts = store.readHosts()
    check hosts.len == 1
    check hosts[0] == host

    let profiles = store.readHostProfiles()
    check profiles.len == 2
    check profiles[0] == retiredProfile
    check profiles[1] == profile
    check profiles[0].validToUnixMillis.isSome
    check profiles[1].validToUnixMillis.isNone

    let runs = store.readRuns()
    check runs.len == 2
    check runs[0] == bareRun
    check runs[1] == fullRun
    check runs[0].gitBranch.isNone
    check runs[1].gitBranch == some("dev")
    check runs[0].droppedObservations == 17

    let executions = store.readExecutions()
    check executions.len == 2
    check executions[0] == fullExecution
    check executions[1] == retryExecution
    check executions[1].retryOf == some("exec-full")
    check executions[1].cpuUserMillis.isNone

    let samples = store.readAmbientSamples()
    check samples.len == 1
    check samples[0] == sample

    let extensions = store.readExtensionRegistry()
    check extensions.len == 1
    check extensions[0] == extension

  test "a reopened store reads what an earlier process wrote":
    let dir = scratchDir("reopen")
    defer: removeDir(dir)
    let path = dir / "observations.sqlite"
    block:
      let store = openObservationStore(path)
      check store.insertHost(HostRow(hostId: "h1",
        createdAtUnixMillis: 1, lastBootId: "b1"))
    let reopened = openObservationStore(path)
    check reopened.status == ssOpen
    check reopened.schemaVersion == spineSchemaVersion
    check reopened.readHosts().len == 1
    check reopened.readHosts()[0].hostId == "h1"

  test "the schema refuses rows the specification forbids":
    let dir = scratchDir("constraints")
    defer: removeDir(dir)
    let store = openObservationStore(dir / "observations.sqlite")
    check store.insertHost(HostRow(hostId: "h1", createdAtUnixMillis: 1,
      lastBootId: "b1"))
    check store.insertRun(RunRow(runId: "r1", hostId: "h1", tool: "t",
      toolVersion: "v", invocationKind: "build", startedAtUnixMillis: 1,
      captureCompleteness: ccComplete))

    proc execution(id: string): ExecutionRow =
      ExecutionRow(executionId: id, hostId: "h1", runId: "r1",
        commandStatsId: "c", startedAtUnixMillis: 1,
        finishedAtUnixMillis: 2, durationMillis: 1, exitStatus: 0,
        termination: tExited, attempt: 1, peakRssBytes: 0, maxProcesses: 1,
        majorPageFaults: 0, captureCompleteness: ccComplete)

    # An execution whose run does not exist is refused: the spine is
    # foreign-keyed, so history cannot lose its parent invocation.
    var orphan = execution("orphan")
    orphan.runId = "missing-run"
    check not store.insertExecution(orphan)
    check "constraint" in store.lastError.toLowerAscii

    # `command_stats_id` is bounded at 64 bytes by the protocol.
    var oversized = execution("oversized")
    oversized.commandStatsId = repeat("x", 65)
    check not store.insertExecution(oversized)

    check store.insertExecution(execution("ok"))
    var duplicate = execution("ok")
    duplicate.exitStatus = 1
    check not store.insertExecution(duplicate)

    # M11 must clamp the foreign residual at zero. The schema makes a
    # negative residual unstorable, so a clamp regression cannot be
    # persisted even if it reaches the writer.
    check not store.insertAmbientSample(AmbientSampleRow(hostId: "h1",
      sampledAtUnixMillis: 1, cpuBusyPct: 10, memAvailableBytes: 1,
      swapInRate: 0, ioQueueDepth: 0, loadAvg1m: 0, selfCpuPct: 50,
      selfRssBytes: 1, foreignCpuPct: -1.0, foreignRssBytes: 1))

    # An extension table must be named after its extension.
    check not store.registerExtension(ExtensionRegistryRow(
      extensionId: "repro_action", schemaVersion: 1, owner: "reprobuild",
      tableName: "actions", registeredAtUnixMillis: 1))
    check store.registerExtension(ExtensionRegistryRow(
      extensionId: "repro_action", schemaVersion: 1, owner: "reprobuild",
      tableName: "ext_repro_action", registeredAtUnixMillis: 1))

    # None of the above turned capture off: a rejected row is the caller's
    # problem, not a broken store.
    check store.captureEnabled
    check store.readExecutions().len == 1
