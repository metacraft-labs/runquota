## M11 gate, the deterministic half: the attribution arithmetic, the clamp,
## and the boundary that says the daemon may not look at process trees.
##
## No mocks, and nothing here is a stand-in for a measurement: the two
## ``HostLoadReading`` values are *constructed* rather than measured on
## purpose, because the property under test is arithmetic and a property
## checked against whatever the machine happened to be doing is a property
## checked against a moving target. The measured half — that ``foreign_*``
## really tracks a real load on a real machine — is
## ``t_ambient_load_attribution``, and neither file is sufficient alone:
## this one cannot show the sampler reads anything true, and that one
## cannot pin an exact value.
##
## THE CLAMP IS THE POINT OF THE FILE. ``foreign_* = host_total - self_*``
## goes negative whenever a client's report covers a busier window than the
## instant the sample fell in, which is the normal case rather than an
## error. Both arms are asserted: clamped to exactly zero when reports
## exceed the host total, and strictly positive and exactly equal to the
## difference when they do not — because a "clamp" implemented as "always
## zero" satisfies the first arm and destroys the column.
##
## The boundary check at the end is a source-inspection test. It is pinned
## to the sentence in ``runquota/CLAUDE.md`` it enforces, so deleting the
## boundary from the policy file fails the test rather than quietly
## retiring it, and it carries a positive control: the same scanner is run
## over the client-side helper that DOES walk process trees and must find
## it there. A scanner that finds nothing anywhere agrees with every
## implementation.

import std/[algorithm, options, os, strutils, unittest]

import runquota_observation_store

const
  # Fifty-eight lines apart from the store, so that a change to either
  # file's location is a compile-time problem rather than a silently
  # skipped test.
  repoRoot = currentSourcePath().parentDir.parentDir.parentDir
  ambientSource =
    repoRoot / "libs" / "runquota_observation_store" / "src" /
    "runquota_observation_store" / "ambient.nim"
  daemonSource =
    repoRoot / "libs" / "runquota_daemon" / "src" / "runquota_daemon.nim"
  macosTreeSource =
    repoRoot / "libs" / "runquota_host_macos" / "src" / "runquota_host_macos" /
    "process_telemetry.nim"
  linuxTreeSource =
    repoRoot / "libs" / "runquota_host_linux" / "src" / "runquota_host_linux.nim"
  boundaryFile = repoRoot / "CLAUDE.md"

  readerStamp = "result.atUnixMillis = unixMillisNow()"
    ## The ONLY way a reading's instant may be set: a platform reader
    ## stamping the moment it read the kernel. Pinned as an exact line
    ## rather than as a pattern, because the check that uses it counts
    ## occurrences of this spelling against assignments of the field, and
    ## a looser pattern would let a second spelling in.

  perProcessInterfaces = [
    # Every documented way of asking an operating system about a PROCESS
    # rather than about the MACHINE. None of these may appear anywhere in
    # the sampler or on the daemon's sampling path.
    "proc_listpids", "proc_pidinfo", "proc_listchildpids", "proc_pid_rusage",
    "libproc.h", "sys/proc_info.h", "kinfo_proc", "KERN_PROC",
    "task_for_pid", "ProcessTreeTelemetry", "processTreeRows",
    "readProcessRow", "readChildProcessIds", "/proc/self"]

  # The ONLY `/proc` files the sampler may name. Every one of them is a
  # host-wide aggregate; a per-process path (`/proc/<pid>/stat`) is not on
  # the list and cannot be added by accident.
  allowedProcPaths = [
    "/proc/stat", "/proc/meminfo", "/proc/vmstat", "/proc/loadavg",
    "/proc/diskstats"]

proc scratchDir(name: string): string =
  result = getTempDir() / ("runquota-m11u-" & name & "-" &
    $getCurrentProcessId())
  removeDir(result)
  createDir(result)

proc reading(atMillis, busyMillis, totalMillis, memTotal, memAvailable,
             swapIn: int64; loadAvg = 1.0; ioQueue = ioQueueDepthUnmeasured):
    HostLoadReading =
  HostLoadReading(
    available: true, source: "constructed", detail: "",
    atUnixMillis: atMillis, cpuBusyMillis: busyMillis,
    cpuTotalMillis: totalMillis, memTotalBytes: memTotal,
    memAvailableBytes: memAvailable, swapInPages: swapIn,
    loadAvg1m: loadAvg, ioQueueDepth: ioQueue)

const
  gib = 1024'i64 * 1024'i64 * 1024'i64
  # A machine with 64 GiB, 40 GiB of it available, so 24 GiB is in use.
  memTotal = 64'i64 * gib
  memAvailable = 40'i64 * gib
  memUsed = 24'i64 * gib

proc pair(busyDeltaMillis, totalDeltaMillis: int64;
          swapDelta = 0'i64; elapsedMillis = 1000'i64):
    tuple[previous, current: HostLoadReading] =
  let previous = reading(1_700_000_000_000'i64, 900_000, 8_000_000, memTotal,
    memAvailable, 4242)
  let current = reading(previous.atUnixMillis + elapsedMillis,
    previous.cpuBusyMillis + busyDeltaMillis,
    previous.cpuTotalMillis + totalDeltaMillis, memTotal, memAvailable,
    previous.swapInPages + swapDelta)
  (previous, current)

# ---------------------------------------------------------------------------
# The measured arm's ESTIMATOR, over readings that are scripted
# ---------------------------------------------------------------------------
#
# `t_ambient_load_attribution` burns real CPU, touches real pages, and asks
# whether `foreign_*` followed. What it can never say is BY HOW MUCH: the
# machine's own background moves while it measures, so its answer comes back
# as a ratio inside a band, and the band has to stay wide enough for a host
# somebody else is also using.
#
# Everything that arm asserts about TRACKING is asserted here instead,
# against constructed readings, and every answer below is an EQUALITY. What
# is left over there is the one claim no constructed reading can make: that
# a real kernel counter moves when a real load runs.

const
  capacityMillis = 8_000_000'i64
    ## Elapsed CPU capacity across the sampled interval, summed over every
    ## logical core. It divides by 100 exactly, so "n percent busy" is a
    ## whole number of milliseconds and `100 * busy / total` comes back as
    ## exactly `n` in IEEE arithmetic rather than near it -- which is what
    ## lets the assertions be equalities instead of tolerances.
  onePercentMillis = capacityMillis div 100

proc rowAtBusy(busyPct: int; reports: openArray[SelfReport] = []):
    AmbientSampleRow =
  ## One written sample from a machine that was exactly ``busyPct`` percent
  ## busy over the interval it covers.
  let (previous, current) = pair(int64(busyPct) * onePercentMillis,
    capacityMillis)
  attributeAmbientSample("host-a", previous, current, reports)

proc rowAtAvailable(availableBytes: int64;
                    reports: openArray[SelfReport] = []): AmbientSampleRow =
  ## One written sample from a machine with exactly ``availableBytes`` free.
  let previous = reading(1_700_000_000_000'i64, 900_000, 8_000_000, memTotal,
    availableBytes, 4242)
  let current = reading(previous.atUnixMillis + 1000,
    previous.cpuBusyMillis + 40 * onePercentMillis,
    previous.cpuTotalMillis + capacityMillis, memTotal, availableBytes,
    previous.swapInPages)
  attributeAmbientSample("host-a", previous, current, reports)

proc median(values: seq[float]): float =
  ## The same statistic the measured arm forms, so what is pinned here is
  ## that estimator and not a different one that happens to agree.
  var sorted = values
  sorted.sort()
  if sorted.len == 0: 0.0
  elif sorted.len mod 2 == 1: sorted[sorted.len div 2]
  else: (sorted[sorted.len div 2 - 1] + sorted[sorted.len div 2]) / 2.0

proc foreignCpu(rows: seq[AmbientSampleRow]): seq[float] =
  for row in rows:
    result.add(row.foreignCpuPct)

type Estimate = object
  ## What the measured arm computes from a run of ON/OFF cycles.
  paired: float
    ## The median over cycles of that cycle's own (ON median - OFF median).
  pooled: float
    ## Every ON sample against every OFF sample, ignoring which cycle each
    ## came from.
  carrying: int
    ## Cycles whose own pair carried more than 0.3x the known load.
  cycles: int

proc estimate(offWindows, onWindows: seq[seq[AmbientSampleRow]];
              known: float): Estimate =
  var deltas: seq[float] = @[]
  var pooledOff: seq[float] = @[]
  var pooledOn: seq[float] = @[]
  for cycle in 0 ..< offWindows.len:
    let delta = median(foreignCpu(onWindows[cycle])) -
      median(foreignCpu(offWindows[cycle]))
    deltas.add(delta)
    if delta > known * 0.3:
      result.carrying += 1
    pooledOff.add(foreignCpu(offWindows[cycle]))
    pooledOn.add(foreignCpu(onWindows[cycle]))
  result.paired = median(deltas)
  result.pooled = median(pooledOn) - median(pooledOff)
  result.cycles = deltas.len

proc scannedFor(path: string; tokens: openArray[string]): seq[string] =
  let text = readFile(path)
  for token in tokens:
    if token in text:
      result.add(token)

proc assignmentsTo(text, field: string): int =
  ## How many times ``field`` appears on the LEFT of an assignment.
  ##
  ## Written as a scan rather than as a substring test because
  ## ``x.field ==`` contains ``x.field =`` and a naive test would call a
  ## comparison an assignment. ``=``, ``+=`` and ``-=`` all count; ``==``
  ## does not.
  var index = 0
  while true:
    let hit = text.find(field, index)
    if hit < 0:
      break
    var cursor = hit + field.len
    index = cursor
    while cursor < text.len and text[cursor] == ' ':
      cursor += 1
    if cursor >= text.len:
      break
    if text[cursor] in {'+', '-'} and cursor + 1 < text.len and
        text[cursor + 1] == '=':
      result += 1
    elif text[cursor] == '=' and
        (cursor + 1 >= text.len or text[cursor + 1] != '='):
      result += 1

suite "observation_store_ambient_attribution":

  test "a rate needs two readings that actually moved":
    # macOS updates the mach CPU tick counters on its own schedule. A
    # byte-identical snapshot divided by itself is 0.0, and 0.0 in
    # `cpu_busy_pct` does not read as "no measurement" — it reads as an
    # idle machine, which is a lie a reader will average.
    let base = reading(1000, 500_000, 4_000_000, memTotal, memAvailable, 10)
    check classifyReadings(base, base) == rpStale

    var advanced = base
    advanced.atUnixMillis += 1000
    advanced.cpuTotalMillis += 16_000
    advanced.cpuBusyMillis += 2_000
    check classifyReadings(base, advanced) == rpAdvanced

    # The clock moved but the counters did not: still no measurement.
    var onlyClock = base
    onlyClock.atUnixMillis += 1000
    check classifyReadings(base, onlyClock) == rpStale

    # Backwards in any dimension is a wrap or a reset, never a rate. Each
    # field is walked back BELOW the baseline, which is what a 32-bit
    # ``natural_t`` tick counter does about once a month per state on a
    # sixteen-core machine.
    for mutate in [
        proc (r: var HostLoadReading) = r.cpuTotalMillis = base.cpuTotalMillis - 1,
        proc (r: var HostLoadReading) = r.cpuBusyMillis = base.cpuBusyMillis - 1,
        proc (r: var HostLoadReading) = r.swapInPages = base.swapInPages - 1,
        proc (r: var HostLoadReading) = r.atUnixMillis = base.atUnixMillis - 1]:
      var broken = advanced
      mutate(broken)
      check classifyReadings(base, broken) == rpDiscontinuous
      # And the same field left alone still classifies as a measurement,
      # so the four assertions above are about the mutation rather than
      # about `advanced` having been broken some other way.
      check classifyReadings(base, advanced) == rpAdvanced

    # Busy time cannot exceed elapsed capacity; if it does, the two
    # counters came from different epochs.
    var impossible = base
    impossible.atUnixMillis += 1000
    impossible.cpuTotalMillis += 1_000
    impossible.cpuBusyMillis += 2_000
    check classifyReadings(base, impossible) == rpDiscontinuous

  test "cpu_busy_pct is busy CPU time over elapsed capacity":
    # Percent of the WHOLE MACHINE, not of one core: 1_000_000 ms of busy
    # CPU time inside 8_000_000 ms of elapsed sixteen-core capacity is
    # 12.5%, whatever the wall clock says. Wall time and CPU time are not
    # interchangeable and the denominator is the one that says which is
    # meant.
    let (previous, current) = pair(1_000_000, 8_000_000)
    let row = attributeAmbientSample("host-a", previous, current, [])
    check row.cpuBusyPct == 12.5
    check row.hostId == "host-a"
    check row.sampledAtUnixMillis == current.atUnixMillis
    check row.memAvailableBytes == memAvailable

    # And the wall clock does NOT enter it: the same counters over a
    # tenfold longer wall interval describe the same fraction.
    let (p2, c2) = pair(1_000_000, 8_000_000, elapsedMillis = 10_000)
    check attributeAmbientSample("host-a", p2, c2, []).cpuBusyPct == 12.5

  test "swap_in_rate is pages per second over the sampled interval":
    let (previous, current) = pair(1_000_000, 8_000_000, swapDelta = 512,
      elapsedMillis = 2000)
    check attributeAmbientSample("host-a", previous, current, []).swapInRate ==
      256.0
    let (p2, c2) = pair(1_000_000, 8_000_000, swapDelta = 0)
    check attributeAmbientSample("host-a", p2, c2, []).swapInRate == 0.0

  test "self is exactly what clients reported, and nothing else":
    # THE LOAD-BEARING ASSERTION AGAINST PROCESS-TREE INSPECTION. The
    # daemon is a lease authority; it does not measure client processes.
    # `self_*` is therefore the arithmetic sum of what clients said about
    # themselves, to the last bit, and any contribution derived from
    # anywhere else — a measured process tree, a lease reservation, a
    # learned estimate — changes a number pinned here. The figures are
    # deliberately awkward: no measurement produces 3.25 and 0.75.
    let reports = [
      SelfReport(executionId: "exec-a", cpuPct: 12.5, rssBytes: 3 * gib),
      SelfReport(executionId: "exec-b", cpuPct: 3.25, rssBytes: 1 * gib),
      SelfReport(executionId: "exec-c", cpuPct: 0.75, rssBytes: 512 * 1024 * 1024)]
    let (previous, current) = pair(3_200_000, 8_000_000)         # 40% busy
    let row = attributeAmbientSample("host-a", previous, current, reports)

    check row.cpuBusyPct == 40.0
    check row.selfCpuPct == 16.5
    check row.selfRssBytes == 4 * gib + 512 * 1024 * 1024
    check sumSelfCpuPct(reports) == row.selfCpuPct
    check sumSelfRssBytes(reports) == row.selfRssBytes

    # Foreign is the residual, exactly.
    check row.foreignCpuPct == 40.0 - 16.5
    check row.foreignRssBytes == memUsed - row.selfRssBytes
    check row.foreignCpuPct > 0.0
    check row.foreignRssBytes > 0

    # An unreported execution lands in FOREIGN rather than being invented
    # into self. That is the correct failure direction for a lease
    # authority: it understates its own share rather than claiming a
    # measurement it did not make.
    let withoutC = attributeAmbientSample("host-a", previous, current,
      reports[0 .. 1])
    check withoutC.selfCpuPct == 15.75
    check withoutC.foreignCpuPct == row.foreignCpuPct + 0.75
    check withoutC.foreignRssBytes ==
      row.foreignRssBytes + 512 * 1024 * 1024

  test "foreign is CLAMPED AT ZERO when client reporting lags sampling":
    let (previous, current) = pair(800_000, 8_000_000)         # 10% busy
                                                               # A client whose report covers a window busier than the instant the
                                                               # sample fell in. This is lag, not error: reports describe intervals
                                                               # and samples describe instants.
    let overshooting = [
      SelfReport(executionId: "exec-a", cpuPct: 55.0, rssBytes: 20 * gib),
      SelfReport(executionId: "exec-b", cpuPct: 20.0, rssBytes: 40 * gib)]
    let row = attributeAmbientSample("host-a", previous, current, overshooting)

    check row.cpuBusyPct == 10.0
    check row.selfCpuPct == 75.0
    check row.selfRssBytes == 60 * gib
    # Exactly zero, not merely non-negative: a residual that ran to -65.0
    # and was reported as -65.0 would also satisfy ">= -100".
    check row.foreignCpuPct == 0.0
    check row.foreignRssBytes == 0'i64
    check row.foreignCpuPct >= 0.0
    check row.foreignRssBytes >= 0'i64

    # THE POSITIVE CONTROL. "Clamped at zero" implemented as "always zero"
    # passes every assertion above and destroys the column. One percentage
    # point of headroom, and one byte of it, must survive.
    let barelyUnder = [
      SelfReport(executionId: "exec-a", cpuPct: 9.0,
        rssBytes: memUsed - 1)]
    let edge = attributeAmbientSample("host-a", previous, current, barelyUnder)
    check edge.foreignCpuPct == 1.0
    check edge.foreignCpuPct > 0.0
    check edge.foreignRssBytes == 1'i64

    # And the clamp agrees with the database rather than merely preceding
    # it: the schema refuses a negative, so an unclamped value would be
    # rejected on write and the sample lost entirely.
    let dir = scratchDir("clamp")
    defer: removeDir(dir)
    let store = openObservationStore(dir / "observations.sqlite")
    check store.captureEnabled
    let hostId = resolveHostIdentity(dir / "host-id").hostId
    check store.ensureHostRow(hostId, "boot-0")
    var stored = row
    stored.hostId = hostId
    check store.insertAmbientSample(stored)
    let readBack = store.readAmbientSamples()
    check readBack.len == 1
    check readBack[0].foreignCpuPct == 0.0
    check readBack[0].foreignRssBytes == 0'i64
    check readBack[0].selfCpuPct == 75.0
    check readBack[0].cpuBusyPct == 10.0

    var negative = stored
    negative.foreignCpuPct = -0.5
    check not store.insertAmbientSample(negative)
    negative = stored
    negative.sampledAtUnixMillis += 1
    negative.foreignRssBytes = -1
    check not store.insertAmbientSample(negative)
    check store.readAmbientSamples().len == 1

  test "a known load lands in foreign_cpu_pct point for point":
    # THE MEASURED ARM'S TRACKING CLAIM, STATED AS ARITHMETIC. Over there
    # the load is real CPU and the answer is a ratio inside a band, because
    # the background wanders underneath the measurement. Here the
    # background is held still and the answer is an equality: a load of
    # exactly twenty-five points moves the column by exactly twenty-five
    # points, and the ratio is exactly one.
    const known = 25
    for background in [0, 12, 40, 60, 74]:
      let off = rowAtBusy(background)
      let on = rowAtBusy(background + known)
      check off.cpuBusyPct == float(background)
      check on.cpuBusyPct == float(background + known)
      check off.foreignCpuPct == float(background)
      check on.foreignCpuPct == float(background + known)
      # The quantity the measured arm actually reads, and its ratio.
      check on.foreignCpuPct - off.foreignCpuPct == float(known)
      check (on.foreignCpuPct - off.foreignCpuPct) / float(known) == 1.0

    # AND IT SURVIVES A CLIENT REPORTING ITS OWN EXECUTION. `self_*` is
    # subtracted from both sides of the difference, so what a client said
    # about itself changes the level and cannot change the tracking. A
    # sampler that let a report leak into only one side would fail here.
    let reports = [SelfReport(executionId: "exec-a", cpuPct: 5.0, rssBytes: 0)]
    check rowAtBusy(40, reports).foreignCpuPct == 35.0
    check rowAtBusy(40 + known, reports).foreignCpuPct == 60.0
    check rowAtBusy(40 + known, reports).foreignCpuPct -
      rowAtBusy(40, reports).foreignCpuPct == float(known)

  test "the ON/OFF estimator recovers a known load from a drifting host":
    # THE ESTIMATOR ITSELF, on scripted samples. The measured arm toggles a
    # load fourteen times and reduces the rows to one number; that
    # reduction is asserted here against a machine whose own background
    # RAMPS a point a cycle underneath it -- thirteen points end to end,
    # which is the order of drift that arm's header records on a real
    # workstation. Both the paired estimator and the pooled one come back
    # with the load exactly, and every cycle carries it.
    const
      cycles = 14
      samplesPerWindow = 3
      known = 25
      baseBackground = 20

    proc script(loadPoints: int): tuple[off, on: seq[seq[AmbientSampleRow]]] =
      for cycle in 0 ..< cycles:
        let background = baseBackground + cycle
        var offWindow: seq[AmbientSampleRow] = @[]
        var onWindow: seq[AmbientSampleRow] = @[]
        for _ in 0 ..< samplesPerWindow:
          offWindow.add(rowAtBusy(background))
          onWindow.add(rowAtBusy(background + loadPoints))
        result.off.add(offWindow)
        result.on.add(onWindow)

    let tracked = script(known)
    let measured = estimate(tracked.off, tracked.on, float(known))
    check measured.cycles == cycles
    check measured.paired == float(known)
    check measured.paired / float(known) == 1.0
    check measured.pooled == float(known)
    check measured.pooled / float(known) == 1.0
    check measured.carrying == cycles

    # A SAMPLER THAT REPORTS A CONSTANT. This is the shape a real
    # regression takes -- a column that no longer moves with the machine --
    # and it is the reason the measured arm's assertion is a DIFFERENCE
    # rather than a level: every estimator reads zero, not "about right".
    var flatOff: seq[seq[AmbientSampleRow]] = @[]
    var flatOn: seq[seq[AmbientSampleRow]] = @[]
    for cycle in 0 ..< cycles:
      var window: seq[AmbientSampleRow] = @[]
      for _ in 0 ..< samplesPerWindow:
        window.add(rowAtBusy(50))
      flatOff.add(window)
      flatOn.add(window)
    let flat = estimate(flatOff, flatOn, float(known))
    check flat.paired == 0.0
    check flat.paired / float(known) == 0.0
    check flat.pooled == 0.0
    check flat.carrying == 0

    # AND A SAMPLER THAT UNDER-REPORTS BY A FIFTH. It tracks, so it is not
    # caught by "the column moved"; it lands at 0.80, which is inside every
    # band the measured arm can afford to state and inside the ratio
    # majority as well. Only an equality catches it, and only a
    # deterministic test can assert an equality.
    let short = script(known * 4 div 5)
    let shortMeasured = estimate(short.off, short.on, float(known))
    check shortMeasured.paired / float(known) == 0.8
    check shortMeasured.carrying == cycles
    check shortMeasured.paired != float(known)

  test "a known allocation lands in foreign_rss_bytes byte for byte":
    # The memory arm's tracking claim, as arithmetic. `foreign_rss_bytes`
    # is `mem_total - mem_available - self_rss`, so an allocation of
    # exactly four gibibytes shows up as exactly four gibibytes whatever
    # else the machine is holding.
    const known = 4'i64 * gib
    for available in [40'i64 * gib, 32'i64 * gib, 8'i64 * gib]:
      let empty = rowAtAvailable(available)
      let full = rowAtAvailable(available - known)
      check empty.foreignRssBytes == memTotal - available
      check full.foreignRssBytes == memTotal - available + known
      check full.foreignRssBytes - empty.foreignRssBytes == known

    # What a client reported about itself moves the level and not the
    # tracking, exactly as on the CPU side.
    let reports = [SelfReport(executionId: "exec-a", cpuPct: 0.0,
      rssBytes: 6 * gib)]
    let empty = rowAtAvailable(40 * gib, reports)
    let full = rowAtAvailable(40 * gib - known, reports)
    check empty.foreignRssBytes == memTotal - 40 * gib - 6 * gib
    check full.foreignRssBytes - empty.foreignRssBytes == known

    # AND UNDER DRIFT. The memory arm's own header records a Time Machine
    # pass releasing 3.4 GB inside one measurement; here the machine's
    # resident set walks a gibibyte a cycle underneath nine cycles and the
    # paired median is still the allocation, to the byte.
    var paired: seq[float] = @[]
    var carrying = 0
    for cycle in 0 ..< 9:
      let base = 40'i64 * gib - int64(cycle) * gib
      let delta = float(rowAtAvailable(base - known).foreignRssBytes) -
        float(rowAtAvailable(base).foreignRssBytes)
      paired.add(delta)
      if delta > float(known) * 0.3:
        carrying += 1
    check paired.len == 9
    check median(paired) == float(known)
    check median(paired) / float(known) == 1.0
    check carrying == 9

    # The constant sampler again, on this column. A `mem_available` that
    # never moves reads as an allocation nobody made.
    var flat: seq[float] = @[]
    for _ in 0 ..< 9:
      flat.add(float(rowAtAvailable(40 * gib).foreignRssBytes) -
        float(rowAtAvailable(40 * gib).foreignRssBytes))
    check median(flat) == 0.0

  test "the live self-report set is a set, and it empties":
    # `self_*` is the sum over CONCURRENTLY LIVE executions. A client
    # reporting twice must not double its own weight, and a finished
    # execution must leave, or `self` grows without bound and drives
    # `foreign` permanently to the clamp.
    clearSelfReportedExecutions()
    check liveSelfReports().len == 0

    reportSelfExecution("exec-a", 10.0, 1000)
    reportSelfExecution("exec-b", 4.0, 2000)
    check liveSelfReports().len == 2
    check sumSelfCpuPct(liveSelfReports()) == 14.0
    check sumSelfRssBytes(liveSelfReports()) == 3000

    reportSelfExecution("exec-a", 25.0, 7000)
    check liveSelfReports().len == 2
    check sumSelfCpuPct(liveSelfReports()) == 29.0
    check sumSelfRssBytes(liveSelfReports()) == 9000

    endSelfReportedExecution("exec-a")
    check liveSelfReports().len == 1
    check sumSelfCpuPct(liveSelfReports()) == 4.0
    endSelfReportedExecution("exec-does-not-exist")
    check liveSelfReports().len == 1
    endSelfReportedExecution("exec-b")
    check liveSelfReports().len == 0
    check sumSelfCpuPct(liveSelfReports()) == 0.0

  test "a sample whose millisecond is taken is DROPPED, never re-timed":
    # `(host_id, sampled_at_unix_millis)` is the primary key. Two samples
    # inside one millisecond collide, and the only two things an
    # implementation can do with the loser are to drop it or to move its
    # timestamp. Moving it writes an instant at which no reading was taken
    # -- a fabricated value presented as an observation, which OS-2
    # forbids -- so it is dropped and counted, exactly as this module
    # already treats a stale pair and a discontinuous one.
    check ambientSampleFollows(1_700_000_000_000'i64, 1_700_000_000_001'i64)
    check not ambientSampleFollows(1_700_000_000_000'i64,
      1_700_000_000_000'i64)
    check not ambientSampleFollows(1_700_000_000_000'i64,
      1_699_999_999_999'i64)

    # The counter is on the same surface as the other two refusals, and a
    # sampler that has taken no colliding sample reads zero rather than
    # not being readable at all.
    stopAmbientSampler()
    startAmbientSampler("", "host-x")
    check ambientSamplesCollided() == 0
    stopAmbientSampler()

    # THE ASSERTION THAT FAILS AGAINST A RE-TIMING SAMPLER, and the reason
    # it is an inspection gate: the collision path is unreachable at any
    # sane cadence, so no run of the sampler can distinguish "drops" from
    # "re-times" -- which is exactly how a fabricated timestamp got shipped
    # as a deferral. What CAN be checked is that no code path in the
    # sampler assigns a sample's instant at all: every `sampled_at` in the
    # store is the `atUnixMillis` of a reading that was actually taken.
    check fileExists(ambientSource)
    let ambientText = readFile(ambientSource)
    check assignmentsTo(ambientText, "sampledAtUnixMillis") == 0
    # And `sampled_at` is populated ONLY by construction from a reading,
    # so the zero above is not zero because the field went missing.
    check "sampledAtUnixMillis: current.atUnixMillis" in ambientText

    # THE HOLE THE TWO CHECKS ABOVE LEAVE, CLOSED. Between them they say
    # the SAMPLE's instant is never assigned and is built from a reading's
    # own `atUnixMillis`. An implementation that wanted a fabricated
    # timestamp anyway has an obvious route left: move the READING's
    # instant instead -- `current.atUnixMillis = <anything>` before the row
    # is constructed -- and both checks above stay green while every
    # `sampled_at` in the store becomes a moment at which nothing was read.
    #
    # It closes with the same shape of statement one level up. There is
    # exactly one thing in this module allowed to set a reading's instant:
    # a reader, stamping the moment it read, on the line below. So the
    # number of assignments to `atUnixMillis` anywhere in the file must be
    # the number of times that exact line appears, and no other spelling
    # can be added without the counts diverging.
    check assignmentsTo(ambientText, "atUnixMillis") ==
      ambientText.count(readerStamp)
    # ... and the equality is not satisfied by there being none of either:
    # the macOS reader carries one and the Linux reader carries one.
    check ambientText.count(readerStamp) >= 2
    # `atUnixMillis` is not a substring of `sampledAtUnixMillis` -- the
    # capital A sees to that -- so the count above is about readings and
    # the count above that is about rows, and neither absorbs the other.
    check "atUnixMillis" notin "sampledAtUnixMillis"

    # THE POSITIVE CONTROL. The same scanner, over a file that really does
    # assign the field -- this one: the clamp test moves a row's instant on
    # purpose to get a second primary key -- must find it. A scanner that
    # finds nothing anywhere agrees with every implementation.
    let selfText = readFile(currentSourcePath())
    check assignmentsTo(selfText, "sampledAtUnixMillis") >= 1
    # ... and it does not mistake this file's comparisons for assignments.
    check "check row.sampledAtUnixMillis == current.atUnixMillis" in selfText

  test "the live-lease count the sampler is gated on starts at zero":
    # The daemon publishes this from the aggregate it already maintains.
    # It starts at zero and a sampler that has never been told about a
    # lease writes nothing, which is what bounds ambient growth by build
    # activity instead of by wall-clock time. The two-directional
    # behavioural gate is `t_ambient_load_attribution`; what is pinned
    # here is that the default is "no work is live" rather than "assume
    # some is".
    stopAmbientSampler()
    startAmbientSampler("", "host-x")
    check ambientLiveLeaseCount() == 0
    check ambientTicksWithoutLease() == 0

    setAmbientLiveLeaseCount(3)
    check ambientLiveLeaseCount() == 3
    setAmbientLiveLeaseCount(0)
    check ambientLiveLeaseCount() == 0
    # A count can never go negative: the daemon decrements a `uint32` it
    # guards, but a gate that could be armed by an arithmetic slip is not
    # a gate.
    setAmbientLiveLeaseCount(-4)
    check ambientLiveLeaseCount() == 0
    stopAmbientSampler()

  test "an unusable store or host leaves the sampler inactive":
    # OS-4 on this path too: ambient sampling is capture, and capture that
    # cannot run must not fail anything.
    stopAmbientSampler()
    startAmbientSampler("", "host-x")
    check not ambientSamplerActive()
    startAmbientSampler(getTempDir() / "nowhere.sqlite", "")
    check not ambientSamplerActive()
    stopAmbientSampler()

  test "io_queue_depth says 'not measured' rather than 'nothing queued'":
    # 0.0 is a legitimate measurement — an idle disk — so a platform with
    # no host-wide in-flight counter must not report it.
    check ioQueueDepthUnmeasured < 0.0
    let (previous, current) = pair(1_000_000, 8_000_000)
    check attributeAmbientSample("host-a", previous, current, [
        ]).ioQueueDepth ==
      ioQueueDepthUnmeasured
    var measured = current
    measured.ioQueueDepth = 0.0
    check attributeAmbientSample("host-a", previous, measured, [
        ]).ioQueueDepth ==
      0.0

  test "the daemon's sampling path performs no process-tree inspection":
    # The boundary this enforces, quoted from the policy file it lives in.
    # Pinning the sentence means deleting the boundary fails the test
    # rather than quietly retiring it.
    let boundary = readFile(boundaryFile)
    check "must not spawn, sandbox, monitor, or kill" in boundary
    check "client process trees" in boundary
    check "runquotad" in boundary

    check fileExists(ambientSource)
    check fileExists(daemonSource)
    check scannedFor(ambientSource, perProcessInterfaces).len == 0
    check scannedFor(daemonSource, perProcessInterfaces).len == 0

    # The sampler may name `/proc`, because `/proc/stat` and `/proc/meminfo`
    # describe the machine. It may not name a process's own directory, and
    # an allow-list is what makes that structural: `/proc/self/stat` and
    # `/proc/<pid>/stat` both fail it.
    let ambientText = readFile(ambientSource)
    var index = 0
    var procPaths = 0
    while true:
      let hit = ambientText.find("/proc/", index)
      if hit < 0:
        break
      var stop = hit + "/proc/".len
      while stop < ambientText.len and
          ambientText[stop] notin {'"', '\'', '`', ' ', '\n', ')', ','}:
        stop += 1
      let path = ambientText[hit ..< stop]
      check path in allowedProcPaths
      procPaths += 1
      index = stop
    # The Linux branch really does name some, so the loop above is not
    # vacuously satisfied by finding nothing.
    check procPaths >= 5

    # THE POSITIVE CONTROL. The same scanner, run over the client-side
    # helpers that DO walk process trees, must find them. Without this, a
    # scanner looking for tokens that no longer exist anywhere would agree
    # with a daemon that walked every process on the machine.
    check fileExists(macosTreeSource)
    check fileExists(linuxTreeSource)
    let macosHits = scannedFor(macosTreeSource, perProcessInterfaces)
    check macosHits.len >= 3
    check "proc_listpids" in macosHits
    check "proc_pidinfo" in macosHits
    let linuxHits = scannedFor(linuxTreeSource, perProcessInterfaces)
    check linuxHits.len >= 2
    check "processTreeRows" in linuxHits
