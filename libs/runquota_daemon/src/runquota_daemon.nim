import std/[algorithm, cpuinfo, locks, os, strutils, tables]

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
import runquota_persistence
import runquota_protocol

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
    estimateQueueCapacity: 128
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

proc estimateTableKey(scope, commandStatsId: string): string =
  scope & "\0" & commandStatsId

proc sessionScope(session: SessionRow): string =
  "session:" & session.name

proc initDaemon*(config: DaemonConfig): RunQuotaDaemon =
  var effectiveConfig = config
  effectiveConfig.normalizeTopology()
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
        effectiveConfig.estimateQueueCapacity)
  )
  for row in loadLearnedEstimates(effectiveConfig.estimateDbPath):
    result.estimates[estimateTableKey(row.scope, row.commandStatsId)] = row

proc countLeases(daemon: RunQuotaDaemon; state: LeaseLifecycleState): uint32 =
  for lease in daemon.leases.values:
    if lease.state == state:
      inc result

proc isResourceActive(state: LeaseLifecycleState): bool =
  state in {leaseStateGranted, leaseStateStarting, leaseStateRunning, leaseStateSupervisorLost}

proc countActiveLeases(daemon: RunQuotaDaemon): uint32 =
  for lease in daemon.leases.values:
    if lease.state.isResourceActive:
      inc result

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

proc activeUsage(daemon: RunQuotaDaemon; targetMachineId, targetCpuGroupId: string;
                 machineCpu: var uint32; machineMemory: var uint64;
                 machineIo: var uint32; sharedCpu: var uint32;
                 pools: var Table[string, uint32]) =
  machineCpu = 0'u32
  machineMemory = 0'u64
  machineIo = 0'u32
  sharedCpu = 0'u32
  pools = initTable[string, uint32]()
  for lease in daemon.leases.values:
    if lease.state.isResourceActive:
      var machine: MachineCapacity
      if not daemon.machineFor(lease.resources.resolvedMachineId(), machine):
        continue
      if machine.id == targetMachineId:
        machineCpu += lease.resources.cpu.value
        machineMemory += lease.resources.memory.value
        machineIo += lease.resources.ioSlots(machine.ioSlots)
      if machine.cpuShareGroup == targetCpuGroupId:
        sharedCpu += lease.resources.cpu.value
      for demand in lease.resources.namedPools:
        pools[demand.name] = pools.getOrDefault(demand.name, 0'u32) + demand.units

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

proc configuredPressureSample(daemon: RunQuotaDaemon): HostMemoryPressureSample =
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
    if daemon.config.pressureFile.len == 0 or not fileExists(
        daemon.config.pressureFile):
      return unavailablePressureSample(
        "deterministic-file",
        daemon.config.pressureRequired,
        "pressure file is missing"
      )
    let raw = readFile(daemon.config.pressureFile).strip().toLowerAscii()
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

proc configuredPressureAvailable(daemon: RunQuotaDaemon): bool =
  case daemon.config.pressureSource
  of pressureSourceHost:
    when defined(macosx):
      true
    else:
      false
  of pressureSourceUnavailable:
    false
  of pressureSourceDeterministicFile:
    if daemon.config.pressureFile.len == 0 or
        not fileExists(daemon.config.pressureFile):
      return false
    let raw = readFile(daemon.config.pressureFile).strip().toLowerAscii()
    raw in ["low", "normal", "ok", "warning", "warn", "critical", "crit"]

proc pressureAllows(daemon: RunQuotaDaemon; resources: ResourceVector;
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
  var usedMachineCpu: uint32
  var usedMachineMemory: uint64
  var usedMachineIo: uint32
  var usedSharedCpu: uint32
  var usedPools: Table[string, uint32]
  daemon.activeUsage(
    machine.id,
    group.id,
    usedMachineCpu,
    usedMachineMemory,
    usedMachineIo,
    usedSharedCpu,
    usedPools
  )
  if usedMachineCpu + resources.cpu.value > machine.cpuSlots.value:
    return false
  if usedSharedCpu + resources.cpu.value > group.cpuSlots.value:
    return false
  if usedMachineMemory + resources.memory.value > machine.memoryBytes.value:
    return false
  if usedMachineIo + resources.ioSlots(machine.ioSlots) > machine.ioSlots:
    return false
  for demand in resources.namedPools:
    let cap = daemon.config.namedPoolCaps.getOrDefault(demand.name, 0'u32)
    let used = usedPools.getOrDefault(demand.name, 0'u32)
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
  for lease in daemon.leases.values:
    if lease.state.isResourceActive and lease.purpose == leasePurposeBenchmark:
      return true

proc benchmarkGateAllows(daemon: RunQuotaDaemon; lease: LeaseRow): bool =
  let benchmarkId = daemon.earliestQueuedBenchmarkId()
  if lease.purpose == leasePurposeBenchmark:
    return benchmarkId == lease.id.value and daemon.countActiveLeases() == 0'u32
  if daemon.hasActiveBenchmark():
    return false
  benchmarkId == 0'u64

proc waitingDiagnostic(daemon: RunQuotaDaemon; lease: LeaseRow): Diagnostic =
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

proc pressureJson(daemon: RunQuotaDaemon): string =
  let sample = daemon.configuredPressureSample()
  "{\"pressure\":{\"level\":" & jsonEscape($sample.level) & "," &
    "\"available\":" & $(sample.available) & "," &
    "\"required\":" & $(daemon.config.pressureRequired) & "," &
    "\"source\":" & jsonEscape(sample.source) & "," &
    "\"diagnostic\":" & jsonEscape(sample.diagnostic.message) & "}}"

proc inspectionJson(daemon: RunQuotaDaemon;
    request: InspectionRequestMessage): string =
  case request.subject
  of "sessions":
    daemon.sessionsJson()
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

proc handleHello(daemon: RunQuotaDaemon; connection: var LocalConnection;
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
  context.peer = connection.peerIdentity()
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
                        commandStatsId: string;
                            requested: ResourceVector): ResourceVector =
  result = requested
  if commandStatsId.len == 0 or not daemon.sessions.hasKey(sessionId.value):
    return
  let scope = daemon.sessions[sessionId.value].sessionScope()
  let key = estimateTableKey(scope, commandStatsId)
  if daemon.estimates.hasKey(key):
    let learned = daemon.estimates[key].conservativeMemoryBytes
    if learned > result.memory.value:
      result.memory = bytes(learned)

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

proc grantQueuedLease(daemon: var RunQuotaDaemon; id: uint64; delivered: bool) =
  var lease = daemon.leases[id]
  lease.state = leaseStateGranted
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
    daemon.leases.del(id.value)
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
    lost.state = leaseStateSupervisorLost
    lost.finishDiagnostic = diagnostic(
      diagCancelled,
      "supervisor connection closed before LeaseFinished",
      "RunQuota did not infer child process completion from IPC closure"
    )
    daemon.leases[id] = lost
  for id in deleteLeaseIds:
    daemon.leases.del(id)
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
    let effective = daemon.effectiveResources(msg.sessionId, msg.commandStatsId, msg.resources)
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
      daemon.leases.del(queued.id.value)
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
          candidate.commandStatsId, candidate.resources)
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
    lease.state = leaseStateStarting
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
    lease.state = leaseStateRunning
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
    lease.state = leaseStateFinished
    lease.finishOutcome = msg.outcome
    lease.finishDiagnostic = msg.diagnostic
    lease.peakMemoryBytes = msg.peakMemoryBytes
    lease.processCount = msg.processCount
    lease.majorPageFaults = msg.majorPageFaults
    lease.pressureEvents = msg.pressureEvents
    lease.hardLimitOrOom = msg.hardLimitOrOom
    daemon.updateEstimateFromFinish(lease, msg)
    inc daemon.totalFinished
    daemon.leases[msg.leaseId.value] = lease
    discard daemon.tryPromoteQueued(defaultFlowControlLimits().maxLeaseDecisionsPerBatch)
    connection.sendResponse(
      rqLeaseFinishedAck,
      frame.header.requestId,
      encodeLeaseFinishedAck(LeaseFinishedAckMessage(sessionId: msg.sessionId,
          leaseId: msg.leaseId))
    )
  of rqStatusRequest:
    connection.sendResponse(rqStatusResponse, frame.header.requestId,
        encodeStatus(daemon.status()))
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

proc serve*(config: DaemonConfig): int =
  initLock(sharedDaemon.lock)
  initConnectionQueue()
  sharedDaemon.daemon = initDaemon(config)
  var listener = bindEndpoint(config.endpoint)
  sharedDaemon.daemon.state = dsServing
  echo "runquotad listening " & config.endpoint.path
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
    finally:
      release(sharedDaemon.lock)
      listener.close()
      deinitLock(sharedDaemon.lock)
      deinitConnectionQueue()
  0
