import std/[options, sets, tables]

import runquota_admission
import runquota_core
import runquota_ipc
import runquota_observation_store
import runquota_persistence
import runquota_protocol
import runquota_stats_table/publisher
import ./owners
import ./cpu_shape
import ./capacity_metrics

export cpu_shape
export capacity_metrics

export owners

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

  SocketActivation* = object
    ## What `takeSocketActivation` read from systemd's `LISTEN_*` variables
    ## ([`sd_listen_fds(3)`](https://www.freedesktop.org/software/systemd/man/latest/sd_listen_fds.html)).
    ## The default value -- `requested` false -- is an ordinary start, which
    ## binds its own endpoint.
    requested*: bool
      ## `LISTEN_PID` named this process: the descriptors are addressed to
      ## it, so it must serve them or refuse, never bind a second socket.
    fd*: int
      ## The descriptor to serve (`SD_LISTEN_FDS_START`, 3) when `refusal`
      ## is empty.
    refusal*: string
      ## Non-empty when the hand-over is unusable (`LISTEN_FDS` other than
      ## 1); `serve` prints it and exits `endpointRefusedExitCode`.

  BudgetFlags* = object
    ## The budget the COMMAND LINE pinned. A reload re-reads the host file and
    ## changes everything else, but never these: a flag is the operator's
    ## statement for this launch (precedence 1 in
    ## `reprobuild-specs/RunQuota-Host-Configuration.md`), and a reload that
    ## let a file edit override it would make the flag mean "until someone
    ## edits the file".
    memoryBytes*: Option[Bytes]      ## `--memory-bytes`
    cpuSlots*: Option[MilliCpu]      ## `--cpu-milli`
    pools*: Table[string, uint32]    ## `--pool NAME=UNITS`
    machines*: bool
      ## `--machine` was given: the topology is the command line's, so the
      ## file's `[machine]` keys have nothing to size.
    cpuShareGroups*: HashSet[string] ## `--cpu-share-group ID=...`
    admissionMaxWaitMillis*: Option[int64]
      ## `--admission-max-wait-millis`, over the file's `admission.max-wait`.

  DaemonConfig* = object
    endpoint*: Endpoint
    daemonId*: uint64
    daemonPath*: string
      ## This daemon's own executable, as `getAppFilename()` reported it at
      ## start. ONE runquotad SERVES THE WHOLE HOST, so the daemon that
      ## refuses a lease is routinely another checkout's, started with
      ## another budget -- and the remedy differs by whose it is (lower the
      ## request, or raise the budget of a daemon somebody else started).
      ## Every denial names it, because establishing it otherwise means
      ## finding the process and reading its command line. Empty when the
      ## platform would not report it.
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
      ## Naming a path does not turn capture on: whether rows are written
      ## is ``captureOn`` (and ``writeStatsDisabled``) below.
    captureOn*: bool
      ## Whether the ``capture`` measurement is on: execution rows,
      ## extension rows and self-report intake. Off by default (the
      ## ``capture`` row of ``runquota_core/measurement``'s registry): it
      ## costs more than the measurement budget allows. Turned on by
      ## ``runquotad --measurement capture=on``.
    writeStatsDisabled*: bool
      ## The operator's explicit off switch (``runquotad --no-write-stats``,
      ## the older spelling of ``capture=off``). It wins over ``captureOn``,
      ## and it is kept apart from it so that "off, deliberately" stays
      ## distinguishable from "off by default" in the startup report and so
      ## that an explicit ``capture=on`` against it can be refused as a
      ## contradiction rather than settled by argument order.
    observationQueueCapacity*: int
    hostIdentityFilePath*: string
      ## Where this machine's ``host_id`` is kept. Empty means the
      ## per-user default; tests point it at a scratch directory so they
      ## neither read nor write the operator's real machine identity.
    profileUncontendedPct*: float64
      ## The most of the host's CPU that everything other than an execution
      ## may have used over its run for the run to count as uncontended and
      ## be folded into its command's learned duration and CPU shape
      ## (``cpu_shape``). `runquotad --profile-uncontended-pct`.
    ambientSampleIntervalMillis*: int
      ## The FIXED cadence of ambient load sampling (M11), independent of
      ## execution boundaries. Zero or negative turns ambient sampling off
      ## while leaving execution capture on.
    metricsTextfilePath*: string
      ## Where the capacity figures are written in Prometheus text format
      ## (`runquotad --metrics-textfile`), for node-exporter's textfile
      ## collector. Empty, the default, writes nothing: it is the
      ## `metrics-export` measurement, and the only thing that turns it on.
    metricsIntervalMillis*: int
      ## How often that file is rewritten; `DefaultMetricsIntervalMillis`.
    retentionPolicy*: RetentionPolicy
      ## The bounds the scheduled retention pass enforces. M15 built them
      ## and nothing called them; this is what a daemon carries so that a
      ## store which captures is also BOUNDED by default, whether capture
      ## was turned on by a switch or, once it passes the overhead gate,
      ## by default: a store that grows forever is a promise nobody meant
      ## to make.
    retentionSweepIntervalMillis*: int
      ## Cadence of that pass. Zero or negative turns retention off while
      ## leaving capture on — the same shape as
      ## ``ambientSampleIntervalMillis`` above and for the same reason:
      ## "off" has to be a state an operator can name, in the config, in
      ## the startup report, and in a test.
    hostConfigPath*: string
      ## The host budget file this daemon reads at start and on every
      ## `ReloadHostConfig`: `hostConfigPath` from
      ## `runquota_daemon/host_config` unless `runquotad --host-config PATH`
      ## named another (a test's private file). Empty: no file, and a reload
      ## re-applies the built-in defaults and the flags.
    builtinMemoryBytes*: Bytes
    builtinCpuSlots*: MilliCpu
      ## The defaults the file is laid over -- 75% of physical memory and
      ## one core per logical processor -- kept so a reload can recompute the
      ## budget from the bottom (defaults, then file, then flags) rather than
      ## from whatever the last file left. Zero means "not recorded" (a
      ## config built by hand), and the current value stands in for it.
    budgetFlags*: BudgetFlags
    hostFilePools*: Table[string, uint32]
      ## The `[pools]` of the host file in force (the last one that parsed).
      ## Kept apart from `namedPoolCaps` so a pool declaration can recompute
      ## the caps without re-reading the file.
    declaredPools*: Table[string, uint32]
      ## The pools open sessions declared (`DeclarePools`), each at the
      ## smallest capacity any of them declared. The bottom layer of the pool
      ## caps: the file and the flags override it (`recomputePoolCaps`).
    hostConfigSource*: string
      ## The file the budget in force was read from; empty when none existed.
      ## Set at start by `runquotad` and by every reload.
    retentionMaxDeferredSweeps*: int
      ## How many consecutive sweeps a live lease may defer before one
      ## runs anyway. A prune competes for the disk the work runs on, so
      ## waiting for a quiet tick is right; waiting for one forever is not
      ## a bound, and a machine that is never idle is the one whose store
      ## grows fastest.
    exitWithParentPid*: int
      ## The parent this daemon stops with, as `takeExitWithParentRequest`
      ## requested by `RUNQUOTA_EXIT_WITH_PARENT=1`, optionally recorded
      ## before spawning with `RUNQUOTA_EXIT_WITH_PARENT_PID`; 0 (the
      ## default, and always on Windows) means no watch. `serve` starts the
      ## watch once SIGTERM is armed, and the watch stops the daemon through
      ## that same orderly SIGTERM path. See `runquota_daemon/parent_watch`.
    idleExitAfterSeconds*: int
      ## `runquotad --idle-exit-after N`: begin the orderly shutdown once no
      ## client connection has been open for N seconds, counted from start-up
      ## or from the moment the last connection closed. 0, the default, never
      ## idles out -- the provisioned service's behaviour, unchanged. The
      ## decision is the retirement decision, made by the daemon itself
      ## (reprobuild-pm `spec/RunQuota-Host-Configuration.md`, "The shared
      ## per-user daemon (POSIX)", "The idle period").
    socketActivation*: SocketActivation
      ## Set by `runquotad` from `takeSocketActivation` at start. See
      ## `runquota_daemon/socket_activation`.
    admissionMaxWaitMillis*: int64
      ## The starvation bound in force (`runquotad
      ## --admission-max-wait-millis`, else the host file's
      ## `admission.max-wait`, else `DefaultMaxWaitMillis`, 120 s;
      ## `resolveBudget` decides): a queued request that has waited this long
      ## without being granted goes before the requests the keys after
      ## `starvation` would rank, and capacity is held for it. Zero or
      ## negative turns the bound off, and so does an order without
      ## `starvation`.
    admissionOrder*: seq[AdmissionKey]
      ## The admission order in force: the host file's `admission.order`, or
      ## `DefaultAdmissionOrder`. Never empty once `resolveBudget` ran.
    shareBetweenUsers*: ShareBetweenUsers
      ## The host file's `admission.share-between-users`, default `drf`.

  SessionRow* = object
    id*: SessionId
    name*: string
    version*: string
    supervisorProcessId*: uint64
    supervisorUserId*: uint64
    peer*: PeerIdentity
    groupKey*: string
      ## The key of the session group this session joined
      ## (`sessionGroupKey`). Empty for a row built without one, which
      ## admission treats as an interactive group of its own.

  SessionGroupRow* = object
    ## A session group: every session that named it (or, for the per-user
    ## `interactive` group, every session of one owner that named none).
    ##
    ## A GROUP BELONGS TO ITS OWNER. The key is the owner, read from peer
    ## credentials, together with the name, so two users who use the same
    ## name have two groups, and only the owner's connections may change a
    ## group's attributes.
    ##
    ## IT LIVES AS LONG AS A SESSION NAMES IT. The attributes and the counters
    ## are forgotten when the last such session closes.
    key*: string
    name*: string
    ownerKnown*: bool
    ownerUid*: int64
      ## Meaningful when `ownerKnown`; a transport that reports no credentials
      ## leaves the owner unknown, and nobody may then update the group.
    priority*: SessionPriority
    cacheDeadlinePresent*: bool
    cacheDeadlineUnixMillis*: uint64
    sessions*: int
      ## Open sessions that name the group.
    busySince*: uint64
      ## One past the queue position of the request with which the group last
      ## became busy (had a lease queued or holding capacity after having
      ## none); its place in arrival order. Zero until its first request. It
      ## is not cleared when the group goes idle: the group's next request
      ## finds it idle and takes a new place then.
    grantsTotal*: uint64
      ## Leases granted to the group since it was created.
    grantedCpuMilliMillis*: uint64
      ## The CPU the group's leases held, integrated over the time they held
      ## it (milli-CPU x milliseconds), for leases that have released it.
      ## Reservations, not measurement: the daemon does not watch process
      ## trees.
    waitsTotalMillis*: uint64
    waitMaxMillis*: uint64
      ## How long the group's granted leases had been queued: the total and
      ## the longest single wait.
    heldCpuMilli*: uint64
      ## What the group's granted leases reserve now, kept current by every
      ## grant and release (`applyLeaseResourceUsage`).
    recentCpu*: float64
    recentCpuAtMillis*: int64
      ## The group's decayed past CPU (`runquota_admission.decayedCpu`,
      ## milli-CPU x seconds) as of the monotonic time `recentCpuAtMillis`.
      ## Brought forward whenever `heldCpuMilli` changes, and on reading, so
      ## the held CPU is constant over every interval it integrates. What
      ## `fair-share` orders by, with what the group holds now.

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
    childStartStamp*: uint64
      ## The child's start stamp, read by the daemon itself when
      ## ``LeaseRunning`` named ``childProcessId``; 0 when it could not be
      ## read. The pid alone stops naming the child the moment the child
      ## exits, so this is what lets the lost-lease reaper tell the child
      ## from a later process that inherited its pid
      ## (``runquota_daemon/child_identity``).
    processGroupId*: uint64
    cleanupRegistered*: bool
    finish*: LeaseFinish
    finishDiagnostic*: Diagnostic
    peakMemoryBytes*: uint64
    processCount*: uint32
    majorPageFaults*: uint64
    pressureEvents*: uint32
    queueDiagnostic*: Diagnostic
    groupKey*: string
      ## The session group of the session that made the request, copied at
      ## request time: a lease whose supervisor was lost outlives its session
      ## and still holds capacity on that group's behalf.
    queuedAtMillis*: int64
    grantedAtMillis*: int64
      ## Monotonic milliseconds (`monoMillis`) at which the request was queued
      ## and granted; what the starvation bound and the group counters are
      ## measured from.
    startedAtUnixMillis*: int64
      ## When the client reported the lease as starting. Observation only:
      ## the daemon does not watch the process tree, so this is the lease
      ## window it was told about, not a measurement it took.
    parentLeaseId*: uint64
      ## 0 for a host lease. Otherwise this is a SUB-LEASE, granted from the
      ## named parent's width and memory and never from the host ledger
      ## (`RequestSubLease`): it is invisible to host admission -- no machine
      ## or share-group usage, no active-lease count, no group held CPU, no
      ## fairness load, no benchmark or pressure gate -- because the parent
      ## already passed all of them for the whole tree it supervises.
    subCpuMinMilli*: uint32
      ## A queued sub-lease's minimum width. Its `resources.cpu` holds the
      ## preferred width until the grant, which narrows it to what fits.
    subHeldCpuMilli*: uint32
    subHeldMemoryBytes*: uint64
      ## What this lease's granted sub-leases hold of it. Maintained on the
      ## parent by `applyLeaseResourceUsage`, the one place every grant and
      ## every release passes, for the reason the host aggregates are.
    cpuMinMilli*: uint32
    cpuPreferredMilli*: uint32
      ## A host lease's CPU range (negotiated widths). A request with one CPU
      ## value has both equal to it. While QUEUED, `resources.cpu` holds the
      ## preferred width; the grant narrows it to the widest value that fits.
    resizable*: bool
      ## The client follows a moving width (a jobserver): the daemon may
      ## widen the lease above its grant while nothing waits, and narrow it
      ## back towards the grant when something does.
    grantCpuMilli*: uint32
      ## The width the lease was granted. Narrowing never goes below it: the
      ## grant is what admission promised, and only width added by widening
      ## is lent.
    cpuTargetMilli*: uint32
    cpuCurrentMilli*: uint32
      ## The width the jobserver should follow, and the width it last said it
      ## holds. A granted resizable lease charges max(target, current) --
      ## that is its `resources.cpu` -- so a narrowing frees slots only as
      ## tokens come back, and a widening is charged at once.
    growWantedMilli*: uint32
      ## The width the lease grows towards: its preferred width, or less
      ## when its client asked for less (`LeaseGrowRequest`).
    growOrder*: uint64
      ## Arrival order among growth candidates: taken from the queue-order
      ## counter when the lease last fell below the width it grows towards.
    chargeSinceMillis*: int64
      ## Monotonic milliseconds since which `resources.cpu` has been the
      ## charge; the group's CPU-time counter integrates each charge over
      ## its own interval.

  ConnectionContext* = object
    supervisorProcessId*: uint64
    supervisorUserId*: uint64
    peer*: PeerIdentity
    sessionIds*: seq[SessionId]

  HelloPeer* = object
    ## What the daemon learned about a connection's peer BEFORE taking the
    ## daemon-wide lock: its credentials, and the display name of the
    ## principal they name. Resolving a name can block -- ``getpwuid_r`` may
    ## ask NSS/LDAP, ``LookupAccountSidW`` a domain controller -- so it is
    ## done on the connection's own worker and handed in, never done under
    ## the lock every lease decision waits behind.
    identity*: PeerIdentity
    ownerName*: Option[string]

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
    imageDigest*: string
      ## `imageDigestOf` this daemon's own executable, taken on a thread
      ## `serve` starts before an installer can rename the file aside, and
      ## filled in by the first `RetireDaemon` request. Compared
      ## with the digest a `RetireDaemon` request names. Empty when the image
      ## could not be read, which proves nothing either way.
    nextSessionId*: uint64
    nextLeaseId*: uint64
    nextQueueOrder*: uint64
    totalGranted*: uint64
    totalFinished*: uint64
    sessions*: Table[uint64, SessionRow]
    sessionGroups*: Table[string, SessionGroupRow]
      ## Open session groups by `sessionGroupKey`.
    leases*: Table[uint64, LeaseRow]
    estimates*: Table[string, LearnedEstimateRow]
    cpuEstimates*: Table[string, CpuShapeEstimate]
      ## The learned CPU estimate per estimate key: totals, uncontended
      ## durations per width and the CPU shape (``cpu_shape``). In memory
      ## only, like the hot-path half of ``estimates``.
    estimateStore*: EstimateStore
    observationStore*: ObservationStore
    owners*: OwnerLedger
      ## Every owner this daemon has seen or found in its store, with the
      ## principal each id was derived from (``owners.nim``). What lets a
      ## Hello whose id another principal already holds be refused, and a
      ## known user connect without rewriting its ``users`` row unless the
      ## name changed.
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
    connectionsFailed*: uint64
      ## Connections that never became a session: one that ended before its
      ## ``Hello`` completed — the peer vanished, or its opening frame was
      ## refused — or one that got past ``Hello`` and then raised instead of
      ## completing. The daemon survives each — it is host-wide, and a single
      ## client must not be able to stop it — so this is the only place such
      ## a failure is visible. A non-zero value with a healthy lease count is
      ## usually peers that connect and vanish; a value tracking the lease
      ## count is a real defect in the connection path.
      ##
      ## THE PRE-HELLO HALF IS WHY THIS IS NOT "raised". A peer that connects
      ## and drops provokes no exception anywhere, so a counter fed only from
      ## ``except`` arms read zero through exactly the population the sentence
      ## above describes.
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
    lostLeasesReaped*: uint64
    sessionPools*: Table[uint64, Table[string, uint32]]
      ## Session id to the pools that session declared (`DeclarePools`).
      ## Removed with the session, orderly or not; `declaredPools` in the
      ## config is recomputed from what remains.
    pendingDenials*: Table[uint64, seq[LeaseDecision]]
      ## Session id to the denials a reload decided for its queued leases,
      ## delivered on that session's next `GrantNext`. The leases themselves
      ## have already left the table (`reloadHostConfig`).
    hostConfigReloads*: uint64
      ## `ReloadHostConfig` requests that changed the budget in force (or
      ## re-applied an unchanged one): the file parsed.
    hostConfigReloadsRefused*: uint64
      ## Reloads refused because the file did not parse or could not be read.
      ## The budget in force is then the previous one, unchanged.
      ## ``supervisor_lost`` leases released because their child process is
      ## provably gone.
      ##
      ## A lease whose supervisor died keeps its resources accounted, on
      ## purpose: the child it launched may still be running, and dropping
      ## the reservation would let the daemon hand the same CPU and memory
      ## to someone else while the orphan still holds them. What that
      ## reasoning does not supply is an END. Nothing ever asked whether the
      ## orphan had exited, so the reservation outlived the process by the
      ## daemon's whole lifetime and the capacity was gone until a restart.
      ##
      ## The failure that follows is silent and total: requests that no
      ## longer fit are QUEUED rather than denied, so a host with enough
      ## leaked leases stops admitting work while reporting itself healthy.
      ## Non-zero here is the evidence that the end exists.
    activeLeaseCount*: uint32
    activeBenchmarkCount*: uint32
    machineUsage*: Table[string, MachineUsage]
    cpuShareGroupUsage*: Table[string, uint32]
    namedPoolUsage*: Table[string, uint32]
    pressureFileCache*: PressureFileCache
    capacity*: CapacityLedger
      ## The per-host and per-session-group counters capacity tools read
      ## (`capacity_metrics`): CPU used by finished leases, grants and
      ## waits. Kept whether or not the text file is written, because
      ## `runquota status --json` carries them too.
