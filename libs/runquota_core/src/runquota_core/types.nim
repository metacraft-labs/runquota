const DefaultMachineId* = "local"

type
  SessionId* = distinct uint64
  LeaseId* = distinct uint64
  MilliCpu* = distinct uint32
  Bytes* = distinct uint64
  DeadlineMillis* = distinct uint64
  MonotonicMillis* = distinct uint64

  IoClass* = enum
    ioNormal
    ioHeavy
    ioExclusive

  CaptureCompleteness* = enum
    ## Per-run and per-row honesty about whether the observation window is
    ## whole (OS-2). ``ccDegraded`` means observations were lost.
    ##
    ## HERE RATHER THAN IN THE STORE LIBRARY, and the move is load-bearing
    ## rather than tidiness. A standalone client — one running with no
    ## ``runquotad`` at all — has to be able to STATE that its window is
    ## incomplete, and it must do so without linking the observation store:
    ## `runquota_client` naming that library is a boundary violation the
    ## repository already checks by inspection
    ## (``tests/unit/t_observation_store_reader_boundary.nim``). Duplicating
    ## the enum on the client side would have been the other way out, and it
    ## would mean the verdict a client sends and the verdict a store records
    ## are two types that merely look alike.
    ##
    ## ``runquota_observation_store`` re-exports it, so every existing
    ## spelling still resolves.
    ccComplete = "complete"
    ccSampled = "sampled"
    ccDegraded = "degraded"

  PriorityClass* = enum
    priorityNormal
    priorityInteractive
    priorityBackground

  LeasePurpose* = enum
    leasePurposeWork
    leasePurposeBenchmark

  DeadlineKind* = enum
    deadlineNone
    deadlineTimeout
    deadlineAbsolute

  Deadline* = object
    kind*: DeadlineKind
    millis*: DeadlineMillis

  DiagnosticCode* = enum
    diagOk
    diagUnavailable
    diagUnsupportedVersion
    diagDenied
    diagCancelled
    diagProtocol
    diagInvalidArgument
    diagInternal

  MemoryLimitMode* = enum
    memoryLimitAdvisory
    memoryLimitEnforced

  MemoryPressureLevel* = enum
    pressureUnavailable
    pressureLow
    pressureWarning
    pressureCritical

  HostMemoryPressureSample* = object
    level*: MemoryPressureLevel
    available*: bool
    required*: bool
    source*: string
    diagnostic*: Diagnostic

  HostProcessTreeTelemetrySample* = object
    rootProcessId*: uint64
    rootAlive*: bool
    processCount*: uint32
    residentMemoryBytes*: uint64
    cpuTimeMicros*: uint64
    source*: string
    diagnostic*: Diagnostic

  Diagnostic* = object
    code*: DiagnosticCode
    message*: string
    detail*: string

  CapabilityRecord* = object
    protocolMajor*: uint16
    protocolMinor*: uint16
    platform*: string
    transport*: string
    maxFrameBytes*: uint32
    maxInflightRequests*: uint32
    cpuSlots*: MilliCpu
    memoryBytes*: Bytes
    hardMemoryLimitEnforced*: bool
    hardMemoryLimitMode*: MemoryLimitMode
    processTelemetry*: bool
    memoryPressureAvailable*: bool
    memoryPressureRequired*: bool

  NamedPoolDemand* = object
    name*: string
    units*: uint32

  ResourceVector* = object
    machineId*: string
    cpu*: MilliCpu
    memory*: Bytes
    hardMemoryLimit*: Bytes
    ioClass*: IoClass
    processCount*: uint32
    namedPools*: seq[NamedPoolDemand]

proc resourceVector*(cpu: MilliCpu; memory: Bytes): ResourceVector =
  ResourceVector(
    machineId: DefaultMachineId,
    cpu: cpu,
    memory: memory,
    hardMemoryLimit: Bytes(0),
    ioClass: ioNormal,
    processCount: 1'u32,
    namedPools: @[]
  )

proc namedPoolDemand*(name: string; units: SomeInteger): NamedPoolDemand =
  NamedPoolDemand(name: name, units: uint32(units))

proc withNamedPool*(resources: ResourceVector; name: string;
                    units: SomeInteger): ResourceVector =
  result = resources
  result.namedPools.add(namedPoolDemand(name, units))

proc forMachine*(resources: ResourceVector; machineId: string): ResourceVector =
  result = resources
  if machineId.len == 0:
    result.machineId = DefaultMachineId
  else:
    result.machineId = machineId

proc sessionId*(value: uint64): SessionId =
  SessionId(value)

proc leaseId*(value: uint64): LeaseId =
  LeaseId(value)

proc milliCpu*(value: SomeInteger): MilliCpu =
  MilliCpu(uint32(value))

proc bytes*(value: SomeInteger): Bytes =
  Bytes(uint64(value))

proc deadlineMillis*(value: SomeInteger): DeadlineMillis =
  DeadlineMillis(uint64(value))

proc monotonicMillis*(value: SomeInteger): MonotonicMillis =
  MonotonicMillis(uint64(value))

proc timeoutDeadline*(millis: DeadlineMillis): Deadline =
  Deadline(kind: deadlineTimeout, millis: millis)

proc noDeadline*(): Deadline =
  Deadline(kind: deadlineNone, millis: DeadlineMillis(0))

proc diagnostic*(code: DiagnosticCode; message: string;
    detail = ""): Diagnostic =
  Diagnostic(code: code, message: message, detail: detail)

proc okDiagnostic*(): Diagnostic =
  diagnostic(diagOk, "ok")

proc value*(id: SessionId): uint64 =
  uint64(id)

proc value*(id: LeaseId): uint64 =
  uint64(id)

proc value*(cpu: MilliCpu): uint32 =
  uint32(cpu)

proc value*(memory: Bytes): uint64 =
  uint64(memory)

proc value*(deadline: DeadlineMillis): uint64 =
  uint64(deadline)

proc value*(instant: MonotonicMillis): uint64 =
  uint64(instant)

proc `$`*(id: SessionId): string =
  $uint64(id)

proc `$`*(id: LeaseId): string =
  $uint64(id)
