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
    rqLeaseObservation = 26
    rqStatsQuery = 27
    rqStatsResponse = 28

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

  ClientEstimate* = object
    ## What the CLIENT already believes this work costs, carried with the
    ## request so that admission needs no round trip at the moment of
    ## asking.
    ##
    ## ``supplied`` is a separate field rather than "zero means absent"
    ## because zero is a legitimate estimate and because the whole point of
    ## the field is to distinguish two daemon behaviours: a supplied
    ## estimate is used UNMODIFIED, and the daemon's own learned table is
    ## the FALLBACK WHEN NONE IS SUPPLIED rather than a check on one that
    ## is. A sentinel would have made "none was supplied" unstatable, and
    ## with it the rule.
    ##
    ## The daemon MUST NOT clamp, second-guess, or validate ``memoryBytes``
    ## against its own table. The client may have got it from its own cache
    ## or from the published aggregate table; RunQuota expresses no opinion
    ## about that cache, and the trust is sound because a client that
    ## under-declares spends its OWN user's budget.
    supplied*: bool
    memoryBytes*: uint64

  LeaseRequestMessage* = object
    sessionId*: SessionId
    label*: string
    commandStatsId*: string
    resources*: ResourceVector
    deadline*: Deadline
    priority*: PriorityClass
    purpose*: LeasePurpose
    metadata*: DynamicMetadata
    estimate*: ClientEstimate

  LeaseCandidate* = object
    clientCandidateId*: uint64
    label*: string
    commandStatsId*: string
    resources*: ResourceVector
    deadline*: Deadline
    priority*: PriorityClass
    purpose*: LeasePurpose
    metadata*: DynamicMetadata
    estimate*: ClientEstimate

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

  LeaseObservationMessage* = object
    ## What a client has MEASURED about one of its own live executions,
    ## while that execution is still running.
    ##
    ## THIS IS THE MESSAGE THAT MAKES ``self_*`` MEAN ANYTHING. Ambient
    ## attribution is by difference — ``foreign = host_total - sum(self)``
    ## — and the daemon deliberately never inspects a client's process
    ## tree, so without an in-flight figure from the client every admitted
    ## execution lands in ``foreign`` and ``self_*`` is a column of zeros.
    ##
    ## MEASURED, never reserved. The figures must come from the client's
    ## own telemetry of its child (``runquota_process`` already samples
    ## exactly this while it waits), never from the lease's requested
    ## resources: a reservation is a number nobody measured, and writing
    ## one here would put an invention into the store this design exists to
    ## keep out of it.
    ##
    ## ONE-WAY: the daemon sends no acknowledgement, so a client pays one
    ## buffered write and no round trip (OS-1, and §"Write Path": "No
    ## observation may introduce an additional round trip").
    sessionId*: SessionId
    leaseId*: LeaseId
    cpuMilliPct*: uint32
      ## Thousandths of one percent of a whole host's CPU capacity, so a
      ## fully busy 16-core box reads 1_600_000. An integer because the
      ## codec has no float and a float on the wire would need an encoding,
      ## a NaN rule and an endianness rule for a quantity that needs none.
    rssBytes*: uint64
    sampledAtUnixMillis*: uint64
      ## When the client took the reading. Carried so a stale report is
      ## recognisable as stale rather than being silently folded in as
      ## current; the daemon refuses one from the future.

  # -------------------------------------------------------------------------
  # The read path (M13a). ARBITRARY READS GO OVER THE SOCKET, never on the
  # observation ring: the ring is a one-way MPSC write path and a read is
  # request/response with a variable-size result. The one read with a
  # latency budget is the admission estimate, and it is served from the
  # published aggregate table instead (M13b).
  #
  # These are WIRE types, deliberately distinct from the store's own query
  # types even though they mirror them. `runquota_client` must be able to
  # ask a question without linking the observation store at all -- that is
  # what makes "runquotad is the only sanctioned reader" enforceable rather
  # than merely intended.
  # -------------------------------------------------------------------------

  StatsSubject* = enum
    ## The two consumers, differing in AGGREGATION rather than in
    ## mechanism: one interface, one set of filters, one transport.
    statsSubjectDistribution = 0
      ## Admission: a resource distribution over a stats key.
    statsSubjectExecutions = 1
      ## Human and agent surfaces: rows.
    statsSubjectRanking = 2
      ## Human and agent surfaces: a ranking.
    statsSubjectExtensionRows = 3
      ## Product-owned extension rows, for the executions the same scope
      ## and span rules select. RunQuota carries the payload and does not
      ## interpret it (OS-5): the caller names the extension and the
      ## columns, and gets text back.

  StatsScopeWire* = enum
    ## Whose rows. Mirrors ``runquota_observation_store.StatsScope``; the
    ## daemon asserts the two agree.
    statsScopeWireOwner = 0
    statsScopeWireHost = 1

  ProfileSpanWire* = enum
    profileSpanWireSingle = 0
    profileSpanWireAll = 1

  StatsKnowledgeWire* = enum
    statsKnowledgeWireUnknown = 0
    statsKnowledgeWireKnown = 1

  StatsQueryMessage* = object
    sessionId*: SessionId
    subject*: StatsSubject
    statsKey*: string
      ## OPAQUE TO RUNQUOTA. It stores and matches the key; it does not
      ## interpret or derive it. Empty means "every key".
    scope*: StatsScopeWire
      ## Widening to the whole host is EXPLICIT and must be available -- a
      ## CI administrator asking "what is slow on this machine" is a real
      ## question. The narrow value is the default, and the uid it narrows
      ## to is NOT in this message: it comes from peer credentials.
    span*: ProfileSpanWire
    limit*: uint32
    extensionId*: string
      ## Only meaningful for ``statsSubjectExtensionRows``.
    extensionColumns*: seq[string]
      ## The columns the CALLER wants. RunQuota checks them for being
      ## storable identifiers and for nothing else; it does not know what
      ## any of them mean.

  ProfileIdentityWire* = object
    hostId*: string
    profileIdPresent*: bool
    profileId*: string
    profileHash*: string
    cpuModel*: string
    logicalCores*: uint64

  ResourceDistributionWire* = object
    profile*: ProfileIdentityWire
    knowledge*: StatsKnowledgeWire
    sampleCount*: uint64
    durationMillisMin*: uint64
    durationMillisP50*: uint64
    durationMillisP90*: uint64
    durationMillisMax*: uint64
    peakRssBytesMax*: uint64

  ExecutionSummaryWire* = object
    executionId*: string
    statsKey*: string
    profile*: ProfileIdentityWire
    ownerUidPresent*: bool
    ownerUid*: uint64
    startedAtUnixMillis*: uint64
    durationMillis*: uint64
    peakRssBytes*: uint64
    exitStatus*: uint64
    termination*: string

  ExtensionRowWire* = object
    hostId*: string
    executionId*: string
    statsKey*: string
    profile*: ProfileIdentityWire
    ownerUidPresent*: bool
    ownerUid*: uint64
    columns*: seq[string]
    values*: seq[string]
      ## Opaque text, one per column, in the order of ``columns``. SQL NULL
      ## arrives as the store's null marker so it stays distinguishable
      ## from the empty string.

  KeyRankingWire* = object
    statsKey*: string
    profile*: ProfileIdentityWire
    sampleCount*: uint64
    totalDurationMillis*: uint64
    maxDurationMillis*: uint64

  StatsResponseMessage* = object
    subject*: StatsSubject
    statsKey*: string
    knowledge*: StatsKnowledgeWire
      ## ``statsKnowledgeWireUnknown`` is NOT "zero". A key with three
      ## zero-duration executions answers KNOWN with zeros; a key with no
      ## history answers UNKNOWN. Callers treat unknown as "use the
      ## declared or default estimate" -- what they would have done before
      ## the store existed.
    scopeApplied*: StatsScopeWire
      ## What the daemon ACTUALLY scoped to, which is not always what was
      ## asked: the estimate path is host-wide by design and says so here
      ## rather than silently.
    spanApplied*: ProfileSpanWire
    ownerUidPresent*: bool
    ownerUid*: uint64
      ## The uid the answer was scoped to, from peer credentials. Absent on
      ## a host-wide answer.
    captureEnabled*: bool
    distributions*: seq[ResourceDistributionWire]
    executions*: seq[ExecutionSummaryWire]
    rankings*: seq[KeyRankingWire]
    extensionRows*: seq[ExtensionRowWire]
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
