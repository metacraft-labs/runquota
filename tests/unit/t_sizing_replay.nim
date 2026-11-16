## The sizing replay, step by step, over hand-built runs whose answer is
## known (the numbered definition in ``sizing_replay``'s module comment).
##
## WHY HAND-BUILT RUNS AND NOT A DAEMON. The replay (`sizing_replay`) is a
## pure function of the recorded rows, and what is guarded here is that
## function: tokens, ready times, `after` chains, stretching, memory
## profiles, quantiles, the baseline and the exclusions. A daemon would only
## add rows nobody can make with these exact figures (eight jobs requested
## in the same millisecond, each holding exactly 1 GiB for exactly 10 s).
## The same code is what the daemon runs; the end-to-end path over a real
## `runquotad` is `tests/integration/t_sizing_end_to_end.nim`.
##
## FALSIFYING MUTATIONS (each applied by hand and seen to fail):
## * `replay_respects_tokens_and_after`: ignoring `after` (never setting
##   `usesAfter`) replays the chain at its recorded offsets, all eight at
##   once at N = 8: 8 GiB, and the chain cases fail.
## * tokens: starting an execution without checking that its tokens fit
##   makes N = 2 hold 8 GiB.
## * quantile: taking the maximum for the quantile makes the 0.5 case read
##   the largest value.
## * exclusion: dropping the completeness test replays the incomplete run
##   and the counts disagree.
## * work budget: not charging a run's cost (or charging oldest first)
##   replays the run the budget had no room for, and the budget case fails.

import std/[options, unittest]

import runquota_observation_store/sizing_replay

const
  GiB = 1024'i64 * 1024 * 1024
  MiB = 1024'i64 * 1024

proc job(id: string; lease: int64; requestedAt, durationMillis: int64;
         peak: int64; width = 1000'i64; after = none(seq[string])):
    SizingExecution =
  SizingExecution(executionId: id, leaseId: lease, hostProfileId: "p1",
    requestedAt: some(requestedAt), startedAt: requestedAt,
    finishedAt: requestedAt + durationMillis, durationMillis: durationMillis,
    peakRssBytes: peak, cpuGrantedMilli: some(width), after: after,
    complete: true)

proc eightJobs(chain: bool): SizingRun =
  ## Eight 1-CPU, 1-GiB, 10-s jobs all requested at t = 1000; with
  ## ``chain`` each declares the previous one in `after`.
  result = SizingRun(runId: "r", hostId: "h", startedAt: 1000, complete: true)
  for i in 0 ..< 8:
    let after =
      if chain and i > 0: some(@["e" & $(i - 1)])
      elif chain: some(newSeq[string]())
      else: none(seq[string])
    result.executions.add(job("e" & $i, int64(i + 1), 1000, 10_000, GiB,
      after = after))

proc replayAt(run: SizingRun; n: int): RunReplay =
  var counts: ReplayCounts
  replayRun(run, n, counts)

suite "replay_respects_tokens_and_after":
  test "no after list: N=2 never holds more than 2 GiB, N=8 reaches 8 GiB":
    let run = eightJobs(chain = false)
    let two = run.replayAt(2)
    check two.peakMemoryBytes == 2 * GiB
    check two.makespanMillis == 40_000
    let eight = run.replayAt(8)
    check eight.peakMemoryBytes == 8 * GiB
    check eight.makespanMillis == 10_000

  test "a declared chain gives 1 GiB at every N":
    let run = eightJobs(chain = true)
    for n in [1, 2, 4, 8, 16]:
      let r = run.replayAt(n)
      checkpoint "N=" & $n & " peak " & $r.peakMemoryBytes
      check r.peakMemoryBytes == GiB
      check r.makespanMillis == 80_000

suite "sizing replay rules":
  test "a wide execution takes at most N tokens and is stretched":
    # 4 CPUs for 10 s with totals of 40 CPU-s: at N = 2 it takes 2 tokens
    # and 20 s; a 1-CPU job beside it waits for a token.
    var run = SizingRun(runId: "r", hostId: "h", startedAt: 0, complete: true)
    var wide = job("w", 1, 0, 10_000, GiB, width = 4000)
    wide.cpuUserMillis = some(40_000'i64)
    wide.cpuSysMillis = some(0'i64)
    run.executions.add(wide)
    run.executions.add(job("n", 2, 0, 5_000, GiB))
    let r = run.replayAt(2)
    check r.makespanMillis == 25_000
    check r.peakMemoryBytes == GiB
    let wider = run.replayAt(8)
    check wider.makespanMillis == 10_000
    check wider.peakMemoryBytes == 2 * GiB

  test "the CPU profile stretches only the intervals that ran wider":
    # Two 1-s samples: 4000 then 1000 milli-CPUs. At 2 CPUs the first takes
    # 2 s and the second stays 1 s.
    var run = SizingRun(runId: "r", hostId: "h", startedAt: 0, complete: true)
    var e = job("e", 1, 0, 2_000, GiB, width = 4000)
    e.cpuProfileIntervalMillis = 1000
    e.cpuProfile = @[4000'u16, 1000'u16]
    run.executions.add(e)
    check run.replayAt(2).makespanMillis == 3_000
    check run.replayAt(4).makespanMillis == 2_000

  test "neither profile nor totals: stretched as if the whole width was used":
    var run = SizingRun(runId: "r", hostId: "h", startedAt: 0, complete: true)
    run.executions.add(job("e", 1, 0, 3_000, GiB, width = 3000))
    var counts: ReplayCounts
    check replayRun(run, 1, counts).makespanMillis == 9_000
    check counts.cpuUnknown == 1

  test "a memory profile is held per interval, scaled onto the replay":
    # 2 s at 100 MiB then 300 MiB, beside a 1-s, 50 MiB job started with it.
    var run = SizingRun(runId: "r", hostId: "h", startedAt: 0, complete: true)
    var e = job("e", 1, 0, 2_000, 999 * GiB)
    e.memoryProfileIntervalMillis = 1000
    e.memoryProfileMiB = @[100'u16, 300'u16]
    run.executions.add(e)
    run.executions.add(job("f", 2, 0, 1_000, 50 * MiB))
    var counts: ReplayCounts
    let r = replayRun(run, 2, counts)
    check r.peakMemoryBytes == 300 * MiB
    check counts.memoryFromPeak == 1

  test "without after, a job is shifted by the delay of what finished before it":
    # A (1 CPU, 10 s) finished at 10 s; B was requested at 12 s. At N = 1
    # with a 1-CPU, 10-s job C requested at 0 ahead of A, A finishes at
    # 20 s (10 s late), so B is ready at 22 s, not 12 s.
    var run = SizingRun(runId: "r", hostId: "h", startedAt: 0, complete: true)
    run.executions.add(job("c", 1, 0, 10_000, GiB))
    var a = job("a", 2, 0, 10_000, GiB)
    run.executions.add(a)
    run.executions.add(job("b", 3, 12_000, 1_000, GiB))
    # Recorded: C and A ran together (N was 2 then), both finished at 10 s.
    let r = run.replayAt(1)
    check r.makespanMillis == 23_000
    check run.replayAt(2).makespanMillis == 13_000

  test "an after naming a later execution is ignored (no cycle)":
    var run = SizingRun(runId: "r", hostId: "h", startedAt: 0, complete: true)
    run.executions.add(job("a", 1, 0, 1_000, GiB, after = some(@["b"])))
    run.executions.add(job("b", 2, 0, 1_000, GiB, after = some(@["a"])))
    let r = run.replayAt(2)
    check r.makespanMillis == 2_000
    check r.peakMemoryBytes == GiB

  test "write rate is replayed like memory":
    var run = SizingRun(runId: "r", hostId: "h", startedAt: 0, complete: true)
    var a = job("a", 1, 0, 2_000, GiB)
    a.ioWriteBytes = some(200 * MiB)
    var b = job("b", 2, 0, 2_000, GiB)
    b.ioWriteBytes = some(100 * MiB)
    run.executions.add(a)
    run.executions.add(b)
    check run.replayAt(2).peakWriteBytesPerSecond == 150 * MiB
    check run.replayAt(1).peakWriteBytesPerSecond == 100 * MiB

suite "quantiles, baseline and exclusions":
  test "nearest rank":
    var values: seq[int64] = @[]
    for i in 1 .. 100:
      values.add(int64(i))
    check nearestRank(values, 0.99) == 99
    check nearestRank(values, 0.5) == 50
    check nearestRank(values, 1.0) == 100
    check nearestRank(@[7'i64], 0.01) == 7

  test "runs are excluded and counted, the baseline read from their windows":
    var runs: seq[SizingRun] = @[]
    for i in 0 ..< 4:
      var run = SizingRun(runId: "r" & $i, hostId: "h",
        startedAt: int64(i) * 100_000, complete: true)
      run.executions.add(job("e" & $i, int64(i + 1), int64(i) * 100_000,
        10_000, int64(i + 1) * GiB))
      runs.add(run)
    runs[1].complete = false
    runs[2].open = true
    runs.add(SizingRun(runId: "empty", hostId: "h", startedAt: 0,
      complete: true))
    var other = runs[0]
    other.runId = "other"
    other.executions[0].hostProfileId = "p2"
    runs.add(other)
    let ambient = @[
      AmbientPoint(hostId: "h", sampledAt: 5_000, foreignRssBytes: 3 * GiB),
      AmbientPoint(hostId: "h", sampledAt: 150_000, foreignRssBytes: 9 * GiB),
      AmbientPoint(hostId: "h", sampledAt: 305_000, foreignRssBytes: GiB),
      AmbientPoint(hostId: "other-host", sampledAt: 5_000,
        foreignRssBytes: 50 * GiB)]
    let figures = computeSizing(runs, ambient, @[1, 2], 0.5, "p1", false)
    check figures.candidates == 6
    check figures.exclusions[exIncluded] == 2
    check figures.exclusions[exIncomplete] == 1
    check figures.exclusions[exOpen] == 1
    check figures.exclusions[exEmpty] == 1
    check figures.exclusions[exOtherProfile] == 1
    check figures.sizes.len == 2
    check figures.sizes[0].memoryMaxBytes == 4 * GiB
    check figures.sizes[0].memoryQuantileBytes == GiB
    # Only the samples inside the two replayed runs' windows, on their host.
    check figures.baselineSamples == 2
    check figures.baselineMaxBytes == 3 * GiB
    check figures.baselineQuantileBytes == GiB
    let all = computeSizing(runs, ambient, @[1], 0.5, "p1", true)
    check all.exclusions[exIncluded] == 3
    check all.profiles == @["p1", "p2"]

suite "the replay's work is bounded":
  test "the budget replays the newest runs that fit and counts the rest":
    # Three complete runs of ten executions each cost 10^2 per N; a budget
    # of two runs at two N replays the two newest and counts the oldest
    # `over-budget`, never a partial run.
    var runs: seq[SizingRun] = @[]
    for i in 0 ..< 3:
      var run = SizingRun(runId: "r" & $i, hostId: "h",
        startedAt: int64(i) * 100_000, complete: true)
      for k in 0 ..< 10:
        run.executions.add(job("e" & $i & "-" & $k, int64(i * 10 + k + 1),
          int64(i) * 100_000, 1_000, int64(i + 1) * GiB))
      runs.add(run)
    check replayCost(runs[0], 2) == 200
    let figures = computeSizing(runs, @[], @[1, 8], 0.01, "p1", false,
      workBudget = 400)
    check figures.exclusions[exIncluded] == 2
    check figures.exclusions[exOverBudget] == 1
    # The oldest run (1-GiB jobs) is the one left out: the smallest peak at
    # N = 8 is the second run's eight concurrent 2-GiB jobs, not 8 GiB.
    check figures.sizes[1].memoryQuantileBytes == 16 * GiB
    check figures.sizes[1].memoryMaxBytes == 24 * GiB
    check figures.counts.executions == 20
    let unbounded = computeSizing(runs, @[], @[1, 8], 1.0, "p1", false)
    check unbounded.exclusions[exIncluded] == 3
    check unbounded.exclusions[exOverBudget] == 0

  test "a run of many executions replays without quadratic memory":
    # 4000 executions requested one after another, each finishing before
    # the next is requested: the recorded-offset rule gives every one of
    # them all earlier executions as potential predecessors (8 million
    # pairs), which the replay must not materialise. It replays them one
    # at a time at any N.
    var run = SizingRun(runId: "big", hostId: "h", startedAt: 0,
      complete: true)
    for i in 0 ..< 4000:
      run.executions.add(job("e" & $i, int64(i + 1), int64(i) * 10, 5, GiB))
    let r = run.replayAt(8)
    check r.peakMemoryBytes == GiB
    check r.makespanMillis == 39_995
