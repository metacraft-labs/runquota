## A learned memory estimate must never make a command unadmittable.
##
## The daemon learns each command's memory from its finished leases and only
## ever RAISES the figure (`updateEstimateFromFinish`: 1.25x the peak, 2x on
## an OOM kill, never lowered). Admission then reserves the learned figure
## for every later request of that command (`effectiveResources`). So one
## inflated sample is permanent — and when it exceeds the machine's memory
## budget, `possible` refuses every future request for that command:
##
##   runquota static-capacity deadlock for 'repro provider compile edge' ...
##   lease request exceeds machine memory budget: local
##
## Observed on a shared Windows workstation: a ~2 GB nim provider compile had
## learned 28.6 GiB against a 16 GiB budget (a peak that absorbed an
## unrelated process through a recycled parent PID), and no build that needed
## a provider compile could run again until the daemon was restarted. The
## learned figure is now capped at the machine budget; these cases pin that,
## and that a figure under the budget still raises the request as before.

import std/[os, tables, unittest]

import runquota_core
import runquota_daemon {.all.}
import runquota_protocol
import runquota_persistence

proc testDaemon(root: string; memory: uint64): RunQuotaDaemon =
  removeDir(root)
  createDir(root)
  let config = DaemonConfig(
    daemonId: 1'u64,
    cpuSlots: milliCpu(4000),
    memoryBytes: bytes(memory),
    ioSlots: 8'u32,
    machines: initTable[string, MachineCapacity](),
    cpuShareGroups: initTable[string, CpuShareGroup](),
    namedPoolCaps: initTable[string, uint32](),
    version: "test",
    estimateDbPath: root / "estimates.db",
    estimateQueueCapacity: 8,
    observationDbPath: root / "observations.db")
  initDaemon(config)

proc seedLearned(daemon: var RunQuotaDaemon; session: SessionRow;
                 commandStatsId: string; memory: uint64) =
  daemon.sessions[session.id.value] = session
  let key = estimateTableKey(sessionScope(session), commandStatsId)
  daemon.estimates[key] = LearnedEstimateRow(
    scope: sessionScope(session),
    commandStatsId: commandStatsId,
    conservativeMemoryBytes: memory,
    recentPeakMemoryBytes: memory,
    sampleCount: 1'u32)

const Budget = 8_000_000_000'u64

suite "learned estimates are capped at the machine memory budget":

  test "an estimate above the budget is capped, and the request is possible":
    let root = getTempDir() / "runquota-estimate-cap-over"
    defer:
      try: removeDir(root) except CatchableError: discard
    var daemon = testDaemon(root, Budget)
    let session = SessionRow(id: sessionId(7'u64), name: "reprobuild action")
    daemon.seedLearned(session, "repro provider compile edge",
      30_000_000_000'u64)  # ~28 GiB learned against an 8 GB budget
    let requested = resourceVector(milliCpu(1000), bytes(134_217_728'u64))
    let effective = daemon.effectiveResources(session.id,
      "repro provider compile edge", requested, ClientEstimate())
    check effective.memory.value == Budget
    var reason = ""
    check daemon.possible(effective, reason)
    check reason == ""

  test "an estimate under the budget still raises the request unchanged":
    # The cap must not flatten the mechanism it guards: a genuine learned
    # figure below the budget is exactly what admission should reserve.
    let root = getTempDir() / "runquota-estimate-cap-under"
    defer:
      try: removeDir(root) except CatchableError: discard
    var daemon = testDaemon(root, Budget)
    let session = SessionRow(id: sessionId(8'u64), name: "reprobuild action")
    daemon.seedLearned(session, "repro interface extract edge",
      870_000_000'u64)
    let requested = resourceVector(milliCpu(1000), bytes(134_217_728'u64))
    let effective = daemon.effectiveResources(session.id,
      "repro interface extract edge", requested, ClientEstimate())
    check effective.memory.value == 870_000_000'u64

  test "a request larger than the learned figure is not lowered":
    let root = getTempDir() / "runquota-estimate-cap-larger-request"
    defer:
      try: removeDir(root) except CatchableError: discard
    var daemon = testDaemon(root, Budget)
    let session = SessionRow(id: sessionId(9'u64), name: "reprobuild action")
    daemon.seedLearned(session, "cmd", 100_000_000'u64)
    let requested = resourceVector(milliCpu(1000), bytes(2_000_000_000'u64))
    let effective = daemon.effectiveResources(session.id, "cmd", requested,
      ClientEstimate())
    check effective.memory.value == 2_000_000_000'u64
