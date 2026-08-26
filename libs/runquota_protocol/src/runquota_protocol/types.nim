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
    rqDeferredObservations = 29
    rqDeclareExtension = 30
    rqExtensionDeclared = 31
    rqExtensionRow = 32

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

  KillEvidence* = object
    ## What a supervisor SAW when it says a process was killed.
    ##
    ## A KILL CLAIM WITHOUT EVIDENCE IS THE STATE THIS TYPE ABOLISHES.
    ## ``reprobuild-specs/RunQuota-Observation-Store.md`` §"The Execution
    ## Spine" says a row MUST NOT carry a termination its other columns
    ## contradict, and the pair that cannot both be true is a kill beside
    ## exit status 0 with no signal: the kill says the supervisor ENDED
    ## this process, the clean exit says it ended of its own accord and
    ## succeeded. That row is immutable (OS-3) and unfalsifiable, and no
    ## later reader can tell it from a measurement.
    ##
    ## A VARIANT RATHER THAN TWO INTEGERS, so the state is not refused but
    ## ABSENT. Two independent fields make "both zero" statable, and
    ## anything statable eventually gets stated; one field per arm makes
    ## the conjunction impossible to write down. The remaining hole --
    ## naming an arm and leaving its single integer at zero -- is closed
    ## by ``killedBySignal``/``killedWithExitCode``, which are the only
    ## way to name one and refuse zero.
    ##
    ## SIGNAL AND EXIT STATUS ARE STILL BOTH ACCEPTABLE EVIDENCE. A
    ## supervisor on POSIX that reaped its child knows the signal; one
    ## that only holds a status integer (Windows, or a wrapper that
    ## reports 128+N) knows the exit code. Either falsifies the claim,
    ## which is all the spine asks for.
    case bySignal*: bool
    of true:
      signal*: uint32
    of false:
      exitCode*: uint32

  LeaseFinishKind* = enum
    ## The CONCLUSION a supervising client reached about its own
    ## execution. Each arm of ``LeaseFinish`` carries exactly the evidence
    ## its conclusion requires and nothing else.
    ##
    ## ``lfTimedOut`` IS HERE BECAUSE THE SPINE HAS NOWHERE ELSE TO LEARN
    ## IT. The observation store's ``termination`` column names ``timeout``
    ## as one of its five kinds, and no other member could produce it: a
    ## deadline is a POLICY THE CLIENT HOLDS, RunQuota imposes none, and
    ## every fact that reaches the daemon about a timed-out execution -- a
    ## non-zero exit, a kill signal -- is indistinguishable from an
    ## ordinary kill. Without this member a timed-out execution landed on
    ## the spine as ``signalled``, which is true and useless.
    lfSucceeded
    lfFailed
    lfCrashed
    lfOomKilled
    lfCancelled
    lfLaunchFailed
    lfTimedOut

  LeaseFinish* = object
    ## Why an execution ended, as the supervising client saw it, together
    ## with the evidence for it.
    ##
    ## ONE FIELD NAMES THE CONCLUSION. It replaced four independently
    ## settable ones -- an outcome enum, an exit code, a signal and an
    ## ``hardLimitOrOom`` flag -- whose combinations included states that
    ## cannot be true, and which the daemon therefore had to refuse at
    ## runtime. The refusals are gone because the states are: a defect
    ## that has no representation needs no handling.
    ##
    ## ``lfSucceeded`` CARRIES NOTHING, which is the whole of the second
    ## impossible state. A finish that says the work succeeded cannot also
    ## hand over a kill's evidence or a non-zero exit, because there is no
    ## field to put one in.
    ##
    ## ``lfFailed`` AND ``lfCrashed`` CARRY DIFFERENT THINGS ON PURPOSE. A
    ## process that died of a signal has no exit status at all, so
    ## ``lfCrashed`` names the signal and the spine records ``exit_status
    ## = 0`` meaning "not applicable"; a process that returned a status
    ## names it, and the constructor refuses zero because "failed with
    ## exit status 0" is the same contradiction in a smaller costume.
    case kind*: LeaseFinishKind
    of lfSucceeded:
      discard
    of lfFailed:
      exitCode*: uint32
    of lfCrashed:
      crashSignal*: uint32
    of lfOomKilled, lfTimedOut:
      kill*: KillEvidence
    of lfCancelled, lfLaunchFailed:
      discard

  LeaseFinishedMessage* = object
    sessionId*: SessionId
    leaseId*: LeaseId
    finish*: LeaseFinish
    peakMemoryBytes*: uint64
    processCount*: uint32
    majorPageFaults*: uint64
    pressureEvents*: uint32
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

  DeferredExecutionRecord* = object
    ## One execution a client ran with NO DAEMON TO ASK, buffered in
    ## memory at the time and carried here afterwards.
    ##
    ## There is no ``leaseId``: nothing granted this execution, and
    ## inventing one would put a lease into the store that no admission
    ## decision ever made.
    label*: string
    commandStatsId*: string
    startedAtUnixMillis*: uint64
    finishedAtUnixMillis*: uint64
    finish*: LeaseFinish
    peakRssBytes*: uint64
    processCount*: uint32
    majorPageFaults*: uint64

  DeferredObservationsMessage* = object
    ## THE SINGLE BEST-EFFORT FLUSH a long-lived standalone client makes
    ## when it exits, and the only way an execution that ran without a
    ## lease can ever reach the store.
    ##
    ## §"Standalone mode": without a daemon, observations are buffered in
    ## memory; a long-lived client MAY make one best-effort flush at exit
    ## and a short-lived one drops them. This message is that flush. It
    ## exists so the flush stays on the SOCKET — a client that wrote the
    ## store itself to compensate for a missing daemon is precisely what
    ## the specification forbids, and giving the honest path no wire form
    ## at all is how an implementer is pushed into the dishonest one.
    ##
    ## ``completeness`` MAY NOT BE ``ccComplete``, and the daemon refuses
    ## the batch when it is. A window nothing drained while it was open is
    ## incomplete by construction, and OS-2 says a thin sample must never
    ## be presentable as a whole one. The verdict is on the message rather
    ## than assumed by the daemon so that the client states it — it is the
    ## only party that knows how much it dropped.
    ##
    ## ONE-WAY, like ``rqLeaseObservation``: nothing is acknowledged. The
    ## client is exiting; a reply is something it would have to wait for.
    tool*: string
    toolVersion*: string
    invocationKind*: string
    completeness*: CaptureCompleteness
    droppedObservations*: uint32
      ## How many observations the buffer had to throw away. Counted
      ## rather than estimated, because OS-2 requires dropped observations
      ## to be counted and a run whose losses are unknown is not a run
      ## whose losses are zero.
    records*: seq[DeferredExecutionRecord]

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

  # -------------------------------------------------------------------------
  # The extension WRITE path (M17). M12 built the extension mechanism as a
  # STORE API and gated it against a synthetic extension declared in the
  # daemon's own process; M13a then gave extension rows a way OUT over the
  # socket but none in. A real client cannot use an in-process API: no
  # client may open the database file, so without these three messages the
  # only way for a product to populate its own extension would be the one
  # thing the boundary forbids.
  #
  # The shapes mirror the store's ``ExtensionDeclaration`` and
  # ``ExtensionRow`` exactly, INCLUDING the four storage classes, so the
  # transport can express everything the mechanism can. A wire that
  # carried only text and integers would have quietly narrowed the
  # mechanism to what its first client happened to need, which is the
  # failure M12's synthetic-extension gate exists to prevent.
  # -------------------------------------------------------------------------

  ExtensionCellKind* = enum
    extCellNull = 0
    extCellText = 1
    extCellInt = 2
    extCellReal = 3

  ExtensionCellWire* = object
    ## One opaque cell. RunQuota knows the storage class because it has to
    ## write a literal; it knows nothing about what the value means.
    ##
    ## A FLAT RECORD RATHER THAN A VARIANT, deliberately: the codec has no
    ## sum type and a variant would need a second encoding rule per arm.
    ## ``real`` travels as the IEEE-754 BIT PATTERN in a ``uint64`` -- the
    ## codec has no float, and a bit pattern needs no NaN rule and no
    ## endianness rule beyond the one the codec already has for integers.
    kind*: ExtensionCellKind
    text*: string
    number*: int64
    realBits*: uint64

  DeclareExtensionMessage* = object
    ## A client registering its own extension. Request/response, and NOT
    ## on the observation path: this happens once per client, carries a
    ## DDL ladder that can be long, and its answer decides whether any
    ## rows may be sent at all.
    sessionId*: SessionId
    extensionId*: string
    owner*: string
    schemaVersion*: uint32
    migrations*: seq[string]
      ## ``migrations[i]`` takes the table from version ``i`` to ``i + 1``.
      ## Passed through to the store verbatim; RunQuota runs these
      ## statements and does not read them.

  ExtensionDeclaredMessage* = object
    ## What happened, in the store's own vocabulary.
    ##
    ## ACCEPTANCE IS A SEPARATE BOOLEAN FROM THE OUTCOME NAME, because the
    ## four acceptances and four refusals must never be told apart by a
    ## client parsing a string: a client that misread "accepted-older" as
    ## a refusal would stop writing rows it is entitled to write.
    accepted*: bool
    outcome*: string

  ExtensionRowMessage* = object
    ## One extension row, attached to the execution one of this client's
    ## leases produced.
    ##
    ## KEYED BY THE LEASE, NOT BY THE EXECUTION. The execution id is minted
    ## by the daemon when the lease finishes and is never told to the
    ## client, so a client-supplied execution id would be an invention.
    ## The daemon resolves the lease to the execution it recorded.
    ##
    ## ONE-WAY, like ``rqLeaseObservation``: no acknowledgement, no
    ## request id to await, one buffered write. §"Write Path" forbids an
    ## observation from introducing an additional round trip.
    sessionId*: SessionId
    leaseId*: LeaseId
    extensionId*: string
    schemaVersion*: uint32
    columns*: seq[string]
    values*: seq[ExtensionCellWire]

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

# ---------------------------------------------------------------------------
# The only way to name a finish
# ---------------------------------------------------------------------------
#
# THE TYPE ABOVE MAKES THE IMPOSSIBLE STATES UNWRITABLE; THESE CLOSE THE
# LAST HOLE IN IT. A variant arm cannot hold a signal AND an exit status,
# so "killed, exit status 0, signal 0" has no representation at all -- but
# an arm holding one integer can still be left at zero, and zero is the
# value that means "no evidence". So no constructor accepts it, and there
# is no other constructor: a caller reaches these or it reaches nothing.
#
# THEY RAISE RATHER THAN RETURNING A SENTINEL, because a sentinel finish
# is a finish, and it would travel. A supervisor that cannot tell what
# happened has an honest thing to say -- ``cancelled()`` -- and
# ``killEvidence`` below is how it finds out that is what it must say.

proc killedBySignal*(signal: uint32): KillEvidence =
  ## A kill the supervisor reaped: it holds the signal number.
  if signal == 0'u32:
    raise newException(ValueError,
      "a kill reported by signal must name a non-zero signal")
  KillEvidence(bySignal: true, signal: signal)

proc killedWithExitCode*(exitCode: uint32): KillEvidence =
  ## A kill the supervisor knows only as a status integer.
  ##
  ## NOT A LESSER FORM OF THE ABOVE. On Windows there are no POSIX
  ## signals and a killed child is reported as a raw exit code, so this is
  ## the ONLY evidence a Windows supervisor can offer for a deadline kill
  ## -- and without it every timed-out execution there would have to
  ## degrade to ``cancelled``.
  if exitCode == 0'u32:
    raise newException(ValueError,
      "a kill reported by exit status must carry a non-zero one")
  KillEvidence(bySignal: false, exitCode: exitCode)

proc killEvidence*(exitCode, signal: uint32; kill: var KillEvidence): bool =
  ## The evidence a supervisor actually holds, or ``false`` when it holds
  ## none.
  ##
  ## THE ONE PLACE EVERY CLIENT DEGRADES THE SAME WAY. A client that
  ## cannot evidence a kill must not claim one, and the alternative it
  ## must fall back to (``cancelled()``) is the same everywhere; writing
  ## that decision once keeps two supervisors from disagreeing about what
  ## an unevidenced deadline is.
  ##
  ## THE SIGNAL WINS WHEN BOTH ARE PRESENT: it is the kernel's own record
  ## of the kill, while a status integer is at best a convention over it.
  if signal != 0'u32:
    kill = KillEvidence(bySignal: true, signal: signal)
    true
  elif exitCode != 0'u32:
    kill = KillEvidence(bySignal: false, exitCode: exitCode)
    true
  else:
    false

proc succeeded*(): LeaseFinish = LeaseFinish(kind: lfSucceeded)

proc failed*(exitCode: uint32): LeaseFinish =
  if exitCode == 0'u32:
    raise newException(ValueError,
      "a failed finish must carry a non-zero exit status")
  LeaseFinish(kind: lfFailed, exitCode: exitCode)

proc crashed*(signal: uint32): LeaseFinish =
  if signal == 0'u32:
    raise newException(ValueError,
      "a crashed finish must name the signal it died of")
  LeaseFinish(kind: lfCrashed, crashSignal: signal)

proc oomKilled*(kill: KillEvidence): LeaseFinish =
  LeaseFinish(kind: lfOomKilled, kill: kill)

proc timedOut*(kill: KillEvidence): LeaseFinish =
  LeaseFinish(kind: lfTimedOut, kill: kill)

proc cancelled*(): LeaseFinish = LeaseFinish(kind: lfCancelled)

proc launchFailed*(): LeaseFinish = LeaseFinish(kind: lfLaunchFailed)

# ---------------------------------------------------------------------------
# What a finish puts on the wire, and what it puts in the spine's column
# ---------------------------------------------------------------------------
#
# TWO DIFFERENT NUMBERS, AND THEY MUST NOT BE ONE FUNCTION. The WIRE
# carries the finish itself, so it needs the arms' own fields back
# unchanged or ``leaseFinishFromWire`` cannot rebuild the value it
# encoded. The SPINE carries a single ``exit_status`` integer that a SQL
# reader will compare against 0, so it needs a RENDERING of the finish in
# the one convention such readers already share. Conflating them is
# caught: a frame built from the spine's column does not decode.

const SignalledExitStatusBase* = 128'u32
  ## What the spine's ``exit_status`` adds to a signal number.
  ##
  ## THE SHELL CONVENTION, BECAUSE THE COLUMN IS READ BY THINGS THAT
  ## ALREADY SPEAK IT. ``exit_status`` is one integer and has to represent
  ## two kinds of ending; every shell, CI system and process supervisor
  ## renders "died of signal N" as 128 + N, and a reader who knows nothing
  ## about RunQuota still reads 139 as "killed", never as "fine".
  ##
  ## AND IT IS LOSSLESS, which a bare 0 was not. The signal arrives on the
  ## wire and the store has no column for it, so writing 0 discarded it
  ## irrecoverably; ``exit_status - 128`` gives it back.
  ##
  ## THIS IS WHY IT IS NOT 0. ``RunQuota-Observation-Store.md`` §"The
  ## Execution Spine" says a row MUST NOT carry a termination its other
  ## columns contradict. A row reading ``termination = signalled`` beside
  ## ``exit_status = 0`` asserts both that a signal ended this process and
  ## that it exited of its own accord, successfully -- the same
  ## unfalsifiable pairing this whole type exists to abolish, reintroduced
  ## one layer down. A docstring calling that zero "not applicable" does
  ## not reach the SQL reader the column exists for.

proc wireExitCode*(finish: LeaseFinish): uint32 =
  ## The exit code THIS ARM CARRIES, and 0 when it carries none. For the
  ## codec only: it is what ``leaseFinishFromWire`` expects to read back.
  case finish.kind
  of lfSucceeded: 0'u32
  of lfFailed: finish.exitCode
  of lfCrashed: 0'u32
  of lfOomKilled, lfTimedOut:
    if finish.kill.bySignal: 0'u32 else: finish.kill.exitCode
  of lfCancelled, lfLaunchFailed: 0'u32

proc wireSignal*(finish: LeaseFinish): uint32 =
  ## The signal THIS ARM NAMES, and 0 when it names none. For the codec
  ## only, like ``wireExitCode``.
  case finish.kind
  of lfCrashed: finish.crashSignal
  of lfOomKilled, lfTimedOut:
    if finish.kill.bySignal: finish.kill.signal else: 0'u32
  else: 0'u32

proc exitStatus*(finish: LeaseFinish): uint32 =
  ## The spine's ``exit_status`` column for this finish.
  ##
  ## ZERO APPEARS TWICE HERE AND MEANS TWO DIFFERENT THINGS, so the two
  ## are worth telling apart:
  ##
  ## * ``lfSucceeded`` -- the process ran and returned 0. A measurement.
  ## * ``lfCancelled`` / ``lfLaunchFailed`` -- NO PROCESS PRODUCED A
  ##   STATUS. These are the two kinds whose ``termination`` is
  ##   ``refused``, the word for work that never ran, so the column is
  ##   making no claim about a process at all and 0 cannot be mistaken
  ##   for one.
  ##
  ## EVERY KIND THAT DESCRIBES A PROCESS WHICH RAN AND WAS ENDED BY
  ## SOMETHING RETURNS NON-ZERO -- by its own status where it has one,
  ## and by ``128 + signal`` where a signal ended it.
  case finish.kind
  of lfSucceeded: 0'u32
  of lfFailed: finish.exitCode
  of lfCrashed: SignalledExitStatusBase + finish.crashSignal
  of lfOomKilled, lfTimedOut:
    if finish.kill.bySignal:
      SignalledExitStatusBase + finish.kill.signal
    else:
      finish.kill.exitCode
  of lfCancelled, lfLaunchFailed: 0'u32
