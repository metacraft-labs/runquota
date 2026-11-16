when defined(macosx):
  import std/sets

import runquota_core
import runquota_host

const TelemetrySource = "macos-libproc"

when defined(macosx):
  const
    ProcPidTBsdInfo = 3.cint
    ProcPidTaskInfo = 4.cint
    RusageFlavorV2 = 2.cint
      ## `RUSAGE_INFO_V2` of `<sys/resource.h>`. Its leading fields are
      ## V1's, which added the reaped-children times (`ri_child_*`).
    MaxChildListAttempts = 8
    MaxTreeProcesses = 65536
      ## A bound on one walk, so a fork bomb cannot make the walk itself
      ## unbounded; the sample then covers the processes visited.

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

    RusageInfoV2 {.importc: "struct rusage_info_v2",
                    header: "<sys/resource.h>", bycopy.} = object
      ri_user_time {.importc.}: uint64
      ri_system_time {.importc.}: uint64
      ri_child_user_time {.importc.}: uint64
      ri_child_system_time {.importc.}: uint64

    MachTimebaseInfoData {.importc: "mach_timebase_info_data_t",
                            header: "<mach/mach_time.h>", bycopy.} = object
      numer {.importc.}: uint32
      denom {.importc.}: uint32

    MacosProcessIdentity = object
      pid: uint64
      ppid: uint64
      startSeconds: uint64
      startMicroseconds: uint64

  proc procPidInfo(pid, flavor: cint; arg: uint64; buffer: pointer;
                   bufferSize: cint): cint {.
    importc: "proc_pidinfo", header: "<libproc.h>".}

  proc procListChildPids(parent: DarwinPid; buffer: pointer;
                         bufferSize: cint): cint {.
    importc: "proc_listchildpids", header: "<libproc.h>".}
    ## Returns the NUMBER of child pids written (not bytes), or -1.

  proc procPidRusage(pid, flavor: cint; buffer: pointer): cint {.
    importc: "proc_pid_rusage", header: "<libproc.h>".}

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

  proc childPids(parent: DarwinPid; children: var seq[DarwinPid]) =
    ## Appends the direct children of `parent`. The buffer is grown until
    ## the answer fits: a full buffer means the list may be truncated.
    var capacity = 32
    for _ in 0 ..< MaxChildListAttempts:
      var pids = newSeq[DarwinPid](capacity)
      let count = procListChildPids(parent, addr pids[0],
        cint(pids.len * sizeof(DarwinPid)))
      if count < 0:
        return
      if int(count) < capacity:
        for index in 0 ..< int(count):
          if pids[index] > 0:
            children.add(pids[index])
        return
      capacity *= 4

  proc treeIdentities(rootProcessId: DarwinPid): seq[MacosProcessIdentity] =
    ## The processes of the tree under `rootProcessId` (the root included),
    ## breadth first through `proc_listchildpids`. One cheap call per tree
    ## member, NOT a snapshot of every process on the host: on a busy
    ## machine that snapshot is thousands of `proc_pidinfo` calls per
    ## reading. Empty when the root is not there.
    var root: MacosProcessIdentity
    if not readIdentity(rootProcessId, root):
      return
    var queue = @[rootProcessId]
    var seen = initHashSet[uint64]()
    seen.incl(uint64(rootProcessId))
    result.add(root)
    var index = 0
    while index < queue.len and result.len < MaxTreeProcesses:
      var children: seq[DarwinPid] = @[]
      childPids(queue[index], children)
      inc index
      for child in children:
        if uint64(child) in seen:
          continue
        seen.incl(uint64(child))
        var identity: MacosProcessIdentity
        if readIdentity(child, identity):
          result.add(identity)
          queue.add(child)

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
                   cpuTimeMicros, cumulativeMicros: var uint64;
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

    # Own plus reaped descendants (`ri_child_*`): the macOS counterpart of
    # `utime + stime + cutime + cstime` in Linux's /proc/<pid>/stat, which is
    # what makes a reading of the tree not fall when a process exits and is
    # reaped inside it. Also in Mach absolute-time ticks. A process whose
    # rusage cannot be read (it exited meanwhile) is skipped like one whose
    # task info cannot.
    var usage: RusageInfoV2
    if procPidRusage(pid, RusageFlavorV2, addr usage) != 0.cint:
      return false
    var cumulativeTicks = usage.ri_user_time
    cumulativeTicks.checkedAdd(usage.ri_system_time)
    cumulativeTicks.checkedAdd(usage.ri_child_user_time)
    cumulativeTicks.checkedAdd(usage.ri_child_system_time)
    cumulativeMicros = absoluteTimeMicros(cumulativeTicks, timebase)
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

    let tree = treeIdentities(DarwinPid(rootProcessId))
    if tree.len == 0:
      let detail = "root process is not present in libproc"
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
    var cumulativeMicros = 0'u64
    var timebase: MachTimebaseInfoData
    if machTimebaseInfo(addr timebase) != 0.cint or timebase.denom == 0'u32:
      return unavailableProcessTreeTelemetrySample(
        TelemetrySource,
        rootProcessId,
        "the Mach absolute-time conversion is unavailable"
      )
    for row in tree:
      var rowResidentBytes, rowCpuTimeMicros, rowCumulativeMicros: uint64
      if readMetrics(row, rowResidentBytes, rowCpuTimeMicros,
                     rowCumulativeMicros, timebase):
        residentMemoryBytes.checkedAdd(rowResidentBytes)
        cpuTimeMicros.checkedAdd(rowCpuTimeMicros)
        cumulativeMicros.checkedAdd(rowCumulativeMicros)

    HostProcessTreeTelemetrySample(
      rootProcessId: rootProcessId,
      rootAlive: true,
      processCount: uint32(tree.len),
      residentMemoryBytes: residentMemoryBytes,
      cpuTimeMicros: cpuTimeMicros,
      cumulativeCpuTimeMicros: cumulativeMicros,
      cumulativeCpuKnown: true,
      source: TelemetrySource,
      diagnostic: okDiagnostic()
    )
  else:
    unavailableProcessTreeTelemetrySample(
      TelemetrySource,
      rootProcessId,
      "backend is only active on macOS"
    )
