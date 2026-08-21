## M11 gate, the measured half: ``foreign_*`` tracked against a KNOWN
## synthetic load, running alongside real RunQuota-admitted executions.
##
## No mocks. The sampler is the real one the daemon starts, writing real
## rows into a real SQLite store; the leases are granted by a real
## ``runquotad`` over a real socket; the load is real CPU burnt and real
## pages touched. The deterministic half of the gate — the arithmetic and
## the clamp, asserted to the bit — is
## ``t_observation_store_ambient_attribution``.
##
## HOW THE LOAD IS MADE KNOWN. The synthetic load runs as THREADS OF THIS
## PROCESS, and the figure it is compared against is this process's own
## CPU time from ``getrusage(RUSAGE_SELF)``, differenced across the
## measurement window and divided by (wall time x logical cores). Three
## things follow, and all three are the point:
##
## * It is a measurement rather than an assumption. "Four spinners must be
##   25%" is an assumption; 23.37% read out of the kernel is not.
## * CPU time and wall time are not interchangeable, and this is where the
##   distinction is load-bearing: the numerator is CPU time, the
##   denominator is wall time times cores. A P-core and an E-core deliver
##   different work per second on this machine and identical CPU time per
##   second, so the ratio is immune to which cluster the scheduler picked.
## * Threads of THIS process are the strongest available probe of the
##   no-process-tree-inspection boundary. A sampler that walked the process
##   tree it lives in would fold the whole load into ``self``. It stays at
##   exactly the declared figure instead.
##
## WHY THE LOAD IS SWITCHED ON AND OFF MANY TIMES INSTEAD OF ONCE. The
## absolute value of ``foreign_cpu_pct`` says as much about what else the
## machine is doing as about the load under test, and that background is
## not steady: on the machine this was developed on — a workstation with
## several VMs, ``fseventsd`` and Spotlight running — the host-wide figure
## wandered between 56% and 88% over twenty consecutive one-second
## readings, and a single before/after pair inverted outright more than
## once. Drift on that timescale is uncorrelated with a load toggled every
## few hundred milliseconds, so pooling all the ON samples against all the
## OFF samples cancels it; a sampler reporting a CONSTANT does not cancel,
## and reads as no effect at all. This is M4's finding — many short
## measurement loops beat few long ones — applied to a different quantity.
##
## STATED TOLERANCE AND ITS VARIANCE. The gate asserts the PAIRED ratio of
## measured to known within **+/-40%**, the pooled one only inside a loose
## band as a cross-check, and a majority of cycles carrying more than 0.3x
## the known load. Nothing is asserted about an individual cycle's
## magnitude.
##
## How that number was arrived at, since a tolerance quoted without its
## measurements is a guess. On a QUIET 16-core Apple M3 Max, ten
## before/after repetitions of a 50%-of-capacity load gave ratios in
## [0.900, 1.044], median 0.994, and a 2 GiB allocation was tracked to
## within 2.1%. On the same machine BUSY at 70-85%, single before/after
## repetitions ranged from **-1.52 to 1.69** — which is what motivated the
## interleaving. With fourteen cycles and paired medians, seven
## consecutive runs at 23-68% background load gave a paired ratio in
## **[1.004, 1.090]** and a memory ratio in **[0.833, 1.077]**. The
## tolerance is four times the observed spread because the residual is
## approximate by construction and the machine under it belongs to
## somebody who is also using it. The claim being made is "``foreign_*``
## tracks a known load within tens of percent", and no stronger claim is
## available from a residual computed by difference.
##
## AND IT REFUSES TO PRETEND. Near full scale the measurement is not
## possible at all: a load added to a saturated machine DISPLACES other
## work instead of adding to it, so the host-wide total barely moves and
## no sampler deriving ``foreign`` by difference could report it —
## measured at 86% busy, a known 12.2-point load moved the figure by 1.85
## points. The test waits a bounded while for headroom, re-runs a block
## whose own OFF baseline turned out to have been out of range, and then
## FAILS saying so rather than reporting a ratio it cannot support.

import std/[algorithm, atomics, cpuinfo, os, osproc, posix, random, streams,
            strutils, times, unittest]

import runquota_client
import runquota_core
import runquota_observation_store

# ---------------------------------------------------------------------------
# The synthetic load
# ---------------------------------------------------------------------------
#
# TWO INDEPENDENT KILL SWITCHES, on purpose. The stop flag is an
# `Atomic[bool]` because a plain `var bool` read in a tight loop is hoisted
# out of it by the optimiser -- that is not hypothetical, it left a
# spinning process behind exactly once while this test was being written,
# and the process had to be killed by hand. The deadline is the second
# switch: even if the flag were never observed, every spinner exits on its
# own within `spinnerLifetimeSeconds` of being started.
#
# `spinnerBurn` is separate from `spinnerStop` so the load can be toggled
# without paying thread creation on every cycle: idle spinners sleep.

const
  maxSpinners = 64
  spinnerLifetimeSeconds = 120.0

var
  spinnerStop: Atomic[bool]
  spinnerBurn: Atomic[bool]
  spinnerDeadline: Atomic[float]
  spinnerSink: array[maxSpinners, uint64]

proc spinner(slot: int) {.thread.} =
  var x = 0'u64
  while not spinnerStop.load(moRelaxed) and
      epochTime() < spinnerDeadline.load(moRelaxed):
    if spinnerBurn.load(moRelaxed):
      for i in 0 ..< 20_000:
        x = (x * 6364136223846793005'u64 + 1442695040888963407'u64) xor uint64(i)
      spinnerSink[slot] = x
    else:
      sleep(2)

type LoadGenerator = object
  threads: seq[ptr Thread[int]]
  running: bool

proc startLoad(count: int): LoadGenerator =
  spinnerStop.store(false, moRelaxed)
  spinnerBurn.store(false, moRelaxed)
  spinnerDeadline.store(epochTime() + spinnerLifetimeSeconds, moRelaxed)
  for i in 0 ..< count:
    let handle = createShared(Thread[int])
    createThread(handle[], spinner, i)
    result.threads.add(handle)
  result.running = true

proc burn(load: LoadGenerator; on: bool) =
  spinnerBurn.store(on, moRelaxed)

proc stopLoad(load: var LoadGenerator) =
  ## Idempotent, and always joins. Nothing in this file may return while a
  ## spinner is still burning a core: a leaked load generator contaminates
  ## every measurement taken after it, in this suite and in any other.
  if not load.running:
    return
  spinnerBurn.store(false, moRelaxed)
  spinnerStop.store(true, moRelaxed)
  spinnerDeadline.store(0.0, moRelaxed)
  for handle in load.threads:
    joinThread(handle[])
    deallocShared(handle)
  load.threads = @[]
  load.running = false

# ---------------------------------------------------------------------------
# The synthetic memory load
# ---------------------------------------------------------------------------
#
# `mmap`/`munmap` rather than a Nim `seq`: a general-purpose allocator
# keeps freed pages on its own free list, so the second cycle of an
# allocate/free loop reuses pages that are ALREADY RESIDENT and the host
# sees no change at all. Measured that way, cycles after the first read as
# -0.23 and -0.09 of the known load. Anonymous mappings go back to the
# kernel on `munmap`, which is what makes a cycle repeatable.

type MemoryLoad = object
  base: pointer
  size: int

proc takeMemory(size: int; random: var Rand): MemoryLoad =
  let base = mmap(nil, size, PROT_READ or PROT_WRITE,
    MAP_PRIVATE or MAP_ANONYMOUS, -1, 0)
  doAssert base != MAP_FAILED, "mmap of " & $size & " bytes failed"
  # Touched at page granularity with unpredictable bytes: an untouched
  # anonymous page is never backed at all, and a compressible one is taken
  # by the macOS memory compressor -- either would leave the allocation
  # invisible to a host-wide "available memory" figure.
  let bytes = cast[ptr UncheckedArray[byte]](base)
  var offset = 0
  while offset < size:
    bytes[offset] = byte(random.rand(255))
    offset += 4096
  MemoryLoad(base: base, size: size)

proc release(load: var MemoryLoad) =
  if load.base != nil:
    discard munmap(load.base, load.size)
    load.base = nil

# ---------------------------------------------------------------------------
# Measurement helpers
# ---------------------------------------------------------------------------

proc selfCpuSeconds(): float =
  ## This process's own CPU time, every thread of it. The figure the
  ## synthetic load is "known" by.
  var usage: RUsage
  if getrusage(RUSAGE_SELF, addr usage) != 0:
    return 0.0
  float(usage.ru_utime.tv_sec) + float(usage.ru_utime.tv_usec) / 1e6 +
  float(usage.ru_stime.tv_sec) + float(usage.ru_stime.tv_usec) / 1e6

type Window = object
  fromMillis, toMillis: int64
  cpuSeconds: float
    ## This process's own CPU time inside the window.
  wallSeconds: float

proc observe(millis: int): Window =
  let cpuBefore = selfCpuSeconds()
  let wallBefore = epochTime()
  sleep(millis)
  let cpuAfter = selfCpuSeconds()
  let wallAfter = epochTime()
  Window(
    fromMillis: int64(wallBefore * 1000.0),
    toMillis: int64(wallAfter * 1000.0),
    cpuSeconds: cpuAfter - cpuBefore,
    wallSeconds: wallAfter - wallBefore)

proc ownCpuPct(windows: openArray[Window]): float =
  ## The pooled CPU this process consumed across ``windows``, as a
  ## percentage of the whole machine's capacity -- the same unit as
  ## ``cpu_busy_pct``.
  let cores = float(max(1, cpuinfo.countProcessors()))
  var cpu = 0.0
  var wall = 0.0
  for window in windows:
    cpu += window.cpuSeconds
    wall += window.wallSeconds
  if wall <= 0.0: 0.0 else: 100.0 * cpu / (wall * cores)

proc median(values: seq[float]): float =
  var sorted = values
  sorted.sort()
  if sorted.len == 0: 0.0
  elif sorted.len mod 2 == 1: sorted[sorted.len div 2]
  else: (sorted[sorted.len div 2 - 1] + sorted[sorted.len div 2]) / 2.0

proc inWindows(rows: seq[AmbientSampleRow]; windows: openArray[Window]):
    seq[AmbientSampleRow] =
  for row in rows:
    for window in windows:
      if row.sampledAtUnixMillis >= window.fromMillis and
          row.sampledAtUnixMillis <= window.toMillis:
        result.add(row)
        break

proc foreignCpu(rows: seq[AmbientSampleRow]): seq[float] =
  for row in rows:
    result.add(row.foreignCpuPct)

proc foreignRss(rows: seq[AmbientSampleRow]): seq[float] =
  for row in rows:
    result.add(float(row.foreignRssBytes))

proc hostBusyPct(overMillis = 600): float =
  ## What fraction of the whole machine is busy right now, read through the
  ## same host-wide interface the sampler uses. A stale kernel snapshot is
  ## retried rather than reported as 0.0.
  var previous = readHostLoad()
  for _ in 0 ..< 10:
    sleep(overMillis)
    let current = readHostLoad()
    case classifyReadings(previous, current)
    of rpAdvanced:
      return attributeAmbientSample("probe", previous, current, []).cpuBusyPct
    of rpDiscontinuous:
      previous = current
    of rpStale:
      discard
  -1.0

const maxBusyForMeasurement = 70.0
  ## Above this the gate CANNOT BE EVALUATED, and says so instead of
  ## reporting a number.
  ##
  ## This is not conservatism. Measured on a host already at 86% busy, a
  ## known 12.2-point load moved the host-wide figure by 1.85 points and
  ## only 20 of 37 ON samples exceeded the OFF median — chance. The load
  ## was real and was consumed; it DISPLACED other work rather than adding
  ## to it, because the machine had nothing left to give. No sampler
  ## deriving ``foreign`` by difference from a host-wide total can report
  ## a load a saturated host absorbed, and a gate that asserted otherwise
  ## would be asserting that the machine was quiet.

proc waitForHeadroom(maxSeconds: int): float =
  ## The host's busy fraction, waiting a bounded while for it to come down
  ## far enough to measure against. Returns the last reading either way:
  ## the caller asserts, so a machine that never settles FAILS rather than
  ## quietly skipping.
  let deadline = epochTime() + float(maxSeconds)
  result = hostBusyPct()
  while result > maxBusyForMeasurement and epochTime() < deadline:
    sleep(2000)
    let reading = hostBusyPct()
    if reading >= 0.0:
      result = reading

proc spinnersForHeadroom(busyPct: float; cores: int): int =
  ## Size the synthetic load to the CPU the machine actually has spare.
  ##
  ## A fixed half-the-cores is the right load on an idle machine and no
  ## load at all on one already at 85%: the host-wide figure saturates at
  ## 100%, the increase gets clipped, and no sampler could report it. The
  ## figure stays KNOWN either way, because it is read out of ``getrusage``
  ## afterwards rather than inferred from the thread count.
  let headroom = max(0.0, 100.0 - busyPct)
  clamp(int(headroom * 0.45 / 100.0 * float(cores)), 2, max(2, cores div 2))

proc scratchDir(name: string): string =
  # Short on purpose: a Unix-domain socket path is capped at ~104 bytes.
  result = getTempDir() / ("rq-m11-" & $getCurrentProcessId() & "-" & name)
  removeDir(result)
  createDir(result)

proc openSampledStore(dir: string; cadenceMillis: int):
    tuple[store: ObservationStore; hostId: string] =
  let path = dir / "observations.sqlite"
  let store = openObservationStore(path)
  doAssert store.captureEnabled, store.report
  let hostId = resolveHostIdentity(dir / "host-id").hostId
  doAssert store.ensureHostRow(hostId, "boot-m11")
  startAmbientSampler(path, hostId, cadenceMillis, flushSamples = 4)
  (store, hostId)

const
  cadenceMillis = 200
    ## The sampler's FIXED cadence for these tests. Short and repeated
    ## rather than long and singular: a single long measurement loop
    ## straddles frequency transitions and P/E-core migrations and averages
    ## them into one number nobody can decompose.
  cpuCycles = 14
  blockAttempts = 3
    ## Bounded: a machine that never offers a measurable window FAILS
    ## rather than looping.
  fullScaleCeiling = 92.0
    ## The OFF baseline plus the known load must stay under this, or the
    ## host-wide figure runs out of scale and clips the very increase the
    ## gate is measuring.
  settleMillis = 250
    ## Discarded after each toggle: thread wake-up and the scheduler's
    ## response are not part of the steady state being compared.
  halfCycleMillis = 700
  pairedTolerance = 0.40
    ## THE STATED TOLERANCE, on the PAIRED estimator: the median over
    ## cycles of (ON median - OFF median) for that cycle's own two windows.
    ##
    ## Paired rather than pooled because the two estimators were measured
    ## against each other over six runs on the machine this was written on.
    ## Paired landed in [0.875, 1.160]; pooling every ON sample against
    ## every OFF sample landed in [0.599, 1.211] on the same runs, because
    ## the machine's own background load drifts on a multi-second timescale
    ## that pairing adjacent windows cancels and pooling does not. On a
    ## QUIET host either estimator lands within ten percent; this is four
    ## times that, because the residual is approximate by construction and
    ## the machine under it belongs to somebody who is also using it.
  pooledBandLow = 0.40
  pooledBandHigh = 1.80
    ## The pooled estimator is asserted too, but only loosely: it is a
    ## cross-check that the paired figure is not a pairing artefact, and
    ## its own spread is wide enough that a tight band on it would be a
    ## flake generator rather than a gate.
  rankMajority = 0.65
    ## The fraction of CYCLES that must have seen the load on their own,
    ## in both the CPU and the memory arm. Under no effect it would be at
    ## most 0.5, and for a sampler reporting a constant it is 0.0.

suite "ambient_load_attribution":

  test "foreign_cpu_pct tracks a known synthetic foreign load":
    let dir = scratchDir("cpu")
    defer: removeDir(dir)
    stopAmbientSampler()
    clearSelfReportedExecutions()
    let (store, _) = openSampledStore(dir, cadenceMillis)
    check ambientSamplerActive()

    let cores = max(1, cpuinfo.countProcessors())
    var busyBefore = -1.0
    var spinners = 0
    var onWindows: seq[Window] = @[]
    var offWindows: seq[Window] = @[]
    var inRange = false
    var load = LoadGenerator()
    try:
      # INSTRUMENT RANGE, CHECKED AGAINST THE MEASUREMENT'S OWN BASELINE
      # AND NOT ONLY AGAINST A PROBE TAKEN BEFORE IT. The probe said 64.9%
      # once and the OFF windows then ran at 89.65%, where a known
      # 12-point load moved the host-wide figure by 6: the machine got
      # busy while the block was running. A block whose OFF baseline plus
      # the known load exceeds full scale was taken out of range and is
      # re-run rather than reported.
      #
      # The criterion looks at the OFF windows and the load, never at the
      # ON windows and never at the ratio. A sampler pinned at 100% is
      # never in range and fails through this; a sampler reporting 0 is
      # always in range and fails on the ratio.
      for attempt in 0 ..< blockAttempts:
        busyBefore = waitForHeadroom(45)
        check busyBefore >= 0.0
        if busyBefore > maxBusyForMeasurement:
          echo "  m11 cpu: HOST HAS NO CPU HEADROOM (",
            busyBefore.formatFloat(ffDecimal, 1), "% busy); this gate needs ",
            (100.0 - maxBusyForMeasurement).formatFloat(ffDecimal, 0),
            " points free to measure a load by its effect on a host-wide total"
          break
        spinners = spinnersForHeadroom(busyBefore, cores)
        onWindows = @[]
        offWindows = @[]
        load = startLoad(spinners)
        for _ in 0 ..< cpuCycles:
          load.burn(false)
          sleep(settleMillis)
          offWindows.add(observe(halfCycleMillis))
          load.burn(true)
          sleep(settleMillis)
          onWindows.add(observe(halfCycleMillis))
        load.burn(false)
        load.stopLoad()

        sleep(cadenceMillis * 2)
        let soFar = store.readAmbientSamples()
        let offSoFar = median(foreignCpu(inWindows(soFar, offWindows)))
        let knownSoFar = ownCpuPct(onWindows) - ownCpuPct(offWindows)
        inRange = offSoFar + knownSoFar <= fullScaleCeiling
        if inRange:
          break
        echo "  m11 cpu: block ", attempt, " OUT OF RANGE (off=",
          offSoFar.formatFloat(ffDecimal, 1), "% + known=",
          knownSoFar.formatFloat(ffDecimal, 1), "pp exceeds ",
          fullScaleCeiling.formatFloat(ffDecimal, 0), "%); re-running"
    finally:
      load.stopLoad()
    # Nothing below this line may run while a spinner is alive.
    check not load.running
    check busyBefore <= maxBusyForMeasurement
    check inRange
    check onWindows.len == cpuCycles
    check offWindows.len == cpuCycles

    sleep(cadenceMillis * 3)
    stopAmbientSampler()
    check not ambientSamplerActive()
    let rows = store.readAmbientSamples()

    # The sampler ran on its cadence at all, and every tick that did not
    # turn into a row is accounted for rather than silently missing.
    check rows.len >= 40
    check ambientSamplesWritten() == int64(rows.len)
    check ambientSampleFailures() == 0
    check ambientSamplesDropped() == 0
    check ambientReadingsUnavailable() == 0
    # Every tick of the fixed cadence is accounted for: it produced a row,
    # or it saw a snapshot the kernel had not updated, or it saw a counter
    # go backwards, or its millisecond was already taken by a written
    # sample. The `+ 1` is the very first reading, which establishes the
    # baseline a rate is measured against and can be nothing else.
    #
    # The collision term is normally zero -- a 200 ms cadence does not put
    # two samples in one millisecond -- but it is a BUCKET and not an
    # exception: a colliding sample is dropped and counted rather than
    # re-timed, so it has to appear here or the identity would call an
    # honest drop a missing tick.
    check ambientSamplerTicks() ==
      ambientSamplesTaken() + ambientReadingsStale() +
      ambientReadingsDiscontinuous() + ambientReadingsUnavailable() +
      ambientSamplesCollided() + 1

    let onRows = inWindows(rows, onWindows)
    let offRows = inWindows(rows, offWindows)
    check onRows.len >= 14
    check offRows.len >= 14

    let onMedian = median(foreignCpu(onRows))
    let offMedian = median(foreignCpu(offRows))
    let known = ownCpuPct(onWindows) - ownCpuPct(offWindows)
    let measured = onMedian - offMedian
    let ratio = measured / known

    # The synthetic load really was synthetic, really ran, and really was
    # large enough to see past the machine's own noise.
    check known >= 8.0
    check known <= 60.0
    # And the machine had room for it, so the host-wide figure was not
    # pinned at full scale while it ran.
    check onMedian < 99.0

    # THE ESTIMATOR THE GATE IS STATED ON: the same quantity computed
    # pairwise, cycle by cycle. The two windows of one cycle are about a
    # second apart, so a paired difference cancels drift the pooled one
    # cannot, and the median over fourteen pairs makes a single inverted
    # pair harmless.
    var paired: seq[float] = @[]
    for i in 0 ..< cpuCycles:
      let on = inWindows(rows, [onWindows[i]])
      let off = inWindows(rows, [offWindows[i]])
      if on.len > 0 and off.len > 0:
        paired.add(median(foreignCpu(on)) - median(foreignCpu(off)))
    check paired.len >= cpuCycles - 2
    let pairedRatio = median(paired) / known

    # Printed rather than only asserted: the campaign's rule is that a
    # figure is reported with its spread, and the spread of this one is a
    # property of the machine the suite happened to run on.
    echo "  m11 cpu paired: median=", median(paired).formatFloat(ffDecimal, 2),
      "pp ratio=", pairedRatio.formatFloat(ffDecimal, 3),
      " pairs=", paired.len
    echo "  m11 cpu pooled: spinners=", spinners, " busyBefore=",
      busyBefore.formatFloat(ffDecimal, 1),
      "% off=", offMedian.formatFloat(ffDecimal, 2),
      "% on=", onMedian.formatFloat(ffDecimal, 2),
      "% measured=", measured.formatFloat(ffDecimal, 2),
      "pp known=", known.formatFloat(ffDecimal, 2),
      "pp ratio=", ratio.formatFloat(ffDecimal, 3),
      " samples=", offRows.len, "/", onRows.len

    # THE TRACKING ASSERTION. It is a DIFFERENCE, so it fails on a quiet
    # host exactly as loudly as on a busy one: a sampler reporting zero, or
    # the host total, or any other value that does not move with the load,
    # yields a ratio of zero and fails here.
    check pairedRatio > 1.0 - pairedTolerance
    check pairedRatio < 1.0 + pairedTolerance
    # And the same effect is there when the samples are pooled instead,
    # loosely, so the figure above cannot be an artefact of how the
    # windows were paired.
    check ratio > pooledBandLow
    check ratio < pooledBandHigh

    # A COUNT beside the ratio, because a median can be moved by a few
    # extreme values and a count of independent cycles cannot: a majority
    # of the fourteen cycles must have seen the load ON THEIR OWN. It is
    # counted per cycle rather than per sample for the same reason the
    # ratio is paired -- a pooled rank inherits the drift the pairing was
    # introduced to cancel, and read 0.643 in a block whose paired ratio
    # was a healthy 0.916. For a sampler reporting a constant this count
    # is zero.
    var carrying = 0
    for delta in paired:
      if delta > known * 0.3:
        carrying += 1
    echo "  m11 cpu cycles: ", carrying, "/", paired.len,
      " carrying more than 0.3x the known load"
    check float(carrying) / float(paired.len) >= rankMajority

    # NO WRITTEN SAMPLE MAY CLAIM AN IDLE MACHINE WHILE THE LOAD IS
    # BURNING. macOS updates the mach tick counters on its own schedule,
    # and a byte-identical snapshot divided by itself is 0.0 -- which lands
    # in the column as "idle" rather than as "not measured". Before
    # `classifyReadings` existed, 12% of samples read exactly 0.0 under
    # this very load.
    for row in onRows:
      check row.cpuBusyPct > 0.0
      check row.foreignCpuPct > 0.0

    # Sanity on the rest of the row: the sampler fills in the whole table,
    # not one column of it.
    var previousAt = 0'i64
    for row in rows:
      check row.sampledAtUnixMillis > previousAt
      previousAt = row.sampledAtUnixMillis
      check row.cpuBusyPct >= 0.0
      check row.cpuBusyPct <= 100.0
      check row.memAvailableBytes > 0
      check row.loadAvg1m > 0.0
      check row.swapInRate >= 0.0
      check row.foreignCpuPct >= 0.0
      check row.foreignRssBytes >= 0
      check row.ioQueueDepth == ioQueueDepthUnmeasured or
        row.ioQueueDepth >= 0.0

  test "foreign_rss_bytes tracks a known synthetic memory load":
    let dir = scratchDir("mem")
    defer: removeDir(dir)
    stopAmbientSampler()
    clearSelfReportedExecutions()
    let (store, _) = openSampledStore(dir, cadenceMillis)

    const knownBytes = 4'i64 * 1024 * 1024 * 1024
    const memoryCycles = 9
      ## Enough that a MEDIAN over cycles survives two bad ones. Resident
      ## memory on this machine moves by gigabytes on its own -- a Time
      ## Machine pass released 3.4 GB inside one measurement while this was
      ## being written, inverting it outright -- and the only defence
      ## against drift that large is the same one the CPU arm uses: many
      ## short cycles and a statistic that ignores outliers.
    const unmapSettleMillis = 900
      ## Longer than the toggle settle used for CPU, and measured rather
      ## than guessed: with 250 ms the empty windows after the first cycle
      ## still counted pages the kernel had not finished reclaiming, and
      ## the arm read a systematic two thirds of the known load.

    var random = initRand(0x11)
    var emptyWindows: seq[Window] = @[]
    var fullWindows: seq[Window] = @[]
    var memory = MemoryLoad()
    try:
      for _ in 0 ..< memoryCycles:
        emptyWindows.add(observe(800))
        memory = takeMemory(int(knownBytes), random)
        sleep(settleMillis)
        fullWindows.add(observe(800))
        # Asserted while the allocation is STILL MAPPED: releasing it
        # before the window closed would make the measurement about
        # nothing.
        check memory.base != nil
        memory.release()
        sleep(unmapSettleMillis)
    finally:
      memory.release()

    sleep(cadenceMillis * 3)
    stopAmbientSampler()
    let rows = store.readAmbientSamples()

    let emptyRows = inWindows(rows, emptyWindows)
    let fullRows = inWindows(rows, fullWindows)
    check emptyRows.len >= 9
    check fullRows.len >= 9

    # PAIRED, cycle by cycle, for the same reason the CPU arm is: the two
    # windows of one cycle are seconds apart, so a paired difference
    # cancels drift that a pooled comparison across the whole test does
    # not.
    var paired: seq[float] = @[]
    var positive = 0
    for i in 0 ..< memoryCycles:
      let empty = inWindows(rows, [emptyWindows[i]])
      let full = inWindows(rows, [fullWindows[i]])
      if empty.len == 0 or full.len == 0:
        continue
      let delta = median(foreignRss(full)) - median(foreignRss(empty))
      paired.add(delta)
      if delta > float(knownBytes) * 0.3:
        positive += 1
    check paired.len >= memoryCycles - 2

    let measured = median(paired)
    echo "  m11 mem: measured=", (measured / 1e9).formatFloat(ffDecimal, 3),
      "GB known=", (float(knownBytes) / 1e9).formatFloat(ffDecimal, 3),
      "GB ratio=", (measured / float(knownBytes)).formatFloat(ffDecimal, 3),
      " cycles=", positive, "/", paired.len, " above 0.3x",
      " samples=", emptyRows.len, "/", fullRows.len
    # Wider than the CPU arm on purpose: the host-wide figure counts the
    # page cache and every other process's pages in the same number, so
    # this is a tracking claim and not a measurement of the allocation.
    check measured > float(knownBytes) * 0.5
    check measured < float(knownBytes) * 1.8
    # And a majority of cycles saw the allocation on their own, so the
    # median is a median of agreement rather than of two outliers either
    # side of it. For a sampler reporting a constant this is zero.
    check float(positive) / float(paired.len) >= rankMajority

    # Nothing was attributed to RunQuota: no client reported anything, so
    # the whole of the machine's resident memory is foreign.
    for row in fullRows:
      check row.selfRssBytes == 0
      check row.foreignRssBytes > 0

  test "self is what admitted executions reported, foreign is the rest":
    # The gate's "alongside a known set of RunQuota-admitted executions".
    # The leases are real, granted by a real daemon over a real socket;
    # the figures attached to them are DECLARED, which is exactly how a
    # client reports its own execution and exactly what makes the
    # assertion falsifiable: no measurement produces 7.5 and 2.25.
    let dir = scratchDir("self")
    defer: removeDir(dir)
    let socketPath = dir / "d.sock"
    let daemonBinary = getCurrentDir() / "build" / "bin" / "runquotad"
    check fileExists(daemonBinary)
    putEnv("RUNQUOTA_SOCKET", socketPath)

    stopAmbientSampler()
    clearSelfReportedExecutions()

    # The daemon here is a lease authority only: its own observation store
    # is deliberately not enabled, so the sampler in this process is the
    # only writer and the rows are unambiguous.
    let daemon = startProcess(daemonBinary,
      args = ["--socket", socketPath, "--cpu-milli", "64000",
              "--memory-bytes", "68719476736"],
      options = {poStdErrToStdOut})
    var load = LoadGenerator()
    try:
      # Readiness is a successful CONNECT, not the presence of the socket
      # file: `fileExists` tests for a REGULAR file and a Unix-domain
      # socket is not one, so a check written that way is false forever
      # and waits out its whole timeout while the daemon is already
      # serving.
      var ready = false
      for _ in 0 ..< 200:
        try:
          var probe = connectDefault()
          probe.close()
          ready = true
          break
        except CatchableError:
          sleep(25)
      check ready

      let (store, _) = openSampledStore(dir, cadenceMillis)

      var client = connectDefault()
      var session = client.registerSession("m11-ambient", "0.1.0")
      const declared = [
        (cpu: 7.5, rss: 3_000_000_000'i64),
        (cpu: 2.25, rss: 1_000_000_000'i64),
        (cpu: 0.25, rss: 500_000_000'i64)]
      const declaredCpu = 7.5 + 2.25 + 0.25
      const declaredRss = 4_500_000_000'i64

      var leases: seq[RunQuotaLease] = @[]
      for i, figures in declared:
        var lease = session.requestLease(resourceRequest(
          "m11-exec-" & $i, milliCpu(1000),
          bytes(256'u64 * 1024'u64 * 1024'u64)))
        check lease.active
        # Admitted by RunQuota, and now reporting its own figures -- the
        # same intake the socket will feed in M13.
        reportSelfExecution("lease-" & $lease.id.value, figures.cpu,
          figures.rss)
        leases.add(lease)
      check leases.len == declared.len
      check liveSelfReports().len == declared.len

      # Under a real load, in this very process. A sampler that inspected
      # the process tree it runs in would fold the spinners' CPU into
      # `self`; the assertions below pin `self` to the declared sum to the
      # bit, so it cannot.
      let cores = max(1, cpuinfo.countProcessors())
      let busyNow = hostBusyPct()
      check busyNow >= 0.0
      load = startLoad(spinnersForHeadroom(busyNow, cores))
      load.burn(true)
      sleep(settleMillis)
      let reporting = observe(2500)
      # The load really is larger than everything the admitted executions
      # declared, so `self` staying at the declared figure is a statement
      # about attribution rather than about there being nothing to
      # attribute.
      check ownCpuPct([reporting]) > declaredCpu

      # Now the clamp, under real conditions rather than constructed ones:
      # one admitted execution reports more CPU and more memory than the
      # whole machine has, which is what a lagging report looks like.
      reportSelfExecution("lease-runaway", 400.0, 512_000_000_000'i64)
      sleep(settleMillis)
      let clamped = observe(2500)
      endSelfReportedExecution("lease-runaway")

      load.stopLoad()
      check not load.running

      for lease in leases.mitems:
        lease.release()
        endSelfReportedExecution("lease-" & $lease.id.value)
      check liveSelfReports().len == 0
      sleep(settleMillis)
      let released = observe(2500)

      session.closeSession()
      client.close()

      sleep(cadenceMillis * 3)
      stopAmbientSampler()
      let rows = store.readAmbientSamples()

      let reportingRows = inWindows(rows, [reporting])
      let clampedRows = inWindows(rows, [clamped])
      let releasedRows = inWindows(rows, [released])
      check reportingRows.len >= 3
      check clampedRows.len >= 3
      check releasedRows.len >= 3

      for row in reportingRows:
        # EXACTLY the declared sum. Not "about", not "at least".
        check row.selfCpuPct == declaredCpu
        check row.selfRssBytes == declaredRss
        # And foreign is the residual of a REAL host total against it, so
        # the subtraction is not vacuous: the machine was busy.
        check row.cpuBusyPct > declaredCpu
        check row.foreignCpuPct == row.cpuBusyPct - declaredCpu
        check row.foreignCpuPct > 0.0
        check row.foreignRssBytes > 0

      for row in clampedRows:
        check row.selfCpuPct == declaredCpu + 400.0
        check row.selfRssBytes == declaredRss + 512_000_000_000'i64
        # Clamped at zero rather than allowed to go negative.
        check row.foreignCpuPct == 0.0
        check row.foreignRssBytes == 0'i64

      for row in releasedRows:
        # The live set emptied with the leases, so the host's whole load is
        # foreign again. Without this, a `self` that never decreased would
        # satisfy the clamp arm forever.
        check row.selfCpuPct == 0.0
        check row.selfRssBytes == 0'i64
        check row.foreignCpuPct == row.cpuBusyPct
        check row.foreignRssBytes > 0
    finally:
      load.stopLoad()
      stopAmbientSampler()
      clearSelfReportedExecutions()
      if daemon.running:
        daemon.terminate()
        discard daemon.waitForExit(5000)
      daemon.close()
    check not load.running

  test "a real daemon samples on a fixed cadence, independent of executions":
    let dir = scratchDir("dmn")
    defer: removeDir(dir)
    let socketPath = dir / "d.sock"
    let dbPath = dir / "observations.sqlite"
    let daemonBinary = getCurrentDir() / "build" / "bin" / "runquotad"
    check fileExists(daemonBinary)
    stopAmbientSampler()

    let daemon = startProcess(daemonBinary,
      args = ["--socket", socketPath, "--observation-db", dbPath,
              "--host-identity-file", dir / "host-id",
              "--ambient-sample-interval-millis", $cadenceMillis],
      options = {poStdErrToStdOut})
    var startupLines: seq[string] = @[]
    var rowsWhileRunning: seq[AmbientSampleRow] = @[]
    try:
      # Exactly the three lines the daemon prints when a store path was
      # given, and then it goes quiet.
      for _ in 0 ..< 3:
        startupLines.add(daemon.outputStream.readLine())
      check startupLines[1].contains("capture enabled")
      check startupLines[2].contains(
        "ambient sampling every " & $cadenceMillis & "ms")

      # NOT ONE CLIENT CONNECTS. The cadence is independent of execution
      # boundaries, so an idle daemon that has never admitted anything must
      # still be describing the machine.
      sleep(3200)
      let store = openObservationStore(dbPath)
      check store.captureEnabled
      rowsWhileRunning = store.readAmbientSamples()
      check store.readExecutions().len == 0
      check store.readRuns().len == 0
    finally:
      if daemon.running:
        daemon.terminate()
        discard daemon.waitForExit(5000)
      daemon.close()

    # Enough rows that the cadence is the cadence and not one flush at
    # shutdown: 2.5 s at 200 ms is twelve ticks, and macOS turns roughly
    # one tick in ten into a stale reading that writes nothing.
    check rowsWhileRunning.len >= 5
    check rowsWhileRunning.len <= 20
    let hostIds = block:
      var ids: seq[string] = @[]
      for row in rowsWhileRunning:
        if row.hostId notin ids:
          ids.add(row.hostId)
      ids
    check hostIds.len == 1
    check isOpaqueId(hostIds[0], "host-")
    check readFile(dir / "host-id").strip() == hostIds[0]

    var previousAt = 0'i64
    var gaps: seq[float] = @[]
    for row in rowsWhileRunning:
      check row.sampledAtUnixMillis > previousAt
      if previousAt > 0:
        gaps.add(float(row.sampledAtUnixMillis - previousAt))
      previousAt = row.sampledAtUnixMillis
      # No client ever reported, so everything the machine did is foreign.
      check row.selfCpuPct == 0.0
      check row.selfRssBytes == 0
      check row.foreignCpuPct == row.cpuBusyPct
      check row.memAvailableBytes > 0
    # A FIXED cadence: the median gap is the configured interval, not a
    # burst at shutdown and not a function of anything the daemon was asked
    # to do.
    check gaps.len >= 4
    let medianGap = median(gaps)
    check medianGap >= float(cadenceMillis) * 0.8
    check medianGap <= float(cadenceMillis) * 2.5

    # And the sampler stopped with the daemon.
    let settled = openObservationStore(dbPath).readAmbientSamples()
    sleep(cadenceMillis * 4)
    check openObservationStore(dbPath).readAmbientSamples().len == settled.len
