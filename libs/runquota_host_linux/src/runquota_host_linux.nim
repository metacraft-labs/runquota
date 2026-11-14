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

  # THE TREE WALK IS THE LAUNCHING CLIENT'S HOT PATH. It runs every
  # tree-sampling interval of every supervised command, so its cost is
  # counted against the measurement budget, and it is kept to what a sample
  # needs:
  #
  # * ONE READ OF `/proc/<pid>/stat` PER PROCESS, into a stack buffer, parsed
  #   in place: no file object, no size probe, no split into a sequence of
  #   strings.
  # * ONE READ OF ITS CHILDREN. `/proc/<pid>/task/<tid>/children` lists the
  #   children of ONE THREAD (proc(5)), so a multi-threaded process's
  #   children are spread over its threads' files. The stat line carries
  #   the thread count; a single-threaded process -- nearly every process
  #   in a build tree -- has its children read from its one thread's file
  #   directly, without listing `task/`. Only a multi-threaded one has its
  #   threads listed and each file read.
  # * The clock-tick and page sizes are read once, not once per process.
  #
  # So a single-threaded process costs two small reads (open, read, close,
  # twice), where it used to cost a buffered whole-file read of `stat`, a
  # directory listing of `task/` and a buffered read of each thread's
  # `children`.

  type
    LinuxProcessRow = object
      pid: uint64
      ppid: uint64
      threads: int64
      residentMemoryBytes: uint64
      cpuTimeMicros: uint64
      cumulativeCpuTimeMicros: uint64
        ## utime + stime + cutime + cstime: this process and every
        ## descendant it has reaped (proc(5), fields 14-17).

  let
    clockTicksPerSecond = max(1'u64, uint64(sysconf(SC_CLK_TCK)))
    pageSizeBytes = max(1'u64, uint64(sysconf(SC_PAGESIZE)))

  proc procRoot(): string =
    getEnv("RUNQUOTA_PROC_ROOT", "/proc")

  proc parseMeminfoBytes(path, key: string): uint64 =
    for line in readFile(path).splitLines():
      let parts = line.splitWhitespace()
      if parts.len >= 2 and parts[0] == key & ":":
        return parseUInt(parts[1]) * 1024'u64

  proc ticksToMicros(ticks: uint64): uint64 =
    (ticks * 1_000_000'u64) div clockTicksPerSecond

  const procReadCapacity = 4096

  proc readSmallFile(path: string; buffer: var array[procReadCapacity, char];
                     length: var int): bool =
    ## Reads up to ``procReadCapacity`` bytes of ``path`` into ``buffer``.
    ## A procfs file of this size is produced in one ``read``; a second one
    ## is made only if the first filled the buffer partly and more remains.
    let fd = posix.open(cstring(path), O_RDONLY or O_CLOEXEC)
    if fd < 0:
      return false
    length = 0
    while length < procReadCapacity:
      let n = posix.read(fd, addr buffer[length], procReadCapacity - length)
      if n < 0:
        if errno == EINTR:
          continue
        discard posix.close(fd)
        return false
      if n == 0:
        break
      length += n
    discard posix.close(fd)
    true

  proc parseProcessStat(pid: uint64; content: openArray[char];
                        row: var LinuxProcessRow): bool =
    ## proc(5) `stat`: the command name is in parentheses and may itself
    ## hold spaces and parentheses, so the fields are counted from the LAST
    ## ')'. Field numbers below are proc(5)'s, 1-based.
    var closeParen = -1
    for i in countdown(content.len - 1, 0):
      if content[i] == ')':
        closeParen = i
        break
    if closeParen < 0:
      return false
    var field = 2    # the ')' ends field 2
    var i = closeParen + 1
    var values: array[24, int64]   # field N at index N - 1, up to field 24
    while i < content.len and field < 24:
      while i < content.len and content[i] in {' ', '\n'}:
        inc i
      if i >= content.len:
        break
      inc field
      var negative = false
      var number = 0'i64
      if content[i] == '-':
        negative = true
        inc i
      while i < content.len and content[i] in {'0' .. '9'}:
        number = number * 10 + int64(ord(content[i]) - ord('0'))
        inc i
      while i < content.len and content[i] notin {' ', '\n'}:
        inc i   # field 3, the state letter, is not a number
      values[field - 1] = if negative: -number else: number
    if field < 24:
      return false
    let rssPages = values[23]
    let utime = uint64(max(0'i64, values[13]))
    let stime = uint64(max(0'i64, values[14]))
    # cutime and cstime are signed in proc(5) (`%ld`); a negative value
    # never occurs for a reaped child's time, but is read as zero rather
    # than wrapping.
    let cutime = uint64(max(0'i64, values[15]))
    let cstime = uint64(max(0'i64, values[16]))
    row = LinuxProcessRow(
      pid: pid,
      ppid: uint64(max(0'i64, values[3])),
      threads: max(1'i64, values[19]),
      residentMemoryBytes:
        if rssPages > 0: uint64(rssPages) * pageSizeBytes else: 0'u64,
      cpuTimeMicros: ticksToMicros(utime + stime),
      cumulativeCpuTimeMicros: ticksToMicros(utime + stime + cutime + cstime))
    true

  proc parseProcessStat(pid: uint64; content: string;
                        row: var LinuxProcessRow): bool =
    parseProcessStat(pid, content.toOpenArray(0, content.len - 1), row)

  proc readProcessRow(root: string; pid: uint64;
                      row: var LinuxProcessRow): bool =
    var buffer: array[procReadCapacity, char]
    var length = 0
    if not readSmallFile(root & "/" & $pid & "/stat", buffer, length):
      return false
    parseProcessStat(pid, buffer.toOpenArray(0, length - 1), row)

  proc readChildrenFile(path: string; children: var seq[uint64]) =
    ## Appends the pids `path` lists. A `children` file longer than the
    ## buffer (hundreds of direct children) is read whole the slow way, so a
    ## wide fan-out is never truncated.
    var buffer: array[procReadCapacity, char]
    var length = 0
    if not readSmallFile(path, buffer, length):
      return
    if length >= procReadCapacity:
      try:
        for child in readFile(path).splitWhitespace():
          try:
            children.add(parseUInt(child))
          except ValueError:
            discard
      except CatchableError:
        discard
      return
    var number = 0'u64
    var digits = false
    for i in 0 ..< length:
      let c = buffer[i]
      if c in {'0' .. '9'}:
        number = number * 10 + uint64(ord(c) - ord('0'))
        digits = true
      else:
        if digits:
          children.add(number)
        number = 0
        digits = false
    if digits:
      children.add(number)

  proc readChildProcessIds(root: string; row: LinuxProcessRow;
                           children: var seq[uint64]) =
    let taskRoot = root & "/" & $row.pid & "/task"
    if row.threads <= 1:
      readChildrenFile(taskRoot & "/" & $row.pid & "/children", children)
      return
    var readTaskChildren = false
    try:
      for kind, path in walkDir(taskRoot):
        if kind != pcDir:
          continue
        let name = splitPath(path).tail
        if name.len == 0 or not name.allCharsInSet(Digits):
          continue
        readTaskChildren = true
        readChildrenFile(path & "/children", children)
    except CatchableError:
      discard
    if not readTaskChildren:
      readChildrenFile(taskRoot & "/" & $row.pid & "/children", children)

  type
    TreeTotals = object
      processes: int
      residentBytes: uint64
      cpuMicros: uint64
      cumulativeMicros: uint64

  proc processTreeRows(root: string; rootProcessId: uint64): TreeTotals =
    ## Walks the tree under ``rootProcessId`` breadth first and sums it.
    ## Nothing per process is kept beyond the queue of pids still to visit.
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
      inc result.processes
      result.residentBytes += row.residentMemoryBytes
      result.cpuMicros += row.cpuTimeMicros
      result.cumulativeMicros += row.cumulativeCpuTimeMicros
      readChildProcessIds(root, row, queue)

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
      let totals = processTreeRows(procRoot(), rootProcessId)
      if totals.processes == 0:
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
      HostProcessTreeTelemetrySample(
        rootProcessId: rootProcessId,
        rootAlive: true,
        processCount: uint32(totals.processes),
        residentMemoryBytes: totals.residentBytes,
        cpuTimeMicros: totals.cpuMicros,
        cumulativeCpuTimeMicros: totals.cumulativeMicros,
        cumulativeCpuKnown: true,
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
