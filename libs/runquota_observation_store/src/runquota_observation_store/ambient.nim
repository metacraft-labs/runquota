## Ambient load sampling with self/foreign attribution (M11, OS-6).
##
## Normative specification:
## ``reprobuild-specs/RunQuota-Observation-Store.md`` §"`ambient_samples`".
##
## THE DESIGN CONSTRAINT. ``runquota/CLAUDE.md`` says ``runquotad`` "is a
## lease authority. It must not spawn, sandbox, monitor, or kill client
## process trees." Attribution here is therefore **by difference** and
## never by inspection:
##
## * the daemon reads **host-wide totals only** — one kernel counter set
##   per sample, describing the machine and no process on it;
## * clients report their own executions' figures, exactly as they already
##   do for learned estimates;
## * ``self_*`` is the sum over concurrently live client-reported
##   executions and ``foreign_* = host_total - self_*``.
##
## Nothing in this module names a process id, enumerates processes, or
## reads a per-process interface. ``t_observation_store_ambient_boundary``
## asserts that against the source, and the arithmetic below makes it
## observable: ``self_*`` is *exactly* the sum of what was reported, so a
## contribution derived from anything else changes a value the tests pin.
##
## THE RESIDUAL IS APPROXIMATE BY CONSTRUCTION. A sample is an instant; an
## execution is an interval; a client's report describes a window that does
## not end where the sample falls. The residual is an indicator, not an
## accounting, and when reporting lags sampling it MUST be clamped at zero
## rather than allowed to go negative — a negative "everything else" is not
## a small error, it is a category error, and the schema rejects it.
##
## PLATFORM STATUS. macOS/arm64 is the only platform this has been run on.
## The Linux branch is written from ``/proc`` semantics and HAS NEVER
## EXECUTED. Every other platform reports unavailable, and an unavailable
## reading writes no row at all: a row of zeros would be indistinguishable
## from a measured idle machine.

import std/[locks, math, os, strutils]

import ./ids, ./store, ./types

const
  ioQueueDepthUnmeasured* = -1.0
    ## What ``io_queue_depth`` holds where the platform exposes no
    ## host-wide in-flight-request counter. It is negative on purpose: 0.0
    ## is a legitimate measurement (an idle disk) and would make "not
    ## measured" indistinguishable from "measured, and nothing was
    ## queued". macOS has no such counter reachable without linking IOKit,
    ## and spawning ``iostat`` once per cadence is exactly the measurement
    ## cost on the hot path the specification forbids.

type
  HostLoadReading* = object
    ## Host-wide totals, and nothing else.
    ##
    ## The cumulative fields are counters, not rates: a rate needs two
    ## readings, and forming it here would need a clock the reader does not
    ## own. ``attributeAmbientSample`` differences a pair.
    available*: bool
    source*: string
    detail*: string
    atUnixMillis*: int64
    cpuBusyMillis*: int64
      ## Cumulative busy CPU time summed over every logical core.
    cpuTotalMillis*: int64
      ## Cumulative busy + idle CPU time summed over every logical core,
      ## i.e. elapsed capacity. ``busy / total`` is therefore a fraction of
      ## the whole machine and not of one core.
    memTotalBytes*: int64
    memAvailableBytes*: int64
    swapInPages*: int64
      ## Cumulative pages faulted in from swap.
    loadAvg1m*: float64
    ioQueueDepth*: float64

  SelfReport* = object
    ## One live, client-reported execution. ``cpuPct`` is in the same unit
    ## as ``cpu_busy_pct``: percent of TOTAL host CPU capacity, so a single
    ## saturated core on a sixteen-core machine is 6.25 and not 100.
    executionId*: string
    cpuPct*: float64
    rssBytes*: int64

  ReadingPair* = enum
    ## Whether a pair of readings supports a measurement at all.
    ##
    ## THIS IS NOT A FORMALITY. macOS updates the mach CPU tick counters on
    ## its own schedule, not when they are read: at a 200 ms cadence about
    ## one sample in eight sees a BYTE-IDENTICAL snapshot. Dividing that
    ## pair yields ``0.0``, which is not "nothing was measured" — it is a
    ## claim that the machine was idle, written into a column a reader will
    ## average. Measured under a known 50%-of-capacity load, 12% of samples
    ## came out as an idle machine before this enumeration existed.
    rpAdvanced
      ## The counters moved. A rate can be formed.
    rpStale
      ## A byte-identical snapshot. NO row may be written, and the caller
      ## MUST keep the older reading as its baseline so the next tick
      ## differences against the last distinct snapshot rather than
      ## silently widening the gap.
    rpDiscontinuous
      ## A counter went backwards. macOS reports CPU ticks as 32-bit
      ## ``natural_t``, which wraps after about 2^32 ticks of core time —
      ## roughly a month of uptime on a sixteen-core machine, and once per
      ## state, so a few times a month. The baseline MUST be reset and one
      ## sample lost; the alternative is a rate computed across a
      ## discontinuity, which is a large wrong number rather than a missing
      ## one.

# ---------------------------------------------------------------------------
# Host-wide readings. Per platform, and per platform ONLY host-wide.
# ---------------------------------------------------------------------------

proc unavailableReading(source, detail: string): HostLoadReading =
  HostLoadReading(
    available: false, source: source, detail: detail,
    atUnixMillis: unixMillisNow(), cpuBusyMillis: 0, cpuTotalMillis: 0,
    memTotalBytes: 0, memAvailableBytes: 0, swapInPages: 0,
    loadAvg1m: 0.0, ioQueueDepth: ioQueueDepthUnmeasured)

when defined(macosx):
  import std/posix

  # `host_statistics`/`host_statistics64` answer for the MACHINE. There is
  # no pid in this interface: it cannot report on a process even if a
  # caller wanted it to, which is the property that makes it the right
  # instrument for a lease authority.
  type
    HostT = cuint
    MachMsgTypeNumberT = cint
    KernReturnT = cint

    HostCpuLoadInfo {.importc: "host_cpu_load_info_data_t",
                      header: "<mach/mach_host.h>", bycopy.} = object
      cpu_ticks {.importc.}: array[4, cuint]

    VmStatistics64 {.importc: "vm_statistics64_data_t",
                     header: "<mach/mach.h>", bycopy.} = object
      free_count {.importc.}: cuint
      inactive_count {.importc.}: cuint
      swapins {.importc.}: uint64

  proc machHostSelf(): HostT
    {.importc: "mach_host_self", header: "<mach/mach.h>".}
  proc hostStatistics(host: HostT; flavor: cint; info: pointer;
                      count: ptr MachMsgTypeNumberT): KernReturnT
    {.importc: "host_statistics", header: "<mach/mach.h>".}
  proc hostStatistics64(host: HostT; flavor: cint; info: pointer;
                        count: ptr MachMsgTypeNumberT): KernReturnT
    {.importc: "host_statistics64", header: "<mach/mach.h>".}
  proc getloadavgC(samples: ptr cdouble; count: cint): cint
    {.importc: "getloadavg", header: "<stdlib.h>".}
  proc sysctlbyname(name: cstring; oldp: pointer; oldlenp: ptr csize_t;
                    newp: pointer; newlen: csize_t): cint
    {.importc: "sysctlbyname", header: "<sys/sysctl.h>".}

  let
    hostCpuLoadInfoFlavor {.importc: "HOST_CPU_LOAD_INFO",
                            header: "<mach/mach_host.h>", nodecl.}: cint
    hostCpuLoadInfoCount {.importc: "HOST_CPU_LOAD_INFO_COUNT",
                           header: "<mach/mach_host.h>", nodecl.}: cint
    hostVmInfo64Flavor {.importc: "HOST_VM_INFO64",
                         header: "<mach/mach_host.h>", nodecl.}: cint
    hostVmInfo64Count {.importc: "HOST_VM_INFO64_COUNT",
                        header: "<mach/mach_host.h>", nodecl.}: cint

  const
    cpuStateUser = 0
    cpuStateSystem = 1
    cpuStateIdle = 2
    cpuStateNice = 3

  proc clockTicksPerSecond(): int64 =
    let value = sysconf(SC_CLK_TCK)
    if value > 0: int64(value) else: 100'i64

  proc totalMemoryBytes(): int64 =
    var value: uint64 = 0
    var size = csize_t(sizeof(value))
    if sysctlbyname("hw.memsize", addr value, addr size, nil, 0) != 0:
      return 0
    int64(value)

  proc readHostLoad*(): HostLoadReading =
    ## One host-wide reading. Never raises.
    result = unavailableReading("macos-mach-host-statistics", "")
    var cpu: HostCpuLoadInfo
    var cpuCount = hostCpuLoadInfoCount
    if hostStatistics(machHostSelf(), hostCpuLoadInfoFlavor, addr cpu,
        addr cpuCount) != 0:
      result.detail = "host_statistics(HOST_CPU_LOAD_INFO) failed"
      return
    var vm: VmStatistics64
    var vmCount = hostVmInfo64Count
    if hostStatistics64(machHostSelf(), hostVmInfo64Flavor, addr vm,
        addr vmCount) != 0:
      result.detail = "host_statistics64(HOST_VM_INFO64) failed"
      return

    let ticks = clockTicksPerSecond()
    let busy = int64(cpu.cpu_ticks[cpuStateUser]) +
      int64(cpu.cpu_ticks[cpuStateSystem]) + int64(cpu.cpu_ticks[cpuStateNice])
    let idle = int64(cpu.cpu_ticks[cpuStateIdle])
    result.cpuBusyMillis = busy * 1000'i64 div ticks
    result.cpuTotalMillis = (busy + idle) * 1000'i64 div ticks

    # `free_count` here already INCLUDES the speculative pages that
    # `vm_stat` reports as a separate line, so adding speculation again
    # would double-count it and overstate what is available.
    let pageSize = int64(sysconf(SC_PAGESIZE))
    result.memAvailableBytes =
      (int64(vm.free_count) + int64(vm.inactive_count)) * pageSize
    result.memTotalBytes = totalMemoryBytes()
    result.swapInPages = int64(vm.swapins)

    var loads: array[3, cdouble]
    result.loadAvg1m =
      if getloadavgC(addr loads[0], 3) >= 1: float64(loads[0]) else: 0.0
    result.ioQueueDepth = ioQueueDepthUnmeasured
    result.atUnixMillis = unixMillisNow()
    result.available = result.cpuTotalMillis > 0 and result.memTotalBytes > 0
    if not result.available:
      result.detail = "kernel reported a zero capacity"

elif defined(linux):
  # NOT EXECUTED ANYWHERE YET. Written from the documented contents of
  # `/proc`; no field below has been compared against a real Linux
  # machine. Treat a wrong value here as a first observation, not a
  # regression. What macOS proves is the shape: every interface named
  # below is host-wide, the attribution downstream is platform-independent,
  # and neither reads a per-process file.
  proc readFileOrEmpty(path: string): string =
    try:
      if fileExists(path): readFile(path) else: ""
    except CatchableError:
      ""

  proc kilobytesField(text, key: string): int64 =
    for line in text.splitLines():
      let parts = line.split(':', maxsplit = 1)
      if parts.len == 2 and parts[0].strip() == key:
        let digits = parts[1].strip().split()
        if digits.len > 0:
          try:
            return parseBiggestInt(digits[0]) * 1024
          except ValueError:
            return 0
    0

  proc vmstatField(text, key: string): int64 =
    for line in text.splitLines():
      let parts = line.splitWhitespace()
      if parts.len == 2 and parts[0] == key:
        try:
          return parseBiggestInt(parts[1])
        except ValueError:
          return 0
    0

  proc inFlightRequests(): float64 =
    ## Field 9 of `/proc/diskstats` is "I/Os currently in progress",
    ## summed over whole devices. Partitions are skipped so a request is
    ## not counted twice.
    var total = 0'i64
    var sawDevice = false
    for line in readFileOrEmpty("/proc/diskstats").splitLines():
      let fields = line.splitWhitespace()
      if fields.len < 12:
        continue
      let name = fields[2]
      if name.startsWith("loop") or name.startsWith("ram"):
        continue
      if name.len > 0 and name[^1] in {'0' .. '9'} and
          (name.startsWith("sd") or name.startsWith("hd") or
           name.startsWith("vd")):
        continue
      try:
        total += parseBiggestInt(fields[11])
        sawDevice = true
      except ValueError:
        discard
    if sawDevice: float64(total) else: ioQueueDepthUnmeasured

  proc readHostLoad*(): HostLoadReading =
    result = unavailableReading("linux-proc", "")
    let stat = readFileOrEmpty("/proc/stat")
    var busyTicks = 0'i64
    var idleTicks = 0'i64
    for line in stat.splitLines():
      let fields = line.splitWhitespace()
      if fields.len < 5 or fields[0] != "cpu":
        continue
      # The aggregate `cpu` line only: the `cpuN` lines below it are the
      # same time counted a second time, per core.
      for i in 1 ..< fields.len:
        let value =
          try: parseBiggestInt(fields[i])
          except ValueError: 0'i64
        # Fields 4 and 5 after the label are idle and iowait; iowait is
        # not busy CPU, so both are idle capacity here.
        if i == 4 or i == 5: idleTicks += value else: busyTicks += value
      break
    if busyTicks + idleTicks <= 0:
      result.detail = "/proc/stat carried no aggregate cpu line"
      return
    # `/proc/stat` is in USER_HZ, which is 100 on every Linux ABI.
    result.cpuBusyMillis = busyTicks * 10'i64
    result.cpuTotalMillis = (busyTicks + idleTicks) * 10'i64

    let meminfo = readFileOrEmpty("/proc/meminfo")
    result.memTotalBytes = kilobytesField(meminfo, "MemTotal")
    result.memAvailableBytes = kilobytesField(meminfo, "MemAvailable")
    result.swapInPages = vmstatField(readFileOrEmpty("/proc/vmstat"), "pswpin")
    let loadavg = readFileOrEmpty("/proc/loadavg").splitWhitespace()
    result.loadAvg1m =
      if loadavg.len > 0:
        try: parseFloat(loadavg[0]) except ValueError: 0.0
      else: 0.0
    result.ioQueueDepth = inFlightRequests()
    result.atUnixMillis = unixMillisNow()
    result.available = result.memTotalBytes > 0
    if not result.available:
      result.detail = "/proc/meminfo carried no MemTotal"

else:
  # Deliberately not written speculatively. Windows host-wide load wants
  # `GetSystemTimes`, `GlobalMemoryStatusEx` and a performance counter for
  # the disk queue; guessing at them here would produce a reading that
  # looks measured and is not. Unavailable writes no row, which is the
  # honest outcome.
  proc readHostLoad*(): HostLoadReading =
    unavailableReading("unsupported-platform",
      "host-wide load sampling is not implemented on this platform")

# ---------------------------------------------------------------------------
# Attribution by difference
# ---------------------------------------------------------------------------

proc sumSelfCpuPct*(reports: openArray[SelfReport]): float64 =
  for report in reports:
    result += report.cpuPct

proc sumSelfRssBytes*(reports: openArray[SelfReport]): int64 =
  for report in reports:
    result += report.rssBytes

proc classifyReadings*(previous, current: HostLoadReading): ReadingPair =
  ## Whether ``previous`` and ``current`` can be differenced at all.
  ##
  ## ``attributeAmbientSample`` may only be called on an ``rpAdvanced``
  ## pair. The sampler writes no row for the other two, because the only
  ## values it could write are inventions.
  let totalDelta = current.cpuTotalMillis - previous.cpuTotalMillis
  let busyDelta = current.cpuBusyMillis - previous.cpuBusyMillis
  if totalDelta < 0 or busyDelta < 0 or busyDelta > totalDelta or
      current.atUnixMillis < previous.atUnixMillis or
      current.swapInPages < previous.swapInPages:
    return rpDiscontinuous
  if totalDelta == 0:
    return rpStale
  rpAdvanced

proc ambientSampleFollows*(lastSampledAtUnixMillis,
                           sampledAtUnixMillis: int64): bool =
  ## Whether a sample taken at ``sampledAtUnixMillis`` can be stored after
  ## one already written at ``lastSampledAtUnixMillis``.
  ##
  ## ``(host_id, sampled_at_unix_millis)`` is the primary key, so two
  ## samples landing inside one millisecond COLLIDE. There are exactly two
  ## things an implementation can do with the loser, and only one of them
  ## is honest: drop it, or move its timestamp. Moving it writes an instant
  ## at which nothing was read — a measurement nobody made, presented in
  ## the store as an observation, which OS-2 forbids. It is dropped and
  ## counted instead, exactly as a stale or discontinuous pair is, and the
  ## count is readable through ``ambientSamplesCollided``.
  sampledAtUnixMillis > lastSampledAtUnixMillis

proc attributeAmbientSample*(hostId: string;
                             previous, current: HostLoadReading;
                             reports: openArray[SelfReport]):
    AmbientSampleRow =
  ## The whole of M11's arithmetic, as a pure function of two host-wide
  ## readings and what clients said about themselves.
  ##
  ## ``previous`` is the preceding reading; the CPU and swap columns are
  ## rates over the interval between the two, because the kernel counters
  ## they come from are cumulative and a cumulative counter divided by
  ## nothing is a number about the time since boot. The pair MUST classify
  ## as ``rpAdvanced``; on anything else the result describes no interval.
  ##
  ## THE CLAMP. ``foreign_*`` is a residual, and a residual goes negative
  ## whenever a client's report covers a busier window than the one the
  ## sample fell in — which is the normal case, not an error, because
  ## reports lag samples. It is clamped at zero here and the schema
  ## refuses a negative besides, so the two cannot disagree.
  let elapsedMillis = current.atUnixMillis - previous.atUnixMillis
  let totalDelta = current.cpuTotalMillis - previous.cpuTotalMillis
  let busyDelta = current.cpuBusyMillis - previous.cpuBusyMillis
  let cpuBusyPct =
    if totalDelta > 0:
      100.0 * float64(busyDelta) / float64(totalDelta)
    else:
      0.0
  let swapDelta = current.swapInPages - previous.swapInPages
  let swapInRate =
    if elapsedMillis > 0 and swapDelta >= 0:
      float64(swapDelta) * 1000.0 / float64(elapsedMillis)
    else:
      0.0
  let memUsedBytes =
    max(0'i64, current.memTotalBytes - current.memAvailableBytes)
  let selfCpuPct = sumSelfCpuPct(reports)
  let selfRssBytes = sumSelfRssBytes(reports)
  AmbientSampleRow(
    hostId: hostId,
    sampledAtUnixMillis: current.atUnixMillis,
    cpuBusyPct: cpuBusyPct,
    memAvailableBytes: current.memAvailableBytes,
    swapInRate: swapInRate,
    ioQueueDepth: current.ioQueueDepth,
    loadAvg1m: current.loadAvg1m,
    selfCpuPct: selfCpuPct,
    selfRssBytes: selfRssBytes,
    foreignCpuPct: max(0.0, cpuBusyPct - selfCpuPct),
    foreignRssBytes: max(0'i64, memUsedBytes - selfRssBytes))

# ---------------------------------------------------------------------------
# The sampler thread
# ---------------------------------------------------------------------------
#
# Single-sampler-per-process, like the observation writer next to it: the
# state below is module-level so no `ref` crosses a thread boundary.
#
# Cadence is FIXED and independent of execution boundaries. Sampling per
# execution would put the measurement cost on the hot path OS-1 protects
# and would say nothing about what happened between executions -- which is
# where an idle machine and a machine somebody else is hammering look most
# alike.

const
  defaultAmbientCadenceMillis* = 1000
    ## One sample a second. The consequence is a row a second per host --
    ## about 86k rows a day -- which is why retention (M15) is a
    ## prerequisite for leaving this on forever rather than an
    ## afterthought.
  defaultAmbientFlushSamples* = 10
    ## Samples buffered before a batch reaches SQLite. Sampling is a pair
    ## of kernel calls; writing is a process spawn, so they run at
    ## different rates on purpose.

var
  samplerLock: Lock
  samplerLockReady = false
  samplerThread: Thread[void]
  samplerPath = ""
  samplerHostId = ""
  samplerCadenceMillis = defaultAmbientCadenceMillis
  samplerFlushSamples = defaultAmbientFlushSamples
  samplerCapacity = 0
  samplerQueue: seq[AmbientSampleRow] = @[]
  samplerReports: seq[SelfReport] = @[]
  samplerTicks = 0'i64
  samplerTaken = 0'i64
  samplerWritten = 0'i64
  samplerDropped = 0'i64
  samplerFailures = 0'i64
  samplerUnavailable = 0'i64
  samplerStale = 0'i64
  samplerDiscontinuous = 0'i64
  samplerCollided = 0'i64
  samplerLastSampledAt = 0'i64
  samplerStop = false
  samplerActive = false

proc ensureSamplerLock() =
  if not samplerLockReady:
    initLock(samplerLock)
    samplerLockReady = true

proc reportSelfExecution*(executionId: string; cpuPct: float64;
                          rssBytes: int64) =
  ## Records what a client said about one of ITS OWN live executions.
  ##
  ## This is the only way a figure becomes ``self``. The daemon never
  ## measures a client's processes, so an execution nobody reports is
  ## indistinguishable here from an execution that does not exist — it
  ## lands in ``foreign`` — and that is the correct failure direction for
  ## a lease authority: it understates what RunQuota takes credit for
  ## rather than inventing a measurement it did not make.
  ##
  ## Repeating an ``executionId`` replaces its figures rather than adding
  ## to them; a client reporting twice must not double its own weight.
  ensureSamplerLock()
  acquire(samplerLock)
  try:
    for i in 0 ..< samplerReports.len:
      if samplerReports[i].executionId == executionId:
        samplerReports[i].cpuPct = cpuPct
        samplerReports[i].rssBytes = rssBytes
        return
    samplerReports.add(SelfReport(executionId: executionId, cpuPct: cpuPct,
      rssBytes: rssBytes))
  finally:
    release(samplerLock)

proc endSelfReportedExecution*(executionId: string) =
  ## Drops a finished execution from the live set. ``self_*`` is the sum
  ## over CONCURRENTLY LIVE executions; leaving a finished one in would
  ## grow ``self`` without bound and drive ``foreign`` to the clamp.
  ensureSamplerLock()
  acquire(samplerLock)
  try:
    for i in 0 ..< samplerReports.len:
      if samplerReports[i].executionId == executionId:
        samplerReports.delete(i)
        return
  finally:
    release(samplerLock)

proc liveSelfReports*(): seq[SelfReport] =
  ensureSamplerLock()
  acquire(samplerLock)
  try:
    samplerReports
  finally:
    release(samplerLock)

proc clearSelfReportedExecutions*() =
  ensureSamplerLock()
  acquire(samplerLock)
  try:
    samplerReports = @[]
  finally:
    release(samplerLock)

proc flushAmbientQueue() {.gcsafe.} =
  {.cast(gcsafe).}:
    var rows: seq[AmbientSampleRow] = @[]
    var path = ""
    acquire(samplerLock)
    try:
      path = samplerPath
      if samplerQueue.len > 0:
        rows = samplerQueue
        samplerQueue = @[]
    finally:
      release(samplerLock)
    if path.len == 0 or rows.len == 0:
      return
    let outcome = appendAmbientSamplesAt(path, rows)
    acquire(samplerLock)
    try:
      if outcome.ok:
        samplerWritten += int64(rows.len)
      else:
        samplerFailures += 1
        samplerDropped += int64(rows.len)
    finally:
      release(samplerLock)

proc takeAmbientSample(previous: var HostLoadReading) {.gcsafe.} =
  {.cast(gcsafe).}:
    acquire(samplerLock)
    try:
      samplerTicks += 1
    finally:
      release(samplerLock)
    let current = readHostLoad()
    if not current.available:
      acquire(samplerLock)
      try:
        samplerUnavailable += 1
      finally:
        release(samplerLock)
      return
    if not previous.available:
      # The first reading of a pair establishes the baseline. There is no
      # rate yet, and writing one would mean dividing a since-boot counter
      # by the age of this daemon.
      previous = current
      return
    case classifyReadings(previous, current)
    of rpStale:
      # The kernel has not updated its counters since the last tick. The
      # baseline is deliberately NOT advanced: the next tick differences
      # against the last distinct snapshot, so the interval widens instead
      # of the sample being invented.
      acquire(samplerLock)
      try:
        samplerStale += 1
      finally:
        release(samplerLock)
      return
    of rpDiscontinuous:
      # A counter wrapped or was reset. Re-baseline and lose exactly one
      # sample rather than report a rate across the discontinuity.
      acquire(samplerLock)
      try:
        samplerDiscontinuous += 1
      finally:
        release(samplerLock)
      previous = current
      return
    of rpAdvanced:
      discard
    var row: AmbientSampleRow
    var collided = false
    acquire(samplerLock)
    try:
      row = attributeAmbientSample(samplerHostId, previous, current,
        samplerReports)
      # `(host_id, sampled_at_unix_millis)` is the primary key, so two
      # samples inside one millisecond collide. The loser is DROPPED and
      # COUNTED, which is how this module already handles a stale pair and
      # a discontinuous one. Re-timing it to the next free millisecond
      # would put an instant in `sampled_at` at which no reading was taken
      # -- a fabricated value presented as an observation, which is what
      # OS-2 forbids and what this store exists to refuse.
      if not ambientSampleFollows(samplerLastSampledAt,
          row.sampledAtUnixMillis):
        samplerCollided += 1
        collided = true
      else:
        samplerLastSampledAt = row.sampledAtUnixMillis
        samplerTaken += 1
        if samplerQueue.len >= samplerCapacity:
          samplerDropped += 1
        else:
          samplerQueue.add(row)
    finally:
      release(samplerLock)
    if collided:
      # The baseline is deliberately NOT advanced, for the same reason a
      # stale pair does not advance it: the interval this reading covered
      # is folded into the next sample rather than thrown away.
      return
    previous = current

proc samplerMain() {.thread.} =
  var previous = HostLoadReading(available: false)
  var sinceFlush = 0
  while true:
    var cadence = 0
    var flushEvery = 0
    var shouldStop = false
    {.cast(gcsafe).}:
      acquire(samplerLock)
      try:
        cadence = samplerCadenceMillis
        flushEvery = samplerFlushSamples
        shouldStop = samplerStop
      finally:
        release(samplerLock)
    if shouldStop:
      break
    sleep(cadence)
    takeAmbientSample(previous)
    sinceFlush += 1
    if sinceFlush >= flushEvery:
      sinceFlush = 0
      flushAmbientQueue()
  flushAmbientQueue()

proc startAmbientSampler*(path, hostId: string;
                          cadenceMillis = defaultAmbientCadenceMillis;
                          flushSamples = defaultAmbientFlushSamples;
                          capacity = 4096) =
  ## Starts the fixed-cadence sampler for ``path``. An empty path or host
  ## id leaves it inactive, which is how a degraded or disabled store is
  ## represented.
  ensureSamplerLock()
  acquire(samplerLock)
  try:
    if samplerActive:
      return
    samplerPath = path
    samplerHostId = hostId
    samplerCadenceMillis = max(1, cadenceMillis)
    samplerFlushSamples = max(1, flushSamples)
    samplerCapacity = max(1, capacity)
    samplerQueue = @[]
    samplerReports = @[]
    samplerTicks = 0
    samplerTaken = 0
    samplerWritten = 0
    samplerDropped = 0
    samplerFailures = 0
    samplerUnavailable = 0
    samplerStale = 0
    samplerDiscontinuous = 0
    samplerCollided = 0
    samplerLastSampledAt = 0
    samplerStop = false
    if path.len == 0 or hostId.len == 0:
      return
    samplerActive = true
  finally:
    release(samplerLock)
  createThread(samplerThread, samplerMain)

proc ambientSamplerActive*(): bool =
  ensureSamplerLock()
  acquire(samplerLock)
  try:
    samplerActive
  finally:
    release(samplerLock)

proc ambientSamplerTicks*(): int64 =
  ## How many times the FIXED cadence fired, whether or not the kernel had
  ## anything new to say. ``ticks - taken`` is the honesty gap.
  ensureSamplerLock()
  acquire(samplerLock)
  try:
    samplerTicks
  finally:
    release(samplerLock)

proc ambientSamplesTaken*(): int64 =
  ensureSamplerLock()
  acquire(samplerLock)
  try:
    samplerTaken
  finally:
    release(samplerLock)

proc ambientReadingsStale*(): int64 =
  ## Ticks that saw a byte-identical kernel snapshot and therefore wrote no
  ## row. On macOS this is normally a tenth of the ticks at a 200 ms
  ## cadence; it is not an error, and each one is a sample NOT invented.
  ensureSamplerLock()
  acquire(samplerLock)
  try:
    samplerStale
  finally:
    release(samplerLock)

proc ambientReadingsDiscontinuous*(): int64 =
  ensureSamplerLock()
  acquire(samplerLock)
  try:
    samplerDiscontinuous
  finally:
    release(samplerLock)

proc ambientSamplesCollided*(): int64 =
  ## Samples dropped because their millisecond was already taken by a
  ## written sample. Nonzero here means the cadence outran the primary
  ## key's resolution; it never means a timestamp was invented, because
  ## this counter exists precisely so that none is.
  ensureSamplerLock()
  acquire(samplerLock)
  try:
    samplerCollided
  finally:
    release(samplerLock)

proc ambientSamplesWritten*(): int64 =
  ensureSamplerLock()
  acquire(samplerLock)
  try:
    samplerWritten
  finally:
    release(samplerLock)

proc ambientSamplesDropped*(): int64 =
  ensureSamplerLock()
  acquire(samplerLock)
  try:
    samplerDropped
  finally:
    release(samplerLock)

proc ambientSampleFailures*(): int64 =
  ensureSamplerLock()
  acquire(samplerLock)
  try:
    samplerFailures
  finally:
    release(samplerLock)

proc ambientReadingsUnavailable*(): int64 =
  ensureSamplerLock()
  acquire(samplerLock)
  try:
    samplerUnavailable
  finally:
    release(samplerLock)

proc stopAmbientSampler*() =
  ## Flushes what is queued and joins the sampler thread.
  ensureSamplerLock()
  var running = false
  acquire(samplerLock)
  try:
    running = samplerActive
    samplerStop = true
  finally:
    release(samplerLock)
  if not running:
    return
  joinThread(samplerThread)
  acquire(samplerLock)
  try:
    samplerActive = false
    samplerPath = ""
    samplerHostId = ""
    samplerReports = @[]
  finally:
    release(samplerLock)
