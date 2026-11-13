## The learned CPU estimate of one command stats key: what its finishes'
## totals and CPU profiles say about how much CPU it uses, when, and for how
## long.
##
## WHAT IS KEPT, AND FROM WHICH FINISHES.
##
## * Totals (CPU time per run) from every finish that carries them, whether
##   or not it brought a profile, so a command whose launcher never samples
##   still has a CPU estimate.
## * The expected uncontended duration at each granted width, and the
##   SHAPE, a curve of CPUs used at ``ShapePoints`` points of the elapsed
##   fraction of the run, only from UNCONTENDED finishes: a run that shared
##   a saturated host took longer and drew a flatter curve than the command
##   needs, and folding it in would teach admission the contention rather
##   than the command.
##
## Each figure is a conservative quantile (``ConservativeQuantile``,
## nearest rank) over the most recent ``ShapeHistory`` observations, so the
## estimate follows a command that changes and costs a bounded amount per
## key.
##
## CONTENDED OR NOT. The daemon judges a finish from the in-memory ambient
## samples over its run: the host's mean CPU busy share, less the share
## this execution itself used (its totals over its duration), is what
## everything else on the host drew. At or under the configured share the
## run is uncontended. This subtracts the execution's own use rather than
## relying on the samples' ``foreign_*`` columns, which subtract only what
## clients self-report while they run -- and no production client does, so
## ``foreign`` would include the execution being judged. With no sample in
## the window (sampling off, or a run shorter than one cadence) the run
## cannot be judged and is not folded into the duration or the shape.
##
## Pure: no clock, no I/O, no daemon state. The daemon supplies the busy
## share and the host's CPU count.

import std/[algorithm, tables]

import runquota_core/cpu_profile

const
  ShapePoints* = 20
  ShapeHistory* = 16
  ConservativeQuantile* = 0.9
  DefaultUncontendedOtherCpuPct* = 25.0
    ## The default ceiling on the share of the host's CPU that everything
    ## other than the execution may have used for its run to count as
    ## uncontended (`runquotad --profile-uncontended-pct`).

type
  ContentionVerdict* = enum
    cvUncontended = "uncontended"
    cvContended = "contended"
    cvUnknown = "unknown"

  CpuShape* = array[ShapePoints, uint32]
    ## Milli-CPUs at the midpoint of each twentieth of the run.

  CpuShapeEstimate* = object
    totalsSeen*: uint32
    profilesFolded*: uint32
    contendedSkipped*: uint32
    unjudgedSkipped*: uint32
    cpuMillis: seq[uint64]
      ## Ring of the last ``ShapeHistory`` CPU totals.
    shapes: seq[CpuShape]
      ## Ring of the last ``ShapeHistory`` uncontended shapes.
    durations: Table[uint32, seq[uint64]]
      ## Granted width (milli-CPUs) -> ring of uncontended durations.

proc pushRing[T](ring: var seq[T]; value: T) =
  if ring.len >= ShapeHistory:
    ring.delete(0)
  ring.add(value)

proc conservative(values: openArray[uint64]): uint64 =
  ## Nearest-rank ``ConservativeQuantile`` of ``values`` (non-empty).
  var sorted = @values
  sorted.sort()
  let rank = max(1, int(float64(sorted.len) * ConservativeQuantile + 0.999999))
  sorted[min(rank, sorted.len) - 1]

proc contention*(hostBusyPct: float64; samples: int; ownCpuMicros: uint64;
                 durationMillis: uint64; hostCpus: int;
                 uncontendedOtherPct: float64): ContentionVerdict =
  ## Whether a run was contended: see the module header. ``hostBusyPct``
  ## is the mean of ``samples`` ambient samples over the run.
  if samples <= 0 or durationMillis == 0'u64 or hostCpus <= 0:
    return cvUnknown
  let ownPct = 100.0 * (float64(ownCpuMicros) / 1000.0) /
    (float64(durationMillis) * float64(hostCpus))
  let otherPct = max(0.0, hostBusyPct - ownPct)
  if otherPct <= uncontendedOtherPct: cvUncontended else: cvContended

proc resample*(profile: CpuProfile; durationMillis: uint64): CpuShape =
  ## The profile as ``ShapePoints`` means over equal fractions of the run.
  ##
  ## Sample ``i`` covers ``[i, i+1) * interval``; the run's end is the
  ## launcher's duration, so the last sample stretches or is cut to meet
  ## it (a profile's last sample may be partial, see
  ## ``runquota_core/cpu_profile``). Each point is the time-weighted mean of
  ## the samples overlapping its twentieth.
  let n = profile.samples.len
  if n == 0 or profile.intervalMillis == 0'u32:
    return
  let interval = float64(profile.intervalMillis)
  var total = float64(durationMillis)
  if total <= 0.0:
    total = interval * float64(n)
  let bin = total / float64(ShapePoints)
  for k in 0 ..< ShapePoints:
    let lo = bin * float64(k)
    let hi = bin * float64(k + 1)
    var area = 0.0
    for i in 0 ..< n:
      let sLo = interval * float64(i)
      let sHi = if i == n - 1: max(total, interval * float64(n))
                else: interval * float64(i + 1)
      let overlap = min(hi, sHi) - max(lo, sLo)
      if overlap > 0.0:
        area += overlap * float64(profile.samples[i])
    result[k] = uint32(area / bin + 0.5)

proc fold*(estimate: var CpuShapeEstimate; totals: FinishTotals;
           profile: CpuProfile; grantedMilli: uint32;
           verdict: ContentionVerdict) =
  ## Fold one finish in. Totals always; duration and shape only when the
  ## run was uncontended.
  if not totals.known:
    return
  inc estimate.totalsSeen
  estimate.cpuMillis.pushRing(totals.totalCpuMicros div 1000'u64)
  case verdict
  of cvContended:
    inc estimate.contendedSkipped
    return
  of cvUnknown:
    inc estimate.unjudgedSkipped
    return
  of cvUncontended:
    discard
  var ring = estimate.durations.getOrDefault(grantedMilli)
  ring.pushRing(totals.durationMillis)
  estimate.durations[grantedMilli] = ring
  if profile.present:
    estimate.shapes.pushRing(resample(profile, totals.durationMillis))
    inc estimate.profilesFolded

proc hasShape*(estimate: CpuShapeEstimate): bool =
  estimate.shapes.len > 0

proc shape*(estimate: CpuShapeEstimate): CpuShape =
  ## Per point, the conservative quantile over the folded shapes. All
  ## zero when none has been folded (check ``hasShape``).
  for k in 0 ..< ShapePoints:
    var column: seq[uint64] = @[]
    for s in estimate.shapes:
      column.add(uint64(s[k]))
    if column.len > 0:
      result[k] = uint32(conservative(column))

proc conservativeCpuMillis*(estimate: CpuShapeEstimate): uint64 =
  ## Conservative CPU time per run, from totals. 0 when none were seen.
  if estimate.cpuMillis.len == 0: 0'u64 else: conservative(estimate.cpuMillis)

proc widths*(estimate: CpuShapeEstimate): seq[uint32] =
  for width in estimate.durations.keys:
    result.add(width)
  result.sort()

proc expectedDurationMillis*(estimate: CpuShapeEstimate;
                             grantedMilli: uint32): uint64 =
  ## Conservative uncontended duration at this granted width; 0 when no
  ## uncontended run at that width has been seen.
  let ring = estimate.durations.getOrDefault(grantedMilli)
  if ring.len == 0: 0'u64 else: conservative(ring)
