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
##
## WHAT SCHEDULES ANY OF THIS is at the bottom of this file: the sweeper
## thread ``runquotad`` starts, and the reasoning about its cadence, its
## idle preference and the ceiling on how long that preference may defer a
## bound.

import std/[locks, options, os, strutils]

import ./ambient, ./extensions, ./ids, ./schema, ./sqlite_cli, ./store

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

# ---------------------------------------------------------------------------
# The scheduled pass
# ---------------------------------------------------------------------------
#
# WHY THIS EXISTS AT ALL. Everything above was built by M15 and CALLED BY
# NOBODY: the only occurrence of ``applyRetention`` outside the tests was
# its own definition, so a long-lived ``runquotad`` grew its store without
# limit. That was tolerable while capture was opt-in. It stops being
# tolerable the moment capture is on by default, because the argument for
# default-on is that an opt-in store is empty exactly when it is first
# needed -- and that argument only holds if the store is also BOUNDED.
# "Every machine accumulates history" and "every machine accumulates
# history forever" are different promises.
#
# WHY A THREAD OF ITS OWN, AND NOT A CALL ON THE SERVE PATH. The
# specification's §"Retention" says pruning MUST NOT hold the write path,
# and in ``runquotad`` that is not a figure of speech: every request is
# handled under one daemon-wide lock, so a prune reached from a request
# handler -- or from anything else holding that lock -- stops the lease
# authority for as long as the delete runs. On a store with a year of
# history that is seconds, during which no lease is granted, no observation
# is accepted and no query is answered. The sweeper below therefore runs on
# its own thread, against its OWN ``ObservationStore`` handle opened from
# the path, and takes ``sweeperLock`` only to read its configuration and to
# publish its counters -- NEVER across the pass itself. A counter read that
# blocked would hold the daemon lock just as surely as the pass would.
#
# WHY IT PREFERS AN IDLE MACHINE, AND WHY IT WILL NOT WAIT FOREVER. A bulk
# delete competes for the same disk as the work being observed, which is
# what OS-1 exists to prevent, and the natural moment to pay for it is one
# where no lease is live. The lease authority already publishes that number
# for the ambient sampler, so the gate costs nothing new. But "prune only
# when idle" alone is not a bound: a machine that is never idle would never
# prune, and a machine that is never idle is precisely the one whose store
# is growing fastest. So a sweep deferred ``maxDeferredSweeps`` times in a
# row runs anyway and is counted separately, which is what keeps the bound
# a bound rather than a preference.
#
# WHY A CADENCE AND NOT AN EVENT. Retention bounds are configured in days;
# a pass an hour is two orders of magnitude finer than the thing it
# enforces, so the exact moment never matters, and a tick is far cheaper to
# reason about than a growth estimate maintained on the write path.

const
  millisPerDay = 24'i64 * 60'i64 * 60'i64 * 1000'i64

  defaultMaxExecutionAgeMillis* = 90'i64 * millisPerDay
    ## Ninety days of execution history. Long enough that "has this test
    ## ever passed on this hardware" and "is this failure new" have a
    ## quarter of evidence behind them, which is what the store is for.
  defaultMaxExecutions* = 2_000_000'i64
    ## The second bound, and it is not redundant with the first: age bounds
    ## a quiet machine's store and says nothing about a build farm that
    ## records a million executions a week.
  defaultMaxAmbientSampleAgeMillis* = 14'i64 * millisPerDay
    ## Ambient samples are a second per host WHILE A LEASE IS LIVE -- about
    ## 86k rows on a day of continuous building -- and they are read to
    ## qualify a duration that was recorded near them. Two weeks outlives
    ## every window a client asks about and is a fourteenth of the spine's
    ## bound, which is the ratio their row rates deserve.
  defaultMaxAmbientSamples* = 2_000_000'i64

  defaultRetentionSweepIntervalMillis* = 3_600_000
    ## One pass an hour. See the note above on why this is a cadence.
  defaultRetentionPollMillis* = 250
    ## How often the sweeper looks at the live-lease count BETWEEN ticks.
    ## The question a tick asks is "was a lease live at any point over the
    ## interval this tick covers", not "is one live at this instant" -- an
    ## hour of continuous building followed by one idle second must read as
    ## busy -- and that needs looking more often than once an interval.
  defaultMaxDeferredSweeps* = 24
    ## A day of unbroken work, at the default cadence, before a sweep runs
    ## regardless. A bound deferred by at most a day cannot make a bound
    ## measured in days meaningfully wrong; a bound deferred without limit
    ## is not a bound.

proc defaultRetentionPolicy*(): RetentionPolicy =
  ## What a daemon enforces when the operator names nothing.
  RetentionPolicy(
    maxExecutionAgeMillis: some(defaultMaxExecutionAgeMillis),
    maxExecutions: some(defaultMaxExecutions),
    maxAmbientSampleAgeMillis: some(defaultMaxAmbientSampleAgeMillis),
    maxAmbientSamples: some(defaultMaxAmbientSamples))

proc describe*(policy: RetentionPolicy): string =
  ## One line, for the startup report. ``off`` is spelled out per bound
  ## rather than omitted: an operator reading this needs to see that a
  ## bound was disabled, not merely fail to see that it was set.
  proc bound(name: string; value: Option[int64]): string =
    name & "=" & (if value.isNone: "off" else: $value.get)
  @[bound("max_execution_age_millis", policy.maxExecutionAgeMillis),
    bound("max_executions", policy.maxExecutions),
    bound("max_ambient_sample_age_millis", policy.maxAmbientSampleAgeMillis),
    bound("max_ambient_samples", policy.maxAmbientSamples)].join(" ")

var
  sweeperLock: Lock
  sweeperLockReady = false
  sweeperThread: Thread[void]
  sweeperPath = ""
  sweeperHostId = ""
  sweeperPolicy = noRetention()
  sweeperIntervalMillis = defaultRetentionSweepIntervalMillis
  sweeperPollMillis = defaultRetentionPollMillis
  sweeperMaxDeferrals = defaultMaxDeferredSweeps
  sweeperConsecutiveDeferrals = 0
  sweeperStarted = 0'i64
  sweeperFinished = 0'i64
  sweeperDeferred = 0'i64
  sweeperForced = 0'i64
  sweeperFailures = 0'i64
  sweeperExecutionsRemoved = 0'i64
  sweeperExtensionRowsRemoved = 0'i64
  sweeperCarriedRowsRemoved = 0'i64
  sweeperAmbientSamplesRemoved = 0'i64
  sweeperLastStartedAt = 0'i64
  sweeperLastFinishedAt = 0'i64
  sweeperLastDetail = ""
  sweeperStop = false
  sweeperActive = false

proc ensureSweeperLock() =
  if not sweeperLockReady:
    initLock(sweeperLock)
    sweeperLockReady = true

proc sweepOnce(store: var ObservationStore; path, hostId: string;
               policy: RetentionPolicy) {.gcsafe.} =
  ## One pass, with NO LOCK HELD while it runs.
  ##
  ## The handle is reopened whenever it is no longer usable. A pass that
  ## fails a write degrades its own store object permanently (OS-4's
  ## "degrade, never fail" applies to the object, not to the file), so
  ## without this a single full disk would silence retention for the
  ## daemon's whole life even after the disk was emptied. The reopen is
  ## once per tick at worst, which at the default cadence is once an hour.
  {.cast(gcsafe).}:
    if store.isNil or not store.captureEnabled:
      store = openObservationStore(path)
    let startedAt = unixMillisNow()
    acquire(sweeperLock)
    try:
      sweeperStarted += 1
      sweeperLastStartedAt = startedAt
    finally:
      release(sweeperLock)

    # THE PASS ITSELF, OUTSIDE EVERY LOCK THIS MODULE OWNS.
    let report = store.applyRetention(hostId, unixMillisNow(), policy)

    let finishedAt = unixMillisNow()
    acquire(sweeperLock)
    try:
      sweeperFinished += 1
      sweeperLastFinishedAt = finishedAt
      if report.applied:
        sweeperExecutionsRemoved += report.executionsRemoved
        sweeperExtensionRowsRemoved += report.extensionRowsRemoved
        sweeperCarriedRowsRemoved += report.carriedRowsRemoved
        sweeperAmbientSamplesRemoved += report.ambientSamplesRemoved
        sweeperLastDetail = ""
      else:
        # OS-4. A pass that could not run is COUNTED and the reason kept;
        # it is never raised, never retried in a tight loop, and never
        # allowed to reach the lease authority. A full disk, a store made
        # read-only underneath the daemon, or a file somebody deleted all
        # land here.
        sweeperFailures += 1
        sweeperLastDetail = report.detail
    finally:
      release(sweeperLock)

proc sweeperMain() {.thread.} =
  {.cast(gcsafe).}:
    var store: ObservationStore = nil
    var elapsedMillis = 0
    var sawLease = false
    while true:
      var poll = 0
      var interval = 0
      var ceiling = 0
      var path = ""
      var hostId = ""
      var policy = noRetention()
      var shouldStop = false
      acquire(sweeperLock)
      try:
        poll = sweeperPollMillis
        interval = sweeperIntervalMillis
        ceiling = sweeperMaxDeferrals
        path = sweeperPath
        hostId = sweeperHostId
        policy = sweeperPolicy
        shouldStop = sweeperStop
      finally:
        release(sweeperLock)
      if shouldStop:
        break

      let slice = max(1, min(poll, interval))
      sleep(slice)
      elapsedMillis += slice
      # THE LIVE-LEASE COUNT IS PUBLISHED ONCE, BY THE LEASE AUTHORITY, AND
      # READ TWICE. `setAmbientLiveLeaseCount` is the one place that number
      # is maintained; a second publication for retention would be a second
      # copy of the same fact to keep in step, and the two disagreeing is a
      # defect nothing would ever notice.
      if ambientLiveLeaseCount() > 0:
        sawLease = true
      if elapsedMillis < interval:
        continue
      elapsedMillis = 0
      let busy = sawLease
      sawLease = false

      var skip = false
      acquire(sweeperLock)
      try:
        if busy and sweeperConsecutiveDeferrals < ceiling:
          # WORK WAS LIVE OVER THIS INTERVAL. The delete competes for the
          # disk the work runs on, so it waits for a quieter tick.
          sweeperConsecutiveDeferrals += 1
          sweeperDeferred += 1
          skip = true
        elif busy:
          # AND THIS IS WHERE WAITING STOPS. A machine that has been busy
          # for `ceiling` consecutive intervals is not going to volunteer a
          # quiet one, and deferring again would turn a bound into a wish.
          sweeperConsecutiveDeferrals = 0
          sweeperForced += 1
        else:
          sweeperConsecutiveDeferrals = 0
      finally:
        release(sweeperLock)
      if skip:
        continue

      sweepOnce(store, path, hostId, policy)

proc startRetentionSweeper*(path, hostId: string; policy: RetentionPolicy;
                            intervalMillis = defaultRetentionSweepIntervalMillis;
                            maxDeferredSweeps = defaultMaxDeferredSweeps;
                            pollMillis = defaultRetentionPollMillis) =
  ## Starts the scheduled pass for ``path``. An empty path or host id, or a
  ## non-positive interval, leaves it inactive -- which is how a disabled
  ## store, an unidentified host and an operator who turned retention off
  ## are all represented, exactly as the ambient sampler represents the
  ## same three states.
  ensureSweeperLock()
  acquire(sweeperLock)
  try:
    if sweeperActive:
      return
    sweeperPath = path
    sweeperHostId = hostId
    sweeperPolicy = policy
    sweeperIntervalMillis = intervalMillis
    # THE POLL IS DERIVED FROM THE INTERVAL RATHER THAN CONFIGURED BESIDE
    # IT. Looking four times per interval is what makes "was a lease live
    # over this interval" answerable, and a fixed 250 ms would be coarser
    # than the whole interval for anyone who set a short one -- which is
    # every test in the suite, and an operator debugging a policy. One
    # knob rather than two that can disagree.
    sweeperPollMillis = max(1, min(pollMillis, intervalMillis div 4))
    sweeperMaxDeferrals = max(0, maxDeferredSweeps)
    sweeperConsecutiveDeferrals = 0
    sweeperStarted = 0
    sweeperFinished = 0
    sweeperDeferred = 0
    sweeperForced = 0
    sweeperFailures = 0
    sweeperExecutionsRemoved = 0
    sweeperExtensionRowsRemoved = 0
    sweeperCarriedRowsRemoved = 0
    sweeperAmbientSamplesRemoved = 0
    sweeperLastStartedAt = 0
    sweeperLastFinishedAt = 0
    sweeperLastDetail = ""
    sweeperStop = false
    if path.len == 0 or hostId.len == 0 or intervalMillis <= 0:
      return
    sweeperActive = true
  finally:
    release(sweeperLock)
  createThread(sweeperThread, sweeperMain)

template sweeperReader(name: untyped; field: untyped; kind: typedesc): untyped =
  proc name*(): kind =
    ensureSweeperLock()
    acquire(sweeperLock)
    try:
      field
    finally:
      release(sweeperLock)

sweeperReader(retentionSweeperActive, sweeperActive, bool)
sweeperReader(retentionSweepsStarted, sweeperStarted, int64)
sweeperReader(retentionSweepsFinished, sweeperFinished, int64)
sweeperReader(retentionSweepsDeferred, sweeperDeferred, int64)
# `retentionSweepsForced` counts sweeps that ran even though work was live,
# because deferring had reached its ceiling. Nonzero there is not an error;
# it is the bound asserting itself over the preference.
sweeperReader(retentionSweepsForced, sweeperForced, int64)
sweeperReader(retentionSweepFailures, sweeperFailures, int64)
sweeperReader(retentionExecutionsRemoved, sweeperExecutionsRemoved, int64)
sweeperReader(retentionExtensionRowsRemoved, sweeperExtensionRowsRemoved, int64)
sweeperReader(retentionCarriedRowsRemoved, sweeperCarriedRowsRemoved, int64)
sweeperReader(retentionAmbientSamplesRemoved, sweeperAmbientSamplesRemoved,
  int64)
sweeperReader(retentionLastPassStartedAtUnixMillis, sweeperLastStartedAt, int64)
sweeperReader(retentionLastPassFinishedAtUnixMillis, sweeperLastFinishedAt,
  int64)
sweeperReader(retentionLastDetail, sweeperLastDetail, string)

proc stopRetentionSweeper*() =
  ## Signals the sweeper and joins it. A pass already in flight finishes;
  ## it is one transaction and interrupting it would buy nothing that
  ## crash-safety does not already provide.
  ensureSweeperLock()
  var running = false
  acquire(sweeperLock)
  try:
    running = sweeperActive
    sweeperStop = true
  finally:
    release(sweeperLock)
  if not running:
    return
  joinThread(sweeperThread)
  acquire(sweeperLock)
  try:
    sweeperActive = false
    sweeperPath = ""
    sweeperHostId = ""
  finally:
    release(sweeperLock)
