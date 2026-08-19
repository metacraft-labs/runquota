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
    defer: removeDir(dir)
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
    defer: removeDir(dir)
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
    defer: removeDir(dir)
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
    defer: removeDir(dir)
    let path = dir / "observations.sqlite"
    block:
      let store = openObservationStore(path)
      check store.status == ssOpen
    let fingerprintBefore = schemaFingerprint(path)
    let store = openObservationStore(path)
    check store.status == ssOpen
    check store.schemaVersion == spineSchemaVersion
    check schemaFingerprint(path) == fingerprintBefore
