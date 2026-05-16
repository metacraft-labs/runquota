import std/[osproc, sets, strutils]

import runquota_core
import runquota_host
import runquota_host_macos/types as macosTypes

export macosTypes

const libraryName* = "runquota_host_macos"

proc libraryInfo*(): macosTypes.LibraryInfo =
  macosTypes.LibraryInfo(name: libraryName)

type
  MacosProcessRow = object
    pid: uint64
    ppid: uint64
    residentKilobytes: uint64
    cpuTimeMicros: uint64

proc parseSecondMicros(raw: string): uint64 =
  let parts = raw.split(".", 1)
  result = parseUInt(parts[0]) * 1_000_000'u64
  if parts.len == 2:
    var fraction = parts[1]
    if fraction.len > 6:
      fraction = fraction[0 ..< 6]
    while fraction.len < 6:
      fraction.add('0')
    if fraction.len > 0:
      result += parseUInt(fraction)

proc parseCpuTimeMicros(raw: string): uint64 =
  var days = 0'u64
  var clock = raw
  if raw.contains("-"):
    let dayParts = raw.split("-", 1)
    days = parseUInt(dayParts[0])
    clock = dayParts[1]
  let parts = clock.split(":")
  var hours = 0'u64
  var minutes = 0'u64
  var secondsMicros = 0'u64
  case parts.len
  of 2:
    minutes = parseUInt(parts[0])
    secondsMicros = parseSecondMicros(parts[1])
  of 3:
    hours = parseUInt(parts[0])
    minutes = parseUInt(parts[1])
    secondsMicros = parseSecondMicros(parts[2])
  else:
    return 0'u64
  (((days * 24'u64 + hours) * 60'u64 + minutes) * 60'u64 * 1_000_000'u64) +
    secondsMicros

proc parseProcessRows(output: string): seq[MacosProcessRow] =
  for line in output.splitLines():
    let parts = line.splitWhitespace()
    if parts.len < 4:
      continue
    try:
      result.add(MacosProcessRow(
        pid: parseUInt(parts[0]),
        ppid: parseUInt(parts[1]),
        residentKilobytes: parseUInt(parts[2]),
        cpuTimeMicros: parseCpuTimeMicros(parts[3])
      ))
    except ValueError:
      discard

proc collectTreePids(rows: openArray[MacosProcessRow]; rootProcessId: uint64): HashSet[uint64] =
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

proc sampleMacosMemoryPressure*(required = false): HostMemoryPressureSample =
  when defined(macosx):
    try:
      let output = execProcess("/usr/bin/memory_pressure", args = ["-Q"], options = {poUsePath})
      let lower = output.toLowerAscii()
      if lower.contains("critical"):
        return HostMemoryPressureSample(
          level: pressureCritical,
          available: true,
          required: required,
          source: "macos-memory_pressure",
          diagnostic: diagnostic(diagDenied, "host memory pressure is critical", output.strip())
        )
      if lower.contains("warn"):
        return HostMemoryPressureSample(
          level: pressureWarning,
          available: true,
          required: required,
          source: "macos-memory_pressure",
          diagnostic: diagnostic(diagDenied, "host memory pressure is warning", output.strip())
        )
      lowPressureSample("macos-memory_pressure", required)
    except CatchableError as error:
      unavailablePressureSample("macos-memory_pressure", required, error.msg)
  else:
    unavailablePressureSample("macos-memory_pressure", required, "backend is only active on macOS")

proc sampleMacosProcessTreeTelemetry*(rootProcessId: uint64): HostProcessTreeTelemetrySample =
  when defined(macosx):
    if rootProcessId == 0'u64:
      return unavailableProcessTreeTelemetrySample(
        "macos-ps",
        rootProcessId,
        "root process id is zero"
      )
    try:
      let output = execProcess(
        "/bin/ps",
        args = ["-axo", "pid=,ppid=,rss=,time="],
        options = {poUsePath}
      )
      let rows = parseProcessRows(output)
      let treePids = collectTreePids(rows, rootProcessId)
      var residentKilobytes = 0'u64
      var cpuTimeMicros = 0'u64
      for row in rows:
        if row.pid in treePids:
          residentKilobytes += row.residentKilobytes
          cpuTimeMicros += row.cpuTimeMicros
      if treePids.len == 0:
        return HostProcessTreeTelemetrySample(
          rootProcessId: rootProcessId,
          rootAlive: false,
          processCount: 0'u32,
          residentMemoryBytes: 0'u64,
          cpuTimeMicros: 0'u64,
          source: "macos-ps",
          diagnostic: diagnostic(
            diagUnavailable,
            "host process telemetry unavailable",
            "root process is not present in ps output"
          )
        )
      HostProcessTreeTelemetrySample(
        rootProcessId: rootProcessId,
        rootAlive: true,
        processCount: uint32(treePids.len),
        residentMemoryBytes: residentKilobytes * 1024'u64,
        cpuTimeMicros: cpuTimeMicros,
        source: "macos-ps",
        diagnostic: okDiagnostic()
      )
    except CatchableError as error:
      unavailableProcessTreeTelemetrySample("macos-ps", rootProcessId, error.msg)
  else:
    unavailableProcessTreeTelemetrySample(
      "macos-ps",
      rootProcessId,
      "backend is only active on macOS"
    )
