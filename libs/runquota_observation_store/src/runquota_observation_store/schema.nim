## The observation-store migration ladder.
##
## Migrations are versioned and forward-only. ``migrations[i]`` takes a
## database at ``user_version == i`` to ``user_version == i + 1``. A shipped
## step MUST NOT be edited afterwards: databases in the field were built by
## the text as it was, and ``t_observation_store_migration`` pins step 1 with
## its own frozen copy of the DDL so that editing it here is caught.
##
## Schema ownership: RunQuota owns every table below. No client may alter a
## spine table; product-specific facts go in ``ext_<extension_id>`` tables
## registered in ``extension_registry`` (M12).

const
  spineSchemaVersion* = 2'i64
    ## The schema version this build understands. A database whose
    ## ``user_version`` exceeds it is REFUSED, never degraded (see
    ## ``openObservationStore``).

  spineTableNames* = [
    "hosts",
    "host_profiles",
    "runs",
    "executions",
    "ambient_samples",
    "extension_registry"
  ]

  migrationV1 = """
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

  migrationV2 = """
alter table runs add column dropped_observations integer not null default 0;
alter table executions
  add column dropped_observations integer not null default 0;
"""

  migrations* = [migrationV1, migrationV2]
    ## Index ``i`` migrates ``user_version`` ``i`` to ``i + 1``.

static:
  doAssert migrations.len == int(spineSchemaVersion)
