import std/[os, tables, strutils]

when defined(posix):
  import std/posix

import runquota_client/types as clientTypes
import runquota_client/standalone as clientStandalone
import runquota_codec
import runquota_core
import runquota_ipc
import runquota_protocol

export clientTypes
export clientStandalone

const libraryName* = "runquota_client"

proc handshakeTimeoutMs(): int =
  ## Bound for the quick control handshakes (Hello / RegisterSession /
  ## CloseSession). A runquota daemon that accepts the connection but never
  ## answers — wedged, stale, or protocol-incompatible — must not block the
  ## caller forever; the read fails so the caller can fall back (the engine's
  ## documented ``fallbackToRunQuotaBypass`` path) instead of hanging. The
  ## default is deliberately generous so a merely busy daemon under heavy
  ## parallel load is never mistaken for an unresponsive one; operators can
  ## tune it via ``RUNQUOTA_HANDSHAKE_TIMEOUT_MS`` (``0`` restores the old
  ## unbounded blocking behaviour). The long-running grant stream is never
  ## bounded by this — only the control handshakes are.
  let override = getEnv("RUNQUOTA_HANDSHAKE_TIMEOUT_MS")
  if override.len > 0:
    try:
      return max(0, parseInt(override))
    except ValueError:
      discard
  30_000

type
  RunQuotaClientError* = object of CatchableError

proc libraryInfo*(): clientTypes.LibraryInfo =
  clientTypes.LibraryInfo(name: libraryName)

proc resourceRequest*(label: string; cpu: MilliCpu;
    memory: Bytes): ResourceRequest =
  ResourceRequest(
    label: label,
    commandStatsId: "",
    resources: resourceVector(cpu, memory),
    deadline: noDeadline(),
    priority: priorityNormal,
    purpose: leasePurposeWork,
    metadata: metadataNone(),
    estimate: ClientEstimate(supplied: false, memoryBytes: 0'u64)
  )

proc withEstimate*(request: ResourceRequest;
                   memoryBytes: uint64): ResourceRequest =
  ## Attaches the client's OWN estimate to a request.
  ##
  ## The daemon takes it at face value: it MUST NOT clamp it, second-guess
  ## it, or validate it against its own learned table. That is only sound
  ## because the blast radius stops at the per-user boundary — a client
  ## that under-declares spends its own user's budget — and it is what lets
  ## the estimate arrive WITH the request, so admission costs no round trip
  ## at the moment of asking.
  result = request
  result.estimate = ClientEstimate(supplied: true, memoryBytes: memoryBytes)

proc benchmarkRequest*(request: ResourceRequest): ResourceRequest =
  result = request
  result.purpose = leasePurposeBenchmark

proc forMachine*(request: ResourceRequest; machineId: string): ResourceRequest =
  result = request
  result.resources = result.resources.forMachine(machineId)

proc requestFrame(client: var RunQuotaClient; kind: RqspMessageKind;
    payload: string): uint64 =
  if uint32(client.inflightRequestIds.len) >= client.flow.maxInflightRequests:
    client.lastDiagnostic = diagnostic(diagProtocol, "in-flight request limit exceeded")
    raise newException(RunQuotaClientError, client.lastDiagnostic.message)
  inc client.nextRequestId
  let requestId = client.nextRequestId
  client.connection.sendFrame(encodeFrame(kind, FrameFlagRequest, requestId, payload))
  client.inflightRequestIds.add(requestId)
  requestId

proc forgetInflight(client: var RunQuotaClient; requestId: uint64) =
  for i, id in client.inflightRequestIds:
    if id == requestId:
      client.inflightRequestIds.delete(i)
      return

proc readResponse(client: var RunQuotaClient; requestId: uint64;
                  timeoutMs = 0): RqspFrame =
  ## Read the response frame for ``requestId``. ``timeoutMs > 0`` bounds the
  ## read so an unresponsive daemon raises ``RunQuotaClientError`` instead of
  ## blocking forever; callers on the long-running grant stream pass ``0``.
  if client.responseBuffer.hasKey(requestId):
    result = client.responseBuffer[requestId]
    client.responseBuffer.del(requestId)
    client.forgetInflight(requestId)
  else:
    while true:
      var frame: RqspFrame
      if not client.connection.receiveFrame(frame, timeoutMs):
        client.lastDiagnostic = diagnostic(diagProtocol, "daemon closed the RQSP connection")
        raise newException(RunQuotaClientError, client.lastDiagnostic.message)
      if frame.header.requestId == requestId:
        result = frame
        client.forgetInflight(requestId)
        break
      client.responseBuffer[frame.header.requestId] = frame
  if (result.header.flags and FrameFlagError) != 0 or
      result.header.messageKind == rqError:
    var errorMessage: ProtocolErrorMessage
    if decodeProtocolError(result.payload, errorMessage):
      client.lastDiagnostic = errorMessage.diagnostic
      raise newException(RunQuotaClientError, errorMessage.diagnostic.message)
    client.lastDiagnostic = diagnostic(diagProtocol, "invalid RQSP error payload")
    raise newException(RunQuotaClientError, client.lastDiagnostic.message)

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
    lastDiagnostic: okDiagnostic(),
    responseBuffer: initTable[uint64, RqspFrame](),
    inflightRequestIds: @[]
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
  let frame = result.readResponse(requestId, handshakeTimeoutMs())
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

proc registerSession*(client: var RunQuotaClient; name,
    version: string): RunQuotaSession =
  let msg = RegisterSessionMessage(name: name, version: version,
      metadata: metadataNone())
  let requestId = client.requestFrame(rqRegisterSession, encodeRegisterSession(msg))
  let frame = client.readResponse(requestId, handshakeTimeoutMs())
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
  let requestId = session.client[].requestFrame(rqCloseSession,
      encodeCloseSession(msg))
  let frame = session.client[].readResponse(requestId, handshakeTimeoutMs())
  if frame.header.messageKind != rqSessionClosed:
    session.client[].lastDiagnostic = diagnostic(diagProtocol, "daemon did not close the session")
    raise newException(RunQuotaClientError, session.client[].lastDiagnostic.message)
  var closed: SessionClosedMessage
  if not decodeSessionClosed(frame.payload, closed) or closed.sessionId.value !=
      session.id.value:
    session.client[].lastDiagnostic = diagnostic(diagProtocol, "invalid SessionClosed payload")
    raise newException(RunQuotaClientError, session.client[].lastDiagnostic.message)
  session.active = false

proc requestLease*(session: var RunQuotaSession;
    request: ResourceRequest): RunQuotaLease =
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
    purpose: request.purpose,
    metadata: request.metadata,
    estimate: request.estimate
  )
  let requestId = session.client[].requestFrame(rqRequestLease,
      encodeLeaseRequest(msg))
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
      active: true,
      state: leaseClientGranted
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

proc toCandidate*(clientCandidateId: uint64;
    request: ResourceRequest): LeaseCandidate =
  LeaseCandidate(
    clientCandidateId: clientCandidateId,
    label: request.label,
    commandStatsId: request.commandStatsId,
    resources: request.resources,
    deadline: request.deadline,
    priority: request.priority,
    purpose: request.purpose,
    metadata: request.metadata,
    estimate: request.estimate
  )

proc sendCandidateOffer*(session: var RunQuotaSession;
                         candidates: openArray[LeaseCandidate]): uint64 =
  if not session.active:
    session.client[].lastDiagnostic = diagnostic(diagInvalidArgument, "session is not active")
    raise newException(RunQuotaClientError, session.client[].lastDiagnostic.message)
  if uint32(candidates.len) > session.client[].flow.maxCandidatesPerBatch:
    session.client[].lastDiagnostic = diagnostic(diagInvalidArgument, "candidate batch exceeds flow-control limit")
    raise newException(RunQuotaClientError, session.client[].lastDiagnostic.message)
  var copied: seq[LeaseCandidate] = @[]
  for candidate in candidates:
    copied.add(candidate)
  let msg = CandidateOfferMessage(sessionId: session.id, candidates: copied)
  session.client[].requestFrame(rqOfferCandidates, encodeCandidateOffer(msg))

proc decodeDecisionBatch(session: var RunQuotaSession; frame: RqspFrame): seq[OfferedLease] =
  if frame.header.messageKind != rqLeaseDecisionBatch:
    session.client[].lastDiagnostic = diagnostic(diagProtocol, "daemon did not answer with a lease decision batch")
    raise newException(RunQuotaClientError, session.client[].lastDiagnostic.message)
  var batch: LeaseDecisionBatchMessage
  if not decodeLeaseDecisionBatch(frame.payload, batch) or
      batch.sessionId.value != session.id.value:
    session.client[].lastDiagnostic = diagnostic(diagProtocol, "invalid LeaseDecisionBatch payload")
    raise newException(RunQuotaClientError, session.client[].lastDiagnostic.message)
  for decision in batch.decisions:
    let active = decision.kind == leaseDecisionGranted or decision.kind == leaseDecisionQueued
    result.add(OfferedLease(
      clientCandidateId: decision.clientCandidateId,
      lease: RunQuotaLease(
        session: addr session,
        id: decision.leaseId,
        resources: decision.resources,
        active: active,
        state: if decision.kind == leaseDecisionGranted: leaseClientGranted else: leaseClientQueued
      ),
      queued: decision.kind == leaseDecisionQueued,
      diagnostic: decision.diagnostic
    ))

proc receiveCandidateDecisions*(session: var RunQuotaSession;
    requestId: uint64): seq[OfferedLease] =
  session.decodeDecisionBatch(session.client[].readResponse(requestId))

proc offerCandidates*(session: var RunQuotaSession;
                      candidates: openArray[LeaseCandidate]): seq[OfferedLease] =
  let requestId = session.sendCandidateOffer(candidates)
  session.receiveCandidateDecisions(requestId)

proc pollNextGrant*(session: var RunQuotaSession): seq[OfferedLease] =
  let msg = GrantNextMessage(sessionId: session.id)
  let requestId = session.client[].requestFrame(rqGrantNext, encodeGrantNext(msg))
  session.decodeDecisionBatch(session.client[].readResponse(requestId))

type
  GrantPollKind* = enum
    ## Result of one bounded ``pollNextGrantBounded`` attempt.
    ##
    ## ``grantPollFrame`` — the daemon answered the outstanding GrantNext
    ##   with a decision batch (which may be *empty* while the candidate is
    ##   still legitimately queued).  A received frame — empty or not — is
    ##   proof the daemon is alive (liveness), so callers treat it as a
    ##   reason to reset any "unresponsive" deadline, NOT as silence.
    ## ``grantPollTimeout`` — no complete frame arrived within the bounded
    ##   read window.  The GrantNext stays outstanding (its request id is
    ##   parked on the session) so the next bounded read continues waiting
    ##   on the same request rather than emitting a fresh GrantNext.  A
    ##   timeout is *ambiguous* on its own (a merely-slow daemon vs a
    ##   wedged one); callers disambiguate with a ``daemonStatus`` liveness
    ##   probe before concluding the daemon is unresponsive.
    grantPollFrame
    grantPollTimeout

  GrantPollFrame* = object
    kind*: GrantPollKind
    decisions*: seq[OfferedLease]   ## valid when ``kind == grantPollFrame``.

proc pollNextGrantBounded*(session: var RunQuotaSession;
                           timeoutMs: int): GrantPollFrame =
  ## Bounded variant of ``pollNextGrant`` used by long waits that must stay
  ## observable and must distinguish a *queued-but-alive* daemon from a
  ## *silent* one.
  ##
  ## A single GrantNext is kept outstanding across attempts: the first call
  ## sends one and parks its request id on the session; while the daemon
  ## stays silent each subsequent call re-reads that same request id with a
  ## fresh bounded window (no new GrantNext is sent, so a wedged daemon can
  ## never accumulate buffered late responses).  As soon as the daemon
  ## answers, the parked id is cleared and the next call issues a new
  ## GrantNext.
  ##
  ## ``timeoutMs <= 0`` falls back to a single blocking round-trip
  ## (equivalent to ``pollNextGrant``) so callers that want the legacy
  ## behaviour still work.
  if not session.active:
    session.client[].lastDiagnostic =
      diagnostic(diagInvalidArgument, "session is not active")
    raise newException(RunQuotaClientError, session.client[].lastDiagnostic.message)
  if timeoutMs <= 0:
    return GrantPollFrame(kind: grantPollFrame, decisions: session.pollNextGrant())
  if session.pendingGrantRequestId == 0'u64:
    let msg = GrantNextMessage(sessionId: session.id)
    session.pendingGrantRequestId =
      session.client[].requestFrame(rqGrantNext, encodeGrantNext(msg))
  let requestId = session.pendingGrantRequestId
  # If the response was already buffered by an earlier read, take it now.
  if session.client[].responseBuffer.hasKey(requestId):
    let frame = session.client[].readResponse(requestId)
    session.pendingGrantRequestId = 0'u64
    return GrantPollFrame(kind: grantPollFrame,
      decisions: session.decodeDecisionBatch(frame))
  # Bounded read for THIS request id.  Buffer any other frames we see so a
  # later read can match them.  A read that returns no frame is reported as
  # a timeout, leaving the GrantNext outstanding.
  var frame: RqspFrame
  if not session.client[].connection.receiveFrame(frame, timeoutMs):
    # No complete frame within the window.  This is EITHER a clean timeout
    # (the daemon is alive but the candidate is still queued and it sent
    # nothing) OR a closed connection.  We do NOT decide that here: the
    # caller runs a ``daemonStatus`` liveness probe to disambiguate.  The
    # request id stays parked so we keep waiting on the same GrantNext.
    return GrantPollFrame(kind: grantPollTimeout)
  if frame.header.requestId != requestId:
    session.client[].responseBuffer[frame.header.requestId] = frame
    # We received *a* frame (liveness) but not the one we wanted; report it
    # as a timeout for this request so the caller resets its clock on the
    # next bounded read picking up the right id — but the parked id stays.
    return GrantPollFrame(kind: grantPollTimeout)
  session.client[].forgetInflight(requestId)
  session.pendingGrantRequestId = 0'u64
  if (frame.header.flags and FrameFlagError) != 0 or
      frame.header.messageKind == rqError:
    var errorMessage: ProtocolErrorMessage
    if decodeProtocolError(frame.payload, errorMessage):
      session.client[].lastDiagnostic = errorMessage.diagnostic
      raise newException(RunQuotaClientError, errorMessage.diagnostic.message)
    session.client[].lastDiagnostic =
      diagnostic(diagProtocol, "invalid RQSP error payload")
    raise newException(RunQuotaClientError, session.client[].lastDiagnostic.message)
  GrantPollFrame(kind: grantPollFrame, decisions: session.decodeDecisionBatch(frame))

proc requestLeaseWaiting*(session: var RunQuotaSession; request: ResourceRequest;
                          pollMillis = 50; maxPolls = 0): RunQuotaLease =
  if not session.active:
    session.client[].lastDiagnostic = diagnostic(diagInvalidArgument, "session is not active")
    raise newException(RunQuotaClientError, session.client[].lastDiagnostic.message)
  let candidateId = session.client[].nextRequestId + 1'u64
  let requestId = session.sendCandidateOffer([toCandidate(candidateId, request)])
  let decisions = session.receiveCandidateDecisions(requestId)
  var queued = false
  for decision in decisions:
    if decision.clientCandidateId == candidateId:
      if not decision.lease.active:
        session.client[].lastDiagnostic = decision.diagnostic
        raise newException(RunQuotaClientError, decision.diagnostic.message)
      if decision.queued:
        queued = true
        break
      return decision.lease
  if not queued:
    session.client[].lastDiagnostic = diagnostic(diagProtocol, "daemon omitted lease decision")
    raise newException(RunQuotaClientError, session.client[].lastDiagnostic.message)
  var polls = 0
  while maxPolls <= 0 or polls < maxPolls:
    let grants = session.pollNextGrant()
    for grant in grants:
      if grant.clientCandidateId == candidateId and not grant.queued:
        return grant.lease
    inc polls
    sleep(pollMillis)
  session.client[].lastDiagnostic = diagnostic(diagDenied, "timed out waiting for lease grant")
  raise newException(RunQuotaClientError, session.client[].lastDiagnostic.message)

# ---------------------------------------------------------------------------
# Domain extensions: the write path (M17)
# ---------------------------------------------------------------------------

proc declareExtension*(session: var RunQuotaSession;
                       extensionId, owner: string; schemaVersion: int64;
                       migrations: openArray[string]): string =
  ## Register an extension, returning "" on acceptance and the daemon's
  ## outcome name on refusal.
  ##
  ## OVER THE SOCKET, for the same reason ``queryStats`` is: this library
  ## does not link the observation store and must not. A product owns its
  ## extension's schema; RunQuota owns where and how it is stored, and the
  ## only place those two meet is here.
  ##
  ## REQUEST/RESPONSE, unlike a row. This is not an observation: it
  ## happens once per client, its payload is a DDL ladder rather than a
  ## measurement, and its answer decides whether any row may be sent at
  ## all. Making it one-way would leave a client writing rows into a
  ## table that was refused, and finding out never.
  var steps: seq[string] = @[]
  for step in migrations:
    steps.add(step)
  let msg = DeclareExtensionMessage(
    sessionId: session.id,
    extensionId: extensionId,
    owner: owner,
    schemaVersion: uint32(max(0'i64, schemaVersion)),
    migrations: steps)
  let requestId = session.client[].requestFrame(rqDeclareExtension,
    encodeDeclareExtension(msg))
  let frame = session.client[].readResponse(requestId)
  if frame.header.messageKind != rqExtensionDeclared:
    session.client[].lastDiagnostic = diagnostic(diagProtocol,
      "daemon did not answer the extension declaration")
    raise newException(RunQuotaClientError,
      session.client[].lastDiagnostic.message)
  var declared: ExtensionDeclaredMessage
  if not decodeExtensionDeclared(frame.payload, declared):
    session.client[].lastDiagnostic = diagnostic(diagProtocol,
      "invalid ExtensionDeclared payload")
    raise newException(RunQuotaClientError,
      session.client[].lastDiagnostic.message)
  if declared.accepted: "" else: declared.outcome

proc recordExtensionRow*(session: var RunQuotaSession; leaseId: uint64;
                         extensionId: string; schemaVersion: int64;
                         columns: openArray[string];
                         values: openArray[ExtensionCellWire]) =
  ## Attach one extension row to the execution the named lease produced.
  ##
  ## ONE BUFFERED WRITE AND NO ROUND TRIP, exactly like ``lease.observe``.
  ## Nothing is read back and no in-flight slot is consumed: §"Write Path"
  ## forbids an observation from introducing an additional round trip and
  ## OS-1 forbids recording one from blocking the work being observed.
  ##
  ## SILENT ON A DEAD CONNECTION, deliberately. A failed send is a lost
  ## observation, and losing one is always preferable to perturbing the
  ## work being observed.
  var columnNames: seq[string] = @[]
  for name in columns:
    columnNames.add(name)
  var cells: seq[ExtensionCellWire] = @[]
  for cell in values:
    cells.add(cell)
  let msg = ExtensionRowMessage(
    sessionId: session.id,
    leaseId: leaseId(leaseId),
    extensionId: extensionId,
    schemaVersion: uint32(max(0'i64, schemaVersion)),
    columns: columnNames,
    values: cells)
  inc session.client[].nextRequestId
  let requestId = session.client[].nextRequestId
  try:
    session.client[].connection.sendFrame(
      encodeFrame(rqExtensionRow, FrameFlagRequest, requestId,
        encodeExtensionRow(msg)))
  except CatchableError:
    discard

proc queryStats*(client: var RunQuotaClient; subject: StatsSubject;
                 statsKey = ""; scope = statsScopeWireOwner;
                 span = profileSpanWireSingle; limit = 0'u32;
                 extensionId = ""; extensionColumns: openArray[string] = [];
                 sessionId = sessionId(0)): StatsResponseMessage =
  ## Ask ``runquotad`` a question about the recorded rows.
  ##
  ## OVER THE SOCKET, WHICH IS THE WHOLE POINT OF THIS PROC EXISTING. This
  ## library does not link the observation store and MUST NOT: ``runquotad``
  ## is the only sanctioned reader, and a client that opened the database
  ## file would be a second reader of a schema RunQuota owns, past every
  ## scoping rule the daemon applies. That is not merely discouraged; it is
  ## checked by inspection (``t_observation_store_reader_boundary``).
  ##
  ## The uid this answer is scoped to is NOT a parameter. It comes from the
  ## connection's peer credentials on the daemon side; a caller can widen
  ## to ``statsScopeWireHost``, which is explicit and available, but it
  ## cannot name somebody else.
  var columns: seq[string] = @[]
  for name in extensionColumns:
    columns.add(name)
  let msg = StatsQueryMessage(
    sessionId: sessionId,
    subject: subject,
    statsKey: statsKey,
    scope: scope,
    span: span,
    limit: limit,
    extensionId: extensionId,
    extensionColumns: columns
  )
  let requestId = client.requestFrame(rqStatsQuery, encodeStatsQuery(msg))
  let frame = client.readResponse(requestId)
  if frame.header.messageKind != rqStatsResponse:
    client.lastDiagnostic = diagnostic(diagProtocol,
      "daemon did not answer with stats data")
    raise newException(RunQuotaClientError, client.lastDiagnostic.message)
  if not decodeStatsResponse(frame.payload, result):
    client.lastDiagnostic = diagnostic(diagProtocol,
      "invalid StatsResponse payload")
    raise newException(RunQuotaClientError, client.lastDiagnostic.message)

proc inspectionJson*(client: var RunQuotaClient; subject: string;
                     sessionId = sessionId(0)): string =
  let msg = InspectionRequestMessage(subject: subject, sessionId: sessionId)
  let requestId = client.requestFrame(rqInspectionRequest,
      encodeInspectionRequest(msg))
  let frame = client.readResponse(requestId)
  if frame.header.messageKind != rqInspectionResponse:
    client.lastDiagnostic = diagnostic(diagProtocol, "daemon did not answer with inspection data")
    raise newException(RunQuotaClientError, client.lastDiagnostic.message)
  var response: InspectionResponseMessage
  if not decodeInspectionResponse(frame.payload, response):
    client.lastDiagnostic = diagnostic(diagProtocol, "invalid InspectionResponse payload")
    raise newException(RunQuotaClientError, client.lastDiagnostic.message)
  response.json

proc release*(lease: var RunQuotaLease) =
  if not lease.active:
    return
  let msg = ReleaseLeaseMessage(sessionId: lease.session[].id,
      leaseId: lease.id)
  let requestId = lease.session[].client[].requestFrame(rqReleaseLease,
      encodeReleaseLease(msg))
  let frame = lease.session[].client[].readResponse(requestId)
  if frame.header.messageKind != rqLeaseReleased:
    lease.session[].client[].lastDiagnostic = diagnostic(diagProtocol, "daemon did not release the lease")
    raise newException(RunQuotaClientError, lease.session[].client[].lastDiagnostic.message)
  var released: LeaseReleasedMessage
  if not decodeLeaseReleased(frame.payload, released) or
      released.leaseId.value != lease.id.value:
    lease.session[].client[].lastDiagnostic = diagnostic(diagProtocol, "invalid LeaseReleased payload")
    raise newException(RunQuotaClientError, lease.session[].client[].lastDiagnostic.message)
  lease.active = false
  lease.state = leaseClientReleased

proc markStarting*(lease: var RunQuotaLease) =
  if not lease.active:
    return
  let msg = LeaseStartingMessage(sessionId: lease.session[].id,
      leaseId: lease.id)
  let requestId = lease.session[].client[].requestFrame(rqLeaseStarting,
      encodeLeaseStarting(msg))
  let frame = lease.session[].client[].readResponse(requestId)
  if frame.header.messageKind != rqLeaseStartingAck:
    lease.session[].client[].lastDiagnostic = diagnostic(diagProtocol, "daemon did not mark the lease starting")
    raise newException(RunQuotaClientError, lease.session[].client[].lastDiagnostic.message)
  var acknowledged: LeaseStartingAckMessage
  if not decodeLeaseStartingAck(frame.payload, acknowledged) or
      acknowledged.leaseId.value != lease.id.value:
    lease.session[].client[].lastDiagnostic = diagnostic(diagProtocol, "invalid LeaseStartingAck payload")
    raise newException(RunQuotaClientError, lease.session[].client[].lastDiagnostic.message)
  lease.state = leaseClientStarting

proc markRunning*(lease: var RunQuotaLease; childProcessId = 0'u64;
                  processGroupId = 0'u64; cleanupRegistered = false) =
  if not lease.active:
    return
  let msg = LeaseRunningMessage(
    sessionId: lease.session[].id,
    leaseId: lease.id,
    childProcessId: childProcessId,
    processGroupId: processGroupId,
    cleanupRegistered: cleanupRegistered
  )
  let requestId = lease.session[].client[].requestFrame(rqLeaseRunning,
      encodeLeaseRunning(msg))
  let frame = lease.session[].client[].readResponse(requestId)
  if frame.header.messageKind != rqLeaseRunningAck:
    lease.session[].client[].lastDiagnostic = diagnostic(diagProtocol, "daemon did not mark the lease running")
    raise newException(RunQuotaClientError, lease.session[].client[].lastDiagnostic.message)
  var acknowledged: LeaseRunningAckMessage
  if not decodeLeaseRunningAck(frame.payload, acknowledged) or
      acknowledged.leaseId.value != lease.id.value:
    lease.session[].client[].lastDiagnostic = diagnostic(diagProtocol, "invalid LeaseRunningAck payload")
    raise newException(RunQuotaClientError, lease.session[].client[].lastDiagnostic.message)
  lease.state = leaseClientRunning

proc reportObservation*(lease: var RunQuotaLease; cpuMilliPct: uint32;
                        rssBytes: uint64; sampledAtUnixMillis: uint64) =
  ## Report what this client has MEASURED about its own running child.
  ##
  ## ONE BUFFERED WRITE AND NO ROUND TRIP. Nothing is read back, no request
  ## id is registered, and no in-flight slot is consumed: §"Write Path"
  ## forbids an observation from introducing an additional round trip, and
  ## OS-1 forbids recording one from blocking the work being observed. A
  ## caller sends this from the loop it already runs while waiting for its
  ## child, next to the telemetry sample it already takes.
  ##
  ## THE FIGURES MUST BE MEASURED. Passing the lease's requested resources
  ## here would put a reservation into `self_*` — a number nobody measured,
  ## in a column whose entire purpose is to be one — and the daemon has no
  ## way to tell the two apart. `runquota_process` samples the child's
  ## resident size and CPU time while it waits; that is the source.
  ##
  ## SILENT ON A DEAD CONNECTION, deliberately. A failed send is a lost
  ## observation, and losing an observation is always preferable to
  ## perturbing the work being observed. The caller finds out about a dead
  ## daemon on the next message it actually needs an answer to.
  if not lease.active:
    return
  let msg = LeaseObservationMessage(
    sessionId: lease.session[].id,
    leaseId: lease.id,
    cpuMilliPct: cpuMilliPct,
    rssBytes: rssBytes,
    sampledAtUnixMillis: sampledAtUnixMillis
  )
  inc lease.session[].client[].nextRequestId
  let requestId = lease.session[].client[].nextRequestId
  try:
    lease.session[].client[].connection.sendFrame(
      encodeFrame(rqLeaseObservation, FrameFlagRequest, requestId,
        encodeLeaseObservation(msg)))
  except CatchableError:
    discard

proc finish*(lease: var RunQuotaLease; outcome = succeeded();
             finishDiagnostic = okDiagnostic();
             peakMemoryBytes = 0'u64; processCount = 0'u32;
             majorPageFaults = 0'u64; pressureEvents = 0'u32) =
  ## Report how this execution ended, and free what it held.
  ##
  ## ONE PARAMETER SAYS WHY IT ENDED, and it is a ``LeaseFinish``. It used
  ## to be four -- an outcome, an exit code, a signal and an
  ## ``hardLimitOrOom`` flag -- which between them could describe a
  ## process that was killed for exceeding memory AND exited successfully.
  ## The daemon had to refuse that at runtime because this signature let a
  ## caller write it by accident. It no longer can: the conclusion and the
  ## evidence for it arrive together or not at all, and the constructors
  ## in ``runquota_protocol`` are the only way to pair them.
  if not lease.active:
    return
  let msg = LeaseFinishedMessage(
    sessionId: lease.session[].id,
    leaseId: lease.id,
    finish: outcome,
    peakMemoryBytes: peakMemoryBytes,
    processCount: processCount,
    majorPageFaults: majorPageFaults,
    pressureEvents: pressureEvents,
    diagnostic: finishDiagnostic
  )
  let requestId = lease.session[].client[].requestFrame(rqLeaseFinished,
      encodeLeaseFinished(msg))
  let frame = lease.session[].client[].readResponse(requestId)
  if frame.header.messageKind != rqLeaseFinishedAck:
    lease.session[].client[].lastDiagnostic = diagnostic(diagProtocol, "daemon did not record LeaseFinished")
    raise newException(RunQuotaClientError, lease.session[].client[].lastDiagnostic.message)
  var acknowledged: LeaseFinishedAckMessage
  if not decodeLeaseFinishedAck(frame.payload, acknowledged) or
      acknowledged.leaseId.value != lease.id.value:
    lease.session[].client[].lastDiagnostic = diagnostic(diagProtocol, "invalid LeaseFinishedAck payload")
    raise newException(RunQuotaClientError, lease.session[].client[].lastDiagnostic.message)
  lease.state = leaseClientFinished

proc daemonStatus*(client: var RunQuotaClient;
                   timeoutMs = 0): DaemonStatusMessage =
  ## Round-trip a StatusRequest.  ``timeoutMs > 0`` bounds the read so a
  ## wedged daemon (accepts the connection but never answers) raises
  ## ``RunQuotaClientError`` instead of blocking forever — this is what
  ## makes ``daemonStatus`` usable as a *liveness probe*: a bounded
  ## successful round-trip proves the daemon is alive, while a timeout (or
  ## a closed connection) is detectable as silence.  ``timeoutMs == 0``
  ## keeps the legacy unbounded behaviour.
  let requestId = client.requestFrame(rqStatusRequest, "")
  let frame = client.readResponse(requestId, timeoutMs)
  if frame.header.messageKind != rqStatusResponse:
    client.lastDiagnostic = diagnostic(diagProtocol, "daemon did not answer with status")
    raise newException(RunQuotaClientError, client.lastDiagnostic.message)
  if not decodeStatus(frame.payload, result):
    client.lastDiagnostic = diagnostic(diagProtocol, "invalid StatusResponse payload")
    raise newException(RunQuotaClientError, client.lastDiagnostic.message)

# ---------------------------------------------------------------------------
# Standalone mode: no daemon at all (M14)
# ---------------------------------------------------------------------------

proc daemonReachable*(endpoint: Endpoint): bool =
  ## Whether a ``runquotad`` answers at ``endpoint`` RIGHT NOW.
  ##
  ## A full Hello handshake rather than a socket-file test: a stale socket
  ## inode outlives the daemon that bound it, and a client that treated the
  ## file's existence as an answer would take the daemon path and fail the
  ## work — which is the outcome OS-4 forbids.
  try:
    var client = connect(endpoint)
    client.close()
    true
  except CatchableError:
    false

proc flushStandaloneAtExit*(capture: var StandaloneCapture;
                            endpoint: Endpoint): StandaloneFlushReason =
  ## THE SINGLE BEST-EFFORT FLUSH, over the socket and nowhere else.
  ##
  ## One connect attempt, one frame, no reply waited for, and no retry: a
  ## client that retried would be blocking its own exit on a daemon that by
  ## hypothesis is not there. If the connection fails — the usual case,
  ## since nothing has changed since the client gave up at startup — the
  ## observations are dropped and counted.
  ##
  ## THE ONE PLACE THIS COULD HAVE OPENED THE DATABASE, and it does not.
  ## Everything below is transport. The specification forbids a client
  ## writing the store to compensate for a missing daemon, and this is the
  ## moment at which a client would be most tempted to: it has real rows in
  ## hand, it is about to throw them away, and the file is right there.
  let plan = capture.planExitFlush()
  if not plan.attempt:
    return plan.reason
  var delivered = false
  try:
    var client = connect(endpoint)
    try:
      inc client.nextRequestId
      client.connection.sendFrame(encodeFrame(rqDeferredObservations,
        FrameFlagRequest, client.nextRequestId,
        encodeDeferredObservations(plan.message)))
      delivered = true
    finally:
      client.close()
  except CatchableError:
    delivered = false
  capture.finishExitFlush(delivered)
  plan.reason

proc deferredRecord*(label, commandStatsId: string;
                     startedAtUnixMillis, finishedAtUnixMillis: uint64;
                     finish: LeaseFinish;
                     peakRssBytes: uint64; processCount: uint32;
                     majorPageFaults = 0'u64): DeferredExecutionRecord =
  ## One buffered execution, from figures the client MEASURED about a child
  ## it ran itself. Same rule as ``reportObservation``: never a request's
  ## reserved resources, which is a number nobody measured.
  ##
  ## THE SAME ``LeaseFinish`` THE LEASED PATH SENDS, so a standalone row
  ## and an admitted row cannot describe the same death with different
  ## words -- and so the impossible states are impossible on both paths
  ## from one type rather than from two rules kept in step by hand.
  DeferredExecutionRecord(
    label: label,
    commandStatsId: commandStatsId,
    startedAtUnixMillis: startedAtUnixMillis,
    finishedAtUnixMillis: finishedAtUnixMillis,
    finish: finish,
    peakRssBytes: peakRssBytes,
    processCount: processCount,
    majorPageFaults: majorPageFaults
  )

template withLease*(session: var RunQuotaSession; request: ResourceRequest;
    body: untyped) =
  var lease {.inject.} = requestLease(session, request)
  try:
    body
  finally:
    release(lease)
