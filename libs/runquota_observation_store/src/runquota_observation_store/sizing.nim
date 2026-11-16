## Sizing over the store: what `runquota profile`, `runquota sizing` and
## `runquota observations export --format sizing` read and say.
##
## The replay itself is ``sizing_replay`` (pure, and its module comment is
## the replay's definition);
## this module reads the rows it needs, renders the answers, and renders the
## export records the reference offline replay (``scripts/sizing-replay.mjs``)
## reads.
##
## READ BY THE DAEMON ONLY. Like every reader of the store it runs inside
## ``runquotad``, the store's only sanctioned reader; clients ask over the
## socket (``QuerySizing``).
##
## SCOPED LIKE `runquota stats`. Rows are the caller's own (owner id from
## peer credentials) unless the query asks for every user, and a caller whose
## owner id is unknown gets nothing rather than everything.

import std/[algorithm, options, sequtils, sets, strutils, tables]

import ./redaction, ./sizing_replay, ./sqlite_cli, ./store, ./types

export sizing_replay

type
  SizingQuery* = object
    project*: string
      ## "" means every project (`profile` only).
    entryPoint*: string
      ## "" means every entry point.
    sinceUnixMillis*: int64
    allUsers*: bool
    ownerUid*: Option[int64]
    allProfiles*: bool
    currentProfile*: string
    openRunIds*: HashSet[string]
      ## Runs whose session is still registered.
    maxRuns*: int
      ## The most runs one answer reads (0: ``MaxSizingRuns``).
    maxExecutions*: int
      ## The most executions one answer reads (0: ``MaxSizingExecutions``).

  SizingRead* = object
    ## What one answer read: the candidate runs (oldest first) and whether
    ## the read limits cut older runs off.
    runs*: seq[SizingRun]
    truncated*: bool

  SizingAnswerStatus* = enum
    sasOk = "ok"
    sasCaptureOff = "capture-off"
    sasNoRuns = "no-runs"

const
  SizingExportFormat* = "runquota-sizing/1"
  MaxSizingRuns* = 1000
    ## The most candidate runs one answer reads: the newest ones in scope.
  MaxSizingExecutions* = 50_000
    ## The most executions one answer reads, over all its runs. Each holds
    ## up to two 256-sample profiles, so this bounds what one query keeps in
    ## the daemon's memory to tens of MiB.
  MaxSizingAmbientSamples* = 200_000
    ## The most ambient samples one answer reads for its baseline.

proc jsonString*(value: string): string =
  ## A JSON string literal (RFC 8259 § 7).
  result = "\""
  for ch in value:
    case ch
    of '"': result.add("\\\"")
    of '\\': result.add("\\\\")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    of '\0' .. '\x08', '\x0b', '\x0c', '\x0e' .. '\x1f':
      result.add("\\u" & toHex(ord(ch), 4).toLowerAscii)
    else: result.add(ch)
  result.add("\"")

proc jsonOptString(value: Option[string]): string =
  if value.isNone: "null" else: jsonString(value.get)

proc jsonOptInt(value: Option[int64]): string =
  if value.isNone: "null" else: $value.get

proc optTextField(field: string): Option[string] =
  if field.isNullField: none(string) else: some(decodeText(field))

proc optIntField(field: string): Option[int64] =
  if field.isNullField: none(int64) else: some(parseBiggestInt(field))

proc runPredicate(query: SizingQuery; params: var seq[SqlValue]): string =
  result = " where r.started_at_unix_millis >= ?"
  params.add(sqlInt(query.sinceUnixMillis))
  if query.project.len > 0:
    result.add(" and r.project = ?")
    params.add(sqlText(query.project))
  if query.entryPoint.len > 0:
    result.add(" and r.entry_point = ?")
    params.add(sqlText(query.entryPoint))

proc ownerScopeRefuses(query: SizingQuery): bool =
  ## A caller whose owner id is unknown is answered empty, never widened.
  not query.allUsers and query.ownerUid.isNone

proc runOrderKey(prefix: string): string =
  ## Newest first, with a total order so a limit cuts at one place.
  " order by " & prefix & "started_at_unix_millis desc, " & prefix &
    "host_id desc, " & prefix & "run_id desc"

proc readSizingRuns*(store: ObservationStore; query: SizingQuery): SizingRead =
  ## The candidate runs of ``query`` with their executions (step 1's
  ## candidates, before any exclusion). Runs with no execution in scope
  ## are candidates only when every user's rows are read: a run without
  ## executions has no owner, so it cannot be said to be the caller's.
  ##
  ## BOUNDED. The daemon answers on its request path, so at most
  ## ``maxRuns`` runs and ``maxExecutions`` executions are read, the NEWEST
  ## ones, and ``truncated`` says older runs in scope were left out. A run is
  ## read whole or not at all: a run cut in the middle would replay as a
  ## different run.
  if store.isNil or not store.captureEnabled or query.ownerScopeRefuses:
    return
  let maxRuns = if query.maxRuns > 0: query.maxRuns else: MaxSizingRuns
  let maxExecutions =
    if query.maxExecutions > 0: query.maxExecutions else: MaxSizingExecutions
  var runParams: seq[SqlValue] = @[]
  let runSql = "select " & [
    selectText("r.run_id"), selectText("r.host_id"), selectText("r.project"),
    selectText("r.entry_point"), selectInt("r.started_at_unix_millis"),
    selectText("r.capture_completeness")
  ].join(" || '|' || ") & " from runs r" & runPredicate(query, runParams) &
    runOrderKey("r.") & " limit " & $(maxRuns + 1) & ";"
  var runs: seq[SizingRun] = @[]
  var byKey = initTable[string, int]()
  for row in store.runQuery(runSql, runParams):
    if row.len != 6:
      continue
    if runs.len == maxRuns:
      result.truncated = true
      break
    let run = SizingRun(runId: decodeText(row[0]), hostId: decodeText(row[1]),
      project: optTextField(row[2]), entryPoint: optTextField(row[3]),
      startedAt: parseBiggestInt(row[4]),
      complete: decodeText(row[5]) == $ccComplete,
      open: decodeText(row[0]) in query.openRunIds)
    byKey[run.hostId & "\0" & run.runId] = runs.len
    runs.add(run)
  if runs.len == 0:
    return
  var params: seq[SqlValue] = @[]
  var sql = "select " & [
    selectText("e.host_id"), selectText("e.run_id"),
    selectText("e.execution_id"), selectInt("e.lease_id"),
    selectText("e.host_profile_id"), selectInt("e.requested_at_unix_millis"),
    selectInt("e.started_at_unix_millis"), selectInt("e.finished_at_unix_millis"),
    selectInt("e.duration_millis"), selectInt("e.peak_rss_bytes"),
    selectInt("e.cpu_user_millis"), selectInt("e.cpu_sys_millis"),
    selectInt("e.cpu_granted_milli"), selectInt("e.io_write_bytes"),
    selectText("e.after_execution_ids"), selectInt("c.interval_ms"),
    "case when c.samples is null then '' else hex(c.samples) end",
    selectInt("m.interval_ms"),
    "case when m.samples is null then '' else hex(m.samples) end",
    selectText("e.capture_completeness"), selectText("e.command_stats_id"),
    selectInt("e.io_read_bytes")
  ].join(" || '|' || ") &
    " from executions e join runs r on r.host_id = e.host_id and " &
    "r.run_id = e.run_id" &
    " left join execution_cpu_profiles c on c.host_id = e.host_id and " &
    "c.execution_id = e.execution_id" &
    " left join execution_memory_profiles m on m.host_id = e.host_id and " &
    "m.execution_id = e.execution_id" & runPredicate(query, params)
  # Only the runs read above: none older than the oldest of them.
  sql.add(" and r.started_at_unix_millis >= ?")
  params.add(sqlInt(runs[^1].startedAt))
  if not query.allUsers:
    sql.add(" and e.owner_uid = ?")
    params.add(sqlInt(query.ownerUid.get))
  sql.add(runOrderKey("r.") & ", e.execution_id limit " &
    $(maxExecutions + 1) & ";")
  var owned = initHashSet[int]()
  var read = 0
  # The run the execution limit cut, if any: it and every older run are
  # dropped whole.
  var cutAt = runs.len
  for row in store.runQuery(sql, params):
    if row.len != 22:
      continue
    let key = decodeText(row[0]) & "\0" & decodeText(row[1])
    if not byKey.hasKey(key):
      continue
    let index = byKey[key]
    if read == maxExecutions:
      cutAt = index
      result.truncated = true
      break
    inc read
    let lease = optIntField(row[3])
    let cpuInterval = optIntField(row[15])
    let memInterval = optIntField(row[17])
    var e = SizingExecution(
      executionId: decodeText(row[2]),
      leaseId: lease.get(-1),
      hostProfileId: decodeText(row[4]),
      requestedAt: optIntField(row[5]),
      startedAt: parseBiggestInt(row[6]),
      finishedAt: parseBiggestInt(row[7]),
      durationMillis: parseBiggestInt(row[8]),
      peakRssBytes: parseBiggestInt(row[9]),
      cpuUserMillis: optIntField(row[10]),
      cpuSysMillis: optIntField(row[11]),
      cpuGrantedMilli: optIntField(row[12]),
      ioWriteBytes: optIntField(row[13]),
      after: parseAfterText(optTextField(row[14])),
      cpuProfileIntervalMillis: cpuInterval.get(0),
      cpuProfile: decodeU16Hex(row[16]),
      memoryProfileIntervalMillis: memInterval.get(0),
      memoryProfileMiB: decodeU16Hex(row[18]),
      complete: decodeText(row[19]) == $ccComplete,
      commandStatsId: decodeText(row[20]),
      ioReadBytes: optIntField(row[21]))
    runs[index].executions.add(e)
    owned.incl(index)
  # Oldest first, as the answers and the export list them.
  for i in countdown(cutAt - 1, 0):
    if query.allUsers or i in owned:
      result.runs.add(runs[i])

proc readAmbientPoints*(store: ObservationStore; runs: seq[SizingRun];
                        truncated: var bool): seq[AmbientPoint] =
  ## The ambient samples of every host the runs ran on, inside their
  ## windows (merged per host); ``computeSizing`` keeps the ones inside a
  ## replayed run's window. At most ``MaxSizingAmbientSamples`` are read,
  ## and ``truncated`` says the limit was reached.
  if store.isNil or not store.captureEnabled or runs.len == 0:
    return @[]
  var spans = initTable[string, seq[(int64, int64)]]()
  for run in runs:
    if run.executions.len == 0:
      continue
    spans.mgetOrPut(run.hostId, @[]).add(run.runWindow())
  var hosts = toSeq(spans.keys)
  hosts.sort()
  for host in hosts:
    var list = spans[host]
    list.sort()
    var merged: seq[(int64, int64)] = @[]
    for (a, b) in list:
      if merged.len > 0 and a <= merged[^1][1]:
        merged[^1][1] = max(merged[^1][1], b)
      else:
        merged.add((a, b))
    for (a, b) in merged:
      let room = MaxSizingAmbientSamples - result.len
      if room <= 0:
        truncated = true
        return
      let sql = "select " & selectInt("sampled_at_unix_millis") &
        " || '|' || " & selectInt("foreign_rss_bytes") &
        " from ambient_samples where host_id = ? and " &
        "sampled_at_unix_millis between ? and ? " &
        "order by sampled_at_unix_millis limit " & $(room + 1) & ";"
      for row in store.runQuery(sql, [sqlText(host), sqlInt(a), sqlInt(b)]):
        if row.len == 2:
          if result.len == MaxSizingAmbientSamples:
            truncated = true
            return
          result.add(AmbientPoint(hostId: host,
            sampledAt: parseBiggestInt(row[0]),
            foreignRssBytes: parseBiggestInt(row[1])))

const
  readTruncatedCaveat = "more runs are in scope than one answer reads (" &
    $MaxSizingRuns & " runs, " & $MaxSizingExecutions & " executions, " &
    $MaxSizingAmbientSamples & " ambient samples): only the newest were " &
    "read; --since or --entry-point narrows the scope"

proc caveatsFor(figures: SizingFigures): seq[string] =
  let c = figures.counts
  if figures.exclusions[exOverBudget] > 0:
    result.add($figures.exclusions[exOverBudget] &
      " older run(s) were not replayed: the answer's work budget was spent " &
      "on newer ones; fewer --cpus values or a narrower --since replays " &
      "more, and 'scripts/sizing-replay.mjs' over the sizing export " &
      "replays them all")
  if figures.exclusions[exIncomplete] > 0:
    result.add($figures.exclusions[exIncomplete] &
      " run(s) had incomplete capture and were excluded")
  if figures.exclusions[exOpen] > 0:
    result.add($figures.exclusions[exOpen] &
      " run(s) are still open (their session is registered) and were excluded")
  if figures.exclusions[exOtherProfile] + figures.exclusions[exMixedProfiles] > 0:
    result.add($(figures.exclusions[exOtherProfile] +
      figures.exclusions[exMixedProfiles]) &
      " run(s) ran on another host profile and were excluded; " &
      "--host-profile all includes them")
  if c.memoryFromPeak > 0:
    result.add($c.memoryFromPeak & " of " & $c.executions &
      " execution(s) had no memory profile and hold their peak for their " &
      "whole duration, which overestimates; turn on 'sizing-data' in the " &
      "launching clients (RUNQUOTA_MEASUREMENT=sizing-data=on) for profiles")
  if c.readyTimeUnknown > 0:
    result.add($c.readyTimeUnknown &
      " execution(s) have no recorded request time and were made ready at " &
      "their recorded start")
  if c.widthUnknown > 0:
    result.add($c.widthUnknown &
      " execution(s) have no recorded width and were replayed at one CPU")
  if c.cpuUnknown > 0:
    result.add($c.cpuUnknown & " execution(s) have no CPU figures; where " &
      "they ran wider than N they were stretched as if they used their " &
      "whole width")
  if figures.baselineSamples == 0 and figures.sizes.len > 0 and
      c.executions > 0:
    result.add("no ambient sample falls inside the replayed runs, so the " &
      "baseline is unknown (ambient sampling runs only with capture on " &
      "and a lease live)")

proc sizingAnswerJson*(figures: SizingFigures; status: SizingAnswerStatus;
                       query: SizingQuery; q: float64;
                       hostWriteBytesPerSec: Option[int64];
                       extraCaveats: seq[string] = @[];
                       readTruncated = false): string =
  ## The `runquota sizing --json` document.
  var caveats = extraCaveats
  if readTruncated:
    caveats.add(readTruncatedCaveat)
  for caveat in caveatsFor(figures):
    caveats.add(caveat)
  let baselineKnown = figures.baselineSamples > 0
  result = "{\"status\":" & jsonString($status) &
    ",\"project\":" & jsonString(query.project) &
    ",\"entry_point\":" &
      (if query.entryPoint.len > 0: jsonString(query.entryPoint) else: "null") &
    ",\"quantile\":" & $q &
    ",\"since_unix_millis\":" & $query.sinceUnixMillis &
    ",\"scope\":" & jsonString(if query.allUsers: "host" else: "owner") &
    ",\"host_profile\":" & jsonString(if query.allProfiles: "all" else: "current") &
    ",\"host_profiles\":["
  for i, profile in figures.profiles:
    if i > 0: result.add(",")
    result.add(jsonString(profile))
  result.add("],\"runs\":{\"candidates\":" & $figures.candidates &
    ",\"replayed\":" & $figures.exclusions[exIncluded] &
    ",\"incomplete\":" & $figures.exclusions[exIncomplete] &
    ",\"open\":" & $figures.exclusions[exOpen] &
    ",\"empty\":" & $figures.exclusions[exEmpty] &
    ",\"other_profile\":" & $figures.exclusions[exOtherProfile] &
    ",\"mixed_profiles\":" & $figures.exclusions[exMixedProfiles] &
    ",\"over_budget\":" & $figures.exclusions[exOverBudget] & "}")
  result.add(",\"read_truncated\":" & $readTruncated)
  let c = figures.counts
  result.add(",\"executions\":{\"replayed\":" & $c.executions &
    ",\"ready_time_unknown\":" & $c.readyTimeUnknown &
    ",\"width_unknown\":" & $c.widthUnknown &
    ",\"memory_from_peak\":" & $c.memoryFromPeak &
    ",\"cpu_unknown\":" & $c.cpuUnknown & "}")
  result.add(",\"baseline\":{\"known\":" & $baselineKnown &
    ",\"samples\":" & $figures.baselineSamples &
    ",\"quantile_bytes\":" &
      (if baselineKnown: $figures.baselineQuantileBytes else: "null") &
    ",\"max_bytes\":" &
      (if baselineKnown: $figures.baselineMaxBytes else: "null") & "}")
  result.add(",\"host_write_bytes_per_sec\":" & jsonOptInt(hostWriteBytesPerSec))
  result.add(",\"sizes\":[")
  for i, size in figures.sizes:
    if i > 0: result.add(",")
    let replayed = figures.exclusions[exIncluded] > 0
    result.add("{\"cpus\":" & $size.cpus)
    if replayed:
      result.add(",\"memory_quantile_bytes\":" & $size.memoryQuantileBytes &
        ",\"memory_max_bytes\":" & $size.memoryMaxBytes &
        ",\"makespan_quantile_millis\":" & $size.makespanQuantileMillis &
        ",\"makespan_max_millis\":" & $size.makespanMaxMillis &
        ",\"write_quantile_bytes_per_sec\":" & $size.writeQuantileBytesPerSecond &
        ",\"write_max_bytes_per_sec\":" & $size.writeMaxBytesPerSecond &
        ",\"total_bytes\":" &
          (if baselineKnown:
             $(size.memoryQuantileBytes + figures.baselineQuantileBytes)
           else: "null"))
    result.add("}")
  result.add("],\"caveats\":[")
  for i, caveat in caveats:
    if i > 0: result.add(",")
    result.add(jsonString(caveat))
  result.add("]}")

# ---------------------------------------------------------------------------
# `runquota profile`
# ---------------------------------------------------------------------------

proc figureJson(values: seq[int64]; q: float64): string =
  if values.len == 0:
    return "{\"count\":0,\"quantile\":null,\"max\":null}"
  "{\"count\":" & $values.len & ",\"quantile\":" & $nearestRank(values, q) &
    ",\"max\":" & $max(values) & "}"

proc profileAnswerJson*(runs: seq[SizingRun]; status: SizingAnswerStatus;
                        query: SizingQuery; q: float64;
                        hostWriteBytesPerSec: Option[int64];
                        readTruncated = false): string =
  ## The `runquota profile --json` document: one entry per project, entry
  ## point and host profile, over the executions of the candidate runs.
  ## An execution whose capture is not complete is left out and counted.
  ## ``readTruncated``: the read limits left older runs out (said in
  ## ``read_truncated`` and a caveat).
  type Group = object
    project: Option[string]
    entryPoint: Option[string]
    profile: string
    runs: HashSet[string]
    executions: int
    excluded: int
    peak, duration, cpu, width, write: seq[int64]
  var groups = initOrderedTable[string, Group]()
  for run in runs:
    for e in run.executions:
      let key = run.project.get("\x01") & "\0" & run.entryPoint.get("\x01") &
        "\0" & e.hostProfileId
      if not groups.hasKey(key):
        groups[key] = Group(project: run.project, entryPoint: run.entryPoint,
          profile: e.hostProfileId, runs: initHashSet[string]())
      var g = groups[key]
      if not e.complete:
        inc g.excluded
        groups[key] = g
        continue
      g.runs.incl(run.hostId & "\0" & run.runId)
      inc g.executions
      g.peak.add(e.peakRssBytes)
      g.duration.add(e.durationMillis)
      if e.durationMillis > 0 and
          (e.cpuUserMillis.isSome or e.cpuSysMillis.isSome):
        g.cpu.add(((e.cpuUserMillis.get(0) + e.cpuSysMillis.get(0)) * 1000) div
          e.durationMillis)
      if e.cpuGrantedMilli.isSome:
        g.width.add(e.cpuGrantedMilli.get)
      if e.ioWriteBytes.isSome and e.durationMillis > 0:
        g.write.add((e.ioWriteBytes.get * 1000) div e.durationMillis)
      groups[key] = g
  var keys = toSeq(groups.keys)
  keys.sort()
  result = "{\"status\":" & jsonString($status) &
    ",\"quantile\":" & $q &
    ",\"since_unix_millis\":" & $query.sinceUnixMillis &
    ",\"scope\":" & jsonString(if query.allUsers: "host" else: "owner") &
    ",\"current_host_profile\":" & jsonString(query.currentProfile) &
    ",\"host_write_bytes_per_sec\":" & jsonOptInt(hostWriteBytesPerSec) &
    ",\"read_truncated\":" & $readTruncated &
    ",\"caveats\":" &
      (if readTruncated: "[" & jsonString(readTruncatedCaveat) & "]"
       else: "[]") &
    ",\"profiles\":["
  for i, key in keys:
    let g = groups[key]
    if i > 0: result.add(",")
    result.add("{\"project\":" & jsonOptString(g.project) &
      ",\"entry_point\":" & jsonOptString(g.entryPoint) &
      ",\"host_profile\":" & jsonString(g.profile) &
      ",\"runs\":" & $g.runs.len &
      ",\"executions\":" & $g.executions &
      ",\"executions_incomplete\":" & $g.excluded &
      ",\"peak_memory_bytes\":" & figureJson(g.peak, q) &
      ",\"duration_millis\":" & figureJson(g.duration, q) &
      ",\"mean_cpu_milli\":" & figureJson(g.cpu, q) &
      ",\"granted_width_milli\":" & figureJson(g.width, q) &
      ",\"write_bytes_per_sec\":" & figureJson(g.write, q) & "}")
  result.add("]}")

# ---------------------------------------------------------------------------
# `observations export --format sizing`
# ---------------------------------------------------------------------------

proc u16Array(values: seq[uint16]): string =
  result = "["
  for i, value in values:
    if i > 0: result.add(",")
    result.add($value)
  result.add("]")

proc sizingExportLines*(runs: seq[SizingRun]; ambient: seq[AmbientPoint];
                        query: SizingQuery; policy: RedactionPolicy;
                        generatedAtUnixMillis: int64;
                        readTruncated = false): seq[string] =
  ## The NDJSON records, redacted by ``policy`` (§ Redaction applied to
  ## these records as to a store export). Ids, times and figures are never
  ## redacted, so a redacted export replays to the same numbers.
  var counts: RedactionCounts
  let active = activeCategories(policy)
  proc text(value: string; category: RedactionCategory): string =
    if category in active:
      return redactionToken(category, value)
    if rcPath in active:
      return redactPathsIn(value, rcRelativePath in active, counts)
    value
  proc optText(value: Option[string]; category: RedactionCategory): string =
    if value.isNone: "null" else: jsonString(text(value.get, category))
  var header = "{\"type\":\"header\",\"format\":" & jsonString(SizingExportFormat) &
    ",\"redaction\":{\"policy\":" & jsonString($policy) & ",\"categories\":["
  var first = true
  for category in RedactionCategory:
    if category in active:
      if not first: header.add(",")
      header.add(jsonString($category))
      first = false
  header.add("]},\"generated_at_unix_millis\":" & $generatedAtUnixMillis &
    ",\"current_host_profile\":" & jsonString(query.currentProfile) &
    ",\"query\":{\"project\":" &
      (if query.project.len > 0: jsonString(text(query.project, rcProject))
       else: "null") &
    ",\"entry_point\":" &
      (if query.entryPoint.len > 0: jsonString(text(query.entryPoint, rcProject))
       else: "null") &
    ",\"since_unix_millis\":" & $query.sinceUnixMillis &
    ",\"scope\":" & jsonString(if query.allUsers: "host" else: "owner") &
    "},\"read_truncated\":" & $readTruncated & "}")
  result.add(header)
  for run in runs:
    result.add("{\"type\":\"run\",\"run_id\":" & jsonString(run.runId) &
      ",\"host_id\":" & jsonString(run.hostId) &
      ",\"project\":" & optText(run.project, rcProject) &
      ",\"entry_point\":" & optText(run.entryPoint, rcProject) &
      ",\"started_at_unix_millis\":" & $run.startedAt &
      ",\"complete\":" & $run.complete &
      ",\"open\":" & $run.open & "}")
    for e in run.executions:
      var line = "{\"type\":\"execution\",\"run_id\":" & jsonString(run.runId) &
        ",\"host_id\":" & jsonString(run.hostId) &
        ",\"execution_id\":" & jsonString(e.executionId) &
        ",\"lease_id\":" & (if e.leaseId >= 0: $e.leaseId else: "null") &
        ",\"host_profile_id\":" & jsonString(e.hostProfileId) &
        ",\"command_stats_id\":" & jsonString(text(e.commandStatsId, rcCommand)) &
        ",\"requested_at_unix_millis\":" & jsonOptInt(e.requestedAt) &
        ",\"started_at_unix_millis\":" & $e.startedAt &
        ",\"finished_at_unix_millis\":" & $e.finishedAt &
        ",\"duration_millis\":" & $e.durationMillis &
        ",\"peak_rss_bytes\":" & $e.peakRssBytes &
        ",\"cpu_user_millis\":" & jsonOptInt(e.cpuUserMillis) &
        ",\"cpu_sys_millis\":" & jsonOptInt(e.cpuSysMillis) &
        ",\"cpu_granted_milli\":" & jsonOptInt(e.cpuGrantedMilli) &
        ",\"io_read_bytes\":" & jsonOptInt(e.ioReadBytes) &
        ",\"io_write_bytes\":" & jsonOptInt(e.ioWriteBytes) &
        ",\"complete\":" & $e.complete & ",\"after\":"
      if e.after.isNone:
        line.add("null")
      else:
        line.add("[")
        for i, id in e.after.get:
          if i > 0: line.add(",")
          line.add(jsonString(id))
        line.add("]")
      line.add(",\"cpu_profile\":")
      if e.cpuProfileIntervalMillis > 0 and e.cpuProfile.len > 0:
        line.add("{\"interval_ms\":" & $e.cpuProfileIntervalMillis &
          ",\"samples\":" & u16Array(e.cpuProfile) & "}")
      else:
        line.add("null")
      line.add(",\"memory_profile\":")
      if e.memoryProfileIntervalMillis > 0 and e.memoryProfileMiB.len > 0:
        line.add("{\"interval_ms\":" & $e.memoryProfileIntervalMillis &
          ",\"samples_mib\":" & u16Array(e.memoryProfileMiB) & "}")
      else:
        line.add("null")
      line.add("}")
      result.add(line)
  for point in ambient:
    result.add("{\"type\":\"ambient\",\"host_id\":" & jsonString(point.hostId) &
      ",\"sampled_at_unix_millis\":" & $point.sampledAt &
      ",\"foreign_rss_bytes\":" & $point.foreignRssBytes & "}")
