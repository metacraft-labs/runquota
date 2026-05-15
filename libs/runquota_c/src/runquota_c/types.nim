import runquota_client

type
  LibraryInfo* = object
    name*: string

  AbiVersion* = object
    major*: uint16
    minor*: uint16

  RqStatus* {.size: sizeof(cint).} = enum
    rqOk = 0
    rqErrUnavailable = 1
    rqErrUnsupportedVersion = 2
    rqErrDenied = 3
    rqErrCancelled = 4
    rqErrProtocol = 5
    rqErrInvalidArgument = 6
    rqErrInternal = 7

  RqResourceRequestV1* {.exportc: "rq_resource_request_v1".} = object
    size*: uint32
    labelPtr*: cstring
    labelLen*: csize_t
    commandStatsIdPtr*: ptr uint8
    commandStatsIdLen*: csize_t
    cpuMilliSlots*: uint32
    memoryBytes*: uint64
    hardMemoryLimitBytes*: uint64
    ioClass*: uint32
    priorityClass*: uint32
    timeoutMillis*: uint64

  RqClient* {.exportc: "rq_client".} = object
    client*: RunQuotaClient
    lastStatus*: RqStatus
    lastError*: string

  RqSession* {.exportc: "rq_session".} = object
    owner*: ptr RqClient
    session*: RunQuotaSession

  RqLease* {.exportc: "rq_lease".} = object
    owner*: ptr RqSession
    lease*: RunQuotaLease
