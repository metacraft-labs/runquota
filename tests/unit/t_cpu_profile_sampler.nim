## CPU profiles: the launcher-side sampler, the `LeaseFinished` totals block
## that carries a profile, and the daemon's fold of profiles into a
## command's learned CPU shape.
##
## WHAT IS GUARDED, AND HOW IT WOULD FAIL.
##
## * A profile is bounded at 256 samples whatever the run's length: when a
##   run outgrows them, adjacent samples merge and the interval doubles, and
##   the launcher reads the tree once per (current) interval. The two-hour
##   case drives the sampler with SIMULATED TIME: the sampler takes its
##   clock as an argument (it reads none itself), so 7200 s of polling at
##   the launcher's 10 ms cadence runs in milliseconds, and a real two-hour
##   process would test nothing more -- the bound is arithmetic over the
##   timestamps it is given. Falsifying mutation: drop the `coarsen` call
##   in `observe` and the run stores 7200 samples at a 1 s interval and
##   fails; make `nextDueMillis` ignore the interval and the reading count
##   grows to 7200 and fails.
## * Merging keeps a steady load's rate exact, a descendant leaving the
##   tree never produces a negative interval, and the tail of a run lands
##   in the profile.
## * The totals block decodes from a current client, an older client's
##   finish (no block) still decodes with the totals NOT known (so the
##   store writes NULL, not zero), and an oversized profile is refused.
## * The fold keeps totals from every finish, and duration and shape only
##   from uncontended ones; a run's own CPU is not counted as contention.
##
## NO MOCKS: the real sampler, codec and fold, which are pure.

import std/[unittest]

import runquota_core
import runquota_core/cpu_profile
import runquota_protocol
import runquota_daemon/cpu_shape

proc driveSteady(sampler: var CpuProfileSampler; milliCpu: uint64;
                 untilMillis: int64; pollMillis = 10'i64): int =
  ## Polls like the launcher does (every `pollMillis`), reading the tree
  ## only when the sampler says a reading is due, under a constant load of
  ## `milliCpu`. Returns how many readings were taken.
  var now = 0'i64
  while now < untilMillis:
    now += pollMillis
    if sampler.due(now):
      sampler.observe(now, uint64(now) * milliCpu)
      inc result

suite "CPU profile sampler":
  test "a two-hour run holds at most 256 samples, the interval doubled accordingly":
    var sampler = initCpuProfileSampler()
    sampler.start(0)
    const twoHours = 2'i64 * 3600'i64 * 1000'i64
    let readings = sampler.driveSteady(3000, twoHours)
    sampler.finish(twoHours, uint64(twoHours) * 3000'u64)
    let profile = sampler.profile()
    check profile.samples.len <= MaxCpuProfileSamples
    # 256 s at 1 s, then doubling at 512, 1024, 2048 and 4096 s: 32 s.
    check profile.intervalMillis == 32_000'u32
    # The profile still spans the run: 128 samples to 4096 s, then one per
    # 32 s to 7200 s.
    check profile.samples.len == 128 + (7200 - 4096) div 32
    # The launcher's readings thin out with the interval: far fewer than
    # one a second (7200), bounded by 256 + 128 per doubling.
    check readings < 256 + 128 * 5 + 1
    for value in profile.samples:
      check value == 3000'u16

  test "a steady load reads back as its rate across a merge":
    var sampler = initCpuProfileSampler()
    sampler.start(0)
    discard sampler.driveSteady(2500, 300_000)
    sampler.finish(300_000, 300_000'u64 * 2500'u64)
    let profile = sampler.profile()
    check profile.intervalMillis == 2000'u32
    for value in profile.samples:
      check value == 2500'u16

  test "a descendant leaving the tree never makes an interval negative":
    var sampler = initCpuProfileSampler()
    sampler.start(0)
    sampler.observe(1000, 4_000_000)
    # The reading falls (a process re-parented away took its time with
    # it); the interval reads as idle, not as a wrapped huge value.
    sampler.observe(2000, 1_000_000)
    sampler.observe(3000, 5_000_000)
    let profile = sampler.profile()
    check profile.samples == @[4000'u16, 0'u16, 1000'u16]

  test "the run's tail and the final total land in the profile":
    var sampler = initCpuProfileSampler()
    sampler.start(0)
    sampler.observe(1000, 1_000_000)
    sampler.observe(2000, 2_000_000)
    # 1.8 s in, the root is reaped with a total of 2.8 CPU-s: a tail of
    # 0.8 s at 1 CPU is its own sample.
    sampler.finish(2800, 2_800_000)
    check sampler.profile().samples == @[1000'u16, 1000'u16, 1000'u16]
    # A tail under half an interval folds into the previous sample.
    var short = initCpuProfileSampler()
    short.start(0)
    short.observe(1000, 1_000_000)
    short.finish(1200, 1_600_000)
    check short.profile().samples == @[1333'u16]

  test "a run shorter than one interval is one sample, from the totals":
    var sampler = initCpuProfileSampler()
    sampler.start(0)
    sampler.finish(400, 800_000)
    let profile = sampler.profile()
    check profile.intervalMillis == 1000'u32
    check profile.samples == @[2000'u16]

  test "the memory profile keeps the peak per interval and merges by maximum":
    var sampler = initCpuProfileSampler()
    sampler.start(0)
    sampler.observe(500, 0, 300'u64 shl 20)
    sampler.observe(1000, 0, 100'u64 shl 20)
    sampler.observe(2000, 0, 200'u64 shl 20)
    check sampler.memoryProfileMiB() == @[300'u16, 200'u16]

suite "finish totals on the wire":
  proc sampleFinish(): LeaseFinishedMessage =
    LeaseFinishedMessage(sessionId: sessionId(3), leaseId: leaseId(9),
      finish: succeeded(), peakMemoryBytes: 1024, processCount: 4,
      diagnostic: okDiagnostic(),
      totals: FinishTotals(known: true, cpuUserMicros: 3_100_000,
        cpuSysMicros: 200_000, maxRssBytes: 8 shl 20, majorPageFaults: 2,
        durationMillis: 1500),
      cpuProfile: CpuProfile(intervalMillis: 1000, samples: @[2000'u16, 1300]))

  test "totals and a profile round-trip":
    var decoded: LeaseFinishedMessage
    check decodeLeaseFinished(encodeLeaseFinished(sampleFinish()), decoded) ==
      lfdOk
    check decoded.totals == sampleFinish().totals
    check decoded.cpuProfile == sampleFinish().cpuProfile

  test "an older client's finish decodes with the totals not known":
    var old = sampleFinish()
    old.totals = FinishTotals(known: false)
    old.cpuProfile = noCpuProfile()
    let payload = encodeLeaseFinished(old)
    var decoded: LeaseFinishedMessage
    check decodeLeaseFinished(payload, decoded) == lfdOk
    check not decoded.totals.known
    check not decoded.cpuProfile.present
    # And that payload is exactly the pre-block layout: no trailing bytes.
    var withTotals = old
    withTotals.totals = sampleFinish().totals
    check encodeLeaseFinished(withTotals).len == payload.len + 4 + 5 * 8

  test "a profile over the bound, a zero interval and unknown bits are refused":
    var big = sampleFinish()
    var payload = encodeLeaseFinished(big)
    # Rewrite the sample count (the u16 before the two samples) to 257.
    payload[payload.len - 6] = char(1)
    payload[payload.len - 5] = char(1)
    var decoded: LeaseFinishedMessage
    check decodeLeaseFinished(payload, decoded) == lfdMalformedPayload
    var zero = sampleFinish()
    zero.cpuProfile.intervalMillis = 0
    zero.totals = FinishTotals(known: false)
    # A zero interval means "no profile", so nothing is written at all.
    check encodeLeaseFinished(zero).len ==
      encodeLeaseFinished(LeaseFinishedMessage(sessionId: sessionId(3),
        leaseId: leaseId(9), finish: succeeded(), peakMemoryBytes: 1024,
        processCount: 4, diagnostic: okDiagnostic())).len
    var bits = encodeLeaseFinished(sampleFinish())
    let blockStart = encodeLeaseFinished(zero).len
    bits[blockStart] = char(7)
    check decodeLeaseFinished(bits, decoded) == lfdMalformedPayload

suite "learned CPU shape":
  proc steppedProfile(): CpuProfile =
    ## 8 CPUs for 10 s, then 2 CPUs for 20 s.
    result = CpuProfile(intervalMillis: 1000, samples: @[])
    for i in 0 ..< 10: result.samples.add(8000'u16)
    for i in 0 ..< 20: result.samples.add(2000'u16)

  proc steppedTotals(): FinishTotals =
    FinishTotals(known: true, cpuUserMicros: 120_000_000,
      durationMillis: 30_000)

  test "a profile resamples onto twenty points of the run":
    let shape = resample(steppedProfile(), 30_000)
    # Each point covers 1.5 s: points 0-5 lie in the first phase, point 6
    # straddles 9-10.5 s (1 s at 8, 0.5 s at 2), the rest in the second.
    for k in 0 .. 5: check shape[k] == 8000'u32
    check shape[6] == 6000'u32
    for k in 7 ..< ShapePoints: check shape[k] == 2000'u32

  test "the run's own CPU is not contention":
    # A 30 s run averaging 4 CPUs on a 32-CPU host is 12.5% of it. The
    # host was 30% busy: everything else drew 17.5%.
    check contention(30.0, 10, 120_000_000, 30_000, 32, 25.0) == cvUncontended
    check contention(45.0, 10, 120_000_000, 30_000, 32, 25.0) == cvContended
    check contention(30.0, 0, 120_000_000, 30_000, 32, 25.0) == cvUnknown

  test "totals from every finish; duration and shape only when uncontended":
    var estimate: CpuShapeEstimate
    estimate.fold(steppedTotals(), steppedProfile(), 8000, cvContended)
    estimate.fold(steppedTotals(), noCpuProfile(), 8000, cvUncontended)
    estimate.fold(steppedTotals(), steppedProfile(), 8000, cvUnknown)
    check estimate.totalsSeen == 3
    check estimate.conservativeCpuMillis() == 120_000'u64
    check estimate.contendedSkipped == 1
    check estimate.unjudgedSkipped == 1
    # The uncontended totals-only finish gives a duration but no shape.
    check estimate.expectedDurationMillis(8000) == 30_000'u64
    check not estimate.hasShape
    estimate.fold(steppedTotals(), steppedProfile(), 8000, cvUncontended)
    check estimate.hasShape
    check estimate.profilesFolded == 1
    check estimate.shape()[0] == 8000'u32
    check estimate.shape()[19] == 2000'u32

  test "the shape and the duration are conservative quantiles":
    var estimate: CpuShapeEstimate
    for i in 0 ..< 9:
      var totals = steppedTotals()
      totals.durationMillis = 30_000
      estimate.fold(totals, steppedProfile(), 8000, cvUncontended)
    var slow = steppedTotals()
    slow.durationMillis = 40_000
    var wide = steppedProfile()
    for i in 0 ..< wide.samples.len: wide.samples[i] = 9000
    estimate.fold(slow, wide, 8000, cvUncontended)
    # Ten values, nearest-rank p90 is the 9th smallest: the common one.
    check estimate.expectedDurationMillis(8000) == 30_000'u64
    check estimate.shape()[0] == 8000'u32
    estimate.fold(slow, wide, 8000, cvUncontended)
    # Eleven values, p90 is the 10th smallest: now the slow/wide one.
    check estimate.expectedDurationMillis(8000) == 40_000'u64
    check estimate.shape()[19] == 9000'u32
    check estimate.expectedDurationMillis(2000) == 0'u64
