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
    sessions: initTable[uint64, SessionRow](),
    leases: initTable[uint64, LeaseRow]()
  )

proc status*(daemon: RunQuotaDaemon): DaemonStatusMessage =
  DaemonStatusMessage(
    activeSessions: uint32(daemon.sessions.len),
    activeLeases: uint32(daemon.leases.len),
    totalGranted: daemon.totalGranted
  )

proc sendResponse(connection: var LocalConnection; kind: RqspMessageKind;
                  requestId: uint64; payload: string) =
  connection.sendFrame(encodeFrame(kind, FrameFlagResponse, requestId, payload))

proc sendError(connection: var LocalConnection; requestId: uint64; diagnostic: Diagnostic) =
  let payload = encodeProtocolError(ProtocolErrorMessage(diagnostic: diagnostic))
  connection.sendFrame(encodeFrame(rqError, FrameFlagResponse or FrameFlagError, requestId, payload))

proc handleHello(daemon: RunQuotaDaemon; connection: var LocalConnection;
                 frame: RqspFrame): bool =
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
  true

proc grantLease(daemon: var RunQuotaDaemon; request: LeaseRequestMessage): LeaseGrantedMessage =
  let id = leaseId(daemon.nextLeaseId)
  inc daemon.nextLeaseId
  inc daemon.totalGranted
  daemon.leases[id.value] = LeaseRow(
    id: id,
    sessionId: request.sessionId,
    label: request.label,
    resources: request.resources
  )
  LeaseGrantedMessage(
    sessionId: request.sessionId,
    leaseId: id,
    resources: request.resources
  )

proc handleRequest(daemon: var RunQuotaDaemon; connection: var LocalConnection;
                   frame: RqspFrame) =
  case frame.header.messageKind
  of rqRegisterSession:
    var msg: RegisterSessionMessage
    if not decodeRegisterSession(frame.payload, msg):
      connection.sendError(frame.header.requestId, diagnostic(diagProtocol, "invalid RegisterSession payload"))
      return
    let id = sessionId(daemon.nextSessionId)
    inc daemon.nextSessionId
    daemon.sessions[id.value] = SessionRow(id: id, name: msg.name, version: msg.version)
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
    daemon.leases.del(msg.leaseId.value)
    connection.sendResponse(
      rqLeaseReleased,
      frame.header.requestId,
      encodeLeaseReleased(LeaseReleasedMessage(sessionId: msg.sessionId, leaseId: msg.leaseId))
    )
  of rqStatusRequest:
    connection.sendResponse(rqStatusResponse, frame.header.requestId, encodeStatus(daemon.status()))
  else:
    connection.sendError(frame.header.requestId, diagnostic(diagProtocol, "unsupported RQSP message"))

proc handleConnection*(daemon: var RunQuotaDaemon; connection: var LocalConnection) =
  var frame: RqspFrame
  if not connection.receiveFrame(frame):
    return
  if not daemon.handleHello(connection, frame):
    return
  while connection.receiveFrame(frame):
    daemon.handleRequest(connection, frame)

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
