## Build-wait pressure, as the daemon aggregates it: what invocations
## reported (`PressureReport`) about the time their commands spent held up,
## per host and per session group.
##
## WHAT A REPORT SAYS. An invocation (a Reprobuild build, a `runquota run`)
## measures, over its own wall time, how long at least one of its
## ready-or-running commands was held up (*some*) and how long all of them
## were (*full*), in the manner of Linux PSI
## (<https://docs.kernel.org/accounting/psi.html>), and sends what those
## counters grew by since its previous report together with the wall time
## the report covers, plus each wait of at least a second with its length.
## The daemon computes none of it: it clamps, adds and averages.
##
## THE AVERAGES are exponentially decaying over 10, 60 and 300 s, as PSI's
## are: held-up time per unit of wall time. A report's held-up time is
## spread evenly over the wall time it covers, so a report that covers 30 s
## does not land as a spike in the 10 s average. For one invocation the
## average is its held-up share; for a group or the host it is the SUM over
## the invocations reporting into it (2.0 = two invocations' worth of
## held-up time per second), because the daemon cannot know whether two
## invocations were held up at the same instants.
##
## Decay with a time constant W: a held-up amount d spread evenly over the
## c microseconds before `now` contributes d * (W / c) * (1 - exp(-c / W))
## to the accumulator, the integral of the kernel exp(-s / W) over that
## interval times the rate d / c. The accumulator divided by W is the
## average; at a constant held-up rate r it converges to r.
##
## MEMORY. Every figure here is a fixed-size value (no sequence grows with
## the number of reports or waits), so a group costs the same whatever its
## clients send, and the figures are copied by value to the metrics writer.
## A group's figures live inside its capacity entry (`capacity_metrics`)
## and drop out with it.
##
## SATURATION. Every counter saturates at `high(uint64)` rather than wrap:
## the figures come from any local peer.
##
## Pure: the caller supplies the monotonic time.

import std/[math, strutils]

const
  PressureWindowsSeconds* = [10, 60, 300]
    ## The averaging windows, as Linux PSI's avg10 / avg60 / avg300.
  WaitBucketBoundsSeconds* = [1'u64, 2, 5, 10, 30, 60, 120, 300, 600, 1800]
    ## The wait-length histogram's upper bounds (inclusive, as Prometheus
    ## `le`); a last bucket holds everything longer.
  DefaultLongWaitMillis* = 300_000'u64
    ## `pressure.long-wait`: a wait at least this long is counted as long.

type
  PressureWaitKindIndex* = range[0 .. 2]
    ## The wire ordinals of `PressureWaitKind`: queue, slowdown, class-queue.

  WaitFigures* = object
    count*: uint64
    sumMillis*: uint64
    longWaits*: uint64
      ## Waits at or over the long-wait threshold in force when reported.
    buckets*: array[WaitBucketBoundsSeconds.len + 1, uint64]
      ## Per bucket, NOT cumulative; the last is the +Inf remainder.

  DecayingAverage* = object
    acc*: array[PressureWindowsSeconds.len, float64]
      ## Per window, the decayed held-up microseconds.
    atMillis*: int64
      ## Monotonic milliseconds the accumulators were last decayed to.
    started*: bool
      ## Whether `atMillis` means anything yet.

  PressureFigures* = object
    wallMicros*: uint64
    someMicros*: uint64
    fullMicros*: uint64
    reports*: uint64
    queueOnlyReports*: uint64
    some*: DecayingAverage
    full*: DecayingAverage
    waits*: array[PressureWaitKindIndex, WaitFigures]

  PressureSample* = object
    ## One report's figures after the daemon clamped them.
    wallMicros*: uint64
    someMicros*: uint64
    fullMicros*: uint64
    queueOnly*: bool

proc saturatingAddU64(a, b: uint64): uint64 =
  if b > high(uint64) - a: high(uint64) else: a + b

proc clampReport*(wallMicros, someMicros, fullMicros: uint64;
                  coveredMaxMicros: uint64; queueOnly: bool): PressureSample =
  ## A report's figures as the daemon trusts them: the wall time to what
  ## the session may still claim (`coveredMaxMicros`, see
  ## `remainingWallMicros`), *some* to the wall time and *full* to *some*.
  result.wallMicros = min(wallMicros, coveredMaxMicros)
  result.someMicros = min(someMicros, result.wallMicros)
  result.fullMicros = min(fullMicros, result.someMicros)
  result.queueOnly = queueOnly

const PressureClockSlackMillis* = 1000'i64
  ## How much more wall time, or wait length, than the daemon itself saw
  ## elapse a report may claim: the client's clock and the daemon's are read
  ## at slightly different moments.

proc elapsedLimitMicros*(elapsedMillis: int64): uint64 =
  ## The most wall time a report may claim after `elapsedMillis` of the
  ## daemon's monotonic clock, in microseconds, saturating.
  let millis = uint64(max(0'i64, elapsedMillis) + PressureClockSlackMillis)
  if millis > high(uint64) div 1000'u64: high(uint64) else: millis * 1000'u64

proc remainingWallMicros*(sessionAgeMillis: int64;
                          acceptedWallMicros: uint64): uint64 =
  ## The wall time a session's next report may still claim: its age (plus
  ## the slack) less the wall time its earlier reports were credited with.
  ## A CUMULATIVE budget, not one per report: a per-report allowance would
  ## grant the slack again on every report, so a client sending a thousand
  ## reports a second could claim a thousand seconds of held-up time per
  ## second.
  let budget = elapsedLimitMicros(sessionAgeMillis)
  if budget > acceptedWallMicros: budget - acceptedWallMicros else: 0'u64

proc clampWaitMillis*(lengthMillis: uint64; sessionAgeMillis: int64): uint64 =
  ## A reported wait's length as the daemon trusts it: no longer than the
  ## session has existed (plus the slack). A wait the client measured
  ## before it connected cannot be told from an invented one.
  min(lengthMillis, elapsedLimitMicros(sessionAgeMillis) div 1000'u64)

proc decayTo(avg: var DecayingAverage; nowMillis: int64) =
  if not avg.started:
    avg.started = true
    avg.atMillis = nowMillis
    return
  if nowMillis <= avg.atMillis:
    return
  let dt = float64(nowMillis - avg.atMillis) / 1000.0
  for i, w in PressureWindowsSeconds:
    avg.acc[i] *= exp(-dt / float64(w))
  avg.atMillis = nowMillis

proc addSpread(avg: var DecayingAverage; heldMicros, coveredMicros: uint64;
               nowMillis: int64) =
  ## Add `heldMicros` spread evenly over the `coveredMicros` before now.
  avg.decayTo(nowMillis)
  if heldMicros == 0:
    return
  let held = float64(heldMicros)
  for i, w in PressureWindowsSeconds:
    let wMicros = float64(w) * 1e6
    let c = float64(coveredMicros)
    let weight =
      if c <= 0.0: 1.0
      else: (wMicros / c) * (1.0 - exp(-c / wMicros))
    avg.acc[i] += held * weight

proc averages*(avg: DecayingAverage; nowMillis: int64):
    array[PressureWindowsSeconds.len, float64] =
  ## The averages as of `nowMillis`, without changing `avg` (a reader may
  ## not own it).
  var copy = avg
  copy.decayTo(nowMillis)
  for i, w in PressureWindowsSeconds:
    result[i] = copy.acc[i] / (float64(w) * 1e6)

proc bucketOf(lengthMillis: uint64): int =
  for i, bound in WaitBucketBoundsSeconds:
    if lengthMillis <= bound * 1000'u64:
      return i
  WaitBucketBoundsSeconds.len

proc noteWait*(figures: var PressureFigures; kind: PressureWaitKindIndex;
               lengthMillis, longWaitMillis: uint64) =
  var w = addr figures.waits[kind]
  w.count = saturatingAddU64(w.count, 1)
  w.sumMillis = saturatingAddU64(w.sumMillis, lengthMillis)
  let b = bucketOf(lengthMillis)
  w.buckets[b] = saturatingAddU64(w.buckets[b], 1)
  if lengthMillis >= longWaitMillis:
    w.longWaits = saturatingAddU64(w.longWaits, 1)

proc noteReport*(figures: var PressureFigures; sample: PressureSample;
                 nowMillis: int64) =
  figures.wallMicros = saturatingAddU64(figures.wallMicros, sample.wallMicros)
  figures.someMicros = saturatingAddU64(figures.someMicros, sample.someMicros)
  figures.fullMicros = saturatingAddU64(figures.fullMicros, sample.fullMicros)
  figures.reports = saturatingAddU64(figures.reports, 1)
  if sample.queueOnly:
    figures.queueOnlyReports = saturatingAddU64(figures.queueOnlyReports, 1)
  figures.some.addSpread(sample.someMicros, sample.wallMicros, nowMillis)
  figures.full.addSpread(sample.fullMicros, sample.wallMicros, nowMillis)

proc hasReports*(figures: PressureFigures): bool =
  figures.reports > 0

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

const waitKindNames*: array[PressureWaitKindIndex, string] =
  ["queue", "slowdown", "class-queue"]

proc ratioText*(value: float64): string =
  formatFloat(max(0.0, value), ffDecimal, 6)

proc secondsText(micros: uint64): string =
  $(micros div 1_000_000) & "." & align($(micros mod 1_000_000), 6, '0')

proc millisSecondsText(millis: uint64): string =
  $(millis div 1000) & "." & align($(millis mod 1000), 3, '0')

proc averageJson(avg: DecayingAverage; total: uint64; nowMillis: int64): string =
  let a = avg.averages(nowMillis)
  "{\"avg10\":" & ratioText(a[0]) & ",\"avg60\":" & ratioText(a[1]) &
    ",\"avg300\":" & ratioText(a[2]) & ",\"total_micros\":" & $total & "}"

proc pressureFiguresJson*(figures: PressureFigures; nowMillis: int64): string =
  ## The members of one scope's JSON object (no braces).
  result = "\"some\":" & averageJson(figures.some, figures.someMicros,
      nowMillis) &
    ",\"full\":" & averageJson(figures.full, figures.fullMicros, nowMillis) &
    ",\"wall_micros\":" & $figures.wallMicros &
    ",\"reports\":" & $figures.reports &
    ",\"queue_only_reports\":" & $figures.queueOnlyReports &
    ",\"waits\":{"
  for kind in PressureWaitKindIndex.low .. PressureWaitKindIndex.high:
    let w = figures.waits[kind]
    if kind > 0:
      result.add(",")
    result.add("\"" & waitKindNames[kind] & "\":{\"count\":" & $w.count &
      ",\"sum_millis\":" & $w.sumMillis & ",\"long_waits\":" & $w.longWaits &
      ",\"buckets\":[")
    var cumulative = 0'u64
    for i in 0 .. WaitBucketBoundsSeconds.len:
      cumulative = saturatingAddU64(cumulative, w.buckets[i])
      if i > 0:
        result.add(",")
      let le =
        if i < WaitBucketBoundsSeconds.len: $WaitBucketBoundsSeconds[i]
        else: "\"+Inf\""
      result.add("{\"le_seconds\":" & le & ",\"count\":" & $cumulative & "}")
    result.add("]}")
  result.add("}")

proc expositionFamilies*(output: var string; prefix: string;
                         scopes: openArray[tuple[labels: string,
                           figures: PressureFigures]];
                         nowMillis: int64) =
  ## The pressure series of `scopes` in Prometheus text format, one family
  ## at a time (every sample of a family together, after its HELP and TYPE).
  ## `prefix` is `runquota_host` or `runquota_group`; a scope's `labels`
  ## are its own (empty for the host).
  if scopes.len == 0:
    return
  proc family(output: var string; name, kind, help: string) =
    output.add("# HELP " & name & " " & help & "\n")
    output.add("# TYPE " & name & " " & kind & "\n")
  proc sample(output: var string; name, labels, value: string) =
    output.add(name)
    if labels.len > 0:
      output.add("{" & labels & "}")
    output.add(" " & value & "\n")
  proc join(a, b: string): string =
    if a.len == 0: b elif b.len == 0: a else: a & "," & b
  for which in ["some", "full"]:
    for i, w in PressureWindowsSeconds:
      let name = prefix & "_pressure_" & which & "_avg" & $w
      output.family(name, "gauge", "Build-wait pressure (" & which &
        "): held-up time per second of wall time, decaying over " & $w &
        " s, summed over the invocations reporting.")
      for scope in scopes:
        let avg =
          if which == "some": scope.figures.some else: scope.figures.full
        output.sample(name, scope.labels, ratioText(avg.averages(nowMillis)[i]))
  for which in ["wall", "some", "full"]:
    let name = prefix & "_pressure_" & which & "_seconds_total"
    output.family(name, "counter",
      (case which
       of "wall": "Wall time covered by build-wait pressure reports."
       of "some": "Time in which at least one reported command was held up."
       else: "Time in which every reported command was held up."))
    for scope in scopes:
      let value =
        case which
        of "wall": scope.figures.wallMicros
        of "some": scope.figures.someMicros
        else: scope.figures.fullMicros
      output.sample(name, scope.labels, secondsText(value))
  let hist = prefix & "_pressure_wait_seconds"
  output.family(hist, "histogram",
    "Lengths of reported waits of at least a second, by kind.")
  for scope in scopes:
    for kind in PressureWaitKindIndex.low .. PressureWaitKindIndex.high:
      let w = scope.figures.waits[kind]
      let labels = join(scope.labels, "kind=\"" & waitKindNames[kind] & "\"")
      var cumulative = 0'u64
      for i in 0 .. WaitBucketBoundsSeconds.len:
        cumulative = saturatingAddU64(cumulative, w.buckets[i])
        let le =
          if i < WaitBucketBoundsSeconds.len: $WaitBucketBoundsSeconds[i]
          else: "+Inf"
        output.sample(hist & "_bucket", join(labels, "le=\"" & le & "\""),
          $cumulative)
      output.sample(hist & "_sum", labels, millisSecondsText(w.sumMillis))
      output.sample(hist & "_count", labels, $w.count)
  let long = prefix & "_pressure_long_waits_total"
  output.family(long, "counter",
    "Reported waits at or over the long-wait threshold, by kind.")
  for scope in scopes:
    for kind in PressureWaitKindIndex.low .. PressureWaitKindIndex.high:
      output.sample(long, join(scope.labels, "kind=\"" & waitKindNames[kind] &
        "\""), $scope.figures.waits[kind].longWaits)
