## The read path over the observation store.
##
## Normative specification: ``reprobuild-specs/RunQuota-Observation-Store.md``
## §"Query Interface". A store only its writer can read is a log, not a
## system of record; this module is the half that makes it the latter.
##
## ONE INTERFACE, TWO AGGREGATIONS. The admission consumer wants a resource
## distribution over a stats key; the human and agent surfaces want rows,
## rankings and summaries. They are the SAME ROWS at different
## aggregations, so they share one set of filters and one notion of what a
## response carries. A second reader path would be a second thing to keep
## correct.
##
## Three rules are structural here rather than advisory, because each of
## them is a REFUSAL and refusals do not survive being left to care:
##
## * **Nothing is ever blended across hardware profiles.** A distribution
##   is computed per ``host_profile_id`` and the profile identity travels
##   with the figures. There is deliberately no code path that pools rows
##   from two profiles into one set of numbers: a caller that wants
##   cross-host data asks for ``spanAllProfiles`` and gets one distribution
##   PER PROFILE, which it may combine itself if it decides that is sound.
## * **Unknown is not zero.** ``statsUnknown`` is a distinct value from a
##   distribution whose figures happen to be zero, and both are reachable:
##   a key with three zero-duration executions is KNOWN to be zero. Callers
##   treat unknown as "use the declared or default estimate", which is what
##   they would have done before the store existed.
## * **Row queries are scoped to an owner uid unless widened explicitly.**
##   The uid is passed in by the daemon from PEER CREDENTIALS; this module
##   never derives one and never defaults to "everybody".
##
## And one asymmetry that is a design decision rather than an oversight:
## ``estimateFor`` is NOT uid-scoped. The cost of compiling a translation
## unit is a property of the work and the hardware, not of who ran it, and
## scoping it per user would discard most of the history on exactly the
## machines that have the most — a CI server where a dozen accounts build
## the same tree. It takes no uid at all, so it cannot be given one by
## accident.

import std/[algorithm, options, strutils, tables]

import ./extensions, ./sqlite_cli, ./store, ./types

type
  StatsScope* = enum
    ## Whose rows a query is about. The default is the narrow one.
    statsScopeOwner = "owner-uid"
    statsScopeHost = "host"

  ProfileSpan* = enum
    ## How many hardware profiles a query is allowed to reach. The default
    ## is the narrow one, and widening never merges.
    spanSingleProfile = "single-profile"
    spanAllProfiles = "all-profiles"

  StatsKnowledge* = enum
    ## Cold start, made a value rather than a convention. ``statsUnknown``
    ## MUST be distinguishable from a distribution that is known to be
    ## zero, because the caller's response to the two is different: use
    ## your own default, versus use this.
    statsUnknown = "unknown"
    statsKnown = "known"

  ProfileIdentity* = object
    ## The host and hardware a set of figures describes. EVERY response
    ## carries one, including an unknown one: client artifacts travel —
    ## Reprobuild's peer cache moves build records between machines — so a
    ## record written on a 32-core builder can be read on a laptop, and the
    ## reader needs what it takes to notice.
    hostId*: string
    profileId*: Option[string]
      ## ``none`` only for rows whose profile could not be established.
      ## Such rows never reach a distribution; see ``estimateFor``.
    profileHash*: string
    cpuModel*: string
    logicalCores*: int64

  ResourceDistribution* = object
    profile*: ProfileIdentity
    knowledge*: StatsKnowledge
    sampleCount*: int64
    durationMillisMin*: int64
    durationMillisP50*: int64
    durationMillisP90*: int64
    durationMillisMax*: int64
    peakRssBytesMax*: int64

  StatsAnswer* = object
    ## What the admission consumer receives. ``distributions`` is empty
    ## when nothing is known, and holds ONE ENTRY PER PROFILE otherwise —
    ## never one entry summarising several.
    statsKey*: string
    span*: ProfileSpan
    knowledge*: StatsKnowledge
    distributions*: seq[ResourceDistribution]

  ExecutionSummary* = object
    ## One row, for the human and agent surfaces.
    executionId*: string
    statsKey*: string
    profile*: ProfileIdentity
    ownerUid*: Option[int64]
    startedAtUnixMillis*: int64
    durationMillis*: int64
    peakRssBytes*: int64
    exitStatus*: int64
    termination*: Termination

  KeyRanking* = object
    ## One ranked stats key, WITHIN one profile. Ranking across profiles
    ## in a single ordering would be the blending rule broken by another
    ## route: a key that is slow on a laptop and fast on a builder would
    ## rank on a number that describes neither machine.
    statsKey*: string
    profile*: ProfileIdentity
    sampleCount*: int64
    totalDurationMillis*: int64
    maxDurationMillis*: int64

  ExtensionQueryRow* = object
    ## One product-owned extension row, with the spine context of the
    ## execution it is attached to.
    ##
    ## THE VALUES ARE OPAQUE (OS-5). RunQuota carries them as the text
    ## SQLite renders them and does not parse them; it does not know which
    ## of these columns is a duration and which is a name. ``columns`` is
    ## echoed back so a reader can pair them up without RunQuota having an
    ## opinion about the pairing. SQL NULL comes back as ``nullMarker``, so
    ## it stays distinguishable from the empty string.
    hostId*: string
    executionId*: string
    statsKey*: string
    profile*: ProfileIdentity
    ownerUid*: Option[int64]
    columns*: seq[string]
    values*: seq[string]

  RowQuery* = object
    ## A human-surface query. ``ownerUid`` is supplied by the daemon from
    ## peer credentials and is REQUIRED when ``scope`` is
    ## ``statsScopeOwner``: a scope-to-me query with nobody to scope to is
    ## refused (empty), never widened.
    statsKey*: string
      ## Empty means "every key".
    scope*: StatsScope
    ownerUid*: Option[int64]
    span*: ProfileSpan
    profileId*: Option[string]
      ## The profile a ``spanSingleProfile`` query is about.
    limit*: int
      ## Zero or less means unbounded.

const
  unknownProfileHash* = ""

proc percentile(sorted: openArray[int64]; percent: int): int64 =
  ## Nearest-rank percentile over an ascending sequence. Exact and
  ## interpolation-free, so a two-sample distribution reports one of its
  ## two samples rather than a number nobody measured.
  if sorted.len == 0:
    return 0
  var rank = (percent * sorted.len + 99) div 100
  if rank < 1:
    rank = 1
  if rank > sorted.len:
    rank = sorted.len
  sorted[rank - 1]

proc profileTable(store: ObservationStore): Table[string, ProfileIdentity] =
  ## Every profile in the store, by ``profile_id``. Read once per query so
  ## that a response's hardware identity comes from the same snapshot as
  ## its figures.
  result = initTable[string, ProfileIdentity]()
  for row in store.readHostProfiles():
    result[row.profileId] = ProfileIdentity(
      hostId: row.hostId,
      profileId: some(row.profileId),
      profileHash: row.profileHash,
      cpuModel: row.cpuModel,
      logicalCores: row.logicalCores)

proc identityFor(profiles: Table[string, ProfileIdentity];
                 profileId: Option[string]): ProfileIdentity =
  if profileId.isSome and profiles.hasKey(profileId.get):
    return profiles[profileId.get]
  ProfileIdentity(hostId: "", profileId: profileId,
    profileHash: unknownProfileHash, cpuModel: "", logicalCores: 0)

proc statsKeyPredicate(statsKey: string): string =
  if statsKey.len == 0: "" else:
    " and command_stats_id = " & encodeText(statsKey)

proc ownerPredicate(scope: StatsScope; ownerUid: Option[int64]): string =
  ## ``owner_uid = N`` also excludes NULL rows, which is correct: a row
  ## whose owner the transport could not report belongs to nobody in
  ## particular, and handing it to whoever happens to be asking would be
  ## the over-sharing the per-user boundary exists to prevent.
  case scope
  of statsScopeHost: ""
  of statsScopeOwner:
    if ownerUid.isNone: " and 0 = 1"
    else: " and owner_uid = " & encodeInt(ownerUid.get)

proc profilePredicate(span: ProfileSpan; profileId: Option[string]): string =
  case span
  of spanAllProfiles: ""
  of spanSingleProfile:
    if profileId.isNone: " and host_profile_id is null"
    else: " and host_profile_id = " & encodeText(profileId.get)

proc limitClause(limit: int): string =
  if limit > 0: " limit " & $limit else: ""

proc estimateFor*(store: ObservationStore; statsKey: string;
                  span = spanSingleProfile;
                  profileId = none(string)): StatsAnswer =
  ## The admission consumer's read: what has this kind of work cost before,
  ## as a resource distribution over ``statsKey``.
  ##
  ## HOST-WIDE ON PURPOSE, and it takes no uid parameter so that it cannot
  ## be narrowed by a caller who thinks it should be. See the module
  ## header.
  ##
  ## Rows whose ``host_profile_id`` is NULL are EXCLUDED, never pooled: a
  ## duration measured on hardware nobody recorded is not a weaker
  ## statistic, it is a misleading one, and the specification refuses the
  ## same pooling at merge time for the same reason.
  result = StatsAnswer(statsKey: statsKey, span: span,
    knowledge: statsUnknown, distributions: @[])
  if store.isNil or not store.captureEnabled:
    return
  let profiles = store.profileTable()
  let sql = "select " & [
      selectText("host_profile_id"), selectInt("duration_millis"),
      selectInt("peak_rss_bytes")
    ].join(" || '|' || ") &
    " from executions where host_profile_id is not null" &
    statsKeyPredicate(statsKey) &
    profilePredicate(span, profileId) &
    " order by host_profile_id, started_at_unix_millis;"

  var durations = initTable[string, seq[int64]]()
  var peaks = initTable[string, int64]()
  var order: seq[string] = @[]
  for row in store.runQuery(sql):
    let id = decodeText(row[0])
    if not durations.hasKey(id):
      durations[id] = @[]
      peaks[id] = 0
      order.add(id)
    durations[id].add(parseBiggestInt(row[1]))
    let peak = parseBiggestInt(row[2])
    if peak > peaks[id]:
      peaks[id] = peak

  # ONE DISTRIBUTION PER PROFILE. There is no branch below that merges two
  # `order` entries, and that is the whole of the "does not silently blend"
  # rule: a caller asking across profiles receives several answers, each
  # qualified, rather than one answer qualified by nothing.
  order.sort()
  for id in order:
    var samples = durations[id]
    samples.sort()
    result.distributions.add(ResourceDistribution(
      profile: identityFor(profiles, some(id)),
      knowledge: statsKnown,
      sampleCount: int64(samples.len),
      durationMillisMin: samples[0],
      durationMillisP50: percentile(samples, 50),
      durationMillisP90: percentile(samples, 90),
      durationMillisMax: samples[^1],
      peakRssBytesMax: peaks[id]))

  if result.distributions.len > 0:
    result.knowledge = statsKnown
    return

  # COLD START. The answer still carries the hardware identity it was asked
  # about, and it is `statsUnknown` rather than a distribution of zeros:
  # "no history" and "known to cost nothing" are different facts and the
  # caller does different things with them.
  result.knowledge = statsUnknown
  if span == spanSingleProfile:
    result.distributions.add(ResourceDistribution(
      profile: identityFor(profiles, profileId),
      knowledge: statsUnknown,
      sampleCount: 0,
      durationMillisMin: 0,
      durationMillisP50: 0,
      durationMillisP90: 0,
      durationMillisMax: 0,
      peakRssBytesMax: 0))

proc queryExecutions*(store: ObservationStore;
                      query: RowQuery): seq[ExecutionSummary] =
  ## The human surfaces' row read. Scoped to ``query.ownerUid`` unless the
  ## caller widened to ``statsScopeHost``.
  if store.isNil or not store.captureEnabled:
    return @[]
  let profiles = store.profileTable()
  let sql = "select " & [
      selectText("execution_id"), selectText("command_stats_id"),
      selectText("host_profile_id"), selectInt("owner_uid"),
      selectInt("started_at_unix_millis"), selectInt("duration_millis"),
      selectInt("peak_rss_bytes"), selectInt("exit_status"),
      selectText("termination")
    ].join(" || '|' || ") &
    " from executions where 1 = 1" &
    statsKeyPredicate(query.statsKey) &
    ownerPredicate(query.scope, query.ownerUid) &
    profilePredicate(query.span, query.profileId) &
    " order by started_at_unix_millis desc, execution_id" &
    limitClause(query.limit) & ";"
  for row in store.runQuery(sql):
    let profileId =
      if row[2].isNullField: none(string) else: some(decodeText(row[2]))
    result.add(ExecutionSummary(
      executionId: decodeText(row[0]),
      statsKey: decodeText(row[1]),
      profile: identityFor(profiles, profileId),
      ownerUid:
        if row[3].isNullField: none(int64) else: some(parseBiggestInt(row[3])),
      startedAtUnixMillis: parseBiggestInt(row[4]),
      durationMillis: parseBiggestInt(row[5]),
      peakRssBytes: parseBiggestInt(row[6]),
      exitStatus: parseBiggestInt(row[7]),
      termination: parseEnum[Termination](decodeText(row[8]))))

proc queryExtensionRows*(store: ObservationStore; query: RowQuery;
                         extensionId: string;
                         columns: openArray[string]): seq[ExtensionQueryRow] =
  ## Product-owned extension rows, for the executions ``query`` selects.
  ##
  ## THE SCOPE RULES ARE NOT RESTATED HERE, THEY ARE REUSED. This runs
  ## ``queryExecutions`` first and then asks for the extension rows of what
  ## came back, so an execution the caller may not see cannot become
  ## visible because a product attached a fact to it — and the uid and
  ## profile rules cannot drift out of step with the ones above, because
  ## there is only one copy of them.
  ##
  ## RUNQUOTA DOES NOT INTERPRET THE PAYLOAD (OS-5). The only column names
  ## it writes into the statement against the extension table are the SPINE
  ## KEY it is joined by; every other name arrived from the caller and is
  ## checked only for being a storable identifier. Values come back as
  ## text, unparsed.
  if store.isNil or not store.captureEnabled:
    return @[]
  if not isStorableIdentifier(extensionId):
    return @[]
  var selected: seq[string] = @[]
  var names: seq[string] = @[]
  for name in columns:
    if not isStorableIdentifier(name):
      return @[]
    selected.add(selectText(name))
    names.add(name)
  if selected.len == 0:
    return @[]

  var visible = initTable[string, ExecutionSummary]()
  var wanted: seq[string] = @[]
  for row in store.queryExecutions(query):
    visible[row.executionId] = row
    wanted.add(encodeText(row.executionId))
  if wanted.len == 0:
    return @[]

  let sql = "select " & (@[selectText(keyHostColumn),
      selectText(keyExecutionColumn)] & selected).join(" || '|' || ") &
    " from " & extensionTableName(extensionId) &
    " where " & keyExecutionColumn & " in (" & wanted.join(", ") & ")" &
    " order by " & keyHostColumn & ", " & keyExecutionColumn & ";"
  for row in store.runQuery(sql):
    let executionId = decodeText(row[1])
    if not visible.hasKey(executionId):
      continue
    let spine = visible[executionId]
    var values: seq[string] = @[]
    for index in 0 ..< names.len:
      let field = row[2 + index]
      values.add(if field.isNullField: nullMarker else: decodeText(field))
    result.add(ExtensionQueryRow(
      hostId: decodeText(row[0]),
      executionId: executionId,
      statsKey: spine.statsKey,
      profile: spine.profile,
      ownerUid: spine.ownerUid,
      columns: names,
      values: values))

proc queryRanking*(store: ObservationStore;
                   query: RowQuery): seq[KeyRanking] =
  ## The human surfaces' ranking read: the costliest stats keys, ranked
  ## WITHIN a profile and never across one.
  if store.isNil or not store.captureEnabled:
    return @[]
  let profiles = store.profileTable()
  let sql = "select " & [
      selectText("command_stats_id"), selectText("host_profile_id"),
      selectInt("count(*)"), selectInt("sum(duration_millis)"),
      selectInt("max(duration_millis)")
    ].join(" || '|' || ") &
    " from executions where 1 = 1" &
    statsKeyPredicate(query.statsKey) &
    ownerPredicate(query.scope, query.ownerUid) &
    profilePredicate(query.span, query.profileId) &
    " group by command_stats_id, host_profile_id" &
    " order by sum(duration_millis) desc, command_stats_id" &
    limitClause(query.limit) & ";"
  for row in store.runQuery(sql):
    let profileId =
      if row[1].isNullField: none(string) else: some(decodeText(row[1]))
    result.add(KeyRanking(
      statsKey: decodeText(row[0]),
      profile: identityFor(profiles, profileId),
      sampleCount: parseBiggestInt(row[2]),
      totalDurationMillis: parseBiggestInt(row[3]),
      maxDurationMillis: parseBiggestInt(row[4])))
