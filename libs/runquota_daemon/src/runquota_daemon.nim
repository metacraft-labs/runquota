import std/[algorithm, cpuinfo, locks, options, os, strutils, tables, times]

when defined(posix):
  # `getuid` for the host-state-directory ownership check below.
  import std/posix

import runquota_daemon/types as daemonTypes
import runquota_codec
import runquota_core
import runquota_host
import runquota_host_macos
when defined(windows):
  # Windows: pull in the Windows host backend so configuredPressureSample()
  # below can route to GlobalMemoryStatusEx instead of the macOS stub (which
  # always returns "unavailable" off-macOS).
  import runquota_host_windows
import runquota_ipc
import runquota_observation_store
import runquota_persistence
import runquota_protocol
import runquota_stats_table/publisher as statsPublisherLib

export daemonTypes

const libraryName* = "runquota_daemon"

proc libraryInfo*(): daemonTypes.LibraryInfo =
  daemonTypes.LibraryInfo(name: libraryName)

proc defaultDaemonConfig*(endpoint = defaultEndpoint()): DaemonConfig =
  DaemonConfig(
    endpoint: endpoint,
    daemonId: uint64(getCurrentProcessId()),
    cpuSlots: milliCpu(max(1, countProcessors()) * 1000),
    memoryBytes: bytes(16'u64 * 1024'u64 * 1024'u64 * 1024'u64),
    ioSlots: 1'u32,
    machines: initTable[string, MachineCapacity](),
    cpuShareGroups: initTable[string, CpuShareGroup](),
    namedPoolCaps: initTable[string, uint32](),
    version: "0.1.0",
    pressureSource: pressureSourceHost,
    pressureFile: "",
    pressureRequired: false,
    memoryPressureHeavyBytes: bytes(512'u64 * 1024'u64 * 1024'u64),
    estimateDbPath: "",
    estimateQueueCapacity: 128,
    observationDbPath: "",
    writeStatsDisabled: false,
    observationQueueCapacity: 1024,
    hostIdentityFilePath: "",
    ambientSampleIntervalMillis: defaultAmbientCadenceMillis
  )

proc machineCapacity*(id: string; cpuSlots: MilliCpu; memoryBytes: Bytes;
                      ioSlots: uint32; cpuShareGroup = ""): MachineCapacity =
  MachineCapacity(
    id: if id.len == 0: DefaultMachineId else: id,
    cpuSlots: cpuSlots,
    memoryBytes: memoryBytes,
    ioSlots: ioSlots,
    cpuShareGroup: if cpuShareGroup.len == 0: (if id.len ==
        0: DefaultMachineId else: id) else: cpuShareGroup
  )

proc cpuShareGroup*(id: string; cpuSlots: MilliCpu): CpuShareGroup =
  CpuShareGroup(
    id: if id.len == 0: DefaultMachineId else: id,
    cpuSlots: cpuSlots
  )

proc normalizeTopology(config: var DaemonConfig) =
  if config.machines.len == 0:
    config.machines[DefaultMachineId] = machineCapacity(
      DefaultMachineId,
      config.cpuSlots,
      config.memoryBytes,
      config.ioSlots,
      DefaultMachineId
    )
  var machineIds: seq[string] = @[]
  for id in config.machines.keys:
    machineIds.add(id)
  for id in machineIds:
    var machine = config.machines[id]
    if machine.id.len == 0:
      machine.id = id
    if machine.cpuShareGroup.len == 0:
      machine.cpuShareGroup = machine.id
    config.machines[id] = machine
    if not config.cpuShareGroups.hasKey(machine.cpuShareGroup):
      config.cpuShareGroups[machine.cpuShareGroup] = cpuShareGroup(
        machine.cpuShareGroup,
        machine.cpuSlots
      )
  if config.machines.hasKey(DefaultMachineId):
    let local = config.machines[DefaultMachineId]
    config.cpuSlots = local.cpuSlots
    config.memoryBytes = local.memoryBytes
    config.ioSlots = local.ioSlots

proc localCpuShareGroup(config: DaemonConfig): string =
  ## The share group of the machine this daemon *is*, for the hardware
  ## profile. ``cpu_share_group`` is not detectable — it is RunQuota's own
  ## machine-model grouping, and carrying it into the profile is what lets
  ## a merged database tell a pinned VM from a co-tenant guest.
  if config.machines.hasKey(DefaultMachineId):
    let group = config.machines[DefaultMachineId].cpuShareGroup
    if group.len > 0:
      return group
  DefaultMachineId

proc hostStateDirectoryRefusal(config: DaemonConfig): string =
  ## M13d: the host-wide state directory's OWNER AND MODE, verified on
  ## every daemon start.
  ##
  ## Its EXISTENCE was already checked, in `resolveHostIdentity`, and
  ## existence alone is the same half-check M13c closed for the rendezvous
  ## and left open here: a `/var/db/runquota` owned by the wrong uid is
  ## accepted for as long as the daemon can still write in it. Exploiting
  ## that needs root, since `/var/db` is root-owned `0755` -- but the
  ## realistic failure needs nobody at all. An operator runs `sudo mkdir
  ## -p` and forgets the `chown`, or leaves the directory `0777`, and then
  ## any local user can replace `host-id` and thereby fork this machine's
  ## history into two or merge it with another machine's. Both are
  ## invisible at the point of use, which is why they are refused rather
  ## than logged.
  ##
  ## HERE RATHER THAN IN `identity.nim`: `runquota_daemon` already imports
  ## both libraries, so this needs no new library edge and no new export,
  ## and "verified on every daemon start" is a statement about the daemon.
  ##
  ## The required mode is `0755` for the DEFAULT host-wide directory --
  ## what `nix/host-state.nix`, the NixOS module and the by-hand runbook
  ## all write -- and, for a directory an operator named explicitly with
  ## `--host-identity-file`, only the invariant: owned by this daemon and
  ## never group- or other-writable. The exact mode of a path an operator
  ## chose is their decision; who can replace what lives in it is not.
  when defined(posix):
    let identityPath =
      if config.hostIdentityFilePath.len > 0: config.hostIdentityFilePath
      else: defaultHostIdentityFile()
    let directory = identityPath.parentDir
    if directory.len == 0:
      return ""
    let trust = inspectPath(directory, wantDirectory = true,
      requiredMode =
        (if directory == hostWideStateDir: hostStateDirectoryMode else: -1),
      expectedOwnerUid = int64(getuid()),
      label = "host state directory")
    # `trustMissing` is NOT refused here: `resolveHostIdentity` already
    # reports an unprovisioned host, with the command that provisions it,
    # and two reports for one condition would be one report too many.
    if trust.reason in {trustOk, trustMissing}: "" else: trust.message
  else:
    ""

proc estimateTableKey(scope, commandStatsId: string): string =
  scope & "\0" & commandStatsId

proc sessionScope(session: SessionRow): string =
  "session:" & session.name

proc effectiveObservationDbPath*(config: DaemonConfig): string =
  ## Where this daemon's observation store lives, given its configuration.
  ##
  ## CAPTURE IS ON WITHOUT ANY FLAG. The specification's §"Capture Is
  ## Enabled By Default" gives the reason and it is not a preference:
  ## the store's primary reader needs the history to ALREADY EXIST at the
  ## moment a question is asked, and nobody can retroactively enable
  ## capture for the week that would have answered it. An opt-in store is
  ## empty exactly when it is first needed.
  ##
  ## Three states, and the order matters:
  ##
  ## 1. ``writeStatsDisabled`` — the operator said no. An empty path, which
  ##    every downstream component already reads as "capture off". It wins
  ##    over an explicit path, so ``--observation-db X --no-write-stats``
  ##    is off rather than ambiguous.
  ## 2. an explicit ``observationDbPath`` — the operator named a file.
  ## 3. otherwise the host default, beside the host identity file.
  if config.writeStatsDisabled:
    return ""
  if config.observationDbPath.len > 0:
    return config.observationDbPath
  observationDbBeside(config.hostIdentityFilePath)

proc statsTablePath*(config: DaemonConfig): string =
  ## Where this daemon publishes its aggregate table, or "" for not at all.
  ##
  ## ``RUNQUOTA_STATS_TABLE=off`` turns the fast path off entirely, and that
  ## switch is not only a test affordance: "can be dropped, resized, or
  ## skipped in a degraded mode without any correctness argument at all" is
  ## the property the table is supposed to have, and an option nobody can
  ## exercise is a claim rather than a property.
  if getEnv("RUNQUOTA_STATS_TABLE") == "off":
    return ""
  let overridePath = getEnv("RUNQUOTA_STATS_TABLE_PATH")
  if overridePath.len > 0:
    return overridePath
  defaultStatsTablePath(config.endpoint)

proc startStatsPublisher*(daemon: var RunQuotaDaemon) =
  ## Called AFTER the rendezvous directory exists, because the table lives
  ## in it. Failure is not an error: the socket answers everything the table
  ## can, so a daemon that cannot publish serves exactly as before, one
  ## round trip slower on the admission read.
  ##
  ## ``segmentHostWide``, and it is the one segment that is: the table is
  ## written only by `runquotad`, so a page no client can write cannot be
  ## used by one user to perturb another. ``requiredSegmentMode`` is asked
  ## rather than ``0640`` written out, so a blanket per-segment ``0600``
  ## cannot silently make the host-wide table unreadable by every user but
  ## one.
  let path = statsTablePath(daemon.config)
  if path.len == 0:
    return
  daemon.statsPublisher = createStatsPublisher(path, DefaultStatsSlotCount,
    requiredSegmentMode(segmentHostWide))

proc initDaemon*(config: DaemonConfig): RunQuotaDaemon =
  var effectiveConfig = config
  effectiveConfig.normalizeTopology()
  # Resolved ONCE, here, and written back into the config the daemon keeps.
  # Every later reader — the store, the writer thread, the sampler, the
  # startup report — then sees one path rather than re-deriving it, which
  # is what stops "the default" from meaning two different files in two
  # places.
  effectiveConfig.observationDbPath = effectiveObservationDbPath(config)
  result = RunQuotaDaemon(
    config: effectiveConfig,
    state: dsStarting,
    nextSessionId: 1'u64,
    nextLeaseId: 1'u64,
    nextQueueOrder: 1'u64,
    lastGrantedSessionId: 0'u64,
    totalGranted: 0'u64,
    totalFinished: 0'u64,
    sessions: initTable[uint64, SessionRow](),
    leases: initTable[uint64, LeaseRow](),
    estimates: initTable[string, LearnedEstimateRow](),
    estimateStore: startEstimateStore(effectiveConfig.estimateDbPath,
        effectiveConfig.estimateQueueCapacity),
    activeLeaseCount: 0'u32,
    activeBenchmarkCount: 0'u32,
    machineUsage: initTable[string, MachineUsage](),
    cpuShareGroupUsage: initTable[string, uint32](),
    namedPoolUsage: initTable[string, uint32](),
    pressureFileCache: PressureFileCache(
      path: "", mtimeUnix: 0, sizeBytes: 0, raw: ""
    ),
    observationStore: openObservationStore(effectiveConfig.observationDbPath),
    observationHostId: "",
    observationProfileId: "",
    observationIdentityReport: "",
    observationBootId: opaqueId("boot-"),
    observationRunIds: initTable[uint64, string](),
    observationsAccepted: 0'u64,
    observationsRejected: 0'u64,
    deferredBatchesAccepted: 0'u64,
    deferredBatchesRefused: 0'u64,
    deferredExecutionsRecorded: 0'u64,
    selfReportsReaped: 0'u64
  )
  for row in loadLearnedEstimates(effectiveConfig.estimateDbPath):
    result.estimates[estimateTableKey(row.scope, row.commandStatsId)] = row
  # OS-4: a store that will not open is reported and then ignored. The
  # daemon keeps serving leases; only capture is lost.
  if result.observationStore.captureEnabled:
    # Identity first, and from the machine rather than from the database:
    # `host_id` is not derived from the hostname, the address, or anything
    # else that two machines can share (M10, OS-6).
    #
    # The directory is verified BEFORE the identity is read out of it. An
    # id minted into, or read from, a directory somebody else can write is
    # an id somebody else chose.
    let stateRefusal = hostStateDirectoryRefusal(effectiveConfig)
    let identity =
      if stateRefusal.len > 0:
        HostIdentity(hostId: "", persisted: false, report: stateRefusal,
          path:
            if effectiveConfig.hostIdentityFilePath.len > 0:
              effectiveConfig.hostIdentityFilePath
            else:
              defaultHostIdentityFile())
      else:
        resolveHostIdentity(effectiveConfig.hostIdentityFilePath)
    result.observationHostId = identity.hostId
    if not identity.persisted:
      # OS-6. AN IDENTITY THAT CANNOT BE PERSISTED IS A REFUSAL. The daemon
      # says which path and why, and records nothing; `resolveHostIdentity`
      # has already declined to invent an id, so `observationHostId` is
      # empty and `observationCaptureEnabled` is false for the process's
      # whole life.
      #
      # CAPTURE OFF RATHER THAN REFUSING TO START, and the reason is what
      # RunQuota is FOR. Admission is the mission: a daemon that cannot
      # record history can still keep a machine from thrashing itself to
      # death, and refusing to admit anything because a statistics
      # directory is missing would let an advisory subsystem take out the
      # host's whole build capacity. It is also the response OS-4 already
      # gives to the neighbouring failure -- a store that will not open
      # degrades to no capture and the daemon carries on -- and two
      # different answers to two indistinguishable operator-visible
      # failures would be the surprising design, not this one.
      result.observationIdentityReport =
        "runquota observation store " & result.observationStore.path &
          ": capture disabled, no host identity; " & identity.report
    elif result.observationStore.ensureHostRow(identity.hostId,
        result.observationBootId):
      # The disk that matters to a build's duration is the one the work
      # happens on, and the store lives beside it.
      #
      # DETECTION HAPPENS HERE AND NOWHERE ELSE. M10 left "the profile is
      # detected once at startup and never again" for M11's sampler to
      # revisit, and M11's answer is that it stays that way ON PURPOSE.
      # Re-detecting on the sampler's cadence would buy almost nothing --
      # adding RAM, swapping a disk, or upgrading the kernel all restart
      # the machine and therefore this daemon -- and it would cost a
      # `diskutil` process spawn per tick plus a standing invitation to
      # the one residual M10 recorded: `swap_bytes` is quantized, not
      # stable, so a macOS host whose dynamic pager crosses a GiB boundary
      # forks its hardware profile, and periodic re-detection is precisely
      # what would make that happen repeatedly. What this leaves uncovered
      # is a daemon that outlives a hardware change without a restart --
      # a live-migrated guest, in practice.
      let hardware = detectHardwareProfile(
        result.observationStore.path.parentDir,
        localCpuShareGroup(effectiveConfig))
      result.observationProfileId =
        result.observationStore.ensureHostProfile(identity.hostId, hardware)
      startObservationWriter(result.observationStore.path,
        effectiveConfig.observationQueueCapacity)
      # Ambient load sampling (M11, OS-6). Host-wide totals only: the
      # daemon is a lease authority and does not inspect client process
      # trees, so `self_*` comes from what clients report about themselves
      # and `foreign_*` is the residual.
      var ambientReport = "ambient sampling off"
      if effectiveConfig.ambientSampleIntervalMillis > 0:
        startAmbientSampler(result.observationStore.path, identity.hostId,
          effectiveConfig.ambientSampleIntervalMillis)
        if ambientSamplerActive():
          ambientReport = "ambient sampling every " &
            $effectiveConfig.ambientSampleIntervalMillis &
            "ms while a lease is live"
      result.observationIdentityReport =
        "runquota observation store " & result.observationStore.path &
          ": host " & identity.hostId & "; hardware profile " &
          (if result.observationProfileId.len > 0: result.observationProfileId
            else: "unavailable") & "; " & ambientReport & "; " & identity.report
    else:
      result.observationHostId = ""
      result.observationIdentityReport =
        "runquota observation store " & result.observationStore.path &
          ": the host row could not be written; executions are not recorded"
  elif effectiveConfig.writeStatsDisabled:
    # NAMED AS A DECISION, not as an accident. Capture being off because
    # the operator asked and capture being off because the store would not
    # open are the same state to every consumer and completely different
    # facts to the person reading the log, so the two must not print the
    # same line. `openObservationStore("")` says "no path configured",
    # which is true and useless here.
    result.observationStore.report =
      "runquota observation store: capture disabled by --no-write-stats; " &
        "no observations are recorded and no store file is opened"
    result.observationIdentityReport =
      "runquota observation store: host identity and hardware profile not " &
        "recorded; capture disabled by --no-write-stats"
  else:
    result.observationIdentityReport =
      "runquota observation store " & effectiveConfig.observationDbPath &
        ": host identity and hardware profile not recorded; capture disabled"

proc countLeases(daemon: RunQuotaDaemon; state: LeaseLifecycleState): uint32 =
  for lease in daemon.leases.values:
    if lease.state == state:
      inc result

proc isResourceActive(state: LeaseLifecycleState): bool =
  state in {leaseStateGranted, leaseStateStarting, leaseStateRunning, leaseStateSupervisorLost}

proc countActiveLeases(daemon: RunQuotaDaemon): uint32 =
  daemon.activeLeaseCount

proc status*(daemon: RunQuotaDaemon): DaemonStatusMessage =
  DaemonStatusMessage(
    activeSessions: uint32(daemon.sessions.len),
    activeLeases: daemon.countActiveLeases(),
    queuedLeases: daemon.countLeases(leaseStateQueued),
    supervisorLostLeases: daemon.countLeases(leaseStateSupervisorLost),
    finishedLeases: daemon.countLeases(leaseStateFinished),
    totalGranted: daemon.totalGranted,
    totalFinished: daemon.totalFinished
  )

proc sendResponse(connection: var LocalConnection; kind: RqspMessageKind;
                  requestId: uint64; payload: string) =
  connection.sendFrame(encodeFrame(kind, FrameFlagResponse, requestId, payload))

proc sendError(connection: var LocalConnection; requestId: uint64;
    diagnostic: Diagnostic) =
  let payload = encodeProtocolError(ProtocolErrorMessage(
      diagnostic: diagnostic))
  connection.sendFrame(encodeFrame(rqError, FrameFlagResponse or FrameFlagError,
      requestId, payload))

proc receiveFrameOrDiagnostic(connection: var LocalConnection;
    frame: var RqspFrame): bool =
  var frameDiagnostic = okDiagnostic()
  if connection.receiveFrame(frame, frameDiagnostic):
    return true
  if frameDiagnostic.code != diagOk and frame.header.requestId != 0'u64:
    connection.sendError(frame.header.requestId, frameDiagnostic)
  false

proc ioSlots(resources: ResourceVector; cap: uint32): uint32 =
  case resources.ioClass
  of ioNormal:
    0'u32
  of ioHeavy:
    1'u32
  of ioExclusive:
    cap

proc priorityRank(priority: PriorityClass): int =
  case priority
  of priorityInteractive: 0
  of priorityNormal: 1
  of priorityBackground: 2

proc resolvedMachineId(resources: ResourceVector): string =
  if resources.machineId.len == 0:
    DefaultMachineId
  else:
    resources.machineId

proc machineFor(daemon: RunQuotaDaemon; machineId: string;
                machine: var MachineCapacity): bool =
  let id = if machineId.len == 0: DefaultMachineId else: machineId
  if not daemon.config.machines.hasKey(id):
    return false
  machine = daemon.config.machines[id]
  true

proc cpuShareGroupFor(daemon: RunQuotaDaemon;
    machine: MachineCapacity): CpuShareGroup =
  let groupId =
    if machine.cpuShareGroup.len == 0:
      machine.id
    else:
      machine.cpuShareGroup
  if daemon.config.cpuShareGroups.hasKey(groupId):
    daemon.config.cpuShareGroups[groupId]
  else:
    cpuShareGroup(groupId, machine.cpuSlots)

proc applyLeaseResourceUsage(daemon: var RunQuotaDaemon; lease: LeaseRow;
                             add: bool) =
  # Maintains live aggregates so fitsNow/countActiveLeases/hasActiveBenchmark
  # avoid a full leases-table walk per admission decision. Skips silently when
  # the lease targets an unknown machine: possible() rejects such leases before
  # they enter the queue, so the resources field is harmless here.
  var machine: MachineCapacity
  if not daemon.machineFor(lease.resources.resolvedMachineId(), machine):
    return
  let groupId =
    if machine.cpuShareGroup.len == 0: machine.id else: machine.cpuShareGroup
  let cpuDelta = lease.resources.cpu.value
  let memDelta = lease.resources.memory.value
  let ioDelta = lease.resources.ioSlots(machine.ioSlots)
  var usage = daemon.machineUsage.getOrDefault(machine.id, MachineUsage())
  if add:
    usage.cpu += cpuDelta
    usage.memory += memDelta
    usage.ioSlots += ioDelta
    daemon.machineUsage[machine.id] = usage
    daemon.cpuShareGroupUsage[groupId] =
      daemon.cpuShareGroupUsage.getOrDefault(groupId, 0'u32) + cpuDelta
    for demand in lease.resources.namedPools:
      daemon.namedPoolUsage[demand.name] =
        daemon.namedPoolUsage.getOrDefault(demand.name, 0'u32) + demand.units
    inc daemon.activeLeaseCount
    if lease.purpose == leasePurposeBenchmark:
      inc daemon.activeBenchmarkCount
  else:
    usage.cpu = (if usage.cpu >= cpuDelta: usage.cpu - cpuDelta else: 0'u32)
    usage.memory = (if usage.memory >= memDelta: usage.memory -
        memDelta else: 0'u64)
    usage.ioSlots = (if usage.ioSlots >= ioDelta: usage.ioSlots -
        ioDelta else: 0'u32)
    daemon.machineUsage[machine.id] = usage
    let prevGroup = daemon.cpuShareGroupUsage.getOrDefault(groupId, 0'u32)
    daemon.cpuShareGroupUsage[groupId] =
      if prevGroup >= cpuDelta: prevGroup - cpuDelta else: 0'u32
    for demand in lease.resources.namedPools:
      let prevPool = daemon.namedPoolUsage.getOrDefault(demand.name, 0'u32)
      daemon.namedPoolUsage[demand.name] =
        if prevPool >= demand.units: prevPool - demand.units else: 0'u32
    if daemon.activeLeaseCount > 0'u32:
      dec daemon.activeLeaseCount
    if lease.purpose == leasePurposeBenchmark and daemon.activeBenchmarkCount > 0'u32:
      dec daemon.activeBenchmarkCount
  # AMBIENT SAMPLING IS GATED ON THIS. The sampler writes no row over an
  # interval in which no lease was live, so the count has to be published
  # from the one place that maintains it -- here, where every add and every
  # release passes -- rather than sampled from the lease table on a
  # cadence, which would be the same walk this aggregate exists to avoid.
  setAmbientLiveLeaseCount(int(daemon.activeLeaseCount))

proc transitionLeaseState(daemon: var RunQuotaDaemon; lease: var LeaseRow;
                          newState: LeaseLifecycleState) =
  let oldActive = lease.state.isResourceActive
  let newActive = newState.isResourceActive
  lease.state = newState
  if not oldActive and newActive:
    daemon.applyLeaseResourceUsage(lease, true)
  elif oldActive and not newActive:
    daemon.applyLeaseResourceUsage(lease, false)

proc removeLeaseFromTable(daemon: var RunQuotaDaemon; id: uint64) =
  if not daemon.leases.hasKey(id):
    return
  let lease = daemon.leases[id]
  if lease.state.isResourceActive:
    daemon.applyLeaseResourceUsage(lease, false)
  daemon.leases.del(id)

proc possible(daemon: RunQuotaDaemon; resources: ResourceVector;
    reason: var string): bool =
  var machine: MachineCapacity
  if not daemon.machineFor(resources.resolvedMachineId(), machine):
    reason = "lease request targets unknown machine: " &
        resources.resolvedMachineId()
    return false
  let group = daemon.cpuShareGroupFor(machine)
  if resources.cpu.value == 0 or resources.memory.value == 0:
    reason = "lease request must reserve CPU and memory"
    return false
  if resources.cpu.value > machine.cpuSlots.value:
    reason = "lease request exceeds machine CPU budget: " & machine.id
    return false
  if resources.cpu.value > group.cpuSlots.value:
    reason = "lease request exceeds shared CPU budget: " & group.id
    return false
  if resources.memory.value > machine.memoryBytes.value:
    reason = "lease request exceeds machine memory budget: " & machine.id
    return false
  if resources.ioSlots(machine.ioSlots) > machine.ioSlots:
    reason = "lease request exceeds machine IO budget: " & machine.id
    return false
  for demand in resources.namedPools:
    if demand.units == 0:
      reason = "named-pool demand must be non-zero"
      return false
    let cap = daemon.config.namedPoolCaps.getOrDefault(demand.name, 0'u32)
    if cap == 0 or demand.units > cap:
      reason = "lease request exceeds named-pool budget: " & demand.name
      return false
  true

proc readDeterministicPressureRaw(daemon: var RunQuotaDaemon;
                                  raw: var string): bool =
  # Cache the deterministic pressure file by (path, mtime, size) so the
  # admission hot path can skip readFile() when the file is unchanged.
  # getFileInfo is much cheaper than readFile and avoids touching disk pages.
  let path = daemon.config.pressureFile
  if path.len == 0 or not fileExists(path):
    daemon.pressureFileCache = PressureFileCache(
      path: "", mtimeUnix: 0, sizeBytes: 0, raw: ""
    )
    return false
  var info: FileInfo
  try:
    info = getFileInfo(path)
  except OSError:
    return false
  let mtimeUnix = info.lastWriteTime.toUnix()
  let sizeBytes = info.size
  if daemon.pressureFileCache.path == path and
      daemon.pressureFileCache.mtimeUnix == mtimeUnix and
      daemon.pressureFileCache.sizeBytes == sizeBytes:
    raw = daemon.pressureFileCache.raw
    return true
  let contents =
    try:
      readFile(path).strip().toLowerAscii()
    except IOError, OSError:
      return false
  daemon.pressureFileCache = PressureFileCache(
    path: path, mtimeUnix: mtimeUnix, sizeBytes: sizeBytes, raw: contents
  )
  raw = contents
  true

proc configuredPressureSample(daemon: var RunQuotaDaemon): HostMemoryPressureSample =
  case daemon.config.pressureSource
  of pressureSourceHost:
    when defined(windows):
      # Windows: route host pressure through GlobalMemoryStatusEx-backed sampler.
      sampleWindowsMemoryPressure(daemon.config.pressureRequired)
    else:
      sampleMacosMemoryPressure(daemon.config.pressureRequired)
  of pressureSourceUnavailable:
    unavailablePressureSample("configured-unavailable",
        daemon.config.pressureRequired)
  of pressureSourceDeterministicFile:
    var raw = ""
    if not daemon.readDeterministicPressureRaw(raw):
      return unavailablePressureSample(
        "deterministic-file",
        daemon.config.pressureRequired,
        "pressure file is missing"
      )
    case raw
    of "low", "normal", "ok":
      lowPressureSample("deterministic-file", daemon.config.pressureRequired)
    of "warning", "warn":
      HostMemoryPressureSample(
        level: pressureWarning,
        available: true,
        required: daemon.config.pressureRequired,
        source: "deterministic-file",
        diagnostic: diagnostic(diagDenied, "host memory pressure is warning", "deterministic pressure file")
      )
    of "critical", "crit":
      HostMemoryPressureSample(
        level: pressureCritical,
        available: true,
        required: daemon.config.pressureRequired,
        source: "deterministic-file",
        diagnostic: diagnostic(diagDenied, "host memory pressure is critical", "deterministic pressure file")
      )
    of "unavailable", "missing":
      unavailablePressureSample("deterministic-file",
          daemon.config.pressureRequired, "deterministic unavailable")
    else:
      unavailablePressureSample("deterministic-file",
          daemon.config.pressureRequired, "unknown level: " & raw)

proc configuredPressureAvailable(daemon: var RunQuotaDaemon): bool =
  case daemon.config.pressureSource
  of pressureSourceHost:
    when defined(macosx) or defined(windows):
      true
    else:
      false
  of pressureSourceUnavailable:
    false
  of pressureSourceDeterministicFile:
    var raw = ""
    if not daemon.readDeterministicPressureRaw(raw):
      return false
    raw in ["low", "normal", "ok", "warning", "warn", "critical", "crit"]

proc pressureAllows(daemon: var RunQuotaDaemon; resources: ResourceVector;
                    diagOut: var Diagnostic): bool =
  if resources.memory.value < daemon.config.memoryPressureHeavyBytes.value:
    diagOut = okDiagnostic()
    return true
  let sample = daemon.configuredPressureSample()
  if not sample.available:
    if daemon.config.pressureRequired:
      diagOut = diagnostic(
        diagDenied,
        "waiting on host memory pressure",
        "required memory-pressure signal unavailable from " & sample.source &
        ": " &
          sample.diagnostic.detail
      )
      return false
    diagOut = okDiagnostic()
    return true
  case sample.level
  of pressureWarning, pressureCritical:
    diagOut = diagnostic(
      diagDenied,
      "waiting on host memory pressure",
      "pressure=" & $sample.level & " source=" & sample.source
    )
    false
  else:
    diagOut = okDiagnostic()
    true

proc fitsNow(daemon: RunQuotaDaemon; resources: ResourceVector): bool =
  var machine: MachineCapacity
  if not daemon.machineFor(resources.resolvedMachineId(), machine):
    return false
  let group = daemon.cpuShareGroupFor(machine)
  let usage = daemon.machineUsage.getOrDefault(machine.id, MachineUsage())
  let usedSharedCpu = daemon.cpuShareGroupUsage.getOrDefault(group.id, 0'u32)
  if usage.cpu + resources.cpu.value > machine.cpuSlots.value:
    return false
  if usedSharedCpu + resources.cpu.value > group.cpuSlots.value:
    return false
  if usage.memory + resources.memory.value > machine.memoryBytes.value:
    return false
  if usage.ioSlots + resources.ioSlots(machine.ioSlots) > machine.ioSlots:
    return false
  for demand in resources.namedPools:
    let cap = daemon.config.namedPoolCaps.getOrDefault(demand.name, 0'u32)
    let used = daemon.namedPoolUsage.getOrDefault(demand.name, 0'u32)
    if used + demand.units > cap:
      return false
  true

proc earliestQueuedBenchmarkId(daemon: RunQuotaDaemon): uint64 =
  var bestPriority = high(int)
  var bestOrder = high(uint64)
  for id, lease in daemon.leases.pairs:
    if lease.state == leaseStateQueued and lease.purpose == leasePurposeBenchmark:
      let rank = priorityRank(lease.priority)
      if rank < bestPriority or (rank == bestPriority and lease.queueOrder < bestOrder):
        result = id
        bestPriority = rank
        bestOrder = lease.queueOrder

proc hasActiveBenchmark(daemon: RunQuotaDaemon): bool =
  daemon.activeBenchmarkCount > 0'u32

proc benchmarkGateAllows(daemon: RunQuotaDaemon; lease: LeaseRow): bool =
  let benchmarkId = daemon.earliestQueuedBenchmarkId()
  if lease.purpose == leasePurposeBenchmark:
    return benchmarkId == lease.id.value and daemon.countActiveLeases() == 0'u32
  if daemon.hasActiveBenchmark():
    return false
  benchmarkId == 0'u64

proc waitingDiagnostic(daemon: var RunQuotaDaemon;
    lease: LeaseRow): Diagnostic =
  if not daemon.benchmarkGateAllows(lease):
    if lease.purpose == leasePurposeBenchmark:
      return diagnostic(
        diagDenied,
        "waiting for benchmark isolation",
        "benchmark candidate waits for all active leases to finish"
      )
    return diagnostic(
      diagDenied,
      "waiting for benchmark isolation",
      "benchmark lease is queued or active"
    )
  var pressureDiagnostic: Diagnostic
  if not daemon.pressureAllows(lease.resources, pressureDiagnostic):
    return pressureDiagnostic
  diagnostic(diagDenied, "waiting for resource budget", "candidate does not fit current CPU, memory, IO, or pool budget")

proc stateName(state: LeaseLifecycleState): string =
  case state
  of leaseStateQueued: "queued"
  of leaseStateGranted: "granted"
  of leaseStateStarting: "starting"
  of leaseStateRunning: "running"
  of leaseStateFinished: "finished"
  of leaseStateSupervisorLost: "supervisor_lost"

proc purposeName(purpose: LeasePurpose): string =
  case purpose
  of leasePurposeWork: "work"
  of leasePurposeBenchmark: "benchmark"

proc leaseDecision(lease: LeaseRow; kind: LeaseDecisionKind;
                   diagnostic = okDiagnostic()): LeaseDecision =
  LeaseDecision(
    clientCandidateId: lease.clientCandidateId,
    leaseId: lease.id,
    kind: kind,
    resources: lease.resources,
    diagnostic: if kind == leaseDecisionQueued: lease.queueDiagnostic else: diagnostic
  )

proc sessionsJson(daemon: RunQuotaDaemon): string =
  var ids: seq[uint64] = @[]
  for id in daemon.sessions.keys:
    ids.add(id)
  ids.sort()
  result = "{\"sessions\":["
  for i, id in ids:
    if i > 0:
      result.add(",")
    let session = daemon.sessions[id]
    result.add("{" &
      "\"id\":" & $session.id.value & "," &
      "\"name\":" & jsonEscape(session.name) & "," &
      "\"version\":" & jsonEscape(session.version) &
    "}")
  result.add("]}")

proc leasesJson(daemon: RunQuotaDaemon; onlySession = sessionId(0)): string =
  var ids: seq[uint64] = @[]
  for id, lease in daemon.leases.pairs:
    if onlySession.value == 0 or lease.sessionId.value == onlySession.value:
      ids.add(id)
  ids.sort()
  result = "{\"leases\":["
  for i, id in ids:
    if i > 0:
      result.add(",")
    let lease = daemon.leases[id]
    result.add("{" &
      "\"id\":" & $lease.id.value & "," &
      "\"session_id\":" & $lease.sessionId.value & "," &
      "\"candidate_id\":" & $lease.clientCandidateId & "," &
      "\"label\":" & jsonEscape(lease.label) & "," &
      "\"command_stats_id\":" & jsonEscape(lease.commandStatsId) & "," &
      "\"state\":" & jsonEscape(lease.state.stateName) & "," &
      "\"purpose\":" & jsonEscape(lease.purpose.purposeName) & "," &
      "\"resources\":" & inspectionResourceJson(lease.resources) & "," &
      "\"peak_memory_bytes\":" & $lease.peakMemoryBytes & "," &
      "\"process_count\":" & $lease.processCount & "," &
      "\"diagnostic\":{\"code\":" & jsonEscape($lease.queueDiagnostic.code) &
        ",\"message\":" & jsonEscape(lease.queueDiagnostic.message) &
        ",\"detail\":" & jsonEscape(lease.queueDiagnostic.detail) & "}" &
    "}")
  result.add("]}")

proc topologyJson(daemon: RunQuotaDaemon): string =
  var machineIds: seq[string] = @[]
  for id in daemon.config.machines.keys:
    machineIds.add(id)
  machineIds.sort()
  var groupIds: seq[string] = @[]
  for id in daemon.config.cpuShareGroups.keys:
    groupIds.add(id)
  groupIds.sort()
  result = "{\"machines\":["
  for i, id in machineIds:
    if i > 0:
      result.add(",")
    let machine = daemon.config.machines[id]
    result.add("{" &
      "\"id\":" & jsonEscape(machine.id) & "," &
      "\"cpu_milli\":" & $machine.cpuSlots.value & "," &
      "\"memory_bytes\":" & $machine.memoryBytes.value & "," &
      "\"io_slots\":" & $machine.ioSlots & "," &
      "\"cpu_share_group\":" & jsonEscape(machine.cpuShareGroup) &
    "}")
  result.add("],\"cpu_share_groups\":[")
  for i, id in groupIds:
    if i > 0:
      result.add(",")
    let group = daemon.config.cpuShareGroups[id]
    result.add("{" &
      "\"id\":" & jsonEscape(group.id) & "," &
      "\"cpu_milli\":" & $group.cpuSlots.value &
    "}")
  result.add("]}")

proc estimatesJson(daemon: RunQuotaDaemon): string =
  var keys: seq[string] = @[]
  for key in daemon.estimates.keys:
    keys.add(key)
  keys.sort()
  result = "{\"estimates\":["
  for i, key in keys:
    if i > 0:
      result.add(",")
    let row = daemon.estimates[key]
    result.add("{" &
      "\"scope\":" & jsonEscape(row.scope) & "," &
      "\"command_stats_id\":" & jsonEscape(row.commandStatsId) & "," &
      "\"conservative_memory_bytes\":" & $row.conservativeMemoryBytes & "," &
      "\"recent_peak_memory_bytes\":" & $row.recentPeakMemoryBytes & "," &
      "\"sample_count\":" & $row.sampleCount &
    "}")
  result.add("]}")

proc pressureJson(daemon: var RunQuotaDaemon): string =
  let sample = daemon.configuredPressureSample()
  "{\"pressure\":{\"level\":" & jsonEscape($sample.level) & "," &
    "\"available\":" & $(sample.available) & "," &
    "\"required\":" & $(daemon.config.pressureRequired) & "," &
    "\"source\":" & jsonEscape(sample.source) & "," &
    "\"diagnostic\":" & jsonEscape(sample.diagnostic.message) & "}}"

proc observationCaptureEnabled(daemon: RunQuotaDaemon): bool =
  ## Capture is running IF AND ONLY IF both halves hold: a store that
  ## opened, and a host identity that persisted. An identity that could not
  ## be persisted is a refusal (M13c-fix), so rows would have no honest
  ## `host_id` to carry and OS-6 forbids writing them anyway.
  daemon.observationStore.captureEnabled and daemon.observationHostId.len > 0

proc observationsJson(daemon: RunQuotaDaemon): string =
  ## The write path's own honesty, readable from outside the daemon.
  ##
  ## ``rqLeaseObservation`` is one-way, so a client is never told that its
  ## report was refused — which leaves nowhere else for OS-2's "every
  ## dropped observation MUST be counted" to be satisfied on this path.
  ## ``rejected`` is that count. ``self_reports_reaped`` is the crash
  ## exit's, and it is here rather than inferred because "the leak is
  ## closed" and "the leak was never exercised" produce identical stores.
  ##
  ## ``self_cpu_pct``/``self_rss_bytes`` are the SUMS, reported beside the
  ## count because a count cannot distinguish "the report was refused" from
  ## "the report was applied and then replaced" — which is exactly what a
  ## partially-applied report would look like: same number of live reports,
  ## different figures in them.
  "{\"observations\":{" &
    "\"capture_enabled\":" & $(daemon.observationCaptureEnabled()) & "," &
    "\"store_path\":" & jsonEscape(daemon.observationStore.path) & "," &
    "\"write_stats_disabled\":" & $(daemon.config.writeStatsDisabled) & "," &
    "\"accepted\":" & $daemon.observationsAccepted & "," &
    "\"rejected\":" & $daemon.observationsRejected & "," &
    "\"live_self_reports\":" & $liveSelfReports().len & "," &
    "\"self_cpu_pct\":" & $sumSelfCpuPct(liveSelfReports()) & "," &
    "\"self_rss_bytes\":" & $sumSelfRssBytes(liveSelfReports()) & "," &
    "\"self_reports_reaped\":" & $daemon.selfReportsReaped & "," &
    "\"deferred_batches_accepted\":" & $daemon.deferredBatchesAccepted & "," &
    "\"deferred_batches_refused\":" & $daemon.deferredBatchesRefused & "," &
    "\"deferred_executions_recorded\":" &
      $daemon.deferredExecutionsRecorded & "," &
    "\"queued\":" & $observationsWritten() & "," &
    "\"dropped\":" & $observationsDropped() & "," &
    "\"write_failures\":" & $observationWriteFailures() &
  "}}"

# ---------------------------------------------------------------------------
# The read path (M13a). `runquotad` is the ONLY sanctioned reader of the
# observation store, so everything below is the whole of what a client can
# learn from it.
# ---------------------------------------------------------------------------

# The wire enums mirror the store's, and the mapping below assumes they do.
# Asserted rather than commented: an enum that gained a case on one side
# only would otherwise translate silently into the wrong one.
static:
  doAssert ord(high(StatsScopeWire)) == ord(high(StatsScope))
  doAssert ord(high(ProfileSpanWire)) == ord(high(ProfileSpan))
  doAssert ord(high(StatsKnowledgeWire)) == ord(high(StatsKnowledge))

proc toStore(scope: StatsScopeWire): StatsScope =
  StatsScope(ord(scope))

proc toStore(span: ProfileSpanWire): ProfileSpan =
  ProfileSpan(ord(span))

proc toWire(span: ProfileSpan): ProfileSpanWire =
  ProfileSpanWire(ord(span))

proc toWire(knowledge: StatsKnowledge): StatsKnowledgeWire =
  StatsKnowledgeWire(ord(knowledge))

proc toWire(profile: ProfileIdentity): ProfileIdentityWire =
  ProfileIdentityWire(
    hostId: profile.hostId,
    profileIdPresent: profile.profileId.isSome,
    profileId: if profile.profileId.isSome: profile.profileId.get else: "",
    profileHash: profile.profileHash,
    cpuModel: profile.cpuModel,
    logicalCores: uint64(max(0'i64, profile.logicalCores)))

proc nonNegative(value: int64): uint64 =
  uint64(max(0'i64, value))

proc statsOwnerUid(context: ConnectionContext): Option[int64] =
  ## FROM PEER CREDENTIALS, never from anything the caller declared.
  ## ``none`` when the transport cannot report them, and the caller below
  ## turns that into an EMPTY uid-scoped answer rather than a host-wide
  ## one: a scope-to-me query with nobody to scope to must not silently
  ## become a scope-to-everybody query.
  if context.peer.kind == peerIdentityUnavailable:
    none(int64)
  else:
    some(int64(context.peer.userId))

proc statsAnswer(daemon: var RunQuotaDaemon; context: ConnectionContext;
                 request: StatsQueryMessage): StatsResponseMessage =
  ## Answers one query over the recorded rows.
  ##
  ## THE DEFAULT PROFILE SPAN IS THIS HOST'S CURRENT PROFILE, and a wider
  ## one is honoured but never merged: the store layer returns one
  ## distribution per profile and nothing here folds them together.
  let span = request.span.toStore
  let profileId =
    if daemon.observationProfileId.len > 0:
      some(daemon.observationProfileId)
    else:
      none(string)
  # A query must see what the daemon has already recorded. The observation
  # queue is drained in the background, so without this a `repro stats`
  # immediately after a build would report the build's own executions as
  # missing -- indistinguishable, to the caller, from never having run.
  flushObservationWriter()

  result = StatsResponseMessage(
    subject: request.subject,
    statsKey: request.statsKey,
    knowledge: statsKnowledgeWireUnknown,
    scopeApplied: request.scope,
    spanApplied: span.toWire,
    ownerUidPresent: false,
    ownerUid: 0'u64,
    captureEnabled: daemon.observationCaptureEnabled(),
    distributions: @[],
    executions: @[],
    rankings: @[],
    extensionRows: @[],
    diagnostic: okDiagnostic()
  )

  case request.subject
  of statsSubjectDistribution:
    # DELIBERATELY NOT UID-SCOPED, and the response says so rather than
    # leaving the caller to assume either way. The cost of compiling a
    # translation unit is a property of the work and the hardware, not of
    # who ran it; scoping it per user would discard most of the history on
    # exactly the machines that have the most -- a CI server where a dozen
    # accounts build the same tree. `estimateFor` takes no uid at all, so
    # this cannot be got wrong by passing one.
    let answer = daemon.observationStore.estimateFor(
      request.statsKey, span, profileId)
    result.scopeApplied = statsScopeWireHost
    result.ownerUidPresent = false
    result.knowledge = answer.knowledge.toWire
    for entry in answer.distributions:
      result.distributions.add(ResourceDistributionWire(
        profile: entry.profile.toWire,
        knowledge: entry.knowledge.toWire,
        sampleCount: nonNegative(entry.sampleCount),
        durationMillisMin: nonNegative(entry.durationMillisMin),
        durationMillisP50: nonNegative(entry.durationMillisP50),
        durationMillisP90: nonNegative(entry.durationMillisP90),
        durationMillisMax: nonNegative(entry.durationMillisMax),
        peakRssBytesMax: nonNegative(entry.peakRssBytesMax)))
  of statsSubjectExecutions, statsSubjectRanking, statsSubjectExtensionRows:
    let owner = statsOwnerUid(context)
    let query = RowQuery(
      statsKey: request.statsKey,
      scope: request.scope.toStore,
      ownerUid: owner,
      span: span,
      profileId: profileId,
      limit: int(request.limit))
    if request.scope == statsScopeWireOwner and owner.isSome:
      result.ownerUidPresent = true
      result.ownerUid = uint64(owner.get)
    if request.subject == statsSubjectExtensionRows:
      # THE PAYLOAD PASSES THROUGH UNINTERPRETED (OS-5). The extension and
      # its columns are named by the CALLER; the daemon checks nothing
      # about what they mean, and the scope rules that decided which
      # executions are visible are the same ones applied above -- an
      # execution this caller may not see does not become visible because
      # a product attached a fact to it.
      var columns: seq[string] = @[]
      for name in request.extensionColumns:
        columns.add(name)
      for entry in daemon.observationStore.queryExtensionRows(
          query, request.extensionId, columns):
        result.extensionRows.add(ExtensionRowWire(
          hostId: entry.hostId,
          executionId: entry.executionId,
          statsKey: entry.statsKey,
          profile: entry.profile.toWire,
          ownerUidPresent: entry.ownerUid.isSome,
          ownerUid:
          if entry.ownerUid.isSome: uint64(entry.ownerUid.get) else: 0'u64,
          columns: entry.columns,
          values: entry.values))
      if result.extensionRows.len > 0:
        result.knowledge = statsKnowledgeWireKnown
    elif request.subject == statsSubjectExecutions:
      for entry in daemon.observationStore.queryExecutions(query):
        result.executions.add(ExecutionSummaryWire(
          executionId: entry.executionId,
          statsKey: entry.statsKey,
          profile: entry.profile.toWire,
          ownerUidPresent: entry.ownerUid.isSome,
          ownerUid:
          if entry.ownerUid.isSome: uint64(entry.ownerUid.get) else: 0'u64,
          startedAtUnixMillis: nonNegative(entry.startedAtUnixMillis),
          durationMillis: nonNegative(entry.durationMillis),
          peakRssBytes: nonNegative(entry.peakRssBytes),
          exitStatus: nonNegative(entry.exitStatus),
          termination: $entry.termination))
      if result.executions.len > 0:
        result.knowledge = statsKnowledgeWireKnown
    else:
      for entry in daemon.observationStore.queryRanking(query):
        result.rankings.add(KeyRankingWire(
          statsKey: entry.statsKey,
          profile: entry.profile.toWire,
          sampleCount: nonNegative(entry.sampleCount),
          totalDurationMillis: nonNegative(entry.totalDurationMillis),
          maxDurationMillis: nonNegative(entry.maxDurationMillis)))
      if result.rankings.len > 0:
        result.knowledge = statsKnowledgeWireKnown
    if request.scope == statsScopeWireOwner and owner.isNone:
      result.diagnostic = diagnostic(diagDenied,
        "the transport did not report peer credentials",
        "a uid-scoped query is answered empty rather than widened")

proc inspectionJson(daemon: var RunQuotaDaemon;
    request: InspectionRequestMessage): string =
  case request.subject
  of "sessions":
    daemon.sessionsJson()
  of "observations":
    daemon.observationsJson()
  of "leases":
    daemon.leasesJson()
  of "explain":
    daemon.leasesJson(request.sessionId)
  of "status":
    inspectionStatusJson(daemon.status())
  of "estimates":
    daemon.estimatesJson()
  of "pressure":
    daemon.pressureJson()
  of "topology":
    daemon.topologyJson()
  else:
    "{\"error\":\"unknown inspection subject\"}"

proc handleHello(daemon: var RunQuotaDaemon; connection: var LocalConnection;
                 context: var ConnectionContext; frame: RqspFrame): bool =
  if frame.header.messageKind != rqHello:
    connection.sendError(frame.header.requestId, diagnostic(diagProtocol,
        "client must send Hello first"))
    return false
  var hello: HelloMessage
  if not decodeHello(frame.payload, hello):
    connection.sendError(frame.header.requestId, diagnostic(diagProtocol,
        "invalid Hello payload"))
    return false
  let compatibility = compatible(hello)
  if not compatibility.compatible:
    connection.sendError(frame.header.requestId, compatibility.diagnostic)
    return false
  # A CLIENT MAY NOT NAME AN OWNER OTHER THAN ITSELF. The daemon is
  # host-wide, so `hello.userId` -- which the client writes -- would
  # otherwise be a way to attribute one user's executions, estimates and
  # reports to another. Peer credentials are the only acceptable source,
  # and where the kernel supplies them a Hello that disagrees is refused
  # rather than corrected: a client that declares somebody else's uid is
  # either broken or lying, and neither is a connection to keep serving.
  let peer = connection.peerIdentity()
  if peer.kind != peerIdentityUnavailable and hello.userId != peer.userId:
    connection.sendError(frame.header.requestId, diagnostic(diagDenied,
      "client declared uid " & $hello.userId &
        " but its peer credentials say uid " & $peer.userId,
      "owner_uid is recorded from peer credentials and MUST NOT be " &
        "declared by the client"))
    return false
  let platformName =
    when defined(macosx): "macos"
    elif defined(linux): "linux"
    elif defined(windows): "windows" # Windows: spec-canonical platform name.
    else: "posix"
  let transportName =
    when defined(windows): "named-pipe" # Windows: see RunQuota protocol spec.
    else: "unix-socket"
  let caps = defaultCapabilities(
    platformName,
    transportName,
    daemon.config.cpuSlots,
    daemon.config.memoryBytes
  )
  var effectiveCaps = caps
  effectiveCaps.hardMemoryLimitEnforced = false
  effectiveCaps.hardMemoryLimitMode = memoryLimitAdvisory
  effectiveCaps.memoryPressureAvailable = daemon.configuredPressureAvailable()
  effectiveCaps.memoryPressureRequired = daemon.config.pressureRequired
  let helloOk = HelloOkMessage(
    selectedProtocolMajor: compatibility.selectedMajor,
    selectedProtocolMinor: compatibility.selectedMinor,
    daemonId: daemon.config.daemonId,
    daemonVersion: daemon.config.version,
    capabilities: effectiveCaps,
    flow: defaultFlowControlLimits()
  )
  connection.sendResponse(rqHelloOk, frame.header.requestId, encodeHelloOk(helloOk))
  context.supervisorProcessId = hello.processId
  context.supervisorUserId = hello.userId
  context.peer = peer
  true

proc createQueuedLease(daemon: var RunQuotaDaemon; sessionId: SessionId;
                       clientCandidateId: uint64; label: string;
                       commandStatsId: string; resources: ResourceVector;
                       priority: PriorityClass;
                           purpose: LeasePurpose): LeaseRow =
  let session = daemon.sessions[sessionId.value]
  let id = leaseId(daemon.nextLeaseId)
  inc daemon.nextLeaseId
  let queueOrder = daemon.nextQueueOrder
  inc daemon.nextQueueOrder
  result = LeaseRow(
    id: id,
    sessionId: sessionId,
    label: label,
    commandStatsId: commandStatsId,
    clientCandidateId: clientCandidateId,
    resources: resources,
    priority: priority,
    purpose: purpose,
    queueOrder: queueOrder,
    delivered: false,
    state: leaseStateQueued,
    supervisorProcessId: session.supervisorProcessId,
    supervisorUserId: session.supervisorUserId,
    peer: session.peer,
    childProcessId: 0'u64,
    processGroupId: 0'u64,
    cleanupRegistered: false,
    finishOutcome: leaseFinishCancelled,
    finishDiagnostic: okDiagnostic(),
    peakMemoryBytes: 0'u64,
    processCount: 0'u32,
    majorPageFaults: 0'u64,
    pressureEvents: 0'u32,
    hardLimitOrOom: false,
    queueDiagnostic: okDiagnostic()
  )
  daemon.leases[id.value] = result

proc effectiveResources(daemon: RunQuotaDaemon; sessionId: SessionId;
                        commandStatsId: string; requested: ResourceVector;
                        estimate: ClientEstimate): ResourceVector =
  ## What admission actually reserves for a request.
  ##
  ## TWO BRANCHES, AND WHICH ONE FIRES IS DECIDED BY ONE FACT: whether the
  ## CLIENT supplied an estimate.
  ##
  ## * **It did.** The estimate is used UNMODIFIED. Not compared with the
  ##   daemon's learned table, not raised to it, not lowered to it, not
  ##   validated against it. RunQuota expresses no opinion about the cache
  ##   the client got it from — not its format, its key, its lifetime, or
  ##   its freshness — and second-guessing it here would be exactly the
  ##   validation the specification forbids. A client that under-declares
  ##   spends its OWN user's budget, which is the whole reason the trust is
  ##   affordable.
  ## * **It did not.** The daemon's learned estimate is the FALLBACK, and
  ##   this is the only branch it may be used on. It is a fallback when
  ##   none is supplied, never a check on one that is.
  ##
  ## The distinction is carried by ``ClientEstimate.supplied`` rather than
  ## by a zero sentinel, because zero is a legitimate estimate and because
  ## "none was supplied" has to be a statable fact for the rule above to
  ## be a rule at all.
  result = requested
  if estimate.supplied:
    result.memory = bytes(estimate.memoryBytes)
    return
  if commandStatsId.len == 0 or not daemon.sessions.hasKey(sessionId.value):
    return
  let scope = daemon.sessions[sessionId.value].sessionScope()
  let key = estimateTableKey(scope, commandStatsId)
  if daemon.estimates.hasKey(key):
    let learned = daemon.estimates[key].conservativeMemoryBytes
    if learned > result.memory.value:
      result.memory = bytes(learned)

proc publishAggregate(daemon: var RunQuotaDaemon; statsKey: string) =
  ## Publish the CURRENT aggregate for one stats key into the segment, as
  ## the daemon folds in the run that just finished.
  ##
  ## THE PUBLISHED FIGURE IS THE ONE THE SOCKET ANSWERS WITH, deliberately
  ## and to the byte: ``estimateFor`` is the same call ``statsAnswer``
  ## makes for ``statsSubjectDistribution``, over the same rows, for the
  ## same profile. That equality is what makes the table a CACHE — a miss
  ## costs a round trip and changes no number — and it is what
  ## ``t_stats_table_cache_control.nim`` measures with the table emptied.
  ## Publishing some other, better figure here would be the moment the
  ## table quietly became a second source of truth.
  ##
  ## NOTHING IS READ BACK. The publisher writes; the daemon's own decisions
  ## are taken from ``daemon.estimates``, its private learned table, exactly
  ## as before this milestone.
  if not daemon.statsPublisher.available: return
  if statsKey.len == 0: return
  if not daemon.observationCaptureEnabled: return
  let profileId =
    if daemon.observationProfileId.len > 0:
      some(daemon.observationProfileId)
    else:
      none(string)
  # The row that has just been captured is still in the writer's queue, and
  # an aggregate published without it would be one run stale from the moment
  # it was written. This is the same flush `statsAnswer` performs before
  # answering, for the same reason.
  flushObservationWriter()
  let answer = daemon.observationStore.estimateFor(statsKey, spanSingleProfile,
    profileId)
  var payload = PublishedEstimate(
    statsKey: statsKey,
    knowledge: statsTableUnknown,
    memoryBytes: 0'u64,
    recentPeakBytes: 0'u64,
    sampleCount: 0'u64,
    updatedUnixMillis: nowUnixMillis())
  for entry in answer.distributions:
    if entry.knowledge == statsKnown:
      payload.knowledge = statsTableKnown
      payload.memoryBytes = uint64(max(0'i64, entry.peakRssBytesMax))
      payload.recentPeakBytes = payload.memoryBytes
      payload.sampleCount = uint64(max(0'i64, entry.sampleCount))
      break
  discard daemon.statsPublisher.publishEstimate(statsKey, payload)

proc updateEstimateFromFinish(daemon: var RunQuotaDaemon; lease: LeaseRow;
                              finish: LeaseFinishedMessage) =
  if lease.commandStatsId.len == 0 or finish.peakMemoryBytes == 0:
    return
  if not daemon.sessions.hasKey(lease.sessionId.value):
    return
  let scope = daemon.sessions[lease.sessionId.value].sessionScope()
  let key = estimateTableKey(scope, lease.commandStatsId)
  let observed = finish.peakMemoryBytes
  var conservative =
    if finish.outcome == leaseFinishResourceLimit or finish.hardLimitOrOom:
      max(observed, lease.resources.memory.value) * 2'u64
    else:
      max(observed, (observed * 125'u64) div 100'u64)
  var sampleCount = 1'u32
  if daemon.estimates.hasKey(key):
    let current = daemon.estimates[key]
    sampleCount = current.sampleCount + 1'u32
    if conservative < current.conservativeMemoryBytes:
      conservative = current.conservativeMemoryBytes
  let row = LearnedEstimateRow(
    scope: scope,
    commandStatsId: lease.commandStatsId,
    conservativeMemoryBytes: conservative,
    recentPeakMemoryBytes: observed,
    sampleCount: sampleCount,
    lastOutcome: uint32(ord(finish.outcome)),
    updatedUnixMillis: nowUnixMillis()
  )
  daemon.estimates[key] = row
  discard enqueueEstimateWrite(daemon.estimateStore, row)

proc openObservationRun(daemon: var RunQuotaDaemon; session: SessionRow) =
  ## One ``runs`` row per registered session. The row is written once, at
  ## registration, and never updated: ``finished_at`` and ``exit_status``
  ## stay NULL until the protocol carries client-declared run boundaries
  ## (M13). NULL says "not declared"; a zero would have claimed a
  ## measurement nobody made.
  if not daemon.observationCaptureEnabled:
    return
  let runId = opaqueId("run-")
  daemon.observationRunIds[session.id.value] = runId
  discard enqueueRunRow(RunRow(
    runId: runId,
    hostId: daemon.observationHostId,
    tool: session.name,
    toolVersion: session.version,
    invocationKind: "lease-session",
    startedAtUnixMillis: unixMillisNow(),
    finishedAtUnixMillis: none(int64),
    exitStatus: none(int64),
    workspaceId: none(string),
    profile: none(string),
    gitCommit: none(string),
    gitBranch: none(string),
    captureCompleteness: ccComplete,
    droppedObservations: 0
  ))

proc selfReportExecutionKey(id: LeaseId): string =
  ## The live-set key for one lease's in-flight figures.
  "lease-" & $id.value

proc selfReportOwnerKey(id: SessionId): string =
  ## The owner every one of a session's reports carries, so the daemon's
  ## existing reclamation path can drop them all when the client behind
  ## that session goes away without ending them.
  "session-" & $id.value

proc applyLeaseObservation(daemon: var RunQuotaDaemon;
                           context: ConnectionContext;
                           msg: LeaseObservationMessage): bool =
  ## Folds one in-flight client report into ambient attribution, or
  ## refuses it. Returns whether it was accepted.
  ##
  ## NOTHING IS APPLIED UNTIL EVERY CHECK HAS PASSED. The order below is
  ## checks first, single mutation last, and it is not stylistic: a
  ## half-applied report is a row that describes no moment — the exact
  ## defect M11 spent a rewrite removing from the sampler — and "reject
  ## the rest of the message" is no help once the CPU figure is already in
  ## the live set.
  ##
  ## THE OWNERSHIP CHECK IS THE ONE THAT MATTERS. One host-wide daemon
  ## holds every user's leases, so a report naming a lease the sending
  ## session does not own would let any local participant deflate another
  ## user's ``foreign_*`` — silently, since the arithmetic stays
  ## self-consistent and the clamp hides the overshoot. The session must
  ## exist, must be one THIS CONNECTION registered, and must own the lease.
  if not daemon.sessions.hasKey(msg.sessionId.value):
    return false
  var ownsSession = false
  for id in context.sessionIds:
    if id.value == msg.sessionId.value:
      ownsSession = true
      break
  if not ownsSession:
    return false
  if not daemon.leases.hasKey(msg.leaseId.value):
    return false
  let lease = daemon.leases[msg.leaseId.value]
  if lease.sessionId.value != msg.sessionId.value:
    return false
  # A figure for an execution that is not running describes nothing that is
  # consuming the machine now, and `self_*` is a sum over CONCURRENTLY LIVE
  # executions.
  if lease.state notin {leaseStateGranted, leaseStateStarting,
      leaseStateRunning}:
    return false
  if leaseObservationRefusal(msg, unixMillisNow()).len > 0:
    return false
  reportSelfExecution(
    selfReportExecutionKey(msg.leaseId),
    observedCpuPct(msg.cpuMilliPct),
    int64(min(msg.rssBytes, uint64(high(int64)))),
    selfReportOwnerKey(msg.sessionId))
  true

proc endLeaseSelfReport(daemon: var RunQuotaDaemon; id: LeaseId) =
  ## The ordinary exit: this lease is over, so its figures stop counting
  ## towards ``self_*``. Leaving them in would grow ``self`` without bound
  ## and drive ``foreign`` to the clamp.
  endSelfReportedExecution(selfReportExecutionKey(id))

proc reapSessionSelfReports(daemon: var RunQuotaDaemon; id: SessionId) =
  ## The crash exit, taken on behalf of a client that cannot take it.
  daemon.selfReportsReaped +=
    uint64(endSelfReportsForOwner(selfReportOwnerKey(id)))

proc observationTermination(finish: LeaseFinishedMessage): Termination =
  ## The protocol's finish outcome mapped onto the specification's
  ## termination set. Provisional: the outcome enum was designed for
  ## admission accounting, not for failure forensics, and M13 is where the
  ## client reports termination directly.
  if finish.hardLimitOrOom or finish.outcome == leaseFinishResourceLimit:
    return tOomKilled
  if finish.signal != 0'u32 or finish.outcome == leaseFinishCrashed:
    return tSignalled
  case finish.outcome
  of leaseFinishCancelled, leaseFinishLaunchFailed: tRefused
  else: tExited

proc captureObservation(daemon: var RunQuotaDaemon; lease: LeaseRow;
                        finish: LeaseFinishedMessage) =
  ## Appends one immutable execution row. In-memory only: the enqueue takes
  ## an uncontended lock and returns, and a background thread does the IO
  ## (OS-1). A dropped row is counted, never an error to the client.
  if not daemon.observationCaptureEnabled:
    return
  if not daemon.observationRunIds.hasKey(lease.sessionId.value):
    return
  let finishedAt = unixMillisNow()
  let startedAt =
    if lease.startedAtUnixMillis > 0: lease.startedAtUnixMillis else: finishedAt
  discard enqueueExecutionRow(ExecutionRow(
    executionId: opaqueId("exec-"),
    hostId: daemon.observationHostId,
    # The profile current when this ran (OS-6). NULL only when detection
    # could not establish one: a wrong profile id would be worse than an
    # absent one, because an aggregate would then be reported against
    # hardware that was never measured.
    hostProfileId:
      if daemon.observationProfileId.len > 0:
        some(daemon.observationProfileId)
      else:
        none(string),
    runId: daemon.observationRunIds[lease.sessionId.value],
    commandStatsId: lease.commandStatsId,
    leaseId: some(int64(lease.id.value)),
    startedAtUnixMillis: startedAt,
    finishedAtUnixMillis: finishedAt,
    durationMillis: max(0'i64, finishedAt - startedAt),
    exitStatus: int64(finish.exitCode),
    termination: observationTermination(finish),
    attempt: 1,
    retryOf: none(string),
    peakRssBytes: int64(finish.peakMemoryBytes),
    cpuUserMillis: none(int64),
    cpuSysMillis: none(int64),
    maxProcesses: int64(finish.processCount),
    majorPageFaults: int64(finish.majorPageFaults),
    ioReadBytes: none(int64),
    ioWriteBytes: none(int64),
    captureCompleteness: ccComplete,
    droppedObservations: 0,
    # FROM PEER CREDENTIALS, never from the client. `lease.peer` was filled
    # in by `getpeereid`/`SO_PEERCRED` on the accepted connection;
    # `supervisorUserId` beside it is whatever the client put in its Hello
    # and is NOT usable here. One host-wide daemon holds every user's rows,
    # so a client-declared owner would let any participant write rows
    # attributed to another user -- the exact failure the per-user boundary
    # exists to prevent.
    #
    # NULL, not 0, when the transport cannot report credentials: 0 is root.
    ownerUid:
      if lease.peer.kind == peerIdentityUnavailable:
        none(int64)
      else:
        some(int64(lease.peer.userId))
  ))

proc deferredTermination(record: DeferredExecutionRecord): Termination =
  ## Same mapping ``observationTermination`` applies to a lease finish, on
  ## the same enum, so a standalone row and an admitted row describe a
  ## crash with the same word.
  if record.outcome == leaseFinishResourceLimit:
    return tOomKilled
  if record.signal != 0'u32 or record.outcome == leaseFinishCrashed:
    return tSignalled
  case record.outcome
  of leaseFinishCancelled, leaseFinishLaunchFailed: tRefused
  else: tExited

proc captureDeferredBatch(daemon: var RunQuotaDaemon;
                          context: ConnectionContext;
                          msg: DeferredObservationsMessage): bool =
  ## Record one standalone client's exit flush: a ``runs`` row and one
  ## ``executions`` row per buffered record.
  ##
  ## THE COMPLETENESS VERDICT COMES FROM THE CLIENT AND IS WRITTEN AS SENT.
  ## The daemon has no way to know how much a client it never spoke to
  ## dropped, so it cannot form the verdict itself — but it can and does
  ## refuse the one verdict that cannot be true. ``ccComplete`` on a batch
  ## like this claims a window that nothing drained was nevertheless whole,
  ## and OS-2 exists to keep exactly that out of the store.
  ##
  ## THE ROWS CARRY NO ``lease_id``. Nothing admitted these executions;
  ## synthesising an id would put a lease in the store that no decision
  ## ever granted, and every later join through it would be a join onto an
  ## invention.
  if not daemon.observationCaptureEnabled:
    return false
  if deferredObservationsRefusal(msg).len > 0:
    return false
  let runId = opaqueId("run-")
  let now = unixMillisNow()
  discard enqueueRunRow(RunRow(
    runId: runId,
    hostId: daemon.observationHostId,
    tool: msg.tool,
    toolVersion: msg.toolVersion,
    invocationKind: msg.invocationKind,
    startedAtUnixMillis: now,
    finishedAtUnixMillis: some(now),
    exitStatus: none(int64),
    workspaceId: none(string),
    profile: none(string),
    gitCommit: none(string),
    gitBranch: none(string),
    captureCompleteness: msg.completeness,
    droppedObservations: int64(msg.droppedObservations)
  ))
  for record in msg.records:
    let startedAt = int64(record.startedAtUnixMillis)
    let finishedAt = int64(record.finishedAtUnixMillis)
    discard enqueueExecutionRow(ExecutionRow(
      executionId: opaqueId("exec-"),
      hostId: daemon.observationHostId,
      hostProfileId:
        if daemon.observationProfileId.len > 0:
          some(daemon.observationProfileId)
        else:
          none(string),
      runId: runId,
      commandStatsId: record.commandStatsId,
      leaseId: none(int64),
      startedAtUnixMillis: startedAt,
      finishedAtUnixMillis: finishedAt,
      durationMillis: max(0'i64, finishedAt - startedAt),
      exitStatus: int64(record.exitStatus),
      termination: deferredTermination(record),
      attempt: 1,
      retryOf: none(string),
      peakRssBytes: int64(record.peakRssBytes),
      cpuUserMillis: none(int64),
      cpuSysMillis: none(int64),
      maxProcesses: int64(record.processCount),
      majorPageFaults: int64(record.majorPageFaults),
      ioReadBytes: none(int64),
      ioWriteBytes: none(int64),
      # PER-ROW, not merely per-run. OS-2 wants the verdict at both
      # granularities, and a reader that filtered executions without
      # joining `runs` would otherwise see rows with nothing on them
      # saying the window they came from lost records.
      captureCompleteness: msg.completeness,
      droppedObservations: 0,
      # FROM PEER CREDENTIALS, exactly as on the admitted path. A
      # standalone client is no more entitled to name its own owner than
      # a leased one.
      ownerUid:
        if context.peer.kind == peerIdentityUnavailable:
          none(int64)
        else:
          some(int64(context.peer.userId))
    ))
  inc daemon.deferredExecutionsRecorded, uint64(msg.records.len)
  true

proc grantQueuedLease(daemon: var RunQuotaDaemon; id: uint64; delivered: bool) =
  var lease = daemon.leases[id]
  daemon.transitionLeaseState(lease, leaseStateGranted)
  lease.delivered = delivered
  daemon.leases[id] = lease
  daemon.lastGrantedSessionId = lease.sessionId.value
  inc daemon.totalGranted

proc queuedSessionOrder(daemon: RunQuotaDaemon): seq[uint64] =
  for lease in daemon.leases.values:
    if lease.state == leaseStateQueued and not result.contains(
        lease.sessionId.value):
      result.add(lease.sessionId.value)
  result.sort()
  if result.len <= 1 or daemon.lastGrantedSessionId == 0:
    return
  var cut = 0
  while cut < result.len and result[cut] <= daemon.lastGrantedSessionId:
    inc cut
  if cut > 0 and cut < result.len:
    result = result[cut .. ^1] & result[0 ..< cut]

proc tryPromoteQueued(daemon: var RunQuotaDaemon; maxDecisions: uint32 = high(
    uint32)): seq[uint64] =
  var promoted = 0'u32
  var madeProgress = true
  while madeProgress and promoted < maxDecisions:
    madeProgress = false
    let sessions = daemon.queuedSessionOrder()
    for sessionIdValue in sessions:
      if promoted >= maxDecisions:
        break
      var bestId = 0'u64
      var bestPriority = high(int)
      var bestOrder = high(uint64)
      for id, lease in daemon.leases.pairs:
        if lease.state == leaseStateQueued and lease.sessionId.value == sessionIdValue:
          let rank = priorityRank(lease.priority)
          if rank < bestPriority or (rank == bestPriority and lease.queueOrder < bestOrder):
            var pressureDiagnostic: Diagnostic
            if daemon.benchmarkGateAllows(lease) and
                daemon.pressureAllows(lease.resources, pressureDiagnostic) and
                daemon.fitsNow(lease.resources):
              bestId = id
              bestPriority = rank
              bestOrder = lease.queueOrder
      if bestId != 0'u64:
        daemon.grantQueuedLease(bestId, false)
        result.add(bestId)
        inc promoted
        madeProgress = true
  for id, lease in daemon.leases.pairs:
    if lease.state == leaseStateQueued:
      var updated = lease
      updated.queueDiagnostic = daemon.waitingDiagnostic(lease)
      daemon.leases[id] = updated

proc requireOwnedLease(daemon: RunQuotaDaemon; connection: var LocalConnection;
                       requestId: uint64; sessionId: SessionId;
                       id: LeaseId; lease: var LeaseRow): bool =
  if not daemon.leases.hasKey(id.value):
    connection.sendError(requestId, diagnostic(diagInvalidArgument,
        "unknown lease id"))
    return false
  lease = daemon.leases[id.value]
  if lease.sessionId.value != sessionId.value:
    connection.sendError(requestId, diagnostic(diagInvalidArgument,
        "lease belongs to another session"))
    return false
  true

proc releaseLease(daemon: var RunQuotaDaemon; id: LeaseId) =
  if daemon.leases.hasKey(id.value):
    daemon.removeLeaseFromTable(id.value)
    discard daemon.tryPromoteQueued(defaultFlowControlLimits().maxLeaseDecisionsPerBatch)

proc cleanupLostSession(daemon: var RunQuotaDaemon; sessionId: SessionId) =
  if not daemon.sessions.hasKey(sessionId.value):
    return
  var deleteLeaseIds: seq[uint64] = @[]
  var lostLeaseIds: seq[uint64] = @[]
  for key, lease in daemon.leases.pairs:
    if lease.sessionId.value == sessionId.value:
      case lease.state
      of leaseStateQueued, leaseStateGranted:
        deleteLeaseIds.add(key)
      of leaseStateFinished:
        discard
      of leaseStateStarting, leaseStateRunning:
        lostLeaseIds.add(key)
      of leaseStateSupervisorLost:
        discard
  for id in lostLeaseIds:
    var lost = daemon.leases[id]
    daemon.transitionLeaseState(lost, leaseStateSupervisorLost)
    lost.finishDiagnostic = diagnostic(
      diagCancelled,
      "supervisor connection closed before LeaseFinished",
      "RunQuota did not infer child process completion from IPC closure"
    )
    daemon.leases[id] = lost
  for id in deleteLeaseIds:
    daemon.removeLeaseFromTable(id)
  # THE CRASH EXIT FOR IN-FLIGHT SELF-REPORTS, and it costs one line here
  # because the reports are keyed by this session.
  #
  # This is the path a client takes when it does not get to say anything:
  # killed mid-execution, or its socket dropped. Its leases are reclaimed
  # above and always were; its reported CPU and RSS figures were not, and
  # before M13 they stayed in the live set for the daemon's whole lifetime,
  # subtracting a dead process's load from every subsequent `foreign_*`
  # until the clamp pinned the column to zero. Nothing about that is
  # visible in the data — the arithmetic stays self-consistent — which is
  # why it is reaped here rather than bounded by a timeout somewhere.
  daemon.reapSessionSelfReports(sessionId)
  daemon.sessions.del(sessionId.value)
  discard daemon.tryPromoteQueued(defaultFlowControlLimits().maxLeaseDecisionsPerBatch)

proc cleanupConnection(daemon: var RunQuotaDaemon; context: ConnectionContext) =
  for id in context.sessionIds:
    daemon.cleanupLostSession(id)

proc handleRequest(daemon: var RunQuotaDaemon; connection: var LocalConnection;
                   context: var ConnectionContext; frame: RqspFrame) =
  case frame.header.messageKind
  of rqRegisterSession:
    var msg: RegisterSessionMessage
    if not decodeRegisterSession(frame.payload, msg):
      connection.sendError(frame.header.requestId, diagnostic(diagProtocol,
          "invalid RegisterSession payload"))
      return
    let id = sessionId(daemon.nextSessionId)
    inc daemon.nextSessionId
    daemon.sessions[id.value] = SessionRow(
      id: id,
      name: msg.name,
      version: msg.version,
      supervisorProcessId: context.supervisorProcessId,
      supervisorUserId: context.supervisorUserId,
      peer: context.peer
    )
    context.sessionIds.add(id)
    daemon.openObservationRun(daemon.sessions[id.value])
    connection.sendResponse(
      rqSessionRegistered,
      frame.header.requestId,
      encodeSessionRegistered(SessionRegisteredMessage(sessionId: id))
    )
  of rqCloseSession:
    var msg: CloseSessionMessage
    if not decodeCloseSession(frame.payload, msg):
      connection.sendError(frame.header.requestId, diagnostic(diagProtocol,
          "invalid CloseSession payload"))
      return
    if not daemon.sessions.hasKey(msg.sessionId.value):
      connection.sendError(frame.header.requestId, diagnostic(
          diagInvalidArgument, "unknown session id"))
      return
    for lease in daemon.leases.values:
      if lease.sessionId.value == msg.sessionId.value and lease.state != leaseStateFinished:
        connection.sendError(frame.header.requestId, diagnostic(
            diagInvalidArgument, "session still owns leases"))
        return
    # An orderly close is still a close: whatever the session reported and
    # did not end goes with it, by the same key the crash path uses.
    daemon.reapSessionSelfReports(msg.sessionId)
    daemon.sessions.del(msg.sessionId.value)
    connection.sendResponse(
      rqSessionClosed,
      frame.header.requestId,
      encodeSessionClosed(SessionClosedMessage(sessionId: msg.sessionId))
    )
  of rqRequestLease:
    var msg: LeaseRequestMessage
    if not decodeLeaseRequest(frame.payload, msg):
      connection.sendError(frame.header.requestId, diagnostic(diagProtocol,
          "invalid RequestLease payload"))
      return
    if not daemon.sessions.hasKey(msg.sessionId.value):
      connection.sendError(frame.header.requestId, diagnostic(
          diagInvalidArgument, "unknown session id"))
      return
    let effective = daemon.effectiveResources(msg.sessionId,
        msg.commandStatsId, msg.resources, msg.estimate)
    var reason = ""
    if not daemon.possible(effective, reason):
      let denied = LeaseDeniedMessage(
        sessionId: msg.sessionId,
        diagnostic: diagnostic(diagDenied, reason)
      )
      connection.sendResponse(rqLeaseDenied, frame.header.requestId,
          encodeLeaseDenied(denied))
      return
    let queued = daemon.createQueuedLease(
      msg.sessionId,
      frame.header.requestId,
      msg.label,
      msg.commandStatsId,
      effective,
      msg.priority,
      msg.purpose
    )
    discard daemon.tryPromoteQueued(defaultFlowControlLimits().maxLeaseDecisionsPerBatch)
    if daemon.leases[queued.id.value].state != leaseStateGranted:
      let deniedDiagnostic = daemon.leases[queued.id.value].queueDiagnostic
      daemon.removeLeaseFromTable(queued.id.value)
      let denied = LeaseDeniedMessage(
        sessionId: msg.sessionId,
        diagnostic: deniedDiagnostic
      )
      connection.sendResponse(rqLeaseDenied, frame.header.requestId,
          encodeLeaseDenied(denied))
      return
    var grantedLease = daemon.leases[queued.id.value]
    grantedLease.delivered = true
    daemon.leases[queued.id.value] = grantedLease
    let granted = LeaseGrantedMessage(
      sessionId: msg.sessionId,
      leaseId: queued.id,
      resources: grantedLease.resources
    )
    connection.sendResponse(rqLeaseGranted, frame.header.requestId,
        encodeLeaseGranted(granted))
  of rqReleaseLease:
    var msg: ReleaseLeaseMessage
    if not decodeReleaseLease(frame.payload, msg):
      connection.sendError(frame.header.requestId, diagnostic(diagProtocol,
          "invalid ReleaseLease payload"))
      return
    if not daemon.leases.hasKey(msg.leaseId.value):
      connection.sendError(frame.header.requestId, diagnostic(
          diagInvalidArgument, "unknown lease id"))
      return
    let lease = daemon.leases[msg.leaseId.value]
    if lease.sessionId.value != msg.sessionId.value:
      connection.sendError(frame.header.requestId, diagnostic(
          diagInvalidArgument, "lease belongs to another session"))
      return
    daemon.endLeaseSelfReport(msg.leaseId)
    daemon.releaseLease(msg.leaseId)
    connection.sendResponse(
      rqLeaseReleased,
      frame.header.requestId,
      encodeLeaseReleased(LeaseReleasedMessage(sessionId: msg.sessionId,
          leaseId: msg.leaseId))
    )
  of rqOfferCandidates:
    var msg: CandidateOfferMessage
    if not decodeCandidateOffer(frame.payload, msg):
      connection.sendError(frame.header.requestId, diagnostic(diagProtocol,
          "invalid OfferCandidates payload"))
      return
    let flow = defaultFlowControlLimits()
    if uint32(msg.candidates.len) > flow.maxCandidatesPerBatch:
      connection.sendError(frame.header.requestId, diagnostic(
        diagProtocol,
        "candidate batch exceeds negotiated flow-control limit",
        "max_candidates_per_batch=" & $flow.maxCandidatesPerBatch
      ))
      return
    if not daemon.sessions.hasKey(msg.sessionId.value):
      connection.sendError(frame.header.requestId, diagnostic(
          diagInvalidArgument, "unknown session id"))
      return
    var offeredIds: seq[uint64] = @[]
    var decisions: seq[LeaseDecision] = @[]
    for candidate in msg.candidates:
      var reason = ""
      let effective = daemon.effectiveResources(msg.sessionId,
          candidate.commandStatsId, candidate.resources, candidate.estimate)
      if not daemon.possible(effective, reason):
        decisions.add(LeaseDecision(
          clientCandidateId: candidate.clientCandidateId,
          leaseId: leaseId(0),
          kind: leaseDecisionDenied,
          resources: effective,
          diagnostic: diagnostic(diagDenied, reason)
        ))
      else:
        let lease = daemon.createQueuedLease(
          msg.sessionId,
          candidate.clientCandidateId,
          candidate.label,
          candidate.commandStatsId,
          effective,
          candidate.priority,
          candidate.purpose
        )
        offeredIds.add(lease.id.value)
    discard daemon.tryPromoteQueued(flow.maxLeaseDecisionsPerBatch)
    for id in offeredIds:
      var lease = daemon.leases[id]
      if lease.state == leaseStateGranted:
        lease.delivered = true
        daemon.leases[id] = lease
        decisions.add(lease.leaseDecision(leaseDecisionGranted))
      else:
        decisions.add(lease.leaseDecision(leaseDecisionQueued))
    connection.sendResponse(
      rqLeaseDecisionBatch,
      frame.header.requestId,
      encodeLeaseDecisionBatch(LeaseDecisionBatchMessage(
          sessionId: msg.sessionId, decisions: decisions))
    )
  of rqGrantNext:
    var msg: GrantNextMessage
    if not decodeGrantNext(frame.payload, msg):
      connection.sendError(frame.header.requestId, diagnostic(diagProtocol,
          "invalid GrantNext payload"))
      return
    if not daemon.sessions.hasKey(msg.sessionId.value):
      connection.sendError(frame.header.requestId, diagnostic(
          diagInvalidArgument, "unknown session id"))
      return
    discard daemon.tryPromoteQueued(defaultFlowControlLimits().maxLeaseDecisionsPerBatch)
    var decisions: seq[LeaseDecision] = @[]
    for id, row in daemon.leases.pairs:
      if row.sessionId.value == msg.sessionId.value and
          row.state == leaseStateGranted and not row.delivered:
        var lease = row
        lease.delivered = true
        daemon.leases[id] = lease
        decisions.add(lease.leaseDecision(leaseDecisionGranted))
        break
    connection.sendResponse(
      rqLeaseDecisionBatch,
      frame.header.requestId,
      encodeLeaseDecisionBatch(LeaseDecisionBatchMessage(
          sessionId: msg.sessionId, decisions: decisions))
    )
  of rqLeaseStarting:
    var msg: LeaseStartingMessage
    if not decodeLeaseStarting(frame.payload, msg):
      connection.sendError(frame.header.requestId, diagnostic(diagProtocol,
          "invalid LeaseStarting payload"))
      return
    var lease: LeaseRow
    if not daemon.requireOwnedLease(connection, frame.header.requestId,
        msg.sessionId, msg.leaseId, lease):
      return
    if lease.state != leaseStateGranted:
      connection.sendError(frame.header.requestId, diagnostic(
          diagInvalidArgument, "lease is not granted"))
      return
    daemon.transitionLeaseState(lease, leaseStateStarting)
    lease.startedAtUnixMillis = unixMillisNow()
    daemon.leases[msg.leaseId.value] = lease
    connection.sendResponse(
      rqLeaseStartingAck,
      frame.header.requestId,
      encodeLeaseStartingAck(LeaseStartingAckMessage(sessionId: msg.sessionId,
          leaseId: msg.leaseId))
    )
  of rqLeaseRunning:
    var msg: LeaseRunningMessage
    if not decodeLeaseRunning(frame.payload, msg):
      connection.sendError(frame.header.requestId, diagnostic(diagProtocol,
          "invalid LeaseRunning payload"))
      return
    var lease: LeaseRow
    if not daemon.requireOwnedLease(connection, frame.header.requestId,
        msg.sessionId, msg.leaseId, lease):
      return
    if lease.state != leaseStateGranted and lease.state != leaseStateStarting:
      connection.sendError(frame.header.requestId, diagnostic(
          diagInvalidArgument, "lease cannot become running"))
      return
    daemon.transitionLeaseState(lease, leaseStateRunning)
    lease.childProcessId = msg.childProcessId
    lease.processGroupId = msg.processGroupId
    lease.cleanupRegistered = msg.cleanupRegistered
    daemon.leases[msg.leaseId.value] = lease
    connection.sendResponse(
      rqLeaseRunningAck,
      frame.header.requestId,
      encodeLeaseRunningAck(LeaseRunningAckMessage(sessionId: msg.sessionId,
          leaseId: msg.leaseId))
    )
  of rqLeaseFinished:
    var msg: LeaseFinishedMessage
    if not decodeLeaseFinished(frame.payload, msg):
      connection.sendError(frame.header.requestId, diagnostic(diagProtocol,
          "invalid LeaseFinished payload"))
      return
    var lease: LeaseRow
    if not daemon.requireOwnedLease(connection, frame.header.requestId,
        msg.sessionId, msg.leaseId, lease):
      return
    if lease.state != leaseStateStarting and lease.state != leaseStateRunning:
      connection.sendError(frame.header.requestId, diagnostic(
          diagInvalidArgument, "lease is not running"))
      return
    daemon.transitionLeaseState(lease, leaseStateFinished)
    lease.finishOutcome = msg.outcome
    lease.finishDiagnostic = msg.diagnostic
    lease.peakMemoryBytes = msg.peakMemoryBytes
    lease.processCount = msg.processCount
    lease.majorPageFaults = msg.majorPageFaults
    lease.pressureEvents = msg.pressureEvents
    lease.hardLimitOrOom = msg.hardLimitOrOom
    daemon.updateEstimateFromFinish(lease, msg)
    daemon.captureObservation(lease, msg)
    # M13b: AS IT FOLDS IN THIS RUN'S RESULTS, and after the row has been
    # captured so the aggregate includes it. Ordered after
    # `captureObservation` rather than beside `updateEstimateFromFinish`
    # because publishing an aggregate that excludes the run that triggered
    # it would make every published entry exactly one execution stale.
    daemon.publishAggregate(lease.commandStatsId)
    daemon.endLeaseSelfReport(msg.leaseId)
    inc daemon.totalFinished
    daemon.leases[msg.leaseId.value] = lease
    discard daemon.tryPromoteQueued(defaultFlowControlLimits().maxLeaseDecisionsPerBatch)
    connection.sendResponse(
      rqLeaseFinishedAck,
      frame.header.requestId,
      encodeLeaseFinishedAck(LeaseFinishedAckMessage(sessionId: msg.sessionId,
          leaseId: msg.leaseId))
    )
  of rqLeaseObservation:
    # ONE-WAY, AND THAT IS THE POINT. No acknowledgement is sent on any
    # path here — not on success, not on a refusal, not on a payload that
    # will not decode. §"Write Path" says an observation may not introduce
    # an additional round trip, and a reply the client would have to read
    # is exactly that; OS-1 says recording an observation must not block
    # the work being observed, and a reply is what a client would block on.
    #
    # A REFUSAL IS THEREFORE COUNTED RATHER THAN REPORTED. The client is
    # not told, because telling it would cost the round trip this message
    # exists to avoid, and because a client cannot do anything useful with
    # the news. The count is readable through the `observations` inspection
    # subject, which is where OS-2's "every dropped observation MUST be
    # counted" is satisfied for this path.
    var msg: LeaseObservationMessage
    if not decodeLeaseObservation(frame.payload, msg):
      inc daemon.observationsRejected
      return
    if daemon.applyLeaseObservation(context, msg):
      inc daemon.observationsAccepted
    else:
      inc daemon.observationsRejected
  of rqDeferredObservations:
    # ONE-WAY, for the same reason ``rqLeaseObservation`` is: the client
    # sending this is EXITING. A reply is something it would have to stay
    # alive to read, and a standalone client's degradation must not cost
    # the work it just finished anything at all.
    #
    # A REFUSAL IS THEREFORE COUNTED RATHER THAN REPORTED, and readable
    # through the `observations` inspection subject.
    var msg: DeferredObservationsMessage
    if not decodeDeferredObservations(frame.payload, msg):
      inc daemon.deferredBatchesRefused
      return
    if daemon.captureDeferredBatch(context, msg):
      inc daemon.deferredBatchesAccepted
    else:
      inc daemon.deferredBatchesRefused
  of rqStatusRequest:
    connection.sendResponse(rqStatusResponse, frame.header.requestId,
        encodeStatus(daemon.status()))
  of rqStatsQuery:
    # THE READ PATH, OVER THE SOCKET. Request/response with a variable-size
    # result, which is why it is here and not on the observation ring: the
    # ring is a one-way MPSC write path of the opposite shape, and the one
    # read with a latency budget (the admission estimate) is served from
    # the published aggregate table instead.
    var msg: StatsQueryMessage
    if not decodeStatsQuery(frame.payload, msg):
      connection.sendError(frame.header.requestId, diagnostic(diagProtocol,
          "invalid StatsQuery payload"))
      return
    connection.sendResponse(
      rqStatsResponse,
      frame.header.requestId,
      encodeStatsResponse(daemon.statsAnswer(context, msg))
    )
  of rqInspectionRequest:
    var msg: InspectionRequestMessage
    if not decodeInspectionRequest(frame.payload, msg):
      connection.sendError(frame.header.requestId, diagnostic(diagProtocol,
          "invalid InspectionRequest payload"))
      return
    connection.sendResponse(
      rqInspectionResponse,
      frame.header.requestId,
      encodeInspectionResponse(InspectionResponseMessage(
          json: daemon.inspectionJson(msg)))
    )
  else:
    connection.sendError(frame.header.requestId, diagnostic(diagProtocol,
        "unsupported RQSP message"))

proc handleConnection*(daemon: var RunQuotaDaemon;
    connection: var LocalConnection) =
  var context = ConnectionContext(
    supervisorProcessId: 0'u64,
    supervisorUserId: 0'u64,
    peer: PeerIdentity(
      kind: peerIdentityUnavailable,
      processId: 0'u64,
      userId: 0'u64,
      groupId: 0'u64
    ),
    sessionIds: @[]
  )
  var frame: RqspFrame
  if not connection.receiveFrameOrDiagnostic(frame):
    return
  if not daemon.handleHello(connection, context, frame):
    return
  try:
    while connection.receiveFrameOrDiagnostic(frame):
      daemon.handleRequest(connection, context, frame)
  finally:
    daemon.cleanupConnection(context)

type
  SharedDaemon = object
    lock: Lock
    daemon: RunQuotaDaemon

  ConnectionQueue = object
    lock: Lock
    ready: Cond
    stopping: bool
    items: seq[AcceptedConnection]

var sharedDaemon: SharedDaemon
var connectionQueue: ConnectionQueue

proc connectionWorkerCount(): int =
  max(4, min(32, countProcessors()))

proc initConnectionQueue() =
  initLock(connectionQueue.lock)
  initCond(connectionQueue.ready)
  connectionQueue.stopping = false
  connectionQueue.items = @[]

proc deinitConnectionQueue() =
  deinitCond(connectionQueue.ready)
  deinitLock(connectionQueue.lock)

proc enqueueConnection(accepted: AcceptedConnection) =
  acquire(connectionQueue.lock)
  try:
    if connectionQueue.stopping:
      return
    connectionQueue.items.add(accepted)
    signal(connectionQueue.ready)
  finally:
    release(connectionQueue.lock)

proc dequeueConnection(accepted: var AcceptedConnection): bool {.gcsafe.} =
  {.cast(gcsafe).}:
    acquire(connectionQueue.lock)
    try:
      while connectionQueue.items.len == 0 and not connectionQueue.stopping:
        wait(connectionQueue.ready, connectionQueue.lock)
      if connectionQueue.items.len > 0:
        accepted = connectionQueue.items[0]
        connectionQueue.items.delete(0)
        result = true
    finally:
      release(connectionQueue.lock)

proc stopConnectionQueue() =
  acquire(connectionQueue.lock)
  try:
    connectionQueue.stopping = true
    broadcast(connectionQueue.ready)
  finally:
    release(connectionQueue.lock)

proc handleSharedConnection(accepted: AcceptedConnection) {.thread, gcsafe.} =
  {.cast(gcsafe).}:
    var localConnection = accepted.localConnection()
    var context = ConnectionContext(
      supervisorProcessId: 0'u64,
      supervisorUserId: 0'u64,
      peer: PeerIdentity(
        kind: peerIdentityUnavailable,
        processId: 0'u64,
        userId: 0'u64,
        groupId: 0'u64
      ),
      sessionIds: @[]
    )
    var frame: RqspFrame
    if not localConnection.receiveFrameOrDiagnostic(frame):
      localConnection.close()
      return
    acquire(sharedDaemon.lock)
    let helloOk =
      try:
        sharedDaemon.daemon.handleHello(localConnection, context, frame)
      finally:
        release(sharedDaemon.lock)
    if not helloOk:
      localConnection.close()
      return
    try:
      while localConnection.receiveFrameOrDiagnostic(frame):
        acquire(sharedDaemon.lock)
        try:
          sharedDaemon.daemon.handleRequest(localConnection, context, frame)
        finally:
          release(sharedDaemon.lock)
    finally:
      acquire(sharedDaemon.lock)
      try:
        sharedDaemon.daemon.cleanupConnection(context)
      finally:
        release(sharedDaemon.lock)
      localConnection.close()

proc connectionWorker() {.thread, gcsafe.} =
  while true:
    var accepted: AcceptedConnection
    if not dequeueConnection(accepted):
      break
    handleSharedConnection(accepted)

const endpointRefusedExitCode* = 3
  ## `serve` returns this when the rendezvous directory is not trustworthy.
  ## Distinct from a usage error (2) so a supervisor can tell "you asked for
  ## something impossible" from "the path you asked for belongs to someone
  ## else".

proc serve*(config: DaemonConfig): int =
  # THE RENDEZVOUS PATH IS CHECKED BEFORE ANYTHING ELSE STARTS. A daemon
  # that has already opened its observation store, minted a boot id and
  # spawned its writer thread has done work on behalf of a directory it is
  # about to refuse. `bindEndpoint` verifies again after creating the
  # directory; this one is about not getting that far.
  let refusal = endpointDirectoryRefusal(config.endpoint)
  if refusal.len > 0:
    echo refusal
    flushFile(stdout)
    return endpointRefusedExitCode
  initLock(sharedDaemon.lock)
  initConnectionQueue()
  sharedDaemon.daemon = initDaemon(config)
  var listener: LocalListener
  try:
    listener = bindEndpoint(config.endpoint)
  except EndpointTrustError as error:
    # Only reachable if the directory changed underneath the pre-check
    # above. Still a refusal rather than a fallback, and the background
    # threads `initDaemon` started are stopped rather than stranded.
    echo error.msg
    flushFile(stdout)
    stopEstimateStore(sharedDaemon.daemon.estimateStore)
    stopAmbientSampler()
    stopObservationWriter()
    deinitLock(sharedDaemon.lock)
    deinitConnectionQueue()
    return endpointRefusedExitCode
  sharedDaemon.daemon.state = dsServing
  # AFTER the rendezvous directory exists and has been verified, because the
  # published table lives in it and is discovered the same way the socket is.
  sharedDaemon.daemon.startStatsPublisher()
  # THE DEGRADATION IS SAID OUT LOUD, and it is appended to the listening
  # line rather than printed on one of its own: the startup output is a
  # FIXED number of lines that readers consume by count, and a fourth line
  # would leave every reader of the third one misreading or blocked. An
  # operator sees, on the line they already read, whether this host's
  # endpoint is group-gated or owner-only.
  #
  # M13b's table is reported on THIS line for the same reason the
  # degradation is: the startup output is a FIXED THREE LINES that readers
  # consume by count, and a fourth would leave every reader of the third one
  # misreading or blocked. That rule has already cost this campaign one
  # defect (M13's unfolded `OSError.msg`), so a new subsystem appends rather
  # than announces.
  echo "runquotad listening " & config.endpoint.path &
    rendezvousDegradationReport() & "; " &
    statsPublisherReport(sharedDaemon.daemon.statsPublisher)
  # The report is the "clear report" half of OS-4: a store that will not
  # open says so on stdout and the daemon carries on serving leases.
  #
  # EXACTLY THREE STARTUP LINES, ALWAYS, and the "always" is new with M13.
  # It used to be three lines when a store path was given and one when it
  # was not — a distinction that stopped existing the moment capture became
  # ON WITHOUT ANY FLAG, because there is now always a store to report on,
  # including the one the operator turned off. A reader that has to guess
  # how many lines it will get is a reader that deadlocks on a daemon which
  # then goes quiet, so the count is fixed rather than conditional.
  echo sharedDaemon.daemon.observationStore.report
  echo sharedDaemon.daemon.observationIdentityReport
  flushFile(stdout)
  var threads: seq[Thread[void]] = @[]
  for _ in 0 ..< connectionWorkerCount():
    threads.add(default(Thread[void]))
    createThread(threads[^1], connectionWorker)
  try:
    while true:
      let accepted = listener.acceptNativeConnection()
      enqueueConnection(accepted)
  finally:
    stopConnectionQueue()
    for i in 0 ..< threads.len:
      joinThread(threads[i])
    acquire(sharedDaemon.lock)
    try:
      sharedDaemon.daemon.state = dsStopping
      stopEstimateStore(sharedDaemon.daemon.estimateStore)
      stopAmbientSampler()
      stopObservationWriter()
      # The FILE is deliberately left behind. A table whose publisher has
      # exited is STALE, not invalid, and a stale entry is a slightly worse
      # estimate rather than an incorrect admission — the anchor in its
      # header is what tells a reader which it is holding. Unlinking here
      # would turn "tolerate staleness", which is specified behaviour, into
      # a path nothing ever takes.
      sharedDaemon.daemon.statsPublisher.close()
    finally:
      release(sharedDaemon.lock)
      listener.close()
      deinitLock(sharedDaemon.lock)
      deinitConnectionQueue()
  0
