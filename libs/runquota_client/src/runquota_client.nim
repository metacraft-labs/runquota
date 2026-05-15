import std/os

when defined(posix):
  import std/posix

import runquota_client/types as clientTypes
import runquota_codec
import runquota_core
import runquota_ipc
import runquota_protocol

export clientTypes

const libraryName* = "runquota_client"

type
  RunQuotaClientError* = object of CatchableError

proc libraryInfo*(): clientTypes.LibraryInfo =
  clientTypes.LibraryInfo(name: libraryName)

proc resourceRequest*(label: string; cpu: MilliCpu; memory: Bytes): ResourceRequest =
  ResourceRequest(
    label: label,
    commandStatsId: "",
    resources: resourceVector(cpu, memory),
    deadline: noDeadline(),
    priority: priorityNormal,
    metadata: metadataNone()
  )

proc requestFrame(client: var RunQuotaClient; kind: RqspMessageKind; payload: string): uint64 =
  inc client.nextRequestId
  let requestId = client.nextRequestId
  client.connection.sendFrame(encodeFrame(kind, FrameFlagRequest, requestId, payload))
  requestId

proc readResponse(client: var RunQuotaClient; requestId: uint64): RqspFrame =
  var frame: RqspFrame
  if not client.connection.receiveFrame(frame):
    client.lastDiagnostic = diagnostic(diagProtocol, "daemon closed the RQSP connection")
    raise newException(RunQuotaClientError, client.lastDiagnostic.message)
  if frame.header.requestId != requestId:
    client.lastDiagnostic = diagnostic(diagProtocol, "unexpected RQSP response id")
    raise newException(RunQuotaClientError, client.lastDiagnostic.message)
  if (frame.header.flags and FrameFlagError) != 0 or frame.header.messageKind == rqError:
    var errorMessage: ProtocolErrorMessage
    if decodeProtocolError(frame.payload, errorMessage):
      client.lastDiagnostic = errorMessage.diagnostic
      raise newException(RunQuotaClientError, errorMessage.diagnostic.message)
    client.lastDiagnostic = diagnostic(diagProtocol, "invalid RQSP error payload")
    raise newException(RunQuotaClientError, client.lastDiagnostic.message)
  frame

proc connect*(endpoint: Endpoint; clientName = "runquota-nim";
              clientVersion = "0.1.0"): RunQuotaClient =
  result = RunQuotaClient(
    connection: connectEndpoint(endpoint),
    nextRequestId: 0'u64,
    state: csConnected,
    daemonId: 0'u64,
    daemonVersion: "",
    capabilities: defaultCapabilities("unknown", "unknown", milliCpu(0), bytes(0)),
    flow: defaultFlowControlLimits(),
    lastDiagnostic: okDiagnostic()
  )
  let pid =
    when declared(getCurrentProcessId):
      uint64(getCurrentProcessId())
    else:
      0'u64
  let uid =
    when defined(posix):
      uint64(getuid())
    else:
      0'u64
  let hello = HelloMessage(
    clientName: clientName,
    clientVersion: clientVersion,
    minProtocolMajor: RqspProtocolMajor,
    maxProtocolMajor: RqspProtocolMajor,
    processId: pid,
    userId: uid,
    desiredCapabilities: "m1-lease"
  )
  let requestId = result.requestFrame(rqHello, encodeHello(hello))
  let frame = result.readResponse(requestId)
  if frame.header.messageKind != rqHelloOk:
    result.lastDiagnostic = diagnostic(diagProtocol, "daemon did not answer Hello with HelloOk")
    raise newException(RunQuotaClientError, result.lastDiagnostic.message)
  var helloOk: HelloOkMessage
  if not decodeHelloOk(frame.payload, helloOk):
    result.lastDiagnostic = diagnostic(diagProtocol, "invalid HelloOk payload")
    raise newException(RunQuotaClientError, result.lastDiagnostic.message)
  result.daemonId = helloOk.daemonId
  result.daemonVersion = helloOk.daemonVersion
  result.capabilities = helloOk.capabilities
  result.flow = helloOk.flow

proc connectDefault*(): RunQuotaClient =
  connect(defaultEndpoint())

proc close*(client: var RunQuotaClient) =
  if client.state == csConnected:
    client.connection.close()
  client.state = csClosed

proc registerSession*(client: var RunQuotaClient; name, version: string): RunQuotaSession =
  let msg = RegisterSessionMessage(name: name, version: version, metadata: metadataNone())
  let requestId = client.requestFrame(rqRegisterSession, encodeRegisterSession(msg))
  let frame = client.readResponse(requestId)
  if frame.header.messageKind != rqSessionRegistered:
    client.lastDiagnostic = diagnostic(diagProtocol, "daemon did not register the session")
    raise newException(RunQuotaClientError, client.lastDiagnostic.message)
  var registered: SessionRegisteredMessage
  if not decodeSessionRegistered(frame.payload, registered):
    client.lastDiagnostic = diagnostic(diagProtocol, "invalid SessionRegistered payload")
    raise newException(RunQuotaClientError, client.lastDiagnostic.message)
  RunQuotaSession(client: addr client, id: registered.sessionId, active: true)

proc closeSession*(session: var RunQuotaSession) =
  if not session.active:
    return
  let msg = CloseSessionMessage(sessionId: session.id)
  let requestId = session.client[].requestFrame(rqCloseSession, encodeCloseSession(msg))
  let frame = session.client[].readResponse(requestId)
  if frame.header.messageKind != rqSessionClosed:
    session.client[].lastDiagnostic = diagnostic(diagProtocol, "daemon did not close the session")
    raise newException(RunQuotaClientError, session.client[].lastDiagnostic.message)
  var closed: SessionClosedMessage
  if not decodeSessionClosed(frame.payload, closed) or closed.sessionId.value != session.id.value:
    session.client[].lastDiagnostic = diagnostic(diagProtocol, "invalid SessionClosed payload")
    raise newException(RunQuotaClientError, session.client[].lastDiagnostic.message)
  session.active = false

proc requestLease*(session: var RunQuotaSession; request: ResourceRequest): RunQuotaLease =
  if not session.active:
    session.client[].lastDiagnostic = diagnostic(diagInvalidArgument, "session is not active")
    raise newException(RunQuotaClientError, session.client[].lastDiagnostic.message)
  let msg = LeaseRequestMessage(
    sessionId: session.id,
    label: request.label,
    commandStatsId: request.commandStatsId,
    resources: request.resources,
    deadline: request.deadline,
    priority: request.priority,
    metadata: request.metadata
  )
  let requestId = session.client[].requestFrame(rqRequestLease, encodeLeaseRequest(msg))
  let frame = session.client[].readResponse(requestId)
  case frame.header.messageKind
  of rqLeaseGranted:
    var granted: LeaseGrantedMessage
    if not decodeLeaseGranted(frame.payload, granted):
      session.client[].lastDiagnostic = diagnostic(diagProtocol, "invalid LeaseGranted payload")
      raise newException(RunQuotaClientError, session.client[].lastDiagnostic.message)
    RunQuotaLease(
      session: addr session,
      id: granted.leaseId,
      resources: granted.resources,
      active: true
    )
  of rqLeaseDenied:
    var denied: LeaseDeniedMessage
    if decodeLeaseDenied(frame.payload, denied):
      session.client[].lastDiagnostic = denied.diagnostic
      raise newException(RunQuotaClientError, denied.diagnostic.message)
    session.client[].lastDiagnostic = diagnostic(diagProtocol, "invalid LeaseDenied payload")
    raise newException(RunQuotaClientError, session.client[].lastDiagnostic.message)
  else:
    session.client[].lastDiagnostic = diagnostic(diagProtocol, "daemon did not answer with a lease decision")
    raise newException(RunQuotaClientError, session.client[].lastDiagnostic.message)

proc release*(lease: var RunQuotaLease) =
  if not lease.active:
    return
  let msg = ReleaseLeaseMessage(sessionId: lease.session[].id, leaseId: lease.id)
  let requestId = lease.session[].client[].requestFrame(rqReleaseLease, encodeReleaseLease(msg))
  let frame = lease.session[].client[].readResponse(requestId)
  if frame.header.messageKind != rqLeaseReleased:
    lease.session[].client[].lastDiagnostic = diagnostic(diagProtocol, "daemon did not release the lease")
    raise newException(RunQuotaClientError, lease.session[].client[].lastDiagnostic.message)
  var released: LeaseReleasedMessage
  if not decodeLeaseReleased(frame.payload, released) or released.leaseId.value != lease.id.value:
    lease.session[].client[].lastDiagnostic = diagnostic(diagProtocol, "invalid LeaseReleased payload")
    raise newException(RunQuotaClientError, lease.session[].client[].lastDiagnostic.message)
  lease.active = false

proc daemonStatus*(client: var RunQuotaClient): DaemonStatusMessage =
  let requestId = client.requestFrame(rqStatusRequest, "")
  let frame = client.readResponse(requestId)
  if frame.header.messageKind != rqStatusResponse:
    client.lastDiagnostic = diagnostic(diagProtocol, "daemon did not answer with status")
    raise newException(RunQuotaClientError, client.lastDiagnostic.message)
  if not decodeStatus(frame.payload, result):
    client.lastDiagnostic = diagnostic(diagProtocol, "invalid StatusResponse payload")
    raise newException(RunQuotaClientError, client.lastDiagnostic.message)

template withLease*(session: var RunQuotaSession; request: ResourceRequest; body: untyped) =
  var lease {.inject.} = requestLease(session, request)
  try:
    body
  finally:
    release(lease)
