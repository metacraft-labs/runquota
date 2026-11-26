import std/[options, os, tables, strutils, monotimes, times]
when defined(posix):
  from std/posix import EACCES, EPERM, ECONNREFUSED, ENOENT, ENOTDIR,
    ENAMETOOLONG, ETIMEDOUT, ECONNRESET, EPIPE, EAGAIN, Stat, lstat, errno,
    S_ISSOCK

import runquota_client/types as clientTypes
import runquota_client/standalone as clientStandalone
import runquota_codec
import runquota_core
import runquota_core/measurement
import runquota_ipc
import runquota_protocol

export clientTypes
export clientStandalone

const libraryName* = "runquota_client"

proc handshakeTimeoutMs(): int =
  ## Bound for the quick control handshakes (Hello / RegisterSession /
  ## CloseSession). A runquota daemon that accepts the connection but never
  ## answers — wedged, stale, or protocol-incompatible — must not block the
  ## caller forever; transport I/O fails so the caller can fall back (the engine's
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
  RunQuotaRefusedError* = object of RunQuotaClientError
    ## THE DAEMON ANSWERED, AND ITS ANSWER WAS NO. Raised when a request --
    ## the opening `Hello` included -- is answered with an RQSP `Error`
    ## frame, so a caller can tell a daemon that is serving and refuses this
    ## client (a denied `Hello`, an incompatible protocol, a rejected
    ## request) from one it could not reach or that never answered (no
    ## listener, a closed connection, a response deadline): those raise the
    ## plain `RunQuotaClientError`, or the endpoint's own `OSError`.
    ##
    ## The difference decides what a launcher may do next. A daemon that
    ## does not answer may be shutting down, and waiting or restarting it is
    ## reasonable; one that refuses is alive and serving its other clients,
    ## and neither waiting nor stopping it changes its answer. `diagnostic`
    ## is the daemon's own, as decoded from the frame; `msg` is its message.
    diagnostic*: Diagnostic

template raiseRefused(refusal: Diagnostic) =
  ## Raises the daemon's refusal as a `RunQuotaRefusedError`. A template, not
  ## a proc returning the exception: this library is a static helper
  ## (`libs/static_helpers.txt`), and the static-helper gate refuses any `ref`
  ## type token in its source, a return type included.
  let refused = refusal
  var error = newException(RunQuotaRefusedError, refused.message)
  error.diagnostic = refused
  raise error

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
  ## it, or validate it against its own learned table, and it is what lets
  ## the estimate arrive WITH the request, so admission costs no round trip
  ## at the moment of asking. The estimate is charged to the ONE host-wide
  ## ledger as declared: an under-declared one frees capacity another user's
  ## request may be granted, so pass a figure you believe.
  result = request
  result.estimate = ClientEstimate(supplied: true, memoryBytes: memoryBytes)

proc withWidthRange*(request: ResourceRequest; minimum, preferred: MilliCpu;
                     resizable = false): ResourceRequest =
  ## Asks for a CPU RANGE: the daemon grants the widest value in
  ## ``minimum .. preferred`` that is free, at least ``minimum``, and the
  ## request waits while not even that fits. The grant's ``resources.cpu`` is
  ## the width chosen.
  ##
  ## ``resizable`` is for a client that follows a moving width -- a jobserver
  ## that issues and withholds tokens -- and then reports with
  ## ``reportResized``. A client that passes the width to its child once, as
  ## a flag, must not set it.
  ##
  ## ``resources.cpu`` is set to ``preferred``: it is what a daemon that
  ## predates ranges is asked for (``sendCandidateOffer`` caps it to that
  ## daemon's CPU budget, so it does not ask for the impossible).
  result = request
  result.resources.cpu = preferred
  result.width = WidthRange(present: true, minMilli: minimum.value,
    preferredMilli: preferred.value, resizable: resizable)

proc acceptingReclaimed*(request: ResourceRequest): ResourceRequest =
  ## Says this client may be given a RECLAIMED grant: one admitted at the
  ## request's minimum width into CPU the daemon predicts the running
  ## leases' tails leave free (``ReclaimedGrantsMinor``). Only a launcher
  ## that runs such a tree at a lower scheduling weight may ask for this --
  ## ``runquota_exec.runWithLease`` does, from ``RunQuotaLease.reclaimed``.
  ##
  ## The flag travels in the width block, so a request for one CPU value
  ## gets a block with both ends equal. A daemon that predates the flag
  ## ignores it (it ignores unknown width flags) and simply never reclaims.
  result = request
  if not result.width.present:
    result.width = WidthRange(present: true,
      minMilli: request.resources.cpu.value,
      preferredMilli: request.resources.cpu.value)
  result.width.acceptsReclaimed = true

proc benchmarkRequest*(request: ResourceRequest): ResourceRequest =
  result = request
  result.purpose = leasePurposeBenchmark

proc forMachine*(request: ResourceRequest; machineId: string): ResourceRequest =
  result = request
  result.resources = result.resources.forMachine(machineId)

proc requestFrame(client: var RunQuotaClient; kind: RqspMessageKind;
    payload: string; timeoutMs = 0): uint64 =
  if uint32(client.inflightRequestIds.len) >= client.flow.maxInflightRequests:
    client.lastDiagnostic = diagnostic(diagProtocol, "in-flight request limit exceeded")
    raise newException(RunQuotaClientError, client.lastDiagnostic.message)
  inc client.nextRequestId
  let requestId = client.nextRequestId
  var frameDiagnostic: Diagnostic
  if not client.connection.sendFrame(
      encodeFrame(kind, FrameFlagRequest, requestId, payload),
      frameDiagnostic, timeoutMs):
    client.lastDiagnostic = frameDiagnostic
    raise newException(RunQuotaClientError, client.lastDiagnostic.message)
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
    let startedNs = getMonoTime().ticks
    if timeoutMs > 0 and (startedNs < 0 or
        int64(timeoutMs) > (high(int64) - startedNs) div 1_000_000):
      client.lastDiagnostic = diagnostic(diagInvalidArgument,
        "response timeout cannot be represented by the monotonic clock")
      raise newException(RunQuotaClientError, client.lastDiagnostic.message)
    let responseDeadline =
      if timeoutMs > 0: startedNs + int64(timeoutMs) * 1_000_000
      else: 0'i64
    while true:
      var remainingMs = timeoutMs
      if responseDeadline != 0:
        let remainingNs = responseDeadline - getMonoTime().ticks
        if remainingNs <= 0:
          client.lastDiagnostic = diagnostic(diagProtocol,
            "daemon response deadline exceeded")
          raise newException(RunQuotaClientError, client.lastDiagnostic.message)
        remainingMs = int((remainingNs + 999_999) div 1_000_000)
      var frame: RqspFrame
      if not client.connection.receiveFrame(frame, remainingMs):
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
      raiseRefused(errorMessage.diagnostic)
    client.lastDiagnostic = diagnostic(diagProtocol, "invalid RQSP error payload")
    raise newException(RunQuotaClientError, client.lastDiagnostic.message)

proc close*(client: var RunQuotaClient) =
  if client.state == csConnected:
    client.connection.close()
  client.state = csClosed

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
  # THIS PROCESS'S OWNER ID, derived exactly as the daemon derives it from
  # the connection: the uid on POSIX, the hash of the token user SID on
  # Windows (`runquota_core/owner_id`). The daemon records the owner from
  # peer credentials and never from this field; what the field buys is the
  # refusal of a client that declares somebody else. It was `0` on every
  # non-POSIX platform, which made that check `0 == 0` on Windows and the
  # declared owner root. A process whose own token cannot be read declares
  # 0, and a daemon that CAN read it refuses the mismatch.
  let ownerId = currentProcessOwnerId()
  let uid = if ownerId.isSome: uint64(ownerId.get) else: 0'u64
  let hello = HelloMessage(
    clientName: clientName,
    clientVersion: clientVersion,
    minProtocolMajor: RqspProtocolMajor,
    maxProtocolMajor: RqspProtocolMajor,
    processId: pid,
    userId: uid,
    # The namespaces this process runs in, so a daemon in other namespaces
    # (this client in a container, the daemon on the host) knows that the
    # uid and pids above are this process's own view and not the daemon's
    # (`runquota_protocol/client_namespaces`).
    desiredCapabilities: withNamespaceTokens("m1-lease", currentNamespaces())
  )
  # THE CONNECTION IS OPEN FROM HERE ON, AND A FAILED HELLO CLOSES IT. Every
  # step below can raise: the send, the bounded read (a handshake timeout, a
  # daemon that closes), a refusal, an answer that is not `HelloOk`, a
  # `HelloOk` that does not decode. The caller never receives the half-built
  # client on those paths, so nobody else could close it: the descriptor
  # would stay open until the process exits, and the daemon would hold the
  # accepted connection until it noticed the peer was gone. A connection's
  # life is Hello, then requests, then close (reprobuild-pm
  # `spec/RunQuota-Protocol-And-Client-Libraries.md`), so a session that is
  # never established is closed at once. `finally` rather than `except`, so
  # the close also covers anything that is not a `CatchableError`, and the
  # original exception propagates unchanged.
  var established = false
  try:
    let requestId = result.requestFrame(rqHello, encodeHello(hello), handshakeTimeoutMs())
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
    result.socketClass = helloOk.connectionClass
    established = true
  finally:
    if not established:
      result.close()

# ---------------------------------------------------------------------------
# Which socket: the shared one, or the socket of the class `RUNQUOTA_CLASS`
# names.
#
# Each `[reservation.<class>]` of the host file has its own daemon socket
# beside the shared endpoint (`runquota_ipc.classEndpoint`), and the socket's
# permissions decide who may claim the class. So the client picks the socket
# by the class: when the class's socket exists it connects THERE, and a
# refusal is an error naming the socket and the class -- never a quiet
# fallback to the shared socket, where the work would run outside its
# reservation. When it does not exist the client connects to the shared
# endpoint: a daemon with class sockets then refuses the class there and says
# the host declares no such class, and a daemon that predates class sockets
# (`ClassSocketsMinor`) is sent the class block as at minor 12, since it has
# no other trust model to offer.
# ---------------------------------------------------------------------------

const classEnvVarName = "RUNQUOTA_CLASS"

type
  ClassSocketRefusedError* = object of RunQuotaClientError
    ## The class's socket exists and this process may not use it (or it
    ## failed its trust check). Carries the socket and the class in its
    ## message; a launcher must not run the work unleased or on the shared
    ## socket instead.
    socketPath*: string
    className*: string

proc classSocketRefusal(path, className, why: string): string =
  "cannot claim class " & className & " at its socket " & path & ": " & why &
    ". Who may claim a class is decided by the host file's [reservation." &
    className & "] (socket-owner, socket-group and socket-mode; " &
    "allowed-users and allowed-groups on Windows); the client does not " &
    "fall back to the shared socket. Unset " & classEnvVarName &
    " to run without the class"

template raiseClassRefused(path, className, why: string) =
  var error = newException(ClassSocketRefusedError,
    classSocketRefusal(path, className, why))
  error.socketPath = path
  error.className = className
  raise error

proc classSocketExists(endpoint: Endpoint): bool =
  ## Whether there is anything at the class socket's path. Only a plain
  ## absence counts as "no socket": a path that cannot be looked at (a
  ## directory this user cannot search) is a socket the user is refused,
  ## and the connect that follows names that.
  case endpoint.kind
  of endpointUnixSocket:
    when defined(posix):
      var info: Stat
      if lstat(endpoint.path.cstring, info) == 0:
        return true
      return errno != ENOENT and errno != ENOTDIR
    else:
      fileExists(endpoint.path)
  of endpointNamedPipe:
    # A pipe cannot be listed cheaply here; the connect decides, and a
    # missing pipe (ERROR_FILE_NOT_FOUND) is the shared-socket case.
    true
  of endpointUnsupported:
    false

proc connectForClass*(className: string; endpoint = defaultEndpoint();
                      clientName = "runquota-nim";
                      clientVersion = "0.1.0"): RunQuotaClient =
  ## Connect for work in `className` ("" for none): to the class's socket
  ## beside `endpoint` when it exists, else to `endpoint` itself. Raises
  ## `ClassSocketRefusedError` when the class's socket refuses this process,
  ## `RunQuotaClientError` for a class outside the class-name rule or a
  ## socket path too long for this platform, and what `connect` raises
  ## otherwise.
  if className.len == 0:
    return connect(endpoint, clientName, clientVersion)
  let problem = classNameProblem(className)
  if problem.len > 0:
    raise newException(RunQuotaClientError, "invalid class " &
      classEnvVarName & ": " & problem)
  var classSocket: Endpoint
  try:
    classSocket = classEndpoint(endpoint, className)
  except ClassEndpointError as error:
    raise newException(RunQuotaClientError, "class " & className & ": " &
      error.msg)
  if not classSocketExists(classSocket):
    # NO SOCKET FOR THE CLASS: the shared endpoint, where a daemon with
    # class sockets answers that the host declares no such class.
    return connect(endpoint, clientName, clientVersion)
  when defined(posix):
    if classSocket.kind == endpointUnixSocket:
      var info: Stat
      if lstat(classSocket.path.cstring, info) == 0 and
          not S_ISSOCK(info.st_mode):
        raiseClassRefused(classSocket.path, className,
          "it is not a socket (a symbolic link or another kind of file), " &
          "so it is not the daemon's")
  try:
    result = connect(classSocket, clientName, clientVersion)
  except RunQuotaClientError:
    # The daemon answered (a refused Hello, a protocol error): its own words
    # are the better message.
    raise
  except OSError as error:
    let code = error.errorCode
    let why =
      if code != 0: osErrorMsg(OSErrorCode(code)).strip()
      else: error.msg.strip()
    raiseClassRefused(classSocket.path, className, why)
  if result.socketClass != className:
    let answered = result.socketClass
    result.connection.close()
    result.state = csClosed
    raiseClassRefused(classSocket.path, className,
      "the daemon there answered " &
      (if answered.len > 0: "for class " & answered else: "for no class") &
      ", so it is not that class's socket")

proc connectDefault*(): RunQuotaClient =
  ## Connect for this process's work: the socket of the class
  ## `RUNQUOTA_CLASS` names, or the shared endpoint (`connectForClass`).
  connectForClass(getEnv(classEnvVarName).strip())

# ---------------------------------------------------------------------------
# Why a launcher has no session, and what it may do about it.
#
# A launcher (`runquota run`, `acquire -- CMD`, `jobserver`, an embedding
# build engine) that cannot get a session runs its command UNLEASED. That is
# right when no daemon exists at all -- standalone mode, which stays quiet so
# a wrapper can be adopted on hosts without RunQuota -- and wrong to do in
# silence when an endpoint EXISTS and refuses the client: a process started
# before its user joined the rendezvous group is refused by the socket's mode
# (`EACCES`), and then competed for the host outside every budget without a
# word. So the failure is classified here, once, for every launcher:
#
# * every kind but `cfkAbsent` is warned about, always, in one line naming
#   the endpoint, the error and what it usually means;
# * `RUNQUOTA_STRICT` turns every kind, absence included, into a refusal:
#   the launcher exits 1 and the command is not started.
# ---------------------------------------------------------------------------

const
  StrictEnvVar* = "RUNQUOTA_STRICT"
    ## Set to anything but empty or `0`: a launcher that cannot get a lease
    ## refuses to run its command instead of running it unleased.
  StrictRefusalExitCode* = 1
    ## The status a strict launcher exits with. It is the one `run`,
    ## `acquire` and `jobserver` already use when no lease could be had and
    ## the command did not run.

type
  ConnectFailureKind* = enum
    cfkNone          ## connected: there is no failure
    cfkAbsent        ## no endpoint at the path (ENOENT, ENOTDIR)
    cfkRefused       ## the endpoint exists and may not be used (EACCES, EPERM)
    cfkNotListening  ## a socket file with nothing listening (ECONNREFUSED)
    cfkUntrusted     ## the endpoint failed the trust checks
    cfkDenied        ## a daemon answered and refused this client at Hello
    cfkClassRefused  ## the socket of the class RUNQUOTA_CLASS names refused
                     ## this process: never run unleased instead
    cfkOther         ## anything else: a handshake timeout, a transport error

  ConnectFailure* = object
    ## Why `tryConnectDefault` got no session.
    kind*: ConnectFailureKind
    endpoint*: string
      ## The path (or pipe name) that was tried; empty when even the
      ## endpoint could not be resolved.
    errorName*: string
      ## `EACCES`, `ECONNREFUSED`, ... for an OS error; otherwise a short
      ## name of the failure (`trust check`, `Hello refused`, ...).
    detail*: string
      ## The error's own text.

  UnleasedFallback* = object
    ## What a launcher does after `tryConnectDefault` failed.
    run*: bool
      ## Run the command unleased (`true`), or refuse and exit
      ## `StrictRefusalExitCode` without starting it (`false`).
    message*: string
      ## One line for standard error, or empty when there is nothing to say
      ## (an absent endpoint outside strict mode: standalone mode).

proc osErrorName(code: int32): string =
  ## The symbolic name of the OS errors a connect can end in. Anything else
  ## is spelled by number; its text still comes from the OS.
  when defined(windows):
    case code
    of 2: "ERROR_FILE_NOT_FOUND"
    of 3: "ERROR_PATH_NOT_FOUND"
    of 5: "ERROR_ACCESS_DENIED"
    of 231: "ERROR_PIPE_BUSY"
    else: "error " & $code
  else:
    if code == EACCES: "EACCES"
    elif code == EPERM: "EPERM"
    elif code == ECONNREFUSED: "ECONNREFUSED"
    elif code == ENOENT: "ENOENT"
    elif code == ENOTDIR: "ENOTDIR"
    elif code == ENAMETOOLONG: "ENAMETOOLONG"
    elif code == ETIMEDOUT: "ETIMEDOUT"
    elif code == ECONNRESET: "ECONNRESET"
    elif code == EPIPE: "EPIPE"
    elif code == EAGAIN: "EAGAIN"
    else: "errno " & $code

proc osErrorKind(code: int32): ConnectFailureKind =
  when defined(windows):
    case code
    of 2, 3: cfkAbsent
    of 5: cfkRefused
    else: cfkOther
  else:
    if code == ENOENT or code == ENOTDIR: cfkAbsent
    elif code == EACCES or code == EPERM: cfkRefused
    elif code == ECONNREFUSED: cfkNotListening
    else: cfkOther

proc oneLine(text: string): string =
  text.replace('\n', ' ').replace('\r', ' ').strip()

proc tryConnectDefault*(client: var RunQuotaClient;
                        failure: var ConnectFailure): bool =
  ## `connectDefault` that answers instead of raising: `true` with `client`
  ## connected, or `false` with `failure` saying why. Nothing it can raise
  ## escapes, so a launcher's fallback sees every failure classified.
  failure = ConnectFailure(kind: cfkNone)
  var endpoint = ""
  try:
    let resolved = defaultEndpoint()
    endpoint = resolved.path
    client = connectForClass(getEnv(classEnvVarName).strip(), resolved)
    return true
  except ClassSocketRefusedError as error:
    # NEVER RUN UNLEASED FOR THIS: the work named a class, and running it
    # outside the class's reservation is exactly what the refusal is for.
    failure = ConnectFailure(kind: cfkClassRefused, endpoint: error.socketPath,
      errorName: "class " & error.className & " refused",
      detail: oneLine(error.msg))
  except RunQuotaRefusedError as error:
    failure = ConnectFailure(kind: cfkDenied, endpoint: endpoint,
      errorName: "Hello refused", detail: oneLine(error.msg))
  except EndpointTrustError as error:
    failure = ConnectFailure(kind: cfkUntrusted, endpoint: endpoint,
      errorName: "trust check", detail: oneLine(error.msg))
  except OSError as error:
    let code = error.errorCode
    var text = ""
    if code != 0:
      text = osErrorMsg(OSErrorCode(code)).oneLine()
    if text.len == 0:
      text = oneLine(error.msg)
    failure = ConnectFailure(
      kind: (if code != 0: osErrorKind(code) else: cfkOther),
      endpoint: endpoint,
      errorName: (if code != 0: osErrorName(code) else: "error"),
      detail: text)
  except CatchableError as error:
    failure = ConnectFailure(kind: cfkOther, endpoint: endpoint,
      errorName: "error", detail: oneLine(error.msg))
  false

proc strictRequested*(): bool =
  ## Whether `RUNQUOTA_STRICT` asks for strict mode: any value but empty or
  ## `0`. A typo must not quietly mean "off", so anything set counts.
  let value = getEnv(StrictEnvVar).strip()
  value.len > 0 and value != "0"

proc failureHint*(failure: ConnectFailure): string =
  ## What the failure usually means, and what to do about it.
  case failure.kind
  of cfkRefused:
    "This process does not carry the group that may connect to the " &
      "socket (for example, its user was added to the group after the " &
      "session started); start a new login session."
  of cfkNotListening:
    "No daemon is listening there: it is stopped, or exited and left its " &
      "socket behind; start it (`runquota daemon start` or the host service)."
  of cfkAbsent:
    "No daemon is provisioned at that path."
  of cfkClassRefused:
    "The host file decides who may claim the class; ask its operator, or " &
      "unset RUNQUOTA_CLASS to run the work without the class."
  of cfkUntrusted, cfkDenied, cfkOther, cfkNone:
    ""

proc failureReason*(failure: ConnectFailure): string =
  ## `cannot use the RunQuota daemon at <path>: <NAME> (<text>)` -- the part
  ## of the warning and of the strict refusal that names what went wrong.
  result = "cannot use the RunQuota daemon at " &
    (if failure.endpoint.len > 0: failure.endpoint
     else: "an endpoint that could not be resolved") &
    ": " & failure.errorName
  if failure.detail.len > 0:
    result.add " (" & failure.detail & ")"

proc withHint(text: string; failure: ConnectFailure): string =
  let hint = failureHint(failure)
  if hint.len > 0: text & " " & hint else: text

proc unleasedFallback*(launcher: string; failure: ConnectFailure;
                       strict = strictRequested()): UnleasedFallback =
  ## The one decision every launcher takes after `tryConnectDefault` failed:
  ## whether to run the command unleased, and the line to print first.
  ## `launcher` prefixes the line (`runquota run`, `repro`).
  if failure.kind == cfkClassRefused:
    # A CLASS THAT MAY NOT BE CLAIMED IS NOT A DAEMON THAT IS NOT THERE: the
    # work asked for a reservation it is not allowed, and running it
    # unleased would put it outside every budget instead.
    return UnleasedFallback(run: false, message: withHint(launcher & ": " &
      failureReason(failure) & "; not running the command.", failure))
  if strict:
    return UnleasedFallback(run: false, message: withHint(launcher & ": " &
      StrictEnvVar & " is set and no lease can be had: " &
      failureReason(failure) & "; not running the command.", failure))
  if failure.kind in {cfkNone, cfkAbsent}:
    return UnleasedFallback(run: true, message: "")
  UnleasedFallback(run: true, message: withHint(launcher & ": warning: " &
    failureReason(failure) & "; running the command without a lease.",
    failure) & " Set " & StrictEnvVar & "=1 to refuse instead.")

const
  ProjectEnvVar* = "RUNQUOTA_PROJECT"
    ## The project this process's sessions work for, declared for sizing
    ## (`runquota profile`, `runquota sizing`). Unset: not declared.
  EntryPointEnvVar* = "RUNQUOTA_ENTRY_POINT"
    ## The entry point (`build`, `test`, a CI job name) they run under.
  SessionGroupEnvVar* = "RUNQUOTA_SESSION"
    ## The session group this process's sessions join: the handle
    ## `<host>:<window>` of the agent session it runs under, exported
    ## by the launcher. Unset or empty: the user's `interactive` group.
  SessionPriorityEnvVar* = "RUNQUOTA_SESSION_PRIORITY"
    ## `urgent`, `high`, `normal` or `low`: the group's priority if this
    ## session is the one that creates it.
  SessionCacheTtlEnvVar* = "RUNQUOTA_SESSION_CACHE_TTL"
    ## Seconds until the group's provider prompt cache expires: the group's
    ## cache deadline (now + TTL) if this session creates it.
  ClassEnvVar* = classEnvVarName
    ## The class of the session's group (`ci`, a VM pool's class): the
    ## class the group joins if this session creates it. A class may hold a
    ## reservation in the host file. Unset or empty: no class.

proc supportsNegotiatedWidths*(client: RunQuotaClient): bool =
  ## Whether the daemon understands CPU ranges on host leases and the resize
  ## messages. Below ``NegotiatedWidthsMinor`` a request asks for one value.
  client.capabilities.protocolMinor >= NegotiatedWidthsMinor

proc widthForPeer*(width: WidthRange; peerMinor: uint16; peerCpuSlots: uint32;
                   resources: var ResourceVector): WidthRange =
  ## The width as a daemon at protocol minor `peerMinor` can be asked for
  ## it. One below `NegotiatedWidthsMinor` gets no range: it is asked for
  ## ``resources.cpu`` (the preferred width), capped to its CPU budget but
  ## never below the minimum, so a range it cannot express does not turn
  ## into a request it must refuse.
  if not width.present or peerMinor >= NegotiatedWidthsMinor:
    return width
  if peerCpuSlots > 0'u32 and resources.cpu.value > peerCpuSlots:
    resources.cpu = milliCpu(max(peerCpuSlots, width.minMilli))
  WidthRange(present: false)

proc forDaemon(client: RunQuotaClient; width: WidthRange;
               resources: var ResourceVector): WidthRange =
  widthForPeer(width, client.capabilities.protocolMinor,
    client.capabilities.cpuSlots.value, resources)

proc supportsSizing*(client: RunQuotaClient): bool =
  ## Whether the daemon understands sizing (`SizingMinor`): the sizing block
  ## of `RegisterSession`, the sizing bits of the finish and `QuerySizing`.
  client.capabilities.protocolMinor >= SizingMinor

proc sizingDeclaration(value: string): string =
  ## A declared project or entry point, bounded so the daemon cannot refuse
  ## the registration over it: cut at `MaxSizingDeclarationBytes`, at a
  ## character boundary.
  if value.len <= MaxSizingDeclarationBytes:
    return value
  var cut = MaxSizingDeclarationBytes
  while cut > 0 and (ord(value[cut]) and 0xC0) == 0x80:
    dec cut
  value[0 ..< cut]

proc supportsSessionGroups*(client: RunQuotaClient): bool =
  ## Whether the daemon understands session groups: its `HelloOk` reported
  ## protocol minor `SessionGroupsMinor` or later. An older daemon refuses a
  ## `RegisterSession` that names a group and closes the connection on
  ## `UpdateSessionGroup`.
  client.capabilities.protocolMinor >= SessionGroupsMinor

proc supportsClasses*(client: RunQuotaClient): bool =
  ## Whether the daemon understands classes (`ClassesMinor`): the class
  ## block of `RegisterSession`. An older daemon would refuse it.
  client.capabilities.protocolMinor >= ClassesMinor

proc sessionGroupFromEnvironment*(): SessionGroupDeclaration =
  ## The group the launcher exported, read from `RUNQUOTA_SESSION`,
  ## `RUNQUOTA_SESSION_PRIORITY` and `RUNQUOTA_SESSION_CACHE_TTL`.
  ##
  ## A PRIORITY OR TTL THAT DOES NOT PARSE IS IGNORED, and the daemon's
  ## default applies. Every RunQuota client below a launcher reads these, and
  ## failing every one of them over an attribute would stop the session's
  ## builds over what is only a scheduling preference; a group NAME that
  ## cannot be one is different (it would merge or split sessions), and
  ## `registerSession` refuses it.
  result.priority = sessionPriorityNormal
  result.name = getEnv(SessionGroupEnvVar)
  # THE CLASS IS READ WITH OR WITHOUT A GROUP: a session that names a class
  # and no group joins its owner's group named after the class.
  result.className = getEnv(ClassEnvVar).strip()
  if result.name.len == 0:
    return
  var priority: SessionPriority
  if parseSessionPriority(getEnv(SessionPriorityEnvVar).strip(), priority):
    result.priorityPresent = true
    result.priority = priority
  let ttlText = getEnv(SessionCacheTtlEnvVar).strip()
  if ttlText.len > 0:
    try:
      let ttlSeconds = parseBiggestUInt(ttlText)
      # Bounded so the deadline stays representable; a TTL of a million
      # years is not a cache deadline anybody means.
      if ttlSeconds <= 1_000_000_000'u64:
        result.cacheDeadlinePresent = true
        result.cacheDeadlineUnixMillis =
          uint64(epochTime() * 1000.0) + uint64(ttlSeconds) * 1000'u64
    except ValueError:
      discard

proc registerSession*(client: var RunQuotaClient; name, version: string;
                      group: SessionGroupDeclaration;
                      project = ""; entryPoint = ""): RunQuotaSession =
  ## Register a session in `group` (`sessionGroupFromEnvironment` for the one
  ## the launcher exported; a declaration with an empty name for the user's
  ## interactive group).
  ##
  ## A DAEMON THAT PREDATES SESSION GROUPS IS SENT NONE. It would refuse the
  ## registration, and its admission has no groups to put the session in;
  ## the session is served as that daemon serves every session.
  if group.name.len > 0:
    let problem = sessionGroupNameProblem(group.name)
    if problem.len > 0:
      client.lastDiagnostic = diagnostic(diagInvalidArgument,
        "invalid session group " & SessionGroupEnvVar & ": " & problem)
      raise newException(RunQuotaClientError, client.lastDiagnostic.message)
  if group.className.len > 0:
    # A CLASS THAT CANNOT BE ONE IS REFUSED, like a group name: it decides
    # which reservation the session's work is admitted under, so a typo
    # would silently put a CI job outside its reservation.
    let problem = classNameProblem(group.className)
    if problem.len > 0:
      client.lastDiagnostic = diagnostic(diagInvalidArgument,
        "invalid class " & ClassEnvVar & ": " & problem)
      raise newException(RunQuotaClientError, client.lastDiagnostic.message)
  var msg = RegisterSessionMessage(name: name, version: version,
      metadata: metadataNone())
  if client.supportsSessionGroups():
    msg.group = group
    # A DAEMON THAT PREDATES CLASSES IS SENT NONE (it would refuse the
    # block); the session is then served outside every reservation, as
    # that daemon serves every session.
    if not client.supportsClasses():
      msg.group.className = ""
  # THE SIZING DECLARATIONS: the caller's, else the launcher's variables.
  # Not a measurement (one pair of strings per session) and so not behind
  # `sizing-data`; sent only to a daemon that reads them.
  if client.supportsSizing():
    msg.project = sizingDeclaration(
      if project.len > 0: project else: getEnv(ProjectEnvVar, ""))
    msg.entryPoint = sizingDeclaration(
      if entryPoint.len > 0: entryPoint else: getEnv(EntryPointEnvVar, ""))
  let requestId = client.requestFrame(rqRegisterSession, encodeRegisterSession(msg), handshakeTimeoutMs())
  let frame = client.readResponse(requestId, handshakeTimeoutMs())
  if frame.header.messageKind != rqSessionRegistered:
    client.lastDiagnostic = diagnostic(diagProtocol, "daemon did not register the session")
    raise newException(RunQuotaClientError, client.lastDiagnostic.message)
  var registered: SessionRegisteredMessage
  if not decodeSessionRegistered(frame.payload, registered):
    client.lastDiagnostic = diagnostic(diagProtocol, "invalid SessionRegistered payload")
    raise newException(RunQuotaClientError, client.lastDiagnostic.message)
  # The group this session is in, as far as this client can tell without
  # asking: the name it declared (or `interactive`), and the priority it
  # would start the group with. `groupPriorityInForce` asks for the real one.
  let groupName =
    if group.name.len > 0: group.name
    elif msg.group.className.len > 0: msg.group.className
    else: InteractiveSessionGroup
  let declared =
    if group.name.len == 0 and msg.group.className.len > 0:
      sessionPriorityNormal
    elif group.name.len == 0: sessionPriorityHigh
    elif group.priorityPresent: group.priority
    else: sessionPriorityNormal
  RunQuotaSession(client: addr client, id: registered.sessionId, active: true,
    groupName: groupName, declaredGroupPriority: declared)

proc registerSession*(client: var RunQuotaClient; name,
    version: string; project = ""; entryPoint = ""): RunQuotaSession =
  ## Register a session in the group the launcher exported
  ## (`RUNQUOTA_SESSION`), or the user's interactive group when it exported
  ## none. ``project`` / ``entryPoint`` override `RUNQUOTA_PROJECT` /
  ## `RUNQUOTA_ENTRY_POINT`.
  client.registerSession(name, version, sessionGroupFromEnvironment(),
    project, entryPoint)

proc updateSessionGroup*(client: var RunQuotaClient;
                         update: UpdateSessionGroupMessage):
    SessionGroupUpdatedMessage =
  ## Change the priority or cache deadline of a session group this process's
  ## user owns. Needs no session: a launcher that holds no lease may call it.
  ## Raises `RunQuotaClientError` when the daemon refuses (another user's
  ## group, or no open session names it) or predates session groups.
  if not client.supportsSessionGroups():
    client.lastDiagnostic = diagnostic(diagUnavailable,
      "the daemon (" & client.daemonVersion & ", protocol minor " &
        $client.capabilities.protocolMinor & ") predates session groups",
      "session groups need protocol minor " & $SessionGroupsMinor)
    raise newException(RunQuotaClientError, client.lastDiagnostic.message)
  let requestId = client.requestFrame(rqUpdateSessionGroup,
    encodeUpdateSessionGroup(update), handshakeTimeoutMs())
  let frame = client.readResponse(requestId, handshakeTimeoutMs())
  if frame.header.messageKind != rqSessionGroupUpdated:
    client.lastDiagnostic = diagnostic(diagProtocol,
      "daemon did not answer UpdateSessionGroup")
    raise newException(RunQuotaClientError, client.lastDiagnostic.message)
  if not decodeSessionGroupUpdated(frame.payload, result):
    client.lastDiagnostic = diagnostic(diagProtocol,
      "invalid SessionGroupUpdated payload")
    raise newException(RunQuotaClientError, client.lastDiagnostic.message)

proc currentGroupPriority*(client: var RunQuotaClient; group: string;
                           priority: var SessionPriority): bool =
  ## The priority the daemon holds for `group` (a group this process's user
  ## owns) at this moment, asked with an `UpdateSessionGroup` that changes
  ## nothing (its answer carries the attributes in force). False, leaving
  ## `priority` alone, when the daemon predates session groups or refuses.
  if not client.supportsSessionGroups():
    return false
  try:
    let answer = client.updateSessionGroup(UpdateSessionGroupMessage(
      group: group, priority: sessionPriorityNormal,
      cacheDeadlineChange: cacheDeadlineKeep))
    priority = answer.priority
    true
  except RunQuotaClientError:
    false

proc groupPriorityNow*(session: var RunQuotaSession): SessionPriority =
  ## The priority the daemon holds for this session's group now, asked
  ## every time (one round trip), and remembered for
  ## `groupPriorityInForce`. A daemon that predates session groups, or a
  ## refusal, gives the last one known, else the declared priority.
  result =
    if session.groupPriorityKnown: session.groupPriority
    else: session.declaredGroupPriority
  if not session.client.isNil:
    var answer = result
    if session.client[].currentGroupPriority(session.groupName, answer):
      result = answer
  session.groupPriority = result
  session.groupPriorityKnown = true

proc groupPriorityInForce*(session: var RunQuotaSession): SessionPriority =
  ## The priority the daemon holds for this session's group. A group
  ## outlives its sessions and its launcher may have changed the priority
  ## since this process's environment was written, so the declared value is
  ## only the fallback. Asked once per session (`groupPriorityNow`) and
  ## remembered: for what must be current at a given moment (a cgroup
  ## weight a launcher writes), ask `groupPriorityNow` instead.
  if session.groupPriorityKnown:
    return session.groupPriority
  session.groupPriorityNow()

proc closeSession*(session: var RunQuotaSession) =
  if not session.active:
    return
  let msg = CloseSessionMessage(sessionId: session.id)
  let requestId = session.client[].requestFrame(rqCloseSession,
      encodeCloseSession(msg), handshakeTimeoutMs())
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
    request: ResourceRequest; timeoutMs = 0): RunQuotaLease =
  ## Optional transport bound for an immediate lease decision. Zero preserves
  ## the existing blocking contract; this is not a workload/deadline budget.
  ## Each frame write/read is bounded by the selected IPC implementation.
  ## Finite uncertainty closes the connection and invalidates this session;
  ## no late grant is accepted or reused. Other sessions on this connection
  ## also lose transport access. The daemon must reclaim them on disconnect.
  ## The bound is per frame write plus a read budget (each IPC header/payload
  ## read can consume the remaining read budget), not one end-to-end timeout.
  if timeoutMs < 0 or int64(timeoutMs) > int64(high(int32)):
    session.client[].lastDiagnostic = diagnostic(diagInvalidArgument,
      "lease request timeout is outside the supported transport range")
    raise newException(RunQuotaClientError, session.client[].lastDiagnostic.message)
  when defined(windows):
    if timeoutMs > 0:
      session.client[].lastDiagnostic = diagnostic(diagInvalidArgument,
        "finite lease-request writes require POSIX socket transport")
      raise newException(RunQuotaClientError, session.client[].lastDiagnostic.message)
  if not session.active:
    session.client[].lastDiagnostic = diagnostic(diagInvalidArgument, "session is not active")
    raise newException(RunQuotaClientError, session.client[].lastDiagnostic.message)
  var resources = request.resources
  let width = session.client[].forDaemon(request.width, resources)
  let msg = LeaseRequestMessage(
    sessionId: session.id,
    label: request.label,
    commandStatsId: request.commandStatsId,
    resources: resources,
    deadline: request.deadline,
    priority: request.priority,
    purpose: request.purpose,
    metadata: request.metadata,
    estimate: request.estimate,
    width: width
  )
  var validDenial = false
  try:
    let requestId = session.client[].requestFrame(rqRequestLease,
        encodeLeaseRequest(msg), timeoutMs)
    let frame = session.client[].readResponse(requestId, timeoutMs)
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
        state: leaseClientGranted,
        reclaimed: granted.reclaimed
      )
    of rqLeaseDenied:
      var denied: LeaseDeniedMessage
      if decodeLeaseDenied(frame.payload, denied):
        validDenial = true
        session.client[].lastDiagnostic = denied.diagnostic
        raise newException(RunQuotaClientError, denied.diagnostic.message)
      session.client[].lastDiagnostic = diagnostic(diagProtocol, "invalid LeaseDenied payload")
      raise newException(RunQuotaClientError, session.client[].lastDiagnostic.message)
    else:
      session.client[].lastDiagnostic = diagnostic(diagProtocol, "daemon did not answer with a lease decision")
      raise newException(RunQuotaClientError, session.client[].lastDiagnostic.message)
  except CatchableError:
    if timeoutMs > 0 and not validDenial:
      session.active = false
      session.client[].close()
    raise

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
    estimate: request.estimate,
    width: request.width
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
    var entry = candidate
    entry.width = session.client[].forDaemon(entry.width, entry.resources)
    copied.add(entry)
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
        state: if decision.kind == leaseDecisionGranted: leaseClientGranted else: leaseClientQueued,
        reclaimed: decision.kind == leaseDecisionGranted and decision.reclaimed
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
      session.client[].requestFrame(rqGrantNext, encodeGrantNext(msg), timeoutMs)
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
      raiseRefused(errorMessage.diagnostic)
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
        # A DENIAL IS NOT A GRANT. A queued lease is denied on a later poll
        # when a host-configuration reload shrank the budget below it
        # (`reloadHostConfig` in `runquota_daemon`); returning its inactive
        # lease here would hand the caller a lease it was never granted.
        if not grant.lease.active:
          session.client[].lastDiagnostic = grant.diagnostic
          raise newException(RunQuotaClientError, grant.diagnostic.message)
        return grant.lease
    inc polls
    sleep(pollMillis)
  session.client[].lastDiagnostic = diagnostic(diagDenied, "timed out waiting for lease grant")
  raise newException(RunQuotaClientError, session.client[].lastDiagnostic.message)

# ---------------------------------------------------------------------------
# Negotiated widths: resizing a running lease
# ---------------------------------------------------------------------------

proc resizeExchange(lease: var RunQuotaLease; kind: RqspMessageKind;
                    payload: string): LeaseResizeMessage =
  let session = lease.session
  let requestId = session.client[].requestFrame(kind, payload)
  let frame = session.client[].readResponse(requestId)
  if frame.header.messageKind != rqLeaseResize or
      not decodeLeaseResize(frame.payload, result) or
      result.leaseId.value != lease.id.value:
    session.client[].lastDiagnostic = diagnostic(diagProtocol,
      "daemon did not answer with LeaseResize")
    raise newException(RunQuotaClientError,
      session.client[].lastDiagnostic.message)

proc checkResizable(lease: RunQuotaLease) =
  if lease.session.isNil or not lease.active:
    raise newException(RunQuotaClientError, "lease is not active")
  if not lease.session.client[].supportsNegotiatedWidths():
    lease.session.client[].lastDiagnostic = diagnostic(diagUnsupportedVersion,
      "daemon (protocol minor " &
      $lease.session.client[].capabilities.protocolMinor &
      ") predates negotiated widths")
    raise newException(RunQuotaClientError,
      lease.session.client[].lastDiagnostic.message)

proc reportResized*(lease: var RunQuotaLease;
                    current: MilliCpu): LeaseResizeMessage =
  ## Tell the daemon the width this lease's jobserver holds now (tokens in
  ## circulation plus the implicit one) and learn the target in force. A
  ## resizable client calls it periodically while its command runs: RQSP is
  ## request and response, so this is how a target set in an admission pass
  ## reaches it. The daemon charges max(target, current).
  lease.checkResizable()
  lease.resizeExchange(rqLeaseResized, encodeLeaseResized(LeaseResizedMessage(
    sessionId: lease.session.id, leaseId: lease.id,
    cpuCurrentMilli: current.value)))

proc requestGrow*(lease: var RunQuotaLease;
                  wanted: MilliCpu): LeaseResizeMessage =
  ## Ask that the lease grow towards ``wanted`` (clamped to its range) when
  ## admission finds free CPU for it. Answers with the target in force now;
  ## the growth itself arrives in a later ``reportResized`` answer.
  lease.checkResizable()
  lease.resizeExchange(rqLeaseGrowRequest,
    encodeLeaseGrowRequest(LeaseGrowRequestMessage(
      sessionId: lease.session.id, leaseId: lease.id,
      cpuWantedMilli: wanted.value)))

# ---------------------------------------------------------------------------
# Nested bridges: sub-leases of a parent lease
# ---------------------------------------------------------------------------

const ParentLeaseEnvVar* = "RUNQUOTA_PARENT_LEASE"
  ## Set by a supervising client for the process tree it launched, to the id
  ## of the lease that tree runs under. A client that finds it asks for a
  ## sub-lease of that lease instead of a host lease, rather than queueing
  ## on the host behind its own parent.

proc parentLeaseFromEnvironment*(): Option[LeaseId] =
  ## The parent lease named by `RUNQUOTA_PARENT_LEASE`, or none. A value that
  ## is not a positive decimal lease id is treated as absent: the variable is
  ## a scheduling hint inherited through arbitrary process trees, and a
  ## malformed one must not make every client below it fail.
  let text = getEnv(ParentLeaseEnvVar).strip()
  if text.len == 0 or text.len > 20:
    return none(LeaseId)
  for ch in text:
    if ch notin {'0' .. '9'}:
      return none(LeaseId)
  try:
    let value = parseBiggestUInt(text)
    if value == 0'u64: none(LeaseId) else: some(leaseId(uint64(value)))
  except ValueError:
    none(LeaseId)

proc supportsSubLeases*(client: RunQuotaClient): bool =
  ## Whether the daemon understands `RequestSubLease`. Below
  ## `SubLeaseMinor` a client takes a host lease instead.
  client.capabilities.protocolMinor >= SubLeaseMinor

proc requestSubLeaseWaiting*(session: var RunQuotaSession; parent: LeaseId;
                             label, commandStatsId: string;
                             cpuMin, cpuPreferred: MilliCpu;
                             memory: Bytes;
                             pollMillis = 50; maxPolls = 0): RunQuotaLease =
  ## Ask for a sub-lease of `parent` with a CPU range, waiting while the
  ## parent's other sub-leases hold what it needs. The grant's
  ## `resources.cpu` is the width the daemon fitted into the range.
  ##
  ## On refusal raises `RunQuotaClientError` with `lastDiagnostic` set:
  ## `diagInvalidArgument` means the PARENT is unusable (unknown, ended, or
  ## another owner's) and the caller may fall back to a host lease;
  ## `diagDenied` means the request can never fit the parent.
  if not session.active:
    session.client[].lastDiagnostic = diagnostic(diagInvalidArgument,
      "session is not active")
    raise newException(RunQuotaClientError,
      session.client[].lastDiagnostic.message)
  if not session.client[].supportsSubLeases():
    session.client[].lastDiagnostic = diagnostic(diagUnsupportedVersion,
      "daemon (protocol minor " &
      $session.client[].capabilities.protocolMinor &
      ") predates sub-leases")
    raise newException(RunQuotaClientError,
      session.client[].lastDiagnostic.message)
  let candidateId = session.client[].nextRequestId + 1'u64
  let msg = RequestSubLeaseMessage(
    sessionId: session.id,
    parentLeaseId: parent,
    clientCandidateId: candidateId,
    label: label,
    commandStatsId: commandStatsId,
    cpuMinMilli: cpuMin.value,
    cpuPreferredMilli: cpuPreferred.value,
    memoryBytes: memory.value)
  let requestId = session.client[].requestFrame(rqRequestSubLease,
    encodeRequestSubLease(msg))
  let decisions = session.decodeDecisionBatch(
    session.client[].readResponse(requestId))
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
    session.client[].lastDiagnostic = diagnostic(diagProtocol,
      "daemon omitted the sub-lease decision")
    raise newException(RunQuotaClientError,
      session.client[].lastDiagnostic.message)
  var polls = 0
  while maxPolls <= 0 or polls < maxPolls:
    for grant in session.pollNextGrant():
      if grant.clientCandidateId == candidateId and not grant.queued:
        # A later denial (the parent ended while this waited) arrives here
        # as an inactive decision, never as a grant.
        if not grant.lease.active:
          session.client[].lastDiagnostic = grant.diagnostic
          raise newException(RunQuotaClientError, grant.diagnostic.message)
        return grant.lease
    inc polls
    sleep(pollMillis)
  session.client[].lastDiagnostic = diagnostic(diagDenied,
    "timed out waiting for sub-lease grant")
  raise newException(RunQuotaClientError,
    session.client[].lastDiagnostic.message)

# ---------------------------------------------------------------------------
# Virtual machines (`VirtualMachinesMinor`)
# ---------------------------------------------------------------------------

proc supportsVirtualMachines*(client: RunQuotaClient): bool =
  ## Whether the daemon understands `RegisterVirtualMachine` and the host
  ## link.
  client.capabilities.protocolMinor >= VirtualMachinesMinor

proc registerVirtualMachineWaiting*(session: var RunQuotaSession;
    name, label: string; resources: ResourceVector;
    pollMillis = 50; maxPolls = 0): RunQuotaLease =
  ## Register a VM of `resources`' shape (CPU = its vCPUs, memory = its RAM,
  ## on `resources.machineId`) and wait until the host grants it. The lease
  ## holds the VM's memory for as long as it lives, and its CPU charge is
  ## the daemon's to move (full shape until the VM's guest daemon links).
  ## Raises `RunQuotaClientError` with `lastDiagnostic` set on refusal.
  if not session.active:
    session.client[].lastDiagnostic = diagnostic(diagInvalidArgument,
      "session is not active")
    raise newException(RunQuotaClientError,
      session.client[].lastDiagnostic.message)
  if not session.client[].supportsVirtualMachines():
    session.client[].lastDiagnostic = diagnostic(diagUnsupportedVersion,
      "daemon (protocol minor " &
      $session.client[].capabilities.protocolMinor &
      ") predates virtual machine registration")
    raise newException(RunQuotaClientError,
      session.client[].lastDiagnostic.message)
  let candidateId = session.client[].nextRequestId + 1'u64
  let requestId = session.client[].requestFrame(rqRegisterVirtualMachine,
    encodeRegisterVirtualMachine(RegisterVirtualMachineMessage(
      sessionId: session.id, clientCandidateId: candidateId, name: name,
      label: label, resources: resources)))
  var queued = false
  for decision in session.decodeDecisionBatch(
      session.client[].readResponse(requestId)):
    if decision.clientCandidateId == candidateId:
      if not decision.lease.active:
        session.client[].lastDiagnostic = decision.diagnostic
        raise newException(RunQuotaClientError, decision.diagnostic.message)
      if not decision.queued:
        return decision.lease
      queued = true
  if not queued:
    session.client[].lastDiagnostic = diagnostic(diagProtocol,
      "daemon omitted the registration decision")
    raise newException(RunQuotaClientError,
      session.client[].lastDiagnostic.message)
  var polls = 0
  while maxPolls <= 0 or polls < maxPolls:
    for grant in session.pollNextGrant():
      if grant.clientCandidateId == candidateId and not grant.queued:
        if not grant.lease.active:
          session.client[].lastDiagnostic = grant.diagnostic
          raise newException(RunQuotaClientError, grant.diagnostic.message)
        return grant.lease
    inc polls
    sleep(pollMillis)
  session.client[].lastDiagnostic = diagnostic(diagDenied,
    "timed out waiting for the virtual machine's registration")
  raise newException(RunQuotaClientError,
    session.client[].lastDiagnostic.message)

proc markVirtualMachineStarted*(lease: var RunQuotaLease; processId: uint64;
                                linkKind = vmLinkNone; vsockCid = 0'u32) =
  ## The registered VM runs as host process `processId`; its guest daemon
  ## will link from `vsockCid`. Moves the lease to running, with the VM
  ## process as the child the daemon watches.
  let msg = VirtualMachineStartedMessage(sessionId: lease.session[].id,
    leaseId: lease.id, processId: processId, linkKind: linkKind,
    vsockCid: vsockCid)
  let requestId = lease.session[].client[].requestFrame(
    rqVirtualMachineStarted, encodeVirtualMachineStarted(msg))
  let frame = lease.session[].client[].readResponse(requestId)
  var ack: VirtualMachineStartedAckMessage
  if frame.header.messageKind != rqVirtualMachineStartedAck or
      not decodeVirtualMachineStartedAck(frame.payload, ack) or
      ack.leaseId.value != lease.id.value:
    lease.session[].client[].lastDiagnostic = diagnostic(diagProtocol,
      "daemon did not acknowledge VirtualMachineStarted")
    raise newException(RunQuotaClientError,
      lease.session[].client[].lastDiagnostic.message)
  lease.state = leaseClientRunning

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

proc supportsPressure*(client: RunQuotaClient): bool =
  ## Whether the daemon understands build-wait pressure reports, queries and
  ## the expected-duration question of the finish: its `HelloOk` reported
  ## protocol minor `PressureMinor` or later.
  client.capabilities.protocolMinor >= PressureMinor

proc reportPressure*(session: var RunQuotaSession;
                     report: PressureReportMessage): bool =
  ## Send one build-wait pressure report for this session: what the
  ## invocation accumulated since its previous report (see
  ## ``PressureReportMessage``). At most ``MaxPressureWaitsPerReport`` of
  ## ``report.waits`` are sent; the caller keeps the rest for its next
  ## report.
  ##
  ## ONE-WAY, as ``reportObservation`` is: nothing is read back and no
  ## in-flight slot is used, so a report never makes the build wait. A
  ## daemon below ``PressureMinor`` is sent nothing (it would close the
  ## connection on the unknown kind). Returns whether the report was
  ## written; a failed write is a lost report, never an error.
  if not session.active or session.client.isNil or
      not session.client[].supportsPressure():
    return false
  var msg = report
  msg.sessionId = session.id
  inc session.client[].nextRequestId
  let requestId = session.client[].nextRequestId
  try:
    session.client[].connection.sendFrame(
      encodeFrame(rqPressureReport, FrameFlagRequest, requestId,
        encodePressureReport(msg)))
    true
  except CatchableError:
    false

proc queryPressure*(client: var RunQuotaClient; scope = psAll;
                    groupName = ""; timeoutMs = 0): string =
  ## The daemon's build-wait pressure figures as JSON (`QueryPressure`).
  ## Raises ``RunQuotaClientError`` for a daemon below ``PressureMinor``.
  if not client.supportsPressure():
    client.lastDiagnostic = diagnostic(diagUnsupportedVersion,
      "the RunQuota daemon predates build-wait pressure (protocol minor " &
      $client.capabilities.protocolMinor & ", needs " & $PressureMinor & ")")
    raise newException(RunQuotaClientError, client.lastDiagnostic.message)
  let requestId = client.requestFrame(rqQueryPressure,
    encodeQueryPressure(QueryPressureMessage(scope: scope,
      groupName: groupName)), timeoutMs)
  let frame = client.readResponse(requestId, timeoutMs)
  var answer: PressureAnswerMessage
  if frame.header.messageKind != rqPressureAnswer or
      not decodePressureAnswer(frame.payload, answer):
    client.lastDiagnostic = diagnostic(diagProtocol,
      "invalid PressureAnswer payload")
    raise newException(RunQuotaClientError, client.lastDiagnostic.message)
  answer.json

proc querySizing*(client: var RunQuotaClient; query: QuerySizingMessage;
                  timeoutMs = 0): string =
  ## The daemon's sizing answer as JSON (`QuerySizing`): profiles, a replay
  ## at N CPUs, or one page of the sizing export. Raises
  ## ``RunQuotaClientError`` for a daemon below ``SizingMinor`` or a
  ## refusal (the diagnostic says why).
  if not client.supportsSizing():
    client.lastDiagnostic = diagnostic(diagUnsupportedVersion,
      "the RunQuota daemon predates sizing (protocol minor " &
      $client.capabilities.protocolMinor & ", needs " & $SizingMinor & ")")
    raise newException(RunQuotaClientError, client.lastDiagnostic.message)
  let requestId = client.requestFrame(rqQuerySizing,
    encodeQuerySizing(query), timeoutMs)
  let frame = client.readResponse(requestId, timeoutMs)
  var answer: SizingAnswerMessage
  if frame.header.messageKind != rqSizingAnswer or
      not decodeSizingAnswer(frame.payload, answer):
    client.lastDiagnostic = diagnostic(diagProtocol,
      "invalid SizingAnswer payload")
    raise newException(RunQuotaClientError, client.lastDiagnostic.message)
  answer.json

proc supportsFinishTotals*(client: RunQuotaClient): bool =
  ## Whether the daemon reads the totals block of `LeaseFinished`: its
  ## `HelloOk` reported protocol minor `FinishTotalsMinor` or later.
  client.capabilities.protocolMinor >= FinishTotalsMinor

proc finish*(lease: var RunQuotaLease; outcome = succeeded();
             finishDiagnostic = okDiagnostic();
             peakMemoryBytes = 0'u64; processCount = 0'u32;
             majorPageFaults = 0'u64; pressureEvents = 0'u32;
             totals = FinishTotals(known: false);
             cpuProfile = noCpuProfile();
             askExpectedDuration = false;
             sizing = noFinishSizing()) =
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
  ##
  ## ``totals`` and ``cpuProfile`` are what the launcher measured of the
  ## tree (``runquota_process``'s ``ProcessCompletion``). They are dropped,
  ## not sent, to a daemon older than ``FinishTotalsMinor``, which would
  ## refuse the whole finish as malformed: losing a measurement is always
  ## preferable to losing the record of the execution.
  ##
  ## ``sizing`` (memory profile, IO bytes, the leases this execution waited
  ## on) is dropped, not sent, to a daemon older than ``SizingMinor``, for
  ## the same reason.
  ##
  ## ``askExpectedDuration`` asks the daemon for its expected uncontended
  ## duration of the command (build-wait pressure needs it to tell a slowed
  ## run from a long one); the answer lands in
  ## ``lease.expectedUncontendedMillis``. Asked only of a daemon at
  ## ``PressureMinor`` or above, which is the first that understands the
  ## question.
  if not lease.active:
    return
  let carriesTotals = lease.session[].client[].supportsFinishTotals()
  let asks = askExpectedDuration and
    lease.session[].client[].supportsPressure()
  let msg = LeaseFinishedMessage(
    sessionId: lease.session[].id,
    leaseId: lease.id,
    finish: outcome,
    peakMemoryBytes: peakMemoryBytes,
    processCount: processCount,
    majorPageFaults: majorPageFaults,
    pressureEvents: pressureEvents,
    diagnostic: finishDiagnostic,
    totals: (if carriesTotals: totals else: FinishTotals(known: false)),
    cpuProfile: (if carriesTotals: cpuProfile else: noCpuProfile()),
    sizing: (if lease.session[].client[].supportsSizing(): sizing
             else: noFinishSizing()),
    wantExpectedDuration: asks
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
  if acknowledged.expectedKnown:
    lease.expectedUncontendedMillis = acknowledged.expectedUncontendedMillis
  lease.state = leaseClientFinished

proc supportsPoolDeclarations*(client: RunQuotaClient): bool =
  ## Whether the daemon this client is connected to understands
  ## `DeclarePools`: its `HelloOk` reported protocol minor
  ## `PoolDeclarationsMinor` or later.
  client.capabilities.protocolMinor >= PoolDeclarationsMinor

proc declarePools*(session: var RunQuotaSession;
                   pools: openArray[NamedPoolCapWire]): PoolsDeclaredMessage =
  ## State the named pools this session's work uses and the capacity each is
  ## expected to have (`DeclarePools`). The daemon admits against a declared
  ## capacity only for a pool neither its host file nor a `runquotad` flag
  ## sizes, and only while a session that declared it is open; the answer
  ## says, per pool, the cap in force and where it comes from.
  ##
  ## NOTHING IS SENT TO A DAEMON THAT PREDATES THE MESSAGE. Such a daemon
  ## closes the connection on an unknown message kind, and every session on
  ## the connection with it, so the daemon's minor is checked first and the
  ## call raises `RunQuotaClientError` (`diagUnsupportedVersion`) with the
  ## connection intact.
  if not session.client[].supportsPoolDeclarations():
    session.client[].lastDiagnostic = diagnostic(diagUnsupportedVersion,
      "the running runquotad (protocol minor " &
      $session.client[].capabilities.protocolMinor & ") predates pool " &
      "declarations, so it admits only the pools its host file or --pool " &
      "flags size")
    raise newException(RunQuotaClientError,
      session.client[].lastDiagnostic.message)
  var msg = DeclarePoolsMessage(sessionId: session.id)
  for pool in pools:
    msg.pools.add(pool)
  let requestId = session.client[].requestFrame(rqDeclarePools,
    encodeDeclarePools(msg), handshakeTimeoutMs())
  let frame = session.client[].readResponse(requestId, handshakeTimeoutMs())
  if frame.header.messageKind != rqPoolsDeclared:
    session.client[].lastDiagnostic = diagnostic(diagProtocol,
      "daemon did not answer DeclarePools")
    raise newException(RunQuotaClientError,
      session.client[].lastDiagnostic.message)
  if not decodePoolsDeclared(frame.payload, result):
    session.client[].lastDiagnostic = diagnostic(diagProtocol,
      "invalid PoolsDeclared payload")
    raise newException(RunQuotaClientError,
      session.client[].lastDiagnostic.message)

proc supportsRetirement*(client: RunQuotaClient): bool =
  ## Whether the daemon this client is connected to understands
  ## `RetireDaemon`: its `HelloOk` reported protocol minor `RetirementMinor`
  ## or later.
  client.capabilities.protocolMinor >= RetirementMinor

proc retireDaemon*(client: var RunQuotaClient; expectedImageDigest = "";
                   reason = ""; timeoutMs = 0): DaemonRetirementMessage =
  ## Ask the daemon to make way for another build of itself (`RetireDaemon`).
  ## With `expectedImageDigest` (`imageDigestOf` the runquotad the caller
  ## would start) a daemon running that image answers `retirementCurrent` and
  ## stays; with none it retires whatever it runs. A retiring daemon exits
  ## once no client connection is open -- this one included, so the caller
  ## closes it when it has read the answer.
  ##
  ## NOTHING IS SENT TO A DAEMON THAT PREDATES THE MESSAGE, for the reason
  ## `declarePools` gives: it would close the connection. The call raises
  ## `RunQuotaClientError` (`diagUnsupportedVersion`) instead, naming the
  ## daemon's version and minor.
  if not client.supportsRetirement():
    client.lastDiagnostic = diagnostic(diagUnsupportedVersion,
      "the running runquotad (" & client.daemonVersion & ", protocol minor " &
      $client.capabilities.protocolMinor & ") predates RetireDaemon, so it " &
      "cannot be asked to make way; it keeps serving until it exits")
    raise newException(RunQuotaClientError, client.lastDiagnostic.message)
  let requestId = client.requestFrame(rqRetireDaemon, encodeRetireDaemon(
    RetireDaemonMessage(expectedImageDigest: expectedImageDigest,
      reason: reason)), timeoutMs)
  let frame = client.readResponse(requestId, timeoutMs)
  if frame.header.messageKind != rqDaemonRetirement:
    client.lastDiagnostic = diagnostic(diagProtocol,
      "daemon did not answer RetireDaemon")
    raise newException(RunQuotaClientError, client.lastDiagnostic.message)
  if not decodeDaemonRetirement(frame.payload, result):
    client.lastDiagnostic = diagnostic(diagProtocol,
      "invalid DaemonRetirement payload")
    raise newException(RunQuotaClientError, client.lastDiagnostic.message)

proc reloadHostConfig*(client: var RunQuotaClient): HostConfigReloadedMessage =
  ## Ask the daemon to re-read its host budget file and put it in force
  ## (`ReloadHostConfig`). Raises `RunQuotaClientError` with the daemon's
  ## reason when the file does not parse -- the budget in force is then
  ## unchanged -- and when the daemon predates the message.
  let requestId = client.requestFrame(rqReloadHostConfig, "")
  let frame =
    try:
      client.readResponse(requestId)
    except RunQuotaClientError as err:
      if client.lastDiagnostic.code in {diagProtocol, diagUnsupportedMessage}:
        # An older daemon refuses a message kind it does not know: below
        # `UnsupportedMessageMinor` by closing the connection or answering
        # "unsupported RQSP message" (`diagProtocol`), from that minor on by
        # answering `diagUnsupportedMessage`. Every daemon at or above that
        # minor knows `ReloadHostConfig`, so today only the first form
        # occurs; both are matched so the check does not depend on that.
        client.lastDiagnostic = diagnostic(diagUnsupportedVersion,
          "the running runquotad does not support ReloadHostConfig (" &
          err.msg & "); it is older than this client, so restart it to " &
          "apply the host configuration")
        raise newException(RunQuotaClientError, client.lastDiagnostic.message)
      raise
  if frame.header.messageKind != rqHostConfigReloaded:
    client.lastDiagnostic = diagnostic(diagProtocol,
      "daemon did not answer ReloadHostConfig")
    raise newException(RunQuotaClientError, client.lastDiagnostic.message)
  if not decodeHostConfigReloaded(frame.payload, result):
    client.lastDiagnostic = diagnostic(diagProtocol,
      "invalid HostConfigReloaded payload")
    raise newException(RunQuotaClientError, client.lastDiagnostic.message)

proc daemonStatus*(client: var RunQuotaClient;
                   timeoutMs = 0): DaemonStatusMessage =
  ## Round-trip a StatusRequest.  ``timeoutMs > 0`` bounds the write and read so a
  ## wedged daemon (accepts the connection but never answers) raises
  ## ``RunQuotaClientError`` instead of blocking forever — this is what
  ## makes ``daemonStatus`` usable as a *liveness probe*: a bounded
  ## successful round-trip proves the daemon is alive, while a timeout (or
  ## a closed connection) is detectable as silence.  ``timeoutMs == 0``
  ## keeps the legacy unbounded behaviour.
  let requestId = client.requestFrame(rqStatusRequest, "", timeoutMs)
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

# ---------------------------------------------------------------------------
# Build-wait pressure of a one-command client (`runquota run`, `runquota
# jobserver`)
# ---------------------------------------------------------------------------

type
  SingleCommandPressure* = object
    ## The build-wait pressure of a client that runs ONE command under one
    ## lease. With one command, *some* and *full* are the same thing: the
    ## command is the only ready-or-running one, so it held the invocation
    ## up exactly while it waited for its lease. Such a client knows no
    ## expected uncontended duration, so it reports the queue part only and
    ## says so (`queue_only`); while the command runs it is counted as not
    ## held up.
    ##
    ## Two reports, each covering its own stretch of wall time, so the
    ## daemon's decaying averages place the wait where it happened: one at
    ## the grant (registration to grant, the queue wait held up) and one at
    ## the end (grant to end, nothing held up).
    enabled*: bool
      ## The `pressure-reports` measurement switch, read once at start.
    registeredAt*: MonoTime
    requestedAt*: MonoTime
    requestedAtUnixMillis*: uint64
    grantedAt*: MonoTime
    granted*: bool

proc pressureReportsEnabled*(): bool =
  ## Whether this client takes build-wait pressure: the `pressure-reports`
  ## measurement, from `RUNQUOTA_MEASUREMENT` (off by default).
  measurePressureReports in clientMeasurements()

proc micros(a, b: MonoTime): uint64 =
  let ns = (b - a).inNanoseconds
  if ns <= 0: 0'u64 else: uint64(ns div 1000)

proc startSingleCommandPressure*(): SingleCommandPressure =
  ## Call right after the session is registered.
  result.enabled = pressureReportsEnabled()
  result.registeredAt = getMonoTime()
  result.requestedAt = result.registeredAt
  result.requestedAtUnixMillis = uint64(max(0'i64,
    (getTime() - fromUnix(0)).inMilliseconds))

proc noteRequested*(pressure: var SingleCommandPressure) =
  ## Call just before the lease is asked for.
  pressure.requestedAt = getMonoTime()
  pressure.requestedAtUnixMillis = uint64(max(0'i64,
    (getTime() - fromUnix(0)).inMilliseconds))

proc reportGranted*(pressure: var SingleCommandPressure;
                    session: var RunQuotaSession) =
  ## Call once the lease is granted: reports the queue wait.
  if pressure.granted:
    return
  pressure.granted = true
  pressure.grantedAt = getMonoTime()
  if not pressure.enabled:
    return
  let queued = micros(pressure.requestedAt, pressure.grantedAt)
  var report = PressureReportMessage(queueOnly: true,
    wallMicros: micros(pressure.registeredAt, pressure.grantedAt),
    someMicros: queued, fullMicros: queued)
  if queued >= 1_000_000'u64:
    report.waits.add(PressureWait(
      startedAtUnixMillis: pressure.requestedAtUnixMillis,
      lengthMillis: queued div 1000'u64, kind: pwkQueue))
  discard session.reportPressure(report)

proc reportEnded*(pressure: var SingleCommandPressure;
                  session: var RunQuotaSession) =
  ## Call when the command has ended, before the session closes: reports
  ## the running time, in which the one command held nothing up.
  if not pressure.enabled or not pressure.granted:
    return
  discard session.reportPressure(PressureReportMessage(queueOnly: true,
    wallMicros: micros(pressure.grantedAt, getMonoTime())))
