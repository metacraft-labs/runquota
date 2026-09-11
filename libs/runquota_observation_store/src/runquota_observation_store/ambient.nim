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
## SAMPLING IS GATED ON AT LEAST ONE LIVE LEASE. Fixed cadence means
## independent of execution *boundaries*, not independent of whether any
## work exists. This is the only writer in the store unbounded in TIME --
## an execution costs one row per execution -- and a sample taken while no
## lease is live can never be joined to an execution, so it is a row no
## query can reach. The gate therefore costs no information and bounds
## ambient growth by build activity. ``setAmbientLiveLeaseCount`` is how
## the lease authority publishes it.
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
    ownerKey*: string
      ## WHO WOULD HAVE TO DIE FOR THIS REPORT TO BE GARBAGE.
      ##
      ## A report has exactly two honest exits: the client says the
      ## execution ended, or the client itself is gone. Before M13 there
      ## was only the first, because a report was keyed by a bare
      ## ``executionId`` with no association to anything the daemon
      ## already reclaims — so a client that reported an execution and then
      ## crashed leaked its figures into ``self_*`` for the daemon's whole
      ## lifetime, understating every later ``foreign_*`` until the clamp
      ## pinned it to zero. That was latent only because nothing in
      ## production called ``reportSelfExecution``; M13 is what makes it
      ## live, so the second exit has to exist.
      ##
      ## The key is opaque here on purpose: this library knows nothing
      ## about sessions or leases. The daemon puts its session identity in
      ## it, and its EXISTING crash-reclamation path — the one that already
      ## handles a client dying mid-lease — reaps by it for free.
      ##
      ## Empty means no owner was declared, and an unowned report is never
      ## swept by ``endSelfReportsForOwner``: sweeping "everything with no
      ## owner" on one session's teardown would drop reports belonging to
      ## nobody in particular, which is not the same set.

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
  samplerThread: Thread[void]
  samplerPath = ""
  samplerHostId = ""
  samplerCadenceMillis = defaultAmbientCadenceMillis
  samplerFlushSamples = defaultAmbientFlushSamples
  samplerCapacity = 0
  samplerQueue: seq[AmbientSampleRow] = @[]
    ## Grown and emptied ONLY on the sampler thread -- `takeAmbientSample`
    ## appends and `flushAmbientQueue` drains, and both run there. That is
    ## what keeps it an ordinary `seq` while the live report set below cannot
    ## be one: `startAmbientSampler` resets it from another thread, and the
    ## reset is safe only because `samplerMain` ends with a flush that leaves
    ## the payload empty. See the note above `reportSlots`.
  samplerTicks = 0'i64
  samplerTaken = 0'i64
  samplerWritten = 0'i64
  samplerDropped = 0'i64
  samplerFailures = 0'i64
  samplerUnavailable = 0'i64
  samplerStale = 0'i64
  samplerDiscontinuous = 0'i64
  samplerCollided = 0'i64
  samplerNoLease = 0'i64
  samplerLastSampledAt = 0'i64
  samplerLiveLeases = 0
  samplerLeaseCovered = false
  samplerStop = false
  samplerActive = false

# ARMED AT MODULE INITIALISATION, for the reason set out at length over the
# same line in ``writer.nim``. The lazy `ensure` proc that stood here was a
# plain ``bool`` gating an ``initLock``, and this module is reached the same
# way the writer is: ``initDaemon`` calls ``startAmbientSampler`` only when
# the store has a host identity, the host row was written AND the configured
# sample interval is positive, so in every other configuration the first
# touch is a connection worker's ``setAmbientLiveLeaseCount`` or
# ``reportSelfExecution`` -- and several workers can arrive together. Module
# initialisation runs inside ``NimMain``, before any thread exists.
initLock(samplerLock)

# ---------------------------------------------------------------------------
# The live self-report set, and why it is not a `seq`
# ---------------------------------------------------------------------------
#
# THIS SET OUTLIVES THE THREADS THAT WRITE INTO IT, and under Nim's ORC
# allocator that is not something a lock can make safe.
#
# Every thread gets its OWN allocator region -- `var allocator
# {.rtlThreadVar.}: MemRegion` in `system/mmdisp.nim`, which is the region
# `system/alloc.nim`'s `instantiateForRegion` is instantiated with under
# ORC -- and every allocated chunk records the region that owns it.
# Freeing a chunk from a DIFFERENT thread is supported:
# `rawDealloc` hands it back through `addToSharedFreeList`, which dereferences
# `chunk.owner`. But that is sound only while the owner still EXISTS, and a
# thread's region lives in its thread-local storage and goes away with the
# thread. A block allocated on one thread and freed after that thread has
# exited therefore dereferences a dead region. The lock is not the issue and
# never was: it serialises ACCESS, and this is a question of OWNERSHIP.
#
# The set is written by whichever thread serves the client that reports -- in
# `runquotad`, a connection worker, from `applyLeaseObservation` -- and emptied
# by `stopAmbientSampler`, which `serve` calls on the shutting-down thread
# AFTER those workers have been joined. As a `seq[SelfReport]` its payload and
# its id strings were owned by threads that no longer existed when they were
# freed. `t_ambient_sample_atomicity` reproduced it as a SIGSEGV inside
# `addToSharedFreeList`, reached from `clearSelfReportedExecutions`; the same
# binary built `-d:useMalloc` -- one process-wide arena, no owning thread --
# passes, which is what identifies the mechanism rather than guessing at it.
#
# So the set is taken off the thread-owned heap. The slot array and the id
# bytes come from the C allocator, which has one arena for the whole process
# and no notion of an owner, so WHICH thread frees them, and WHEN, stops
# mattering. Nim's `allocShared` is NOT that allocator under ORC:
# `allocSharedImpl` is `allocImpl` verbatim there, with exactly the same
# per-thread ownership, which is why `malloc` is reached for directly.
#
# What crosses this boundary as ordinary Nim values is unaffected and stays
# that way: `liveSelfReports` and the sampler's snapshot build a fresh
# `seq[SelfReport]` on the CALLING thread, which then allocates and frees it
# itself.

proc cMalloc(size: csize_t): pointer {.importc: "malloc",
  header: "<stdlib.h>".}
proc cRealloc(p: pointer; size: csize_t): pointer {.importc: "realloc",
  header: "<stdlib.h>".}
proc cFree(p: pointer) {.importc: "free", header: "<stdlib.h>".}

type
  SelfReportSlot = object
    ## One live report, in storage the PROCESS owns rather than a thread.
    ##
    ## The ids are kept as bytes plus a length rather than as NUL-terminated
    ## strings because every operation on this set is a lookup by id: a length
    ## check and an `equalMem` allocate nothing, where converting a `cstring`
    ## back would allocate on the reporting thread once per slot scanned.
    executionId: ptr UncheckedArray[char]
    executionIdLen: int
    ownerKey: ptr UncheckedArray[char]
    ownerKeyLen: int
    cpuPct: float64
    rssBytes: int64

var
  reportSlots: ptr UncheckedArray[SelfReportSlot] = nil
  reportSlotsLen = 0
  reportSlotsCap = 0

# Every proc in this section requires `samplerLock` to be held. Process-owned
# storage answers ownership; it does not answer mutual exclusion, and both
# have to be answered.

proc adoptBytes(value: string; field: var ptr UncheckedArray[char];
                fieldLen: var int): bool =
  ## Replaces ``field`` with a C-heap copy of ``value``. Returns false, and
  ## leaves ``field`` exactly as it was, when the allocator has nothing to
  ## give.
  if value.len == 0:
    if field != nil:
      cFree(field)
    field = nil
    fieldLen = 0
    return true
  let fresh = cast[ptr UncheckedArray[char]](cMalloc(csize_t(value.len)))
  if fresh == nil:
    return false
  copyMem(fresh, unsafeAddr value[0], value.len)
  if field != nil:
    cFree(field)
  field = fresh
  fieldLen = value.len
  true

proc sameBytes(field: ptr UncheckedArray[char]; fieldLen: int;
               value: string): bool =
  if fieldLen != value.len:
    return false
  if fieldLen == 0:
    return true
  equalMem(field, unsafeAddr value[0], fieldLen)

proc asNimString(field: ptr UncheckedArray[char]; fieldLen: int): string =
  result = newString(fieldLen)
  if fieldLen > 0:
    copyMem(addr result[0], field, fieldLen)

proc releaseSlot(slot: var SelfReportSlot) =
  if slot.executionId != nil:
    cFree(slot.executionId)
    slot.executionId = nil
  if slot.ownerKey != nil:
    cFree(slot.ownerKey)
    slot.ownerKey = nil
  slot.executionIdLen = 0
  slot.ownerKeyLen = 0

proc reserveSlots(needed: int): bool =
  if needed <= reportSlotsCap:
    return true
  var capacity = max(8, reportSlotsCap)
  while capacity < needed:
    capacity = capacity * 2
  let grown = cRealloc(reportSlots, csize_t(capacity * sizeof(SelfReportSlot)))
  if grown == nil:
    return false
  reportSlots = cast[ptr UncheckedArray[SelfReportSlot]](grown)
  reportSlotsCap = capacity
  true

proc dropSlotAt(index: int) =
  ## Removes one slot, keeping the rest in order. Order is not load-bearing
  ## for the sums, but ``liveSelfReports`` is a public view, and a set that
  ## reshuffled itself on every removal would make that view depend on
  ## reclamation history.
  releaseSlot(reportSlots[index])
  for i in index ..< reportSlotsLen - 1:
    reportSlots[i] = reportSlots[i + 1]
  reportSlotsLen -= 1

proc clearSelfReportSlots() =
  for i in 0 ..< reportSlotsLen:
    releaseSlot(reportSlots[i])
  reportSlotsLen = 0
  if reportSlots != nil:
    cFree(reportSlots)
    reportSlots = nil
  reportSlotsCap = 0

proc snapshotSelfReports(): seq[SelfReport] =
  ## The set as ordinary Nim values, allocated on the CALLING thread and so
  ## freed by it too.
  result = newSeqOfCap[SelfReport](reportSlotsLen)
  for i in 0 ..< reportSlotsLen:
    result.add(SelfReport(
      executionId: asNimString(reportSlots[i].executionId,
        reportSlots[i].executionIdLen),
      cpuPct: reportSlots[i].cpuPct,
      rssBytes: reportSlots[i].rssBytes,
      ownerKey: asNimString(reportSlots[i].ownerKey,
        reportSlots[i].ownerKeyLen)))

proc setAmbientLiveLeaseCount*(count: int) =
  ## How many leases the daemon currently holds live. SAMPLING IS GATED ON
  ## THIS: with none, a tick writes no row.
  ##
  ## Called by the lease authority, which is the only component that knows.
  ## It is a COUNT rather than a flag so that the caller can publish the
  ## number it already maintains instead of deriving a boolean it would
  ## then have to keep consistent.
  ##
  ## Raising it above zero also arms the coverage flag the sampler reads,
  ## which is what makes the tick straddling a lease's START a written
  ## sample rather than a lost one.
  acquire(samplerLock)
  try:
    samplerLiveLeases = max(0, count)
    if samplerLiveLeases > 0:
      samplerLeaseCovered = true
  finally:
    release(samplerLock)

proc ambientLiveLeaseCount*(): int =
  acquire(samplerLock)
  try:
    samplerLiveLeases
  finally:
    release(samplerLock)

proc reportSelfExecution*(executionId: string; cpuPct: float64;
                          rssBytes: int64; ownerKey = "") =
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
  acquire(samplerLock)
  try:
    for i in 0 ..< reportSlotsLen:
      if sameBytes(reportSlots[i].executionId, reportSlots[i].executionIdLen,
                   executionId):
        reportSlots[i].cpuPct = cpuPct
        reportSlots[i].rssBytes = rssBytes
        discard adoptBytes(ownerKey, reportSlots[i].ownerKey,
          reportSlots[i].ownerKeyLen)
        return
    # THE ONE CONDITION THIS SET CANNOT RECORD ITS WAY OUT OF is the machine
    # having no memory left to record in. The report is dropped rather than
    # raised: it would be raised on the thread serving a client, and an
    # unrecorded report only understates ``self_*`` -- the direction this
    # module already errs in on purpose, as the doc comment above says.
    if not reserveSlots(reportSlotsLen + 1):
      return
    var slot = SelfReportSlot(
      executionId: nil, executionIdLen: 0,
      ownerKey: nil, ownerKeyLen: 0,
      cpuPct: cpuPct, rssBytes: rssBytes)
    if not adoptBytes(executionId, slot.executionId, slot.executionIdLen) or
       not adoptBytes(ownerKey, slot.ownerKey, slot.ownerKeyLen):
      releaseSlot(slot)
      return
    reportSlots[reportSlotsLen] = slot
    reportSlotsLen += 1
  finally:
    release(samplerLock)

proc endSelfReportedExecution*(executionId: string) =
  ## Drops a finished execution from the live set. ``self_*`` is the sum
  ## over CONCURRENTLY LIVE executions; leaving a finished one in would
  ## grow ``self`` without bound and drive ``foreign`` to the clamp.
  acquire(samplerLock)
  try:
    for i in 0 ..< reportSlotsLen:
      if sameBytes(reportSlots[i].executionId, reportSlots[i].executionIdLen,
                   executionId):
        dropSlotAt(i)
        return
  finally:
    release(samplerLock)

proc endSelfReportsForOwner*(ownerKey: string): int {.discardable.} =
  ## Drops every live report an owner left behind, returning how many.
  ##
  ## THE CRASH EXIT. ``endSelfReportedExecution`` is the exit a working
  ## client takes; this is the one taken FOR a client that cannot take it
  ## itself — killed, disconnected, or wedged. The daemon calls it from the
  ## reclamation path it already runs when a supervisor's connection drops,
  ## which is why the owner key exists at all: that path had nothing to
  ## reap self-reports by, so it reaped leases and left the figures.
  ##
  ## AN EMPTY KEY SWEEPS NOTHING, deliberately. Reports arriving without an
  ## owner belong to no session, and letting one session's teardown carry
  ## them off would make the reaped set depend on which session happened to
  ## end first.
  if ownerKey.len == 0:
    return 0
  acquire(samplerLock)
  try:
    # Compacted in place, which keeps the survivors in order and hands the
    # swept slots' bytes straight back to the C allocator.
    var kept = 0
    for i in 0 ..< reportSlotsLen:
      if sameBytes(reportSlots[i].ownerKey, reportSlots[i].ownerKeyLen,
                   ownerKey):
        releaseSlot(reportSlots[i])
        inc result
      else:
        if kept != i:
          reportSlots[kept] = reportSlots[i]
        inc kept
    reportSlotsLen = kept
  finally:
    release(samplerLock)

proc liveSelfReports*(): seq[SelfReport] =
  acquire(samplerLock)
  try:
    snapshotSelfReports()
  finally:
    release(samplerLock)

proc clearSelfReportedExecutions*() =
  acquire(samplerLock)
  try:
    clearSelfReportSlots()
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
    # THE READING AND THE SELF FIGURES ARE ONE OBSERVATION, so they are
    # taken under one lock hold.
    #
    # `foreign_* = host total - sum(self_*)` is a subtraction of two
    # measurements, and it only means anything if both describe the SAME
    # instant. Taking the host reading here and reading the live set
    # later let a `reportSelfExecution` land between them: the row then
    # carried a timestamp from before the report and a `self_*` from after
    # it. Where the late figures exceeded the earlier host total -- a burst
    # of lease starts does this, and so does one lagging report -- the
    # clamp fired and `foreign_*` was written as zero. That row describes
    # no moment that ever existed.
    #
    # A row's `sampled_at_unix_millis` therefore now denotes the instant at
    # which BOTH the kernel counters and the live self-reports were read.
    # `readHostLoad` is syscalls only (mach counters on macOS, `/proc` on
    # Linux); it spawns nothing and takes no lock of its own, so holding
    # `samplerLock` across it costs a few microseconds and cannot deadlock.
    var current: HostLoadReading
    var reports: seq[SelfReport]
    acquire(samplerLock)
    try:
      samplerTicks += 1
      current = readHostLoad()
      reports = snapshotSelfReports()
    finally:
      release(samplerLock)
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

    # THE LIVE-LEASE GATE. A sample taken while no lease is live can never
    # be joined to an execution -- there is no execution for it to be
    # joined to -- so it is a row no query can reach, and this is the only
    # writer in the store unbounded in TIME rather than by work done. The
    # reading itself is still taken and still becomes the baseline: it
    # costs two kernel calls, it writes nothing, and it is what keeps the
    # first WRITTEN sample after work resumes an interval of one cadence
    # rather than an average over the whole idle night.
    #
    # BOTH TRANSITION EDGES ARE COVERED, and covered the same way. A tick
    # measures the interval since the previous one, so the question is
    # whether a lease was live at any point INSIDE that interval, not
    # whether one is live at the instant the tick fires. `samplerLeaseCovered`
    # answers it: raised the moment a lease appears, and cleared at the end
    # of a tick only when none is live any more. The tick straddling the
    # first lease's start is therefore written, and so is the one
    # straddling the last lease's end -- each of those intervals really did
    # contain work -- and the tick after that is the first one dropped.
    var covered = false
    acquire(samplerLock)
    try:
      covered = samplerLeaseCovered or samplerLiveLeases > 0
      samplerLeaseCovered = samplerLiveLeases > 0
      if not covered:
        samplerNoLease += 1
    finally:
      release(samplerLock)
    if not covered:
      previous = current
      return

    var row: AmbientSampleRow
    var collided = false
    acquire(samplerLock)
    try:
      # `reports` is the snapshot taken WITH the reading above, not
      # the live set as it stands NOW: re-reading it here is precisely
      # the skew this proc exists to avoid.
      row = attributeAmbientSample(samplerHostId, previous, current, reports)
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
    clearSelfReportSlots()
    samplerTicks = 0
    samplerTaken = 0
    samplerWritten = 0
    samplerDropped = 0
    samplerFailures = 0
    samplerUnavailable = 0
    samplerStale = 0
    samplerDiscontinuous = 0
    samplerCollided = 0
    samplerNoLease = 0
    samplerLastSampledAt = 0
    # A sampler starts with NOTHING LIVE, and therefore writing nothing.
    # The lease authority publishes the count as leases come and go; there
    # can be no live lease before the daemon that grants them is serving,
    # so starting from zero cannot lose one.
    samplerLiveLeases = 0
    samplerLeaseCovered = false
    samplerStop = false
    if path.len == 0 or hostId.len == 0:
      return
    samplerActive = true
  finally:
    release(samplerLock)
  createThread(samplerThread, samplerMain)

proc ambientSamplerActive*(): bool =
  acquire(samplerLock)
  try:
    samplerActive
  finally:
    release(samplerLock)

proc ambientSamplerTicks*(): int64 =
  ## How many times the FIXED cadence fired, whether or not the kernel had
  ## anything new to say. ``ticks - taken`` is the honesty gap.
  acquire(samplerLock)
  try:
    samplerTicks
  finally:
    release(samplerLock)

proc ambientSamplesTaken*(): int64 =
  acquire(samplerLock)
  try:
    samplerTaken
  finally:
    release(samplerLock)

proc ambientReadingsStale*(): int64 =
  ## Ticks that saw a byte-identical kernel snapshot and therefore wrote no
  ## row. On macOS this is normally a tenth of the ticks at a 200 ms
  ## cadence; it is not an error, and each one is a sample NOT invented.
  acquire(samplerLock)
  try:
    samplerStale
  finally:
    release(samplerLock)

proc ambientReadingsDiscontinuous*(): int64 =
  acquire(samplerLock)
  try:
    samplerDiscontinuous
  finally:
    release(samplerLock)

proc ambientTicksWithoutLease*(): int64 =
  ## Ticks that read the host, kept the reading as a baseline, and wrote no
  ## row because no lease was live over the interval they measured. On an
  ## idle host this is every tick, which is the point: ambient growth is
  ## bounded by build activity, the same bound every other table in the
  ## store already obeys.
  acquire(samplerLock)
  try:
    samplerNoLease
  finally:
    release(samplerLock)

proc ambientSamplesCollided*(): int64 =
  ## Samples dropped because their millisecond was already taken by a
  ## written sample. Nonzero here means the cadence outran the primary
  ## key's resolution; it never means a timestamp was invented, because
  ## this counter exists precisely so that none is.
  acquire(samplerLock)
  try:
    samplerCollided
  finally:
    release(samplerLock)

proc ambientSamplesWritten*(): int64 =
  acquire(samplerLock)
  try:
    samplerWritten
  finally:
    release(samplerLock)

proc ambientSamplesDropped*(): int64 =
  acquire(samplerLock)
  try:
    samplerDropped
  finally:
    release(samplerLock)

proc ambientSampleFailures*(): int64 =
  acquire(samplerLock)
  try:
    samplerFailures
  finally:
    release(samplerLock)

proc ambientReadingsUnavailable*(): int64 =
  acquire(samplerLock)
  try:
    samplerUnavailable
  finally:
    release(samplerLock)

proc stopAmbientSampler*() =
  ## Flushes what is queued and joins the sampler thread.
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
    clearSelfReportSlots()
    samplerLiveLeases = 0
    samplerLeaseCovered = false
  finally:
    release(samplerLock)
