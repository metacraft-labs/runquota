## Row and status types for the RunQuota observation store.
##
## The schema these mirror is normatively specified in
## ``reprobuild-specs/RunQuota-Observation-Store.md`` §"The Execution Spine".
## Columns the RunQuota protocol cannot yet supply are modelled as
## ``Option`` and stored as SQL ``NULL`` rather than as a zero, because a
## zero would be indistinguishable from a measured zero.

import std/options

# `CaptureCompleteness` LIVES IN `runquota_core` and is re-exported here.
# A standalone client has to say "this window is incomplete" without
# linking the store library, so the enum cannot live in the store; it is
# re-exported so every `import runquota_observation_store` still sees it.
import runquota_core/types as coreTypes
export coreTypes.CaptureCompleteness

type
  LibraryInfo* = object
    name*: string

  Termination* = enum
    ## Failure modes a bare exit status conflates.
    tExited = "exited"
    tSignalled = "signalled"
    tTimeout = "timeout"
    tOomKilled = "oom_killed"
    tRefused = "refused"

  DiskClass* = enum
    dcNvme = "nvme"
    dcSsd = "ssd"
    dcHdd = "hdd"
    dcNetwork = "network"
    dcUnknown = "unknown"

  StoreStatus* = enum
    ## Why capture is or is not running. Only ``ssOpen`` enables capture;
    ## every other value degrades to no capture and MUST NOT fail a build
    ## or a test run (OS-4).
    ssOpen = "open"
    ssDisabled = "disabled"
    ssNoSqliteTool = "degraded-no-sqlite-tool"
    ssCorrupt = "degraded-corrupt"
    ssUnwritable = "degraded-unwritable"
    ssRefusedNewer = "refused-newer-schema"

  HostRow* = object
    hostId*: string
    createdAtUnixMillis*: int64
    lastBootId*: string

  HardwareProfile* = object
    ## The descriptive half of a ``host_profiles`` row: what the machine
    ## is, with nothing about which row records it or when that row was
    ## current. ``profileHash`` digests exactly these fields, which is why
    ## they are a separate type rather than a comment on ``HostProfileRow``
    ## — a field added to the row that must not change the hash cannot be
    ## added here by accident.
    cpuModel*: string
    physicalCores*: int64
    logicalCores*: int64
    ramBytes*: int64
    swapBytes*: int64
    diskClass*: DiskClass
    fsType*: string
    arch*: string
    os*: string
    osVersion*: string
    kernelVersion*: string
    virtualization*: string
    cpuShareGroup*: string

  HostProfileRow* = object
    hostId*: string
    profileId*: string
    profileHash*: string
    validFromUnixMillis*: int64
    validToUnixMillis*: Option[int64]
    cpuModel*: string
    physicalCores*: int64
    logicalCores*: int64
    ramBytes*: int64
    swapBytes*: int64
    diskClass*: DiskClass
    fsType*: string
    arch*: string
    os*: string
    osVersion*: string
    kernelVersion*: string
    virtualization*: string
    cpuShareGroup*: string

  RunRow* = object
    runId*: string
    hostId*: string
    tool*: string
    toolVersion*: string
    invocationKind*: string
    startedAtUnixMillis*: int64
    finishedAtUnixMillis*: Option[int64]
    exitStatus*: Option[int64]
    workspaceId*: Option[string]
    profile*: Option[string]
    gitCommit*: Option[string]
    gitBranch*: Option[string]
    captureCompleteness*: CaptureCompleteness
    droppedObservations*: int64

  ExecutionRow* = object
    executionId*: string
    hostId*: string
    hostProfileId*: Option[string]
    runId*: string
    commandStatsId*: string
    leaseId*: Option[int64]
    startedAtUnixMillis*: int64
    finishedAtUnixMillis*: int64
    durationMillis*: int64
    exitStatus*: int64
    termination*: Termination
    attempt*: int64
    retryOf*: Option[string]
    peakRssBytes*: int64
    cpuUserMillis*: Option[int64]
    cpuSysMillis*: Option[int64]
    maxProcesses*: int64
    majorPageFaults*: int64
    ioReadBytes*: Option[int64]
    ioWriteBytes*: Option[int64]
    captureCompleteness*: CaptureCompleteness
    droppedObservations*: int64
    ownerUid*: Option[int64]
      ## The owner id whose lease this execution ran under -- the uid on
      ## POSIX, the SID's hash on Windows (``runquota_core/owner_id``) --
      ## taken by the daemon from the connection's peer credentials and
      ## NEVER from anything the client declares. ``none`` means the
      ## transport could not report them; it does not mean root. A value
      ## must have a ``users`` row: the schema refuses the insert otherwise.

  AmbientSampleRow* = object
    hostId*: string
    sampledAtUnixMillis*: int64
    cpuBusyPct*: float64
    memAvailableBytes*: int64
    swapInRate*: float64
    ioQueueDepth*: float64
    loadAvg1m*: float64
    selfCpuPct*: float64
    selfRssBytes*: int64
    foreignCpuPct*: float64
    foreignRssBytes*: int64

  ExtensionRegistryRow* = object
    extensionId*: string
    schemaVersion*: int64
    owner*: string
    tableName*: string
    registeredAtUnixMillis*: int64

  PrincipalKind* = enum
    ## What a ``users`` row's owner id was derived from.
    pkUid = "uid"
      ## A POSIX uid; ``principal`` is the uid in decimal.
    pkSid = "sid"
      ## A Windows SID; ``principal`` is its string form and the owner id
      ## its hash (``runquota_core/owner_id``).

  UserRow* = object
    ## One owner, recorded once. ``executions.owner_uid`` references it.
    ownerUid*: int64
    principalKind*: PrincipalKind
    principal*: string
      ## The preimage of ``ownerUid``. Immutable: a different principal
      ## under an existing id is a collision and is refused.
    name*: Option[string]
      ## For display only -- ``DOMAIN\user`` or the login name. ``none``
      ## means it has never been resolved; a name that stops resolving is
      ## KEPT rather than cleared.
    firstSeenAtUnixMillis*: int64
    nameUpdatedAtUnixMillis*: Option[int64]
      ## When ``name`` last took its current value. ``none`` exactly when
      ## ``name`` is.
