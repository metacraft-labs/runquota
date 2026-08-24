## Retention: the bounds that keep the store from growing without limit,
## and the check that says pruning never cost the store its hardware
## context.
##
## Normative specification:
## ``reprobuild-specs/RunQuota-Observation-Store.md`` §"Retention":
##
## * bounded by BOTH age and row count, with configurable limits;
## * pruning cascades to extension rows;
## * pruning is crash-safe and does not hold the write path;
## * ``hosts`` and ``host_profiles`` are retained as long as any row
##   references them — a pruned execution history MUST NOT orphan hardware
##   context.
##
## THE CASCADE IS M12'S AND IS NOT REBUILT HERE. ``extensions.nim`` already
## owns "which extension tables exist" (the registry) and "one transaction
## per pass"; this module supplies the two BOUNDS and the ambient table,
## and reaches the extension rows through the same code. What is new below
## the surface is that the doomed set is a VALUE rather than a hardcoded
## ``started_at < cutoff`` predicate, because a row-count bound is not
## expressible as a timestamp: with N rows to keep, which rows are doomed
## depends on the rest of the table.
##
## WHAT THIS MODULE DELIBERATELY DOES NOT DELETE, and why the omission is
## the requirement rather than an oversight:
##
## * ``hosts`` and ``host_profiles``. A machine whose hardware last changed
##   two years ago has a CURRENT profile row whose ``valid_from`` is two
##   years old, and every execution ever recorded on it points at that row.
##   An age bound applied to hardware would delete exactly the row every
##   surviving execution needs, and OS-6 would be gone with it: an
##   execution whose profile cannot be resolved is a duration pooled across
##   unknown hardware. The hardware dimension is not aged out; it is
##   retained as long as anything references it, which for a live machine
##   is forever.
## * ``runs``. A run is the parent of the executions retention removes, and
##   the spine's foreign keys point from execution to run rather than the
##   other way, so a run left behind orphans nothing. Pruning empty runs
##   would be a defensible extra; it is not what the specification asks
##   for, and M12's cascade test pins that a prune leaves them alone.
##
## CRASH SAFETY, STATED PRECISELY. Each pass below is one SQLite
## transaction, so a process killed while one is open leaves the store as
## it was before that pass: SQLite's WAL recovery discards the uncommitted
## frames on the next open. A retention run that applies two bounds is two
## transactions, and a kill between them leaves the store CONSISTENT and
## partially pruned — every extension row's parent still present, every
## host and profile still resolvable — which is the property the
## specification asks for. It is not "all or nothing across the whole run",
## and claiming that would be claiming something the design does not do.
## ``tests/integration/t_observation_store_retention_crash.nim`` kills a
## real process, with a real signal, inside the window.

import std/[options, strutils]

import ./extensions, ./schema, ./sqlite_cli, ./store

type
  RetentionPolicy* = object
    ## Both bounds, both optional, both configurable. ``none`` means "this
    ## bound does not apply", which is distinct from a bound of zero — a
    ## limit of zero executions is a legitimate instruction to keep none.
    maxExecutionAgeMillis*: Option[int64]
    maxExecutions*: Option[int64]
    maxAmbientSampleAgeMillis*: Option[int64]
    maxAmbientSamples*: Option[int64]

  RetentionReport* = object
    applied*: bool
    ageBoundApplied*: bool
    countBoundApplied*: bool
    executionsRemoved*: int64
    extensionRowsRemoved*: int64
    carriedRowsRemoved*: int64
    ambientSamplesRemoved*: int64
    extensionsCascaded*: seq[string]
    hostsRetained*: int64
      ## Counted AFTER the pass. The caller compares it with what was there
      ## before; a retention run that removed hardware context would be
      ## visible here and in ``orphanReport`` both.
    hostProfilesRetained*: int64
    detail*: string

  OrphanReport* = object
    ## Every referencing row in the store, checked against the row it
    ## references. This is a DETECTOR, and it is only worth having if it
    ## can go off: ``tests/unit/t_observation_store_retention.nim`` feeds it
    ## a manufactured orphan of each shape and requires it to report one.
    checked*: bool
    detail*: string
    hostProfilesWithoutHost*: int64
    runsWithoutHost*: int64
    executionsWithoutHost*: int64
    executionsWithoutProfile*: int64
      ## Counts rows whose ``host_profile_id`` is SET and does not resolve.
      ## A NULL profile is not an orphan, it is an unknown — the store
      ## records "nobody said" as NULL everywhere else too.
    ambientSamplesWithoutHost*: int64
    extensionRowsWithoutExecution*: int64
    carriedRowsWithoutExecution*: int64
    extensionTablesChecked*: seq[string]

proc noRetention*(): RetentionPolicy =
  RetentionPolicy(maxExecutionAgeMillis: none(int64),
                  maxExecutions: none(int64),
                  maxAmbientSampleAgeMillis: none(int64),
                  maxAmbientSamples: none(int64))

proc orphans*(report: OrphanReport): int64 =
  ## The single number the assertions are written against.
  report.hostProfilesWithoutHost + report.runsWithoutHost +
    report.executionsWithoutHost + report.executionsWithoutProfile +
    report.ambientSamplesWithoutHost +
    report.extensionRowsWithoutExecution +
    report.carriedRowsWithoutExecution

proc scalar(store: ObservationStore; sql: string): int64 =
  let rows = store.runQuery(sql)
  if rows.len != 1 or rows[0].len != 1:
    return -1
  try:
    parseBiggestInt(rows[0][0].strip())
  except ValueError:
    -1

proc orphanReport*(store: ObservationStore): OrphanReport =
  ## Whether anything in the store now references a row that is not there.
  ##
  ## It is written as a set of OUTER-JOIN counts rather than as a reliance
  ## on foreign keys, and that is the point: foreign keys are enforced by
  ## the connection that writes, so a store edited with
  ## ``pragma foreign_keys = off`` — or restored from a copy taken by
  ## something that did not care — can hold orphans that no constraint will
  ## ever mention again. The detector has to be able to see a state the
  ## library itself cannot create.
  result = OrphanReport(checked: false, detail: "",
    extensionTablesChecked: @[])
  if not store.captureEnabled:
    result.detail = "store is not open"
    return

  result.hostProfilesWithoutHost = store.scalar(
    "select count(*) from host_profiles p where not exists (" &
    "select 1 from hosts h where h.host_id = p.host_id);")
  result.runsWithoutHost = store.scalar(
    "select count(*) from runs r where not exists (" &
    "select 1 from hosts h where h.host_id = r.host_id);")
  result.executionsWithoutHost = store.scalar(
    "select count(*) from executions e where not exists (" &
    "select 1 from hosts h where h.host_id = e.host_id);")
  result.executionsWithoutProfile = store.scalar(
    "select count(*) from executions e where e.host_profile_id is not null " &
    "and not exists (select 1 from host_profiles p where " &
    "p.host_id = e.host_id and p.profile_id = e.host_profile_id);")
  result.ambientSamplesWithoutHost = store.scalar(
    "select count(*) from ambient_samples a where not exists (" &
    "select 1 from hosts h where h.host_id = a.host_id);")
  result.carriedRowsWithoutExecution = store.scalar(
    "select count(*) from " & carriedExtensionTable & " c where not exists (" &
    "select 1 from executions e where e.host_id = c.host_id and " &
    "e.execution_id = c.execution_id);")

  # The extension half is driven by the REGISTRY, exactly as the cascade
  # is. An extension nobody registered is not RunQuota's to check, and a
  # hardcoded list would go stale the first time a product declared one.
  for entry in store.readExtensionRegistry():
    if not isStorableIdentifier(entry.extensionId):
      continue
    let table = extensionTableName(entry.extensionId)
    if not store.extensionTableExists(table):
      continue
    result.extensionTablesChecked.add(entry.extensionId)
    let count = store.scalar("select count(*) from " & table & " x where " &
      "not exists (select 1 from executions e where e.host_id = x." &
      keyHostColumn & " and e.execution_id = x." & keyExecutionColumn & ");")
    if count > 0:
      result.extensionRowsWithoutExecution += count
  result.checked = true

proc pruneAmbientSamples(store: ObservationStore; hostId: string;
                         policy: RetentionPolicy; nowUnixMillis: int64;
                         report: var RetentionReport) =
  ## The one writer in the store that is unbounded in TIME rather than in
  ## work done. Nothing references an ambient sample, so there is no
  ## cascade — which is why it is here and not in the extension pass.
  var clauses: seq[string] = @[]
  if policy.maxAmbientSampleAgeMillis.isSome:
    let cutoff = nowUnixMillis - policy.maxAmbientSampleAgeMillis.get
    clauses.add("host_id = " & encodeText(hostId) &
      " and sampled_at_unix_millis < " & encodeInt(cutoff))
  if policy.maxAmbientSamples.isSome:
    let keep = max(0'i64, policy.maxAmbientSamples.get)
    clauses.add("host_id = " & encodeText(hostId) &
      " and sampled_at_unix_millis not in (select sampled_at_unix_millis " &
      "from ambient_samples where host_id = " & encodeText(hostId) &
      " order by sampled_at_unix_millis desc limit " & encodeInt(keep) & ")")
  if clauses.len == 0:
    return
  for clause in clauses:
    let doomed = store.scalar(
      "select count(*) from ambient_samples where " & clause & ";")
    if not store.runStatement("begin immediate;\ndelete from " &
        "ambient_samples where " & clause & ";\ncommit;\n"):
      report.detail = store.lastError
      return
    if doomed > 0:
      report.ambientSamplesRemoved += doomed

proc applyRetention*(store: ObservationStore; hostId: string;
                     nowUnixMillis: int64;
                     policy: RetentionPolicy): RetentionReport =
  ## Enforces both bounds for one host, cascading to every extension row
  ## and every carried row, and never touching ``hosts`` or
  ## ``host_profiles``.
  ##
  ## The AGE bound runs first and the COUNT bound second, and the order is
  ## not arbitrary: the count bound asks "which rows are outside the newest
  ## N", and asking that before the age bound has run would count rows that
  ## are about to disappear anyway. Running age first makes the count bound
  ## a statement about what is KEPT rather than about what happened to be
  ## in the table when the pass started.
  result = RetentionReport(applied: false, ageBoundApplied: false,
    countBoundApplied: false, executionsRemoved: 0, extensionRowsRemoved: 0,
    carriedRowsRemoved: 0, ambientSamplesRemoved: 0, extensionsCascaded: @[],
    hostsRetained: -1, hostProfilesRetained: -1, detail: "")
  if not store.captureEnabled:
    result.detail = "store is not open"
    return
  if hostId.len == 0:
    result.detail = "no host"
    return

  if policy.maxExecutionAgeMillis.isSome:
    let cutoff = nowUnixMillis - policy.maxExecutionAgeMillis.get
    let pass = store.pruneExecutions(hostId, startedBefore(cutoff))
    if not pass.pruned:
      result.detail = pass.detail
      return
    result.ageBoundApplied = true
    result.executionsRemoved += pass.executionsRemoved
    result.extensionRowsRemoved += pass.extensionRowsRemoved
    result.carriedRowsRemoved += pass.carriedRowsRemoved
    for id in pass.extensionsCascaded:
      if id notin result.extensionsCascaded:
        result.extensionsCascaded.add(id)

  if policy.maxExecutions.isSome:
    let pass = store.pruneExecutions(hostId,
      beyondNewest(max(0'i64, policy.maxExecutions.get)))
    if not pass.pruned:
      result.detail = pass.detail
      return
    result.countBoundApplied = true
    result.executionsRemoved += pass.executionsRemoved
    result.extensionRowsRemoved += pass.extensionRowsRemoved
    result.carriedRowsRemoved += pass.carriedRowsRemoved
    for id in pass.extensionsCascaded:
      if id notin result.extensionsCascaded:
        result.extensionsCascaded.add(id)

  pruneAmbientSamples(store, hostId, policy, nowUnixMillis, result)
  if result.detail.len > 0:
    return

  result.hostsRetained = store.scalar("select count(*) from hosts;")
  result.hostProfilesRetained =
    store.scalar("select count(*) from host_profiles;")
  result.applied = true
