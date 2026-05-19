import std/sets

import runquota_core
import runquota_host
import runquota_host_windows/types as windowsTypes

export windowsTypes

const libraryName* = "runquota_host_windows"

proc libraryInfo*(): windowsTypes.LibraryInfo =
  windowsTypes.LibraryInfo(name: libraryName)

when defined(windows):
  # Windows: pull the Win32 surface we need directly. winlean exposes Handle /
  # WINBOOL but not the memory-pressure or toolhelp APIs we need.
  import std/winlean

  type
    MEMORYSTATUSEX = object
      dwLength: int32
      dwMemoryLoad: int32
      ullTotalPhys: uint64
      ullAvailPhys: uint64
      ullTotalPageFile: uint64
      ullAvailPageFile: uint64
      ullTotalVirtual: uint64
      ullAvailVirtual: uint64
      ullAvailExtendedVirtual: uint64

    # Windows: PROCESS_MEMORY_COUNTERS layout per psapi.h. WorkingSetSize is
    # the resident set (physical pages mapped to the process).
    PROCESS_MEMORY_COUNTERS = object
      cb: int32
      PageFaultCount: int32
      PeakWorkingSetSize: uint
      WorkingSetSize: uint
      QuotaPeakPagedPoolUsage: uint
      QuotaPagedPoolUsage: uint
      QuotaPeakNonPagedPoolUsage: uint
      QuotaNonPagedPoolUsage: uint
      PagefileUsage: uint
      PeakPagefileUsage: uint

    # Windows: PROCESSENTRY32W layout per tlhelp32.h. szExeFile must be a
    # MAX_PATH-sized buffer or Process32FirstW returns ERROR_INSUFFICIENT_BUFFER.
    PROCESSENTRY32W = object
      dwSize: int32
      cntUsage: int32
      th32ProcessID: int32
      th32DefaultHeapID: uint
      th32ModuleID: int32
      cntThreads: int32
      th32ParentProcessID: int32
      pcPriClassBase: int32
      dwFlags: int32
      szExeFile: array[260, Utf16Char]

    # Windows: 100-ns ticks from FILETIME used for accumulating CPU time. Each
    # tick = 100 ns; 10 ticks = 1 microsecond.
    FILETIME = object
      dwLowDateTime: int32
      dwHighDateTime: int32

  const
    # Windows: TH32CS_SNAPPROCESS = 0x00000002 — snapshot all processes.
    TH32CS_SNAPPROCESS = 0x00000002'i32
    # Windows: PROCESS_QUERY_LIMITED_INFORMATION (0x1000) is enough for memory
    # info and works for processes we don't own. Falls back to QUERY_INFORMATION
    # (0x0400) if the limited variant is unavailable on very old hosts.
    PROCESS_QUERY_LIMITED_INFORMATION = 0x1000'i32
    PROCESS_VM_READ = 0x0010'i32

  proc globalMemoryStatusEx(
    lpBuffer: ptr MEMORYSTATUSEX
  ): WINBOOL {.stdcall, dynlib: "kernel32.dll", importc: "GlobalMemoryStatusEx".}

  proc createToolhelp32Snapshot(
    dwFlags: int32; th32ProcessID: int32
  ): Handle {.stdcall, dynlib: "kernel32.dll", importc: "CreateToolhelp32Snapshot".}

  proc process32FirstW(
    hSnapshot: Handle; lppe: ptr PROCESSENTRY32W
  ): WINBOOL {.stdcall, dynlib: "kernel32.dll", importc: "Process32FirstW".}

  proc process32NextW(
    hSnapshot: Handle; lppe: ptr PROCESSENTRY32W
  ): WINBOOL {.stdcall, dynlib: "kernel32.dll", importc: "Process32NextW".}

  proc openProcess(
    dwDesiredAccess: int32; bInheritHandle: WINBOOL; dwProcessId: int32
  ): Handle {.stdcall, dynlib: "kernel32.dll", importc: "OpenProcess".}

  # Windows: K32GetProcessMemoryInfo lives in kernel32.dll on Win7+. The legacy
  # psapi.dll forwarder still works but kernel32 avoids a load-time dep.
  proc k32GetProcessMemoryInfo(
    hProcess: Handle; ppsmemCounters: ptr PROCESS_MEMORY_COUNTERS;
    cb: int32
  ): WINBOOL {.stdcall, dynlib: "kernel32.dll", importc: "K32GetProcessMemoryInfo".}

  proc getProcessTimes(
    hProcess: Handle; lpCreationTime, lpExitTime, lpKernelTime,
    lpUserTime: ptr FILETIME
  ): WINBOOL {.stdcall, dynlib: "kernel32.dll", importc: "GetProcessTimes".}

  proc snapshotMemoryStatus(): tuple[ok: bool; status: MEMORYSTATUSEX] =
    # Windows: GlobalMemoryStatusEx requires dwLength = sizeof(MEMORYSTATUSEX)
    # before the call so it can validate the struct version.
    result.status.dwLength = int32(sizeof(MEMORYSTATUSEX))
    result.ok = globalMemoryStatusEx(addr result.status) != 0

  proc filetimeMicros(ft: FILETIME): uint64 =
    # Windows: a FILETIME 100-ns tick is 0.1 microseconds. We avoid the 64-bit
    # union trick from MS samples and reconstruct manually.
    let high = uint64(uint32(ft.dwHighDateTime))
    let low = uint64(uint32(ft.dwLowDateTime))
    ((high shl 32) or low) div 10'u64

  iterator processSnapshot(): PROCESSENTRY32W =
    # Windows: ownership of the snapshot handle is local to this iterator so we
    # always close it even if the consumer breaks out early.
    let snapshot = createToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0'i32)
    if snapshot != Handle(-1) and snapshot != 0:
      try:
        var entry: PROCESSENTRY32W
        entry.dwSize = int32(sizeof(PROCESSENTRY32W))
        if process32FirstW(snapshot, addr entry) != 0:
          while true:
            yield entry
            entry.dwSize = int32(sizeof(PROCESSENTRY32W))
            if process32NextW(snapshot, addr entry) == 0:
              break
      finally:
        discard closeHandle(snapshot)

  proc collectTreePids(rootProcessId: uint64): HashSet[uint64] =
    # Windows: build a PID -> PPID map then BFS from rootProcessId. We do two
    # passes so we don't depend on Toolhelp32 enumeration order.
    result = initHashSet[uint64]()
    if rootProcessId == 0:
      return
    var rows: seq[(uint64, uint64)] = @[]
    var sawRoot = false
    for entry in processSnapshot():
      let pid = uint64(uint32(entry.th32ProcessID))
      let ppid = uint64(uint32(entry.th32ParentProcessID))
      rows.add((pid, ppid))
      if pid == rootProcessId:
        sawRoot = true
    if not sawRoot:
      return
    result.incl(rootProcessId)
    var changed = true
    while changed:
      changed = false
      for row in rows:
        let pid = row[0]
        let ppid = row[1]
        if pid notin result and ppid in result:
          result.incl(pid)
          changed = true

  proc openProcessForQuery(pid: uint64): Handle =
    # Windows: prefer PROCESS_QUERY_LIMITED_INFORMATION (Vista+, doesn't need
    # SeDebugPrivilege) plus PROCESS_VM_READ which K32GetProcessMemoryInfo
    # requires. If that fails (e.g., protected process), return 0 and treat as
    # zero RSS rather than erroring the whole sample.
    openProcess(
      PROCESS_QUERY_LIMITED_INFORMATION or PROCESS_VM_READ,
      WINBOOL(0),
      int32(uint32(pid))
    )

  proc sampleWindowsMemoryPressure*(required = false): HostMemoryPressureSample =
    # Windows: GlobalMemoryStatusEx returns dwMemoryLoad as percent of physical
    # memory in use. We map thresholds to the runquota pressure enum so the
    # daemon's pressure gating works the same way as on macOS:
    #   <70%  -> pressureLow
    #   70-85 -> pressureWarning
    #   >85   -> pressureCritical
    # These thresholds match the conservative end of what the Windows MMPL
    # (Memory Management Performance Library) considers "low" / "very low".
    let probe = snapshotMemoryStatus()
    if not probe.ok:
      return unavailablePressureSample(
        "windows-GlobalMemoryStatusEx",
        required,
        "GlobalMemoryStatusEx failed"
      )
    let load = uint32(probe.status.dwMemoryLoad)
    let detail = "dwMemoryLoad=" & $load & "% availPhys=" &
      $probe.status.ullAvailPhys & " totalPhys=" & $probe.status.ullTotalPhys
    if load > 85'u32:
      return HostMemoryPressureSample(
        level: pressureCritical,
        available: true,
        required: required,
        source: "windows-GlobalMemoryStatusEx",
        diagnostic: diagnostic(diagDenied, "host memory pressure is critical", detail)
      )
    if load >= 70'u32:
      return HostMemoryPressureSample(
        level: pressureWarning,
        available: true,
        required: required,
        source: "windows-GlobalMemoryStatusEx",
        diagnostic: diagnostic(diagDenied, "host memory pressure is warning", detail)
      )
    HostMemoryPressureSample(
      level: pressureLow,
      available: true,
      required: required,
      source: "windows-GlobalMemoryStatusEx",
      diagnostic: okDiagnostic()
    )

  proc sampleWindowsProcessTreeTelemetry*(rootProcessId: uint64): HostProcessTreeTelemetrySample =
    # Windows: enumerate processes via Toolhelp32, build the parent/child tree
    # rooted at rootProcessId, then sum WorkingSetSize and CPU time across the
    # tree. Mirrors sampleMacosProcessTreeTelemetry's contract: rootAlive=false
    # if the root PID is not present in the snapshot.
    if rootProcessId == 0'u64:
      return unavailableProcessTreeTelemetrySample(
        "windows-toolhelp32",
        rootProcessId,
        "root process id is zero"
      )
    let treePids = collectTreePids(rootProcessId)
    if treePids.len == 0:
      return HostProcessTreeTelemetrySample(
        rootProcessId: rootProcessId,
        rootAlive: false,
        processCount: 0'u32,
        residentMemoryBytes: 0'u64,
        cpuTimeMicros: 0'u64,
        source: "windows-toolhelp32",
        diagnostic: diagnostic(
          diagUnavailable,
          "host process telemetry unavailable",
          "root process is not present in toolhelp32 snapshot"
        )
      )
    var residentBytes = 0'u64
    var cpuMicros = 0'u64
    for pid in treePids:
      let handle = openProcessForQuery(pid)
      if handle == 0:
        # Windows: process may have just exited or be protected; skip it but
        # still count it toward processCount since it was in the snapshot.
        continue
      try:
        var counters: PROCESS_MEMORY_COUNTERS
        counters.cb = int32(sizeof(PROCESS_MEMORY_COUNTERS))
        if k32GetProcessMemoryInfo(handle, addr counters,
            int32(sizeof(PROCESS_MEMORY_COUNTERS))) != 0:
          residentBytes += uint64(counters.WorkingSetSize)
        var creation, exitT, kernelT, userT: FILETIME
        if getProcessTimes(handle, addr creation, addr exitT,
            addr kernelT, addr userT) != 0:
          cpuMicros += filetimeMicros(kernelT) + filetimeMicros(userT)
      finally:
        discard closeHandle(handle)
    HostProcessTreeTelemetrySample(
      rootProcessId: rootProcessId,
      rootAlive: true,
      processCount: uint32(treePids.len),
      residentMemoryBytes: residentBytes,
      cpuTimeMicros: cpuMicros,
      source: "windows-toolhelp32",
      diagnostic: okDiagnostic()
    )

  proc currentMemoryAvailable*(): uint64 =
    # Windows: convenience wrapper for telemetry consumers that just want raw
    # available physical bytes without the pressure-level mapping.
    let probe = snapshotMemoryStatus()
    if probe.ok: probe.status.ullAvailPhys else: 0'u64

  proc totalMemory*(): uint64 =
    let probe = snapshotMemoryStatus()
    if probe.ok: probe.status.ullTotalPhys else: 0'u64

else:
  # Windows: when this module is imported on a non-Windows build (for code that
  # uses `when defined(windows):` gates at call sites but still needs to type-
  # check on all platforms) the procs degrade to the unavailable sentinel.
  proc sampleWindowsMemoryPressure*(required = false): HostMemoryPressureSample =
    unavailablePressureSample(
      "windows-GlobalMemoryStatusEx",
      required,
      "backend is only active on Windows"
    )

  proc sampleWindowsProcessTreeTelemetry*(rootProcessId: uint64): HostProcessTreeTelemetrySample =
    unavailableProcessTreeTelemetrySample(
      "windows-toolhelp32",
      rootProcessId,
      "backend is only active on Windows"
    )

  proc currentMemoryAvailable*(): uint64 = 0'u64
  proc totalMemory*(): uint64 = 0'u64
