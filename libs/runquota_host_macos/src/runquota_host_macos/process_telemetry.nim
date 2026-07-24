when defined(macosx):
  import std/sets

import runquota_core
import runquota_host

const TelemetrySource = "macos-libproc"

when defined(macosx):
  const
    ProcAllPids = 1'u32
    ProcPidTBsdInfo = 3.cint
    ProcPidTaskInfo = 4.cint
    PidGrowthMargin = 64
    MaxPidListAttempts = 4

  type
    DarwinPid = int32

    ProcBsdInfo {.importc: "struct proc_bsdinfo",
                   header: "<sys/proc_info.h>", bycopy.} = object
      pbi_pid {.importc.}: uint32
      pbi_ppid {.importc.}: uint32
      pbi_start_tvsec {.importc.}: uint64
      pbi_start_tvusec {.importc.}: uint64

    ProcTaskInfo {.importc: "struct proc_taskinfo",
                    header: "<sys/proc_info.h>", bycopy.} = object
      pti_resident_size {.importc.}: uint64
      pti_total_user {.importc.}: uint64
      pti_total_system {.importc.}: uint64

    MachTimebaseInfoData {.importc: "mach_timebase_info_data_t",
                            header: "<mach/mach_time.h>", bycopy.} = object
      numer {.importc.}: uint32
      denom {.importc.}: uint32

    MacosProcessIdentity = object
      pid: uint64
      ppid: uint64
      startSeconds: uint64
      startMicroseconds: uint64

  proc procListPids(kind, kindInfo: uint32; buffer: pointer;
                    bufferSize: cint): cint {.
    importc: "proc_listpids", header: "<libproc.h>".}

  proc procPidInfo(pid, flavor: cint; arg: uint64; buffer: pointer;
                   bufferSize: cint): cint {.
    importc: "proc_pidinfo", header: "<libproc.h>".}

  proc machTimebaseInfo(info: ptr MachTimebaseInfoData): cint {.
    importc: "mach_timebase_info", header: "<mach/mach_time.h>".}

  proc readIdentity(pid: DarwinPid; identity: var MacosProcessIdentity): bool =
    var info: ProcBsdInfo
    let bytes = procPidInfo(
      pid,
      ProcPidTBsdInfo,
      0'u64,
      addr info,
      cint(sizeof(info))
    )
    if bytes != cint(sizeof(info)) or info.pbi_pid != uint32(pid):
      return false
    identity = MacosProcessIdentity(
      pid: uint64(info.pbi_pid),
      ppid: uint64(info.pbi_ppid),
      startSeconds: info.pbi_start_tvsec,
      startMicroseconds: info.pbi_start_tvusec
    )
    true

  proc sameProcess(left, right: MacosProcessIdentity): bool =
    left.pid == right.pid and
      left.startSeconds == right.startSeconds and
      left.startMicroseconds == right.startMicroseconds

  proc processIdentities(): tuple[rows: seq[MacosProcessIdentity];
                                  detail: string] =
    let queriedBytes = procListPids(ProcAllPids, 0'u32, nil, 0.cint)
    if queriedBytes <= 0:
      return (@[], "libproc could not size the process list")

    let pidBytes = sizeof(DarwinPid)
    var capacity = (int(queriedBytes) + pidBytes - 1) div pidBytes
    capacity += PidGrowthMargin
    for _ in 0 ..< MaxPidListAttempts:
      var pids = newSeq[DarwinPid](capacity)
      let returnedBytes = procListPids(
        ProcAllPids,
        0'u32,
        addr pids[0],
        cint(pids.len * pidBytes)
      )
      if returnedBytes < 0:
        return (@[], "libproc could not enumerate processes")
      if int(returnedBytes) < pids.len * pidBytes:
        let returnedCount = int(returnedBytes) div pidBytes
        var seen = initHashSet[uint64]()
        for index in 0 ..< returnedCount:
          let pid = pids[index]
          if pid <= 0:
            continue
          var identity: MacosProcessIdentity
          if readIdentity(pid, identity) and identity.pid notin seen:
            result.rows.add(identity)
            seen.incl(identity.pid)
        return
      capacity = capacity * 2

    result.detail = "the process list kept growing during the bounded snapshot"

  proc collectTreePids(rows: openArray[MacosProcessIdentity];
                       rootProcessId: uint64): HashSet[uint64] =
    result = initHashSet[uint64]()
    for row in rows:
      if row.pid == rootProcessId:
        result.incl(rootProcessId)
        break
    var changed = true
    while changed:
      changed = false
      for row in rows:
        if row.pid notin result and row.ppid in result:
          result.incl(row.pid)
          changed = true

  proc checkedAdd(total: var uint64; value: uint64) =
    if value > high(uint64) - total:
      total = high(uint64)
    else:
      total += value

  proc absoluteTimeMicros(ticks: uint64;
                          timebase: MachTimebaseInfoData): uint64 =
    if timebase.numer == 0'u32 or timebase.denom == 0'u32:
      return 0'u64
    let denominator = uint64(timebase.denom)
    let numerator = uint64(timebase.numer)
    let whole = ticks div denominator
    let remainder = ticks mod denominator
    var nanoseconds: uint64
    if whole > high(uint64) div numerator:
      nanoseconds = high(uint64)
    else:
      nanoseconds = whole * numerator
      nanoseconds.checkedAdd((remainder * numerator) div denominator)
    nanoseconds div 1_000'u64

  proc readMetrics(identity: MacosProcessIdentity; residentBytes,
                   cpuTimeMicros: var uint64;
                   timebase: MachTimebaseInfoData): bool =
    if identity.pid > uint64(high(DarwinPid)):
      return false
    let pid = DarwinPid(identity.pid)
    var before, after: MacosProcessIdentity
    if not readIdentity(pid, before) or not sameProcess(identity, before):
      return false

    var task: ProcTaskInfo
    let bytes = procPidInfo(
      pid,
      ProcPidTaskInfo,
      0'u64,
      addr task,
      cint(sizeof(task))
    )
    if bytes != cint(sizeof(task)):
      return false
    if not readIdentity(pid, after) or not sameProcess(identity, after):
      return false

    residentBytes = task.pti_resident_size
    # XNU fills proc_taskinfo's CPU fields with Mach absolute-time ticks.
    # Convert through the running kernel's timebase before exposing the host
    # API's microsecond unit.
    var cpuTimeTicks = task.pti_total_user
    cpuTimeTicks.checkedAdd(task.pti_total_system)
    cpuTimeMicros = absoluteTimeMicros(cpuTimeTicks, timebase)
    true

proc sampleMacosProcessTreeTelemetryNative*(
    rootProcessId: uint64): HostProcessTreeTelemetrySample =
  when defined(macosx):
    if rootProcessId == 0'u64 or rootProcessId > uint64(high(DarwinPid)):
      return unavailableProcessTreeTelemetrySample(
        TelemetrySource,
        rootProcessId,
        "root process id is outside the Darwin PID range"
      )

    let snapshot = processIdentities()
    let treePids = collectTreePids(snapshot.rows, rootProcessId)
    if treePids.len == 0:
      let detail =
        if snapshot.detail.len > 0:
          snapshot.detail
        else:
          "root process is not present in the libproc snapshot"
      return HostProcessTreeTelemetrySample(
        rootProcessId: rootProcessId,
        rootAlive: false,
        processCount: 0'u32,
        residentMemoryBytes: 0'u64,
        cpuTimeMicros: 0'u64,
        source: TelemetrySource,
        diagnostic: diagnostic(
          diagUnavailable,
          "host process telemetry unavailable",
          detail
        )
      )

    var residentMemoryBytes = 0'u64
    var cpuTimeMicros = 0'u64
    var timebase: MachTimebaseInfoData
    if machTimebaseInfo(addr timebase) != 0.cint or timebase.denom == 0'u32:
      return unavailableProcessTreeTelemetrySample(
        TelemetrySource,
        rootProcessId,
        "the Mach absolute-time conversion is unavailable"
      )
    for row in snapshot.rows:
      if row.pid in treePids:
        var rowResidentBytes, rowCpuTimeMicros: uint64
        if readMetrics(row, rowResidentBytes, rowCpuTimeMicros, timebase):
          residentMemoryBytes.checkedAdd(rowResidentBytes)
          cpuTimeMicros.checkedAdd(rowCpuTimeMicros)

    HostProcessTreeTelemetrySample(
      rootProcessId: rootProcessId,
      rootAlive: true,
      processCount: uint32(treePids.len),
      residentMemoryBytes: residentMemoryBytes,
      cpuTimeMicros: cpuTimeMicros,
      source: TelemetrySource,
      diagnostic: okDiagnostic()
    )
  else:
    unavailableProcessTreeTelemetrySample(
      TelemetrySource,
      rootProcessId,
      "backend is only active on macOS"
    )
