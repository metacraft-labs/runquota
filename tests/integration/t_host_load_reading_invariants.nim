## ``readHostLoad`` itself: the function that reads the real kernel
## counters, asserted against INVARIANTS rather than against measurements.
##
## WHY THIS FILE EXISTS. Every other test of the ambient path either
## scripts ``HostLoadReading`` values -- ``t_observation_store_ambient_
## attribution`` -- or consumes the reader through the sampler and asserts
## a band on a derived RATIO -- ``t_ambient_load_attribution``. Neither
## constrains the reader. The scripted file never calls it at all, and the
## banded one divides two of its fields by each other, which is exactly the
## shape a scaling error survives:
##
##     result.cpuBusyMillis  = busy * 500'i64 div ticks        # 2x LOW
##     result.cpuTotalMillis = (busy + idle) * 1000'i64 div ticks
##
## That defect was built and run. The scripted file stayed green because it
## never reaches the reader; the banded file stayed green at a pooled ratio
## of 0.547 inside ``[0.40, 1.80]``. A reader under-reporting the machine
## by half shipped green. The two fields are computed SEPARATELY, so the
## often-repeated "it is a ratio of two counters from the same call, an
## error cancels" is false, and the hole it described as closed was open.
##
## WHY INVARIANTS AND NOT A TIGHTER BAND. Restoring a tight band on the
## derived ratio re-imports the flakiness that motivated moving the
## tracking claim to scripted readings in the first place: a TRUE paired
## ratio of 0.651 was measured on a busy run of UNMUTATED code, 8% above
## the 0.60 floor that band used to carry. Every assertion in this file is
## instead a statement that holds by construction -- an identity about
## time, or an inequality that a busier machine makes STRICTLY EASIER to
## satisfy. An invariant needs no tolerance, so it brings no tolerance's
## flakiness with it.
##
## THE ONE PLACE THIS FILE DELIBERATELY SATURATES THE MACHINE, and why
## that is acceptable HERE and nowhere else in it. The under-reporting
## direction is caught by comparing the host's busy delta against work
## THIS PROCESS is known to have done, and by requiring that a machine
## this process has filled reads as busy. Both are a-fortiori: more
## occupancy, from us or from anyone else, makes each inequality strictly
## harder to violate. A previous attempt at the first one failed only
## because it was tried at about 32% occupancy, where a 2x under-report
## still cleared our own usage. There is deliberately NO headroom
## precondition anywhere below -- ``waitForHeadroom`` and
## ``maxBusyForMeasurement`` belong to the file that measures a load by
## its effect on a host-wide total, and a gate that refuses to run on a
## busy host is the opposite of what these assertions need.
##
## No mocks. ``sysctl`` and ``vm_stat`` are used as INDEPENDENT ORACLES --
## separate implementations reading the same kernel interfaces -- not as
## stand-ins for anything. Nothing here substitutes for a real reading.
##
## WHAT IS STILL NOT COVERED, stated rather than implied.
##
## * THE LINUX BRANCH. ``readHostLoad`` has a second implementation, read
##   out of ``/proc``, and it HAS NEVER EXECUTED ANYWHERE -- not before
##   this file and not because of it. Every figure quoted below is
##   macOS/arm64. The three CPU assertions are written in terms the Linux
##   branch would satisfy unchanged if it ever ran, and the two memory
##   oracles are macOS tools compiled only on macOS, so on Linux this file
##   would drop to the CPU assertions and the burst. Until it is run
##   there, ``USER_HZ``, the iowait-is-idle decision, the aggregate-``cpu``
##   line parse, ``MemAvailable``, ``pswpin`` and the ``/proc/diskstats``
##   in-flight sum are all unexercised.
## * THE 32-BIT WRAP. macOS reports the tick counters as ``natural_t``,
##   which wraps a few times a month per state on a busy machine. The
##   reader widens to ``int64`` WITHOUT unwrapping, by design: the
##   discontinuity is caught downstream by ``classifyReadings``, which is
##   asserted over scripted values in
##   ``t_observation_store_ambient_attribution``. Nothing here reaches the
##   wrap, and nothing can without a month of uptime or a fake kernel.
## * ``loadAvg1m``, ``swapInPages`` and ``ioQueueDepth`` are checked for
##   shape (non-negative, cumulative, the documented sentinel) and NOT for
##   value. There is no independent oracle for them in this file.
## * HOW ``memAvailableBytes`` RESPONDS to an allocation. Its absolute
##   value is pinned against ``vm_stat`` below; its response to memory
##   being taken is asserted only by the 0.25x liveness floor in
##   ``t_ambient_load_attribution``, which a reader tracking memory at
##   half scale would clear.
## * A FAILING KERNEL CALL. The two ``host_statistics`` error paths, and
##   the "kernel reported a zero capacity" branch, are unreachable from a
##   test that is not allowed to mock the kernel.

import std/[algorithm, atomics, cpuinfo, os, osproc, posix, strutils, times,
            unittest]

import runquota_observation_store

# ---------------------------------------------------------------------------
# A load this process can be held responsible for
# ---------------------------------------------------------------------------
#
# TWO INDEPENDENT KILL SWITCHES, for the reason `t_ambient_load_
# attribution` records next to the same pattern: a plain `var bool` read
# in a tight loop is hoisted out of it by the optimiser, and a leaked
# spinner contaminates every measurement taken after it in this suite and
# in any other. The stop flag is atomic and the deadline fires regardless.

const
  spinnerLifetimeSeconds = 120.0
  maxSpinners = 96

var
  spinnerStop: Atomic[bool]
  spinnerDeadline: Atomic[float]
  spinnerSink: array[maxSpinners, uint64]

proc spinner(slot: int) {.thread.} =
  var x = 0'u64
  while not spinnerStop.load(moRelaxed) and
      epochTime() < spinnerDeadline.load(moRelaxed):
    for i in 0 ..< 20_000:
      x = (x * 6364136223846793005'u64 + 1442695040888963407'u64) xor uint64(i)
    spinnerSink[slot] = x

type LoadGenerator = object
  threads: seq[ptr Thread[int]]
  running: bool

proc startLoad(count: int): LoadGenerator =
  spinnerStop.store(false, moRelaxed)
  spinnerDeadline.store(epochTime() + spinnerLifetimeSeconds, moRelaxed)
  for i in 0 ..< count:
    let handle = createShared(Thread[int])
    createThread(handle[], spinner, i)
    result.threads.add(handle)
  result.running = true

proc stopLoad(load: var LoadGenerator) =
  ## Idempotent, and always joins.
  if not load.running:
    return
  spinnerStop.store(true, moRelaxed)
  spinnerDeadline.store(0.0, moRelaxed)
  for handle in load.threads:
    joinThread(handle[])
    deallocShared(handle)
  load.threads = @[]
  load.running = false

proc selfCpuMillis(): float =
  ## This process's own CPU time, every thread of it, in the SAME unit as
  ## ``cpuBusyMillis``: milliseconds of CPU summed over cores, not wall
  ## milliseconds.
  var usage: Rusage
  if getrusage(RUSAGE_SELF, addr usage) != 0:
    return 0.0
  1000.0 * (
    float(usage.ru_utime.tv_sec) + float(usage.ru_utime.tv_usec) / 1e6 +
    float(usage.ru_stime.tv_sec) + float(usage.ru_stime.tv_usec) / 1e6)

proc f(value: float; digits = 4): string = value.formatFloat(ffDecimal, digits)

proc median(values: seq[float]): float =
  var sorted = values
  sorted.sort()
  if sorted.len == 0: 0.0
  elif sorted.len mod 2 == 1: sorted[sorted.len div 2]
  else: (sorted[sorted.len div 2 - 1] + sorted[sorted.len div 2]) / 2.0

# ---------------------------------------------------------------------------
# Independent oracles for the memory fields (macOS)
# ---------------------------------------------------------------------------

when defined(macosx):
  const
    sysctlBinary = "/usr/sbin/sysctl"
    vmStatBinary = "/usr/bin/vm_stat"

  proc sysctlMemsizeBytes(): int64 =
    ## ``hw.memsize`` read through the ``sysctl`` COMMAND rather than
    ## through ``sysctlbyname``. A separate implementation of the same
    ## query, which is what makes an exact equality below meaningful
    ## rather than circular.
    let (output, code) = execCmdEx(sysctlBinary & " -n hw.memsize")
    if code != 0:
      return -1
    try: parseBiggestInt(output.strip()) except ValueError: -1

  proc vmStatAvailableBytes(): int64 =
    ## ``free + speculative + inactive`` pages, in bytes, out of
    ## ``vm_stat``.
    ##
    ## SPECULATIVE IS ADDED BACK ON PURPOSE, and it is the whole reason
    ## this oracle is worth having. ``ambient.nim`` claims in a comment
    ## that ``free_count`` from ``host_statistics64`` ALREADY INCLUDES
    ## the speculative pages ``vm_stat`` breaks out onto their own line.
    ## Summing ``vm_stat``'s free and inactive lines alone disagrees with
    ## the reader by 5.4 GB on this machine; adding speculative back
    ## brings the two to within 5 MB of each other. The equality below is
    ## therefore a live check of that documented claim, not a restatement
    ## of it -- if the reader ever double-counted speculation, or dropped
    ## inactive, this is what would notice.
    let (output, code) = execCmdEx(vmStatBinary)
    if code != 0:
      return -1
    var pageSize = 0'i64
    var pages = 0'i64
    proc pagesOn(line: string): int64 =
      let parts = line.split(':')
      if parts.len < 2: return 0
      try: parseBiggestInt(parts[1].strip().strip(chars = {'.'}))
      except ValueError: 0
    for line in output.splitLines():
      if line.startsWith("Mach Virtual Memory Statistics"):
        const sizeMarker = "page size of "
        let marker = line.find(sizeMarker)
        if marker >= 0:
          let rest = line[marker + sizeMarker.len .. ^1].splitWhitespace()
          if rest.len > 0:
            try: pageSize = parseBiggestInt(rest[0])
            except ValueError: pageSize = 0
      elif line.startsWith("Pages free:") or
          line.startsWith("Pages speculative:") or
          line.startsWith("Pages inactive:"):
        pages += pagesOn(line)
    if pageSize <= 0:
      return -1
    pages * pageSize

const
  burstReadings = 500
    ## Back-to-back reads with nothing between them. The mach tick
    ## counters do not advance this fast -- 2000 consecutive reads saw one
    ## byte-identical snapshot throughout -- which is exactly the point:
    ## a burst is where a counter that goes BACKWARDS between two adjacent
    ## calls shows up, and it costs milliseconds.

  capacitySpans = 5
  capacitySpanMillis = 3000
  advancePollMillis = 2
  advancePollAttempts = 4000
    ## THE SPAN IS PINNED TO COUNTER UPDATES, NOT TO THE WALL CLOCK, and
    ## that is a measured requirement rather than a refinement.
    ##
    ## macOS folds the mach tick counters in on its own schedule. Polled
    ## every 20 ms at ambient load, the counters moved 30 times in six
    ## seconds -- a mean gap of 172 ms, and a WORST gap of 986 ms. A span
    ## whose endpoints are taken at arbitrary instants therefore charges
    ## one span for time the next one is credited with: measured over
    ## twenty 700 ms windows, nineteen landed inside 0.5% and the
    ## twentieth read 2.1699, immediately after one that read 0.0000. The
    ## first draft of this test asserted per-window and went red on
    ## exactly that pair. Nothing was wrong with the reader; the wall
    ## clock and the counter simply do not tick together.
    ##
    ## Taking BOTH endpoints immediately after the counter has been seen
    ## to move removes the lag rather than averaging over it: whatever
    ## delay there is between an update and the reading that catches it is
    ## bounded by the poll interval, and it appears at both ends, so it
    ## cancels. Measured that way over thirty-two 3 s spans at ambient
    ## load, across seven separate runs, the ratio landed in
    ## [0.9847, 0.9998].

  capacityBandLow = 0.95
  capacityBandHigh = 1.05
    ## ``cpuTotalMillis`` advances by ONE MILLISECOND PER LOGICAL CORE PER
    ## ELAPSED MILLISECOND. This is a statement about the clock, not about
    ## the machine's load, and it is the only assertion in this file that
    ## constrains the TOTAL side on its own: the two inequalities in the
    ## saturation test compare busy against total, so a defect that scaled
    ## the total UP would pass both of them.
    ##
    ## The band is wide relative to what was measured, and deliberately so
    ## -- but what was measured is TIGHT, PROVIDED both endpoints are
    ## pinned to a counter update. Over thirty-two advance-pinned 3 s
    ## spans at ambient load the ratio landed in [0.9847, 0.9998], and
    ## over twenty-five 2.5 s windows under saturation in [0.9985,
    ## 1.0014]. Worst deviation 1.53%, better than three times inside this
    ## band's nearest edge. Unpinned, the same measurement read 1.1630
    ## once in twenty saturated windows and 2.1699 once in twenty at
    ## ambient load -- which is why nothing in this file measures a span
    ## without pinning it. It catches any scaling error of 5% or more on
    ## ``cpuTotalMillis``: a wrong tick divisor, a wrong unit, a missing
    ## state, a per-core figure reported as a machine-wide one.
    ##
    ## AND IT IS NOT REDUNDANT WITH THE SATURATION TEST, which is easy to
    ## assume because a total scaled on its own moves ``busy / total`` too.
    ## A defect that scales BOTH counters by the same factor does not: the
    ## tick divisor halved leaves ``busy / total`` at exactly 1.0000, keeps
    ## ``busyDelta <= totalDelta``, and makes ``busyDelta >= ownMillis``
    ## strictly easier. Built and run, it passes every assertion in the
    ## saturation test and fails here at 1.98.

  saturationWindows = 5
  saturationBurnMillis = 2500
  saturatedBusyFloor = 0.90
    ## A MACHINE THIS PROCESS HAS FILLED MUST READ AS BUSY. With one
    ## spinner per logical core plus two, every window measured read
    ## ``busyDelta / totalDelta`` as exactly 1.0000 -- thirty of thirty,
    ## and twelve of twelve in a standalone probe at one-times and
    ## two-times oversubscription -- because there is no idle capacity
    ## left for the kernel to charge idle ticks to.
    ##
    ## THIS IS THE ASSERTION THAT CLOSES THE HOLE, and it is a-fortiori in
    ## the direction that matters: foreign load on the machine ADDS to the
    ## busy fraction, so a busy host makes it strictly easier to satisfy,
    ## never harder. That is the property every band in
    ## ``t_ambient_load_attribution`` lacked, and it is why there is no
    ## headroom precondition in this file. It is also independent of how
    ## much of the machine WE occupy, which is what the previous attempt
    ## at this coverage got wrong: tried at about 32% occupancy, a 2x
    ## under-report still cleared this process's own usage.
    ##
    ## Against the 2x under-reporting defect in this file's header it
    ## reads 0.500 against a floor of 0.900, on every one of five windows.
    ## A ten-percent under-report is the smallest it lets through.
    ##
    ## The floor is 0.90 and not 0.99 for one reason only: the spinners
    ## have to be scheduled. Nothing about a busy host puts it at risk --
    ## a machine somebody else is hammering reads HIGHER here, not lower.
    ## What would put it at risk is a machine that refuses to run the
    ## spinners on more than a few cores, which is a machine-configuration
    ## failure (macOS low-power mode confining threads to the efficiency
    ## cluster) and reads as one: the printed figure collapses towards
    ## the E-core fraction rather than wandering near the floor.

proc advancedReading(baseline: HostLoadReading): HostLoadReading =
  ## The first reading whose cumulative total has moved past ``baseline``.
  ##
  ## Not a retry-until-green: it is how a span is pinned to the kernel's
  ## own update schedule instead of to the wall clock. Bounded, and a
  ## machine whose counters never move again yields an UNAVAILABLE reading
  ## with a zero total, which the caller counts and asserts against rather
  ## than skipping.
  for _ in 0 ..< advancePollAttempts:
    let current = readHostLoad()
    if current.cpuTotalMillis > baseline.cpuTotalMillis:
      return current
    sleep(advancePollMillis)
  HostLoadReading(available: false)

suite "host_load_reading_invariants":

  test "a reading is well-formed and its counters never go backwards":
    # The cheapest invariants, and the ones that hold at any load: a
    # reading describes a machine, and cumulative counters are cumulative.
    let first = readHostLoad()
    check first.available
    check first.source.len > 0
    check first.detail.len == 0
    check first.atUnixMillis > 0
    check first.cpuTotalMillis > 0
    check first.memTotalBytes > 0

    var previous = first
    var backwards = 0
    var advanced = 0
    for _ in 0 ..< burstReadings:
      let current = readHostLoad()
      # NEVER RAISES: the reader's own contract. A burst of five hundred
      # calls with nothing between them is where a partially-filled
      # snapshot would surface.
      check current.available
      check current.source == first.source
      check current.detail.len == 0
      # CUMULATIVE MEANS CUMULATIVE. Each of these is a since-boot
      # counter; the sampler differences pairs of them, and a counter
      # that can go backwards makes every rate downstream a large wrong
      # number rather than a missing one.
      if current.cpuBusyMillis < previous.cpuBusyMillis or
          current.cpuTotalMillis < previous.cpuTotalMillis or
          current.swapInPages < previous.swapInPages or
          current.atUnixMillis < previous.atUnixMillis:
        backwards += 1
      if current.cpuTotalMillis > previous.cpuTotalMillis:
        advanced += 1
      # A HOST CANNOT BE BUSIER THAN ITS OWN CAPACITY. True of the
      # cumulative pair as well as of any difference of them.
      check current.cpuBusyMillis >= 0
      check current.cpuBusyMillis <= current.cpuTotalMillis
      # And the memory fields describe the same machine as each other.
      check current.memAvailableBytes > 0
      check current.memAvailableBytes <= current.memTotalBytes
      check current.memTotalBytes == first.memTotalBytes
      check current.swapInPages >= 0
      check current.loadAvg1m >= 0.0
      check current.ioQueueDepth == ioQueueDepthUnmeasured or
        current.ioQueueDepth >= 0.0
      previous = current

    echo "  hostload burst: readings=", burstReadings,
      " backwards=", backwards, " advanced=", advanced,
      " busy/total=",
      f(float(previous.cpuBusyMillis) / float(previous.cpuTotalMillis)),
      " memAvail/memTotal=",
      f(float(previous.memAvailableBytes) / float(previous.memTotalBytes))
    check backwards == 0
    # Not a rate claim: only that a burst this short does not somehow
    # advance every counter, which would mean the "counter" is a clock.
    check advanced < burstReadings

    # The cumulative pair is a WEAK constraint and this is the record of
    # how weak, so nobody mistakes it for coverage of the busy side: this
    # machine's since-boot busy fraction is about 0.14, so a reader
    # over-reporting busy by 1.8x would still satisfy
    # `cpuBusyMillis <= cpuTotalMillis` on every one of these readings.
    # The saturation test below is where that direction is caught.
    check float(first.cpuBusyMillis) / float(first.cpuTotalMillis) <= 1.0

  test "cpu_total_millis advances at one millisecond per logical core":
    # AN IDENTITY ABOUT TIME, NOT ABOUT LOAD, which is what lets it be
    # asserted at whatever the machine happens to be doing and lets it be
    # asserted tightly. `cpuTotalMillis` is busy + idle summed over every
    # logical core, so between two readings it must advance by the
    # elapsed wall time times the core count -- a core is always in one
    # state or the other.
    #
    # This and its twin inside the saturation test are the only
    # assertions in the file that pin the TOTAL side by itself: every
    # other one compares busy against total, so a defect scaling BOTH by
    # the same factor satisfies all of them. This one runs at ambient
    # load and needs the counter-update pinning; the twin runs on a full
    # machine, where the counters move too fast for the pinning to
    # matter. Between them the identity is asserted where the counters
    # move slowest and where they move fastest.
    let cores = max(1, cpuinfo.countProcessors())
    check cores >= 1
    var ratios: seq[float] = @[]
    var pinFailures = 0
    for _ in 0 ..< capacitySpans:
      let before = advancedReading(readHostLoad())
      sleep(capacitySpanMillis)
      let after = advancedReading(readHostLoad())
      # A span whose endpoint could not be pinned to a counter update is
      # a MACHINE that stopped reporting, not a tolerance to widen: it is
      # counted and asserted to be zero rather than skipped.
      if not before.available or not after.available:
        pinFailures += 1
        continue
      let elapsedMillis = after.atUnixMillis - before.atUnixMillis
      check elapsedMillis > 0
      let capacity = float(elapsedMillis) * float(cores)
      let totalDelta = float(after.cpuTotalMillis - before.cpuTotalMillis)
      let ratio = totalDelta / capacity
      ratios.add(ratio)
      check ratio > capacityBandLow
      check ratio < capacityBandHigh
    echo "  hostload capacity: cores=", cores, " spans=", ratios.len,
      " median=", f(median(ratios)),
      " min=", f(min(ratios)), " max=", f(max(ratios)),
      " pinFailures=", pinFailures
    check pinFailures == 0
    check ratios.len == capacitySpans

  test "a machine this process fills reads as busy, never busier than full":
    # THE ASSERTION THAT COVERS THE BUSY SIDE, in both directions, without
    # a tolerance and without a headroom precondition.
    #
    # The machine is filled with one spinner per logical core plus two.
    # Everything asserted per window is a-fortiori: more occupancy -- from
    # these spinners, from the rest of the suite, from whoever else is
    # using the machine -- makes each inequality STRICTLY HARDER TO
    # VIOLATE. There is therefore no busy-host failure mode here, which is
    # precisely what every band in `t_ambient_load_attribution` could not
    # claim.
    let cores = max(1, cpuinfo.countProcessors())
    let spinners = min(maxSpinners, cores + 2)
    var busyOverTotal: seq[float] = @[]
    var busyOverOwn: seq[float] = @[]
    var capacityRatios: seq[float] = @[]
    var load = startLoad(spinners)
    try:
      # The scheduler has to have placed the threads before the first
      # window opens, or that window measures the ramp rather than the
      # steady state. Not a settling tolerance: it is discarded time.
      sleep(400)
      for _ in 0 ..< saturationWindows:
        # PINNED TO COUNTER UPDATES AT BOTH ENDS, exactly as the capacity
        # test is, and for a reason that was measured rather than
        # anticipated: the first draft pinned only there, on the argument
        # that a full machine folds its counters in every scheduler tick.
        # That argument is right about the STEADY STATE and wrong about
        # the FIRST window, whose opening reading is taken moments after
        # an idle stretch and can still catch a snapshot the kernel has
        # not refreshed. Measured across four full-suite runs it went
        # wrong once, on window one, reading 1.1630 against a 1.05 ceiling
        # -- the counter caught up inside the window and the window was
        # credited with time it had not been open for.
        #
        # The same lag would push `busyDelta` DOWN at a stale closing
        # reading, which is the direction that matters far more: at the
        # observed occupancy it is enough to take `busyDelta >= ownMillis`
        # below 1. Pinning removes it from every assertion in this loop
        # rather than only from the one that noticed.
        #
        # NESTED ON PURPOSE. The host window strictly CONTAINS this
        # process's own accounting window, so the work `getrusage`
        # reports really did happen inside the interval the host counters
        # cover, and the inequality below is exact rather than
        # approximate.
        let before = advancedReading(readHostLoad())
        let ownBefore = selfCpuMillis()
        sleep(saturationBurnMillis)
        let ownAfter = selfCpuMillis()
        let after = advancedReading(readHostLoad())

        check before.available
        check after.available
        if not before.available or not after.available:
          continue
        let totalDelta = float(after.cpuTotalMillis - before.cpuTotalMillis)
        let busyDelta = float(after.cpuBusyMillis - before.cpuBusyMillis)
        let ownMillis = ownAfter - ownBefore
        check totalDelta > 0.0
        check ownMillis > 0.0

        # OVER-REPORTING. A host cannot be busier than its own capacity.
        # On the cumulative counters this is nearly vacuous -- a machine
        # 14% busy since boot has room for a 1.8x over-report -- but on a
        # SATURATED interval the two are equal, so any over-report at all
        # breaks it.
        check busyDelta <= totalDelta

        # UNDER-REPORTING, and the weaker of the two forms because its
        # power depends on how much of the machine we occupy. It is here
        # because it assumes NOTHING about the platform: no core count,
        # no scheduler behaviour, no idle accounting. The host cannot be
        # less busy than one process running on it.
        check busyDelta >= ownMillis

        # UNDER-REPORTING, the form that closes the hole. It does not
        # depend on our share of the machine at all -- only on the
        # machine being full, which the spinners guarantee and which any
        # foreign load only reinforces.
        check busyDelta >= saturatedBusyFloor * totalDelta

        # THE WALL-CLOCK IDENTITY AGAIN, asserted in both places on
        # purpose: this one covers it while the counters are moving
        # fastest, the other while they are moving slowest.
        let elapsedMillis = float(after.atUnixMillis - before.atUnixMillis)
        check elapsedMillis > 0.0
        let capacityRatio = totalDelta / (elapsedMillis * float(cores))
        capacityRatios.add(capacityRatio)
        check capacityRatio > capacityBandLow
        check capacityRatio < capacityBandHigh

        busyOverTotal.add(busyDelta / totalDelta)
        busyOverOwn.add(busyDelta / ownMillis)
    finally:
      load.stopLoad()
    # Nothing after this line may run while a spinner is alive.
    check not load.running

    echo "  hostload saturated: spinners=", spinners,
      " windows=", busyOverTotal.len,
      " busy/total min=", f(min(busyOverTotal)),
      " median=", f(median(busyOverTotal)),
      " busy/own min=", f(min(busyOverOwn)),
      " median=", f(median(busyOverOwn)),
      " capacity min=", f(min(capacityRatios)),
      " max=", f(max(capacityRatios))
    check busyOverTotal.len == saturationWindows

  when defined(macosx):
    test "the memory fields agree with an independent read of the kernel":
      # NOT A SECOND OPINION ABOUT THE MACHINE: `sysctl` and `vm_stat` are
      # separate implementations reading the SAME kernel interfaces the
      # reader uses, so a disagreement is a defect in the reader's
      # arithmetic -- a wrong page size, a pages-for-bytes slip, a dropped
      # or double-counted field -- and not weather.
      check fileExists(sysctlBinary)
      check fileExists(vmStatBinary)

      let reading = readHostLoad()
      check reading.available
      # EXACT. `memTotalBytes` is a constant of the hardware; there is no
      # drift for a tolerance to absorb, so there is no tolerance.
      let oracleTotal = sysctlMemsizeBytes()
      check oracleTotal > 0
      check reading.memTotalBytes == oracleTotal

      # `memAvailableBytes` moves between the two calls, so this one is a
      # ratio -- but the observed drift is five parts in a hundred
      # thousand, so the band below is a thousand times the noise. What it
      # catches is a change of SCALE, which is the only way this field
      # goes wrong quietly: the page size (16 KiB here, 4 KiB elsewhere)
      # is a factor of four, and pages-reported-as-bytes is a factor of
      # 16384. Dropping `inactive_count` was built and run: it reads
      # 0.7195 against the 0.95 floor.
      #
      # NOT COVERED BY THIS, AND DELIBERATELY SAID OUT LOUD: nothing here
      # or anywhere else pins how `memAvailableBytes` RESPONDS to an
      # allocation. The memory arm of `t_ambient_load_attribution` asserts
      # that with a liveness floor of 0.25x, so a reader that tracked
      # memory at half scale would clear it. This oracle catches a reader
      # whose ABSOLUTE value is wrong; it cannot catch one whose response
      # is.
      var ratios: seq[float] = @[]
      for _ in 0 ..< 5:
        let sample = readHostLoad()
        let oracleAvailable = vmStatAvailableBytes()
        check sample.available
        check oracleAvailable > 0
        ratios.add(float(sample.memAvailableBytes) / float(oracleAvailable))
        sleep(150)
      echo "  hostload memory: memTotal=", reading.memTotalBytes,
        " oracle=", oracleTotal,
        " avail/oracle median=", f(median(ratios)),
        " min=", f(min(ratios)), " max=", f(max(ratios))
      check median(ratios) > 0.95
      check median(ratios) < 1.05
