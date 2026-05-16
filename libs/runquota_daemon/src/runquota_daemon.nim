import std/[algorithm, cpuinfo, locks, os, tables]

import runquota_daemon/types as daemonTypes
import runquota_codec
import runquota_core
import runquota_ipc
import runquota_protocol

export daemonTypes

const libraryName* = "runquota_daemon"

proc libraryInfo*(): daemonTypes.LibraryInfo =
  daemonTypes.LibraryInfo(name: libraryName)

proc defaultDaemonConfig*(endpoint = defaultEndpoint()): DaemonConfig =
  DaemonConfig(
    endpoint: endpoint,
    daemonId: uint64(getCurrentProcessId()),
    cpuSlots: milliCpu(max(1, countProcessors()) * 1000),
    memoryBytes: bytes(16'u64 * 1024'u64 * 1024'u64 * 1024'u64),
    ioSlots: 1'u32,
    namedPoolCaps: initTable[string, uint32](),
    version: "0.1.0"
  )

proc initDaemon*(config: DaemonConfig): RunQuotaDaemon =
  RunQuotaDaemon(
    config: config,
    state: dsStarting,
    nextSessionId: 1'u64,
    nextLeaseId: 1'u64,
    nextQueueOrder: 1'u64,
    lastGrantedSessionId: 0'u64,
    totalGranted: 0'u64,
    totalFinished: 0'u64,
    sessions: initTable[uint64, SessionRow](),
    leases: initTable[uint64, LeaseRow]()
  )

proc countLeases(daemon: RunQuotaDaemon; state: LeaseLifecycleState): uint32 =
  for lease in daemon.leases.values:
    if lease.state == state:
      inc result

proc isResourceActive(state: LeaseLifecycleState): bool =
  state in {leaseStateGranted, leaseStateStarting, leaseStateRunning, leaseStateSupervisorLost}

proc countActiveLeases(daemon: RunQuotaDaemon): uint32 =
  for lease in daemon.leases.values:
    if lease.state.isResourceActive:
      inc result

proc status*(daemon: RunQuotaDaemon): DaemonStatusMessage =
  DaemonStatusMessage(
    activeSessions: uint32(daemon.sessions.len),
    activeLeases: daemon.countActiveLeases(),
    queuedLeases: daemon.countLeases(leaseStateQueued),
    supervisorLostLeases: daemon.countLeases(leaseStateSupervisorLost),
    finishedLeases: daemon.countLeases(leaseStateFinished),
    totalGranted: daemon.totalGranted,
    totalFinished: daemon.totalFinished
  )

proc sendResponse(connection: var LocalConnection; kind: RqspMessageKind;
                  requestId: uint64; payload: string) =
  connection.sendFrame(encodeFrame(kind, FrameFlagResponse, requestId, payload))

proc sendError(connection: var LocalConnection; requestId: uint64; diagnostic: Diagnostic) =
  let payload = encodeProtocolError(ProtocolErrorMessage(diagnostic: diagnostic))
  connection.sendFrame(encodeFrame(rqError, FrameFlagResponse or FrameFlagError, requestId, payload))

proc receiveFrameOrDiagnostic(connection: var LocalConnection; frame: var RqspFrame): bool =
  var frameDiagnostic = okDiagnostic()
  if connection.receiveFrame(frame, frameDiagnostic):
    return true
  if frameDiagnostic.code != diagOk and frame.header.requestId != 0'u64:
    connection.sendError(frame.header.requestId, frameDiagnostic)
  false

proc ioSlots(resources: ResourceVector; cap: uint32): uint32 =
  case resources.ioClass
  of ioNormal:
    0'u32
  of ioHeavy:
    1'u32
  of ioExclusive:
    cap

proc priorityRank(priority: PriorityClass): int =
  case priority
  of priorityInteractive: 0
  of priorityNormal: 1
  of priorityBackground: 2

proc activeUsage(daemon: RunQuotaDaemon; cpu: var uint32; memory: var uint64;
                 io: var uint32; pools: var Table[string, uint32]) =
  cpu = 0'u32
  memory = 0'u64
  io = 0'u32
  pools = initTable[string, uint32]()
  for lease in daemon.leases.values:
    if lease.state.isResourceActive:
      cpu += lease.resources.cpu.value
      memory += lease.resources.memory.value
      io += lease.resources.ioSlots(daemon.config.ioSlots)
      for demand in lease.resources.namedPools:
        pools[demand.name] = pools.getOrDefault(demand.name, 0'u32) + demand.units

proc possible(daemon: RunQuotaDaemon; resources: ResourceVector; reason: var string): bool =
  if resources.cpu.value == 0 or resources.memory.value == 0:
    reason = "lease request must reserve CPU and memory"
    return false
  if resources.cpu.value > daemon.config.cpuSlots.value:
    reason = "lease request exceeds CPU budget"
    return false
  if resources.memory.value > daemon.config.memoryBytes.value:
    reason = "lease request exceeds memory budget"
    return false
  if resources.ioSlots(daemon.config.ioSlots) > daemon.config.ioSlots:
    reason = "lease request exceeds IO budget"
    return false
  for demand in resources.namedPools:
    if demand.units == 0:
      reason = "named-pool demand must be non-zero"
      return false
    let cap = daemon.config.namedPoolCaps.getOrDefault(demand.name, 0'u32)
    if cap == 0 or demand.units > cap:
      reason = "lease request exceeds named-pool budget: " & demand.name
      return false
  true

proc fitsNow(daemon: RunQuotaDaemon; resources: ResourceVector): bool =
  var usedCpu: uint32
  var usedMemory: uint64
  var usedIo: uint32
  var usedPools: Table[string, uint32]
  daemon.activeUsage(usedCpu, usedMemory, usedIo, usedPools)
  if usedCpu + resources.cpu.value > daemon.config.cpuSlots.value:
    return false
  if usedMemory + resources.memory.value > daemon.config.memoryBytes.value:
    return false
  if usedIo + resources.ioSlots(daemon.config.ioSlots) > daemon.config.ioSlots:
    return false
  for demand in resources.namedPools:
    let cap = daemon.config.namedPoolCaps.getOrDefault(demand.name, 0'u32)
    let used = usedPools.getOrDefault(demand.name, 0'u32)
    if used + demand.units > cap:
      return false
  true

proc stateName(state: LeaseLifecycleState): string =
  case state
  of leaseStateQueued: "queued"
  of leaseStateGranted: "granted"
  of leaseStateStarting: "starting"
  of leaseStateRunning: "running"
  of leaseStateFinished: "finished"
  of leaseStateSupervisorLost: "supervisor_lost"

proc leaseDecision(lease: LeaseRow; kind: LeaseDecisionKind;
                   diagnostic = okDiagnostic()): LeaseDecision =
  LeaseDecision(
    clientCandidateId: lease.clientCandidateId,
    leaseId: lease.id,
    kind: kind,
    resources: lease.resources,
    diagnostic: diagnostic
  )

proc sessionsJson(daemon: RunQuotaDaemon): string =
  var ids: seq[uint64] = @[]
  for id in daemon.sessions.keys:
    ids.add(id)
  ids.sort()
  result = "{\"sessions\":["
  for i, id in ids:
    if i > 0:
      result.add(",")
    let session = daemon.sessions[id]
    result.add("{" &
      "\"id\":" & $session.id.value & "," &
      "\"name\":" & jsonEscape(session.name) & "," &
      "\"version\":" & jsonEscape(session.version) &
    "}")
  result.add("]}")

proc leasesJson(daemon: RunQuotaDaemon; onlySession = sessionId(0)): string =
  var ids: seq[uint64] = @[]
  for id, lease in daemon.leases.pairs:
    if onlySession.value == 0 or lease.sessionId.value == onlySession.value:
      ids.add(id)
  ids.sort()
  result = "{\"leases\":["
  for i, id in ids:
    if i > 0:
      result.add(",")
    let lease = daemon.leases[id]
    result.add("{" &
      "\"id\":" & $lease.id.value & "," &
      "\"session_id\":" & $lease.sessionId.value & "," &
      "\"candidate_id\":" & $lease.clientCandidateId & "," &
      "\"label\":" & jsonEscape(lease.label) & "," &
      "\"state\":" & jsonEscape(lease.state.stateName) & "," &
      "\"resources\":" & inspectionResourceJson(lease.resources) &
    "}")
  result.add("]}")

proc inspectionJson(daemon: RunQuotaDaemon; request: InspectionRequestMessage): string =
  case request.subject
  of "sessions":
    daemon.sessionsJson()
  of "leases":
    daemon.leasesJson()
  of "explain":
    daemon.leasesJson(request.sessionId)
  of "status":
    inspectionStatusJson(daemon.status())
  else:
    "{\"error\":\"unknown inspection subject\"}"

proc handleHello(daemon: RunQuotaDaemon; connection: var LocalConnection;
                 context: var ConnectionContext; frame: RqspFrame): bool =
  if frame.header.messageKind != rqHello:
    connection.sendError(frame.header.requestId, diagnostic(diagProtocol, "client must send Hello first"))
    return false
  var hello: HelloMessage
  if not decodeHello(frame.payload, hello):
    connection.sendError(frame.header.requestId, diagnostic(diagProtocol, "invalid Hello payload"))
    return false
  let compatibility = compatible(hello)
  if not compatibility.compatible:
    connection.sendError(frame.header.requestId, compatibility.diagnostic)
    return false
  let platformName =
    when defined(macosx): "macos"
    elif defined(linux): "linux"
    else: "posix"
  let caps = defaultCapabilities(
    platformName,
    "unix-socket",
    daemon.config.cpuSlots,
    daemon.config.memoryBytes
  )
  let helloOk = HelloOkMessage(
    selectedProtocolMajor: compatibility.selectedMajor,
    selectedProtocolMinor: compatibility.selectedMinor,
    daemonId: daemon.config.daemonId,
    daemonVersion: daemon.config.version,
    capabilities: caps,
    flow: defaultFlowControlLimits()
  )
  connection.sendResponse(rqHelloOk, frame.header.requestId, encodeHelloOk(helloOk))
  context.supervisorProcessId = hello.processId
  context.supervisorUserId = hello.userId
  context.peer = connection.peerIdentity()
  true

proc createQueuedLease(daemon: var RunQuotaDaemon; sessionId: SessionId;
                       clientCandidateId: uint64; label: string;
                       resources: ResourceVector; priority: PriorityClass): LeaseRow =
  let session = daemon.sessions[sessionId.value]
  let id = leaseId(daemon.nextLeaseId)
  inc daemon.nextLeaseId
  let queueOrder = daemon.nextQueueOrder
  inc daemon.nextQueueOrder
  result = LeaseRow(
    id: id,
    sessionId: sessionId,
    label: label,
    clientCandidateId: clientCandidateId,
    resources: resources,
    priority: priority,
    queueOrder: queueOrder,
    delivered: false,
    state: leaseStateQueued,
    supervisorProcessId: session.supervisorProcessId,
    supervisorUserId: session.supervisorUserId,
    peer: session.peer,
    childProcessId: 0'u64,
    processGroupId: 0'u64,
    cleanupRegistered: false,
    finishOutcome: leaseFinishCancelled,
    finishDiagnostic: okDiagnostic()
  )
  daemon.leases[id.value] = result

proc grantQueuedLease(daemon: var RunQuotaDaemon; id: uint64; delivered: bool) =
  var lease = daemon.leases[id]
  lease.state = leaseStateGranted
  lease.delivered = delivered
  daemon.leases[id] = lease
  daemon.lastGrantedSessionId = lease.sessionId.value
  inc daemon.totalGranted

proc queuedSessionOrder(daemon: RunQuotaDaemon): seq[uint64] =
  for lease in daemon.leases.values:
    if lease.state == leaseStateQueued and not result.contains(lease.sessionId.value):
      result.add(lease.sessionId.value)
  result.sort()
  if result.len <= 1 or daemon.lastGrantedSessionId == 0:
    return
  var cut = 0
  while cut < result.len and result[cut] <= daemon.lastGrantedSessionId:
    inc cut
  if cut > 0 and cut < result.len:
    result = result[cut .. ^1] & result[0 ..< cut]

proc tryPromoteQueued(daemon: var RunQuotaDaemon; maxDecisions: uint32 = high(uint32)): seq[uint64] =
  var promoted = 0'u32
  var madeProgress = true
  while madeProgress and promoted < maxDecisions:
    madeProgress = false
    let sessions = daemon.queuedSessionOrder()
    for sessionIdValue in sessions:
      if promoted >= maxDecisions:
        break
      var bestId = 0'u64
      var bestPriority = high(int)
      var bestOrder = high(uint64)
      for id, lease in daemon.leases.pairs:
        if lease.state == leaseStateQueued and lease.sessionId.value == sessionIdValue:
          let rank = priorityRank(lease.priority)
          if rank < bestPriority or (rank == bestPriority and lease.queueOrder < bestOrder):
            if daemon.fitsNow(lease.resources):
              bestId = id
              bestPriority = rank
              bestOrder = lease.queueOrder
      if bestId != 0'u64:
        daemon.grantQueuedLease(bestId, false)
        result.add(bestId)
        inc promoted
        madeProgress = true

proc requireOwnedLease(daemon: RunQuotaDaemon; connection: var LocalConnection;
                       requestId: uint64; sessionId: SessionId;
                       id: LeaseId; lease: var LeaseRow): bool =
  if not daemon.leases.hasKey(id.value):
    connection.sendError(requestId, diagnostic(diagInvalidArgument, "unknown lease id"))
    return false
  lease = daemon.leases[id.value]
  if lease.sessionId.value != sessionId.value:
    connection.sendError(requestId, diagnostic(diagInvalidArgument, "lease belongs to another session"))
    return false
  true

proc releaseLease(daemon: var RunQuotaDaemon; id: LeaseId) =
  if daemon.leases.hasKey(id.value):
    daemon.leases.del(id.value)
    discard daemon.tryPromoteQueued(defaultFlowControlLimits().maxLeaseDecisionsPerBatch)

proc cleanupLostSession(daemon: var RunQuotaDaemon; sessionId: SessionId) =
  if not daemon.sessions.hasKey(sessionId.value):
    return
  var deleteLeaseIds: seq[uint64] = @[]
  var lostLeaseIds: seq[uint64] = @[]
  for key, lease in daemon.leases.pairs:
    if lease.sessionId.value == sessionId.value:
      case lease.state
      of leaseStateQueued, leaseStateGranted:
        deleteLeaseIds.add(key)
      of leaseStateFinished:
        discard
      of leaseStateStarting, leaseStateRunning:
        lostLeaseIds.add(key)
      of leaseStateSupervisorLost:
        discard
  for id in lostLeaseIds:
    var lost = daemon.leases[id]
    lost.state = leaseStateSupervisorLost
    lost.finishDiagnostic = diagnostic(
      diagCancelled,
      "supervisor connection closed before LeaseFinished",
      "RunQuota did not infer child process completion from IPC closure"
    )
    daemon.leases[id] = lost
  for id in deleteLeaseIds:
    daemon.leases.del(id)
  daemon.sessions.del(sessionId.value)
  discard daemon.tryPromoteQueued(defaultFlowControlLimits().maxLeaseDecisionsPerBatch)

proc cleanupConnection(daemon: var RunQuotaDaemon; context: ConnectionContext) =
  for id in context.sessionIds:
    daemon.cleanupLostSession(id)

proc handleRequest(daemon: var RunQuotaDaemon; connection: var LocalConnection;
                   context: var ConnectionContext; frame: RqspFrame) =
  case frame.header.messageKind
  of rqRegisterSession:
    var msg: RegisterSessionMessage
    if not decodeRegisterSession(frame.payload, msg):
      connection.sendError(frame.header.requestId, diagnostic(diagProtocol, "invalid RegisterSession payload"))
      return
    let id = sessionId(daemon.nextSessionId)
    inc daemon.nextSessionId
    daemon.sessions[id.value] = SessionRow(
      id: id,
      name: msg.name,
      version: msg.version,
      supervisorProcessId: context.supervisorProcessId,
      supervisorUserId: context.supervisorUserId,
      peer: context.peer
    )
    context.sessionIds.add(id)
    connection.sendResponse(
      rqSessionRegistered,
      frame.header.requestId,
      encodeSessionRegistered(SessionRegisteredMessage(sessionId: id))
    )
  of rqCloseSession:
    var msg: CloseSessionMessage
    if not decodeCloseSession(frame.payload, msg):
      connection.sendError(frame.header.requestId, diagnostic(diagProtocol, "invalid CloseSession payload"))
      return
    if not daemon.sessions.hasKey(msg.sessionId.value):
      connection.sendError(frame.header.requestId, diagnostic(diagInvalidArgument, "unknown session id"))
      return
    for lease in daemon.leases.values:
      if lease.sessionId.value == msg.sessionId.value and lease.state != leaseStateFinished:
        connection.sendError(frame.header.requestId, diagnostic(diagInvalidArgument, "session still owns leases"))
        return
    daemon.sessions.del(msg.sessionId.value)
    connection.sendResponse(
      rqSessionClosed,
      frame.header.requestId,
      encodeSessionClosed(SessionClosedMessage(sessionId: msg.sessionId))
    )
  of rqRequestLease:
    var msg: LeaseRequestMessage
    if not decodeLeaseRequest(frame.payload, msg):
      connection.sendError(frame.header.requestId, diagnostic(diagProtocol, "invalid RequestLease payload"))
      return
    if not daemon.sessions.hasKey(msg.sessionId.value):
      connection.sendError(frame.header.requestId, diagnostic(diagInvalidArgument, "unknown session id"))
      return
    var reason = ""
    if not daemon.possible(msg.resources, reason):
      let denied = LeaseDeniedMessage(
        sessionId: msg.sessionId,
        diagnostic: diagnostic(diagDenied, reason)
      )
      connection.sendResponse(rqLeaseDenied, frame.header.requestId, encodeLeaseDenied(denied))
      return
    let queued = daemon.createQueuedLease(
      msg.sessionId,
      frame.header.requestId,
      msg.label,
      msg.resources,
      msg.priority
    )
    discard daemon.tryPromoteQueued(defaultFlowControlLimits().maxLeaseDecisionsPerBatch)
    if daemon.leases[queued.id.value].state != leaseStateGranted:
      daemon.leases.del(queued.id.value)
      let denied = LeaseDeniedMessage(
        sessionId: msg.sessionId,
        diagnostic: diagnostic(diagDenied, "resources unavailable; use candidate offers for queued admission")
      )
      connection.sendResponse(rqLeaseDenied, frame.header.requestId, encodeLeaseDenied(denied))
      return
    var grantedLease = daemon.leases[queued.id.value]
    grantedLease.delivered = true
    daemon.leases[queued.id.value] = grantedLease
    let granted = LeaseGrantedMessage(
      sessionId: msg.sessionId,
      leaseId: queued.id,
      resources: msg.resources
    )
    connection.sendResponse(rqLeaseGranted, frame.header.requestId, encodeLeaseGranted(granted))
  of rqReleaseLease:
    var msg: ReleaseLeaseMessage
    if not decodeReleaseLease(frame.payload, msg):
      connection.sendError(frame.header.requestId, diagnostic(diagProtocol, "invalid ReleaseLease payload"))
      return
    if not daemon.leases.hasKey(msg.leaseId.value):
      connection.sendError(frame.header.requestId, diagnostic(diagInvalidArgument, "unknown lease id"))
      return
    let lease = daemon.leases[msg.leaseId.value]
    if lease.sessionId.value != msg.sessionId.value:
      connection.sendError(frame.header.requestId, diagnostic(diagInvalidArgument, "lease belongs to another session"))
      return
    daemon.releaseLease(msg.leaseId)
    connection.sendResponse(
      rqLeaseReleased,
      frame.header.requestId,
      encodeLeaseReleased(LeaseReleasedMessage(sessionId: msg.sessionId, leaseId: msg.leaseId))
    )
  of rqOfferCandidates:
    var msg: CandidateOfferMessage
    if not decodeCandidateOffer(frame.payload, msg):
      connection.sendError(frame.header.requestId, diagnostic(diagProtocol, "invalid OfferCandidates payload"))
      return
    let flow = defaultFlowControlLimits()
    if uint32(msg.candidates.len) > flow.maxCandidatesPerBatch:
      connection.sendError(frame.header.requestId, diagnostic(
        diagProtocol,
        "candidate batch exceeds negotiated flow-control limit",
        "max_candidates_per_batch=" & $flow.maxCandidatesPerBatch
      ))
      return
    if not daemon.sessions.hasKey(msg.sessionId.value):
      connection.sendError(frame.header.requestId, diagnostic(diagInvalidArgument, "unknown session id"))
      return
    var offeredIds: seq[uint64] = @[]
    var decisions: seq[LeaseDecision] = @[]
    for candidate in msg.candidates:
      var reason = ""
      if not daemon.possible(candidate.resources, reason):
        decisions.add(LeaseDecision(
          clientCandidateId: candidate.clientCandidateId,
          leaseId: leaseId(0),
          kind: leaseDecisionDenied,
          resources: candidate.resources,
          diagnostic: diagnostic(diagDenied, reason)
        ))
      else:
        let lease = daemon.createQueuedLease(
          msg.sessionId,
          candidate.clientCandidateId,
          candidate.label,
          candidate.resources,
          candidate.priority
        )
        offeredIds.add(lease.id.value)
    discard daemon.tryPromoteQueued(flow.maxLeaseDecisionsPerBatch)
    for id in offeredIds:
      var lease = daemon.leases[id]
      if lease.state == leaseStateGranted:
        lease.delivered = true
        daemon.leases[id] = lease
        decisions.add(lease.leaseDecision(leaseDecisionGranted))
      else:
        decisions.add(lease.leaseDecision(leaseDecisionQueued))
    connection.sendResponse(
      rqLeaseDecisionBatch,
      frame.header.requestId,
      encodeLeaseDecisionBatch(LeaseDecisionBatchMessage(sessionId: msg.sessionId, decisions: decisions))
    )
  of rqGrantNext:
    var msg: GrantNextMessage
    if not decodeGrantNext(frame.payload, msg):
      connection.sendError(frame.header.requestId, diagnostic(diagProtocol, "invalid GrantNext payload"))
      return
    if not daemon.sessions.hasKey(msg.sessionId.value):
      connection.sendError(frame.header.requestId, diagnostic(diagInvalidArgument, "unknown session id"))
      return
    discard daemon.tryPromoteQueued(defaultFlowControlLimits().maxLeaseDecisionsPerBatch)
    var decisions: seq[LeaseDecision] = @[]
    for id, row in daemon.leases.pairs:
      if row.sessionId.value == msg.sessionId.value and
          row.state == leaseStateGranted and not row.delivered:
        var lease = row
        lease.delivered = true
        daemon.leases[id] = lease
        decisions.add(lease.leaseDecision(leaseDecisionGranted))
        break
    connection.sendResponse(
      rqLeaseDecisionBatch,
      frame.header.requestId,
      encodeLeaseDecisionBatch(LeaseDecisionBatchMessage(sessionId: msg.sessionId, decisions: decisions))
    )
  of rqLeaseStarting:
    var msg: LeaseStartingMessage
    if not decodeLeaseStarting(frame.payload, msg):
      connection.sendError(frame.header.requestId, diagnostic(diagProtocol, "invalid LeaseStarting payload"))
      return
    var lease: LeaseRow
    if not daemon.requireOwnedLease(connection, frame.header.requestId, msg.sessionId, msg.leaseId, lease):
      return
    if lease.state != leaseStateGranted:
      connection.sendError(frame.header.requestId, diagnostic(diagInvalidArgument, "lease is not granted"))
      return
    lease.state = leaseStateStarting
    daemon.leases[msg.leaseId.value] = lease
    connection.sendResponse(
      rqLeaseStartingAck,
      frame.header.requestId,
      encodeLeaseStartingAck(LeaseStartingAckMessage(sessionId: msg.sessionId, leaseId: msg.leaseId))
    )
  of rqLeaseRunning:
    var msg: LeaseRunningMessage
    if not decodeLeaseRunning(frame.payload, msg):
      connection.sendError(frame.header.requestId, diagnostic(diagProtocol, "invalid LeaseRunning payload"))
      return
    var lease: LeaseRow
    if not daemon.requireOwnedLease(connection, frame.header.requestId, msg.sessionId, msg.leaseId, lease):
      return
    if lease.state != leaseStateGranted and lease.state != leaseStateStarting:
      connection.sendError(frame.header.requestId, diagnostic(diagInvalidArgument, "lease cannot become running"))
      return
    lease.state = leaseStateRunning
    lease.childProcessId = msg.childProcessId
    lease.processGroupId = msg.processGroupId
    lease.cleanupRegistered = msg.cleanupRegistered
    daemon.leases[msg.leaseId.value] = lease
    connection.sendResponse(
      rqLeaseRunningAck,
      frame.header.requestId,
      encodeLeaseRunningAck(LeaseRunningAckMessage(sessionId: msg.sessionId, leaseId: msg.leaseId))
    )
  of rqLeaseFinished:
    var msg: LeaseFinishedMessage
    if not decodeLeaseFinished(frame.payload, msg):
      connection.sendError(frame.header.requestId, diagnostic(diagProtocol, "invalid LeaseFinished payload"))
      return
    var lease: LeaseRow
    if not daemon.requireOwnedLease(connection, frame.header.requestId, msg.sessionId, msg.leaseId, lease):
      return
    if lease.state != leaseStateStarting and lease.state != leaseStateRunning:
      connection.sendError(frame.header.requestId, diagnostic(diagInvalidArgument, "lease is not running"))
      return
    lease.state = leaseStateFinished
    lease.finishOutcome = msg.outcome
    lease.finishDiagnostic = msg.diagnostic
    inc daemon.totalFinished
    daemon.leases[msg.leaseId.value] = lease
    discard daemon.tryPromoteQueued(defaultFlowControlLimits().maxLeaseDecisionsPerBatch)
    connection.sendResponse(
      rqLeaseFinishedAck,
      frame.header.requestId,
      encodeLeaseFinishedAck(LeaseFinishedAckMessage(sessionId: msg.sessionId, leaseId: msg.leaseId))
    )
  of rqStatusRequest:
    connection.sendResponse(rqStatusResponse, frame.header.requestId, encodeStatus(daemon.status()))
  of rqInspectionRequest:
    var msg: InspectionRequestMessage
    if not decodeInspectionRequest(frame.payload, msg):
      connection.sendError(frame.header.requestId, diagnostic(diagProtocol, "invalid InspectionRequest payload"))
      return
    connection.sendResponse(
      rqInspectionResponse,
      frame.header.requestId,
      encodeInspectionResponse(InspectionResponseMessage(json: daemon.inspectionJson(msg)))
    )
  else:
    connection.sendError(frame.header.requestId, diagnostic(diagProtocol, "unsupported RQSP message"))

proc handleConnection*(daemon: var RunQuotaDaemon; connection: var LocalConnection) =
  var context = ConnectionContext(
    supervisorProcessId: 0'u64,
    supervisorUserId: 0'u64,
    peer: PeerIdentity(
      kind: peerIdentityUnavailable,
      processId: 0'u64,
      userId: 0'u64,
      groupId: 0'u64
    ),
    sessionIds: @[]
  )
  var frame: RqspFrame
  if not connection.receiveFrameOrDiagnostic(frame):
    return
  if not daemon.handleHello(connection, context, frame):
    return
  try:
    while connection.receiveFrameOrDiagnostic(frame):
      daemon.handleRequest(connection, context, frame)
  finally:
    daemon.cleanupConnection(context)

type
  SharedDaemon = object
    lock: Lock
    daemon: RunQuotaDaemon

var sharedDaemon: SharedDaemon

proc handleSharedConnection(connection: LocalConnection) {.thread, gcsafe.} =
  {.cast(gcsafe).}:
    var localConnection = connection
    var context = ConnectionContext(
      supervisorProcessId: 0'u64,
      supervisorUserId: 0'u64,
      peer: PeerIdentity(
        kind: peerIdentityUnavailable,
        processId: 0'u64,
        userId: 0'u64,
        groupId: 0'u64
      ),
      sessionIds: @[]
    )
    var frame: RqspFrame
    if not localConnection.receiveFrameOrDiagnostic(frame):
      localConnection.close()
      return
    acquire(sharedDaemon.lock)
    let helloOk =
      try:
        sharedDaemon.daemon.handleHello(localConnection, context, frame)
      finally:
        release(sharedDaemon.lock)
    if not helloOk:
      localConnection.close()
      return
    try:
      while localConnection.receiveFrameOrDiagnostic(frame):
        acquire(sharedDaemon.lock)
        try:
          sharedDaemon.daemon.handleRequest(localConnection, context, frame)
        finally:
          release(sharedDaemon.lock)
    finally:
      acquire(sharedDaemon.lock)
      try:
        sharedDaemon.daemon.cleanupConnection(context)
      finally:
        release(sharedDaemon.lock)
      localConnection.close()

proc serve*(config: DaemonConfig): int =
  initLock(sharedDaemon.lock)
  sharedDaemon.daemon = initDaemon(config)
  var listener = bindEndpoint(config.endpoint)
  sharedDaemon.daemon.state = dsServing
  echo "runquotad listening " & config.endpoint.path
  flushFile(stdout)
  var threads: seq[Thread[LocalConnection]] = @[]
  try:
    while true:
      var connection = listener.acceptConnection()
      threads.add(default(Thread[LocalConnection]))
      createThread(threads[^1], handleSharedConnection, connection)
  finally:
    acquire(sharedDaemon.lock)
    sharedDaemon.daemon.state = dsStopping
    release(sharedDaemon.lock)
    listener.close()
    deinitLock(sharedDaemon.lock)
  0
