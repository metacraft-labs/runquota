import runquota_protocol/types as protocolTypes
import runquota_codec
import runquota_core

export protocolTypes

const libraryName* = "runquota_protocol"
const RqspMagic* = "RQSP"
const RqspProtocolMajor* = 1'u16
const RqspProtocolMinor* = 4'u16
  ## Minor 3 added ``rqLeaseObservation`` (M13). Minor 4 adds the READ path
  ## (M13a): ``rqStatsQuery``/``rqStatsResponse``, and the client estimate
  ## carried on a lease request. Minor rather than major because the store
  ## is a system of record either way: a client that never asks a question
  ## and never supplies an estimate behaves exactly as before, and the
  ## daemon's learned table remains the fallback for it.
  ##
  ## THAT CLAIM IS NOW TRUE OF THE DECODER AS WELL, which it was not when
  ## minor 4 shipped: ``decodeLeaseRequest`` read the estimate
  ## unconditionally and rejected a frame that ended before it, so a
  ## genuinely pre-M13a payload failed to decode against a version number
  ## promising it would not. An absent estimate now takes the not-supplied
  ## branch. Either the decoder tolerates the absent field or the claim
  ## changes; this is the first of those.
const RqspHeaderLen* = 24'u16
const MaxCommandStatsIdBytes* = 64
const FrameFlagRequest* = 0x0001'u16
const FrameFlagResponse* = 0x0002'u16
const FrameFlagError* = 0x0004'u16
const DefaultMaxFrameBytes* = 1_048_576'u32
const DefaultMaxInflightRequests* = 32'u32
const DefaultMaxCandidatesPerBatch* = 16'u32
const DefaultMaxLeaseDecisionsPerBatch * = 8'u32

proc libraryInfo*(): protocolTypes.LibraryInfo =
  protocolTypes.LibraryInfo(name: libraryName)

proc defaultFlowControlLimits*(): FlowControlLimits =
  FlowControlLimits(
    maxInflightRequests: DefaultMaxInflightRequests,
    maxFrameBytes: DefaultMaxFrameBytes,
    maxCandidatesPerBatch: DefaultMaxCandidatesPerBatch,
    maxLeaseDecisionsPerBatch: DefaultMaxLeaseDecisionsPerBatch
  )

proc defaultCapabilities*(platform: string; transport: string; cpuSlots: MilliCpu;
                          memoryBytes: Bytes): CapabilityRecord =
  CapabilityRecord(
    protocolMajor: RqspProtocolMajor,
    protocolMinor: RqspProtocolMinor,
    platform: platform,
    transport: transport,
    maxFrameBytes: DefaultMaxFrameBytes,
    maxInflightRequests: DefaultMaxInflightRequests,
    cpuSlots: cpuSlots,
    memoryBytes: memoryBytes,
    hardMemoryLimitEnforced: false,
    hardMemoryLimitMode: memoryLimitAdvisory,
    processTelemetry: false,
    memoryPressureAvailable: false,
    memoryPressureRequired: false
  )

proc messageKindFromWire*(value: uint16; kind: var RqspMessageKind): bool =
  if value < uint16(ord(low(RqspMessageKind))) or value > uint16(ord(high(
      RqspMessageKind))):
    return false
  kind = RqspMessageKind(int(value))
  true

proc encodeFrame*(kind: RqspMessageKind; flags: uint16; requestId: uint64;
                  payload: string): string =
  var w = writer()
  w.data.add(RqspMagic)
  w.writeU16(RqspProtocolMajor)
  w.writeU16(RqspHeaderLen)
  w.writeU16(uint16(ord(kind)))
  w.writeU16(flags)
  w.writeU64(requestId)
  w.writeU32(uint32(payload.len))
  w.data.add(payload)
  w.data

proc decodeFrameHeader*(bytes: string; header: var FrameHeader): bool =
  if bytes.len != int(RqspHeaderLen):
    return false
  if bytes.substr(0, RqspMagic.len - 1) != RqspMagic:
    return false
  var r = reader(bytes.substr(RqspMagic.len))
  var version: uint16
  var headerLen: uint16
  var kindRaw: uint16
  var flags: uint16
  var requestId: uint64
  var payloadLen: uint32
  var kind: RqspMessageKind
  if not r.readU16(version): return false
  if not r.readU16(headerLen): return false
  if headerLen != RqspHeaderLen: return false
  if not r.readU16(kindRaw): return false
  if not messageKindFromWire(kindRaw, kind): return false
  if not r.readU16(flags): return false
  if not r.readU64(requestId): return false
  if not r.readU32(payloadLen): return false
  header = FrameHeader(
    version: version,
    headerLen: headerLen,
    messageKind: kind,
    flags: flags,
    requestId: requestId,
    payloadLen: payloadLen
  )
  true

proc decodeFrame*(data: string; frame: var RqspFrame): bool =
  if data.len < int(RqspHeaderLen):
    return false
  var header: FrameHeader
  if not decodeFrameHeader(data.substr(0, int(RqspHeaderLen) - 1), header):
    return false
  if data.len != int(RqspHeaderLen) + int(header.payloadLen):
    return false
  frame = RqspFrame(header: header, payload: data.substr(int(RqspHeaderLen)))
  true

proc compatible*(hello: HelloMessage): CompatibilityResult =
  if hello.minProtocolMajor <= RqspProtocolMajor and RqspProtocolMajor <=
      hello.maxProtocolMajor:
    CompatibilityResult(
      compatible: true,
      selectedMajor: RqspProtocolMajor,
      selectedMinor: RqspProtocolMinor,
      diagnostic: okDiagnostic()
    )
  else:
    CompatibilityResult(
      compatible: false,
      selectedMajor: 0'u16,
      selectedMinor: 0'u16,
      diagnostic: diagnostic(
        diagUnsupportedVersion,
        "unsupported RQSP protocol version",
        "daemon supports major " & $RqspProtocolMajor
      )
    )

proc encodeHello*(msg: HelloMessage): string =
  var w = writer()
  w.writeString(msg.clientName)
  w.writeString(msg.clientVersion)
  w.writeU16(msg.minProtocolMajor)
  w.writeU16(msg.maxProtocolMajor)
  w.writeU64(msg.processId)
  w.writeU64(msg.userId)
  w.writeString(msg.desiredCapabilities)
  w.data

proc decodeHello*(payload: string; msg: var HelloMessage): bool =
  var r = reader(payload)
  var clientName: string
  var clientVersion: string
  var minProtocolMajor: uint16
  var maxProtocolMajor: uint16
  var processId: uint64
  var userId: uint64
  var desiredCapabilities: string
  if not r.readString(clientName): return false
  if not r.readString(clientVersion): return false
  if not r.readU16(minProtocolMajor): return false
  if not r.readU16(maxProtocolMajor): return false
  if not r.readU64(processId): return false
  if not r.readU64(userId): return false
  if not r.readString(desiredCapabilities): return false
  if r.remaining != 0: return false
  msg = HelloMessage(
    clientName: clientName,
    clientVersion: clientVersion,
    minProtocolMajor: minProtocolMajor,
    maxProtocolMajor: maxProtocolMajor,
    processId: processId,
    userId: userId,
    desiredCapabilities: desiredCapabilities
  )
  true

proc encodeHelloOk*(msg: HelloOkMessage): string =
  var w = writer()
  w.writeU16(msg.selectedProtocolMajor)
  w.writeU16(msg.selectedProtocolMinor)
  w.writeU64(msg.daemonId)
  w.writeString(msg.daemonVersion)
  w.writeCapabilities(msg.capabilities)
  w.writeU32(msg.flow.maxInflightRequests)
  w.writeU32(msg.flow.maxFrameBytes)
  w.writeU32(msg.flow.maxCandidatesPerBatch)
  w.writeU32(msg.flow.maxLeaseDecisionsPerBatch)
  w.data

proc decodeHelloOk*(payload: string; msg: var HelloOkMessage): bool =
  var r = reader(payload)
  var selectedProtocolMajor: uint16
  var selectedProtocolMinor: uint16
  var daemonId: uint64
  var daemonVersion: string
  var capabilities: CapabilityRecord
  var maxInflightRequests: uint32
  var maxFrameBytes: uint32
  var maxCandidatesPerBatch: uint32
  var maxLeaseDecisionsPerBatch: uint32
  if not r.readU16(selectedProtocolMajor): return false
  if not r.readU16(selectedProtocolMinor): return false
  if not r.readU64(daemonId): return false
  if not r.readString(daemonVersion): return false
  if not r.readCapabilities(capabilities): return false
  if not r.readU32(maxInflightRequests): return false
  if not r.readU32(maxFrameBytes): return false
  if not r.readU32(maxCandidatesPerBatch): return false
  if not r.readU32(maxLeaseDecisionsPerBatch): return false
  if r.remaining != 0: return false
  msg = HelloOkMessage(
    selectedProtocolMajor: selectedProtocolMajor,
    selectedProtocolMinor: selectedProtocolMinor,
    daemonId: daemonId,
    daemonVersion: daemonVersion,
    capabilities: capabilities,
    flow: FlowControlLimits(
      maxInflightRequests: maxInflightRequests,
      maxFrameBytes: maxFrameBytes,
      maxCandidatesPerBatch: maxCandidatesPerBatch,
      maxLeaseDecisionsPerBatch: maxLeaseDecisionsPerBatch
    )
  )
  true

proc encodeRegisterSession*(msg: RegisterSessionMessage): string =
  var w = writer()
  w.writeString(msg.name)
  w.writeString(msg.version)
  w.writeMetadata(msg.metadata)
  w.data

proc decodeRegisterSession*(payload: string;
    msg: var RegisterSessionMessage): bool =
  var r = reader(payload)
  var name: string
  var version: string
  var metadata: DynamicMetadata
  if not r.readString(name): return false
  if not r.readString(version): return false
  if not r.readMetadata(metadata): return false
  if r.remaining != 0: return false
  msg = RegisterSessionMessage(name: name, version: version, metadata: metadata)
  true

proc encodeSessionRegistered*(msg: SessionRegisteredMessage): string =
  var w = writer()
  w.writeU64(msg.sessionId.value)
  w.data

proc decodeSessionRegistered*(payload: string;
    msg: var SessionRegisteredMessage): bool =
  var r = reader(payload)
  var id: uint64
  if not r.readU64(id): return false
  if r.remaining != 0: return false
  msg = SessionRegisteredMessage(sessionId: sessionId(id))
  true

proc encodeCloseSession*(msg: CloseSessionMessage): string =
  var w = writer()
  w.writeU64(msg.sessionId.value)
  w.data

proc decodeCloseSession*(payload: string; msg: var CloseSessionMessage): bool =
  var r = reader(payload)
  var id: uint64
  if not r.readU64(id): return false
  if r.remaining != 0: return false
  msg = CloseSessionMessage(sessionId: sessionId(id))
  true

proc encodeSessionClosed*(msg: SessionClosedMessage): string =
  var w = writer()
  w.writeU64(msg.sessionId.value)
  w.data

proc decodeSessionClosed*(payload: string;
    msg: var SessionClosedMessage): bool =
  var r = reader(payload)
  var id: uint64
  if not r.readU64(id): return false
  if r.remaining != 0: return false
  msg = SessionClosedMessage(sessionId: sessionId(id))
  true

proc writeClientEstimate(w: var BinaryWriter; estimate: ClientEstimate) =
  ## PRESENCE FIRST, VALUE SECOND, and the presence flag is what the
  ## admission rule is written against. See ``ClientEstimate``.
  w.writeBool(estimate.supplied)
  w.writeU64(estimate.memoryBytes)

proc readClientEstimate(r: var BinaryReader;
    estimate: var ClientEstimate): bool =
  var supplied: bool
  var memoryBytes: uint64
  if not r.readBool(supplied): return false
  if not r.readU64(memoryBytes): return false
  # NOT VALIDATED, NOT CLAMPED, NOT RANGE-CHECKED against anything the
  # daemon knows. A decoder that "corrected" an implausible estimate here
  # would break the pass-through rule below the level the rule is written
  # at, which is exactly how such rules stop holding.
  estimate = ClientEstimate(supplied: supplied, memoryBytes: memoryBytes)
  true

proc encodeLeaseRequest*(msg: LeaseRequestMessage): string =
  var w = writer()
  w.writeU64(msg.sessionId.value)
  w.writeString(msg.label)
  w.writeBytes(msg.commandStatsId)
  w.writeResourceVector(msg.resources)
  w.writeDeadline(msg.deadline)
  w.writeU32(uint32(ord(msg.priority)))
  w.writeU32(uint32(ord(msg.purpose)))
  w.writeMetadata(msg.metadata)
  w.writeClientEstimate(msg.estimate)
  w.data

proc decodeLeaseRequest*(payload: string; msg: var LeaseRequestMessage): bool =
  var r = reader(payload)
  var id: uint64
  var label: string
  var commandStatsId: string
  var resources: ResourceVector
  var deadline: Deadline
  var priorityRaw: uint32
  var purposeRaw: uint32
  var metadata: DynamicMetadata
  if not r.readU64(id): return false
  if not r.readString(label): return false
  if not r.readBytes(commandStatsId): return false
  # ``commandStatsId`` is a best-effort stats-grouping hint, not a load-bearing
  # field. An over-long value (e.g. a caller that defaults it to a long, unique
  # action id) must NOT hard-fail the decode: in the batched ``OfferCandidates``
  # message that would reject the WHOLE batch and stall the caller's entire
  # build over one non-essential field — and it is asymmetric with ``label``,
  # which carries no length cap. ``readBytes`` has already consumed the full
  # field, so truncating to the cap here is frame-alignment-safe.
  if commandStatsId.len > MaxCommandStatsIdBytes:
    commandStatsId.setLen(MaxCommandStatsIdBytes)
  if not r.readResourceVector(resources): return false
  if not r.readDeadline(deadline): return false
  if not r.readU32(priorityRaw): return false
  if priorityRaw > uint32(ord(high(PriorityClass))): return false
  if not r.readU32(purposeRaw): return false
  if purposeRaw > uint32(ord(high(LeasePurpose))): return false
  if not r.readMetadata(metadata): return false
  # THE FIELD IS OPTIONAL ON THE WIRE, WHICH IS WHAT A MINOR BUMP PROMISED.
  #
  # M13a added `ClientEstimate` to this message and shipped it as protocol
  # MINOR 4 with a comment calling the change purely additive — while the
  # decoder read the field unconditionally and then rejected the frame for
  # having no trailing bytes. A genuinely pre-M13a client's payload therefore
  # FAILED to decode, and the version number said otherwise. In-tree the
  # defect was invisible, because client and daemon build from one source
  # tree; what was wrong was the CLAIM, and a version number that overstates
  # compatibility is worse than one that understates it, because the party it
  # misleads is the one that cannot see this code.
  #
  # An absent field takes the NOT-SUPPLIED branch, which is byte-identical in
  # effect to the pre-M13a `effectiveResources` body: the daemon's learned
  # estimate is the fallback, exactly as it was before the field existed. So
  # this is a decoder change and not a semantic one.
  var estimate = ClientEstimate(supplied: false, memoryBytes: 0'u64)
  if r.remaining != 0:
    if not r.readClientEstimate(estimate): return false
  if r.remaining != 0: return false
  msg = LeaseRequestMessage(
    sessionId: sessionId(id),
    label: label,
    commandStatsId: commandStatsId,
    resources: resources,
    deadline: deadline,
    priority: PriorityClass(int(priorityRaw)),
    purpose: LeasePurpose(int(purposeRaw)),
    metadata: metadata,
    estimate: estimate
  )
  true

proc writeLeaseCandidate(w: var BinaryWriter; candidate: LeaseCandidate) =
  w.writeU64(candidate.clientCandidateId)
  w.writeString(candidate.label)
  w.writeBytes(candidate.commandStatsId)
  w.writeResourceVector(candidate.resources)
  w.writeDeadline(candidate.deadline)
  w.writeU32(uint32(ord(candidate.priority)))
  w.writeU32(uint32(ord(candidate.purpose)))
  w.writeMetadata(candidate.metadata)
  w.writeClientEstimate(candidate.estimate)

proc readLeaseCandidate(r: var BinaryReader;
    candidate: var LeaseCandidate): bool =
  var clientCandidateId: uint64
  var label: string
  var commandStatsId: string
  var resources: ResourceVector
  var deadline: Deadline
  var priorityRaw: uint32
  var purposeRaw: uint32
  var metadata: DynamicMetadata
  if not r.readU64(clientCandidateId): return false
  if not r.readString(label): return false
  if not r.readBytes(commandStatsId): return false
  # ``commandStatsId`` is a best-effort stats-grouping hint, not a load-bearing
  # field. An over-long value (e.g. a caller that defaults it to a long, unique
  # action id) must NOT hard-fail the decode: in the batched ``OfferCandidates``
  # message that would reject the WHOLE batch and stall the caller's entire
  # build over one non-essential field — and it is asymmetric with ``label``,
  # which carries no length cap. ``readBytes`` has already consumed the full
  # field, so truncating to the cap here is frame-alignment-safe.
  if commandStatsId.len > MaxCommandStatsIdBytes:
    commandStatsId.setLen(MaxCommandStatsIdBytes)
  if not r.readResourceVector(resources): return false
  if not r.readDeadline(deadline): return false
  if not r.readU32(priorityRaw): return false
  if priorityRaw > uint32(ord(high(PriorityClass))): return false
  if not r.readU32(purposeRaw): return false
  if purposeRaw > uint32(ord(high(LeasePurpose))): return false
  if not r.readMetadata(metadata): return false
  var estimate: ClientEstimate
  if not r.readClientEstimate(estimate): return false
  candidate = LeaseCandidate(
    clientCandidateId: clientCandidateId,
    label: label,
    commandStatsId: commandStatsId,
    resources: resources,
    deadline: deadline,
    priority: PriorityClass(int(priorityRaw)),
    purpose: LeasePurpose(int(purposeRaw)),
    metadata: metadata,
    estimate: estimate
  )
  true

proc encodeCandidateOffer*(msg: CandidateOfferMessage): string =
  var w = writer()
  w.writeU64(msg.sessionId.value)
  w.writeU32(uint32(msg.candidates.len))
  for candidate in msg.candidates:
    w.writeLeaseCandidate(candidate)
  w.data

proc decodeCandidateOffer*(payload: string;
    msg: var CandidateOfferMessage): bool =
  var r = reader(payload)
  var sessionRaw: uint64
  var count: uint32
  if not r.readU64(sessionRaw): return false
  if not r.readU32(count): return false
  var candidates: seq[LeaseCandidate] = @[]
  for _ in 0 ..< count:
    var candidate: LeaseCandidate
    if not r.readLeaseCandidate(candidate): return false
    candidates.add(candidate)
  if r.remaining != 0: return false
  msg = CandidateOfferMessage(sessionId: sessionId(sessionRaw),
      candidates: candidates)
  true

proc encodeLeaseDecisionBatch*(msg: LeaseDecisionBatchMessage): string =
  var w = writer()
  w.writeU64(msg.sessionId.value)
  w.writeU32(uint32(msg.decisions.len))
  for decision in msg.decisions:
    w.writeU64(decision.clientCandidateId)
    w.writeU64(decision.leaseId.value)
    w.writeU32(uint32(ord(decision.kind)))
    w.writeResourceVector(decision.resources)
    w.writeDiagnostic(decision.diagnostic)
  w.data

proc decodeLeaseDecisionBatch*(payload: string;
    msg: var LeaseDecisionBatchMessage): bool =
  var r = reader(payload)
  var sessionRaw: uint64
  var count: uint32
  if not r.readU64(sessionRaw): return false
  if not r.readU32(count): return false
  var decisions: seq[LeaseDecision] = @[]
  for _ in 0 ..< count:
    var clientCandidateId: uint64
    var leaseRaw: uint64
    var kindRaw: uint32
    var resources: ResourceVector
    var diagnostic: Diagnostic
    if not r.readU64(clientCandidateId): return false
    if not r.readU64(leaseRaw): return false
    if not r.readU32(kindRaw): return false
    if kindRaw > uint32(ord(high(LeaseDecisionKind))): return false
    if not r.readResourceVector(resources): return false
    if not r.readDiagnostic(diagnostic): return false
    decisions.add(LeaseDecision(
      clientCandidateId: clientCandidateId,
      leaseId: leaseId(leaseRaw),
      kind: LeaseDecisionKind(int(kindRaw)),
      resources: resources,
      diagnostic: diagnostic
    ))
  if r.remaining != 0: return false
  msg = LeaseDecisionBatchMessage(sessionId: sessionId(sessionRaw),
      decisions: decisions)
  true

proc encodeGrantNext*(msg: GrantNextMessage): string =
  var w = writer()
  w.writeU64(msg.sessionId.value)
  w.data

proc decodeGrantNext*(payload: string; msg: var GrantNextMessage): bool =
  var r = reader(payload)
  var sessionRaw: uint64
  if not r.readU64(sessionRaw): return false
  if r.remaining != 0: return false
  msg = GrantNextMessage(sessionId: sessionId(sessionRaw))
  true

proc encodeLeaseGranted*(msg: LeaseGrantedMessage): string =
  var w = writer()
  w.writeU64(msg.sessionId.value)
  w.writeU64(msg.leaseId.value)
  w.writeResourceVector(msg.resources)
  w.data

proc decodeLeaseGranted*(payload: string; msg: var LeaseGrantedMessage): bool =
  var r = reader(payload)
  var sessionRaw: uint64
  var leaseRaw: uint64
  var resources: ResourceVector
  if not r.readU64(sessionRaw): return false
  if not r.readU64(leaseRaw): return false
  if not r.readResourceVector(resources): return false
  if r.remaining != 0: return false
  msg = LeaseGrantedMessage(
    sessionId: sessionId(sessionRaw),
    leaseId: leaseId(leaseRaw),
    resources: resources
  )
  true

proc encodeLeaseDenied*(msg: LeaseDeniedMessage): string =
  var w = writer()
  w.writeU64(msg.sessionId.value)
  w.writeDiagnostic(msg.diagnostic)
  w.data

proc decodeLeaseDenied*(payload: string; msg: var LeaseDeniedMessage): bool =
  var r = reader(payload)
  var sessionRaw: uint64
  var diagnostic: Diagnostic
  if not r.readU64(sessionRaw): return false
  if not r.readDiagnostic(diagnostic): return false
  if r.remaining != 0: return false
  msg = LeaseDeniedMessage(sessionId: sessionId(sessionRaw),
      diagnostic: diagnostic)
  true

proc encodeReleaseLease*(msg: ReleaseLeaseMessage): string =
  var w = writer()
  w.writeU64(msg.sessionId.value)
  w.writeU64(msg.leaseId.value)
  w.data

proc decodeReleaseLease*(payload: string; msg: var ReleaseLeaseMessage): bool =
  var r = reader(payload)
  var sessionRaw: uint64
  var leaseRaw: uint64
  if not r.readU64(sessionRaw): return false
  if not r.readU64(leaseRaw): return false
  if r.remaining != 0: return false
  msg = ReleaseLeaseMessage(sessionId: sessionId(sessionRaw), leaseId: leaseId(leaseRaw))
  true

proc encodeLeaseReleased*(msg: LeaseReleasedMessage): string =
  var w = writer()
  w.writeU64(msg.sessionId.value)
  w.writeU64(msg.leaseId.value)
  w.data

proc decodeLeaseReleased*(payload: string;
    msg: var LeaseReleasedMessage): bool =
  var r = reader(payload)
  var sessionRaw: uint64
  var leaseRaw: uint64
  if not r.readU64(sessionRaw): return false
  if not r.readU64(leaseRaw): return false
  if r.remaining != 0: return false
  msg = LeaseReleasedMessage(sessionId: sessionId(sessionRaw), leaseId: leaseId(leaseRaw))
  true

proc encodeLeaseStarting*(msg: LeaseStartingMessage): string =
  var w = writer()
  w.writeU64(msg.sessionId.value)
  w.writeU64(msg.leaseId.value)
  w.data

proc decodeLeaseStarting*(payload: string;
    msg: var LeaseStartingMessage): bool =
  var r = reader(payload)
  var sessionRaw: uint64
  var leaseRaw: uint64
  if not r.readU64(sessionRaw): return false
  if not r.readU64(leaseRaw): return false
  if r.remaining != 0: return false
  msg = LeaseStartingMessage(sessionId: sessionId(sessionRaw), leaseId: leaseId(leaseRaw))
  true

proc encodeLeaseStartingAck*(msg: LeaseStartingAckMessage): string =
  var w = writer()
  w.writeU64(msg.sessionId.value)
  w.writeU64(msg.leaseId.value)
  w.data

proc decodeLeaseStartingAck*(payload: string;
    msg: var LeaseStartingAckMessage): bool =
  var r = reader(payload)
  var sessionRaw: uint64
  var leaseRaw: uint64
  if not r.readU64(sessionRaw): return false
  if not r.readU64(leaseRaw): return false
  if r.remaining != 0: return false
  msg = LeaseStartingAckMessage(sessionId: sessionId(sessionRaw),
      leaseId: leaseId(leaseRaw))
  true

proc encodeLeaseRunning*(msg: LeaseRunningMessage): string =
  var w = writer()
  w.writeU64(msg.sessionId.value)
  w.writeU64(msg.leaseId.value)
  w.writeU64(msg.childProcessId)
  w.writeU64(msg.processGroupId)
  w.writeBool(msg.cleanupRegistered)
  w.data

proc decodeLeaseRunning*(payload: string; msg: var LeaseRunningMessage): bool =
  var r = reader(payload)
  var sessionRaw: uint64
  var leaseRaw: uint64
  var childProcessId: uint64
  var processGroupId: uint64
  var cleanupRegistered: bool
  if not r.readU64(sessionRaw): return false
  if not r.readU64(leaseRaw): return false
  if not r.readU64(childProcessId): return false
  if not r.readU64(processGroupId): return false
  if not r.readBool(cleanupRegistered): return false
  if r.remaining != 0: return false
  msg = LeaseRunningMessage(
    sessionId: sessionId(sessionRaw),
    leaseId: leaseId(leaseRaw),
    childProcessId: childProcessId,
    processGroupId: processGroupId,
    cleanupRegistered: cleanupRegistered
  )
  true

proc encodeLeaseRunningAck*(msg: LeaseRunningAckMessage): string =
  var w = writer()
  w.writeU64(msg.sessionId.value)
  w.writeU64(msg.leaseId.value)
  w.data

proc decodeLeaseRunningAck*(payload: string;
    msg: var LeaseRunningAckMessage): bool =
  var r = reader(payload)
  var sessionRaw: uint64
  var leaseRaw: uint64
  if not r.readU64(sessionRaw): return false
  if not r.readU64(leaseRaw): return false
  if r.remaining != 0: return false
  msg = LeaseRunningAckMessage(sessionId: sessionId(sessionRaw),
      leaseId: leaseId(leaseRaw))
  true

proc encodeLeaseFinished*(msg: LeaseFinishedMessage): string =
  var w = writer()
  w.writeU64(msg.sessionId.value)
  w.writeU64(msg.leaseId.value)
  w.writeU32(uint32(ord(msg.outcome)))
  w.writeU32(msg.exitCode)
  w.writeU32(msg.signal)
  w.writeU64(msg.peakMemoryBytes)
  w.writeU32(msg.processCount)
  w.writeU64(msg.majorPageFaults)
  w.writeU32(msg.pressureEvents)
  w.writeBool(msg.hardLimitOrOom)
  w.writeDiagnostic(msg.diagnostic)
  w.data

proc decodeLeaseFinished*(payload: string;
    msg: var LeaseFinishedMessage): bool =
  var r = reader(payload)
  var sessionRaw: uint64
  var leaseRaw: uint64
  var outcomeRaw: uint32
  var exitCode: uint32
  var signal: uint32
  var peakMemoryBytes: uint64
  var processCount: uint32
  var majorPageFaults: uint64
  var pressureEvents: uint32
  var hardLimitOrOom: bool
  var diagnostic: Diagnostic
  if not r.readU64(sessionRaw): return false
  if not r.readU64(leaseRaw): return false
  if not r.readU32(outcomeRaw): return false
  if outcomeRaw > uint32(ord(high(LeaseFinishOutcome))): return false
  if not r.readU32(exitCode): return false
  if not r.readU32(signal): return false
  if not r.readU64(peakMemoryBytes): return false
  if not r.readU32(processCount): return false
  if not r.readU64(majorPageFaults): return false
  if not r.readU32(pressureEvents): return false
  if not r.readBool(hardLimitOrOom): return false
  if not r.readDiagnostic(diagnostic): return false
  if r.remaining != 0: return false
  msg = LeaseFinishedMessage(
    sessionId: sessionId(sessionRaw),
    leaseId: leaseId(leaseRaw),
    outcome: LeaseFinishOutcome(int(outcomeRaw)),
    exitCode: exitCode,
    signal: signal,
    peakMemoryBytes: peakMemoryBytes,
    processCount: processCount,
    majorPageFaults: majorPageFaults,
    pressureEvents: pressureEvents,
    hardLimitOrOom: hardLimitOrOom,
    diagnostic: diagnostic
  )
  true

# ---------------------------------------------------------------------------
# The finish's own evidence has to reconcile before a row can be made of it
# ---------------------------------------------------------------------------

proc terminationContradiction(killClaimed, killClaimIsSuccess: bool;
                              exitCode, signal: uint32): string =
  ## The one rule, in the one place it is stated, shared by the leased and
  ## the standalone finish shapes so the two cannot drift.
  ##
  ## ``reprobuild-specs/RunQuota-Observation-Store.md`` §"The Execution
  ## Spine", the ``termination`` row: *a row MUST NOT carry a termination
  ## its other columns contradict*, and *an unfalsifiable row is worse than
  ## an absent one, because it reads as a measurement.*
  ##
  ## A KILL AND A CLEAN EXIT ARE THE PAIR THAT CANNOT BOTH BE TRUE. The
  ## daemon derives ``oom_killed`` and ``timeout`` from fields that say
  ## the supervisor ENDED this process; ``exit_status = 0`` with no signal
  ## says it ended of its own accord, successfully. A row asserting both
  ## is immutable (OS-3) and unfalsifiable, and no later reader can tell
  ## it from a measurement.
  if killClaimed and exitCode == 0'u32 and signal == 0'u32:
    return "a kill was reported beside exit status 0 and no signal"
  if killClaimIsSuccess:
    return "a kill was reported as a successful finish"
  ""

proc leaseFinishedContradiction*(msg: LeaseFinishedMessage): string =
  ## Why no execution row may be made of this finish, or "" when its
  ## evidence reconciles.
  ##
  ## PURE, and separate from the daemon, exactly as
  ## ``leaseObservationRefusal`` is: the states this refuses are ones a
  ## well-behaved client library cannot be asked to produce, so the rule
  ## has to be assertable without one.
  ##
  ## THE TWO KILL FIELDS ARE INDEPENDENT AND STAY THAT WAY.
  ## ``hardLimitOrOom`` and ``outcome == leaseFinishResourceLimit`` are two
  ## pieces of evidence for the same conclusion, not a field and its
  ## checksum -- a supervisor that watched an ``ru_maxrss`` cross a hard
  ## limit may set one, a runner reading its own cgroup may set the other,
  ## and neither is obliged to set both. So this does NOT require them to
  ## agree with each other. What it requires is that the CONCLUSION they
  ## reach agrees with the exit the same message reports.
  let claimsKill = msg.hardLimitOrOom or
    msg.outcome == leaseFinishResourceLimit or
    msg.outcome == leaseFinishTimedOut
  terminationContradiction(claimsKill,
    claimsKill and msg.outcome == leaseFinishSucceeded,
    msg.exitCode, msg.signal)

proc encodeLeaseFinishedAck*(msg: LeaseFinishedAckMessage): string =
  var w = writer()
  w.writeU64(msg.sessionId.value)
  w.writeU64(msg.leaseId.value)
  w.data

proc decodeLeaseFinishedAck*(payload: string;
    msg: var LeaseFinishedAckMessage): bool =
  var r = reader(payload)
  var sessionRaw: uint64
  var leaseRaw: uint64
  if not r.readU64(sessionRaw): return false
  if not r.readU64(leaseRaw): return false
  if r.remaining != 0: return false
  msg = LeaseFinishedAckMessage(sessionId: sessionId(sessionRaw),
      leaseId: leaseId(leaseRaw))
  true

proc encodeStatus*(msg: DaemonStatusMessage): string =
  var w = writer()
  w.writeU32(msg.activeSessions)
  w.writeU32(msg.activeLeases)
  w.writeU32(msg.queuedLeases)
  w.writeU32(msg.supervisorLostLeases)
  w.writeU32(msg.finishedLeases)
  w.writeU64(msg.totalGranted)
  w.writeU64(msg.totalFinished)
  w.data

proc decodeStatus*(payload: string; msg: var DaemonStatusMessage): bool =
  var r = reader(payload)
  var activeSessions: uint32
  var activeLeases: uint32
  var queuedLeases: uint32
  var supervisorLostLeases: uint32
  var finishedLeases: uint32
  var totalGranted: uint64
  var totalFinished: uint64
  if not r.readU32(activeSessions): return false
  if not r.readU32(activeLeases): return false
  if not r.readU32(queuedLeases): return false
  if not r.readU32(supervisorLostLeases): return false
  if not r.readU32(finishedLeases): return false
  if not r.readU64(totalGranted): return false
  if not r.readU64(totalFinished): return false
  if r.remaining != 0: return false
  msg = DaemonStatusMessage(
    activeSessions: activeSessions,
    activeLeases: activeLeases,
    queuedLeases: queuedLeases,
    supervisorLostLeases: supervisorLostLeases,
    finishedLeases: finishedLeases,
    totalGranted: totalGranted,
    totalFinished: totalFinished
  )
  true

proc encodeProtocolError*(msg: ProtocolErrorMessage): string =
  var w = writer()
  w.writeDiagnostic(msg.diagnostic)
  w.data

proc decodeProtocolError*(payload: string;
    msg: var ProtocolErrorMessage): bool =
  var r = reader(payload)
  var diagnostic: Diagnostic
  if not r.readDiagnostic(diagnostic): return false
  if r.remaining != 0: return false
  msg = ProtocolErrorMessage(diagnostic: diagnostic)
  true

const
  ObservationFutureSkewMillis* = 2_000'i64
    ## How far ahead of the daemon's clock a client's reading may be
    ## stamped before it is refused. Not zero: the client and the daemon
    ## read two different clocks, and a few hundred milliseconds of skew
    ## between two calls to the same wall clock is ordinary. Two seconds of
    ## slack, and a figure stamped beyond it is refused — a measurement
    ## from the future was not made.
  ObservationMaxAgeMillis* = 30_000'i64
    ## How old a reading may be and still be folded into ``self_*``.
    ##
    ## THIS BOUND IS THE ONE THAT PROTECTS THE ARITHMETIC. ``foreign =
    ## host_total - sum(self)`` subtracts two measurements and means
    ## nothing unless both describe about the same instant; M11 found this
    ## the expensive way, where self figures read a moment after the host
    ## counters produced rows describing no moment that ever existed. A
    ## half-minute-old figure summed into a sample taken now is the same
    ## defect with a bigger gap, so it is refused rather than folded in.

proc leaseObservationRefusal*(msg: LeaseObservationMessage;
                              nowUnixMillis: int64): string =
  ## Why this observation must be rejected, or "" if it is acceptable.
  ##
  ## PURE, and separate from the daemon, so the refusal can be exercised
  ## on values a well-behaved client cannot send. The daemon adds the
  ## checks only it can make — that the session exists and that the lease
  ## belongs to it — because those need daemon state.
  ##
  ## A REFUSAL IS TOTAL. There is no such thing as accepting the memory
  ## figure from a report whose timestamp is a lie: the caller applies
  ## nothing until this has returned "".
  if msg.sampledAtUnixMillis == 0'u64:
    return "observation carries no sample time"
  let sampledAt = int64(msg.sampledAtUnixMillis)
  if sampledAt < 0:
    return "observation sample time is not representable"
  if sampledAt - nowUnixMillis > ObservationFutureSkewMillis:
    return "observation sample time is " & $(sampledAt - nowUnixMillis) &
      "ms in the future"
  if nowUnixMillis - sampledAt > ObservationMaxAgeMillis:
    return "observation sample time is " & $(nowUnixMillis - sampledAt) &
      "ms stale"
  ""

proc encodeLeaseObservation*(msg: LeaseObservationMessage): string =
  var w = writer()
  w.writeU64(msg.sessionId.value)
  w.writeU64(msg.leaseId.value)
  w.writeU32(msg.cpuMilliPct)
  w.writeU64(msg.rssBytes)
  w.writeU64(msg.sampledAtUnixMillis)
  w.data

proc decodeLeaseObservation*(payload: string;
    msg: var LeaseObservationMessage): bool =
  ## ALL OR NOTHING. ``msg`` is assigned once, at the end, from locals: a
  ## payload that runs out halfway through leaves the caller's message
  ## exactly as it was, so there is no state in which half a report has
  ## been applied. The trailing-bytes check is part of the same rule — a
  ## frame carrying more than this message is not this message.
  var r = reader(payload)
  var sessionRaw: uint64
  var leaseRaw: uint64
  var cpuMilliPct: uint32
  var rssBytes: uint64
  var sampledAtUnixMillis: uint64
  if not r.readU64(sessionRaw): return false
  if not r.readU64(leaseRaw): return false
  if not r.readU32(cpuMilliPct): return false
  if not r.readU64(rssBytes): return false
  if not r.readU64(sampledAtUnixMillis): return false
  if r.remaining != 0: return false
  msg = LeaseObservationMessage(
    sessionId: sessionId(sessionRaw),
    leaseId: leaseId(leaseRaw),
    cpuMilliPct: cpuMilliPct,
    rssBytes: rssBytes,
    sampledAtUnixMillis: sampledAtUnixMillis
  )
  true

proc observedCpuPct*(cpuMilliPct: uint32): float64 =
  ## The wire's integer thousandths-of-a-percent as the percent
  ## ``ambient.nim`` sums.
  float64(cpuMilliPct) / 1000.0

# ---------------------------------------------------------------------------
# The standalone flush (M14): observations buffered with no daemon present,
# delivered once at exit if a daemon happens to be there by then.
# ---------------------------------------------------------------------------

const MaxDeferredRecords* = 4096'u32
  ## A bound on the wire, not merely on the buffer. The frame limit already
  ## caps the payload, but a length prefix a peer can set to four billion is
  ## an allocation a peer can ask for before a single record has been read;
  ## the decoder refuses past this before reserving anything.

proc encodeDeferredObservations*(msg: DeferredObservationsMessage): string =
  var w = writer()
  w.writeString(msg.tool)
  w.writeString(msg.toolVersion)
  w.writeString(msg.invocationKind)
  w.writeU32(uint32(ord(msg.completeness)))
  w.writeU32(msg.droppedObservations)
  w.writeU32(uint32(msg.records.len))
  for record in msg.records:
    w.writeString(record.label)
    w.writeBytes(record.commandStatsId)
    w.writeU64(record.startedAtUnixMillis)
    w.writeU64(record.finishedAtUnixMillis)
    w.writeU32(record.exitStatus)
    w.writeU32(record.signal)
    w.writeU32(uint32(ord(record.outcome)))
    w.writeU64(record.peakRssBytes)
    w.writeU32(record.processCount)
    w.writeU64(record.majorPageFaults)
  w.data

proc decodeDeferredObservations*(payload: string;
    msg: var DeferredObservationsMessage): bool =
  ## ALL OR NOTHING, like every other decoder here: ``msg`` is assigned once
  ## at the end from locals, so a payload that runs out in the middle of the
  ## seventh record leaves the caller's message untouched rather than
  ## holding six records and a claim about how many there were.
  var r = reader(payload)
  var tool: string
  var toolVersion: string
  var invocationKind: string
  var completenessRaw: uint32
  var droppedObservations: uint32
  var count: uint32
  if not r.readString(tool): return false
  if not r.readString(toolVersion): return false
  if not r.readString(invocationKind): return false
  if not r.readU32(completenessRaw): return false
  if completenessRaw > uint32(ord(high(CaptureCompleteness))): return false
  if not r.readU32(droppedObservations): return false
  if not r.readU32(count): return false
  if count > MaxDeferredRecords: return false
  var records: seq[DeferredExecutionRecord] = @[]
  for _ in 0 ..< int(count):
    var record: DeferredExecutionRecord
    var outcomeRaw: uint32
    if not r.readString(record.label): return false
    if not r.readBytes(record.commandStatsId): return false
    if not r.readU64(record.startedAtUnixMillis): return false
    if not r.readU64(record.finishedAtUnixMillis): return false
    if not r.readU32(record.exitStatus): return false
    if not r.readU32(record.signal): return false
    if not r.readU32(outcomeRaw): return false
    if outcomeRaw > uint32(ord(high(LeaseFinishOutcome))): return false
    record.outcome = LeaseFinishOutcome(int(outcomeRaw))
    if not r.readU64(record.peakRssBytes): return false
    if not r.readU32(record.processCount): return false
    if not r.readU64(record.majorPageFaults): return false
    records.add(record)
  if r.remaining != 0: return false
  msg = DeferredObservationsMessage(
    tool: tool,
    toolVersion: toolVersion,
    invocationKind: invocationKind,
    completeness: CaptureCompleteness(int(completenessRaw)),
    droppedObservations: droppedObservations,
    records: records
  )
  true

proc deferredObservationsRefusal*(msg: DeferredObservationsMessage): string =
  ## Why a decoded flush is not recordable, or "" when it is.
  ##
  ## THE REFUSAL THIS MILESTONE TURNS ON. A standalone client's window was
  ## never drained by anything, so it is incomplete by construction; a batch
  ## claiming ``ccComplete`` would put a window that lost an unknown number
  ## of observations into the store as an authoritative one, which is the
  ## single thing OS-2 forbids by name. Refused here — in a pure predicate
  ## on the message — rather than inside the daemon's handler, so it can be
  ## asserted at the exact value that straddles the boundary.
  if msg.completeness == ccComplete:
    return "a deferred batch may not claim a complete capture window"
  if msg.tool.len == 0:
    return "a deferred batch must say which tool produced it"
  if msg.records.len == 0 and msg.droppedObservations == 0:
    return "a deferred batch with nothing in it and nothing dropped"
  ""

proc deferredRecordContradiction*(record: DeferredExecutionRecord): string =
  ## The same rule ``leaseFinishedContradiction`` states, on the shape a
  ## standalone client flushes at exit. The record carries no
  ## ``hardLimitOrOom``, so ``outcome`` is the whole of its kill evidence.
  ##
  ## PER RECORD, NOT PER BATCH, which is why it is separate from
  ## ``deferredObservationsRefusal`` above. A batch is one client's entire
  ## exit flush; discarding a hundred honest rows because the hundred-and-
  ## first contradicts itself is a larger loss than the one this rule
  ## exists to prevent, and OS-4 asks for the smallest degradation that
  ## keeps the store honest rather than the largest.
  let claimsKill = record.outcome == leaseFinishResourceLimit or
    record.outcome == leaseFinishTimedOut
  terminationContradiction(claimsKill,
    claimsKill and record.outcome == leaseFinishSucceeded,
    record.exitStatus, record.signal)

# ---------------------------------------------------------------------------
# The extension WRITE path (M17): declaration, then rows.
# ---------------------------------------------------------------------------

const
  MaxExtensionMigrations* = 64
  MaxExtensionColumns* = 128
    ## Bounds on the two variable-length parts, so a malformed length
    ## prefix allocates a bounded amount rather than whatever a 32-bit
    ## count says. The store refuses anything it cannot name anyway; these
    ## exist so the DECODER never has to trust the number to find out.

proc wireNull*(): ExtensionCellWire =
  ExtensionCellWire(kind: extCellNull)

proc wireText*(value: string): ExtensionCellWire =
  ExtensionCellWire(kind: extCellText, text: value)

proc wireInt*(value: int64): ExtensionCellWire =
  ExtensionCellWire(kind: extCellInt, number: value)

proc wireReal*(value: float64): ExtensionCellWire =
  ExtensionCellWire(kind: extCellReal, realBits: cast[uint64](value))

proc wireRealValue*(cell: ExtensionCellWire): float64 =
  cast[float64](cell.realBits)

proc encodeDeclareExtension*(msg: DeclareExtensionMessage): string =
  var w = writer()
  w.writeU64(msg.sessionId.value)
  w.writeString(msg.extensionId)
  w.writeString(msg.owner)
  w.writeU32(msg.schemaVersion)
  w.writeU32(uint32(msg.migrations.len))
  for step in msg.migrations:
    w.writeString(step)
  w.data

proc decodeDeclareExtension*(payload: string;
                             msg: var DeclareExtensionMessage): bool =
  var r = reader(payload)
  var sessionRaw: uint64
  var extensionId, owner: string
  var schemaVersion, stepCount: uint32
  if not r.readU64(sessionRaw): return false
  if not r.readString(extensionId): return false
  if not r.readString(owner): return false
  if not r.readU32(schemaVersion): return false
  if not r.readU32(stepCount): return false
  if stepCount > uint32(MaxExtensionMigrations): return false
  var migrations: seq[string] = @[]
  for _ in 0 ..< stepCount:
    var step: string
    if not r.readString(step): return false
    migrations.add(step)
  msg = DeclareExtensionMessage(
    sessionId: sessionId(sessionRaw),
    extensionId: extensionId,
    owner: owner,
    schemaVersion: schemaVersion,
    migrations: migrations)
  true

proc encodeExtensionDeclared*(msg: ExtensionDeclaredMessage): string =
  var w = writer()
  w.writeBool(msg.accepted)
  w.writeString(msg.outcome)
  w.data

proc decodeExtensionDeclared*(payload: string;
                              msg: var ExtensionDeclaredMessage): bool =
  var r = reader(payload)
  var accepted: bool
  var outcome: string
  if not r.readBool(accepted): return false
  if not r.readString(outcome): return false
  msg = ExtensionDeclaredMessage(accepted: accepted, outcome: outcome)
  true

proc encodeExtensionRow*(msg: ExtensionRowMessage): string =
  var w = writer()
  w.writeU64(msg.sessionId.value)
  w.writeU64(msg.leaseId.value)
  w.writeString(msg.extensionId)
  w.writeU32(msg.schemaVersion)
  w.writeU32(uint32(msg.columns.len))
  for name in msg.columns:
    w.writeString(name)
  w.writeU32(uint32(msg.values.len))
  for cell in msg.values:
    w.writeU8(uint8(ord(cell.kind)))
    w.writeString(cell.text)
    w.writeU64(cast[uint64](cell.number))
    w.writeU64(cell.realBits)
  w.data

proc decodeExtensionRow*(payload: string; msg: var ExtensionRowMessage): bool =
  var r = reader(payload)
  var sessionRaw, leaseRaw: uint64
  var extensionId: string
  var schemaVersion, columnCount, valueCount: uint32
  if not r.readU64(sessionRaw): return false
  if not r.readU64(leaseRaw): return false
  if not r.readString(extensionId): return false
  if not r.readU32(schemaVersion): return false
  if not r.readU32(columnCount): return false
  if columnCount > uint32(MaxExtensionColumns): return false
  var columns: seq[string] = @[]
  for _ in 0 ..< columnCount:
    var name: string
    if not r.readString(name): return false
    columns.add(name)
  if not r.readU32(valueCount): return false
  if valueCount > uint32(MaxExtensionColumns): return false
  var values: seq[ExtensionCellWire] = @[]
  for _ in 0 ..< valueCount:
    var kindRaw: uint8
    var text: string
    var number, realBits: uint64
    if not r.readU8(kindRaw): return false
    # A STORAGE CLASS THE DAEMON DOES NOT KNOW IS REFUSED, NOT DEFAULTED.
    # Defaulting an unknown class to text would write the wrong literal
    # into a column whose type the client, not RunQuota, chose.
    if kindRaw > uint8(ord(high(ExtensionCellKind))): return false
    if not r.readString(text): return false
    if not r.readU64(number): return false
    if not r.readU64(realBits): return false
    values.add(ExtensionCellWire(
      kind: ExtensionCellKind(kindRaw),
      text: text,
      number: cast[int64](number),
      realBits: realBits))
  msg = ExtensionRowMessage(
    sessionId: sessionId(sessionRaw),
    leaseId: leaseId(leaseRaw),
    extensionId: extensionId,
    schemaVersion: schemaVersion,
    columns: columns,
    values: values)
  true

proc extensionRowRefusal*(msg: ExtensionRowMessage): string =
  ## Why this row must be rejected before the store is ever consulted,
  ## or "" if it is worth passing on.
  ##
  ## A COUNT MISMATCH IS THE ONE THE TRANSPORT MUST CATCH. The store
  ## indexes ``values`` by the position of ``columns``, so a row with
  ## fewer values than columns is not a refusal there but an out-of-bounds
  ## read — and a row with MORE values silently drops the extras into a
  ## table the client believes it filled.
  if msg.extensionId.len == 0:
    return "an extension row must name its extension"
  if msg.columns.len == 0:
    return "an extension row with no columns"
  if msg.columns.len != msg.values.len:
    return "an extension row with " & $msg.columns.len & " columns and " &
      $msg.values.len & " values"
  if msg.schemaVersion == 0:
    return "an extension row declaring schema version 0"
  ""

# ---------------------------------------------------------------------------
# The read path (M13a): stats queries over the socket.
# ---------------------------------------------------------------------------

proc writeProfileIdentity(w: var BinaryWriter; profile: ProfileIdentityWire) =
  ## THE HARDWARE DIMENSION TRAVELS WITH EVERY ANSWER. It is written by one
  ## helper used by all three result shapes so that a result shape added
  ## later cannot quietly omit it.
  w.writeString(profile.hostId)
  w.writeBool(profile.profileIdPresent)
  w.writeString(profile.profileId)
  w.writeString(profile.profileHash)
  w.writeString(profile.cpuModel)
  w.writeU64(profile.logicalCores)

proc readProfileIdentity(r: var BinaryReader;
    profile: var ProfileIdentityWire): bool =
  var hostId, profileId, profileHash, cpuModel: string
  var present: bool
  var logicalCores: uint64
  if not r.readString(hostId): return false
  if not r.readBool(present): return false
  if not r.readString(profileId): return false
  if not r.readString(profileHash): return false
  if not r.readString(cpuModel): return false
  if not r.readU64(logicalCores): return false
  profile = ProfileIdentityWire(hostId: hostId, profileIdPresent: present,
    profileId: profileId, profileHash: profileHash, cpuModel: cpuModel,
    logicalCores: logicalCores)
  true

proc encodeStatsQuery*(msg: StatsQueryMessage): string =
  var w = writer()
  w.writeU64(msg.sessionId.value)
  w.writeU32(uint32(ord(msg.subject)))
  w.writeBytes(msg.statsKey)
  w.writeU32(uint32(ord(msg.scope)))
  w.writeU32(uint32(ord(msg.span)))
  w.writeU32(msg.limit)
  w.writeString(msg.extensionId)
  w.writeU32(uint32(msg.extensionColumns.len))
  for name in msg.extensionColumns:
    w.writeString(name)
  w.data

proc decodeStatsQuery*(payload: string; msg: var StatsQueryMessage): bool =
  var r = reader(payload)
  var sessionRaw: uint64
  var subjectRaw, scopeRaw, spanRaw, limit: uint32
  var statsKey: string
  if not r.readU64(sessionRaw): return false
  if not r.readU32(subjectRaw): return false
  if subjectRaw > uint32(ord(high(StatsSubject))): return false
  if not r.readBytes(statsKey): return false
  if statsKey.len > MaxCommandStatsIdBytes:
    statsKey.setLen(MaxCommandStatsIdBytes)
  if not r.readU32(scopeRaw): return false
  # A SCOPE THE DAEMON DOES NOT KNOW IS REFUSED, NOT DEFAULTED. Defaulting
  # an unrecognised widening request to the narrow value would be safe;
  # defaulting it to the wide one would over-share, and a decoder that
  # silently picks either makes the caller's request unknowable.
  if scopeRaw > uint32(ord(high(StatsScopeWire))): return false
  if not r.readU32(spanRaw): return false
  if spanRaw > uint32(ord(high(ProfileSpanWire))): return false
  if not r.readU32(limit): return false
  var extensionId: string
  var columnCount: uint32
  if not r.readString(extensionId): return false
  if not r.readU32(columnCount): return false
  var extensionColumns: seq[string] = @[]
  for _ in 0 ..< columnCount:
    var name: string
    if not r.readString(name): return false
    extensionColumns.add(name)
  if r.remaining != 0: return false
  msg = StatsQueryMessage(
    sessionId: sessionId(sessionRaw),
    subject: StatsSubject(int(subjectRaw)),
    statsKey: statsKey,
    scope: StatsScopeWire(int(scopeRaw)),
    span: ProfileSpanWire(int(spanRaw)),
    limit: limit,
    extensionId: extensionId,
    extensionColumns: extensionColumns
  )
  true

proc encodeStatsResponse*(msg: StatsResponseMessage): string =
  var w = writer()
  w.writeU32(uint32(ord(msg.subject)))
  w.writeBytes(msg.statsKey)
  w.writeU32(uint32(ord(msg.knowledge)))
  w.writeU32(uint32(ord(msg.scopeApplied)))
  w.writeU32(uint32(ord(msg.spanApplied)))
  w.writeBool(msg.ownerUidPresent)
  w.writeU64(msg.ownerUid)
  w.writeBool(msg.captureEnabled)
  w.writeU32(uint32(msg.distributions.len))
  for entry in msg.distributions:
    w.writeProfileIdentity(entry.profile)
    w.writeU32(uint32(ord(entry.knowledge)))
    w.writeU64(entry.sampleCount)
    w.writeU64(entry.durationMillisMin)
    w.writeU64(entry.durationMillisP50)
    w.writeU64(entry.durationMillisP90)
    w.writeU64(entry.durationMillisMax)
    w.writeU64(entry.peakRssBytesMax)
  w.writeU32(uint32(msg.executions.len))
  for entry in msg.executions:
    w.writeString(entry.executionId)
    w.writeBytes(entry.statsKey)
    w.writeProfileIdentity(entry.profile)
    w.writeBool(entry.ownerUidPresent)
    w.writeU64(entry.ownerUid)
    w.writeU64(entry.startedAtUnixMillis)
    w.writeU64(entry.durationMillis)
    w.writeU64(entry.peakRssBytes)
    w.writeU64(entry.exitStatus)
    w.writeString(entry.termination)
  w.writeU32(uint32(msg.rankings.len))
  for entry in msg.rankings:
    w.writeBytes(entry.statsKey)
    w.writeProfileIdentity(entry.profile)
    w.writeU64(entry.sampleCount)
    w.writeU64(entry.totalDurationMillis)
    w.writeU64(entry.maxDurationMillis)
  w.writeU32(uint32(msg.extensionRows.len))
  for entry in msg.extensionRows:
    w.writeString(entry.hostId)
    w.writeString(entry.executionId)
    w.writeBytes(entry.statsKey)
    w.writeProfileIdentity(entry.profile)
    w.writeBool(entry.ownerUidPresent)
    w.writeU64(entry.ownerUid)
    w.writeU32(uint32(entry.columns.len))
    for name in entry.columns:
      w.writeString(name)
    w.writeU32(uint32(entry.values.len))
    for value in entry.values:
      w.writeString(value)
  w.writeDiagnostic(msg.diagnostic)
  w.data

proc decodeStatsResponse*(payload: string;
    msg: var StatsResponseMessage): bool =
  var r = reader(payload)
  var subjectRaw, knowledgeRaw, scopeRaw, spanRaw, count: uint32
  var statsKey: string
  var ownerUidPresent, captureEnabled: bool
  var ownerUid: uint64
  if not r.readU32(subjectRaw): return false
  if subjectRaw > uint32(ord(high(StatsSubject))): return false
  if not r.readBytes(statsKey): return false
  if not r.readU32(knowledgeRaw): return false
  if knowledgeRaw > uint32(ord(high(StatsKnowledgeWire))): return false
  if not r.readU32(scopeRaw): return false
  if scopeRaw > uint32(ord(high(StatsScopeWire))): return false
  if not r.readU32(spanRaw): return false
  if spanRaw > uint32(ord(high(ProfileSpanWire))): return false
  if not r.readBool(ownerUidPresent): return false
  if not r.readU64(ownerUid): return false
  if not r.readBool(captureEnabled): return false

  var distributions: seq[ResourceDistributionWire] = @[]
  if not r.readU32(count): return false
  for _ in 0 ..< count:
    var entry: ResourceDistributionWire
    var entryKnowledge: uint32
    if not r.readProfileIdentity(entry.profile): return false
    if not r.readU32(entryKnowledge): return false
    if entryKnowledge > uint32(ord(high(StatsKnowledgeWire))): return false
    entry.knowledge = StatsKnowledgeWire(int(entryKnowledge))
    if not r.readU64(entry.sampleCount): return false
    if not r.readU64(entry.durationMillisMin): return false
    if not r.readU64(entry.durationMillisP50): return false
    if not r.readU64(entry.durationMillisP90): return false
    if not r.readU64(entry.durationMillisMax): return false
    if not r.readU64(entry.peakRssBytesMax): return false
    distributions.add(entry)

  var executions: seq[ExecutionSummaryWire] = @[]
  if not r.readU32(count): return false
  for _ in 0 ..< count:
    var entry: ExecutionSummaryWire
    if not r.readString(entry.executionId): return false
    if not r.readBytes(entry.statsKey): return false
    if not r.readProfileIdentity(entry.profile): return false
    if not r.readBool(entry.ownerUidPresent): return false
    if not r.readU64(entry.ownerUid): return false
    if not r.readU64(entry.startedAtUnixMillis): return false
    if not r.readU64(entry.durationMillis): return false
    if not r.readU64(entry.peakRssBytes): return false
    if not r.readU64(entry.exitStatus): return false
    if not r.readString(entry.termination): return false
    executions.add(entry)

  var rankings: seq[KeyRankingWire] = @[]
  if not r.readU32(count): return false
  for _ in 0 ..< count:
    var entry: KeyRankingWire
    if not r.readBytes(entry.statsKey): return false
    if not r.readProfileIdentity(entry.profile): return false
    if not r.readU64(entry.sampleCount): return false
    if not r.readU64(entry.totalDurationMillis): return false
    if not r.readU64(entry.maxDurationMillis): return false
    rankings.add(entry)

  var extensionRows: seq[ExtensionRowWire] = @[]
  if not r.readU32(count): return false
  for _ in 0 ..< count:
    var entry: ExtensionRowWire
    var inner: uint32
    if not r.readString(entry.hostId): return false
    if not r.readString(entry.executionId): return false
    if not r.readBytes(entry.statsKey): return false
    if not r.readProfileIdentity(entry.profile): return false
    if not r.readBool(entry.ownerUidPresent): return false
    if not r.readU64(entry.ownerUid): return false
    if not r.readU32(inner): return false
    for _ in 0 ..< inner:
      var name: string
      if not r.readString(name): return false
      entry.columns.add(name)
    if not r.readU32(inner): return false
    for _ in 0 ..< inner:
      var value: string
      if not r.readString(value): return false
      entry.values.add(value)
    # A ROW WHOSE COLUMNS AND VALUES DISAGREE IN LENGTH IS REFUSED, not
    # zipped as far as it goes. RunQuota does not know what these mean, so
    # it cannot repair a mispairing -- and a silently truncated payload is
    # a product's fact turned into a different fact.
    if entry.columns.len != entry.values.len: return false
    extensionRows.add(entry)

  var diag: Diagnostic
  if not r.readDiagnostic(diag): return false
  if r.remaining != 0: return false
  msg = StatsResponseMessage(
    subject: StatsSubject(int(subjectRaw)),
    statsKey: statsKey,
    knowledge: StatsKnowledgeWire(int(knowledgeRaw)),
    scopeApplied: StatsScopeWire(int(scopeRaw)),
    spanApplied: ProfileSpanWire(int(spanRaw)),
    ownerUidPresent: ownerUidPresent,
    ownerUid: ownerUid,
    captureEnabled: captureEnabled,
    distributions: distributions,
    executions: executions,
    rankings: rankings,
    extensionRows: extensionRows,
    diagnostic: diag
  )
  true

proc encodeInspectionRequest*(msg: InspectionRequestMessage): string =
  var w = writer()
  w.writeString(msg.subject)
  w.writeU64(msg.sessionId.value)
  w.data

proc decodeInspectionRequest*(payload: string;
    msg: var InspectionRequestMessage): bool =
  var r = reader(payload)
  var subject: string
  var sessionRaw: uint64
  if not r.readString(subject): return false
  if not r.readU64(sessionRaw): return false
  if r.remaining != 0: return false
  msg = InspectionRequestMessage(subject: subject, sessionId: sessionId(sessionRaw))
  true

proc encodeInspectionResponse*(msg: InspectionResponseMessage): string =
  var w = writer()
  w.writeString(msg.json)
  w.data

proc decodeInspectionResponse*(payload: string;
    msg: var InspectionResponseMessage): bool =
  var r = reader(payload)
  var json: string
  if not r.readString(json): return false
  if r.remaining != 0: return false
  msg = InspectionResponseMessage(json: json)
  true

proc inspectionStatusJson*(status: DaemonStatusMessage): string =
  "{" &
    "\"active_sessions\":" & $status.activeSessions & "," &
    "\"active_leases\":" & $status.activeLeases & "," &
    "\"queued_leases\":" & $status.queuedLeases & "," &
    "\"supervisor_lost_leases\":" & $status.supervisorLostLeases & "," &
    "\"finished_leases\":" & $status.finishedLeases & "," &
    "\"total_granted\":" & $status.totalGranted & "," &
    "\"total_finished\":" & $status.totalFinished &
  "}"
