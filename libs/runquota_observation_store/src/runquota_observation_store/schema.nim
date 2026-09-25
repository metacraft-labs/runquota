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
  spineSchemaVersion* = 6'i64
    ## The schema version this build understands. A database whose
    ## ``user_version`` exceeds it is REFUSED, never degraded (see
    ## ``openObservationStore``).

  carriedExtensionTable* = "carried_extension_rows"
    ## Quarantine for extension rows a merge could not place, named here
    ## because it is a SPINE table RunQuota owns outright — it is not an
    ## ``ext_`` table and no product declares it.

  spineTableNames* = [
    "hosts",
    "host_profiles",
    "runs",
    "executions",
    "ambient_samples",
    "extension_registry",
    carriedExtensionTable,
    "users"
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

  # Version 3 makes "unchanged hardware MUST NOT accumulate profile rows"
  # structural instead of merely tested. A host has at most one *current*
  # profile -- one row whose ``valid_to`` is still open -- so a second one
  # cannot be inserted even by a client reaching past this library into
  # ``sqlite3``. Superseded rows are unconstrained: a machine may have as
  # many closed profiles as it has had hardware.
  migrationV3 = """
create unique index host_profiles_current
  on host_profiles(host_id) where valid_to_unix_millis is null;
"""

  # Version 4 adds the owner of an execution. One host-wide daemon means
  # one store holding every user's executions, so a row has to say whose
  # it is -- otherwise a uid-scoped query cannot be written at all and
  # "queries are scoped to the calling uid by default" is unimplementable.
  #
  # NULLABLE ON PURPOSE, twice over. Rows written before this column
  # existed have no owner to backfill, and inventing one would attribute
  # somebody's history to whoever happens to be reading. And a transport
  # that cannot report peer credentials (Windows named pipes today) must
  # write NULL rather than 0, because 0 is root and a wrong owner is worse
  # than an absent one.
  #
  # The value comes from the peer credentials of the connection, never
  # from anything the client declares: a client-declared owner would let
  # any participant write rows attributed to another user, which is the
  # failure the per-user boundary exists to prevent.
  migrationV4 = """
alter table executions add column owner_uid integer;
"""

  # Version 5 is where a merge puts an extension row it must CARRY and
  # must not let anybody query (M15, OS-7). Three of its columns are
  # decisions rather than storage.
  #
  # `queryable` is pinned to zero by a CHECK CONSTRAINT rather than by a
  # default. "Marked unqueryable" has to survive a client reaching past
  # this library into `sqlite3`, and a default is only a suggestion about
  # rows nobody named a value for.
  #
  # `payload` is OPAQUE and stays opaque: it holds the source's own column
  # names and their values, rendered as bytes. RunQuota carries it and
  # never reads a column out of it, which is OS-5's non-interpretation
  # clause applied to a row whose schema RunQuota does not have.
  #
  # THERE IS NO TIMESTAMP, AND THE OMISSION IS THE REQUIREMENT. A
  # `carried_at` column would make merging two sources in one order
  # produce a different database from the other order, because whichever
  # source arrived first would be stamped earlier. OS-7 is
  # order-independence; a clock in this table would be the one thing that
  # destroys it.
  #
  # The foreign key to `executions` is what puts these rows inside the
  # retention cascade: a carried row is a fact about an execution, and it
  # is pruned with its parent like every other extension row.
  migrationV5 = """
create table carried_extension_rows (
  extension_id text not null,
  schema_version integer not null,
  host_id text not null,
  execution_id text not null,
  payload text not null,
  queryable integer not null default 0 check (queryable = 0),
  primary key (extension_id, schema_version, host_id, execution_id),
  foreign key (host_id, execution_id)
    references executions(host_id, execution_id)
);

create index carried_extension_rows_by_execution
  on carried_extension_rows(host_id, execution_id);
"""

  # Version 6 says WHO an owner id is. `executions.owner_uid` holds an
  # integer; on POSIX it is the uid, and on Windows -- where the credential
  # is a SID and not an integer -- it is the SID's hash with bit 62 set
  # (`runquota_core/owner_id`). Neither is readable by a person, and the
  # Windows one is not even reversible, so the table below records, ONCE per
  # owner, the principal the id was derived from and a name to show for it.
  #
  # `owner_uid` IS THE KEY AND NEVER CHANGES. `principal` is its preimage --
  # the uid in decimal, or the SID string -- and is immutable too: a second
  # principal arriving under an existing id is a hash collision, and the
  # trigger below turns it into an abort rather than letting two users
  # silently share a scope. The check constraint pins each kind to its range,
  # so a Windows id and a POSIX uid cannot be confused in a store merged
  # from both.
  #
  # `name` IS FOR DIAGNOSTICS AND MAY GO STALE: accounts get renamed. The
  # daemon refreshes it when the name it resolves for a connecting principal
  # differs from the stored one, and stamps `name_updated_at_unix_millis`
  # when it does; a principal that no longer resolves (a deleted account)
  # keeps its last known name rather than being overwritten with NULL. NULL
  # means "never resolved", which is why the two columns are NULL together.
  #
  # THE REFERENCE FROM `executions` IS A TRIGGER, NOT A FOREIGN KEY, and
  # that is the cheaper of two correct choices: SQLite cannot add a
  # constraint to an existing column, and rebuilding `executions` would
  # rebuild the table every extension and the merge quarantine point at.
  # The trigger enforces the same thing for every row written from now on,
  # and the backfill below makes it true of every row already there.
  #
  # TWO PASSES OVER WHAT IS ALREADY THERE.
  #
  # 1. Rows a WINDOWS daemon wrote before this version carry `owner_uid = 0`,
  #    and that 0 was never a credential: the named-pipe peer never set it,
  #    so every Windows client was recorded as root. docs/database.md says a
  #    wrong owner is worse than an absent one, so those rows are set to
  #    NULL -- "the owner is unknown", which is the truth, since the SID was
  #    never recorded. A Windows host is one whose hardware profile says
  #    `os = 'windows'`; a real uid 0 from a POSIX host merged into the same
  #    store is left alone. This is the one migration that edits
  #    `executions`, so the immutability trigger is lifted for that single
  #    statement and re-created from the same text.
  # 2. Every remaining owner is a POSIX uid (no other id space existed), and
  #    gets a `users` row with no name. The daemon fills the name in the
  #    next time that user connects.
  migrationV6 = """
create table users (
  owner_uid integer primary key,
  principal_kind text not null check (principal_kind in ('uid', 'sid')),
  principal text not null,
  name text,
  first_seen_at_unix_millis integer not null,
  name_updated_at_unix_millis integer,
  check ((principal_kind = 'uid' and owner_uid between 0 and 4294967295
            and principal = cast(owner_uid as text))
      or (principal_kind = 'sid' and owner_uid >= 4611686018427387904)),
  check ((name is null) = (name_updated_at_unix_millis is null))
);

create trigger users_principal_is_immutable
before update of owner_uid, principal_kind, principal on users
when new.owner_uid is not old.owner_uid
  or new.principal_kind is not old.principal_kind
  or new.principal is not old.principal
begin
  select raise(abort,
    'runquota: owner id collision: users.principal is the key''s preimage and never changes (constraint)');
end;

create trigger users_referenced_are_kept
before delete on users
when exists (select 1 from executions where owner_uid = old.owner_uid)
begin
  select raise(abort,
    'runquota: users rows referenced by executions are never deleted (constraint)');
end;

drop trigger executions_immutable;

update executions set owner_uid = null
where owner_uid = 0
  and host_id in (select host_id from host_profiles where os = 'windows');

create trigger executions_immutable
before update on executions
begin
  select raise(abort,
    'runquota: executions rows are immutable after write (OS-3)');
end;

insert into users (owner_uid, principal_kind, principal, name,
                   first_seen_at_unix_millis, name_updated_at_unix_millis)
select owner_uid, 'uid', cast(owner_uid as text), null,
       min(started_at_unix_millis), null
from executions
where owner_uid between 0 and 4294967295
group by owner_uid;

create trigger executions_owner_is_a_user
before insert on executions
when new.owner_uid is not null
  and not exists (select 1 from users where owner_uid = new.owner_uid)
begin
  select raise(abort,
    'runquota: executions.owner_uid names no users row (constraint)');
end;
"""

  migrations* = [migrationV1, migrationV2, migrationV3, migrationV4,
                 migrationV5, migrationV6]
    ## Index ``i`` migrates ``user_version`` ``i`` to ``i + 1``.

static:
  doAssert migrations.len == int(spineSchemaVersion)
