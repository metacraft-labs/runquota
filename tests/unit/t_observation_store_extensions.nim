## M12 gate, the behavioural half: a synthetic extension registers, writes
## rows, migrates its schema INDEPENDENTLY OF THE SPINE, and has its rows
## pruned when the parent execution is pruned. The refusal clause — a
## client declaring a version this database cannot store is refused rather
## than silently mis-stored — is asserted here too, together with its
## converse. The inspection clause is
## ``t_observation_store_extension_boundary``.
##
## No mocks: real SQLite files, written by `sqlite3` and read back by the
## same code the daemon uses. The extension is SYNTHETIC on purpose. The
## two extensions that will really exist — the generic test-execution layer
## and Reprobuild's action layer — are M17 and M19, and building the
## mechanism against one of them would let that one product's shape decide
## what the mechanism can express. ``m12_probe`` exists only here.
##
## THE TRAP THIS FILE IS WRITTEN AROUND. "The extension migrates
## independently of the spine" is not shown by bumping both: a mechanism
## that migrated the two together would pass that. It is shown by the two
## arms of "an extension moves while the spine stands still" and "the spine
## moves while the extension stands still", and both are here, each
## asserting that the OTHER schema's version and DDL text are unchanged
## across the migration.

import std/[options, os, strutils, times, unittest]

import runquota_observation_store

proc scratchDir(name: string): string =
  result = getTempDir() / ("rq-m12-" & name & "-" &
    $getCurrentProcessId() & "-" & $epochTime())
  removeDir(result)
  createDir(result)

# ---------------------------------------------------------------------------
# The synthetic extension
# ---------------------------------------------------------------------------
#
# Version 1 is a `create table`; version 2 adds one column. That is the
# whole ladder, and it is deliberately the smallest thing that can move on
# its own: what is under test is the MECHANISM, and a richer schema would
# only give the assertions more to be about.

const
  probeId = "m12_probe"
  probeOwner = "runquota-m12"

  probeV1Ddl = """
create table ext_m12_probe (
  host_id text not null,
  execution_id text not null,
  probe_label text not null,
  probe_count integer not null,
  primary key (host_id, execution_id),
  foreign key (host_id, execution_id)
    references executions(host_id, execution_id)
);
"""

  probeV2Step = """
alter table ext_m12_probe add column probe_weight real;
"""

  # An extension table with no spine key and no foreign key. The
  # specification requires both, and a table without them cannot be joined
  # to an execution or cascaded from one.
  unkeyedDdl = """
create table ext_m12_unkeyed (
  host_id text not null,
  execution_id text not null,
  probe_label text not null
);
"""

  # A second extension, used only to prove the prune is ONE transaction.
  guardDdl = """
create table ext_m12_guard (
  host_id text not null,
  execution_id text not null,
  probe_label text not null,
  primary key (host_id, execution_id),
  foreign key (host_id, execution_id)
    references executions(host_id, execution_id)
);
"""

proc probeV1(): ExtensionDeclaration =
  ExtensionDeclaration(extensionId: probeId, owner: probeOwner,
    schemaVersion: 1, migrations: @[probeV1Ddl])

proc probeV2(): ExtensionDeclaration =
  ExtensionDeclaration(extensionId: probeId, owner: probeOwner,
    schemaVersion: 2, migrations: @[probeV1Ddl, probeV2Step])

proc probeV3WithoutItsStep(): ExtensionDeclaration =
  ## A client that DECLARES version 3 and carries the DDL for two. This is
  ## what "an unknown-newer schema version" is at the extension layer: a
  ## version this database has no route to, because nobody gave it one.
  ExtensionDeclaration(extensionId: probeId, owner: probeOwner,
    schemaVersion: 3, migrations: @[probeV1Ddl, probeV2Step])

proc guardV1(): ExtensionDeclaration =
  ExtensionDeclaration(extensionId: "m12_guard", owner: probeOwner,
    schemaVersion: 1, migrations: @[guardDdl])

# ---------------------------------------------------------------------------
# Spine fixtures
# ---------------------------------------------------------------------------

proc seedSpine(store: ObservationStore; hostId: string) =
  doAssert store.insertHost(HostRow(hostId: hostId, createdAtUnixMillis: 1,
    lastBootId: "boot"))
  doAssert store.insertRun(RunRow(runId: "run-1", hostId: hostId, tool: "t",
    toolVersion: "v", invocationKind: "build", startedAtUnixMillis: 1,
    captureCompleteness: ccComplete))

proc execution(hostId, id: string; startedAt: int64): ExecutionRow =
  ExecutionRow(executionId: id, hostId: hostId, runId: "run-1",
    commandStatsId: "c", startedAtUnixMillis: startedAt,
    finishedAtUnixMillis: startedAt + 1, durationMillis: 1, exitStatus: 0,
    termination: tExited, attempt: 1, peakRssBytes: 0, maxProcesses: 1,
    majorPageFaults: 0, captureCompleteness: ccComplete)

proc probeRow(hostId, executionId, label: string; count: int64): ExtensionRow =
  ExtensionRow(hostId: hostId, executionId: executionId,
    columns: @["probe_label", "probe_count"],
    values: @[extText(label), extInt(count)])

proc tableSql(store: ObservationStore; name: string): string =
  ## The DDL SQLite recorded for a table, verbatim. Comparing this across a
  ## migration is what makes "the other schema did not move" a statement
  ## about the DDL rather than about a version number somebody could have
  ## bumped without touching anything.
  let rows = store.runQuery(
    "select " & selectText("sql") & " from sqlite_master where type = " &
      "'table' and name = " & encodeText(name) & ";")
  if rows.len != 1: "" else: decodeText(rows[0][0])

proc userVersion(path: string): int64 =
  let outcome = runSqlite(path, "pragma user_version;")
  doAssert outcome.ok, outcome.error
  parseBiggestInt(outcome.output.strip())

# The frozen version-1 spine, for the arm where the SPINE moves and the
# extension does not. It is a frozen copy for the same reason
# `t_observation_store_migration` keeps one: a database in the field was
# built by the text as it was, and a fixture that tracked the library would
# stop being evidence the moment the library changed.
const frozenSpineV1 = """
create table hosts (
  host_id text primary key,
  created_at_unix_millis integer not null,
  last_boot_id text not null
);

create table host_profiles (
  host_id text not null references hosts(host_id),
  profile_id text not null,
  profile_hash text not null,
  valid_from_unix_millis integer not null,
  valid_to_unix_millis integer,
  cpu_model text not null,
  physical_cores integer not null,
  logical_cores integer not null,
  ram_bytes integer not null,
  swap_bytes integer not null,
  disk_class text not null
    check (disk_class in ('nvme', 'ssd', 'hdd', 'network', 'unknown')),
  fs_type text not null,
  arch text not null,
  os text not null,
  os_version text not null,
  kernel_version text not null,
  virtualization text not null,
  cpu_share_group text not null,
  primary key (host_id, profile_id)
);

create table runs (
  run_id text not null,
  host_id text not null references hosts(host_id),
  tool text not null,
  tool_version text not null,
  invocation_kind text not null,
  started_at_unix_millis integer not null,
  finished_at_unix_millis integer,
  exit_status integer,
  workspace_id text,
  profile text,
  git_commit text,
  git_branch text,
  capture_completeness text not null
    check (capture_completeness in ('complete', 'sampled', 'degraded')),
  primary key (host_id, run_id)
);

create table executions (
  execution_id text not null,
  host_id text not null references hosts(host_id),
  host_profile_id text,
  run_id text not null,
  command_stats_id text not null
    check (length(cast(command_stats_id as blob)) <= 64),
  lease_id integer,
  started_at_unix_millis integer not null,
  finished_at_unix_millis integer not null,
  duration_millis integer not null,
  exit_status integer not null,
  termination text not null
    check (termination in
      ('exited', 'signalled', 'timeout', 'oom_killed', 'refused')),
  attempt integer not null,
  retry_of text,
  peak_rss_bytes integer not null,
  cpu_user_millis integer,
  cpu_sys_millis integer,
  max_processes integer not null,
  major_page_faults integer not null,
  io_read_bytes integer,
  io_write_bytes integer,
  capture_completeness text not null
    check (capture_completeness in ('complete', 'sampled', 'degraded')),
  primary key (host_id, execution_id),
  foreign key (host_id, run_id) references runs(host_id, run_id),
  foreign key (host_id, host_profile_id)
    references host_profiles(host_id, profile_id)
);

create trigger executions_immutable
before update on executions
begin
  select raise(abort,
    'runquota: executions rows are immutable after write (OS-3)');
end;

create index executions_by_run on executions(host_id, run_id);
create index executions_by_command_stats_id on executions(command_stats_id);

create table ambient_samples (
  host_id text not null references hosts(host_id),
  sampled_at_unix_millis integer not null,
  cpu_busy_pct real not null,
  mem_available_bytes integer not null,
  swap_in_rate real not null,
  io_queue_depth real not null,
  load_avg_1m real not null,
  self_cpu_pct real not null,
  self_rss_bytes integer not null,
  foreign_cpu_pct real not null check (foreign_cpu_pct >= 0),
  foreign_rss_bytes integer not null check (foreign_rss_bytes >= 0),
  primary key (host_id, sampled_at_unix_millis)
);

create table extension_registry (
  extension_id text primary key,
  schema_version integer not null,
  owner text not null,
  table_name text not null check (table_name = 'ext_' || extension_id),
  registered_at_unix_millis integer not null
);
"""

const frozenSpineV1Rows = """
insert into hosts values ('host-v1', 1000, 'boot-v1');
insert into runs values (
  'run-1', 'host-v1', 'repro-build', '0.0.1', 'build', 1000,
  2000, 0, 'ws', 'debug', 'abc123', 'dev', 'complete');
insert into executions values (
  'exec-old', 'host-v1', null, 'run-1', 'stats-v1', 7, 1100, 1900, 800, 0,
  'exited', 1, null, 4096, 10, 2, 3, 5, 64, 128, 'complete');
"""

suite "observation_store_extensions":

  test "a synthetic extension registers, writes rows, and reads them back":
    let dir = scratchDir("register")
    defer: removeDir(dir)
    let store = openObservationStore(dir / "o.sqlite")
    check store.captureEnabled
    seedSpine(store, "host-a")
    check store.insertExecution(execution("host-a", "exec-a", 1000))
    check store.insertExecution(execution("host-a", "exec-b", 2000))

    check store.declareExtension(probeV1()) == eoCreated

    # The registry says what the database carries, and the table name obeys
    # the naming rule the registry's own check constraint enforces.
    let registry = store.readExtensionRegistry()
    check registry.len == 1
    check registry[0].extensionId == probeId
    check registry[0].schemaVersion == 1
    check registry[0].owner == probeOwner
    check registry[0].tableName == extensionTableName(probeId)
    check registry[0].tableName == "ext_m12_probe"
    check store.extensionTableExists("ext_m12_probe")

    check store.insertExtensionRow(probeV1(),
      probeRow("host-a", "exec-a", "alpha", 3)) == ewWritten
    check store.insertExtensionRow(probeV1(),
      probeRow("host-a", "exec-b", "beta", 5)) == ewWritten
    check store.extensionRowCount(probeId) == 2

    let rows = store.readExtensionColumns(probeId,
      ["probe_label", "probe_count"])
    check rows.len == 2
    check rows[0] == @["alpha", "3"]
    check rows[1] == @["beta", "5"]

    # THE JOIN TO THE SPINE IS REAL. A row for an execution that does not
    # exist is refused by the foreign key, so an extension table cannot
    # accumulate facts about work the spine never recorded.
    check store.insertExtensionRow(probeV1(),
      probeRow("host-a", "exec-missing", "orphan", 1)) == ewRejected
    check "constraint" in store.lastError.toLowerAscii
    check store.extensionRowCount(probeId) == 2
    # ... and a rejected row is the caller's problem, not a broken store.
    check store.captureEnabled

    # Declaring the same version again changes nothing.
    check store.declareExtension(probeV1()) == eoUpToDate
    check store.readExtensionRegistry().len == 1

    # An identifier that is not a bare lowercase name is refused before any
    # SQL is built from it.
    var hostile = probeV1()
    hostile.extensionId = "m12 probe\"; drop table executions; --"
    check store.declareExtension(hostile) == eoRefusedIdentifier
    check store.readExecutions().len == 2

    # A table without the spine key and the foreign key is refused, and
    # nothing of it survives: no table, no registry row.
    check store.declareExtension(ExtensionDeclaration(
      extensionId: "m12_unkeyed", owner: probeOwner, schemaVersion: 1,
      migrations: @[unkeyedDdl])) == eoRefusedShape
    check not store.extensionTableExists("ext_m12_unkeyed")
    check store.readExtensionRegistry().len == 1
    check store.captureEnabled

  test "the extension migrates while the spine stands still":
    let dir = scratchDir("extmove")
    defer: removeDir(dir)
    let path = dir / "o.sqlite"
    let store = openObservationStore(path)
    check store.captureEnabled
    seedSpine(store, "host-a")
    check store.insertExecution(execution("host-a", "exec-a", 1000))
    check store.insertExecution(execution("host-a", "exec-b", 2000))
    check store.declareExtension(probeV1()) == eoCreated
    check store.insertExtensionRow(probeV1(),
      probeRow("host-a", "exec-a", "alpha", 3)) == ewWritten

    # Everything about the SPINE, recorded before the extension moves.
    let spineVersionBefore = userVersion(path)
    let executionsSqlBefore = store.tableSql("executions")
    let registrySqlBefore = store.tableSql("extension_registry")
    check spineVersionBefore == spineSchemaVersion
    check executionsSqlBefore.len > 0

    check store.declareExtension(probeV2()) == eoMigrated

    # THE EXTENSION MOVED.
    let registry = store.readExtensionRegistry()
    check registry.len == 1
    check registry[0].schemaVersion == 2
    check "probe_weight" in store.tableSql("ext_m12_probe")

    # THE SPINE DID NOT. Its version is unchanged and so is the recorded
    # DDL of its tables, so this is not a version number that stood still
    # while the schema underneath it moved.
    check userVersion(path) == spineVersionBefore
    check store.tableSql("executions") == executionsSqlBefore
    check store.tableSql("extension_registry") == registrySqlBefore

    # The row written under version 1 survives the migration, and the
    # column version 2 added reads as NULL rather than as a measured zero.
    let migrated = store.readExtensionColumns(probeId,
      ["probe_label", "probe_count", "probe_weight"])
    check migrated.len == 1
    check migrated[0] == @["alpha", "3", nullMarker]

    # A version-2 client writes the new column ...
    check store.insertExtensionRow(probeV2(), ExtensionRow(
      hostId: "host-a", executionId: "exec-b",
      columns: @["probe_label", "probe_count", "probe_weight"],
      values: @[extText("beta"), extInt(5), extReal(0.5)])) == ewWritten
    let both = store.readExtensionColumns(probeId,
      ["probe_label", "probe_weight"])
    check both.len == 2
    check both[0] == @["alpha", nullMarker]
    check both[1] == @["beta", "0.5"]

  test "the spine migrates while the extension stands still":
    # The other arm, and the one that makes the pair discriminating: a
    # mechanism that moved the two schemas together would pass the arm
    # above and fail here.
    let dir = scratchDir("spinemove")
    defer: removeDir(dir)
    let path = dir / "o.sqlite"

    # A version-1 spine carrying an extension already at ITS version 2.
    let created = runSqlite(path,
      frozenSpineV1 & frozenSpineV1Rows & probeV1Ddl & probeV2Step &
      "insert into ext_m12_probe values ('host-v1', 'exec-old', 'alpha', " &
      "3, 0.25);\n" &
      "insert into extension_registry values ('m12_probe', 2, 'runquota-m12'," &
      " 'ext_m12_probe', 1000);\n" &
      "pragma user_version = 1;")
    check created.ok
    check userVersion(path) == 1

    let extensionSqlBefore = block:
      let outcome = runSqlite(path,
        "select " & selectText("sql") & " from sqlite_master where name = " &
          encodeText("ext_m12_probe") & ";")
      check outcome.ok
      decodeText(outcome.output.strip())
    check "probe_weight" in extensionSqlBefore

    let store = openObservationStore(path)
    check store.captureEnabled

    # THE SPINE MOVED, three versions in one open.
    check store.schemaVersion == spineSchemaVersion
    check userVersion(path) == spineSchemaVersion
    check spineSchemaVersion - 1 >= 3
    check "owner_uid" in store.tableSql("executions")

    # THE EXTENSION DID NOT. Same registered version, same DDL, same rows.
    let registry = store.readExtensionRegistry()
    check registry.len == 1
    check registry[0].extensionId == probeId
    check registry[0].schemaVersion == 2
    check store.tableSql("ext_m12_probe") == extensionSqlBefore
    let carried = store.readExtensionColumns(probeId,
      ["probe_label", "probe_count", "probe_weight"])
    check carried.len == 1
    check carried[0] == @["alpha", "3", "0.25"]

    # And the extension needed no migration of its own to be usable after
    # the spine took three steps.
    check store.declareExtension(probeV2()) == eoUpToDate
    check store.insertExecution(ExecutionRow(executionId: "exec-after",
      hostId: "host-v1", runId: "run-1", commandStatsId: "c",
      startedAtUnixMillis: 5000, finishedAtUnixMillis: 5001,
      durationMillis: 1, exitStatus: 0, termination: tExited, attempt: 1,
      peakRssBytes: 0, maxProcesses: 1, majorPageFaults: 0,
      captureCompleteness: ccComplete))
    check store.insertExtensionRow(probeV2(), ExtensionRow(
      hostId: "host-v1", executionId: "exec-after",
      columns: @["probe_label", "probe_count", "probe_weight"],
      values: @[extText("beta"), extInt(5), extReal(0.5)])) == ewWritten
    check store.extensionRowCount(probeId) == 2

  test "a client declaring a version this database cannot store is refused":
    let dir = scratchDir("refuse")
    defer: removeDir(dir)
    let store = openObservationStore(dir / "o.sqlite")
    check store.captureEnabled
    seedSpine(store, "host-a")
    check store.insertExecution(execution("host-a", "exec-a", 1000))
    check store.insertExecution(execution("host-a", "exec-b", 2000))

    # A version this database has no route to is refused BEFORE anything
    # exists, so the refusal is not an artefact of an established table.
    check store.declareExtension(probeV3WithoutItsStep()) ==
      eoRefusedUnstorableVersion
    check store.readExtensionRegistry().len == 0
    check not store.extensionTableExists("ext_m12_probe")
    check store.captureEnabled

    check store.declareExtension(probeV1()) == eoCreated
    check store.insertExtensionRow(probeV1(),
      probeRow("host-a", "exec-a", "alpha", 3)) == ewWritten

    # And refused against an established table: the registry stays at 1 and
    # the table does not grow the column version 2 would have added.
    check store.declareExtension(probeV3WithoutItsStep()) ==
      eoRefusedUnstorableVersion
    check store.readExtensionRegistry()[0].schemaVersion == 1
    check "probe_weight" notin store.tableSql("ext_m12_probe")

    # REFUSED RATHER THAN SILENTLY MIS-STORED. The row a version-3 client
    # offers is shaped for a table this database does not have; writing it
    # would drop whatever version 3 added and leave a row that reads
    # afterwards as a complete observation. It is refused, and the table is
    # exactly as it was.
    check store.extensionRowCount(probeId) == 1
    check store.insertExtensionRow(probeV3WithoutItsStep(), ExtensionRow(
      hostId: "host-a", executionId: "exec-b",
      columns: @["probe_label", "probe_count"],
      values: @[extText("beta"), extInt(5)])) == ewRefusedUnstorableVersion
    check store.extensionRowCount(probeId) == 1
    check store.captureEnabled

    # A version-2 client, which DOES carry the step, is not refused: the
    # rule is about a version that cannot be stored, not about newness.
    check store.declareExtension(probeV2()) == eoMigrated
    check store.readExtensionRegistry()[0].schemaVersion == 2

    # THE CONVERSE, WITHOUT WHICH "REFUSE EVERYTHING" WOULD PASS THE CLAUSE
    # ABOVE. Equal is accepted and writes; OLDER is accepted and writes,
    # with the column it does not know left NULL.
    check store.declareExtension(probeV2()) == eoUpToDate
    check store.insertExtensionRow(probeV2(), ExtensionRow(
      hostId: "host-a", executionId: "exec-b",
      columns: @["probe_label", "probe_count", "probe_weight"],
      values: @[extText("beta"), extInt(5), extReal(1.5)])) == ewWritten

    check store.declareExtension(probeV1()) == eoAcceptedOlder
    check store.readExtensionRegistry()[0].schemaVersion == 2
    check "probe_weight" in store.tableSql("ext_m12_probe")
    check store.insertExecution(execution("host-a", "exec-c", 3000))
    check store.insertExtensionRow(probeV1(),
      probeRow("host-a", "exec-c", "gamma", 7)) == ewWritten

    let rows = store.readExtensionColumns(probeId,
      ["probe_label", "probe_weight"])
    check rows.len == 3
    check rows[0] == @["alpha", nullMarker]
    check rows[1] == @["beta", "1.5"]
    check rows[2] == @["gamma", nullMarker]

    # A version-3 client is STILL refused after the migration to 2, so the
    # refusal tracks what the database carries rather than a fixed number.
    check store.declareExtension(probeV3WithoutItsStep()) ==
      eoRefusedUnstorableVersion
    check store.insertExtensionRow(probeV3WithoutItsStep(),
      probeRow("host-a", "exec-c", "delta", 9)) == ewRefusedUnstorableVersion
    check store.extensionRowCount(probeId) == 3

  test "pruning an execution takes its extension rows with it":
    let dir = scratchDir("prune")
    defer: removeDir(dir)
    let store = openObservationStore(dir / "o.sqlite")
    check store.captureEnabled
    seedSpine(store, "host-a")
    check store.insertExecution(execution("host-a", "exec-old-1", 1000))
    check store.insertExecution(execution("host-a", "exec-old-2", 2000))
    check store.insertExecution(execution("host-a", "exec-new", 9000))
    check store.declareExtension(probeV1()) == eoCreated

    check store.insertExtensionRow(probeV1(),
      probeRow("host-a", "exec-old-1", "old-one", 1)) == ewWritten
    check store.insertExtensionRow(probeV1(),
      probeRow("host-a", "exec-old-2", "old-two", 2)) == ewWritten
    check store.insertExtensionRow(probeV1(),
      probeRow("host-a", "exec-new", "recent", 3)) == ewWritten

    # THE POSITIVE CONTROL, AND IT COMES FIRST. "The extension rows are
    # gone after the prune" is satisfied trivially by rows that were never
    # written, so the rows are asserted to EXIST before anything is pruned.
    check store.extensionRowCount(probeId) == 3
    # Ordered by the spine key, so `exec-new` sorts before `exec-old-*`.
    check store.readExtensionColumns(probeId, ["probe_label"]) ==
      @[@["recent"], @["old-one"], @["old-two"]]
    check store.readExecutions().len == 3

    # AND THE CASCADE IS NOT A NO-OP THE DATABASE WOULD HAVE DONE ANYWAY.
    # Deleting the parent while its extension row is still there is refused
    # by the foreign key, so the extension rows have to be removed by
    # RunQuota and cannot merely be found missing afterwards.
    check not store.runStatement(
      "delete from executions where execution_id = " &
        encodeText("exec-old-1") & ";")
    check "constraint" in store.lastError.toLowerAscii
    check store.readExecutions().len == 3
    check store.captureEnabled

    let outcome = store.pruneExecutionsBefore("host-a", 5000)
    check outcome.pruned
    check outcome.executionsRemoved == 2
    check outcome.extensionRowsRemoved == 2
    check outcome.extensionsCascaded == @[probeId]

    check store.readExecutions().len == 1
    check store.readExecutions()[0].executionId == "exec-new"
    check store.extensionRowCount(probeId) == 1
    check store.readExtensionColumns(probeId, ["probe_label"]) ==
      @[@["recent"]]
    # The rest of the spine is untouched: retention prunes executions, not
    # the hosts and runs they hang off.
    check store.readHosts().len == 1
    check store.readRuns().len == 1

  test "a prune that cannot finish removes nothing":
    # ONE TRANSACTION, asserted rather than described. A cascade that
    # removed the spine rows and then failed would leave extension rows
    # pointing at executions that no longer exist -- rows no query can
    # reach and no later pass would find, because the pass is driven by the
    # parent it just deleted.
    let dir = scratchDir("atomic")
    defer: removeDir(dir)
    let store = openObservationStore(dir / "o.sqlite")
    check store.captureEnabled
    seedSpine(store, "host-a")
    check store.insertExecution(execution("host-a", "exec-old", 1000))
    check store.insertExecution(execution("host-a", "exec-new", 9000))
    check store.declareExtension(probeV1()) == eoCreated
    check store.declareExtension(guardV1()) == eoCreated
    check store.insertExtensionRow(probeV1(),
      probeRow("host-a", "exec-old", "old-one", 1)) == ewWritten
    check store.insertExtensionRow(guardV1(), ExtensionRow(
      hostId: "host-a", executionId: "exec-old",
      columns: @["probe_label"], values: @[extText("guard")])) == ewWritten

    # THE OBSTRUCTION MUST SIT ON THE EXTENSION THE CASCADE REACHES SECOND,
    # AND THAT IS THE WHOLE DIFFICULTY OF THIS TEST. The registry is read in
    # `extension_id` order, so `m12_guard` is cascaded before `m12_probe`,
    # and the batch runs under `sqlite3 -bail`. Obstruct the FIRST table and
    # the batch dies on its first statement with nothing yet done -- and
    # "nothing moved" then holds whether or not the pass is one transaction,
    # so the assertion would be about `-bail` rather than about atomicity.
    # Obstructing `m12_probe` means `m12_guard`'s rows are ALREADY DELETED
    # inside the open transaction when the failure lands, so the counts
    # below can only come back to 1 if that work was rolled back.
    #
    # The ordering is asserted rather than assumed, on the successful pass
    # below: if the registry ever stopped being read in that order this test
    # would go quietly vacuous again.
    #
    # A FOREIGN KEY violation rather than a `raise(abort)` on purpose: a
    # constraint failure is the caller's problem and leaves capture on,
    # which is what lets the same call be made again below. An abort is a
    # store that stopped working, and turns capture off for everyone.
    check store.runStatement("""
create table m12_probe_dependent (
  host_id text not null,
  execution_id text not null,
  foreign key (host_id, execution_id)
    references ext_m12_probe(host_id, execution_id)
);
insert into m12_probe_dependent values ('host-a', 'exec-old');
""")

    let outcome = store.pruneExecutionsBefore("host-a", 5000)
    check not outcome.pruned
    check outcome.executionsRemoved == 0
    check outcome.extensionRowsRemoved == 0

    # NOTHING MOVED. Not the spine, and not `m12_guard`, whose delete had
    # already run when the pass failed on `m12_probe`.
    check store.readExecutions().len == 2
    check store.extensionRowCount(probeId) == 1
    check store.extensionRowCount("m12_guard") == 1
    check store.captureEnabled

    # And with the obstruction gone the same call succeeds, so the arm
    # above failed for the reason it claims and not because the prune never
    # works.
    check store.runStatement("delete from m12_probe_dependent;")
    let second = store.pruneExecutionsBefore("host-a", 5000)
    check second.pruned
    check second.executionsRemoved == 1
    check second.extensionRowsRemoved == 2
    # The cascade order the arm above depends on, pinned.
    check second.extensionsCascaded == @["m12_guard", probeId]
    check store.readExecutions().len == 1
    check store.extensionRowCount(probeId) == 0
    check store.extensionRowCount("m12_guard") == 0

  test "a store that is not open refuses every extension operation":
    # OS-4 on this path too: the extension mechanism is capture, and
    # capture that cannot run must not fail anything.
    let dir = scratchDir("closed")
    defer: removeDir(dir)
    let path = dir / "o.sqlite"
    block:
      let store = openObservationStore(path)
      check store.captureEnabled
    check runSqlite(path,
      "pragma user_version = " & $(spineSchemaVersion + 1) & ";").ok

    let store = openObservationStore(path)
    check store.status == ssRefusedNewer
    check store.declareExtension(probeV1()) == eoUnavailable
    check store.insertExtensionRow(probeV1(),
      probeRow("host-a", "exec-a", "alpha", 1)) == ewUnavailable
    let outcome = store.pruneExecutionsBefore("host-a", 5000)
    check not outcome.pruned
    check outcome.detail == "store is not open"
