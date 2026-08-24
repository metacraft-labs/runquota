## M15 gate, the retention half: age and row-count bounds are enforced,
## pruning cascades to extension rows, and ``hosts`` / ``host_profiles``
## are never orphaned.
##
## The fourth retention clause — pruning is crash-safe under a KILLED
## process — is ``tests/integration/t_observation_store_retention_crash.nim``,
## because it needs a real signal delivered to a real process group and
## nothing in-process can stand in for that. M12's atomicity check used an
## induced constraint failure and its own record says plainly that this is
## atomicity rather than crash recovery; the gate here asks for the other
## thing.
##
## NO MOCKS. Real SQLite files on the real filesystem, written and read by
## the same code the daemon uses. The one fixture a well-behaved client
## cannot produce is the manufactured ORPHAN, and it is manufactured on
## purpose: the "never orphaned" clause is a claim about a state the
## library's own foreign keys prevent, so a detector for it is untestable
## until somebody creates that state deliberately. It is created with
## ``pragma foreign_keys = off``, which is exactly how a real one would
## arrive — a store edited past this library, or restored from a copy taken
## by something that did not care.
##
## THE TRAP THIS FILE IS WRITTEN AROUND. "Retention does not delete
## hardware context" is trivially true of an implementation that deletes
## nothing, and equally true of one that never had a reason to. What makes
## it a real claim is that the fixture below gives it a reason: the host's
## CURRENT hardware profile is OLDER than the age bound, and every
## surviving execution points at it. An implementation that applied the age
## bound to hardware — the obvious reading of "remove everything older than
## T" — deletes the row every surviving execution needs.

import std/[options, os, strutils, times, unittest]

import runquota_observation_store

proc scratchDir(name: string): string =
  result = getTempDir() / ("rq-m15r-" & name & "-" &
    $getCurrentProcessId() & "-" & $epochTime())
  removeDir(result)
  createDir(result)

# ---------------------------------------------------------------------------
# Two synthetic extensions
# ---------------------------------------------------------------------------
#
# Two rather than one, because "the cascade reached the extensions" and
# "the cascade reached AN extension" are different claims, and the registry
# is read in `extension_id` order so a pass that stopped after the first
# would pass with one.

const
  alphaId = "m15r_alpha"
  betaId = "m15r_beta"
  probeOwner = "runquota-m15"

  alphaDdl = """
create table ext_m15r_alpha (
  host_id text not null,
  execution_id text not null,
  alpha_label text not null,
  primary key (host_id, execution_id),
  foreign key (host_id, execution_id)
    references executions(host_id, execution_id)
);
"""

  betaDdl = """
create table ext_m15r_beta (
  host_id text not null,
  execution_id text not null,
  beta_label text not null,
  primary key (host_id, execution_id),
  foreign key (host_id, execution_id)
    references executions(host_id, execution_id)
);
"""

proc alphaV1(): ExtensionDeclaration =
  ExtensionDeclaration(extensionId: alphaId, owner: probeOwner,
    schemaVersion: 1, migrations: @[alphaDdl])

proc betaV1(): ExtensionDeclaration =
  ExtensionDeclaration(extensionId: betaId, owner: probeOwner,
    schemaVersion: 1, migrations: @[betaDdl])

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

const
  theHost = "host-m15r"
  # THE HARDWARE IS OLD, AND THAT IS THE FIXTURE. `valid_from` is two years
  # before the newest execution and `valid_to` is NULL, which is what a
  # machine whose RAM has not changed since 2024 actually looks like. Any
  # age bound wide enough to keep a recent execution is narrow enough to
  # call this profile stale.
  hardwareValidFrom = 1_000'i64
  currentProfile = "profile-current"
  supersededProfile = "profile-superseded"

proc profileRow(profileId: string; validFrom: int64;
                validTo: Option[int64]): HostProfileRow =
  HostProfileRow(hostId: theHost, profileId: profileId,
    profileHash: "sha256:" & profileId, validFromUnixMillis: validFrom,
    validToUnixMillis: validTo, cpuModel: "synthetic", physicalCores: 4,
    logicalCores: 8, ramBytes: 1 shl 34, swapBytes: 0, diskClass: dcSsd,
    fsType: "apfs", arch: "arm64", os: "macos", osVersion: "15",
    kernelVersion: "24", virtualization: "none", cpuShareGroup: "default")

proc execution(id: string; startedAt: int64;
               profileId = currentProfile): ExecutionRow =
  ExecutionRow(executionId: id, hostId: theHost,
    hostProfileId: some(profileId), runId: "run-1", commandStatsId: "c",
    startedAtUnixMillis: startedAt, finishedAtUnixMillis: startedAt + 1,
    durationMillis: 1, exitStatus: 0, termination: tExited, attempt: 1,
    peakRssBytes: 0, maxProcesses: 1, majorPageFaults: 0,
    captureCompleteness: ccComplete)

proc ambient(sampledAt: int64): AmbientSampleRow =
  AmbientSampleRow(hostId: theHost, sampledAtUnixMillis: sampledAt,
    cpuBusyPct: 1.0, memAvailableBytes: 1024, swapInRate: 0.0,
    ioQueueDepth: -1.0, loadAvg1m: 0.5, selfCpuPct: 0.0, selfRssBytes: 0,
    foreignCpuPct: 1.0, foreignRssBytes: 1024)

proc seedStore(path: string; executionTimes: openArray[int64];
               ambientTimes: openArray[int64] = []): ObservationStore =
  ## A whole store: one host, two hardware profiles (one superseded, one
  ## current and old), one run, and an execution per timestamp with a row
  ## in BOTH extensions.
  result = openObservationStore(path)
  doAssert result.captureEnabled, result.report
  doAssert result.insertHost(HostRow(hostId: theHost,
    createdAtUnixMillis: hardwareValidFrom, lastBootId: "boot"))
  doAssert result.insertHostProfile(profileRow(supersededProfile,
    hardwareValidFrom, some(hardwareValidFrom + 1)))
  doAssert result.insertHostProfile(profileRow(currentProfile,
    hardwareValidFrom + 1, none(int64)))
  doAssert result.insertRun(RunRow(runId: "run-1", hostId: theHost,
    tool: "t", toolVersion: "v", invocationKind: "build",
    startedAtUnixMillis: hardwareValidFrom,
    captureCompleteness: ccComplete))
  doAssert result.declareExtension(alphaV1()) == eoCreated
  doAssert result.declareExtension(betaV1()) == eoCreated
  for startedAt in executionTimes:
    let id = "exec-" & $startedAt
    doAssert result.insertExecution(execution(id, startedAt))
    doAssert result.insertExtensionRow(alphaV1(), ExtensionRow(
      hostId: theHost, executionId: id, columns: @["alpha_label"],
      values: @[extText("a-" & $startedAt)])) == ewWritten
    doAssert result.insertExtensionRow(betaV1(), ExtensionRow(
      hostId: theHost, executionId: id, columns: @["beta_label"],
      values: @[extText("b-" & $startedAt)])) == ewWritten
  for sampledAt in ambientTimes:
    doAssert result.insertAmbientSample(ambient(sampledAt))

proc executionIds(store: ObservationStore): seq[string] =
  for row in store.readExecutions():
    result.add(row.executionId)

proc scalar(store: ObservationStore; sql: string): int64 =
  let rows = store.runQuery(sql)
  doAssert rows.len == 1 and rows[0].len == 1, sql
  parseBiggestInt(rows[0][0].strip())

suite "observation_store_retention":

  test "the age bound removes what is older than the limit and nothing else":
    let dir = scratchDir("age")
    defer: removeDir(dir)
    let store = seedStore(dir / "o.sqlite",
      [10_000'i64, 20_000, 30_000, 40_000, 50_000],
      [10_000'i64, 20_000, 30_000, 40_000, 50_000])

    # THE POSITIVE CONTROL COMES FIRST. "The old rows are gone" is
    # satisfied trivially by rows that were never written.
    check store.executionIds().len == 5
    check store.extensionRowCount(alphaId) == 5
    check store.extensionRowCount(betaId) == 5
    check store.readAmbientSamples().len == 5

    # `now` is 50_000 and the bound is 25_000 ms, so 10_000 and 20_000 are
    # doomed and 30_000 onwards are not.
    var policy = noRetention()
    policy.maxExecutionAgeMillis = some(25_000'i64)
    policy.maxAmbientSampleAgeMillis = some(25_000'i64)
    let report = store.applyRetention(theHost, 50_000, policy)

    check report.applied
    check report.ageBoundApplied
    check not report.countBoundApplied
    check report.executionsRemoved == 2
    # Two extensions, two rows each.
    check report.extensionRowsRemoved == 4
    check report.extensionsCascaded == @[alphaId, betaId]
    check report.ambientSamplesRemoved == 2

    check store.executionIds() ==
      @["exec-30000", "exec-40000", "exec-50000"]
    check store.extensionRowCount(alphaId) == 3
    check store.extensionRowCount(betaId) == 3
    check store.readExtensionColumns(alphaId, ["alpha_label"]) ==
      @[@["a-30000"], @["a-40000"], @["a-50000"]]
    check store.readExtensionColumns(betaId, ["beta_label"]) ==
      @[@["b-30000"], @["b-40000"], @["b-50000"]]
    check store.readAmbientSamples().len == 3
    check store.captureEnabled

    # A SECOND PASS REMOVES NOTHING, which is what makes the first pass a
    # statement about the bound rather than about running at all.
    let second = store.applyRetention(theHost, 50_000, policy)
    check second.applied
    check second.executionsRemoved == 0
    check second.extensionRowsRemoved == 0
    check second.ambientSamplesRemoved == 0
    check store.executionIds().len == 3

  test "the row-count bound removes what is outside the newest N":
    # The bound that CANNOT be expressed as a timestamp: which rows are
    # doomed depends on how many other rows there are, so an implementation
    # that only ever computed a cutoff cannot enforce it at all.
    let dir = scratchDir("count")
    defer: removeDir(dir)
    let store = seedStore(dir / "o.sqlite",
      [10_000'i64, 20_000, 30_000, 40_000, 50_000],
      [10_000'i64, 20_000, 30_000, 40_000, 50_000])
    check store.executionIds().len == 5
    check store.extensionRowCount(alphaId) == 5

    var policy = noRetention()
    policy.maxExecutions = some(2'i64)
    policy.maxAmbientSamples = some(3'i64)
    # `now` is deliberately absurd: nothing below may depend on it, because
    # no age bound is set.
    let report = store.applyRetention(theHost, 0, policy)

    check report.applied
    check not report.ageBoundApplied
    check report.countBoundApplied
    check report.executionsRemoved == 3
    check report.extensionRowsRemoved == 6
    check report.ambientSamplesRemoved == 2

    # THE NEWEST N, not merely N of them.
    check store.executionIds() == @["exec-40000", "exec-50000"]
    check store.extensionRowCount(alphaId) == 2
    check store.extensionRowCount(betaId) == 2
    check store.readExtensionColumns(alphaId, ["alpha_label"]) ==
      @[@["a-40000"], @["a-50000"]]
    var sampledAt: seq[int64] = @[]
    for row in store.readAmbientSamples():
      sampledAt.add(row.sampledAtUnixMillis)
    check sampledAt == @[30_000'i64, 40_000, 50_000]

    # A limit of zero is a limit, not an absent bound.
    var none = noRetention()
    none.maxExecutions = some(0'i64)
    let cleared = store.applyRetention(theHost, 0, none)
    check cleared.applied
    check cleared.executionsRemoved == 2
    check store.executionIds().len == 0
    check store.extensionRowCount(alphaId) == 0
    check store.extensionRowCount(betaId) == 0
    check store.captureEnabled

  test "both bounds are enforced in one pass, and both are needed":
    # "Bounded by BOTH age and row count" is not two features that happen
    # to exist; it is one pass that applies both. Each arm below is
    # unreachable by the other bound alone.
    let dir = scratchDir("both")
    defer: removeDir(dir)
    var times: seq[int64] = @[]
    for i in 1 .. 10:
      times.add(int64(i) * 10_000)
    let store = seedStore(dir / "o.sqlite", times)
    check store.executionIds().len == 10

    var policy = noRetention()
    policy.maxExecutionAgeMillis = some(55_000'i64)  # keeps 50k..100k -> 6
    policy.maxExecutions = some(2'i64)               # then keeps 90k, 100k
    let report = store.applyRetention(theHost, 100_000, policy)

    check report.applied
    check report.ageBoundApplied
    check report.countBoundApplied
    # 4 removed by age, then 4 more by count.
    check report.executionsRemoved == 8
    check report.extensionRowsRemoved == 16
    # Ordered by the spine key, so the six-digit id sorts first.
    check store.executionIds() == @["exec-100000", "exec-90000"]

    # AND NEITHER BOUND ALONE WOULD HAVE DONE IT. The age bound leaves six
    # rows; the count bound applied to the untouched table leaves two, but
    # they are the same two only because the two orderings agree here — so
    # the discriminating figure is the SIX, asserted directly.
    let ageOnlyDir = scratchDir("ageonly")
    defer: removeDir(ageOnlyDir)
    let ageOnly = seedStore(ageOnlyDir / "o.sqlite", times)
    var agePolicy = noRetention()
    agePolicy.maxExecutionAgeMillis = some(55_000'i64)
    check ageOnly.applyRetention(theHost, 100_000, agePolicy).applied
    check ageOnly.executionIds().len == 6

  test "retention never orphans hardware context":
    # The clause's own trap: the CURRENT hardware profile is older than
    # every bound below, and every surviving execution points at it.
    let dir = scratchDir("orphan")
    defer: removeDir(dir)
    var times: seq[int64] = @[]
    for i in 1 .. 8:
      times.add(int64(i) * 10_000)
    let store = seedStore(dir / "o.sqlite", times, times)

    let hostsBefore = store.readHosts().len
    let profilesBefore = store.readHostProfiles().len
    check hostsBefore == 1
    check profilesBefore == 2
    # The profile every survivor will point at is older than the bound by
    # more than the whole history. Stated rather than assumed, because it
    # is the entire fixture.
    for profile in store.readHostProfiles():
      check profile.validFromUnixMillis < 80_000 - 25_000

    var policy = noRetention()
    policy.maxExecutionAgeMillis = some(25_000'i64)
    policy.maxExecutions = some(2'i64)
    policy.maxAmbientSampleAgeMillis = some(25_000'i64)
    let report = store.applyRetention(theHost, 80_000, policy)

    check report.applied
    check report.executionsRemoved == 6
    check report.hostsRetained == int64(hostsBefore)
    check report.hostProfilesRetained == int64(profilesBefore)
    check store.readHosts().len == hostsBefore
    check store.readHostProfiles().len == profilesBefore

    # NOTHING IS ORPHANED, and it is asserted as a JOIN rather than as a
    # count of rows that happen to still be there.
    let orphanage = store.orphanReport()
    check orphanage.checked
    check orphanage.orphans == 0
    check orphanage.extensionTablesChecked == @[alphaId, betaId]
    # Every survivor's hardware still resolves, which is what OS-6 needs
    # and what a row count alone would not establish.
    check store.executionIds().len == 2
    check store.scalar("select count(*) from executions e join " &
      "host_profiles p on p.host_id = e.host_id and " &
      "p.profile_id = e.host_profile_id;") == 2
    for row in store.readExecutions():
      check row.hostProfileId == some(currentProfile)
    check store.captureEnabled

    # WHY THE CLAUSE HOLDS, ASSERTED RATHER THAN LEFT TO THE CODE'S GOOD
    # BEHAVIOUR — and this leg is here because the obvious mutation does
    # NOT redden the arms above. Adding "delete the profiles that are older
    # than the bound" to retention leaves this test green, because the
    # database itself refuses that delete: the foreign key from
    # `executions` to `host_profiles` is what stands between an age bound
    # and the hardware dimension, and it is a property of the SCHEMA rather
    # than of the retention code. So the schema is what gets asserted.
    check not store.runStatement("delete from host_profiles where " &
      "profile_id = " & encodeText(currentProfile) & ";")
    check "constraint" in store.lastError.toLowerAscii
    check store.readHostProfiles().len == profilesBefore
    check store.captureEnabled
    # AND THE CONTROL, without which "the delete is refused" would be
    # satisfied by a table nothing can ever be removed from: the SUPERSEDED
    # profile, which no surviving execution points at, deletes cleanly.
    # "Retained as long as any row references them" is a statement about
    # references, and this is the other side of it.
    check store.runStatement("delete from host_profiles where " &
      "profile_id = " & encodeText(supersededProfile) & ";")
    check store.readHostProfiles().len == profilesBefore - 1
    check store.orphanReport().orphans == 0

  test "the orphan detector goes off, once per shape":
    # WITHOUT THIS THE CLAUSE ABOVE IS A DETECTOR NOBODY HAS SEEN WORK.
    # Each shape is manufactured with foreign keys OFF, which is the only
    # way this state can exist and is also how a real one arrives: a store
    # edited past this library, or a copy taken by something that did not
    # enforce them.
    let dir = scratchDir("detector")
    defer: removeDir(dir)
    let store = seedStore(dir / "o.sqlite", [10_000'i64, 20_000],
      [10_000'i64])
    check store.orphanReport().orphans == 0

    proc withoutForeignKeys(sql: string) =
      check store.runStatement("pragma foreign_keys = off;\n" & sql)

    # 1. An execution whose hardware profile is gone.
    withoutForeignKeys("delete from host_profiles where profile_id = " &
      encodeText(currentProfile) & ";")
    var seen = store.orphanReport()
    check seen.executionsWithoutProfile == 2
    check seen.orphans == 2
    withoutForeignKeys("insert into host_profiles select * from " &
      "host_profiles limit 0;")  # no-op, keeps the arm honest about order
    check store.insertHostProfile(profileRow(currentProfile,
      hardwareValidFrom + 1, none(int64)))
    check store.orphanReport().orphans == 0

    # 2. An extension row whose execution is gone.
    withoutForeignKeys("delete from executions where execution_id = " &
      encodeText("exec-10000") & ";")
    seen = store.orphanReport()
    check seen.extensionRowsWithoutExecution == 2
    check seen.orphans == 2

    # 3. A run, an ambient sample and a profile whose host is gone.
    withoutForeignKeys("delete from hosts;")
    seen = store.orphanReport()
    check seen.runsWithoutHost == 1
    check seen.ambientSamplesWithoutHost == 1
    check seen.hostProfilesWithoutHost == 2
    check seen.executionsWithoutHost == 1
    check seen.orphans == 7

  test "a store that is not open refuses retention rather than failing":
    # OS-4 on this path too. Retention is housekeeping for capture, and
    # housekeeping that cannot run must not fail anything.
    let dir = scratchDir("closed")
    defer: removeDir(dir)
    let path = dir / "o.sqlite"
    block:
      let store = seedStore(path, [10_000'i64])
      check store.captureEnabled
    check runSqlite(path,
      "pragma user_version = " & $(spineSchemaVersion + 1) & ";").ok

    let store = openObservationStore(path)
    check store.status == ssRefusedNewer
    var policy = noRetention()
    policy.maxExecutionAgeMillis = some(1'i64)
    let report = store.applyRetention(theHost, 50_000, policy)
    check not report.applied
    check report.detail == "store is not open"
    check store.orphanReport().detail == "store is not open"
    check not store.orphanReport().checked
