## Completion totals and CPU profiles: what the client that launched a
## process tree reports about it when the tree's root exits.
##
## TWO KINDS OF FIGURE, WITH DIFFERENT COSTS.
##
## * ``FinishTotals`` are the tree's CPU time, largest resident set and
##   duration as the launcher receives them when it reaps the root
##   (``wait4`` rusage on POSIX, Job Object accounting on Windows). They
##   cost nothing beyond the wait the launcher performs anyway, so every
##   finish carries them.
## * A ``CpuProfile`` is the same CPU time spread over the run: CPU used per
##   interval, in milli-CPUs. Taking one means reading the tree while it
##   runs, so it is an optional measurement behind the ``profiles`` switch
##   (``runquota_core/measurement``).
##
## WHAT THE TOTALS CANNOT SEE. ``wait4`` reports the root's own usage plus
## that of every descendant that was WAITED FOR, directly or through an
## intermediate parent that was itself waited for. A descendant that
## outlives its parent is re-parented to init (or to a subreaper) and its
## CPU time is reaped there, never here: a daemonising grandchild, or a
## backgrounded job whose shell exited without ``wait``, is missing from
## the totals. Peak memory has the same limit, and ``ru_maxrss`` is the
## largest single process, not the sum of a tree running at once; the
## launcher's own tree samples (``tree-sampling``) supply the sum while the
## tree runs.
##
## THE SAMPLER IS PURE. ``CpuProfileSampler`` is driven with explicit
## timestamps and cumulative CPU readings and reads no clock itself, so the
## coarsening rule (at most ``MaxCpuProfileSamples`` samples, the interval
## doubling as the run lengthens) is testable over a simulated two-hour run
## in microseconds. The launcher supplies the clock and the readings.

const
  MaxCpuProfileSamples* = 256
    ## The most samples a profile ever holds, whatever the run's duration.
  BaseCpuProfileIntervalMillis* = 1000'u32
    ## The interval a profile starts at, before any coarsening.

type
  FinishTotals* = object
    ## The tree's totals from the launcher's wait for its root.
    known*: bool
      ## False when the launcher could not obtain them (it never reaped
      ## the root, or the platform offers no accounting). The figures below
      ## are then zero and MUST be reported as not measured, never as zero.
    cpuUserMicros*: uint64
    cpuSysMicros*: uint64
    maxRssBytes*: uint64
      ## The largest resident set of any single process among the root and
      ## its waited-for descendants (``ru_maxrss``). 0 when not reported.
    majorPageFaults*: uint64
    durationMillis*: uint64
      ## From the launch to the reap of the root, on the launcher's clock.

  CpuProfile* = object
    ## CPU used per interval, in milli-CPUs (1000 = one CPU busy for the
    ## whole interval), saturating at 65535. ``intervalMillis == 0`` means
    ## no profile was taken.
    ##
    ## The last sample may cover less than a full interval (the run ended
    ## inside it); its value is the mean over the time it does cover.
    intervalMillis*: uint32
    samples*: seq[uint16]

  CpuProfileSampler* = object
    ## Folds cumulative CPU readings of a running tree into a bounded
    ## profile. See ``observe`` and ``finish``.
    started: bool
    intervalMillis: uint32
    startMillis: int64
    boundaryMillis: int64
      ## When the interval being accumulated began.
    boundaryCpuMicros: uint64
      ## The tree's cumulative CPU at ``boundaryMillis``.
    lastCpuMicros: uint64
      ## The highest cumulative reading seen. Readings are clamped to it,
      ## so a descendant leaving the tree (re-parented away, see the module
      ## header) can never make an interval negative.
    cpuMicros: seq[uint64]
      ## CPU used in each completed sample.
    spanMillis: seq[int64]
      ## The time each completed sample really covers. Kept beside the CPU
      ## so a merge sums both and the mean stays exact even though the
      ## readings arrive a little after each nominal boundary.
    peakRssBytes: seq[uint64]
      ## The largest tree resident set seen in each sample (memory profile
      ## for sizing; merged by maximum).
    pendingPeakRssBytes: uint64

proc noCpuProfile*(): CpuProfile =
  CpuProfile(intervalMillis: 0'u32, samples: @[])

proc present*(profile: CpuProfile): bool =
  profile.intervalMillis > 0'u32 and profile.samples.len > 0

proc totalCpuMicros*(totals: FinishTotals): uint64 =
  totals.cpuUserMicros + totals.cpuSysMicros

proc initCpuProfileSampler*(): CpuProfileSampler =
  CpuProfileSampler(started: false, intervalMillis: BaseCpuProfileIntervalMillis)

proc started*(sampler: CpuProfileSampler): bool = sampler.started

proc intervalMillis*(sampler: CpuProfileSampler): uint32 =
  sampler.intervalMillis

proc sampleCount*(sampler: CpuProfileSampler): int =
  sampler.cpuMicros.len

proc start*(sampler: var CpuProfileSampler; nowMillis: int64;
            cpuMicros = 0'u64) =
  ## Begin at ``nowMillis`` with the tree's cumulative CPU at that moment
  ## (0 for a tree launched just now).
  sampler = CpuProfileSampler(started: true,
    intervalMillis: BaseCpuProfileIntervalMillis, startMillis: nowMillis,
    boundaryMillis: nowMillis, boundaryCpuMicros: cpuMicros,
    lastCpuMicros: cpuMicros)

proc nextDueMillis*(sampler: CpuProfileSampler): int64 =
  ## When the launcher should next read the tree. One reading per interval:
  ## as the interval doubles, so does the gap between readings, which is
  ## what keeps the cost of a long run from growing with its length.
  sampler.boundaryMillis + int64(sampler.intervalMillis)

proc due*(sampler: CpuProfileSampler; nowMillis: int64): bool =
  sampler.started and nowMillis >= sampler.nextDueMillis()

proc coarsen(sampler: var CpuProfileSampler) =
  ## Merge adjacent pairs and double the interval. Called with an even
  ## count (exactly ``MaxCpuProfileSamples``).
  var cpu: seq[uint64] = @[]
  var span: seq[int64] = @[]
  var rss: seq[uint64] = @[]
  var i = 0
  while i < sampler.cpuMicros.len:
    if i + 1 < sampler.cpuMicros.len:
      cpu.add(sampler.cpuMicros[i] + sampler.cpuMicros[i + 1])
      span.add(sampler.spanMillis[i] + sampler.spanMillis[i + 1])
      rss.add(max(sampler.peakRssBytes[i], sampler.peakRssBytes[i + 1]))
    else:
      cpu.add(sampler.cpuMicros[i])
      span.add(sampler.spanMillis[i])
      rss.add(sampler.peakRssBytes[i])
    i += 2
  sampler.cpuMicros = cpu
  sampler.spanMillis = span
  sampler.peakRssBytes = rss
  sampler.intervalMillis = sampler.intervalMillis * 2'u32

proc clampedReading(sampler: var CpuProfileSampler; cpuMicros: uint64): uint64 =
  if cpuMicros > sampler.lastCpuMicros:
    sampler.lastCpuMicros = cpuMicros
  sampler.lastCpuMicros

proc closeSample(sampler: var CpuProfileSampler; nowMillis: int64;
                 cpuMicros: uint64) =
  sampler.cpuMicros.add(cpuMicros - sampler.boundaryCpuMicros)
  sampler.spanMillis.add(max(1'i64, nowMillis - sampler.boundaryMillis))
  sampler.peakRssBytes.add(sampler.pendingPeakRssBytes)
  sampler.pendingPeakRssBytes = 0
  sampler.boundaryMillis = nowMillis
  sampler.boundaryCpuMicros = cpuMicros

proc observe*(sampler: var CpuProfileSampler; nowMillis: int64;
              cpuMicros: uint64; residentBytes = 0'u64) =
  ## One reading of the tree: its cumulative CPU time (own plus reaped
  ## descendants, of every live process in it) and, optionally, its summed
  ## resident set. A reading taken before the current interval is due only
  ## raises the interval's memory peak; one taken at or after it closes the
  ## interval.
  ##
  ## A reading arriving late (the launcher was busy) closes ONE sample
  ## covering the whole gap rather than inventing several: the CPU between
  ## two readings cannot be apportioned to instants nobody looked at, and
  ## the sample's true span is kept, so its mean stays right.
  if not sampler.started:
    return
  if residentBytes > sampler.pendingPeakRssBytes:
    sampler.pendingPeakRssBytes = residentBytes
  let cpu = sampler.clampedReading(cpuMicros)
  if nowMillis < sampler.nextDueMillis():
    return
  sampler.closeSample(nowMillis, cpu)
  if sampler.cpuMicros.len >= MaxCpuProfileSamples:
    sampler.coarsen()

proc finish*(sampler: var CpuProfileSampler; nowMillis: int64;
             cpuMicros: uint64) =
  ## The root has exited and ``cpuMicros`` is the tree's final total (the
  ## launcher's ``wait4`` figure, which also covers CPU used since the last
  ## reading). Closes the last, partial sample.
  ##
  ## A tail shorter than half an interval is folded into the previous
  ## sample rather than standing alone: a 30 ms tail's mean is mostly
  ## noise, and the sums keep the folded sample's mean exact.
  if not sampler.started:
    return
  let cpu = sampler.clampedReading(cpuMicros)
  let tail = nowMillis - sampler.boundaryMillis
  if tail <= 0 and cpu == sampler.boundaryCpuMicros:
    return
  if sampler.cpuMicros.len > 0 and tail * 2 < int64(sampler.intervalMillis):
    sampler.cpuMicros[^1] += cpu - sampler.boundaryCpuMicros
    sampler.spanMillis[^1] += max(0'i64, tail)
    sampler.peakRssBytes[^1] = max(sampler.peakRssBytes[^1],
      sampler.pendingPeakRssBytes)
    sampler.boundaryMillis = nowMillis
    sampler.boundaryCpuMicros = cpu
    return
  if sampler.cpuMicros.len >= MaxCpuProfileSamples:
    sampler.coarsen()
  sampler.closeSample(nowMillis, cpu)

proc saturatingU16(value: uint64): uint16 =
  if value > 65535'u64: 65535'u16 else: uint16(value)

proc profile*(sampler: CpuProfileSampler): CpuProfile =
  ## The profile so far: per sample, CPU micros over the sample's real
  ## span in milliseconds, which is milli-CPUs.
  if sampler.cpuMicros.len == 0:
    return noCpuProfile()
  result = CpuProfile(intervalMillis: sampler.intervalMillis, samples: @[])
  for i in 0 ..< sampler.cpuMicros.len:
    let span = uint64(max(1'i64, sampler.spanMillis[i]))
    result.samples.add(saturatingU16(
      (sampler.cpuMicros[i] + span div 2'u64) div span))

proc memoryProfileMiB*(sampler: CpuProfileSampler): seq[uint16] =
  ## The largest summed resident set seen in each sample, in MiB
  ## (saturating), on the same intervals as ``profile``. Zero where no
  ## memory reading was supplied.
  for value in sampler.peakRssBytes:
    result.add(saturatingU16(value div (1024'u64 * 1024'u64)))

proc profileCpuMicros*(profile: CpuProfile): uint64 =
  ## The CPU time a profile accounts for, taking every sample as a full
  ## interval. An approximation (the last sample may be partial), used to
  ## compare a profile with the totals beside it.
  for value in profile.samples:
    result += uint64(value) * uint64(profile.intervalMillis)
