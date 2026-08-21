## An ambient row's host reading and its self figures must describe the SAME
## instant.
##
## ``foreign_* = host total - sum(self_*)`` is a subtraction of two
## measurements. It means nothing unless both were taken together. The sampler
## used to stamp ``sampled_at_unix_millis`` inside ``readHostLoad`` and then
## read the live self-report set later, under a lock it had to queue for; a
## ``reportSelfExecution`` arriving in between produced a row whose timestamp
## said one instant and whose ``self_*`` said another. When the later figures
## exceeded the earlier host total -- a burst of lease starts does this -- the
## clamp fired and ``foreign_*`` was written as zero. That row describes no
## moment that ever existed, and it is written into columns a reader averages.
##
## THE INVARIANT UNDER TEST, stated without reference to the implementation: a
## row's ``self_cpu_pct`` is the value that was live at the row's own
## ``sampled_at_unix_millis``.
##
## How it is driven: one thread advances a single probe execution's reported
## CPU through a STRICTLY INCREASING sequence, recording the instant before and
## the instant after each change. Monotonicity is what makes the check exact
## without needing to resolve ties. For a row stamped at ``at``:
##
## * ``definite`` -- the newest value whose write COMPLETED in an earlier
##   millisecond -- was certainly live at ``at``;
## * ``possible`` -- the newest value whose write had even BEGUN by the end of
##   millisecond ``at`` -- is the newest that could conceivably be live.
##
## A correct sampler reads the set at the instant it stamps, so every row must
## satisfy ``definite <= self_cpu_pct <= possible``. The skew is
## ONE-DIRECTIONAL -- the old code read the set at or after the stamp, never
## before -- so it shows up as a value ABOVE ``possible``: a figure whose write
## had not started when the row claims to have been taken. Both comparisons are
## chosen for the millisecond truncation that is all the resolution
## ``sampled_at_unix_millis`` has, and every row is checked; nothing is skipped
## as ambiguous, because the bound does not need a tie broken.
##
## The skew opens when the sampler is descheduled between reading the kernel
## counters and reading the report set, so the machine is deliberately put
## under load: without contention the window is too narrow to enter often.
##
## HOW RELIABLY IT SEPARATES THE TWO IMPLEMENTATIONS, measured rather than
## asserted: against the non-atomic sampler it failed on 8 runs out of 8, with
## one to four violations each; against the atomic one it passed 8 runs out of
## 8. It is a probabilistic detector, not a deterministic one -- it catches a
## scheduler interleaving, and no test that does so can promise a single run
## will see it. What it does guarantee is the other direction: a violation is
## never a false alarm, because it reports a value whose write had not begun
## when the row says it was taken, which no interleaving of a correct sampler
## can produce. `checked` and `straddling` are echoed on every run so a drop in
## yield is visible rather than silent.
##
## No mocks. The real sampler thread, the real host readings, the real store.

import std/[atomics, cpuinfo, math, os, strutils, tempfiles, unittest]

import runquota_observation_store
import runquota_observation_store/ids

const
  ProbeId = "atomicity-probe"
  ProbeRss = 4096'i64

  ## Slow enough that macOS actually advances its mach counters between
  ## ticks -- a faster cadence is mostly rejected as a stale pair and yields
  ## too few rows to conclude anything from.
  CadenceMillis = 100

  ## The probe moves far faster than the sampler ticks, so that a sampler
  ## delayed even slightly between its two reads picks up a value that did
  ## not exist at the instant it stamped.
  StepMillis = 2

  RunMillis = 10000
  MaxSpinners = 64

  ## CONTENTION, and why it is needed rather than gratuitous.
  ##
  ## The skew is only observable while the sampler sits between its two
  ## reads, and on an idle lock that is a handful of microseconds -- far too
  ## narrow for a probe stepping every few milliseconds to slip into, as a
  ## first version of this test demonstrated by finding nothing. The
  ## non-atomic sampler RELEASES `samplerLock` after its live-lease gate and
  ## re-acquires it to build the row, so a thread already queued on that
  ## lock is admitted in between. `liveSelfReports` copies the whole live
  ## set under the lock, so a large set makes each hold long enough to
  ## matter, and several threads doing it keep the lock continuously busy.
  ##
  ## None of this changes what is asserted. It changes only how often the
  ## sampler is caught in a window it should not have.
  FillerCount = 20_000
  ChurnThreads = 8
  MaxChurn = 16

  ## Floor on rows examined. Every row is checkable now, so this is simply
  ## a guard against a run that collected almost nothing passing vacuously.
  MinCheckedRows = 15

  ## The probe's motion has to actually reach the rows. If every row carried
  ## the same figure, equality would hold for a sampler that never read the
  ## report set at all.
  MinDistinctSelfValues = 5

type
  StepRecord = object
    beforeMillis: int64
    afterMillis: int64
    value: float64

  Stepper = object
    stop: Atomic[bool]
    steps: seq[StepRecord]

  Spinner = object
    stop: Atomic[bool]
    sink: float64

  Churn = object
    stop: Atomic[bool]
    rounds: int

var
  stepper: Stepper
  stepperThread: Thread[ptr Stepper]
  spinners: array[MaxSpinners, Spinner]
  spinnerThreads: array[MaxSpinners, Thread[ptr Spinner]]
  churners: array[MaxChurn, Churn]
  churnThreads: array[MaxChurn, Thread[ptr Churn]]

proc stepProbe(state: ptr Stepper) {.thread.} =
  # `reportSelfExecution` guards its own module state with `samplerLock`;
  # `ambient` casts for the same reason on the sampler side.
  {.cast(gcsafe).}:
    var index = 0
    while not state.stop.load():
      inc index
      let value = float64(index) * 0.01
      let before = unixMillisNow()
      reportSelfExecution(ProbeId, value, ProbeRss)
      let after = unixMillisNow()
      state.steps.add(StepRecord(
        beforeMillis: before, afterMillis: after, value: value))
      sleep(StepMillis)

proc churnLock(state: ptr Churn) {.thread.} =
  ## Keep `samplerLock` continuously busy. `liveSelfReports` is an ordinary
  ## public read; it is used here for its lock hold, not its result.
  {.cast(gcsafe).}:
    while not state.stop.load():
      discard liveSelfReports()
      inc state.rounds

proc burnCpu(state: ptr Spinner) {.thread.} =
  var total = 0.0
  var i = 1
  while not state.stop.load():
    total += sqrt(float64(i))
    inc i
    if i > 1_000_000:
      i = 1
  state.sink = total

suite "ambient sample atomicity":
  test "a row's self figures are the ones live at its own timestamp":
    let dir = createTempDir("runquota_ambient_atomicity_", "")
    defer: removeDir(dir)
    let path = dir / "observations.sqlite"
    let store = openObservationStore(path)
    check store.captureEnabled
    let hostId = resolveHostIdentity(dir / "host-id").hostId
    check store.ensureHostRow(hostId, "boot-0")

    # ORDER MATTERS: `startAmbientSampler` resets the live-lease count and
    # empties the report set, so both have to be established after it, not
    # before, or the sampler spends the whole run gated off and writes
    # nothing.
    startAmbientSampler(path, hostId, cadenceMillis = CadenceMillis,
                        flushSamples = 2)
    # Opens the live-lease gate; without it the sampler writes no rows.
    setAmbientLiveLeaseCount(1)
    # The value in effect before the first recorded step, so every row has a
    # defined answer even if it lands before the stepper's first write. An
    # empty report set sums to the same 0.0, so the two agree either way.
    reportSelfExecution(ProbeId, 0.0, ProbeRss)

    # Filler entries hold 0.0, so the sum over the live set stays exactly
    # the probe's value and the assertion below is unchanged by their
    # presence. They exist to give `liveSelfReports` something bulky to copy
    # while holding the lock.
    for i in 0 ..< FillerCount:
      reportSelfExecution("filler-" & $i, 0.0, 0)

    for i in 0 ..< ChurnThreads:
      createThread(churnThreads[i], churnLock, addr churners[i])

    # OVERSUBSCRIBED ON PURPOSE, at several runnable threads per core. The
    # gap to be caught is the sampler sitting between its two reads, and the
    # cheapest way to stretch it is to make the scheduler take the sampler
    # off a core there. Spinners are used rather than more lock churn
    # because they do not touch `samplerLock`: they stretch the SAMPLER's
    # gap without also stretching the stepper's write bracket, which is what
    # `possible` is derived from and therefore what loosens the bound.
    let spinnerCount = max(4, min(MaxSpinners, countProcessors() * 4))
    for i in 0 ..< spinnerCount:
      createThread(spinnerThreads[i], burnCpu, addr spinners[i])
    createThread(stepperThread, stepProbe, addr stepper)

    sleep(RunMillis)
    stopAmbientSampler()

    stepper.stop.store(true)
    joinThread(stepperThread)
    for i in 0 ..< ChurnThreads:
      churners[i].stop.store(true)
      joinThread(churnThreads[i])
    for i in 0 ..< spinnerCount:
      spinners[i].stop.store(true)
      joinThread(spinnerThreads[i])

    setAmbientLiveLeaseCount(0)
    clearSelfReportedExecutions()

    let rows = store.readAmbientSamples()
    let steps = stepper.steps

    # The driver has to have actually driven something.
    check steps.len > 100
    check steps[^1].value > steps[0].value

    var checkedRows = 0
    var straddling = 0
    var violations: seq[string] = @[]
    var distinctSelf: seq[float64] = @[]

    for row in rows:
      if row.selfCpuPct notin distinctSelf:
        distinctSelf.add(row.selfCpuPct)

      let at = row.sampledAtUnixMillis
      # Steps are recorded in increasing time order, so the final assignment
      # wins. A write whose `after` falls in the SAME millisecond as the
      # stamp may still have landed after it, so only a strictly earlier
      # millisecond proves a value was already live; a write whose `before`
      # falls in that same millisecond may have landed before it, so it
      # stays possible. Getting these the wrong way round makes the test
      # accuse a correct sampler of being one step behind.
      var definite = 0.0
      var possible = 0.0
      for step in steps:
        if step.afterMillis < at:
          definite = step.value
        if step.beforeMillis <= at:
          possible = step.value
      inc checkedRows
      if definite != possible:
        inc straddling
      if row.selfCpuPct > possible:
        violations.add(
          "row stamped " & $at & " carries self_cpu_pct=" & $row.selfCpuPct &
          ", newer than " & $possible &
          " -- the newest value whose write had even begun by then")
      elif row.selfCpuPct < definite:
        violations.add(
          "row stamped " & $at & " carries self_cpu_pct=" & $row.selfCpuPct &
          ", older than " & $definite &
          " -- which was already live at that instant")

    # Echoed on every run, not only on failure: the yield is what says
    # whether a green result means anything, and it is the first thing to
    # look at when this test starts passing for the wrong reason.
    echo "  m11 atomicity: rows=", rows.len, " checked=", checkedRows,
      " straddling=", straddling, " steps=", steps.len,
      " distinctSelf=", distinctSelf.len, " violations=", violations.len,
      " churnRounds=", churners[0].rounds

    check checkedRows >= MinCheckedRows
    check distinctSelf.len >= MinDistinctSelfValues

    for violation in violations[0 ..< min(5, violations.len)]:
      checkpoint(violation)
    check violations.len == 0
