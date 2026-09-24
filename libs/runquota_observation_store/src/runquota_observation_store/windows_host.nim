## The Windows kernel interfaces the observation store reads: host-wide load
## for the ambient sampler, and the machine's descriptive facts for its
## hardware profile.
##
## Normative specification: ``reprobuild-specs/RunQuota-Observation-Store.md``
## §"`hosts` and `host_profiles`" and §"`ambient_samples`"; the milestone that
## asks for exactly this is MP2 in ``RunQuota-Observation-Store.milestones.org``
## ("The store's Windows backends land here: hardware detection and host-wide
## sampling via the platform's own APIs").
##
## EVERY INTERFACE HERE IS DOCUMENTED AND NEEDS NO PRIVILEGE, and every one is
## host-wide. Nothing inspects a process tree: the daemon is a lease authority
## and the ambient split is derived by difference (the specification's
## "Therefore:" list), so the only per-process figure anywhere near this file
## is the process count PDH already aggregates.
##
## NOTHING HERE RAISES, for OS-4's reason: a question the machine will not
## answer yields an empty string, a zero or an ``ok = false``, and the callers
## turn that into the documented ``unknown`` or an unavailable reading.

when not defined(windows):
  {.error: "windows_host is the Windows arm; import it only on Windows".}

import std/[bitops, locks, math, strutils, winlean]

# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------

const
  HkeyLocalMachine = cast[Handle](0x80000002'u)
  RrfRtRegSz = 0x00000002'i32
  RrfRtRegDword = 0x00000010'i32

proc regGetValueW(key: Handle; subKey, value: WideCString; flags: int32;
                  kind: ptr int32; data: pointer; size: ptr int32): int32
  {.stdcall, dynlib: "advapi32.dll", importc: "RegGetValueW".}

proc registryString*(subKey, value: string): string =
  ## A ``REG_SZ`` under HKEY_LOCAL_MACHINE, or "" when it is absent.
  var size = 0'i32
  let wideKey = newWideCString(subKey)
  let wideValue = newWideCString(value)
  if regGetValueW(HkeyLocalMachine, wideKey, wideValue, RrfRtRegSz, nil, nil,
      addr size) != 0 or size <= 2:
    return ""
  var buffer = newSeq[uint16](int(size) div 2 + 1)
  if regGetValueW(HkeyLocalMachine, wideKey, wideValue, RrfRtRegSz, nil,
      addr buffer[0], addr size) != 0:
    return ""
  $cast[WideCString](addr buffer[0])

proc registryDword*(subKey, value: string; found: var bool): uint32 =
  var data = 0'u32
  var size = int32(sizeof(data))
  found = regGetValueW(HkeyLocalMachine, newWideCString(subKey),
    newWideCString(value), RrfRtRegDword, nil, addr data, addr size) == 0
  data

# ---------------------------------------------------------------------------
# Memory
# ---------------------------------------------------------------------------

type
  MemoryStatusEx = object
    dwLength: uint32
    dwMemoryLoad: uint32
    ullTotalPhys: uint64
    ullAvailPhys: uint64
    ullTotalPageFile: uint64
    ullAvailPageFile: uint64
    ullTotalVirtual: uint64
    ullAvailVirtual: uint64
    ullAvailExtendedVirtual: uint64

  MemoryFigures* = object
    ok*: bool
    totalPhysicalBytes*: int64
    availablePhysicalBytes*: int64
    commitLimitBytes*: int64
      ## Physical memory plus the paging files: `ullTotalPageFile`, which
      ## despite its name is the commit limit and not the paging file.

proc globalMemoryStatusEx(buffer: ptr MemoryStatusEx): WINBOOL
  {.stdcall, dynlib: "kernel32.dll", importc: "GlobalMemoryStatusEx".}

proc getPhysicallyInstalledSystemMemory(kilobytes: ptr uint64): WINBOOL
  {.stdcall, dynlib: "kernel32.dll",
    importc: "GetPhysicallyInstalledSystemMemory".}

proc memoryFigures*(): MemoryFigures =
  var status = MemoryStatusEx(dwLength: uint32(sizeof(MemoryStatusEx)))
  if globalMemoryStatusEx(addr status) == 0:
    return MemoryFigures(ok: false)
  MemoryFigures(ok: true,
    totalPhysicalBytes: int64(status.ullTotalPhys),
    availablePhysicalBytes: int64(status.ullAvailPhys),
    commitLimitBytes: int64(status.ullTotalPageFile))

proc installedMemoryBytes*(): int64 =
  ## RAM as INSTALLED, from the firmware tables -- a capacity, which is what
  ## a hardware profile records. `ullTotalPhys` is what the OS can use, and
  ## moves when firmware or a driver reserves a different amount.
  var kilobytes = 0'u64
  if getPhysicallyInstalledSystemMemory(addr kilobytes) == 0:
    return 0
  int64(kilobytes) * 1024

# ---------------------------------------------------------------------------
# CPU
# ---------------------------------------------------------------------------

proc getSystemTimes(idle, kernel, user: ptr FILETIME): WINBOOL
  {.stdcall, dynlib: "kernel32.dll", importc: "GetSystemTimes".}

proc fileTimeTicks(value: FILETIME): int64 =
  (int64(value.dwHighDateTime) shl 32) or int64(uint32(value.dwLowDateTime))

proc systemCpuMillis*(busy, total: var int64): bool =
  ## Cumulative busy and busy + idle CPU time, summed over every processor,
  ## in milliseconds. `GetSystemTimes` reports 100 ns units and its KERNEL
  ## time INCLUDES the idle time, so busy is kernel + user - idle.
  var idle, kernel, user: FILETIME
  if getSystemTimes(addr idle, addr kernel, addr user) == 0:
    return false
  let idleTicks = fileTimeTicks(idle)
  let totalTicks = fileTimeTicks(kernel) + fileTimeTicks(user)
  if totalTicks <= 0 or idleTicks > totalTicks:
    return false
  # BUSY AND IDLE ARE ROUNDED, AND TOTAL IS THEIR SUM. Both are cumulative,
  # so each rounded figure is monotone, and a total built from them can never
  # advance by less than busy does. Rounding busy and total separately let a
  # saturated interval's busy delta exceed its total delta by a millisecond;
  # deriving busy as rounded total minus rounded idle let busy step BACKWARDS
  # by one on a nearly idle interval. Measured, both, on this reader.
  let busyMillis = (totalTicks - idleTicks) div 10_000
  let idleMillis = idleTicks div 10_000
  busy = busyMillis
  total = busyMillis + idleMillis
  true

const
  RelationProcessorCore = 0'i32

proc getLogicalProcessorInformationEx(relationship: int32; buffer: pointer;
                                      length: ptr uint32): WINBOOL
  {.stdcall, dynlib: "kernel32.dll",
    importc: "GetLogicalProcessorInformationEx".}

proc coreCounts*(physical, logical: var int64): bool =
  ## Physical cores are the `RelationProcessorCore` records; logical
  ## processors are the bits set in each core's group masks. Both span every
  ## processor group, which `GetSystemInfo` does not.
  var length = 0'u32
  discard getLogicalProcessorInformationEx(RelationProcessorCore, nil,
    addr length)
  if length == 0:
    return false
  var buffer = newSeq[byte](int(length))
  if getLogicalProcessorInformationEx(RelationProcessorCore, addr buffer[0],
      addr length) == 0:
    return false
  physical = 0
  logical = 0
  var offset = 0
  while offset + 8 <= int(length):
    # SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX: Relationship (4), Size (4),
    # then PROCESSOR_RELATIONSHIP: Flags, EfficiencyClass, Reserved[20],
    # GroupCount (2) at 30, GROUP_AFFINITY[] at 32, 16 bytes each with the
    # 8-byte KAFFINITY mask first.
    let relationship = cast[ptr int32](addr buffer[offset])[]
    let size = int(cast[ptr uint32](addr buffer[offset + 4])[])
    if size <= 0 or offset + size > int(length):
      break
    if relationship == RelationProcessorCore and size >= 32:
      physical += 1
      let groups = int(cast[ptr uint16](addr buffer[offset + 30])[])
      for g in 0 ..< groups:
        let at = offset + 32 + g * 16
        if at + 8 > offset + size:
          break
        logical += int64(countSetBits(cast[ptr uint64](addr buffer[at])[]))
    offset += size
  physical > 0 and logical > 0

# ---------------------------------------------------------------------------
# Operating system
# ---------------------------------------------------------------------------

proc getNativeSystemInfo(info: pointer)
  {.stdcall, dynlib: "kernel32.dll", importc: "GetNativeSystemInfo".}

proc nativeArchitecture*(): string =
  ## The MACHINE's architecture, not this process's: an x64 daemon under
  ## emulation on an arm64 machine still describes an arm64 machine. Spelled
  ## as the Linux and macOS arms' `uname -m` spell it. Read from
  ## `GetNativeSystemInfo` rather than `PROCESSOR_ARCHITECTURE`, which is an
  ## environment variable and so whatever the parent chose to pass down.
  # SYSTEM_INFO starts with the WORD wProcessorArchitecture; 64 bytes covers
  # the whole structure on every architecture.
  var info: array[64, byte]
  getNativeSystemInfo(addr info[0])
  case cast[ptr uint16](addr info[0])[]
  of 9: "x86_64"
  of 12: "arm64"
  of 5: "arm"
  of 0: "i686"
  else: ""

type
  OsVersionInfoW = object
    dwOSVersionInfoSize: uint32
    dwMajorVersion: uint32
    dwMinorVersion: uint32
    dwBuildNumber: uint32
    dwPlatformId: uint32
    szCSDVersion: array[128, uint16]

proc rtlGetVersion(info: ptr OsVersionInfoW): int32
  {.stdcall, dynlib: "ntdll.dll", importc: "RtlGetVersion".}

proc kernelVersion*(major, minor, build: var uint32): bool =
  ## `RtlGetVersion`, not `GetVersionEx`: the latter reports whatever the
  ## executable's manifest claims compatibility with, not the running kernel.
  var info = OsVersionInfoW(dwOSVersionInfoSize: uint32(sizeof(OsVersionInfoW)))
  if rtlGetVersion(addr info) != 0:
    return false
  major = info.dwMajorVersion
  minor = info.dwMinorVersion
  build = info.dwBuildNumber
  true

# ---------------------------------------------------------------------------
# Volumes and the disk under them
# ---------------------------------------------------------------------------

const
  DriveRemote = 4'u32
  FileShareReadWrite = 0x00000003'i32
  OpenExisting = 3'i32
  IoctlStorageQueryProperty = 0x002D1400'i32
  StorageDeviceProperty = 0'i32
  StorageDeviceSeekPenaltyProperty = 7'i32
  PropertyStandardQuery = 0'i32
  BusTypeNvme = 17'u32

proc getVolumePathNameW(path: WideCString; volume: ptr uint16;
                        length: uint32): WINBOOL
  {.stdcall, dynlib: "kernel32.dll", importc: "GetVolumePathNameW".}
proc getVolumeNameForVolumeMountPointW(mountPoint: WideCString;
                                       name: ptr uint16;
                                       length: uint32): WINBOOL
  {.stdcall, dynlib: "kernel32.dll",
    importc: "GetVolumeNameForVolumeMountPointW".}
proc getVolumeInformationW(root: WideCString; name: ptr uint16;
                           nameLength: uint32; serial, maxComponent,
                           flags: ptr uint32; fsName: ptr uint16;
                           fsNameLength: uint32): WINBOOL
  {.stdcall, dynlib: "kernel32.dll", importc: "GetVolumeInformationW".}
proc getDriveTypeW(root: WideCString): uint32
  {.stdcall, dynlib: "kernel32.dll", importc: "GetDriveTypeW".}
proc createFileW(name: WideCString; access, share: int32; security: pointer;
                 disposition, flags: int32; templateFile: Handle): Handle
  {.stdcall, dynlib: "kernel32.dll", importc: "CreateFileW".}
proc deviceIoControl(device: Handle; code: int32; input: pointer;
                     inputSize: int32; output: pointer; outputSize: int32;
                     returned: ptr int32; overlapped: pointer): WINBOOL
  {.stdcall, dynlib: "kernel32.dll", importc: "DeviceIoControl".}

type
  VolumeFacts* = object
    fsType*: string
      ## "NTFS", "ReFS", ...; "" when the volume would not say.
    remote*: bool
    solidState*: int
      ## 1: no seek penalty; 0: incurs one; -1: the disk would not say.
    nvme*: bool

  StoragePropertyQuery = object
    propertyId: int32
    queryType: int32
    additional: array[4, byte]

proc wideToString(buffer: openArray[uint16]): string =
  $cast[WideCString](unsafeAddr buffer[0])

proc volumeFacts*(path: string): VolumeFacts =
  ## What the volume holding ``path`` is and what it sits on. The volume is
  ## opened with NO access rights, which is what `IOCTL_STORAGE_QUERY_PROPERTY`
  ## needs and what an unprivileged daemon can do.
  result = VolumeFacts(fsType: "", remote: false, solidState: -1, nvme: false)
  var root: array[1024, uint16]
  if getVolumePathNameW(newWideCString(path), addr root[0],
      uint32(root.len)) == 0:
    return
  let rootWide = newWideCString(wideToString(root))
  result.remote = getDriveTypeW(rootWide) == DriveRemote
  var fsName: array[64, uint16]
  if getVolumeInformationW(rootWide, nil, 0, nil, nil, nil, addr fsName[0],
      uint32(fsName.len)) != 0:
    result.fsType = wideToString(fsName)
  if result.remote:
    return
  var volumeName: array[64, uint16]
  if getVolumeNameForVolumeMountPointW(rootWide, addr volumeName[0],
      uint32(volumeName.len)) == 0:
    return
  var device = wideToString(volumeName)
  # `\\?\Volume{...}\` names the volume's root DIRECTORY; the device is the
  # same name without the trailing separator.
  if device.endsWith("\\"):
    device.setLen(device.len - 1)
  let handle = createFileW(newWideCString(device), 0, FileShareReadWrite, nil,
    OpenExisting, 0, Handle(0))
  if handle == INVALID_HANDLE_VALUE:
    return
  defer: discard closeHandle(handle)

  var query = StoragePropertyQuery(propertyId: StorageDeviceSeekPenaltyProperty,
    queryType: PropertyStandardQuery)
  # DEVICE_SEEK_PENALTY_DESCRIPTOR: Version, Size, IncursSeekPenalty (BOOLEAN).
  var seek: array[12, byte]
  var returned = 0'i32
  if deviceIoControl(handle, IoctlStorageQueryProperty, addr query,
      int32(sizeof(query)), addr seek[0], int32(seek.len), addr returned,
      nil) != 0 and returned >= 9:
    result.solidState = if seek[8] == 0: 1 else: 0

  query.propertyId = StorageDeviceProperty
  # STORAGE_DEVICE_DESCRIPTOR: BusType is the 4-byte enum at offset 28.
  var descriptor: array[1024, byte]
  if deviceIoControl(handle, IoctlStorageQueryProperty, addr query,
      int32(sizeof(query)), addr descriptor[0], int32(descriptor.len),
      addr returned, nil) != 0 and returned >= 32:
    result.nvme = cast[ptr uint32](addr descriptor[28])[] == BusTypeNvme

# ---------------------------------------------------------------------------
# Performance counters (PDH)
# ---------------------------------------------------------------------------
#
# THREE HOST-WIDE FIGURES WINDOWS HAS NO OTHER DOCUMENTED SOURCE FOR, read
# through one PDH query opened once and kept for the life of the process:
#
# * `\Memory\Pages Input/sec`, whose RAW value is the cumulative count of
#   pages read from disk to resolve hard faults -- the closest Windows has to
#   Linux's `pswpin` and macOS's `swapins`. It is a SUPERSET of swap-in: a
#   hard fault on a memory-mapped file counts too, because Windows does not
#   separate the two.
# * `\PhysicalDisk(_Total)\Current Disk Queue Length`, requests outstanding
#   on every physical disk at the instant of collection -- the same quantity
#   as the Linux arm's in-flight sum over `/proc/diskstats`.
# * `\System\Processor Queue Length`, threads ready to run and waiting for a
#   processor, which the load average below is built from.
#
# One query, collected once per reading, under a lock: PDH query handles are
# not documented as safe for concurrent collection, and the reader is called
# from the sampler thread and from anything else that wants a reading.

type
  PdhRawCounter = object
    cStatus: uint32
    timeStamp: FILETIME
    firstValue: int64
    secondValue: int64
    multiCount: uint32

  PdhFmtCounterValueDouble = object
    cStatus: uint32
    padding: uint32
    doubleValue: float64

const
  PdhFmtDouble = 0x00000200'u32
  PdhFmtNoCap100 = 0x00008000'u32

proc pdhOpenQueryW(source: WideCString; userData: uint; query: ptr Handle):
    uint32 {.stdcall, dynlib: "pdh.dll", importc: "PdhOpenQueryW".}
proc pdhAddEnglishCounterW(query: Handle; path: WideCString; userData: uint;
                           counter: ptr Handle): uint32
  {.stdcall, dynlib: "pdh.dll", importc: "PdhAddEnglishCounterW".}
proc pdhCollectQueryData(query: Handle): uint32
  {.stdcall, dynlib: "pdh.dll", importc: "PdhCollectQueryData".}
proc pdhGetRawCounterValue(counter: Handle; kind: ptr uint32;
                           value: ptr PdhRawCounter): uint32
  {.stdcall, dynlib: "pdh.dll", importc: "PdhGetRawCounterValue".}
proc pdhGetFormattedCounterValue(counter: Handle; format: uint32;
                                 kind: ptr uint32;
                                 value: ptr PdhFmtCounterValueDouble): uint32
  {.stdcall, dynlib: "pdh.dll", importc: "PdhGetFormattedCounterValue".}

type
  CounterReading* = object
    pagesInputOk*: bool
    pagesInput*: int64
    diskQueueOk*: bool
    diskQueue*: float64
    readyThreadsOk*: bool
    readyThreads*: float64

var
  pdhLock: Lock
  pdhOpened = false
  pdhQuery: Handle
  pdhPagesInput: Handle
  pdhDiskQueue: Handle
  pdhReadyThreads: Handle

# Armed at module initialisation, before any thread exists -- the rule
# `t_lock_init_precedes_threads` pins for every lock in this library.
initLock(pdhLock)

proc openCounter(path: string; counter: var Handle): bool =
  pdhAddEnglishCounterW(pdhQuery, newWideCString(path), 0,
    addr counter) == 0

proc formatted(counter: Handle; value: var float64): bool =
  var kind = 0'u32
  var formattedValue: PdhFmtCounterValueDouble
  if pdhGetFormattedCounterValue(counter, PdhFmtDouble or PdhFmtNoCap100,
      addr kind, addr formattedValue) != 0:
    return false
  value = formattedValue.doubleValue
  true

proc readCounters*(): CounterReading =
  withLock pdhLock:
    if not pdhOpened:
      pdhOpened = true
      if pdhOpenQueryW(nil, 0, addr pdhQuery) != 0:
        pdhQuery = Handle(0)
      else:
        if not openCounter(r"\Memory\Pages Input/sec", pdhPagesInput):
          pdhPagesInput = Handle(0)
        if not openCounter(r"\PhysicalDisk(_Total)\Current Disk Queue Length",
            pdhDiskQueue):
          pdhDiskQueue = Handle(0)
        if not openCounter(r"\System\Processor Queue Length",
            pdhReadyThreads):
          pdhReadyThreads = Handle(0)
    if pdhQuery == Handle(0) or pdhCollectQueryData(pdhQuery) != 0:
      return
    if pdhPagesInput != Handle(0):
      var kind = 0'u32
      var raw: PdhRawCounter
      if pdhGetRawCounterValue(pdhPagesInput, addr kind, addr raw) == 0 and
          raw.firstValue >= 0:
        result.pagesInputOk = true
        result.pagesInput = raw.firstValue
    if pdhDiskQueue != Handle(0):
      result.diskQueueOk = formatted(pdhDiskQueue, result.diskQueue) and
        result.diskQueue >= 0.0
    if pdhReadyThreads != Handle(0):
      result.readyThreadsOk = formatted(pdhReadyThreads,
        result.readyThreads) and result.readyThreads >= 0.0

# ---------------------------------------------------------------------------
# The load average
# ---------------------------------------------------------------------------
#
# WINDOWS KEEPS NO LOAD AVERAGE, so this computes the one POSIX defines, from
# its definition: an exponentially damped average, with a one-minute time
# constant, of the number of threads that are RUNNING OR READY TO RUN. The
# running half is the busy processors over the interval since the previous
# reading (busy CPU time over elapsed time, both from `GetSystemTimes`); the
# ready half is `\System\Processor Queue Length`. The damping uses the real
# interval between readings, `exp(-dt / 60 s)`, so an irregular caller gets
# the same curve a fixed-cadence one does. (Linux also counts threads in
# uninterruptible sleep; Windows has no equivalent state to count.)
#
# The same emulation is what `psutil.getloadavg()` ships on Windows. Until
# the first interval exists the average is seeded with the since-boot busy
# processors plus the current ready queue, rather than with zero, because
# zero would read as an idle machine for the first minute of every daemon.

var
  loadLock: Lock
  loadSeeded = false
  loadValue = 0.0
  loadAtMillis = 0'i64
  loadBusyMillis = 0'i64

initLock(loadLock)

proc dampedLoadAverage*(nowMillis, busyMillis, totalMillis: int64;
                        logicalProcessors: int;
                        readyThreads: float64): float64 =
  withLock loadLock:
    if not loadSeeded:
      loadSeeded = true
      let busyFraction =
        if totalMillis > 0: float64(busyMillis) / float64(totalMillis)
        else: 0.0
      loadValue = busyFraction * float64(logicalProcessors) + readyThreads
    else:
      let elapsed = nowMillis - loadAtMillis
      let busyDelta = busyMillis - loadBusyMillis
      if elapsed > 0 and busyDelta >= 0:
        let running = float64(busyDelta) / float64(elapsed)
        let decay = exp(-float64(elapsed) / 60_000.0)
        loadValue = loadValue * decay + (running + readyThreads) *
          (1.0 - decay)
    loadAtMillis = nowMillis
    loadBusyMillis = busyMillis
    result = max(0.0, loadValue)
