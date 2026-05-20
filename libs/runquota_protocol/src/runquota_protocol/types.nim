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
    rqLeaseStarting = 15
    rqLeaseStartingAck = 16
    rqLeaseRunning = 17
    rqLeaseRunningAck = 18
    rqLeaseFinished = 19
    rqLeaseFinishedAck = 20
    rqOfferCandidates = 21
    rqLeaseDecisionBatch = 22
    rqGrantNext = 23
    rqInspectionRequest = 24
    rqInspectionResponse = 25

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
    purpose*: LeasePurpose
    metadata*: DynamicMetadata

  LeaseCandidate* = object
    clientCandidateId*: uint64
    label*: string
    commandStatsId*: string
    resources*: ResourceVector
    deadline*: Deadline
    priority*: PriorityClass
    purpose*: LeasePurpose
    metadata*: DynamicMetadata

  CandidateOfferMessage* = object
    sessionId*: SessionId
    candidates*: seq[LeaseCandidate]

  LeaseDecisionKind* = enum
    leaseDecisionQueued
    leaseDecisionGranted
    leaseDecisionDenied

  LeaseDecision* = object
    clientCandidateId*: uint64
    leaseId*: LeaseId
    kind*: LeaseDecisionKind
    resources*: ResourceVector
    diagnostic*: Diagnostic

  LeaseDecisionBatchMessage* = object
    sessionId*: SessionId
    decisions*: seq[LeaseDecision]

  GrantNextMessage* = object
    sessionId*: SessionId

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

  LeaseStartingMessage* = object
    sessionId*: SessionId
    leaseId*: LeaseId

  LeaseStartingAckMessage* = object
    sessionId*: SessionId
    leaseId*: LeaseId

  LeaseRunningMessage* = object
    sessionId*: SessionId
    leaseId*: LeaseId
    childProcessId*: uint64
    processGroupId*: uint64
    cleanupRegistered*: bool

  LeaseRunningAckMessage* = object
    sessionId*: SessionId
    leaseId*: LeaseId

  LeaseFinishOutcome* = enum
    leaseFinishSucceeded
    leaseFinishFailed
    leaseFinishCrashed
    leaseFinishResourceLimit
    leaseFinishCancelled
    leaseFinishLaunchFailed

  LeaseFinishedMessage* = object
    sessionId*: SessionId
    leaseId*: LeaseId
    outcome*: LeaseFinishOutcome
    exitCode*: uint32
    signal*: uint32
    peakMemoryBytes*: uint64
    processCount*: uint32
    majorPageFaults*: uint64
    pressureEvents*: uint32
    hardLimitOrOom*: bool
    diagnostic*: Diagnostic

  LeaseFinishedAckMessage* = object
    sessionId*: SessionId
    leaseId*: LeaseId

  DaemonStatusMessage* = object
    activeSessions*: uint32
    activeLeases*: uint32
    queuedLeases*: uint32
    supervisorLostLeases*: uint32
    finishedLeases*: uint32
    totalGranted*: uint64
    totalFinished*: uint64

  ProtocolErrorMessage* = object
    diagnostic*: Diagnostic

  InspectionRequestMessage* = object
    subject*: string
    sessionId*: SessionId

  InspectionResponseMessage* = object
    json*: string

  CompatibilityResult* = object
    compatible*: bool
    selectedMajor*: uint16
    selectedMinor*: uint16
    diagnostic*: Diagnostic
