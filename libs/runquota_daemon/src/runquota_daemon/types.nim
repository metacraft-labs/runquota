import std/tables

import runquota_core
import runquota_ipc
import runquota_observation_store
import runquota_persistence
import runquota_protocol

type
  LibraryInfo* = object
    name*: string

  DaemonState* = enum
    dsStarting
    dsServing
    dsStopping

  LeaseLifecycleState* = enum
    leaseStateQueued
    leaseStateGranted
    leaseStateStarting
    leaseStateRunning
    leaseStateFinished
    leaseStateSupervisorLost

  PressureSourceKind* = enum
    pressureSourceHost
    pressureSourceDeterministicFile
    pressureSourceUnavailable

  MachineCapacity* = object
    id*: string
    cpuSlots*: MilliCpu
    memoryBytes*: Bytes
    ioSlots*: uint32
    cpuShareGroup*: string

  CpuShareGroup* = object
    id*: string
    cpuSlots*: MilliCpu

  DaemonConfig* = object
    endpoint*: Endpoint
    daemonId*: uint64
    cpuSlots*: MilliCpu
    memoryBytes*: Bytes
    ioSlots*: uint32
    machines*: Table[string, MachineCapacity]
    cpuShareGroups*: Table[string, CpuShareGroup]
    namedPoolCaps*: Table[string, uint32]
    version*: string
    pressureSource*: PressureSourceKind
    pressureFile*: string
    pressureRequired*: bool
    memoryPressureHeavyBytes*: Bytes
    estimateDbPath*: string
    estimateQueueCapacity*: int
    observationDbPath*: string
      ## An EXPLICIT store path, or empty for the host's default one.
      ## Empty no longer means "capture off": capture is on by default
      ## (the specification's §"Capture Is Enabled By Default"), and the
      ## way to turn it off is ``writeStatsDisabled`` below.
    writeStatsDisabled*: bool
      ## The operator's off switch (``runquotad --no-write-stats``). It is
      ## a FLAG rather than "leave the path empty" so that the two states
      ## the operator cares about — "on, at the default location" and
      ## "off, deliberately" — are distinguishable in the config, in the
      ## startup report, and in a test. An empty path meaning "off" would
      ## have made the default-on requirement unstatable.
    observationQueueCapacity*: int
    hostIdentityFilePath*: string
      ## Where this machine's ``host_id`` is kept. Empty means the
      ## per-user default; tests point it at a scratch directory so they
      ## neither read nor write the operator's real machine identity.
    ambientSampleIntervalMillis*: int
      ## The FIXED cadence of ambient load sampling (M11), independent of
      ## execution boundaries. Zero or negative turns ambient sampling off
      ## while leaving execution capture on.

  SessionRow* = object
    id*: SessionId
    name*: string
    version*: string
    supervisorProcessId*: uint64
    supervisorUserId*: uint64
    peer*: PeerIdentity

  LeaseRow* = object
    id*: LeaseId
    sessionId*: SessionId
    label*: string
    commandStatsId*: string
    clientCandidateId*: uint64
    resources*: ResourceVector
    priority*: PriorityClass
    purpose*: LeasePurpose
    queueOrder*: uint64
    delivered*: bool
    state*: LeaseLifecycleState
    supervisorProcessId*: uint64
    supervisorUserId*: uint64
    peer*: PeerIdentity
    childProcessId*: uint64
    processGroupId*: uint64
    cleanupRegistered*: bool
    finishOutcome*: LeaseFinishOutcome
    finishDiagnostic*: Diagnostic
    peakMemoryBytes*: uint64
    processCount*: uint32
    majorPageFaults*: uint64
    pressureEvents*: uint32
    hardLimitOrOom*: bool
    queueDiagnostic*: Diagnostic
    startedAtUnixMillis*: int64
      ## When the client reported the lease as starting. Observation only:
      ## the daemon does not watch the process tree, so this is the lease
      ## window it was told about, not a measurement it took.

  ConnectionContext* = object
    supervisorProcessId*: uint64
    supervisorUserId*: uint64
    peer*: PeerIdentity
    sessionIds*: seq[SessionId]

  MachineUsage* = object
    cpu*: uint32
    memory*: uint64
    ioSlots*: uint32

  PressureFileCache* = object
    path*: string
    mtimeUnix*: int64
    sizeBytes*: int64
    raw*: string

  RunQuotaDaemon* = object
    config*: DaemonConfig
    state*: DaemonState
    nextSessionId*: uint64
    nextLeaseId*: uint64
    nextQueueOrder*: uint64
    lastGrantedSessionId*: uint64
    totalGranted*: uint64
    totalFinished*: uint64
    sessions*: Table[uint64, SessionRow]
    leases*: Table[uint64, LeaseRow]
    estimates*: Table[string, LearnedEstimateRow]
    estimateStore*: EstimateStore
    observationStore*: ObservationStore
    observationHostId*: string
    observationProfileId*: string
      ## The hardware profile current for this daemon's host. Every
      ## ``executions`` row it writes references this and nothing else, so
      ## a profile transition mid-life would need a restart to be picked
      ## up — see M10's deferrals.
    observationIdentityReport*: string
    observationBootId*: string
    observationRunIds*: Table[uint64, string]
      ## Session id to the ``runs`` row it opened.
    observationsAccepted*: uint64
      ## In-flight ``LeaseObservation`` reports folded into ``self_*``.
    observationsRejected*: uint64
      ## Reports refused, for any reason. OS-2 wants every lost
      ## observation COUNTED, and a refusal is a loss: the client believes
      ## it reported and the store disagrees, so the number has to be
      ## readable somewhere. It is one counter rather than one per reason
      ## because the reason is already in the daemon's own view and the
      ## count is what a reader needs to distrust a window.
    selfReportsReaped*: uint64
      ## Live self-reports dropped on behalf of a client that did not end
      ## them itself — a supervisor whose connection died mid-execution.
      ## Non-zero means the crash exit fired, which is the only evidence
      ## that the leak M11 recorded is actually closed rather than merely
      ## unreachable in the happy path.
    activeLeaseCount*: uint32
    activeBenchmarkCount*: uint32
    machineUsage*: Table[string, MachineUsage]
    cpuShareGroupUsage*: Table[string, uint32]
    namedPoolUsage*: Table[string, uint32]
    pressureFileCache*: PressureFileCache
