## M9 gate, clause 2: a database one version old migrates forward, and a
## database one version NEWER is refused to open rather than degraded.
##
## The version-1 database is built from the frozen copy of the version-1
## DDL below, not by calling into the library. That is the point: databases
## in the field were created by the text as it was on the day they were
## written, so the migration has to work against an artifact that does not
## move when the library changes. If a shipped migration step is edited,
## the "migrated and fresh schemas are identical" assertion catches it.
##
## No mocks: real SQLite files, written by `sqlite3` and read back by the
## same code the daemon uses.

import std/[options, os, strutils, times, unittest]

import runquota_observation_store

proc scratchDir(name: string): string =
  result = getTempDir() / ("runquota-obs-" & name & "-" &
    $getCurrentProcessId() & "-" & $epochTime())
  removeDir(result)
  createDir(result)

const frozenSchemaV1 = """
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

const v1Rows = """
insert into hosts values ('host-v1', 1000, 'boot-v1');
insert into runs values (
  'run-v1', 'host-v1', 'repro-build', '0.0.1', 'build', 1000,
  2000, 0, 'ws', 'debug', 'abc123', 'dev', 'complete');
insert into executions values (
  'exec-v1', 'host-v1', null, 'run-v1', 'stats-v1', 7, 1100, 1900, 800, 0,
  'exited', 1, null, 4096, 10, 2, 3, 5, 64, 128, 'complete');
"""

proc schemaFingerprint(path: string): string =
  let outcome = runSqlite(path,
    "select type || '|' || name || '|' || coalesce(sql, '') " &
      "from sqlite_master order by type, name;")
  doAssert outcome.ok, outcome.error
  outcome.output.strip()

proc userVersion(path: string): int64 =
  let outcome = runSqlite(path, "pragma user_version;")
  doAssert outcome.ok, outcome.error
  parseBiggestInt(outcome.output.strip())

suite "observation_store_migration":
  test "a database one version old migrates forward and keeps its rows":
    let dir = scratchDir("migrate")
    defer:
      closePooledConnections()
      removeDir(dir)
    let path = dir / "observations.sqlite"

    let created = runSqlite(path,
      frozenSchemaV1 & v1Rows & "pragma user_version = 1;")
    check created.ok
    check userVersion(path) == 1

    let store = openObservationStore(path)
    check store.status == ssOpen
    check store.schemaVersion == spineSchemaVersion
    check userVersion(path) == spineSchemaVersion

    # The version-1 rows survive, and the column version 2 added takes its
    # documented default rather than NULL.
    let runs = store.readRuns()
    check runs.len == 1
    check runs[0].runId == "run-v1"
    check runs[0].tool == "repro-build"
    check runs[0].gitBranch == some("dev")
    check runs[0].droppedObservations == 0

    let executions = store.readExecutions()
    check executions.len == 1
    check executions[0].executionId == "exec-v1"
    check executions[0].peakRssBytes == 4096
    check executions[0].leaseId == some(7'i64)
    check executions[0].hostProfileId.isNone
    check executions[0].droppedObservations == 0

    # New rows are accepted on the migrated database.
    check store.insertRun(RunRow(runId: "run-v2", hostId: "host-v1",
      tool: "ct-test-runner", toolVersion: "1", invocationKind: "test",
      startedAtUnixMillis: 3000, captureCompleteness: ccComplete,
      droppedObservations: 4))
    check store.readRuns().len == 2

  test "migrating an old database lands on exactly the fresh schema":
    # Without this, a migration step could drift from table creation and
    # produce two different databases that both report the same version.
    let dir = scratchDir("converge")
    defer:
      closePooledConnections()
      removeDir(dir)
    let migratedPath = dir / "migrated.sqlite"
    let freshPath = dir / "fresh.sqlite"

    check runSqlite(migratedPath,
      frozenSchemaV1 & "pragma user_version = 1;").ok
    let migrated = openObservationStore(migratedPath)
    check migrated.status == ssOpen

    let fresh = openObservationStore(freshPath)
    check fresh.status == ssOpen

    check schemaFingerprint(migratedPath) == schemaFingerprint(freshPath)
    check userVersion(migratedPath) == userVersion(freshPath)

  test "a database one version newer is refused, not degraded":
    let dir = scratchDir("newer")
    defer:
      closePooledConnections()
      removeDir(dir)
    let path = dir / "observations.sqlite"

    block:
      let store = openObservationStore(path)
      check store.insertHost(HostRow(hostId: "host-future",
        createdAtUnixMillis: 1, lastBootId: "boot"))
    let futureVersion = spineSchemaVersion + 1
    check runSqlite(path, "pragma user_version = " & $futureVersion & ";").ok

    let fingerprintBefore = schemaFingerprint(path)
    let sizeBefore = getFileSize(path)

    let store = openObservationStore(path)
    check store.status == ssRefusedNewer
    check not store.captureEnabled
    check "refusing" in store.report
    check $futureVersion in store.report
    check $spineSchemaVersion in store.report

    # Refused means refused: no write is accepted through the store.
    check not store.insertHost(HostRow(hostId: "host-new",
      createdAtUnixMillis: 2, lastBootId: "boot"))
    check store.readHosts().len == 0

    # And the database on disk is exactly as it was.
    check userVersion(path) == futureVersion
    check schemaFingerprint(path) == fingerprintBefore
    check getFileSize(path) == sizeBefore
    let remaining = runSqlite(path, "select count(*) from hosts;")
    check remaining.ok
    check remaining.output.strip() == "1"

  test "a database at the current version is opened without migrating":
    let dir = scratchDir("current")
    defer:
      closePooledConnections()
      removeDir(dir)
    let path = dir / "observations.sqlite"
    block:
      let store = openObservationStore(path)
      check store.status == ssOpen
    let fingerprintBefore = schemaFingerprint(path)
    let store = openObservationStore(path)
    check store.status == ssOpen
    check store.schemaVersion == spineSchemaVersion
    check schemaFingerprint(path) == fingerprintBefore

  test "a version-7 store with rows migrates to 8 and keeps every row":
    # Schema 8 (sizing data) ADDS columns and a table; every row a version-7
    # daemon wrote must read back unchanged, with NULL -- "not recorded" --
    # in each new column, and the migrated store must accept sizing rows.
    # The version-7 store is built from the SHIPPED steps 1-7 (which no
    # later change may edit) and filled the way a version-7 daemon fills
    # it: a host and its profile, an owner, a run, an execution with
    # totals, and its CPU profile.
    let dir = scratchDir("v7")
    defer:
      closePooledConnections()
      removeDir(dir)
    let path = dir / "observations.sqlite"
    var ladder = ""
    for i in 0 ..< 7:
      ladder.add(migrations[i] & "\n")
    let created = runSqlite(path, ladder & """
insert into hosts values ('host-7', 1000, 'boot-7');
insert into host_profiles values ('host-7', 'prof-7', 'hash', 1000, null,
  'cpu', 8, 16, 34359738368, 0, 'nvme', 'ext4', 'x86_64', 'linux', '6',
  '6.1', 'bare-metal', 'local');
insert into users values (1000, 'uid', '1000', 'someone', 1000, 1000);
insert into runs (run_id, host_id, tool, tool_version, invocation_kind,
  started_at_unix_millis, capture_completeness, dropped_observations)
  values ('run-7', 'host-7', 'repro-build', '1', 'lease-session', 2000,
  'complete', 0);
insert into executions (execution_id, host_id, host_profile_id, run_id,
  command_stats_id, lease_id, started_at_unix_millis,
  finished_at_unix_millis, duration_millis, exit_status, termination,
  attempt, peak_rss_bytes, cpu_user_millis, cpu_sys_millis, max_processes,
  major_page_faults, capture_completeness, dropped_observations, owner_uid)
  values ('exec-7', 'host-7', 'prof-7', 'run-7', 'key-7', 3, 2100, 4100,
  2000, 0, 'exited', 1, 536870912, 1500, 100, 1, 0, 'complete', 0, 1000);
insert into execution_cpu_profiles values ('host-7', 'exec-7', 1000,
  x'e803e803', 'client-tree');
pragma user_version = 7;
""")
    check created.ok
    check userVersion(path) == 7

    let store = openObservationStore(path)
    check store.status == ssOpen
    check userVersion(path) == spineSchemaVersion

    let runs = store.readRuns()
    check runs.len == 1
    check runs[0].project.isNone
    check runs[0].entryPoint.isNone
    let executions = store.readExecutions()
    check executions.len == 1
    let e = executions[0]
    check e.executionId == "exec-7"
    check e.peakRssBytes == 536870912
    check e.cpuUserMillis == some(1500'i64)
    check e.ownerUid == some(1000'i64)
    check e.requestedAtUnixMillis.isNone
    check e.cpuGrantedMilli.isNone
    check e.afterExecutionIds.isNone
    check store.readCpuProfiles().len == 1
    check store.readMemoryProfiles().len == 0
    # Still immutable after the migration.
    check not runSqlite(path,
      "update executions set duration_millis = 1;").ok

    # Sizing rows are accepted beside the old ones.
    check store.insertRun(RunRow(runId: "run-8", hostId: "host-7",
      tool: "repro-build", toolVersion: "2", invocationKind: "build",
      startedAtUnixMillis: 5000, captureCompleteness: ccComplete,
      project: some("p"), entryPoint: some("build")))
    let row = ExecutionRow(executionId: "exec-8", hostId: "host-7",
      hostProfileId: some("prof-7"), runId: "run-8", commandStatsId: "k",
      startedAtUnixMillis: 5100, finishedAtUnixMillis: 6100,
      durationMillis: 1000, termination: tExited, attempt: 1,
      peakRssBytes: 1, captureCompleteness: ccComplete,
      requestedAtUnixMillis: some(5050'i64), cpuGrantedMilli: some(2000'i64),
      afterExecutionIds: some(@["exec-7"]),
      memoryProfileIntervalMillis: 1000, memoryProfileSamples: @[7'u16, 9])
    check store.appendBatch(newSeq[RunRow](), [row])
    let after = store.readExecutions()
    check after.len == 2
    for r in after:
      if r.executionId == "exec-8":
        check r.afterExecutionIds == some(@["exec-7"])
        check r.cpuGrantedMilli == some(2000'i64)
    check store.readMemoryProfiles().len == 1

    # And the legacy rows replay, with the gaps counted.
    let sizingRuns = store.readSizingRuns(SizingQuery(sinceUnixMillis: 0,
      allUsers: true, allProfiles: true)).runs
    check sizingRuns.len == 2
    let figures = computeSizing(sizingRuns, @[], @[2], 0.99, "prof-7", true)
    check figures.exclusions[exIncluded] == 2
    check figures.counts.readyTimeUnknown == 1
    check figures.counts.widthUnknown == 1

  test "an interrupted migration to 8 leaves the store at 7, and a retry completes it":
    # The step runs in ONE transaction with its `user_version` bump, so a
    # failure part-way (here: the table it creates already exists, after the
    # `alter table`s have run) must leave none of it behind -- no added
    # column, version still 7 -- and the store must migrate cleanly once the
    # obstacle is gone. Falsifying mutation: running the step without
    # `begin immediate` leaves the columns added at version 7, and the
    # retry then fails on a duplicate column.
    let dir = scratchDir("v7int")
    defer:
      closePooledConnections()
      removeDir(dir)
    let path = dir / "observations.sqlite"
    var ladder = ""
    for i in 0 ..< 7:
      ladder.add(migrations[i] & "\n")
    check runSqlite(path, ladder & """
create table execution_memory_profiles (blocker integer);
pragma user_version = 7;
""").ok
    block:
      let store = openObservationStore(path)
      check store.status != ssOpen
    check userVersion(path) == 7
    let columns = runSqlite(path,
      "select name from pragma_table_info('runs') where name = 'project';")
    check columns.ok
    check columns.output.strip() == ""
    check runSqlite(path, "drop table execution_memory_profiles;").ok
    let store = openObservationStore(path)
    check store.status == ssOpen
    check userVersion(path) == spineSchemaVersion
    # And opening the migrated store again changes nothing.
    let fingerprint = schemaFingerprint(path)
    let again = openObservationStore(path)
    check again.status == ssOpen
    check schemaFingerprint(path) == fingerprint

  test "a version-8 store with rows migrates to 9 and keeps every row":
    # Schema 9 adds the `cap_exceeded` termination, which a CHECK constraint
    # cannot be altered to allow, so `executions` is rebuilt. Every row must
    # come back -- the executions, and the rows that point at them: a CPU
    # profile, a memory profile and an extension table's row, whose foreign
    # keys must name the rebuilt table and still hold -- the indexes and
    # both triggers must be back, and the new word must be accepted.
    # Falsifying mutations: copying the rows back with a filter (one
    # execution lost) fails the step's commit on the orphaned profile and
    # leaves the store at 8; dropping the trigger re-creation lets an
    # update through.
    let dir = scratchDir("v8")
    defer: removeDir(dir)
    let path = dir / "observations.sqlite"
    var ladder = ""
    for i in 0 ..< 8:
      ladder.add(migrations[i] & "\n")
    let created = runSqlite(path, ladder & """
insert into hosts values ('host-8', 1000, 'boot-8');
insert into host_profiles values ('host-8', 'prof-8', 'hash', 1000, null,
  'cpu', 8, 16, 34359738368, 0, 'nvme', 'ext4', 'x86_64', 'linux', '6',
  '6.1', 'bare-metal', 'local');
insert into users values (1000, 'uid', '1000', 'someone', 1000, 1000);
insert into runs (run_id, host_id, tool, tool_version, invocation_kind,
  started_at_unix_millis, capture_completeness, dropped_observations)
  values ('run-8', 'host-8', 'repro-build', '1', 'lease-session', 2000,
  'complete', 0);
insert into executions (execution_id, host_id, host_profile_id, run_id,
  command_stats_id, lease_id, started_at_unix_millis,
  finished_at_unix_millis, duration_millis, exit_status, termination,
  attempt, peak_rss_bytes, cpu_user_millis, cpu_sys_millis, max_processes,
  major_page_faults, capture_completeness, dropped_observations, owner_uid,
  requested_at_unix_millis, cpu_granted_milli, after_execution_ids)
  values ('exec-8a', 'host-8', 'prof-8', 'run-8', 'key-8', 3, 2100, 4100,
  2000, 0, 'exited', 1, 536870912, 1500, 100, 1, 0, 'complete', 0, 1000,
  2050, 2000, ''),
  ('exec-8b', 'host-8', 'prof-8', 'run-8', 'key-8', 4, 2200, 4200,
  2000, 137, 'oom_killed', 1, 1073741824, 900, 50, 2, 1, 'complete', 0,
  1000, 2150, 1000, 'exec-8a');
insert into execution_cpu_profiles values ('host-8', 'exec-8a', 1000,
  x'e803e803', 'client-tree');
insert into execution_memory_profiles values ('host-8', 'exec-8b', 1000,
  x'0200', 'client-tree');
create table ext_probe (
  host_id text not null,
  execution_id text not null,
  figure integer,
  primary key (host_id, execution_id),
  foreign key (host_id, execution_id)
    references executions(host_id, execution_id)
);
insert into ext_probe values ('host-8', 'exec-8b', 42);
pragma user_version = 8;
""")
    check created.ok
    check userVersion(path) == 8

    let store = openObservationStore(path)
    check store.status == ssOpen
    check userVersion(path) == 9

    let executions = store.readExecutions()
    check executions.len == 2
    for e in executions:
      if e.executionId == "exec-8b":
        check e.termination == tOomKilled
        check e.exitStatus == 137
        check e.ownerUid == some(1000'i64)
        check e.cpuGrantedMilli == some(1000'i64)
        check e.afterExecutionIds == some(@["exec-8a"])
      else:
        check e.executionId == "exec-8a"
        check e.peakRssBytes == 536870912
        check e.afterExecutionIds == some(newSeq[string]())
    check store.readCpuProfiles().len == 1
    check store.readMemoryProfiles().len == 1
    let probe = runSqlite(path, "select figure from ext_probe;")
    check probe.ok and probe.output.strip() == "42"
    # The references still resolve, and still bind.
    let fk = runSqlite(path, "pragma foreign_key_check;")
    check fk.ok and fk.output.strip() == ""
    check not runSqlite(path, "pragma foreign_keys = on;\n" &
      "insert into ext_probe values ('host-8', 'exec-none', 1);").ok
    # The indexes and both triggers are back.
    let objects = runSqlite(path, "select name from sqlite_master where " &
      "tbl_name = 'executions' and type in ('index', 'trigger') " &
      "and name not like 'sqlite_autoindex_%' order by name;")
    check objects.ok
    check objects.output.strip().splitLines() == @[
      "executions_by_command_stats_id", "executions_by_run",
      "executions_immutable", "executions_owner_is_a_user"]
    check not runSqlite(path,
      "update executions set duration_millis = 1;").ok
    check not runSqlite(path, "pragma foreign_keys = on;\n" &
      "insert into executions (execution_id, host_id, run_id, " &
      "command_stats_id, started_at_unix_millis, finished_at_unix_millis, " &
      "duration_millis, exit_status, termination, attempt, peak_rss_bytes, " &
      "max_processes, major_page_faults, capture_completeness, owner_uid) " &
      "values ('exec-x', 'host-8', 'run-8', 'k', 1, 2, 1, 0, 'exited', 1, " &
      "1, 1, 0, 'complete', 4242);").ok

    # And a cap-exceeded execution is accepted.
    let capped = ExecutionRow(executionId: "exec-9", hostId: "host-8",
      hostProfileId: some("prof-8"), runId: "run-8", commandStatsId: "key-8",
      startedAtUnixMillis: 5100, finishedAtUnixMillis: 6100,
      durationMillis: 1000, exitStatus: 137, termination: tCapExceeded,
      attempt: 1, peakRssBytes: 2147483648'i64,
      captureCompleteness: ccComplete)
    check store.appendBatch(newSeq[RunRow](), [capped])
    var found = false
    for e in store.readExecutions():
      if e.executionId == "exec-9":
        found = true
        check e.termination == tCapExceeded
    check found

