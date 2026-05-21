import std/[os, sets, strutils]

import runquota_core
import runquota_host
import runquota_host_linux/types as linuxTypes

export linuxTypes

const libraryName* = "runquota_host_linux"

proc libraryInfo*(): linuxTypes.LibraryInfo =
  linuxTypes.LibraryInfo(name: libraryName)

when defined(linux):
  import std/posix

  type
    LinuxProcessRow = object
      pid: uint64
      ppid: uint64
      residentMemoryBytes: uint64
      cpuTimeMicros: uint64

  proc procRoot(): string =
    getEnv("RUNQUOTA_PROC_ROOT", "/proc")

  proc parseMeminfoBytes(path, key: string): uint64 =
    for line in readFile(path).splitLines():
      let parts = line.splitWhitespace()
      if parts.len >= 2 and parts[0] == key & ":":
        return parseUInt(parts[1]) * 1024'u64

  proc ticksToMicros(ticks: uint64): uint64 =
    let ticksPerSecond = max(1, int(sysconf(SC_CLK_TCK)))
    (ticks * 1_000_000'u64) div uint64(ticksPerSecond)

  proc parseProcessStat(pid: uint64; content: string;
                        row: var LinuxProcessRow): bool =
    let closeParen = content.rfind(")")
    if closeParen < 0 or closeParen + 2 >= content.len:
      return false
    let fields = content[(closeParen + 2) .. ^1].splitWhitespace()
    if fields.len < 22:
      return false
    let rssPages = parseBiggestInt(fields[21])
    row = LinuxProcessRow(
      pid: pid,
      ppid: parseUInt(fields[1]),
      residentMemoryBytes:
        if rssPages > 0: uint64(rssPages) * uint64(sysconf(SC_PAGESIZE)) else: 0'u64,
      cpuTimeMicros: ticksToMicros(parseUInt(fields[11]) + parseUInt(fields[12]))
    )
    true

  proc readProcessRow(root: string; pid: uint64;
                      row: var LinuxProcessRow): bool =
    try:
      parseProcessStat(pid, readFile(root / $pid / "stat"), row)
    except CatchableError:
      false

  proc readChildrenFile(path: string; children: var HashSet[uint64]) =
    try:
      for child in readFile(path).splitWhitespace():
        try:
          children.incl(parseUInt(child))
        except ValueError:
          discard
    except CatchableError:
      discard

  proc readChildProcessIds(root: string; pid: uint64): HashSet[uint64] =
    let taskRoot = root / $pid / "task"
    var readTaskChildren = false
    try:
      for kind, path in walkDir(taskRoot):
        if kind != pcDir:
          continue
        let name = splitPath(path).tail
        if name.len == 0 or not name.allCharsInSet(Digits):
          continue
        readTaskChildren = true
        readChildrenFile(path / "children", result)
    except CatchableError:
      discard
    if not readTaskChildren:
      readChildrenFile(taskRoot / $pid / "children", result)

  proc processTreeRows(root: string; rootProcessId: uint64): seq[LinuxProcessRow] =
    var queue = @[rootProcessId]
    var seen = initHashSet[uint64]()
    var index = 0
    while index < queue.len:
      let pid = queue[index]
      inc index
      if pid in seen:
        continue
      seen.incl(pid)
      var row: LinuxProcessRow
      if not readProcessRow(root, pid, row):
        continue
      result.add(row)
      for child in readChildProcessIds(root, pid):
        if child notin seen:
          queue.add(child)

  proc sampleLinuxMemoryPressure*(required = false): HostMemoryPressureSample =
    try:
      let meminfoPath = procRoot() / "meminfo"
      let total = parseMeminfoBytes(meminfoPath, "MemTotal")
      let available = parseMeminfoBytes(meminfoPath, "MemAvailable")
      if total == 0'u64 or available == 0'u64:
        return unavailablePressureSample(
          "linux-proc-meminfo",
          required,
          "MemTotal or MemAvailable is missing"
        )
      let usedPermille = ((total - min(total, available)) * 1000'u64) div total
      let detail = "MemAvailable=" & $available & " MemTotal=" & $total
      if usedPermille > 850'u64:
        return HostMemoryPressureSample(
          level: pressureCritical,
          available: true,
          required: required,
          source: "linux-proc-meminfo",
          diagnostic: diagnostic(diagDenied, "host memory pressure is critical", detail)
        )
      if usedPermille >= 700'u64:
        return HostMemoryPressureSample(
          level: pressureWarning,
          available: true,
          required: required,
          source: "linux-proc-meminfo",
          diagnostic: diagnostic(diagDenied, "host memory pressure is warning", detail)
        )
      lowPressureSample("linux-proc-meminfo", required)
    except CatchableError as error:
      unavailablePressureSample("linux-proc-meminfo", required, error.msg)

  proc sampleLinuxProcessTreeTelemetry*(rootProcessId: uint64): HostProcessTreeTelemetrySample =
    if rootProcessId == 0'u64:
      return unavailableProcessTreeTelemetrySample(
        "linux-procfs",
        rootProcessId,
        "root process id is zero"
      )
    try:
      let rows = processTreeRows(procRoot(), rootProcessId)
      if rows.len == 0:
        return HostProcessTreeTelemetrySample(
          rootProcessId: rootProcessId,
          rootAlive: false,
          processCount: 0'u32,
          residentMemoryBytes: 0'u64,
          cpuTimeMicros: 0'u64,
          source: "linux-procfs",
          diagnostic: diagnostic(
            diagUnavailable,
            "host process telemetry unavailable",
            "root process is not present in procfs"
          )
        )
      var residentBytes = 0'u64
      var cpuMicros = 0'u64
      for row in rows:
        residentBytes += row.residentMemoryBytes
        cpuMicros += row.cpuTimeMicros
      HostProcessTreeTelemetrySample(
        rootProcessId: rootProcessId,
        rootAlive: true,
        processCount: uint32(rows.len),
        residentMemoryBytes: residentBytes,
        cpuTimeMicros: cpuMicros,
        source: "linux-procfs",
        diagnostic: okDiagnostic()
      )
    except CatchableError as error:
      unavailableProcessTreeTelemetrySample("linux-procfs", rootProcessId, error.msg)

  proc currentMemoryAvailable*(): uint64 =
    try: parseMeminfoBytes(procRoot() / "meminfo", "MemAvailable")
    except CatchableError: 0'u64

  proc totalMemory*(): uint64 =
    try: parseMeminfoBytes(procRoot() / "meminfo", "MemTotal")
    except CatchableError: 0'u64

else:
  proc sampleLinuxMemoryPressure*(required = false): HostMemoryPressureSample =
    unavailablePressureSample(
      "linux-proc-meminfo",
      required,
      "backend is only active on Linux"
    )

  proc sampleLinuxProcessTreeTelemetry*(rootProcessId: uint64): HostProcessTreeTelemetrySample =
    unavailableProcessTreeTelemetrySample(
      "linux-procfs",
      rootProcessId,
      "backend is only active on Linux"
    )

  proc currentMemoryAvailable*(): uint64 = 0'u64
  proc totalMemory*(): uint64 = 0'u64
