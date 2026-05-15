import runquota_protocol/types as protocolTypes
import runquota_codec
import runquota_core

export protocolTypes

const libraryName* = "runquota_protocol"
const RqspMagic* = "RQSP"
const RqspProtocolMajor* = 1'u16
const RqspProtocolMinor* = 0'u16
const RqspHeaderLen* = 24'u16
const FrameFlagRequest* = 0x0001'u16
const FrameFlagResponse* = 0x0002'u16
const FrameFlagError* = 0x0004'u16
const DefaultMaxFrameBytes* = 1_048_576'u32
const DefaultMaxInflightRequests* = 32'u32

proc libraryInfo*(): protocolTypes.LibraryInfo =
  protocolTypes.LibraryInfo(name: libraryName)

proc defaultFlowControlLimits*(): FlowControlLimits =
  FlowControlLimits(
    maxInflightRequests: DefaultMaxInflightRequests,
    maxFrameBytes: DefaultMaxFrameBytes,
    maxCandidatesPerBatch: 1'u32,
    maxLeaseDecisionsPerBatch: 1'u32
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
    processTelemetry: false
  )

proc messageKindFromWire*(value: uint16; kind: var RqspMessageKind): bool =
  if value < uint16(ord(low(RqspMessageKind))) or value > uint16(ord(high(RqspMessageKind))):
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
  if hello.minProtocolMajor <= RqspProtocolMajor and RqspProtocolMajor <= hello.maxProtocolMajor:
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

proc decodeRegisterSession*(payload: string; msg: var RegisterSessionMessage): bool =
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

proc decodeSessionRegistered*(payload: string; msg: var SessionRegisteredMessage): bool =
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

proc decodeSessionClosed*(payload: string; msg: var SessionClosedMessage): bool =
  var r = reader(payload)
  var id: uint64
  if not r.readU64(id): return false
  if r.remaining != 0: return false
  msg = SessionClosedMessage(sessionId: sessionId(id))
  true

proc encodeLeaseRequest*(msg: LeaseRequestMessage): string =
  var w = writer()
  w.writeU64(msg.sessionId.value)
  w.writeString(msg.label)
  w.writeBytes(msg.commandStatsId)
  w.writeResourceVector(msg.resources)
  w.writeDeadline(msg.deadline)
  w.writeU32(uint32(ord(msg.priority)))
  w.writeMetadata(msg.metadata)
  w.data

proc decodeLeaseRequest*(payload: string; msg: var LeaseRequestMessage): bool =
  var r = reader(payload)
  var id: uint64
  var label: string
  var commandStatsId: string
  var resources: ResourceVector
  var deadline: Deadline
  var priorityRaw: uint32
  var metadata: DynamicMetadata
  if not r.readU64(id): return false
  if not r.readString(label): return false
  if not r.readBytes(commandStatsId): return false
  if not r.readResourceVector(resources): return false
  if not r.readDeadline(deadline): return false
  if not r.readU32(priorityRaw): return false
  if priorityRaw > uint32(ord(high(PriorityClass))): return false
  if not r.readMetadata(metadata): return false
  if r.remaining != 0: return false
  msg = LeaseRequestMessage(
    sessionId: sessionId(id),
    label: label,
    commandStatsId: commandStatsId,
    resources: resources,
    deadline: deadline,
    priority: PriorityClass(int(priorityRaw)),
    metadata: metadata
  )
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
  msg = LeaseDeniedMessage(sessionId: sessionId(sessionRaw), diagnostic: diagnostic)
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

proc decodeLeaseReleased*(payload: string; msg: var LeaseReleasedMessage): bool =
  var r = reader(payload)
  var sessionRaw: uint64
  var leaseRaw: uint64
  if not r.readU64(sessionRaw): return false
  if not r.readU64(leaseRaw): return false
  if r.remaining != 0: return false
  msg = LeaseReleasedMessage(sessionId: sessionId(sessionRaw), leaseId: leaseId(leaseRaw))
  true

proc encodeStatus*(msg: DaemonStatusMessage): string =
  var w = writer()
  w.writeU32(msg.activeSessions)
  w.writeU32(msg.activeLeases)
  w.writeU64(msg.totalGranted)
  w.data

proc decodeStatus*(payload: string; msg: var DaemonStatusMessage): bool =
  var r = reader(payload)
  var activeSessions: uint32
  var activeLeases: uint32
  var totalGranted: uint64
  if not r.readU32(activeSessions): return false
  if not r.readU32(activeLeases): return false
  if not r.readU64(totalGranted): return false
  if r.remaining != 0: return false
  msg = DaemonStatusMessage(
    activeSessions: activeSessions,
    activeLeases: activeLeases,
    totalGranted: totalGranted
  )
  true

proc encodeProtocolError*(msg: ProtocolErrorMessage): string =
  var w = writer()
  w.writeDiagnostic(msg.diagnostic)
  w.data

proc decodeProtocolError*(payload: string; msg: var ProtocolErrorMessage): bool =
  var r = reader(payload)
  var diagnostic: Diagnostic
  if not r.readDiagnostic(diagnostic): return false
  if r.remaining != 0: return false
  msg = ProtocolErrorMessage(diagnostic: diagnostic)
  true

proc inspectionStatusJson*(status: DaemonStatusMessage): string =
  "{" &
    "\"active_sessions\":" & $status.activeSessions & "," &
    "\"active_leases\":" & $status.activeLeases & "," &
    "\"total_granted\":" & $status.totalGranted &
  "}"
