## Predicted CPU demand of running leases, and the CPU predicted free.
##
## Predictive admission ("admission into the tail") admits a queued
## request's minimum width into CPU the running leases are PREDICTED to
## leave free over the admission horizon, although their granted widths
## still fill the ledger: a test run that saturated the host for a minute
## and then runs on one core still holds its whole grant until it ends.
## The prior art it builds on is Borg's and Mesos' resource reclamation,
## which admit best-effort work into the gap between what is reserved and
## what is used.
##
## WHAT A LEASE IS PREDICTED TO USE over ``[now, now + horizon]``:
##
## * with a learned shape (``cpu_shape``: CPUs used at twenty points of the
##   elapsed fraction of the run) and an expected uncontended duration at
##   its granted width, the LARGEST shape point overlapping that window, the
##   window taken as fractions of the expected duration elapsed since the
##   grant and cut at the expected end. The largest, because the grant made
##   now must fit for the whole horizon, not on average;
## * otherwise, and once it has run past its expected duration, its charge:
##   the CPU the ledger holds for it. A prediction that cannot be read is
##   the declared width, so with no shapes anywhere this is declared-width
##   admission exactly.
##
## BACKGROUND DEMAND is what the host's busy CPU shows beyond the daemon's
## own leases (their demand predicted NOW), less the CPU the budget leaves
## outside RunQuota: work outside RunQuota is taken to run first on the
## processors the budget does not lease.
##
## A test may hold the host's busy share in a file instead
## (``runquotad --host-cpu-busy-file``, ``parseHostBusyPct``).
##
## Pure: no clock, no daemon state, no I/O.

import std/strutils

import ./cpu_shape

type
  LeaseForecast* = object
    ## What the prediction needs to know about one running lease.
    chargeMilli*: uint32
      ## The CPU the ledger holds for it.
    shapeKnown*: bool
    shape*: CpuShape
    expectedDurationMillis*: uint64
      ## At its granted width; 0 when unknown.
    elapsedMillis*: int64
      ## Since its grant.

proc readable(lease: LeaseForecast): bool =
  lease.shapeKnown and lease.expectedDurationMillis > 0'u64 and
    lease.elapsedMillis >= 0'i64 and
    uint64(lease.elapsedMillis) < lease.expectedDurationMillis

proc pointIndex(fraction: float64): int =
  ## The shape point covering ``fraction`` of the run (point ``k`` covers
  ## ``[k, k+1) / ShapePoints``), clamped to the last point.
  min(ShapePoints - 1, max(0, int(fraction * float64(ShapePoints))))

proc predictedDemandMilli*(lease: LeaseForecast; horizonMillis: int64): uint32 =
  ## The lease's predicted demand over ``[now, now + horizonMillis]``; see
  ## the module header. ``horizonMillis = 0`` is its demand now.
  if not lease.readable:
    return lease.chargeMilli
  let expected = float64(lease.expectedDurationMillis)
  let fromFraction = float64(lease.elapsedMillis) / expected
  let toFraction = min(1.0,
    float64(lease.elapsedMillis + max(0'i64, horizonMillis)) / expected)
  let first = pointIndex(fromFraction)
  # The window's end is exclusive on a point boundary: a window ending
  # exactly where point k begins does not reach it.
  var last = first
  if toFraction > fromFraction:
    let scaled = toFraction * float64(ShapePoints)
    var k = int(scaled)
    if float64(k) == scaled:
      dec k
    last = min(ShapePoints - 1, max(first, k))
  for k in first .. last:
    result = max(result, lease.shape[k])

proc backgroundDemandMilli*(hostBusyMilli, ownNowMilli,
                            outsideBudgetMilli: uint64): uint64 =
  ## Busy CPU on the host that is not the daemon's own leases and does not
  ## fit on the processors the budget leaves outside RunQuota; never below 0.
  let foreign =
    if hostBusyMilli > ownNowMilli: hostBusyMilli - ownNowMilli else: 0'u64
  if foreign > outsideBudgetMilli: foreign - outsideBudgetMilli else: 0'u64

proc predictedFreeMilli*(budgetMilli, demandMilli,
                         backgroundMilli: uint64): uint64 =
  ## ``budget - demand - background``, saturating at 0.
  let used = demandMilli + backgroundMilli
  if budgetMilli > used: budgetMilli - used else: 0'u64

proc parseHostBusyPct*(text: string; pct: var float64): bool =
  ## The host's busy CPU share from a ``--host-cpu-busy-file``: one decimal
  ## percentage from 0 to 100, surrounding whitespace allowed. False, with
  ## ``pct`` untouched, for anything else (empty, not a number, NaN, out
  ## of range), which leaves background demand unknown.
  let raw = text.strip()
  if raw.len == 0:
    return false
  var value: float64
  try:
    value = parseFloat(raw)
  except ValueError:
    return false
  if value != value or value < 0.0 or value > 100.0:
    return false
  pct = value
  true

proc fitsPredictedFree*(minimumMilli: uint32; freeMilli: uint64): bool =
  ## Whether a reclaimed grant of ``minimumMilli`` fits the CPU predicted
  ## free: exactly, with no tolerance either way. A minimum equal to the
  ## free CPU fits; one milli-CPU more does not.
  uint64(minimumMilli) <= freeMilli
