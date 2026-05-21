import std/[os, osproc, strutils, unittest]

import runquota_client
import runquota_core
when defined(linux):
  import runquota_host_linux
import runquota_host_macos
import runquota_process
import runquota_protocol

const FixtureArg = "--pressure-fixture"

if commandLineParams().len == 1 and commandLineParams()[0] == FixtureArg:
  var ballast = newSeq[byte](8 * 1024 * 1024)
  for i in countup(0, ballast.high, 4096):
    ballast[i] = byte(i and 0xff)
  sleep(30_000)
  doAssert ballast.len > 0
  quit 0

proc daemonPath(): string =
  getCurrentDir() / "build" / "bin" / "runquotad"

proc waitForDaemon(socketPath: string) =
  putEnv("RUNQUOTA_SOCKET", socketPath)
  var lastError = ""
  for _ in 0 ..< 100:
    try:
      var client = connectDefault()
      client.close()
      return
    except CatchableError as error:
      lastError = error.msg
      sleep(50)
  raise newException(OSError, "runquotad did not become ready: " & lastError)

proc writePressure(path, level: string) =
  writeFile(path, level & "\n")

proc mib(value: uint64): uint64 =
  value * 1024'u64 * 1024'u64

proc conservativeEstimate(observedPeakMemoryBytes: uint64): uint64 =
  max(observedPeakMemoryBytes, (observedPeakMemoryBytes * 125'u64) div 100'u64)

proc req(label: string; memoryMiB: uint64; commandStatsId = ""): ResourceRequest =
  result = resourceRequest(label, milliCpu(500), bytes(mib(memoryMiB)))
  result.commandStatsId = commandStatsId

proc candidate(id: uint64; request: ResourceRequest): LeaseCandidate =
  toCandidate(id, request)

proc findDecision(decisions: seq[OfferedLease]; candidateId: uint64): OfferedLease =
  for decision in decisions:
    if decision.clientCandidateId == candidateId:
      return decision
  raise newException(ValueError, "missing decision for candidate " & $candidateId)

proc waitForGrant(session: var RunQuotaSession; candidateId: uint64): RunQuotaLease =
  for _ in 0 ..< 100:
    for grant in session.pollNextGrant():
      if grant.clientCandidateId == candidateId and not grant.queued:
        return grant.lease
    sleep(50)
  raise newException(OSError, "grant did not arrive for candidate " & $candidateId)

proc launchForLease(lease: var RunQuotaLease): LaunchedProcess =
  result = launchProcess(getAppFilename(), [FixtureArg])
  lease.markStarting()
  lease.markRunning(childProcessId = result.info.processId, cleanupRegistered = true)

proc waitForProcessTelemetry(processId: uint64): HostProcessTreeTelemetrySample =
  for _ in 0 ..< 100:
    result =
      when defined(linux):
        sampleLinuxProcessTreeTelemetry(processId)
      else:
        sampleMacosProcessTreeTelemetry(processId)
    if result.diagnostic.code == diagOk and result.rootAlive and
        result.processCount > 0 and result.residentMemoryBytes > mib(1):
      return
    sleep(50)
  raise newException(OSError, "process telemetry was not observed")

proc finishLaunched(lease: var RunQuotaLease; child: var LaunchedProcess;
                    peakMemoryBytes: uint64; processCount: uint32) =
  if child.running:
    child.terminate()
    discard child.waitForExit(3000)
  child.close()
  lease.finish(peakMemoryBytes = peakMemoryBytes, processCount = processCount)

proc persistedEstimate(dbPath, commandStatsId: string): uint64 =
  try:
    let output = execProcess(
      "sqlite3",
      args = [
        dbPath,
        "select conservative_memory_bytes from learned_estimates " &
          "where command_stats_id = '" & commandStatsId & "' limit 1;"
      ],
      options = {poUsePath}
    ).strip()
    if output.len == 0:
      return 0'u64
    parseUInt(output.splitLines()[0])
  except CatchableError:
    0'u64

proc waitForPersistedEstimate(dbPath, commandStatsId: string): uint64 =
  for _ in 0 ..< 100:
    let value = persistedEstimate(dbPath, commandStatsId)
    if value > 0:
      return value
    sleep(50)
  raise newException(OSError, "learned estimate was not persisted")

suite "integration_runquota_memory_pressure_gate":
  test "real daemon gates memory-heavy work and persists learned estimates":
    let socketDir = getTempDir() / ("runquota-m4-" & $getCurrentProcessId())
    let socketPath = socketDir / "runquotad.sock"
    let pressurePath = socketDir / "pressure.txt"
    let estimateDb = socketDir / "estimates.sqlite"
    if dirExists(socketDir):
      removeDir(socketDir)
    createDir(socketDir)
    writePressure(pressurePath, "low")
    check fileExists(daemonPath())

    let daemon = startProcess(
      daemonPath(),
      args = [
        "--socket", socketPath,
        "--cpu-milli", "2000",
        "--memory-bytes", $mib(1000),
        "--memory-pressure-source", "deterministic-file",
        "--memory-pressure-file", pressurePath,
        "--memory-pressure-required",
        "--memory-pressure-heavy-bytes", $mib(256),
        "--estimate-db", estimateDb
      ],
      options = {poStdErrToStdOut}
    )
    try:
      waitForDaemon(socketPath)

      var client = connectDefault()
      check client.capabilities.hardMemoryLimitMode == memoryLimitAdvisory
      check client.capabilities.memoryPressureRequired
      var session = client.registerSession("m4-pressure", "0.1.0")

      let first = session.offerCandidates([
        candidate(101, req("low-pressure-heavy", 400, "learned-stat"))
      ])
      var learnedLease = first.findDecision(101).lease
      check not first.findDecision(101).queued
      var learnedChild = learnedLease.launchForLease()

      writePressure(pressurePath, "warning")
      let warning = session.offerCandidates([
        candidate(102, req("warning-heavy", 998))
      ])
      let warningDecision = warning.findDecision(102)
      check warningDecision.queued
      check warningDecision.diagnostic.message.contains("host memory pressure")
      check learnedChild.running

      let small = session.offerCandidates([
        candidate(103, req("warning-small", 64))
      ])
      var smallLease = small.findDecision(103).lease
      check not small.findDecision(103).queued
      var smallChild = smallLease.launchForLease()
      smallLease.finishLaunched(smallChild, mib(32), 1'u32)

      writePressure(pressurePath, "critical")
      let critical = session.offerCandidates([
        candidate(104, req("critical-heavy", 300))
      ])
      let criticalDecision = critical.findDecision(104)
      check criticalDecision.queued
      check criticalDecision.diagnostic.detail.contains("pressureCritical")
      var criticalLease = criticalDecision.lease
      criticalLease.release()

      writePressure(pressurePath, "low")
      let learnedTelemetry = waitForProcessTelemetry(learnedChild.info.processId)
      let learnedConservative = conservativeEstimate(learnedTelemetry.residentMemoryBytes)
      learnedLease.finishLaunched(
        learnedChild,
        learnedTelemetry.residentMemoryBytes,
        learnedTelemetry.processCount
      )

      let repeated = session.offerCandidates([
        candidate(106, req("learned-repeat", 1, "learned-stat"))
      ])
      let repeatedDecision = repeated.findDecision(106)
      check repeatedDecision.queued
      check repeatedDecision.lease.resources.memory.value >= learnedConservative
      check client.inspectionJson("estimates").contains("learned-stat")

      let persisted = waitForPersistedEstimate(estimateDb, "learned-stat")
      check persisted >= learnedConservative

      var warningLease = session.waitForGrant(102)
      warningLease.release()

      var repeatedLease = repeatedDecision.lease
      repeatedLease.release()

      writePressure(pressurePath, "unavailable")
      let unavailable = session.offerCandidates([
        candidate(107, req("unavailable-required-heavy", 300))
      ])
      let unavailableDecision = unavailable.findDecision(107)
      check unavailableDecision.queued
      check unavailableDecision.diagnostic.detail.contains("required memory-pressure signal unavailable")
      var unavailableLease = unavailableDecision.lease
      unavailableLease.release()

      session.closeSession()
      client.close()
    finally:
      if daemon.running:
        daemon.terminate()
        discard daemon.waitForExit(3000)
      daemon.close()
      if dirExists(socketDir):
        removeDir(socketDir)
