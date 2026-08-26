import std/tables

import runquota_core
import runquota_ipc
import runquota_observation_store
import runquota_persistence
import runquota_protocol
import runquota_stats_table/publisher

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
    retentionPolicy*: RetentionPolicy
      ## The bounds the scheduled retention pass enforces. M15 built them
      ## and nothing called them; this is what a daemon carries so that a
      ## store which is ON BY DEFAULT is also BOUNDED by default. The two
      ## have to travel together: the argument for default-on capture is
      ## that an opt-in store is empty exactly when it is first needed,
      ## and that argument does not survive an unbounded one.
    retentionSweepIntervalMillis*: int
      ## Cadence of that pass. Zero or negative turns retention off while
      ## leaving capture on — the same shape as
      ## ``ambientSampleIntervalMillis`` above and for the same reason:
      ## "off" has to be a state an operator can name, in the config, in
      ## the startup report, and in a test.
    retentionMaxDeferredSweeps*: int
      ## How many consecutive sweeps a live lease may defer before one
      ## runs anyway. A prune competes for the disk the work runs on, so
      ## waiting for a quiet tick is right; waiting for one forever is not
      ## a bound, and a machine that is never idle is the one whose store
      ## grows fastest.

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
    finish*: LeaseFinish
    finishDiagnostic*: Diagnostic
    peakMemoryBytes*: uint64
    processCount*: uint32
    majorPageFaults*: uint64
    pressureEvents*: uint32
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
    observationExecutionIds*: Table[uint64, tuple[executionId: string,
        sessionId: uint64]]
      ## Lease id to the ``executions`` row it produced, and to the session
      ## that owned the lease (M17).
      ##
      ## THE ONLY WAY AN EXTENSION ROW CAN BE JOINED TO THE SPINE. The
      ## execution id is minted here when the lease finishes and is never
      ## sent to the client, so a client-supplied key would be an
      ## invention; the client names the LEASE it was granted, and this
      ## table is what turns that into the row's key.
      ##
      ## THE SESSION IS REMEMBERED BESIDE IT, AND IS THE OWNERSHIP CHECK.
      ## It cannot be `daemon.leases`: a client releases a lease as soon as
      ## its process exits, which deletes the row, whereas the facts a
      ## build knows about that action -- its output sizes, its dependency
      ## evidence -- are not complete until much later. Checking a table
      ## the client has already been told to empty would refuse every
      ## honest row and accept none.
      ##
      ## BOUNDED, and the bound is what makes a late row a DROP rather
      ## than a leak: a build that runs a million actions must not grow a
      ## million-entry map for rows most of its clients will never send.
      ## The oldest entries go first, and a row arriving after its entry
      ## was evicted is counted as a rejected observation like any other
      ## loss.
    observationExecutionOrder*: seq[uint64]
      ## Insertion order for the bound above. A sequence rather than a
      ## timestamp because eviction is by AGE OF ENTRY, and two leases
      ## finishing in the same millisecond must still evict in a defined
      ## order or two runs of the same build could differ.
    observationExtensionRows*: uint64
      ## Extension rows admitted and queued for the writer.
    observationExtensionRowsRefused*: uint64
      ## Extension rows refused, for any reason — a payload that would not
      ## decode, a lease this connection does not own, a lease whose
      ## execution has been evicted, or a row the store would not admit.
      ## Counted rather than reported, because the message is one-way and
      ## a reply is the round trip it exists to avoid.
    observationsAccepted*: uint64
      ## In-flight ``LeaseObservation`` reports folded into ``self_*``.
    observationsRejected*: uint64
      ## Reports refused, for any reason. OS-2 wants every lost
      ## observation COUNTED, and a refusal is a loss: the client believes
      ## it reported and the store disagrees, so the number has to be
      ## readable somewhere. It is one counter rather than one per reason
      ## because the reason is already in the daemon's own view and the
      ## count is what a reader needs to distrust a window.
    deferredBatchesAccepted*: uint64
      ## Exit flushes from standalone clients that were recorded (M14). A
      ## batch, not a row: one long-lived client that ran without a daemon
      ## produces exactly one of these however many executions it buffered.
    deferredBatchesRefused*: uint64
      ## Exit flushes refused — a batch that would not decode, or one
      ## claiming a COMPLETE capture window, which a client that ran with
      ## nothing draining it cannot have had. Counted here because the
      ## message is one-way: the client is exiting and is never told.
    deferredExecutionsRecorded*: uint64
      ## Rows written out of accepted batches, so "the flush landed" and
      ## "the flush arrived empty" are distinguishable from outside.
    observationsContradictory*: uint64
      ## Executions whose finish carried a termination its own exit could
      ## not support — a resource-limit or deadline kill reported beside a
      ## clean exit — and which therefore produced NO row.
      ##
      ## A SEPARATE COUNTER FROM ``observationsRejected``, which is about
      ## in-flight self-reports and about nothing else. These are whole
      ## executions the store does not hold and the client believes it
      ## reported, so a reader deciding whether a window is thinned needs
      ## them counted apart from a refused sample of a live one.
      ##
      ## Counted rather than reported, for the reason ``captureObservation``
      ## gives: the alternative is failing a ``LeaseFinished``, which
      ## strands the lease.
    statsPublisher*: StatsPublisher
      ## M13b's published aggregate table. WRITE-ONLY FROM HERE: nothing in
      ## the daemon ever reads it back, and no daemon decision depends on
      ## it. It is published output living in a host-wide segment, and a
      ## decision that consulted it would be a decision that depends on
      ## memory outside the daemon's own address space — which the
      ## transport spec's §"Trust and the privilege boundary" forbids.
      ##
      ## Started AFTER the rendezvous directory exists, by
      ## ``startStatsPublisher``, because the table lives beside the socket.
      ## A daemon that cannot publish keeps serving: the socket is the
      ## answer of record and this only removes a round trip from it.
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
