import std/[osproc, strutils]

import runquota_core
import runquota_host
import runquota_host_macos/types as macosTypes
import runquota_host_macos/process_telemetry

export macosTypes

const libraryName* = "runquota_host_macos"

proc libraryInfo*(): macosTypes.LibraryInfo =
  macosTypes.LibraryInfo(name: libraryName)

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
  sampleMacosProcessTreeTelemetryNative(rootProcessId)
