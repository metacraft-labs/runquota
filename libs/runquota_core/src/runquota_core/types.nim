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

  PriorityClass* = enum
    priorityNormal
    priorityInteractive
    priorityBackground

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
    processTelemetry*: bool

  NamedPoolDemand* = object
    name*: string
    units*: uint32

  ResourceVector* = object
    cpu*: MilliCpu
    memory*: Bytes
    hardMemoryLimit*: Bytes
    ioClass*: IoClass
    processCount*: uint32
    namedPools*: seq[NamedPoolDemand]

proc resourceVector*(cpu: MilliCpu; memory: Bytes): ResourceVector =
  ResourceVector(
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

proc diagnostic*(code: DiagnosticCode; message: string; detail = ""): Diagnostic =
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
