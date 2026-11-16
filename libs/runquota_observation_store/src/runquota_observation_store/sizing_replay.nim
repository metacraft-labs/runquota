## Sizing replay: how much memory N dedicated CPUs need for a project's
## recorded job mix.
##
## THE DEFINITION. This module implements these steps, and the reference
## offline replay ``scripts/sizing-replay.mjs`` is a second, independent
## implementation of them: the two must give the same figures for the same
## records, which the "offline_replay_matches_daemon" case of
## ``tests/integration/t_sizing_end_to_end.nim`` checks.
##
## 1. Runs. A candidate run is replayed unless, under the first reason that
##    applies, it is `empty` (no executions), `open` (its session is still
##    registered), `incomplete` (the run or an execution is not complete),
##    `mixed-profiles` or `other-profile` (its first execution's host
##    profile is not the asked one; both only without `--host-profile all`),
##    or `over-budget` (see THE BUDGET). Each exclusion is counted.
## 2. Order. Executions are ordered by (request time, lease id, execution
##    id); one without a request time uses its start. ``T0`` is the earliest
##    of the run's start and every ordering time.
## 3. Tokens: ``min(N, max(1, ceil(width / 1000)))``, width 1000 when not
##    recorded.
## 4. Duration at N: unchanged when the tokens cover the width; otherwise
##    stretched by the CPU profile (each sample ``max(len, ceil(len * c /
##    W'))``), else by the CPU totals (``max(d, ceil(cpu * 1000 / W'))``),
##    else as if the whole width was used (``ceil(d * width / W')``).
## 5. Memory: the memory profile mapped onto the replayed duration by
##    ``t' = floor(t * d' / d)``, else the peak for the whole duration.
## 6. Ready time: when the last earlier execution its `after` list names has
##    finished; without a usable list, its recorded offset shifted by the
##    largest delay (replayed minus recorded finish) of the earlier
##    executions that had finished when it was requested.
## 7. Admission: at each instant, retire what has ended, then start, in
##    order, every ready execution whose tokens fit (backfill).
## 8. Per run: the peak of the summed memory, the makespan, and the peak of
##    the summed write rate (``floor(write_bytes * 1000 / d')``).
## 9. Across runs: the nearest-rank ``q`` quantile (``k = max(1, ceil(q * n
##    - 1e-9))``, 1-based) and the maximum, per N.
## 10. Baseline: the foreign RSS of the ambient samples inside some replayed
##    run's ``[T0, last recorded finish]``, at the same quantile; unknown,
##    never 0, without a sample.
##
## THE BUDGET. The daemon answers on its request path, and one run costs
## about ``m^2`` steps per N for ``m`` executions. ``computeSizing``
## therefore spends at most ``workBudget`` units of ``m^2 * |N|``: runs are
## charged newest first, and a run that no longer fits is counted
## `over-budget` instead of replayed, so an answer is bounded and says it is
## partial. The offline replay has no budget: over an export it gives the
## figures of every run the export carries.
##
## PURE ON PURPOSE. Nothing here reads a store, a clock or the environment:
## a run is handed in as values and the figures come back as values, so the
## replay can be tested over hand-built runs whose answer is known (eight
## 1-GiB jobs at N = 2 hold at most 2 GiB at once) without a daemon, and
## the daemon and the tests run exactly the same code.
##
## INTEGERS EVERYWHERE BUT THE QUANTILE. Times are milliseconds, memory is
## bytes, widths milli-CPUs, and every division that the specification
## rounds is written out with its rounding. The only floating-point value
## is ``q``, used once, in ``nearestRankIndex``. That is what lets an
## implementation in another language agree to the byte rather than to a
## tolerance.

import std/[algorithm, math, options, tables]

type
  SizingExecution* = object
    ## One recorded execution, as the replay reads it.
    executionId*: string
    leaseId*: int64
      ## -1 when the execution held no lease.
    hostProfileId*: string
      ## "" when the row names none.
    commandStatsId*: string
      ## Carried for the export; the replay does not read it.
    ioReadBytes*: Option[int64]
      ## Carried for the export; the replay does not read it.
    requestedAt*: Option[int64]
      ## Unix ms; none for a row recorded before schema 8.
    startedAt*: int64
    finishedAt*: int64
    durationMillis*: int64
    peakRssBytes*: int64
    cpuUserMillis*: Option[int64]
    cpuSysMillis*: Option[int64]
    cpuGrantedMilli*: Option[int64]
    ioWriteBytes*: Option[int64]
    after*: Option[seq[string]]
    cpuProfileIntervalMillis*: int64
    cpuProfile*: seq[uint16]
      ## Milli-CPUs per interval; empty when there is none.
    memoryProfileIntervalMillis*: int64
    memoryProfileMiB*: seq[uint16]
      ## MiB per interval; empty when there is none.
    complete*: bool
      ## ``capture_completeness = 'complete'``.

  SizingRun* = object
    runId*: string
    hostId*: string
    project*: Option[string]
    entryPoint*: Option[string]
    startedAt*: int64
    complete*: bool
    open*: bool
      ## Its session is still registered: it may still add executions.
    executions*: seq[SizingExecution]

  ReplayCounts* = object
    ## How many executions of the replayed runs lacked a figure the replay
    ## would have liked, so an answer can say what it was computed from.
    executions*: int
    readyTimeUnknown*: int
    widthUnknown*: int
    memoryFromPeak*: int
    cpuUnknown*: int
      ## Had neither a CPU profile nor CPU totals: where it ran wider than
      ## an N allows, it was stretched as if it had used its whole width.

  RunReplay* = object
    peakMemoryBytes*: int64
    makespanMillis*: int64
    peakWriteBytesPerSecond*: int64

  RunExclusion* = enum
    exIncluded = "included"
    exIncomplete = "incomplete"
    exOpen = "open"
    exEmpty = "empty"
    exOtherProfile = "other-profile"
    exMixedProfiles = "mixed-profiles"
    exOverBudget = "over-budget"
      ## Would have been replayed, but the answer's work budget was spent
      ## on newer runs.

const
  DefaultSizingQuantile* = 0.99
  DefaultReplayWorkBudget* = 100_000_000'i64
    ## ``m^2 * |N|`` units one answer may spend (THE BUDGET above). One unit
    ## is one pass of the event loop over one execution, about 5 ns in a
    ## release build (measured over runs of 1000-5000 executions), so a
    ## worst-case answer holds the daemon's request path for about half a
    ## second; a run of 2500 executions still fits at 16 N, and one of 5700
    ## at 3.
  MiB = 1024'i64 * 1024'i64

proc ceilDiv(a, b: int64): int64 =
  ## ``ceil(a / b)`` for ``a >= 0``, ``b > 0``.
  if a <= 0: 0'i64 else: (a + b - 1) div b

proc nearestRankIndex*(n: int; q: float64): int =
  ## The 0-based index of the nearest-rank ``q``-quantile of ``n`` sorted
  ## values: ``max(1, ceil(q * n - 1e-9)) - 1``. The ``1e-9`` keeps a
  ## product that is mathematically an integer (0.99 * 100) from rounding
  ## up to the next rank through its binary representation.
  if n <= 0:
    return -1
  let rank = max(1, int(ceil(q * float64(n) - 1e-9)))
  min(n, rank) - 1

proc nearestRank*(values: seq[int64]; q: float64): int64 =
  ## The nearest-rank quantile; 0 for no values (callers report the count
  ## beside it, so an empty set is never read as a measured 0).
  if values.len == 0:
    return 0
  var sorted = values
  sorted.sort()
  sorted[nearestRankIndex(sorted.len, q)]

proc orderTime(e: SizingExecution): int64 =
  if e.requestedAt.isSome: e.requestedAt.get else: e.startedAt

proc runProfile*(run: SizingRun; mixed: var bool): string =
  ## A run's host profile: its first execution's (in replay order). ``mixed``
  ## when another execution names a different one.
  mixed = false
  if run.executions.len == 0:
    return ""
  var first = 0
  for i in 1 ..< run.executions.len:
    let a = run.executions[i]
    let b = run.executions[first]
    if (orderTime(a), a.leaseId, a.executionId) <
        (orderTime(b), b.leaseId, b.executionId):
      first = i
  result = run.executions[first].hostProfileId
  for e in run.executions:
    if e.hostProfileId != result:
      mixed = true

proc classifyRun*(run: SizingRun; currentProfile: string;
                  allProfiles: bool): RunExclusion =
  ## Step 1 of the definition: whether a candidate run is replayed, and if
  ## not, why. The order of the tests is the order the counts are reported
  ## in, so a run is counted once, under its first reason.
  if run.executions.len == 0:
    return exEmpty
  if run.open:
    return exOpen
  if not run.complete:
    return exIncomplete
  for e in run.executions:
    if not e.complete:
      return exIncomplete
  var mixed = false
  let profile = run.runProfile(mixed)
  if not allProfiles:
    if mixed:
      return exMixedProfiles
    if profile != currentProfile:
      return exOtherProfile
  exIncluded

proc stretchedDuration(e: SizingExecution; width, granted: int64): int64 =
  ## Step 4: the duration at ``granted`` milli-CPUs of an execution that
  ## ran at ``width``.
  let d = max(0'i64, e.durationMillis)
  if granted >= width:
    return d
  let interval = e.cpuProfileIntervalMillis
  if interval > 0 and e.cpuProfile.len > 0 and d > 0:
    let k = min(e.cpuProfile.len, int(ceilDiv(d, interval)))
    var total = 0'i64
    for i in 0 ..< k:
      let length =
        if i < k - 1: interval else: d - int64(k - 1) * interval
      let c = int64(e.cpuProfile[i])
      total += max(length, ceilDiv(length * c, granted))
    return total
  if e.cpuUserMillis.isSome or e.cpuSysMillis.isSome:
    let cpu = e.cpuUserMillis.get(0) + e.cpuSysMillis.get(0)
    return max(d, ceilDiv(cpu * 1000, granted))
  ceilDiv(d * width, granted)

type
  Segment = tuple[startAt, endAt: int64; amount: int64]

proc peakOf(segments: seq[Segment]): int64 =
  ## The maximum of the sum of ``[start, end)`` segments. All changes at
  ## one instant are applied before the sum is read, so a segment ending at
  ## t and another starting at t are never counted together.
  var events: seq[(int64, int64)] = @[]
  for s in segments:
    if s.endAt > s.startAt and s.amount != 0:
      events.add((s.startAt, s.amount))
      events.add((s.endAt, -s.amount))
  events.sort()
  var current = 0'i64
  var i = 0
  while i < events.len:
    let t = events[i][0]
    while i < events.len and events[i][0] == t:
      current += events[i][1]
      inc i
    result = max(result, current)

proc replayRun*(run: SizingRun; n: int; counts: var ReplayCounts;
                countIt = true): RunReplay =
  ## Steps 2-8 of the definition for one run at ``n`` CPU tokens.
  ## ``countIt`` adds this run's missing-data counts to ``counts`` (done
  ## once per run, not once per N).
  let n = max(1, n)
  var es = run.executions
  es.sort(proc (a, b: SizingExecution): int =
    cmp((orderTime(a), a.leaseId, a.executionId),
        (orderTime(b), b.leaseId, b.executionId)))
  let m = es.len
  if m == 0:
    return
  # Step 2: the origin and the recorded times relative to it.
  var t0 = run.startedAt
  for e in es:
    t0 = min(t0, orderTime(e))
  var req = newSeq[int64](m)
  var recFinish = newSeq[int64](m)
  var width = newSeq[int64](m)
  var tokens = newSeq[int](m)
  var duration = newSeq[int64](m)
  var index = initTable[string, int]()
  for i, e in es:
    index[e.executionId] = i
  for i, e in es:
    req[i] = max(0'i64, orderTime(e) - t0)
    recFinish[i] = e.finishedAt - t0
    # Step 3.
    width[i] = if e.cpuGrantedMilli.isSome: max(0'i64, e.cpuGrantedMilli.get)
               else: 1000'i64
    tokens[i] = min(n, max(1, int(ceilDiv(width[i], 1000))))
    # Step 4.
    duration[i] = stretchedDuration(e, width[i], int64(tokens[i]) * 1000)
    if countIt:
      inc counts.executions
      if e.requestedAt.isNone: inc counts.readyTimeUnknown
      if e.cpuGrantedMilli.isNone: inc counts.widthUnknown
      if e.memoryProfileIntervalMillis <= 0 or e.memoryProfileMiB.len == 0:
        inc counts.memoryFromPeak
      if (e.cpuProfileIntervalMillis <= 0 or e.cpuProfile.len == 0) and
          e.cpuUserMillis.isNone and e.cpuSysMillis.isNone:
        inc counts.cpuUnknown
  # Step 6: who each execution waits for. A declared predecessor must come
  # earlier in the order (which rules out a cycle); with none usable, the
  # recorded-offset rule applies, whose potential predecessors are the
  # earlier executions that had finished when it was requested.
  var usesAfter = newSeq[bool](m)
  var pending = newSeq[int](m)
  var dependents = newSeq[seq[int]](m)
  for i, e in es:
    if e.after.isSome:
      for id in e.after.get:
        if index.hasKey(id):
          let j = index[id]
          if j < i and i notin dependents[j]:
            dependents[j].add(i)
            inc pending[i]
            usesAfter[i] = true
  # The offset rule's predecessors are NOT materialised as edges: there can
  # be ``m^2 / 2`` of them, and a run of many executions would cost that
  # much memory. A retiring ``j`` releases them by the same test instead
  # (``offsetDependant``), and only the count is kept here.
  for i in 0 ..< m:
    if not usesAfter[i]:
      for j in 0 ..< i:
        if recFinish[j] <= req[i]:
          inc pending[i]
  var readyKnown = newSeq[bool](m)
  var readyAt = newSeq[int64](m)
  var anyShift = newSeq[bool](m)
  var shift = newSeq[int64](m)
  var latestPredFinish = newSeq[int64](m)
  for i in 0 ..< m:
    if pending[i] == 0:
      readyKnown[i] = true
      readyAt[i] = req[i]
  # Step 7: the event simulation.
  var startAt = newSeq[int64](m)
  var finishAt = newSeq[int64](m)
  var started = newSeq[bool](m)
  var done = newSeq[bool](m)
  var running: seq[int] = @[]
  var free = n
  var finishedCount = 0
  var t = 0'i64
  while finishedCount < m:
    # Retire everything that has ended by now, releasing its dependants.
    var retired = true
    while retired:
      retired = false
      var still: seq[int] = @[]
      for r in running:
        if finishAt[r] <= t:
          done[r] = true
          inc finishedCount
          free += tokens[r]
          retired = true
          template release(i: int) =
            dec pending[i]
            if usesAfter[i]:
              latestPredFinish[i] = max(latestPredFinish[i], finishAt[r])
            else:
              let delay = finishAt[r] - recFinish[r]
              if not anyShift[i] or delay > shift[i]:
                shift[i] = delay
              anyShift[i] = true
            if pending[i] == 0:
              readyKnown[i] = true
              readyAt[i] =
                if usesAfter[i]: latestPredFinish[i]
                else: max(0'i64, req[i] + shift[i])
          for i in dependents[r]:
            release(i)
          # The offset rule's dependants of ``r``: every later execution
          # without a usable `after` list that was requested once ``r`` had
          # finished in the recording.
          for i in r + 1 ..< m:
            if not usesAfter[i] and recFinish[r] <= req[i]:
              release(i)
        else:
          still.add(r)
      running = still
      # Start, in order, every ready execution that fits (backfill).
      for i in 0 ..< m:
        if not started[i] and readyKnown[i] and readyAt[i] <= t and
            tokens[i] <= free:
          started[i] = true
          startAt[i] = t
          finishAt[i] = t + duration[i]
          free -= tokens[i]
          running.add(i)
          if duration[i] == 0:
            retired = true
    if finishedCount >= m:
      break
    var next = high(int64)
    for r in running:
      if finishAt[r] > t:
        next = min(next, finishAt[r])
    for i in 0 ..< m:
      if not started[i] and readyKnown[i] and readyAt[i] > t:
        next = min(next, readyAt[i])
    if next == high(int64):
      # Unreachable by construction (the lowest unstarted execution always
      # becomes startable once nothing runs); stop rather than spin.
      break
    t = next
  # Step 8: the run's figures.
  var memory: seq[Segment] = @[]
  var writes: seq[Segment] = @[]
  for i, e in es:
    if not started[i]:
      continue
    let d = max(0'i64, e.durationMillis)
    let dPrime = duration[i]
    result.makespanMillis = max(result.makespanMillis, finishAt[i])
    let interval = e.memoryProfileIntervalMillis
    if interval > 0 and e.memoryProfileMiB.len > 0:
      if d > 0:
        for j, mib in e.memoryProfileMiB:
          let a = int64(j) * interval
          if a >= d:
            break
          let b = min(int64(j + 1) * interval, d)
          let aPrime = (a * dPrime) div d
          let bPrime = (b * dPrime) div d
          if bPrime > aPrime:
            memory.add((startAt[i] + aPrime, startAt[i] + bPrime,
              int64(mib) * MiB))
    else:
      memory.add((startAt[i], startAt[i] + dPrime, max(0'i64, e.peakRssBytes)))
    if e.ioWriteBytes.isSome and dPrime > 0:
      writes.add((startAt[i], startAt[i] + dPrime,
        (max(0'i64, e.ioWriteBytes.get) * 1000) div dPrime))
  result.peakMemoryBytes = peakOf(memory)
  result.peakWriteBytesPerSecond = peakOf(writes)

type
  AmbientPoint* = object
    hostId*: string
    sampledAt*: int64
    foreignRssBytes*: int64

  SizeAtN* = object
    cpus*: int
    memoryQuantileBytes*: int64
    memoryMaxBytes*: int64
    makespanQuantileMillis*: int64
    makespanMaxMillis*: int64
    writeQuantileBytesPerSecond*: int64
    writeMaxBytesPerSecond*: int64

  SizingFigures* = object
    ## Everything a sizing answer says, before it is rendered.
    candidates*: int
    exclusions*: array[RunExclusion, int]
    profiles*: seq[string]
      ## The host profiles of the replayed runs, sorted.
    counts*: ReplayCounts
    baselineSamples*: int
    baselineQuantileBytes*: int64
    baselineMaxBytes*: int64
    sizes*: seq[SizeAtN]

proc runWindow*(run: SizingRun): (int64, int64) =
  ## ``[T0, last recorded finish]`` of a run (step 10's window).
  var t0 = run.startedAt
  var last = run.startedAt
  for e in run.executions:
    t0 = min(t0, orderTime(e))
    last = max(last, e.finishedAt)
  (t0, last)

proc replayCost*(run: SizingRun; cpuCounts: int): int64 =
  ## What replaying ``run`` at ``cpuCounts`` N charges to the budget.
  let m = int64(run.executions.len)
  m * m * int64(max(0, cpuCounts))

proc newerFirst(a, b: SizingRun): int =
  ## Newest run first, by (start, host id, run id), so the budget is spent
  ## in an order that does not depend on how the rows were read.
  -cmp((a.startedAt, a.hostId, a.runId), (b.startedAt, b.hostId, b.runId))

proc computeSizing*(runs: seq[SizingRun]; ambient: seq[AmbientPoint];
                    cpus: seq[int]; q: float64; currentProfile: string;
                    allProfiles: bool;
                    workBudget = DefaultReplayWorkBudget): SizingFigures =
  ## Steps 1-10 over every candidate run: which are replayed, the replay at
  ## each N, and the baseline. At most ``workBudget`` is spent (THE BUDGET);
  ## the runs it does not reach are counted ``exOverBudget``.
  result.candidates = runs.len
  var ordered = runs
  ordered.sort(newerFirst)
  var included: seq[SizingRun] = @[]
  var profiles: seq[string] = @[]
  var spent = 0'i64
  for run in ordered:
    var verdict = classifyRun(run, currentProfile, allProfiles)
    if verdict == exIncluded:
      let cost = replayCost(run, cpus.len)
      if cost > workBudget - spent:
        verdict = exOverBudget
      else:
        spent += cost
    inc result.exclusions[verdict]
    if verdict == exIncluded:
      included.add(run)
      var mixed = false
      let profile = run.runProfile(mixed)
      for e in run.executions:
        if e.hostProfileId notin profiles:
          profiles.add(e.hostProfileId)
      if profile notin profiles:
        profiles.add(profile)
  profiles.sort()
  result.profiles = profiles
  for ni, n in cpus:
    var peaks, spans, writes: seq[int64] = @[]
    for run in included:
      let replay = replayRun(run, n, result.counts, countIt = ni == 0)
      peaks.add(replay.peakMemoryBytes)
      spans.add(replay.makespanMillis)
      writes.add(replay.peakWriteBytesPerSecond)
    var size = SizeAtN(cpus: n)
    if peaks.len > 0:
      size.memoryQuantileBytes = nearestRank(peaks, q)
      size.memoryMaxBytes = max(peaks)
      size.makespanQuantileMillis = nearestRank(spans, q)
      size.makespanMaxMillis = max(spans)
      size.writeQuantileBytesPerSecond = nearestRank(writes, q)
      size.writeMaxBytesPerSecond = max(writes)
    result.sizes.add(size)
  # Step 10: the ambient samples inside some replayed run's window, each
  # counted once however many windows it falls in. The windows are merged
  # per host and searched, so the cost is (samples + runs) * log, not their
  # product.
  var windows = initTable[string, seq[(int64, int64)]]()
  for run in included:
    windows.mgetOrPut(run.hostId, @[]).add(run.runWindow())
  for host, list in windows.mpairs:
    list.sort()
    var merged: seq[(int64, int64)] = @[]
    for (a, b) in list:
      if merged.len > 0 and a <= merged[^1][1]:
        merged[^1][1] = max(merged[^1][1], b)
      else:
        merged.add((a, b))
    list = merged
  var foreign: seq[int64] = @[]
  for point in ambient:
    if not windows.hasKey(point.hostId):
      continue
    let list = windows[point.hostId]
    # The last window starting at or before the sample.
    let k = list.upperBound((point.sampledAt, high(int64))) - 1
    if k >= 0 and point.sampledAt <= list[k][1]:
      foreign.add(point.foreignRssBytes)
  result.baselineSamples = foreign.len
  if foreign.len > 0:
    result.baselineQuantileBytes = nearestRank(foreign, q)
    result.baselineMaxBytes = max(foreign)
