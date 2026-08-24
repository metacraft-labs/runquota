## M15 gate, the merge half: merging the same source twice and two sources
## in both orders yields the same database; extension rows with an unknown
## schema are CARRIED and marked unqueryable, never dropped; a merge
## attempted without the host/profile dimension is REFUSED.
##
## This is also where OS-5's fourth limb lands. M12 narrowed its own
## ``:proves:`` because OS-5 names registration, migration, retention
## cascade and MERGE, and only the first three existed; the merge code is
## here, so the invariant is established in full from this milestone on.
##
## ---------------------------------------------------------------------
## THE GATE SAYS "BYTE-IDENTICAL DATABASES" AND THAT IS NOT ACHIEVABLE
## ---------------------------------------------------------------------
##
## Not "hard": not achievable, for this schema, by any correct merge. Every
## spine table is an ordinary rowid table, so SQLite gives each inserted
## row an implicit rowid in INSERTION order, and two merges that insert the
## same facts in different orders put them under different rowids on
## different pages. ``vacuum`` repacks a database but PRESERVES rowids, so
## it does not launder the difference either.
##
## That is asserted below rather than asserted around: the first test
## builds two databases with identical content in different insert orders
## and requires their BYTES TO DIFFER — before and after ``vacuum into`` —
## while their canonical digests match. If SQLite ever made the file itself
## carry the property, that test goes red and this substitution should be
## withdrawn.
##
## WHAT IS ASSERTED INSTEAD. Identity over a canonical form: every table
## discovered from ``sqlite_master``, every column of every row rendered
## with its storage class and the hex of its bytes, rows sorted, objects
## sorted, ``user_version`` included, digested with SHA-256. The property
## the gate is reaching for is that NO OBSERVABLE DIFFERENCE SURVIVES; the
## file's bytes are one way to say that and, here, not an available one.
##
## AND THE CANONICALISATION IS ITSELF CHECKED, because a digest that could
## not tell two databases apart would satisfy the clause by being blind.
## The second test is a battery: one extra row, one changed cell, ``NULL``
## against the empty string, an integer against its own text, a moved
## ``user_version``, a new index, and a table the store's own list has
## never heard of each change the digest. Only physical layout does not.
##
## NO MOCKS. Real SQLite files, real merges, and the sources are built by
## the same library the daemon writes with. The fixtures a well-behaved
## client cannot produce are the two refusal sources — one whose
## executions carry no hardware profile, one with no ``hosts`` table at all
## — and a source declaring an extension at a version this receiver does
## not have. Each is a real store some other machine could hand over.

import std/[options, os, strutils, times, unittest]

import runquota_observation_store

proc scratchDir(name: string): string =
  result = getTempDir() / ("rq-m15m-" & name & "-" &
    $getCurrentProcessId() & "-" & $epochTime())
  removeDir(result)
  createDir(result)

# ---------------------------------------------------------------------------
# Two synthetic extensions, and one of them at two versions
# ---------------------------------------------------------------------------
#
# `m15m_known` exists at v1 and v2. The RECEIVER carries v1; source B
# carries v2, whose extra column is the thing a lossy merge drops on the
# floor while leaving a row that reads afterwards as complete.
#
# `m15m_alien` the receiver has never heard of at all — the other half of
# "an extension_id OR schema_version the receiver does not know".

const
  knownId = "m15m_known"
  alienId = "m15m_alien"
  fixtureOwner = "runquota-m15"

  knownV1Ddl = """
create table ext_m15m_known (
  host_id text not null,
  execution_id text not null,
  known_label text not null,
  primary key (host_id, execution_id),
  foreign key (host_id, execution_id)
    references executions(host_id, execution_id)
);
"""

  knownV2Step = """
alter table ext_m15m_known add column known_weight real;
"""

  alienV1Ddl = """
create table ext_m15m_alien (
  host_id text not null,
  execution_id text not null,
  alien_label text not null,
  primary key (host_id, execution_id),
  foreign key (host_id, execution_id)
    references executions(host_id, execution_id)
);
"""

proc knownV1(): ExtensionDeclaration =
  ExtensionDeclaration(extensionId: knownId, owner: fixtureOwner,
    schemaVersion: 1, migrations: @[knownV1Ddl])

proc knownV2(): ExtensionDeclaration =
  ExtensionDeclaration(extensionId: knownId, owner: fixtureOwner,
    schemaVersion: 2, migrations: @[knownV1Ddl, knownV2Step])

proc alienV1(): ExtensionDeclaration =
  ExtensionDeclaration(extensionId: alienId, owner: fixtureOwner,
    schemaVersion: 1, migrations: @[alienV1Ddl])

# ---------------------------------------------------------------------------
# Spine fixtures
# ---------------------------------------------------------------------------

proc profileRow(hostId, profileId: string): HostProfileRow =
  HostProfileRow(hostId: hostId, profileId: profileId,
    profileHash: "sha256:" & profileId, validFromUnixMillis: 1_000,
    validToUnixMillis: none(int64), cpuModel: "synthetic-" & hostId,
    physicalCores: 4, logicalCores: 8, ramBytes: 1 shl 34, swapBytes: 0,
    diskClass: dcSsd, fsType: "apfs", arch: "arm64", os: "macos",
    osVersion: "15", kernelVersion: "24", virtualization: "none",
    cpuShareGroup: "default")

proc execution(hostId, profileId, id: string;
               startedAt: int64): ExecutionRow =
  ExecutionRow(executionId: id, hostId: hostId,
    hostProfileId: some(profileId), runId: "run-" & hostId,
    commandStatsId: "c", startedAtUnixMillis: startedAt,
    finishedAtUnixMillis: startedAt + 1, durationMillis: 1, exitStatus: 0,
    termination: tExited, attempt: 1, peakRssBytes: 0, maxProcesses: 1,
    majorPageFaults: 0, captureCompleteness: ccComplete)

proc seedSpine(store: ObservationStore; hostId, profileId: string;
               qualified = true) =
  doAssert store.insertHost(HostRow(hostId: hostId,
    createdAtUnixMillis: 1_000, lastBootId: "boot-" & hostId))
  if qualified:
    doAssert store.insertHostProfile(profileRow(hostId, profileId))
  doAssert store.insertRun(RunRow(runId: "run-" & hostId, hostId: hostId,
    tool: "t", toolVersion: "v", invocationKind: "build",
    startedAtUnixMillis: 1_000, captureCompleteness: ccComplete))

proc sourceA(path: string): ObservationStore =
  ## Host A: three executions, ``m15m_known`` at the version the receiver
  ## carries, and ``m15m_alien`` which the receiver has never heard of.
  result = openObservationStore(path)
  doAssert result.captureEnabled, result.report
  seedSpine(result, "host-a", "pa")
  doAssert result.declareExtension(knownV1()) == eoCreated
  doAssert result.declareExtension(alienV1()) == eoCreated
  for i in 1 .. 3:
    let id = "a-exec-" & $i
    doAssert result.insertExecution(
      execution("host-a", "pa", id, int64(i) * 1_000))
    doAssert result.insertExtensionRow(knownV1(), ExtensionRow(
      hostId: "host-a", executionId: id, columns: @["known_label"],
      values: @[extText("ka-" & $i)])) == ewWritten
    doAssert result.insertExtensionRow(alienV1(), ExtensionRow(
      hostId: "host-a", executionId: id, columns: @["alien_label"],
      values: @[extText("al-" & $i)])) == ewWritten

proc sourceB(path: string): ObservationStore =
  ## Host B: two executions and ``m15m_known`` AT VERSION 2. The receiver
  ## has no route to that version, so these rows must be carried whole
  ## rather than trimmed to the columns it recognises.
  result = openObservationStore(path)
  doAssert result.captureEnabled, result.report
  seedSpine(result, "host-b", "pb")
  doAssert result.declareExtension(knownV2()) == eoCreated
  for i in 1 .. 2:
    let id = "b-exec-" & $i
    doAssert result.insertExecution(
      execution("host-b", "pb", id, int64(i) * 1_000))
    doAssert result.insertExtensionRow(knownV2(), ExtensionRow(
      hostId: "host-b", executionId: id,
      columns: @["known_label", "known_weight"],
      values: @[extText("kb-" & $i), extReal(0.5 * float64(i))])) == ewWritten

proc receiver(path: string): ObservationStore =
  ## A destination that knows ``m15m_known`` at version 1 and nothing else.
  result = openObservationStore(path)
  doAssert result.captureEnabled, result.report
  doAssert result.declareExtension(knownV1()) == eoCreated

proc pristine(dir: string): string =
  ## ONE receiver, built once. Every destination below is a COPY of it.
  ##
  ## This is methodology and not convenience. Two receivers built by two
  ## calls differ before a merge has happened at all — ``extension_registry``
  ## records when a registration was made, and two registrations a
  ## millisecond apart are two different databases. Comparing two
  ## independently constructed destinations would therefore compare the
  ## clock as much as the merge. Starting both from the same bytes makes
  ## any difference afterwards attributable to the merge, and the tests
  ## assert the shared starting point rather than assuming it.
  result = dir / "pristine.sqlite"
  discard receiver(result)

proc copyOfPristine(pristinePath, path: string): ObservationStore =
  let source = openObservationStore(pristinePath)
  doAssert source.captureEnabled
  doAssert source.backupTo(path)
  result = openObservationStore(path)
  doAssert result.captureEnabled, result.report

proc digestOf(path: string): string =
  let dump = canonicalDump(path)
  doAssert dump.ok, dump.detail
  dump.digest

suite "observation_store_merge":

  test "the file's bytes cannot carry the identity, and the canonical form can":
    # THE CLAUSE THE GATE ASKS FOR, MEASURED RATHER THAN ASSUMED. Two
    # databases with identical content, built by inserting the same rows in
    # opposite orders. If the bytes matched, the gate would be satisfiable
    # as written and this whole substitution would be unnecessary.
    let dir = scratchDir("bytes")
    defer: removeDir(dir)
    let first = dir / "first.sqlite"
    let second = dir / "second.sqlite"
    const ddl = "create table t (k text primary key, v integer);"
    check runSqlite(first, ddl &
      "insert into t values ('a', 1); insert into t values ('b', 2);").ok
    check runSqlite(second, ddl &
      "insert into t values ('b', 2); insert into t values ('a', 1);").ok

    # Same rows, both ways round.
    check runSqlite(first, "select group_concat(k || '=' || v) from " &
      "(select k, v from t order by k);").output.strip() == "a=1,b=2"
    check runSqlite(second, "select group_concat(k || '=' || v) from " &
      "(select k, v from t order by k);").output.strip() == "a=1,b=2"

    # THE BYTES DIFFER, because the implicit rowid is assigned in insertion
    # order and is part of the page image.
    check readFile(first) != readFile(second)
    check runSqlite(first, "select group_concat(rowid || ':' || k) from " &
      "(select rowid, k from t order by k);").output.strip() == "1:a,2:b"
    check runSqlite(second, "select group_concat(rowid || ':' || k) from " &
      "(select rowid, k from t order by k);").output.strip() == "2:a,1:b"

    # AND VACUUM DOES NOT LAUNDER IT: `vacuum` repacks the file and
    # preserves rowids, so the normalisation a reader would reach for first
    # does not produce the property either.
    let firstVacuum = dir / "first-vacuum.sqlite"
    let secondVacuum = dir / "second-vacuum.sqlite"
    check runSqlite(first,
      "vacuum into " & encodeText(firstVacuum) & ";").ok
    check runSqlite(second,
      "vacuum into " & encodeText(secondVacuum) & ";").ok
    check readFile(firstVacuum) != readFile(secondVacuum)

    # THE CANONICAL FORM SEES THROUGH EXACTLY THAT AND NOTHING ELSE.
    check digestOf(first) == digestOf(second)
    check digestOf(firstVacuum) == digestOf(first)

  test "the canonical form notices every difference it is asked to carry":
    # A digest that could not tell two databases apart would satisfy the
    # identity clause by being blind, so each arm below changes ONE thing
    # and requires the digest to move.
    let dir = scratchDir("canon")
    defer: removeDir(dir)
    let base = dir / "base.sqlite"
    const ddl = "create table t (k text primary key, v, w text);"
    check runSqlite(base, ddl &
      "insert into t values ('a', 1, null);" &
      "insert into t values ('b', 2, 'x');").ok
    let baseDigest = digestOf(base)
    check baseDigest.len == 64

    proc variant(name, sql: string): string =
      let path = dir / (name & ".sqlite")
      check runSqlite(path, ddl &
        "insert into t values ('a', 1, null);" &
        "insert into t values ('b', 2, 'x');" & sql).ok
      digestOf(path)

    # One extra row.
    check variant("extra", "insert into t values ('c', 3, 'y');") !=
      baseDigest
    # One changed cell.
    check variant("changed", "update t set w = 'z' where k = 'b';") !=
      baseDigest
    # NULL against the EMPTY STRING, which is the direction a decoder that
    # rendered "anything it could not make a value of" as absent would miss.
    check variant("empty", "update t set w = '' where k = 'a';") != baseDigest
    # THE INTEGER AGAINST ITS OWN TEXT. Same characters, different storage
    # class; a rendering without `typeof` would hash them alike.
    check variant("text", "update t set v = '1' where k = 'a';") != baseDigest
    # A moved schema version.
    check variant("version", "pragma user_version = 7;") != baseDigest
    # A new schema object with no rows of its own.
    check variant("index", "create index t_by_v on t(v);") != baseDigest
    # A TABLE NOTHING IN RUNQUOTA HAS EVER HEARD OF. This is the discovery
    # claim: the dump walks `sqlite_master`, so a table added by a later
    # migration or arriving with a merge is covered the day it exists.
    let unknown = variant("unknown",
      "create table nobody_declared_this (x integer); " &
      "insert into nobody_declared_this values (1);")
    check unknown != baseDigest
    check "nobody_declared_this" in canonicalDump(dir / "unknown.sqlite").tables

    # THE NEGATIVE CONTROL, without which every arm above is satisfied by a
    # digest that simply changes whenever anything is touched: the same
    # content written in a different order, and vacuumed, is the SAME.
    let reordered = dir / "reordered.sqlite"
    check runSqlite(reordered, ddl &
      "insert into t values ('b', 2, 'x');" &
      "insert into t values ('a', 1, null);").ok
    check digestOf(reordered) == baseDigest
    check readFile(reordered) != readFile(base)

  test "merging the same source twice is merging it once":
    let dir = scratchDir("idempotent")
    defer: removeDir(dir)
    let source = dir / "a.sqlite"
    discard sourceA(source)

    let seed = pristine(dir)
    let onceStore = copyOfPristine(seed, dir / "once.sqlite")
    let twiceStore = copyOfPristine(seed, dir / "twice.sqlite")
    # THE SHARED STARTING POINT, asserted. Without it the comparison below
    # is between two databases that were never the same.
    check digestOf(dir / "once.sqlite") == digestOf(dir / "twice.sqlite")

    let first = onceStore.mergeObservationStore(source)
    check first.outcome == moMerged
    check first.hostsAdded == 1
    check first.hostProfilesAdded == 1
    check first.runsAdded == 1
    check first.executionsAdded == 3
    check first.extensionRowsAdded == 3
    check first.knownExtensions == @[knownId]
    check first.carriedExtensions == @[alienId]
    check first.carriedRowsAdded == 3

    check twiceStore.mergeObservationStore(source).outcome == moMerged
    let second = twiceStore.mergeObservationStore(source)
    check second.outcome == moMerged
    # THE SECOND PASS ADDS NOTHING. Reported as zero rather than inferred
    # from the digest, so "idempotent" is a statement about the merge and
    # not only about the comparison.
    check second.executionsAdded == 0
    check second.extensionRowsAdded == 0
    check second.carriedRowsAdded == 0

    check digestOf(dir / "twice.sqlite") == digestOf(dir / "once.sqlite")
    # AND THE CONTROL: an untouched copy of the same starting point is not
    # equal to a merged one, so the equality above is not the equality of
    # two things that never moved.
    let empty = copyOfPristine(seed, dir / "empty.sqlite")
    check empty.captureEnabled
    check digestOf(dir / "empty.sqlite") != digestOf(dir / "once.sqlite")

  test "two sources merge to the same database in either order":
    let dir = scratchDir("order")
    defer: removeDir(dir)
    let a = dir / "a.sqlite"
    let b = dir / "b.sqlite"
    discard sourceA(a)
    discard sourceB(b)

    let seed = pristine(dir)
    let forwardPath = dir / "forward.sqlite"
    let backwardPath = dir / "backward.sqlite"
    let forward = copyOfPristine(seed, forwardPath)
    let backward = copyOfPristine(seed, backwardPath)
    check digestOf(forwardPath) == digestOf(backwardPath)

    check forward.mergeObservationStore(a).outcome == moMerged
    check forward.mergeObservationStore(b).outcome == moMerged
    check backward.mergeObservationStore(b).outcome == moMerged
    check backward.mergeObservationStore(a).outcome == moMerged

    # Both sources really arrived: two hosts, five executions, and rows in
    # both halves of the extension story.
    check forward.readHosts().len == 2
    check forward.readExecutions().len == 5
    check backward.readHosts().len == 2
    check backward.readExecutions().len == 5

    check digestOf(forwardPath) == digestOf(backwardPath)

    # THE REGISTRY IS NOT MERGED, AND THIS IS WHERE THAT IS ASSERTED
    # DIRECTLY RATHER THAN LEFT TO THE DIGEST. Copying a source's
    # `extension_registry` row would make the receiver claim to know a
    # schema it does not have — but it would ALSO be order-independent,
    # because `insert or ignore` is, so the equality above cannot see it.
    # A decision the module's header says it makes needs an assertion of
    # its own, not a comparison that happens to be insensitive to it.
    let registry = forward.readExtensionRegistry()
    check registry.len == 1
    check registry[0].extensionId == knownId
    check registry[0].schemaVersion == 1
    check backward.readExtensionRegistry() == registry
    # The control: the sources really did carry registry rows the receiver
    # would have picked up, including one for an extension it has never
    # heard of and one at a version it cannot store.
    let sourceRegistry = openObservationStore(a).readExtensionRegistry()
    check sourceRegistry.len == 2
    check openObservationStore(b).readExtensionRegistry()[0].schemaVersion == 2

    # THE CONTROLS. One source alone is a different database, so the
    # equality above is not two empty stores agreeing.
    let onlyA = copyOfPristine(seed, dir / "only-a.sqlite")
    check onlyA.mergeObservationStore(a).outcome == moMerged
    check digestOf(dir / "only-a.sqlite") != digestOf(forwardPath)

    # AND THE BYTES ARE NOT THE IDENTITY, recorded here at the exact place
    # the gate asks for byte-identity rather than left to the note at the
    # top of the file.
    check readFile(forwardPath) != readFile(backwardPath)

  test "an extension schema the receiver does not know is carried, not dropped":
    let dir = scratchDir("carry")
    defer: removeDir(dir)
    let a = dir / "a.sqlite"
    let b = dir / "b.sqlite"
    discard sourceA(a)
    discard sourceB(b)
    let path = dir / "dest.sqlite"
    let store = receiver(path)

    check store.mergeObservationStore(a).outcome == moMerged
    check store.mergeObservationStore(b).outcome == moMerged

    # THE KNOWN HALF IS QUERYABLE AND COMPLETE: source A declared
    # `m15m_known` at the version the receiver carries, so its rows went
    # into the real table.
    check store.extensionRowCount(knownId) == 3
    check store.readExtensionColumns(knownId, ["known_label"]) ==
      @[@["ka-1"], @["ka-2"], @["ka-3"]]

    # THE UNKNOWN HALVES ARE NOT THERE, AND THAT IS THE POINT OF THE
    # CLAUSE. Source B's rows were shaped for a version this database has
    # no route to; inserting the columns it happened to recognise would
    # have left a row reading afterwards as a complete observation with the
    # v2 column silently gone.
    check "kb-1" notin $store.readExtensionColumns(knownId, ["known_label"])
    check not store.extensionTableExists(extensionTableName(alienId))
    check store.extensionRegistryEntry(alienId).isNone

    # THEY ARE CARRIED, WHOLE. Source A's alien rows and source B's newer
    # rows are both in quarantine, with the column NAMES and the values the
    # source held.
    let alien = store.carriedExtensionRows(alienId)
    check alien.len == 3
    check "alien_label=text:" in alien[0]
    let carriedKnown = store.carriedExtensionRows(knownId)
    check carriedKnown.len == 2
    check "known_label=text:" in carriedKnown[0]
    # THE COLUMN A LOSSY MERGE WOULD HAVE DROPPED, present with its value.
    check "known_weight=real:" in carriedKnown[0]
    check "known_weight=real:" in carriedKnown[1]
    check carriedKnown[0] != carriedKnown[1]

    # MARKED UNQUERYABLE, STRUCTURALLY. The column is pinned by a check
    # constraint, so no row anywhere can claim otherwise — not even one
    # written by a client reaching past this library.
    let flags = store.runQuery("select distinct queryable from " &
      carriedExtensionTable & ";")
    check flags.len == 1
    check flags[0][0].strip() == "0"
    check not store.runStatement("update " & carriedExtensionTable &
      " set queryable = 1;")
    check "constraint" in store.lastError.toLowerAscii
    check store.captureEnabled

    # AND THE RETENTION CASCADE REACHES THEM. A carried row is a fact about
    # an execution; leaving it behind when its parent goes would orphan a
    # row no query can reach and no later pass would find.
    let before = store.runQuery("select count(*) from " &
      carriedExtensionTable & ";")
    check before[0][0].strip() == "5"
    var policy = noRetention()
    policy.maxExecutionAgeMillis = some(1'i64)
    let pruned = store.applyRetention("host-b", 10_000, policy)
    check pruned.applied
    check pruned.executionsRemoved == 2
    check pruned.carriedRowsRemoved == 2
    check store.carriedExtensionRows(knownId).len == 0
    check store.carriedExtensionRows(alienId).len == 3
    check store.orphanReport().orphans == 0

  test "a merge without the host and hardware dimension is refused":
    let dir = scratchDir("refuse")
    defer: removeDir(dir)
    let path = dir / "dest.sqlite"
    let store = receiver(path)

    # A SOURCE WHOSE EXECUTIONS CARRY NO HARDWARE PROFILE. This is not a
    # malformed file: it is exactly what a store written before host
    # profiles existed looks like, and every column in it is valid.
    let unqualified = dir / "unqualified.sqlite"
    block:
      let source = openObservationStore(unqualified)
      check source.captureEnabled
      seedSpine(source, "host-u", "pu", qualified = false)
      check source.insertExecution(ExecutionRow(executionId: "u-exec-1",
        hostId: "host-u", hostProfileId: none(string), runId: "run-host-u",
        commandStatsId: "c", startedAtUnixMillis: 1_000,
        finishedAtUnixMillis: 1_001, durationMillis: 1, exitStatus: 0,
        termination: tExited, attempt: 1, peakRssBytes: 0, maxProcesses: 1,
        majorPageFaults: 0, captureCompleteness: ccComplete))

    let beforeDigest = digestOf(path)
    let refusal = store.mergeObservationStore(unqualified)
    check refusal.outcome == moRefusedNoHostDimension
    check "hardware profile" in refusal.detail
    # REFUSED BEFORE ANYTHING WAS WRITTEN: not one row of that source is in
    # the destination, and the destination is byte-for-byte the database it
    # was.
    check refusal.hostsAdded == 0
    check refusal.executionsAdded == 0
    check digestOf(path) == beforeDigest
    check store.readHosts().len == 0
    check store.captureEnabled

    # A SOURCE WITH NO `hosts` TABLE AT ALL — the other way to lose the
    # dimension, and one no library call can produce.
    let headless = dir / "headless.sqlite"
    block:
      let source = openObservationStore(headless)
      check source.captureEnabled
      seedSpine(source, "host-h", "ph")
      check source.insertExecution(execution("host-h", "ph", "h-exec-1", 1000))
    check runSqlite(headless,
      "pragma foreign_keys = off;\ndrop table hosts;").ok
    let headlessRefusal = store.mergeObservationStore(headless)
    check headlessRefusal.outcome == moRefusedNoHostDimension
    check "hosts" in headlessRefusal.detail
    check digestOf(path) == beforeDigest

    # A SOURCE NAMING A PROFILE THAT IS NOT THERE.
    let danglingProfile = dir / "dangling.sqlite"
    block:
      let source = openObservationStore(danglingProfile)
      check source.captureEnabled
      seedSpine(source, "host-d", "pd")
      check source.insertExecution(execution("host-d", "pd", "d-exec-1", 1000))
      check source.runStatement(
        "pragma foreign_keys = off;\ndelete from host_profiles;")
    let danglingRefusal = store.mergeObservationStore(danglingProfile)
    check danglingRefusal.outcome == moRefusedNoHostDimension
    check "not there" in danglingRefusal.detail
    check digestOf(path) == beforeDigest

    # THE CONVERSE, WITHOUT WHICH "REFUSE EVERYTHING" WOULD PASS. A source
    # that DOES carry the dimension merges, from the same receiver, right
    # after three refusals.
    let good = dir / "good.sqlite"
    discard sourceA(good)
    check store.mergeObservationStore(good).outcome == moMerged
    check store.readExecutions().len == 3
    check digestOf(path) != beforeDigest

  test "merging needs no daemon on either side, and refuses what it cannot read":
    # "Merging MUST be possible without a live daemon on either side" — two
    # paths, no socket, no rendezvous directory, no lease authority. The
    # entry point that says so in its signature is the one used here.
    let dir = scratchDir("daemonless")
    defer: removeDir(dir)
    let a = dir / "a.sqlite"
    let dest = dir / "dest.sqlite"
    discard sourceA(a)
    discard receiver(dest)

    let report = mergeObservationStores(dest, a)
    check report.outcome == moMerged
    check report.executionsAdded == 3

    # A source that is not there, and one that is not a database.
    check mergeObservationStores(dest, dir / "absent.sqlite").outcome ==
      moSourceUnreadable
    let garbage = dir / "garbage.sqlite"
    writeFile(garbage, "this is not a database, it is a sentence")
    check mergeObservationStores(dest, garbage).outcome == moSourceUnreadable

    # A source written by a NEWER RunQuota is refused rather than read
    # wrong, which is the same refusal `openObservationStore` makes.
    let newer = dir / "newer.sqlite"
    discard sourceA(newer)
    check runSqlite(newer,
      "pragma user_version = " & $(spineSchemaVersion + 3) & ";").ok
    let refused = mergeObservationStores(dest, newer)
    check refused.outcome == moRefusedNewerSchema
    check $(spineSchemaVersion + 3) in refused.detail

    # And a destination that is not open answers "unavailable" rather than
    # failing: OS-4 reaches this path too.
    check mergeObservationStores(dir / "nothing" / "x.sqlite", a).outcome ==
      moMerged  # a destination is CREATED, which is not the same as broken
    check runSqlite(dest,
      "pragma user_version = " & $(spineSchemaVersion + 1) & ";").ok
    check mergeObservationStores(dest, a).outcome == moUnavailable
