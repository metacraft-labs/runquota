## M13a gate, the store half: the READ PATH over spine AND extension
## rows.
##
## A store only its writer can read is a log, not a system of record. This
## file asserts what the read path answers; ``t_observation_query_interface``
## asserts that ``runquotad`` answers it over the socket, and
## ``t_observation_store_reader_boundary`` asserts nothing else answers it
## at all.
##
## THE FIXTURE IS THE ASSERTION, AND IT IS ASSERTED FIRST. Every clause
## below passes trivially on the wrong store:
##
## * "does not blend hardware profiles" is unfalsifiable in a store with
##   ONE profile — a single-group answer is then both the blended and the
##   unblended one;
## * "uid-scoped by default" is unfalsifiable in a store with ONE uid, and
##   a scan that returned everything would look correctly scoped;
## * "unknown is not zero" is unfalsifiable without a key that is KNOWN TO
##   BE ZERO, because then no other answer has the numeric content unknown
##   would be confused with.
##
## So the store below holds TWO hardware profiles, TWO owner uids plus a
## row owned by neither, a key with history, a key whose whole history is
## zeros, and a key with no history at all — and ``fixture invariants``
## runs first and asserts every one of those before anything else asserts
## anything about an answer.
##
## NO MOCKS. A real SQLite file on the real filesystem, written through the
## same insert path the daemon uses. The rows are written directly rather
## than driven through a daemon because the fixture the gate demands is one
## a well-behaved client CANNOT PRODUCE: a single machine does not have two
## hardware profiles current at once, and one test process does not run
## under two uids. Constructing that state is the point, not a shortcut
## around one.

import std/[options, os, strutils, unittest]

import runquota_observation_store
from runquota_observation_store/extensions as extensions import nil

const
  KeyWithHistory = "m13a-key-with-history"
  KeyZeroHistory = "m13a-key-zero-history"
  KeyNeverSeen = "m13a-key-never-seen"
  HostId = "host-m13a-fixture"
  RunId = "run-m13a-fixture"
  OldProfileId = "profile-m13a-old"
  NewProfileId = "profile-m13a-new"
  UidAlice = 4001'i64
  UidBob = 4002'i64
  ProbeExtensionId = "m13a_probe"

  # The smallest table that can carry a product's fact: the spine key the
  # extension is joined by, and two columns RunQuota knows nothing about.
  probeDdl = """
create table ext_m13a_probe (
  host_id text not null,
  execution_id text not null,
  probe_label text,
  probe_count integer,
  primary key (host_id, execution_id),
  foreign key (host_id, execution_id)
    references executions(host_id, execution_id)
);
"""

type FixtureRow = object
  statsKey: string
  profileId: string
  ownerUid: Option[int64]
  durationMillis: int64
  peakRssBytes: int64

const fixtureRows = [
  # THE SAME KEY ON BOTH PROFILES, and on each profile from BOTH uids plus
    # one row the transport could not attribute. That shape is what makes the
    # two independent rules independently testable: blending is visible
    # because the per-profile figures are far apart, and uid scoping is
    # visible because dropping it changes a count on a profile that has rows
    # from more than one owner.
  FixtureRow(statsKey: KeyWithHistory, profileId: OldProfileId,
    ownerUid: some(UidAlice), durationMillis: 100, peakRssBytes: 1_000),
  FixtureRow(statsKey: KeyWithHistory, profileId: OldProfileId,
    ownerUid: some(UidBob), durationMillis: 110, peakRssBytes: 1_100),
  FixtureRow(statsKey: KeyWithHistory, profileId: OldProfileId,
    ownerUid: none(int64), durationMillis: 120, peakRssBytes: 1_200),
  FixtureRow(statsKey: KeyWithHistory, profileId: NewProfileId,
    ownerUid: some(UidAlice), durationMillis: 900, peakRssBytes: 9_000),
  FixtureRow(statsKey: KeyWithHistory, profileId: NewProfileId,
    ownerUid: some(UidBob), durationMillis: 910, peakRssBytes: 9_100),
  FixtureRow(statsKey: KeyWithHistory, profileId: NewProfileId,
    ownerUid: none(int64), durationMillis: 920, peakRssBytes: 9_200),
  # A KEY WHOSE WHOLE HISTORY IS ZERO. Its distribution is numerically
  # identical to the one a cold-start answer would carry if "unknown" were
  # reported as zero, which is exactly why it is here.
  FixtureRow(statsKey: KeyZeroHistory, profileId: NewProfileId,
    ownerUid: some(UidAlice), durationMillis: 0, peakRssBytes: 0),
  FixtureRow(statsKey: KeyZeroHistory, profileId: NewProfileId,
    ownerUid: some(UidBob), durationMillis: 0, peakRssBytes: 0),
  FixtureRow(statsKey: KeyZeroHistory, profileId: NewProfileId,
    ownerUid: none(int64), durationMillis: 0, peakRssBytes: 0)]

proc hardware(cpuModel: string; cores: int64; ram: int64): HardwareProfile =
  HardwareProfile(
    cpuModel: cpuModel, physicalCores: cores, logicalCores: cores,
    ramBytes: ram, swapBytes: 0, diskClass: dcNvme, fsType: "apfs",
    arch: "arm64", os: "macos", osVersion: "15.0", kernelVersion: "24.0",
    virtualization: "none", cpuShareGroup: "")

proc profileRow(profileId: string; hw: HardwareProfile; validFrom: int64;
                validTo: Option[int64]): HostProfileRow =
  HostProfileRow(
    hostId: HostId, profileId: profileId, profileHash: profileHash(hw),
    validFromUnixMillis: validFrom, validToUnixMillis: validTo,
    cpuModel: hw.cpuModel, physicalCores: hw.physicalCores,
    logicalCores: hw.logicalCores, ramBytes: hw.ramBytes,
    swapBytes: hw.swapBytes, diskClass: hw.diskClass, fsType: hw.fsType,
    arch: hw.arch, os: hw.os, osVersion: hw.osVersion,
    kernelVersion: hw.kernelVersion, virtualization: hw.virtualization,
    cpuShareGroup: hw.cpuShareGroup)

proc buildFixture(path: string): ObservationStore =
  result = openObservationStore(path)
  doAssert result.captureEnabled, result.report
  doAssert result.insertHost(HostRow(hostId: HostId,
    createdAtUnixMillis: 1_000, lastBootId: "boot-m13a"))
  # TWO PROFILES ON ONE HOST: the old one closed, the new one current. That
  # is the only legal way to hold two, because `host_profiles_current`
  # refuses a second open profile — and it is the real situation the rule
  # exists for, a machine whose hardware changed under a history that
  # outlives it.
  let oldHardware = hardware("M13a Builder 32", 32, 128_000_000_000'i64)
  let newHardware = hardware("M13a Laptop 8", 8, 16_000_000_000'i64)
  doAssert result.insertHostProfile(
    profileRow(OldProfileId, oldHardware, 1_000, some(2_000'i64)))
  doAssert result.insertHostProfile(
    profileRow(NewProfileId, newHardware, 2_000, none(int64)))
  doAssert result.insertRun(RunRow(
    runId: RunId, hostId: HostId, tool: "m13a", toolVersion: "0.1.0",
    invocationKind: "fixture", startedAtUnixMillis: 1_000,
    finishedAtUnixMillis: none(int64), exitStatus: none(int64),
    workspaceId: none(string), profile: none(string),
    gitCommit: none(string), gitBranch: none(string),
    captureCompleteness: ccComplete, droppedObservations: 0))
  for index, row in fixtureRows:
    doAssert result.insertExecution(ExecutionRow(
      executionId: "exec-m13a-" & $index,
      hostId: HostId,
      hostProfileId: some(row.profileId),
      runId: RunId,
      commandStatsId: row.statsKey,
      leaseId: none(int64),
      startedAtUnixMillis: 10_000 + int64(index),
      finishedAtUnixMillis: 10_000 + int64(index) + row.durationMillis,
      durationMillis: row.durationMillis,
      exitStatus: 0,
      termination: tExited,
      attempt: 1,
      retryOf: none(string),
      peakRssBytes: row.peakRssBytes,
      cpuUserMillis: none(int64),
      cpuSysMillis: none(int64),
      maxProcesses: 1,
      majorPageFaults: 0,
      ioReadBytes: none(int64),
      ioWriteBytes: none(int64),
      captureCompleteness: ccComplete,
      droppedObservations: 0,
      ownerUid: row.ownerUid)), result.lastError

proc scratch(name: string): string =
  result = getTempDir() / ("rq-m13a-" & $getCurrentProcessId() & "-" & name)
  removeDir(result)
  createDir(result)

proc groupFor(answer: StatsAnswer; profileId: string): ResourceDistribution =
  for entry in answer.distributions:
    if entry.profile.profileId == some(profileId):
      return entry
  raise newException(ValueError, "no distribution for " & profileId)

suite "observation_store_query":

  # -------------------------------------------------------------------------
  # NON-VACUITY. This runs first and asserts the store really holds what
  # every clause below needs it to hold.
  # -------------------------------------------------------------------------

  test "fixture invariants: two profiles, two uids, a key with and without":
    let root = scratch("fixture")
    defer: removeDir(root)
    let store = buildFixture(root / "observations.sqlite3")

    let profiles = store.readHostProfiles()
    check profiles.len == 2
    check profiles[0].profileId != profiles[1].profileId
    # DIFFERENT HARDWARE, not merely different ids: a blended answer over
    # two identical profiles would be indistinguishable from an unblended
    # one, and the durations below are only meaningful because the machines
    # they were measured on really differ.
    check profiles[0].profileHash != profiles[1].profileHash
    check profiles[0].logicalCores != profiles[1].logicalCores
    var openProfiles = 0
    for profile in profiles:
      if profile.validToUnixMillis.isNone:
        openProfiles += 1
    check openProfiles == 1

    let rows = store.readExecutions()
    var uids: seq[int64] = @[]
    var unowned = 0
    for row in rows:
      if row.ownerUid.isSome:
        if row.ownerUid.get notin uids:
          uids.add(row.ownerUid.get)
      else:
        unowned += 1
    check uids.len == 2
    check UidAlice in uids
    check UidBob in uids
    check unowned == 3

    var withHistory = 0
    var zeroHistory = 0
    var neverSeen = 0
    for row in rows:
      case row.commandStatsId
      of KeyWithHistory: withHistory += 1
      of KeyZeroHistory: zeroHistory += 1
      of KeyNeverSeen: neverSeen += 1
      else: discard
    check withHistory == 6
    check zeroHistory == 3
    # THE KEY WITHOUT HISTORY REALLY HAS NONE. Asserted rather than
    # assumed: a cold-start clause tested against a key that quietly had
    # rows would be measuring the wrong branch.
    check neverSeen == 0

    # And both uids really have rows for the SAME key on the SAME profile,
    # which is what makes "uid scoping changed the answer" observable at
    # all.
    var aliceOnOld = 0
    var bobOnOld = 0
    for row in rows:
      if row.commandStatsId == KeyWithHistory and
          row.hostProfileId == some(OldProfileId):
        if row.ownerUid == some(UidAlice): aliceOnOld += 1
        if row.ownerUid == some(UidBob): bobOnOld += 1
    check aliceOnOld == 1
    check bobOnOld == 1

  # -------------------------------------------------------------------------
  # HOST QUALIFICATION: every answer carries the profile, and two profiles
  # are never blended into one set of figures.
  # -------------------------------------------------------------------------

  test "a query spanning two profiles answers per profile and never blends":
    let root = scratch("blend")
    defer: removeDir(root)
    let store = buildFixture(root / "observations.sqlite3")

    let answer = store.estimateFor(KeyWithHistory, spanAllProfiles)
    check answer.knowledge == statsKnown
    # ONE ENTRY PER PROFILE. A blended answer is one entry; this is two,
    # and each of them names the hardware it describes.
    check answer.distributions.len == 2
    check answer.distributions[0].profile.profileId !=
      answer.distributions[1].profile.profileId

    let old = answer.groupFor(OldProfileId)
    let recent = answer.groupFor(NewProfileId)

    # THE PROFILE IDENTITY TRAVELS WITH THE FIGURES, and it is the real
    # hardware rather than a label: a record written on a 32-core builder
    # and read on an 8-core laptop has to be recognisable as such.
    check old.profile.hostId == HostId
    check old.profile.cpuModel == "M13a Builder 32"
    check old.profile.logicalCores == 32
    check recent.profile.cpuModel == "M13a Laptop 8"
    check recent.profile.logicalCores == 8
    check old.profile.profileHash != recent.profile.profileHash
    check old.profile.profileHash.len > 0

    # Each group's figures are its OWN profile's rows, exactly.
    check old.sampleCount == 3
    check old.durationMillisMin == 100
    check old.durationMillisP50 == 110
    check old.durationMillisP90 == 120
    check old.durationMillisMax == 120
    check old.peakRssBytesMax == 1_200

    check recent.sampleCount == 3
    check recent.durationMillisMin == 900
    check recent.durationMillisP50 == 910
    check recent.durationMillisP90 == 920
    check recent.durationMillisMax == 920
    check recent.peakRssBytesMax == 9_200

    # AND THE BLENDED ANSWER APPEARS NOWHERE. These are the figures a
    # single pooled distribution over all six rows would have carried:
    # sampleCount 6, a p50 of 120, a maximum of 920 sitting beside a
    # minimum of 100. Asserting their ABSENCE is what makes this clause
    # fail when the profile dimension is dropped, rather than merely
    # asserting that the right numbers are present somewhere.
    for entry in answer.distributions:
      check entry.sampleCount != 6
      check not (entry.durationMillisMin == 100 and
        entry.durationMillisMax == 920)
      check not (entry.durationMillisMin == 100 and
        entry.peakRssBytesMax == 9_200)

  test "the default span is one profile, and it is the one asked for":
    let root = scratch("span")
    defer: removeDir(root)
    let store = buildFixture(root / "observations.sqlite3")

    # NARROW BY DEFAULT: a caller that does not ask for cross-host data
    # does not receive it. Widening is the explicit act.
    let narrow = store.estimateFor(KeyWithHistory, spanSingleProfile,
      some(OldProfileId))
    check narrow.distributions.len == 1
    check narrow.distributions[0].profile.profileId == some(OldProfileId)
    check narrow.distributions[0].sampleCount == 3
    check narrow.distributions[0].durationMillisMax == 120

    let other = store.estimateFor(KeyWithHistory, spanSingleProfile,
      some(NewProfileId))
    check other.distributions.len == 1
    check other.distributions[0].profile.profileId == some(NewProfileId)
    check other.distributions[0].durationMillisMax == 920

  # -------------------------------------------------------------------------
  # COLD START: unknown is a different answer from zero, not a smaller one.
  # -------------------------------------------------------------------------

  test "a key with no history is UNKNOWN, distinguishably from known zero":
    let root = scratch("cold")
    defer: removeDir(root)
    let store = buildFixture(root / "observations.sqlite3")

    let unknown = store.estimateFor(KeyNeverSeen, spanSingleProfile,
      some(NewProfileId))
    let zero = store.estimateFor(KeyZeroHistory, spanSingleProfile,
      some(NewProfileId))

    check unknown.knowledge == statsUnknown
    check zero.knowledge == statsKnown
    check unknown.distributions.len == 1
    check zero.distributions.len == 1
    let unknownEntry = unknown.distributions[0]
    let zeroEntry = zero.distributions[0]
    check unknownEntry.knowledge == statsUnknown
    check zeroEntry.knowledge == statsKnown

    # THE TWO ANSWERS AGREE ON EVERY MEASURED FIGURE. A reader looking at
    # the numbers alone could not tell them apart -- which is the whole
    # reason `knowledge` has to carry the difference, and the reason this
    # clause is not satisfied by a distribution that merely happens to be
    # empty.
    check unknownEntry.durationMillisMin == zeroEntry.durationMillisMin
    check unknownEntry.durationMillisP50 == zeroEntry.durationMillisP50
    check unknownEntry.durationMillisP90 == zeroEntry.durationMillisP90
    check unknownEntry.durationMillisMax == zeroEntry.durationMillisMax
    check unknownEntry.peakRssBytesMax == zeroEntry.peakRssBytesMax
    check zeroEntry.durationMillisMax == 0
    check zeroEntry.peakRssBytesMax == 0

    # And they differ where a caller can act on it: three measurements
    # against none.
    check zeroEntry.sampleCount == 3
    check unknownEntry.sampleCount == 0

    # AN UNKNOWN ANSWER IS STILL QUALIFIED. It names the hardware it knows
    # nothing about, because "no history on this machine" and "no history
    # anywhere" are different facts.
    check unknownEntry.profile.profileId == some(NewProfileId)
    check unknownEntry.profile.cpuModel == "M13a Laptop 8"

  # -------------------------------------------------------------------------
  # SCOPING: rows are the calling uid's unless widening is asked for, and
  # the estimate path is deliberately not scoped at all.
  # -------------------------------------------------------------------------

  test "row queries are uid-scoped by default and widen only when asked":
    let root = scratch("scope")
    defer: removeDir(root)
    let store = buildFixture(root / "observations.sqlite3")

    let mine = store.queryExecutions(RowQuery(
      statsKey: KeyWithHistory, scope: statsScopeOwner,
      ownerUid: some(UidAlice), span: spanAllProfiles, limit: 0))
    check mine.len == 2
    for row in mine:
      check row.ownerUid == some(UidAlice)

    # NOT MERELY "MINE ARE PRESENT": the other user's rows are ABSENT, and
    # the store really holds them, so an unscoped scan cannot pass this.
    let widened = store.queryExecutions(RowQuery(
      statsKey: KeyWithHistory, scope: statsScopeHost,
      ownerUid: some(UidAlice), span: spanAllProfiles, limit: 0))
    check widened.len == 6
    var bobRows = 0
    var unownedRows = 0
    for row in widened:
      if row.ownerUid == some(UidBob): bobRows += 1
      if row.ownerUid.isNone: unownedRows += 1
    check bobRows == 2
    check unownedRows == 2

    # A ROW NOBODY OWNS IS NOT MINE. The transport could not report the
    # owner, so attributing it to whoever happens to be asking would be
    # over-sharing by default -- the failure the per-user boundary exists
    # to prevent.
    for row in mine:
      check row.ownerUid.isSome

    # EVERY ROW IS QUALIFIED TOO. The rows aggregation carries the same
    # hardware identity the distribution does; a ranking that mixed
    # machines would be the blending rule broken by another route.
    for row in widened:
      check row.profile.profileId.isSome
      check row.profile.profileHash.len > 0

  test "widening is available, which is the half a refusal must not eat":
    let root = scratch("widen")
    defer: removeDir(root)
    let store = buildFixture(root / "observations.sqlite3")

    # A CI administrator asking "what is slow on this machine" is a real
    # question, and the answer must be reachable. A read path that only
    # ever answered for the caller would satisfy every scoping assertion
    # above and still be wrong.
    let ranking = store.queryRanking(RowQuery(
      statsKey: "", scope: statsScopeHost, ownerUid: none(int64),
      span: spanAllProfiles, limit: 0))
    var seenKeys: seq[string] = @[]
    for entry in ranking:
      if entry.statsKey notin seenKeys:
        seenKeys.add(entry.statsKey)
    check KeyWithHistory in seenKeys
    check KeyZeroHistory in seenKeys

    # RANKED WITHIN A PROFILE, never across one: the same key appears once
    # per profile it ran on, each entry naming its own hardware.
    var historyEntries: seq[KeyRanking] = @[]
    for entry in ranking:
      if entry.statsKey == KeyWithHistory:
        historyEntries.add(entry)
    check historyEntries.len == 2
    check historyEntries[0].profile.profileId !=
      historyEntries[1].profile.profileId
    for entry in historyEntries:
      check entry.sampleCount == 3
      check entry.totalDurationMillis in [330'i64, 2_730'i64]
      check entry.totalDurationMillis != 3_060

  test "a uid-scoped query with no uid to scope to returns nothing":
    let root = scratch("nouid")
    defer: removeDir(root)
    let store = buildFixture(root / "observations.sqlite3")

    # THE DEGRADATION, NOT THE HAPPY PATH. A transport that cannot report
    # peer credentials leaves the daemon with nobody to scope to. The
    # answer is EMPTY, never widened: silently answering host-wide would
    # hand every user's rows to a caller that asked for its own.
    let answer = store.queryExecutions(RowQuery(
      statsKey: KeyWithHistory, scope: statsScopeOwner,
      ownerUid: none(int64), span: spanAllProfiles, limit: 0))
    check answer.len == 0

  test "the estimate path is NOT uid-scoped, and cannot be given a uid":
    let root = scratch("estimate-scope")
    defer: removeDir(root)
    let store = buildFixture(root / "observations.sqlite3")

    # THE ASYMMETRY IS DELIBERATE. The cost of this work is a property of
    # the work and the hardware, not of who ran it; scoping it per user
    # would discard most of the history on exactly the machines that have
    # the most. So the distribution over one profile counts BOTH uids' rows
    # and the unattributed one -- three samples, not the one Alice owns.
    let answer = store.estimateFor(KeyWithHistory, spanSingleProfile,
      some(OldProfileId))
    check answer.distributions.len == 1
    check answer.distributions[0].sampleCount == 3
    check answer.distributions[0].durationMillisMin == 100
    check answer.distributions[0].durationMillisMax == 120

    # Alice alone would have been a single sample of 100, which is what a
    # uid-scoped estimate would have reported. It does not appear.
    check answer.distributions[0].sampleCount != 1
    let aliceRows = store.queryExecutions(RowQuery(
      statsKey: KeyWithHistory, scope: statsScopeOwner,
      ownerUid: some(UidAlice), span: spanSingleProfile,
      profileId: some(OldProfileId), limit: 0))
    check aliceRows.len == 1
    check aliceRows[0].durationMillis == 100

  # -------------------------------------------------------------------------
  # EXTENSION ROWS: the same interface, over rows RunQuota does not
  # understand, under the same scoping rules.
  # -------------------------------------------------------------------------

  test "extension rows answer under the SAME scope rules as the spine":
    let root = scratch("ext")
    defer: removeDir(root)
    let store = buildFixture(root / "observations.sqlite3")
    check store.declareExtension(ExtensionDeclaration(
      extensionId: ProbeExtensionId, owner: "runquota-m13a",
      schemaVersion: 1, migrations: @[probeDdl])) == eoCreated

    # A fact attached to ONE ROW PER UID, so the scoping assertion below
    # has something to hide.
    var attached = 0
    for row in store.readExecutions():
      if row.commandStatsId != KeyWithHistory or
          row.hostProfileId != some(OldProfileId):
        continue
      check store.insertExtensionRow(
        ExtensionDeclaration(extensionId: ProbeExtensionId,
          owner: "runquota-m13a", schemaVersion: 1, migrations: @[probeDdl]),
        extensions.ExtensionRow(
          hostId: row.hostId, executionId: row.executionId,
          columns: @["probe_label", "probe_count"],
          values: @[
            (if row.ownerUid == some(UidAlice): extText("alice-fact")
              elif row.ownerUid == some(UidBob): extText("bob-fact")
              else: extNull()),
            extInt(row.durationMillis)])) == ewWritten
      attached += 1
    # NON-VACUITY for this arm: three rows really carry the extension, one
    # per owner, so "the other user's fact is absent" is a statement about
    # scoping rather than about an empty table.
    check attached == 3
    check store.extensionRowCount(ProbeExtensionId) == 3

    let mine = store.queryExtensionRows(RowQuery(
      statsKey: KeyWithHistory, scope: statsScopeOwner,
      ownerUid: some(UidAlice), span: spanSingleProfile,
      profileId: some(OldProfileId), limit: 0),
      ProbeExtensionId, ["probe_label", "probe_count"])
    check mine.len == 1
    check mine[0].ownerUid == some(UidAlice)
    check mine[0].statsKey == KeyWithHistory
    # THE SPINE CONTEXT TRAVELS WITH THE PRODUCT'S FACT, so a reader can
    # tell which machine it was measured on without asking again.
    check mine[0].profile.profileId == some(OldProfileId)
    check mine[0].profile.cpuModel == "M13a Builder 32"
    # AND THE PAYLOAD IS OPAQUE: echoed column names, unparsed text values,
    # in the order asked for.
    check mine[0].columns == @["probe_label", "probe_count"]
    check mine[0].values == @["alice-fact", "100"]

    # Bob's fact is in the store and is NOT in Alice's answer.
    let hostWide = store.queryExtensionRows(RowQuery(
      statsKey: KeyWithHistory, scope: statsScopeHost,
      ownerUid: some(UidAlice), span: spanSingleProfile,
      profileId: some(OldProfileId), limit: 0),
      ProbeExtensionId, ["probe_label", "probe_count"])
    check hostWide.len == 3
    var labels: seq[string] = @[]
    for row in hostWide:
      labels.add(row.values[0])
    check "bob-fact" in labels
    check "bob-fact" notin @[mine[0].values[0]]
    # SQL NULL COMES BACK AS THE NULL MARKER, not as the empty string: an
    # extension value nobody set and an extension value set to "" are
    # different facts, and RunQuota cannot tell which one a product meant.
    check nullMarker in labels
    check "" notin labels

    # -----------------------------------------------------------------------
    # THE REFUSALS, ASSERTED AS REFUSALS RATHER THAN AS EMPTINESS.
    #
    # `.len == 0` ON ITS OWN PROVES NOTHING HERE, and this is the M12 defect
    # in its exact shape. An implementation that ignored
    # `isStorableIdentifier` and composed SQL out of caller text would ALSO
    # answer empty for a payload that is not valid SQL -- because the
    # statement fails and `store.query` returns nothing, not because a guard
    # fired. Emptiness cannot tell "refused" from "broke".
    #
    # So every probe below is chosen so that a GUARDLESS implementation
    # SUCCEEDS: it either returns rows, or it executes the statement it was
    # handed. The assertions are on what that success would have produced.
    # -----------------------------------------------------------------------

    # (1) A COLUMN NAME THAT IS NOT A STORABLE IDENTIFIER BUT IS PERFECTLY
    # GOOD SQL. SQLite accepts a double-quoted identifier, so composing this
    # yields a VALID statement over a real column and three rows come back.
    # Emptiness here is therefore the guard and nothing else.
    check store.queryExtensionRows(RowQuery(statsKey: "",
      scope: statsScopeHost, span: spanAllProfiles),
      ProbeExtensionId, ["\"probe_label\""]).len == 0

    # (2) THE SAME FOR THE EXTENSION ID, by the same trick from the other
    # side: SQLite identifiers are case-insensitive, so `ext_M13a_probe`
    # names the table that exists. A guardless implementation reads it and
    # answers rows; `isStorableIdentifier` refuses the uppercase.
    check store.queryExtensionRows(RowQuery(statsKey: "",
      scope: statsScopeHost, span: spanAllProfiles),
      "M13a_probe", ["probe_label"]).len == 0

    # (3) AN INJECTION THAT WOULD REALLY RUN, which the previous
    # `probe_label; drop table executions` did not: that payload makes the
    # FIRST statement a syntax error, `sqlite3 -bail` exits, and the empty
    # answer measures the breakage. These two close the CASE expression and
    # the FROM clause first, so a guardless implementation emits a VALID
    # first statement, COMMITS the `delete` that follows it, and only then
    # reaches the fragment that fails.
    const injectedColumn =
      "probe_count is null then 1 end from ext_m13a_probe;" &
      " delete from ext_m13a_probe;" &
      " select case when probe_count"
    check store.queryExtensionRows(RowQuery(statsKey: "",
      scope: statsScopeHost, span: spanAllProfiles),
      ProbeExtensionId, [injectedColumn]).len == 0
    const injectedExtension =
      "m13a_probe; delete from ext_m13a_probe; select 1 from ("
    check store.queryExtensionRows(RowQuery(statsKey: "",
      scope: statsScopeHost, span: spanAllProfiles),
      injectedExtension, ["probe_label"]).len == 0

    # (4) An empty column list is refused before any statement exists to
    # compose. This one already discriminates on emptiness alone -- dropping
    # the check yields a valid two-column statement and three rows.
    check store.queryExtensionRows(RowQuery(statsKey: "",
      scope: statsScopeHost, span: spanAllProfiles),
      ProbeExtensionId, []).len == 0

    # AND NOTHING RAN. This is what the injections are for: had either been
    # composed instead of refused, its `delete` would have committed before
    # the failing fragment aborted the batch, and the counts below would
    # have moved. The spine is checked too, because a payload aimed at
    # `executions` would leave the extension table untouched.
    check store.extensionRowCount(ProbeExtensionId) == 3
    check store.readExecutions().len == fixtureRows.len

  test "a degraded store answers rather than raising, and says it knows nothing":
    let root = scratch("degraded")
    defer: removeDir(root)
    # OS-4 REACHES THE READ PATH TOO. A store that could not open must not
    # turn a `repro stats` into a crash; it answers UNKNOWN and empty.
    #
    # THE DEGRADED STORE HERE IS A FULL ONE. Asserting emptiness against a
    # store that is empty anyway is the vacuity this campaign keeps
    # shipping: deleting the degradation check would produce the same empty
    # answer, because there was nothing to answer with. So the file below
    # is the FIXTURE built above -- two profiles, nine executions, a key
    # with history -- and only the handle is degraded. "Empty" is then a
    # statement about the degradation.
    let path = root / "observations.sqlite3"
    let live = buildFixture(path)
    check live.captureEnabled
    check live.readExecutions().len == fixtureRows.len
    check live.estimateFor(KeyWithHistory, spanAllProfiles)
      .knowledge == statsKnown

    let closed = ObservationStore(path: path, status: ssDisabled,
      report: "disabled", schemaVersion: -1)
    check not closed.captureEnabled
    let answer = closed.estimateFor(KeyWithHistory, spanAllProfiles)
    check answer.knowledge == statsUnknown
    check answer.distributions.len == 0
    # NOT EVEN A COLD-START ENTRY. A degraded store is not "no history on
    # this profile" -- it is "cannot answer at all", and the two must not
    # be conflated any more than unknown and zero may be. This is the
    # clause that fails if the capture check is deleted from `estimateFor`:
    # the query then falls through to the cold-start branch and manufactures
    # a distribution for hardware it never read.
    let narrow = closed.estimateFor(KeyWithHistory, spanSingleProfile,
      some(NewProfileId))
    check narrow.knowledge == statsUnknown
    check narrow.distributions.len == 0

    # And no rows leak, from a store that demonstrably holds them.
    check closed.queryExecutions(RowQuery(scope: statsScopeHost)).len == 0
    check closed.queryRanking(RowQuery(scope: statsScopeHost)).len == 0
    # A store that cannot be opened AT ALL takes the same path rather than
    # raising: the read side of OS-4 is "degrade", not "fail loudly". The
    # parent is a regular file, so no amount of `createDir` rescues it --
    # `openObservationStore` happily creates missing directories, which is
    # why "a path that does not exist yet" is NOT a degraded store and
    # would have made this arm test nothing.
    let blocker = root / "not-a-directory"
    writeFile(blocker, "")
    let unopenable = openObservationStore(blocker / "y.sqlite3")
    check not unopenable.captureEnabled
    check unopenable.estimateFor(KeyWithHistory, spanAllProfiles)
      .knowledge == statsUnknown
    check unopenable.queryExecutions(RowQuery(scope: statsScopeHost)).len == 0
