## Schema version 6: the `users` table, and every path that writes one.
##
## `executions.owner_uid` is the uid on POSIX and the hash of the token user
## SID on Windows (`runquota_core/owner_id`); `users` records, once per
## owner, the principal the id was derived from and a name to show for it.
## What is asserted here, each with the control that makes it falsifiable:
##
## * the SCHEMA refuses what must never happen -- an execution naming an
##   owner with no row, a second principal under an existing id, a deleted
##   owner that rows still reference, a Windows id in the POSIX range;
## * a RENAME refreshes the name and stamps it, leaves `owner_uid` alone,
##   and an account that stops resolving keeps its last known name. The
##   rename is driven through the daemon's own ledger (`runquota_daemon/
##   owners`) with a resolver whose answer the test changes -- no real
##   account is renamed;
## * the version-6 MIGRATION gives every existing owner a row and turns the
##   `0` every pre-fix Windows daemon recorded into NULL, without touching a
##   real uid 0 from a POSIX host;
## * MERGE carries owners, collapses identical principals, is independent of
##   order, refuses a collision naming both principals, and migrates an
##   older source on a private copy without writing the source;
## * EXPORT redacts the name and says so in its manifest.

import std/[options, os, strutils, times, unittest]

import runquota_core/owner_id
import runquota_ipc
import runquota_observation_store
import runquota_daemon/owners

proc scratchDir(name: string): string =
  result = getTempDir() / ("rq-users-" & name & "-" & $getCurrentProcessId() &
    "-" & $int64(epochTime() * 1000.0))
  removeDir(result)
  createDir(result)

proc hardwareRow(hostId, profileId, osName: string): HostProfileRow =
  let hardware = HardwareProfile(
    cpuModel: "Users Fixture 4", physicalCores: 4, logicalCores: 4,
    ramBytes: 8_000_000_000'i64, swapBytes: 0, diskClass: dcSsd,
    fsType: "ntfs", arch: "amd64", os: osName, osVersion: "1",
    kernelVersion: "1", virtualization: "none", cpuShareGroup: "")
  HostProfileRow(
    hostId: hostId, profileId: profileId,
    profileHash: profileHash(hardware),
    validFromUnixMillis: 1, validToUnixMillis: none(int64),
    cpuModel: hardware.cpuModel, physicalCores: hardware.physicalCores,
    logicalCores: hardware.logicalCores, ramBytes: hardware.ramBytes,
    swapBytes: hardware.swapBytes, diskClass: hardware.diskClass,
    fsType: hardware.fsType, arch: hardware.arch, os: hardware.os,
    osVersion: hardware.osVersion, kernelVersion: hardware.kernelVersion,
    virtualization: hardware.virtualization,
    cpuShareGroup: hardware.cpuShareGroup)

proc execution(hostId, profileId, id: string;
               owner: Option[int64]): ExecutionRow =
  ExecutionRow(
    executionId: id, hostId: hostId, hostProfileId: some(profileId),
    runId: "run-" & hostId, commandStatsId: "key-" & id,
    leaseId: none(int64), startedAtUnixMillis: 5_000,
    finishedAtUnixMillis: 5_100, durationMillis: 100, exitStatus: 0,
    termination: tExited, attempt: 1, retryOf: none(string),
    peakRssBytes: 1_000, cpuUserMillis: none(int64),
    cpuSysMillis: none(int64), maxProcesses: 1, majorPageFaults: 0,
    ioReadBytes: none(int64), ioWriteBytes: none(int64),
    captureCompleteness: ccComplete, droppedObservations: 0,
    ownerUid: owner)

proc hostFixture(store: ObservationStore; hostId, osName: string) =
  doAssert store.insertHost(HostRow(hostId: hostId, createdAtUnixMillis: 1,
    lastBootId: "boot")), store.lastError
  doAssert store.insertHostProfile(hardwareRow(hostId, "profile-" & hostId,
    osName)), store.lastError
  doAssert store.insertRun(RunRow(runId: "run-" & hostId, hostId: hostId,
    tool: "users-fixture", toolVersion: "1", invocationKind: "test",
    startedAtUnixMillis: 1, captureCompleteness: ccComplete,
    droppedObservations: 0)), store.lastError

const
  AliceSid = "S-1-5-21-1111111111-2222222222-3333333333-1001"
  BobSid = "S-1-5-21-1111111111-2222222222-3333333333-1002"

var resolverAnswer = none(string)
  ## THE SEAM. The daemon's ledger takes its resolver as a parameter; this
  ## one answers whatever the test last put here.

proc fixtureResolver(principal: OwnerPrincipal): Option[string] {.
    nimcall, gcsafe.} =
  {.cast(gcsafe).}:
    resolverAnswer

proc sidPeer(sid: string): PeerIdentity =
  PeerIdentity(kind: peerIdentityProcess, processId: 42,
    userId: uint64(ownerIdFromSid(sid)), groupId: 0, sid: sid)

proc hello(ledger: var OwnerLedger; store: ObservationStore; peer: PeerIdentity;
           atUnixMillis: int64): string =
  ## One Hello, the way the daemon handles it: observe the peer (resolving
  ## its name through the seam), decide, and apply what was decided. The
  ## daemon queues the statement on its writer; here it is applied to the
  ## store directly, which is the same SQL.
  let observed = observePeerOwner(peer, fixtureResolver)
  doAssert observed.principal.isSome
  let decision = ledger.decide(observed.principal.get, observed.name,
    atUnixMillis, captureEnabled = true)
  if decision.refusal.len > 0:
    return decision.refusal
  if decision.statement.len > 0:
    doAssert store.runStatement(decision.statement), store.lastError
    ledger.confirm(observed.principal.get, observed.name)
  ""

proc countOf(path, sql: string): int64 =
  let outcome = runSqlite(path, sql)
  doAssert outcome.ok, outcome.error
  parseBiggestInt(outcome.output.strip())

suite "observation_store_users":

  test "the schema refuses an unowned execution, a collision, and a Windows id in the uid range":
    let dir = scratchDir("schema")
    defer: removeDir(dir)
    let path = dir / "observations.sqlite3"
    let store = openObservationStore(path)
    check store.captureEnabled
    check store.schemaVersion == 6
    store.hostFixture("host-a", "windows")
    let alice = ownerIdFromSid(AliceSid)

    # AN EXECUTION MAY NOT NAME AN OWNER NOBODY RECORDED...
    check not store.insertExecution(execution("host-a", "profile-host-a",
      "e1", some(alice)))
    check "names no users row" in store.lastError
    check store.captureEnabled   # a refused row is not a broken store
    # ...and may once the owner is recorded. The control: same row, accepted.
    check store.recordUser(alice, pkSid, AliceSid, some("HOST\\alice"), 10)
    check store.insertExecution(execution("host-a", "profile-host-a", "e1",
      some(alice)))
    # An absent owner needs no row: NULL is "unknown", not a reference.
    check store.insertExecution(execution("host-a", "profile-host-a", "e2",
      none(int64)))

    # A SECOND PRINCIPAL UNDER AN EXISTING ID is a collision, and it fails
    # loudly rather than being skipped: two accounts may not share a scope.
    check not store.recordUser(alice, pkSid, BobSid, some("HOST\\bob"), 20)
    check "collision" in store.lastError
    let kept = store.userRow(alice)
    check kept.isSome
    check kept.get.principal == AliceSid
    check kept.get.name == some("HOST\\alice")

    # A REFERENCED OWNER IS NEVER DELETED.
    check not store.runStatement("delete from users where owner_uid = " &
      $alice & ";")
    check store.userRow(alice).isSome

    # THE RANGES ARE STRUCTURAL: a SID-derived id below 2^62, a uid above
    # 2^32, and a uid whose principal is not its own decimal are refused.
    check not store.recordUser(4242, pkSid, BobSid, none(string), 30)
    check not store.recordUser(sidOwnerIdFloor, pkUid, $sidOwnerIdFloor,
      none(string), 30)
    check not store.recordUser(4242, pkUid, "4243", none(string), 30)
    # And the well-formed ones are accepted, so the refusals are about the
    # values rather than about recordUser.
    check store.recordUser(4242, pkUid, "4242", none(string), 30)
    check store.recordUser(ownerIdFromSid(BobSid), pkSid, BobSid,
      none(string), 30)

  test "a rename refreshes the name, stamps it, never touches owner_uid, and an unresolvable account keeps its name":
    let dir = scratchDir("rename")
    defer: removeDir(dir)
    let store = openObservationStore(dir / "observations.sqlite3")
    check store.captureEnabled
    var ledger = initOwnerLedger()
    let peer = sidPeer(AliceSid)
    let alice = ownerIdFromSid(AliceSid)

    # FIRST SIGHTING: the row is written with the name the resolver gave.
    resolverAnswer = some("CORP\\alice")
    check ledger.hello(store, peer, 1_000) == ""
    var row = store.userRow(alice)
    check row.isSome
    check row.get.principal == AliceSid
    check row.get.principalKind == pkSid
    check row.get.name == some("CORP\\alice")
    check row.get.firstSeenAtUnixMillis == 1_000
    check row.get.nameUpdatedAtUnixMillis == some(1_000'i64)
    check ledger.records == 1

    # THE SAME NAME AGAIN writes nothing: no spurious refresh, no stamp.
    check ledger.hello(store, peer, 2_000) == ""
    check ledger.records == 1
    check store.userRow(alice).get.nameUpdatedAtUnixMillis == some(1_000'i64)

    # THE RENAME. The resolver now answers a different name for the same
    # SID; the row's name follows, is stamped, and the key does not move.
    resolverAnswer = some("CORP\\alice.smith")
    check ledger.hello(store, peer, 3_000) == ""
    check ledger.records == 2
    row = store.userRow(alice)
    check row.get.ownerUid == alice
    check row.get.principal == AliceSid
    check row.get.name == some("CORP\\alice.smith")
    check row.get.nameUpdatedAtUnixMillis == some(3_000'i64)
    check row.get.firstSeenAtUnixMillis == 1_000
    check store.readUsers().len == 1

    # THE ACCOUNT STOPS RESOLVING (deleted, or its domain is unreachable):
    # the last known name is kept, not overwritten with NULL.
    resolverAnswer = none(string)
    check ledger.hello(store, peer, 4_000) == ""
    row = store.userRow(alice)
    check row.get.name == some("CORP\\alice.smith")
    check row.get.nameUpdatedAtUnixMillis == some(3_000'i64)

    # THE UPSERT KEEPS THE SAME RULE ON ITS OWN, for a writer that holds no
    # ledger -- a second daemon life, whose ledger was seeded from the
    # store, or a tool: a NULL name never erases one.
    check store.recordUser(alice, pkSid, AliceSid, none(string), 5_000)
    check store.userRow(alice).get.name == some("CORP\\alice.smith")

    # A LEDGER SEEDED FROM THE STORE -- the daemon's startup -- refreshes a
    # rename it has never seen happen, from the stored name.
    var restarted = initOwnerLedger()
    restarted.seed(store.readUsers())
    resolverAnswer = some("CORP\\asmith")
    check restarted.hello(store, peer, 6_000) == ""
    check store.userRow(alice).get.name == some("CORP\\asmith")
    check store.userRow(alice).get.nameUpdatedAtUnixMillis == some(6_000'i64)

  test "the ledger refuses a principal whose id another principal holds":
    let dir = scratchDir("collide")
    defer: removeDir(dir)
    let store = openObservationStore(dir / "observations.sqlite3")
    var ledger = initOwnerLedger()
    resolverAnswer = some("CORP\\alice")
    check ledger.hello(store, sidPeer(AliceSid), 1_000) == ""
    # A real collision cannot be produced on demand -- that is the point of
    # a 62-bit hash -- so the ledger is handed a principal claiming Alice's
    # id with Bob's SID, which is exactly what a collision would look like.
    let forged = OwnerPrincipal(ownerId: ownerIdFromSid(AliceSid),
      kind: opkSid, principal: BobSid)
    let decision = ledger.decide(forged, some("CORP\\bob"), 2_000, true)
    check decision.refusal.len > 0
    check AliceSid in decision.refusal
    check BobSid in decision.refusal
    check decision.statement.len == 0
    check ledger.collisionsRefused == 1
    check store.userRow(ownerIdFromSid(AliceSid)).get.principal == AliceSid
    # The control: the real Bob, under his own id, is accepted.
    check ledger.hello(store, sidPeer(BobSid), 3_000) == ""
    check ledger.collisionsRefused == 1

  test "version 6 backfills every owner and un-attributes the root a Windows daemon recorded":
    let dir = scratchDir("migrate")
    defer: removeDir(dir)
    let path = dir / "observations.sqlite3"
    # A VERSION-5 STORE, built by the shipped ladder's first five steps --
    # every one of them frozen once shipped -- and filled the way the
    # daemons of that version filled it.
    var ddl = ""
    for step in 0 ..< 5:
      ddl.add(migrations[step] & "\n")
    check runSqlite(path, ddl & "pragma user_version = 5;").ok
    var rows = ""
    for (host, osName) in [("host-linux", "linux"), ("host-win", "windows")]:
      rows.add("insert into hosts values ('" & host & "', 1, 'b');\n")
      rows.add("insert into host_profiles (host_id, profile_id, " &
        "profile_hash, valid_from_unix_millis, cpu_model, physical_cores, " &
        "logical_cores, ram_bytes, swap_bytes, disk_class, fs_type, arch, " &
        "os, os_version, kernel_version, virtualization, cpu_share_group) " &
        "values ('" & host & "', 'p-" & host & "', 'h', 1, 'c', 1, 1, 1, " &
        "0, 'ssd', 'fs', 'amd64', '" & osName & "', '1', '1', 'none', '');\n")
      rows.add("insert into runs (run_id, host_id, tool, tool_version, " &
        "invocation_kind, started_at_unix_millis, capture_completeness) " &
        "values ('r', '" & host & "', 't', '1', 'k', 1, 'complete');\n")
    proc exec(host, id: string; started: int; owner: string): string =
      "insert into executions (execution_id, host_id, host_profile_id, " &
        "run_id, command_stats_id, started_at_unix_millis, " &
        "finished_at_unix_millis, duration_millis, exit_status, " &
        "termination, attempt, peak_rss_bytes, max_processes, " &
        "major_page_faults, capture_completeness, owner_uid) values ('" &
        id & "', '" & host & "', 'p-" & host & "', 'r', 'k', " & $started &
        ", " & $(started + 1) & ", 1, 0, 'exited', 1, 1, 1, 0, 'complete', " &
        owner & ");\n"
    rows.add(exec("host-linux", "l-root", 300, "0"))
    rows.add(exec("host-linux", "l-1000a", 200, "1000"))
    rows.add(exec("host-linux", "l-1000b", 100, "1000"))
    rows.add(exec("host-linux", "l-none", 100, "null"))
    rows.add(exec("host-win", "w-zero-1", 100, "0"))
    rows.add(exec("host-win", "w-zero-2", 100, "0"))
    rows.add(exec("host-win", "w-none", 100, "null"))
    check runSqlite(path, rows).ok

    let store = openObservationStore(path)
    check store.captureEnabled
    check store.schemaVersion == 6

    var owners: seq[(string, Option[int64])] = @[]
    for row in store.readExecutions():
      owners.add((row.executionId, row.ownerUid))
    # THE WINDOWS ZEROS ARE GONE: they were never a credential.
    check ("w-zero-1", none(int64)) in owners
    check ("w-zero-2", none(int64)) in owners
    check ("w-none", none(int64)) in owners
    # THE REAL ROOT from a POSIX host is untouched -- the control that the
    # repair is about Windows rows and not about the value 0.
    check ("l-root", some(0'i64)) in owners
    check ("l-1000a", some(1000'i64)) in owners
    check ("l-none", none(int64)) in owners

    # EVERY REMAINING OWNER HAS A ROW, first seen at its earliest execution,
    # with no name yet: the daemon fills it in when that user connects.
    let users = store.readUsers()
    check users.len == 2
    for user in users:
      check user.principalKind == pkUid
      check user.principal == $user.ownerUid
      check user.name.isNone
      check user.nameUpdatedAtUnixMillis.isNone
    check store.userRow(1000).get.firstSeenAtUnixMillis == 100
    check store.userRow(0).get.firstSeenAtUnixMillis == 300
    # And executions are still immutable after the one statement that had
    # to edit them.
    check not store.runStatement(
      "update executions set duration_millis = 2 where execution_id = 'l-root';")
    check "immutable" in store.lastError

  test "merge carries owners, collapses one principal seen twice, and does not depend on order":
    let dir = scratchDir("merge")
    defer: removeDir(dir)
    let alice = ownerIdFromSid(AliceSid)
    # Two hosts saw Alice, at different times and under different names.
    let a = openObservationStore(dir / "a.sqlite3")
    a.hostFixture("host-a", "windows")
    check a.recordUser(alice, pkSid, AliceSid, some("CORP\\alice"), 1_000)
    check a.insertExecution(execution("host-a", "profile-host-a", "ea",
      some(alice)))
    let b = openObservationStore(dir / "b.sqlite3")
    b.hostFixture("host-b", "windows")
    check b.recordUser(alice, pkSid, AliceSid, some("CORP\\alice.smith"),
      500)
    check b.recordUser(alice, pkSid, AliceSid, some("CORP\\alice.smith2"),
      3_000)
    check b.recordUser(4242, pkUid, "4242", none(string), 700)
    check b.insertExecution(execution("host-b", "profile-host-b", "eb",
      some(alice)))

    let ab = openObservationStore(dir / "ab.sqlite3")
    let ba = openObservationStore(dir / "ba.sqlite3")
    check ab.mergeObservationStore(dir / "a.sqlite3").outcome == moMerged
    let second = ab.mergeObservationStore(dir / "b.sqlite3")
    check second.outcome == moMerged
    check second.usersAdded == 1   # 4242 is new; Alice collapsed
    check ba.mergeObservationStore(dir / "b.sqlite3").outcome == moMerged
    check ba.mergeObservationStore(dir / "a.sqlite3").outcome == moMerged

    # ONE ROW FOR ONE PRINCIPAL, first seen at the earliest sighting, named
    # by the latest rename.
    let merged = ab.userRow(alice)
    check merged.isSome
    check merged.get.principal == AliceSid
    check merged.get.firstSeenAtUnixMillis == 500
    check merged.get.name == some("CORP\\alice.smith2")
    check merged.get.nameUpdatedAtUnixMillis == some(3_000'i64)
    check ab.readUsers().len == 2
    check ab.readExecutions().len == 2
    # EITHER ORDER, THE SAME DATABASE.
    check canonicalDigest(dir / "ab.sqlite3") ==
      canonicalDigest(dir / "ba.sqlite3")

    # A redacted export of a store does not replace a readable name it is
    # merged into: a readable name outranks a redaction token.
    let exported = exportObservationStore(dir / "a.sqlite3",
      dir / "a-export.sqlite3", rpDefault)
    check exported.outcome == xoExported
    let c = openObservationStore(dir / "c.sqlite3")
    check c.mergeObservationStore(dir / "a-export.sqlite3").outcome ==
      moMerged
    check c.userRow(alice).get.name.get.startsWith("[redacted:owner-name:")
    check c.mergeObservationStore(dir / "a.sqlite3").outcome == moMerged
    check c.userRow(alice).get.name == some("CORP\\alice")

  test "merge refuses an owner id two principals claim, before writing anything":
    let dir = scratchDir("merge-collision")
    defer: removeDir(dir)
    let alice = ownerIdFromSid(AliceSid)
    let a = openObservationStore(dir / "a.sqlite3")
    a.hostFixture("host-a", "windows")
    check a.recordUser(alice, pkSid, AliceSid, some("CORP\\alice"), 1_000)
    # The source is FORGED into the state a collision would produce: Bob's
    # SID under Alice's id. The schema's own checks do not forbid that --
    # only the preimage could, and it is not reversible.
    let b = openObservationStore(dir / "b.sqlite3")
    b.hostFixture("host-b", "windows")
    check b.recordUser(alice, pkSid, BobSid, some("CORP\\bob"), 2_000)
    check b.insertExecution(execution("host-b", "profile-host-b", "eb",
      some(alice)))
    let before = canonicalDigest(dir / "a.sqlite3")
    let report = a.mergeObservationStore(dir / "b.sqlite3")
    check report.outcome == moRefusedOwners
    check "collision" in report.detail
    check AliceSid in report.detail
    check BobSid in report.detail
    check canonicalDigest(dir / "a.sqlite3") == before
    check countOf(dir / "a.sqlite3", "select count(*) from executions;") == 0

  test "an older source is migrated on a private copy and the source is not written":
    let dir = scratchDir("merge-older")
    defer: removeDir(dir)
    let source = dir / "v5.sqlite3"
    var ddl = ""
    for step in 0 ..< 5:
      ddl.add(migrations[step] & "\n")
    check runSqlite(source, ddl &
      "insert into hosts values ('host-old', 1, 'b');\n" &
      "insert into host_profiles (host_id, profile_id, profile_hash, " &
      "valid_from_unix_millis, cpu_model, physical_cores, logical_cores, " &
      "ram_bytes, swap_bytes, disk_class, fs_type, arch, os, os_version, " &
      "kernel_version, virtualization, cpu_share_group) values " &
      "('host-old', 'p', 'h', 1, 'c', 1, 1, 1, 0, 'ssd', 'fs', 'amd64', " &
      "'linux', '1', '1', 'none', '');\n" &
      "insert into runs (run_id, host_id, tool, tool_version, " &
      "invocation_kind, started_at_unix_millis, capture_completeness) " &
      "values ('r', 'host-old', 't', '1', 'k', 1, 'complete');\n" &
      "insert into executions (execution_id, host_id, host_profile_id, " &
      "run_id, command_stats_id, started_at_unix_millis, " &
      "finished_at_unix_millis, duration_millis, exit_status, termination, " &
      "attempt, peak_rss_bytes, max_processes, major_page_faults, " &
      "capture_completeness, owner_uid) values ('e-old', 'host-old', 'p', " &
      "'r', 'k', 10, 11, 1, 0, 'exited', 1, 1, 1, 0, 'complete', 1000);\n" &
      "pragma user_version = 5;").ok
    let sourceBytes = readFile(source)

    let destination = openObservationStore(dir / "dest.sqlite3")
    let report = destination.mergeObservationStore(source)
    check report.outcome == moMerged
    check report.executionsAdded == 1
    check report.usersAdded == 1
    check destination.userRow(1000).get.principal == "1000"
    # THE SOURCE WAS ONLY READ: same bytes, same version, and no copy left
    # behind beside the destination.
    check readFile(source) == sourceBytes
    check countOf(source, "pragma user_version;") == 5
    for kind, file in walkDir(dir):
      check "merge-source" notin file

  test "export redacts owner names from default upward and records it":
    let dir = scratchDir("export")
    defer: removeDir(dir)
    let source = dir / "local.sqlite3"
    let store = openObservationStore(source)
    store.hostFixture("host-a", "windows")
    let alice = ownerIdFromSid(AliceSid)
    check store.recordUser(alice, pkSid, AliceSid, some("CORP\\alice"), 1_000)
    for policy in [rpNone, rpDefault, rpStrict]:
      let destination = dir / ("export-" & $policy & ".sqlite3")
      let report = exportObservationStore(source, destination, policy)
      check report.outcome == xoExported
      let exported = openObservationStore(destination)
      let row = exported.userRow(alice)
      check row.isSome
      # The key and its preimage travel unredacted under every policy:
      # merge compares the principal to refuse collisions.
      check row.get.principal == AliceSid
      let manifest = readExportManifest(destination)
      check manifest.ok
      if policy == rpNone:
        check row.get.name == some("CORP\\alice")
        check rcOwnerName notin manifest.categories
      else:
        check row.get.name.get.startsWith("[redacted:owner-name:")
        check "alice" notin row.get.name.get
        check rcOwnerName in manifest.categories
        check manifest.counts[rcOwnerName] == 1
