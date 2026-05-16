import runquota_core
import runquota_host/types

export types

const libraryName* = "runquota_host"

proc libraryInfo*(): LibraryInfo =
  LibraryInfo(name: libraryName)

proc unavailablePressureSample*(source: string; required = false;
                                detail = ""): HostMemoryPressureSample =
  HostMemoryPressureSample(
    level: pressureUnavailable,
    available: false,
    required: required,
    source: source,
    diagnostic: diagnostic(diagUnavailable, "host memory pressure unavailable", detail)
  )

proc lowPressureSample*(source: string; required = false): HostMemoryPressureSample =
  HostMemoryPressureSample(
    level: pressureLow,
    available: true,
    required: required,
    source: source,
    diagnostic: okDiagnostic()
  )

proc unavailableProcessTreeTelemetrySample*(source: string; rootProcessId: uint64;
                                            detail = ""): HostProcessTreeTelemetrySample =
  HostProcessTreeTelemetrySample(
    rootProcessId: rootProcessId,
    rootAlive: false,
    processCount: 0'u32,
    residentMemoryBytes: 0'u64,
    cpuTimeMicros: 0'u64,
    source: source,
    diagnostic: diagnostic(diagUnavailable, "host process telemetry unavailable", detail)
  )
