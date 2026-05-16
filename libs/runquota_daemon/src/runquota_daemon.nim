import std/[cpuinfo, os, tables]

import runquota_daemon/types as daemonTypes
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
    version: "0.1.0"
  )

proc initDaemon*(config: DaemonConfig): RunQuotaDaemon =
  RunQuotaDaemon(
    config: config,
    state: dsStarting,
    nextSessionId: 1'u64,
    nextLeaseId: 1'u64,
    totalGranted: 0'u64,
    totalFinished: 0'u64,
    sessions: initTable[uint64, SessionRow](),
    leases: initTable[uint64, LeaseRow]()
  )

proc countLeases(daemon: RunQuotaDaemon; state: LeaseLifecycleState): uint32 =
  for lease in daemon.leases.values:
    if lease.state == state:
      inc result

proc status*(daemon: RunQuotaDaemon): DaemonStatusMessage =
  DaemonStatusMessage(
    activeSessions: uint32(daemon.sessions.len),
    activeLeases: uint32(daemon.leases.len),
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

proc grantLease(daemon: var RunQuotaDaemon; request: LeaseRequestMessage): LeaseGrantedMessage =
  let session = daemon.sessions[request.sessionId.value]
  let id = leaseId(daemon.nextLeaseId)
  inc daemon.nextLeaseId
  inc daemon.totalGranted
  daemon.leases[id.value] = LeaseRow(
    id: id,
    sessionId: request.sessionId,
    label: request.label,
    resources: request.resources,
    state: leaseStateGranted,
    supervisorProcessId: session.supervisorProcessId,
    supervisorUserId: session.supervisorUserId,
    peer: session.peer,
    childProcessId: 0'u64,
    processGroupId: 0'u64,
    cleanupRegistered: false,
    finishOutcome: leaseFinishCancelled,
    finishDiagnostic: okDiagnostic()
  )
  LeaseGrantedMessage(
    sessionId: request.sessionId,
    leaseId: id,
    resources: request.resources
  )

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

proc cleanupLostSession(daemon: var RunQuotaDaemon; sessionId: SessionId) =
  if not daemon.sessions.hasKey(sessionId.value):
    return
  var deleteLeaseIds: seq[uint64] = @[]
  var lostLeaseIds: seq[uint64] = @[]
  for key, lease in daemon.leases.pairs:
    if lease.sessionId.value == sessionId.value:
      case lease.state
      of leaseStateGranted, leaseStateFinished:
        deleteLeaseIds.add(key)
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
      if lease.sessionId.value == msg.sessionId.value:
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
    if msg.resources.cpu.value == 0 or msg.resources.memory.value == 0:
      let denied = LeaseDeniedMessage(
        sessionId: msg.sessionId,
        diagnostic: diagnostic(diagDenied, "lease request must reserve CPU and memory")
      )
      connection.sendResponse(rqLeaseDenied, frame.header.requestId, encodeLeaseDenied(denied))
      return
    let granted = daemon.grantLease(msg)
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
    connection.sendResponse(
      rqLeaseFinishedAck,
      frame.header.requestId,
      encodeLeaseFinishedAck(LeaseFinishedAckMessage(sessionId: msg.sessionId, leaseId: msg.leaseId))
    )
  of rqStatusRequest:
    connection.sendResponse(rqStatusResponse, frame.header.requestId, encodeStatus(daemon.status()))
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
  if not connection.receiveFrame(frame):
    return
  if not daemon.handleHello(connection, context, frame):
    return
  try:
    while connection.receiveFrame(frame):
      daemon.handleRequest(connection, context, frame)
  finally:
    daemon.cleanupConnection(context)

proc serve*(config: DaemonConfig): int =
  var daemon = initDaemon(config)
  var listener = bindEndpoint(config.endpoint)
  daemon.state = dsServing
  echo "runquotad listening " & config.endpoint.path
  flushFile(stdout)
  try:
    while true:
      var connection = listener.acceptConnection()
      try:
        daemon.handleConnection(connection)
      finally:
        connection.close()
  finally:
    daemon.state = dsStopping
    listener.close()
  0
