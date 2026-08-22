## Row and status types for the RunQuota observation store.
##
## The schema these mirror is normatively specified in
## ``reprobuild-specs/RunQuota-Observation-Store.md`` §"The Execution Spine".
## Columns the RunQuota protocol cannot yet supply are modelled as
## ``Option`` and stored as SQL ``NULL`` rather than as a zero, because a
## zero would be indistinguishable from a measured zero.

import std/options

type
  LibraryInfo* = object
    name*: string

  CaptureCompleteness* = enum
    ## Per-run and per-row honesty about whether the observation window is
    ## whole (OS-2). ``ccDegraded`` means observations were lost.
    ccComplete = "complete"
    ccSampled = "sampled"
    ccDegraded = "degraded"

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
      ## The uid whose lease this execution ran under, taken by the daemon
      ## from the connection's peer credentials and NEVER from anything the
      ## client declares. ``none`` means the transport could not report
      ## them; it does not mean root.

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
