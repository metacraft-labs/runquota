import runquota_core
import runquota_codec

type
  LibraryInfo* = object
    name*: string

  RqspMessageKind* = enum
    rqHello = 1
    rqHelloOk = 2
    rqRegisterSession = 3
    rqSessionRegistered = 4
    rqCloseSession = 5
    rqSessionClosed = 6
    rqRequestLease = 7
    rqLeaseGranted = 8
    rqLeaseDenied = 9
    rqReleaseLease = 10
    rqLeaseReleased = 11
    rqStatusRequest = 12
    rqStatusResponse = 13
    rqError = 14

  MessageKind* = RqspMessageKind

  FrameHeader* = object
    version*: uint16
    headerLen*: uint16
    messageKind*: RqspMessageKind
    flags*: uint16
    requestId*: uint64
    payloadLen*: uint32

  RqspFrame* = object
    header*: FrameHeader
    payload*: string

  FlowControlLimits* = object
    maxInflightRequests*: uint32
    maxFrameBytes*: uint32
    maxCandidatesPerBatch*: uint32
    maxLeaseDecisionsPerBatch*: uint32

  HelloMessage* = object
    clientName*: string
    clientVersion*: string
    minProtocolMajor*: uint16
    maxProtocolMajor*: uint16
    processId*: uint64
    userId*: uint64
    desiredCapabilities*: string

  HelloOkMessage* = object
    selectedProtocolMajor*: uint16
    selectedProtocolMinor*: uint16
    daemonId*: uint64
    daemonVersion*: string
    capabilities*: CapabilityRecord
    flow*: FlowControlLimits

  RegisterSessionMessage* = object
    name*: string
    version*: string
    metadata*: DynamicMetadata

  SessionRegisteredMessage* = object
    sessionId*: SessionId

  CloseSessionMessage* = object
    sessionId*: SessionId

  SessionClosedMessage* = object
    sessionId*: SessionId

  LeaseRequestMessage* = object
    sessionId*: SessionId
    label*: string
    commandStatsId*: string
    resources*: ResourceVector
    deadline*: Deadline
    priority*: PriorityClass
    metadata*: DynamicMetadata

  LeaseGrantedMessage* = object
    sessionId*: SessionId
    leaseId*: LeaseId
    resources*: ResourceVector

  LeaseDeniedMessage* = object
    sessionId*: SessionId
    diagnostic*: Diagnostic

  ReleaseLeaseMessage* = object
    sessionId*: SessionId
    leaseId*: LeaseId

  LeaseReleasedMessage* = object
    sessionId*: SessionId
    leaseId*: LeaseId

  DaemonStatusMessage* = object
    activeSessions*: uint32
    activeLeases*: uint32
    totalGranted*: uint64

  ProtocolErrorMessage* = object
    diagnostic*: Diagnostic

  CompatibilityResult* = object
    compatible*: bool
    selectedMajor*: uint16
    selectedMinor*: uint16
    diagnostic*: Diagnostic
