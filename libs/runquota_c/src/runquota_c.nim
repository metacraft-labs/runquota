import std/strutils

import runquota_c/types as cTypes
import runquota_client
import runquota_core

export cTypes

const libraryName* = "runquota_c"
const RqAbiMajor* = 1'u16
const RqAbiMinor* = 0'u16

proc libraryInfo*(): cTypes.LibraryInfo =
  cTypes.LibraryInfo(name: libraryName)

proc abiVersion*(): AbiVersion =
  AbiVersion(major: RqAbiMajor, minor: RqAbiMinor)

proc rq_abi_version*(): AbiVersion {.exportc, cdecl.} =
  abiVersion()

proc rq_resource_request_v1_size*(): uint32 {.exportc, cdecl.} =
  uint32(sizeof(RqResourceRequestV1))

proc rq_abi_layout_ok*(): bool {.exportc, cdecl.} =
  sizeof(RqResourceRequestV1) >= (sizeof(uint32) * 4 + sizeof(uint64) * 3 + sizeof(csize_t) * 2 + sizeof(pointer) * 2)

proc makeString(value: cstring; length: csize_t): string =
  if value == nil or length == 0:
    return ""
  result = newString(int(length))
  copyMem(addr result[0], value, int(length))

proc makeBytes(value: ptr uint8; length: csize_t): string =
  if value == nil or length == 0:
    return ""
  result = newString(int(length))
  copyMem(addr result[0], value, int(length))

proc setError(client: ptr RqClient; status: RqStatus; message: string): RqStatus =
  if client != nil:
    client.lastStatus = status
    client.lastError = message
  status

proc toStatusMessage(message: string): RqStatus =
  if message.contains("unsupported"):
    rqErrUnsupportedVersion
  elif message.contains("denied"):
    rqErrDenied
  elif message.contains("invalid"):
    rqErrInvalidArgument
  else:
    rqErrProtocol

proc toResourceRequest(request: ptr RqResourceRequestV1): ResourceRequest =
  if request == nil:
    raise newException(ValueError, "request is nil")
  if request.size < rq_resource_request_v1_size():
    raise newException(ValueError, "request size is smaller than rq_resource_request_v1")
  result = resourceRequest(
    makeString(request.labelPtr, request.labelLen),
    milliCpu(request.cpuMilliSlots),
    bytes(request.memoryBytes)
  )
  result.commandStatsId = makeBytes(request.commandStatsIdPtr, request.commandStatsIdLen)
  result.resources.hardMemoryLimit = bytes(request.hardMemoryLimitBytes)
  if request.ioClass <= uint32(ord(high(IoClass))):
    result.resources.ioClass = IoClass(int(request.ioClass))
  if request.priorityClass <= uint32(ord(high(PriorityClass))):
    result.priority = PriorityClass(int(request.priorityClass))
  if request.timeoutMillis > 0:
    result.deadline = timeoutDeadline(deadlineMillis(request.timeoutMillis))

proc rq_client_connect_default*(outClient: ptr ptr RqClient): RqStatus {.exportc, cdecl.} =
  if outClient == nil:
    return rqErrInvalidArgument
  let raw = cast[ptr RqClient](alloc0(sizeof(RqClient)))
  if raw == nil:
    return rqErrInternal
  try:
    raw.client = connectDefault()
    raw.lastStatus = rqOk
    raw.lastError = ""
    outClient[] = raw
    rqOk
  except CatchableError as error:
    dealloc(raw)
    outClient[] = nil
    toStatusMessage(error.msg)

proc rq_client_close*(client: ptr RqClient): RqStatus {.exportc, cdecl.} =
  if client == nil:
    return rqErrInvalidArgument
  client.client.close()
  dealloc(client)
  rqOk

proc rq_session_register*(client: ptr RqClient; namePtr: cstring; nameLen: csize_t;
                          outSession: ptr ptr RqSession): RqStatus {.exportc, cdecl.} =
  if client == nil or outSession == nil:
    return rqErrInvalidArgument
  let raw = cast[ptr RqSession](alloc0(sizeof(RqSession)))
  if raw == nil:
    return client.setError(rqErrInternal, "allocation failed")
  try:
    raw.owner = client
    raw.session = client.client.registerSession(makeString(namePtr, nameLen), "c-abi")
    outSession[] = raw
    client.setError(rqOk, "")
  except CatchableError as error:
    dealloc(raw)
    outSession[] = nil
    client.setError(toStatusMessage(error.msg), error.msg)

proc rq_session_close*(session: ptr RqSession): RqStatus {.exportc, cdecl.} =
  if session == nil:
    return rqErrInvalidArgument
  try:
    session.session.closeSession()
    dealloc(session)
    rqOk
  except CatchableError as error:
    session.owner.setError(toStatusMessage(error.msg), error.msg)

proc rq_lease_request*(session: ptr RqSession; request: ptr RqResourceRequestV1;
                       outLease: ptr ptr RqLease): RqStatus {.exportc, cdecl.} =
  if session == nil or request == nil or outLease == nil:
    return rqErrInvalidArgument
  let raw = cast[ptr RqLease](alloc0(sizeof(RqLease)))
  if raw == nil:
    return session.owner.setError(rqErrInternal, "allocation failed")
  try:
    let converted = toResourceRequest(request)
    raw.owner = session
    raw.lease = session.session.requestLease(converted)
    outLease[] = raw
    session.owner.setError(rqOk, "")
  except CatchableError as error:
    dealloc(raw)
    outLease[] = nil
    session.owner.setError(toStatusMessage(error.msg), error.msg)

proc rq_lease_release*(lease: ptr RqLease): RqStatus {.exportc, cdecl.} =
  if lease == nil:
    return rqErrInvalidArgument
  try:
    lease.lease.release()
    dealloc(lease)
    rqOk
  except CatchableError as error:
    lease.owner.owner.setError(toStatusMessage(error.msg), error.msg)

proc rq_last_error_json*(client: ptr RqClient; outJson: ptr cstring;
                         outLen: ptr csize_t): RqStatus {.exportc, cdecl.} =
  if client == nil or outJson == nil or outLen == nil:
    return rqErrInvalidArgument
  let message = "{\"status\":" & $ord(client.lastStatus) & ",\"message\":\"" &
    client.lastError.replace("\\", "\\\\").replace("\"", "\\\"") & "\"}"
  let mem = cast[ptr UncheckedArray[char]](alloc(message.len + 1))
  if mem == nil:
    return client.setError(rqErrInternal, "allocation failed")
  copyMem(addr mem[0], cstring(message), message.len)
  mem[message.len] = '\0'
  outJson[] = cast[cstring](mem)
  outLen[] = csize_t(message.len)
  rqOk

proc rq_free*(memory: pointer) {.exportc, cdecl.} =
  if memory != nil:
    dealloc(memory)

static:
  doAssert RqAbiMajor == 1'u16
  doAssert sizeof(RqResourceRequestV1) >= sizeof(uint64) * 3
