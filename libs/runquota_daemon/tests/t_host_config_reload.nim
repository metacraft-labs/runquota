## Changing the host budget under a running daemon (`reloadHostConfig`).
##
## One daemon serves the whole host, so restarting it to change a budget
## drops every workspace's session at once; that is why the budget can be
## reloaded. The decision this file pins is what a new budget does to the
## leases that already exist (reprobuild-specs/RunQuota-Host-Configuration.md,
## "Changing it under a running daemon"):
##
## * a GROW promotes queued leases that now fit, in the reload itself;
## * a SHRINK never revokes a granted lease. The granted total may exceed the
##   new budget, and nothing new is admitted until it falls below;
## * a queued lease the new budget can NEVER hold is denied, and the denial
##   reaches its session on the next `GrantNext`;
## * a file that does not parse changes nothing;
## * a `runquotad` flag still wins over the file after a reload.
##
## NO MOCKS. A real `RunQuotaDaemon` object reads a real TOML file in a
## scratch directory; nothing serves an endpoint here, because these cases
## drive admission directly. `tests/integration/t_runquota_config_reload.nim`
## does the same through a real `runquotad` and the `runquota config` verb.

import std/[options, os, strutils, tables, unittest]

import runquota_core
import runquota_daemon {.all.}
import runquota_daemon/host_config
import runquota_protocol

const GiB = 1024'u64 * 1024'u64 * 1024'u64

var scratchRoots: seq[string] = @[]

proc scratch(tag: string): string =
  result = getTempDir() / ("runquota-reload-" & tag & "-" &
    $getCurrentProcessId())
  removeDir(result)
  createDir(result)
  scratchRoots.add(result)

proc writeBudget(path: string; memoryGiB: uint64; extra = "") =
  writeFile(path, "schema = \"runquota.host-config.v1\"\n[machine]\n" &
    "memory_bytes = " & $(memoryGiB * GiB) & "\ncpu_milli = 8000\n" & extra)

proc testDaemon(root: string; flags = BudgetFlags()): RunQuotaDaemon =
  ## A daemon laid out the way `runquotad` lays one out: built-in defaults,
  ## then the file at `root/runquotad.toml`, then `flags`.
  var config = DaemonConfig(
    daemonId: 1'u64,
    cpuSlots: milliCpu(4000),
    memoryBytes: bytes(2'u64 * GiB),
    builtinCpuSlots: milliCpu(4000),
    builtinMemoryBytes: bytes(2'u64 * GiB),
    ioSlots: 8'u32,
    machines: initTable[string, MachineCapacity](),
    cpuShareGroups: initTable[string, CpuShareGroup](),
    namedPoolCaps: initTable[string, uint32](),
    version: "test",
    # Admission must depend on the ledger alone, not on this host's pressure.
    pressureSource: pressureSourceUnavailable,
    estimateDbPath: root / "estimates.db",
    estimateQueueCapacity: 8,
    observationDbPath: root / "observations.db",
    hostConfigPath: root / "runquotad.toml",
    budgetFlags: flags)
  let host = readHostConfig(config.hostConfigPath)
  config.resolveBudget(host)
  config.hostConfigSource = host.sourcePath
  result = initDaemon(config)
  result.sessions[1'u64] = SessionRow(id: sessionId(1'u64), name: "one")
  result.sessions[2'u64] = SessionRow(id: sessionId(2'u64), name: "two")

proc offer(daemon: var RunQuotaDaemon; session: uint64; memoryGiB: uint64;
           pool = ""): LeaseRow =
  ## A candidate queued the way `OfferCandidates` queues one, then decided.
  var resources = resourceVector(milliCpu(1000), bytes(memoryGiB * GiB))
  if pool.len > 0:
    resources.namedPools.add(namedPoolDemand(pool, 1'u32))
  let lease = daemon.createQueuedLease(sessionId(session),
    daemon.nextLeaseId, "offer", "", resources, priorityNormal,
    leasePurposeWork)
  discard daemon.tryPromoteQueued()
  daemon.leases[lease.id.value]

proc local(daemon: RunQuotaDaemon): MachineCapacity =
  daemon.config.machines[DefaultMachineId]

proc grantNext(daemon: var RunQuotaDaemon; session: uint64):
    seq[LeaseDecision] =
  ## The `GrantNext` handler's own answer to `session`.
  daemon.grantNextDecisions(sessionId(session))

suite "host configuration reload":

  test "start-up reads the file over the built-in defaults":
    let root = scratch("start")
    writeBudget(root / "runquotad.toml", 8)
    var daemon = testDaemon(root)
    check daemon.local.memoryBytes.value == 8'u64 * GiB
    check daemon.local.cpuSlots.value == 8000'u32
    check daemon.config.hostConfigSource == root / "runquotad.toml"

  test "a grow promotes what now fits, in the reload itself":
    let root = scratch("grow")
    writeBudget(root / "runquotad.toml", 8)
    var daemon = testDaemon(root)
    let first = daemon.offer(1, 6)
    check first.state == leaseStateGranted
    let waiting = daemon.offer(2, 6)
    check waiting.state == leaseStateQueued

    writeBudget(root / "runquotad.toml", 16)
    let answer = daemon.reloadHostConfig()
    check answer.memoryBytes == 16'u64 * GiB
    check answer.promotedLeases == 1'u32
    check answer.sourcePath == root / "runquotad.toml"
    check daemon.local.memoryBytes.value == 16'u64 * GiB
    check daemon.leases[waiting.id.value].state == leaseStateGranted
    # Delivered to its session on the next poll, like any other grant.
    let decisions = daemon.grantNext(2)
    check decisions.len == 1
    check decisions[0].kind == leaseDecisionGranted
    check decisions[0].leaseId.value == waiting.id.value

  test "a shrink never revokes a granted lease, and admits nothing new":
    let root = scratch("shrink")
    writeBudget(root / "runquotad.toml", 16)
    var daemon = testDaemon(root)
    let big = daemon.offer(1, 10)
    check big.state == leaseStateGranted

    writeBudget(root / "runquotad.toml", 8)
    let answer = daemon.reloadHostConfig()
    check answer.memoryBytes == 8'u64 * GiB
    # The granted lease is still granted, and still holds its 10 GiB --
    # over the new budget, and reported as such.
    check daemon.leases[big.id.value].state == leaseStateGranted
    check answer.memoryInUse == 10'u64 * GiB
    check daemon.activeLeaseCount == 1'u32
    check "over the new budget" in reloadReport(answer)
    # A lease that fits the new budget on its own still waits: the granted
    # total already exceeds it.
    let small = daemon.offer(2, 2)
    check small.state == leaseStateQueued
    # Once the big lease is released the budget has room again.
    daemon.releaseLease(big.id)
    check daemon.leases[small.id.value].state == leaseStateGranted

  test "a queued lease the new budget can never hold is denied on GrantNext":
    let root = scratch("doomed")
    writeBudget(root / "runquotad.toml", 16)
    var daemon = testDaemon(root)
    let holder = daemon.offer(1, 10)
    check holder.state == leaseStateGranted
    let doomed = daemon.offer(2, 12)
    check doomed.state == leaseStateQueued
    let fits = daemon.offer(2, 4)
    check fits.state == leaseStateGranted

    writeBudget(root / "runquotad.toml", 8)
    discard daemon.reloadHostConfig()
    # Gone from the queue at once: it could only ever wait forever.
    check not daemon.leases.hasKey(doomed.id.value)
    # Granted leases are untouched, even the one granted in the same session.
    check daemon.leases[fits.id.value].state == leaseStateGranted
    let decisions = daemon.grantNext(2)
    var denied = 0
    for decision in decisions:
      if decision.leaseId.value == doomed.id.value:
        inc denied
        check decision.kind == leaseDecisionDenied
        check decision.diagnostic.code == diagDenied
        check decision.diagnostic.message ==
          "lease request exceeds machine memory budget: local"
    check denied == 1
    # Delivered once.
    for decision in daemon.grantNext(2):
      check decision.leaseId.value != doomed.id.value

  test "a session that goes away takes its pending denials with it":
    let root = scratch("lost")
    writeBudget(root / "runquotad.toml", 16)
    var daemon = testDaemon(root)
    discard daemon.offer(1, 10)
    discard daemon.offer(2, 12)
    writeBudget(root / "runquotad.toml", 8)
    discard daemon.reloadHostConfig()
    check daemon.pendingDenials.hasKey(2'u64)
    daemon.cleanupLostSession(sessionId(2'u64))
    check not daemon.pendingDenials.hasKey(2'u64)

  test "a pool the file drops refuses new demand; one it grows promotes":
    let root = scratch("pools")
    writeBudget(root / "runquotad.toml", 16, "[pools]\ncompile = 1\n")
    var daemon = testDaemon(root)
    let first = daemon.offer(1, 1, "compile")
    check first.state == leaseStateGranted
    let second = daemon.offer(2, 1, "compile")
    check second.state == leaseStateQueued

    writeBudget(root / "runquotad.toml", 16, "[pools]\ncompile = 2\n")
    check daemon.reloadHostConfig().promotedLeases == 1'u32
    check daemon.leases[second.id.value].state == leaseStateGranted

    let third = daemon.offer(1, 1, "compile")
    check third.state == leaseStateQueued
    writeBudget(root / "runquotad.toml", 16)
    let answer = daemon.reloadHostConfig()
    check answer.pools.len == 0
    check not daemon.leases.hasKey(third.id.value)
    # The two granted `compile` leases keep running.
    check daemon.leases[first.id.value].state == leaseStateGranted
    check daemon.leases[second.id.value].state == leaseStateGranted

  test "a file that does not parse changes nothing":
    let root = scratch("broken")
    writeBudget(root / "runquotad.toml", 8)
    var daemon = testDaemon(root)
    writeFile(root / "runquotad.toml",
      "schema = \"runquota.host-config.v1\"\n[machine]\nmemory_bytes = 1.5\n")
    expect HostConfigError:
      discard daemon.reloadHostConfig()
    check daemon.local.memoryBytes.value == 8'u64 * GiB
    check daemon.config.memoryBytes.value == 8'u64 * GiB
    check daemon.hostConfigReloads == 0'u64

  test "removing the file returns to the built-in defaults":
    let root = scratch("removed")
    writeBudget(root / "runquotad.toml", 8)
    var daemon = testDaemon(root)
    removeFile(root / "runquotad.toml")
    let answer = daemon.reloadHostConfig()
    check answer.sourcePath == ""
    check answer.memoryBytes == 2'u64 * GiB
    check answer.cpuMilli == 4000'u32
    check daemon.config.hostConfigSource == ""

  test "a flag still wins after a reload, and the answer says so":
    let root = scratch("flags")
    writeBudget(root / "runquotad.toml", 8, "[pools]\ncompile = 2\n")
    var flags = BudgetFlags(memoryBytes: some(bytes(4'u64 * GiB)))
    flags.pools["compile"] = 5'u32
    var daemon = testDaemon(root, flags)
    check daemon.local.memoryBytes.value == 4'u64 * GiB
    check daemon.config.namedPoolCaps["compile"] == 5'u32

    writeBudget(root / "runquotad.toml", 32, "[pools]\ncompile = 3\n" &
      "fetch = 1\n")
    let answer = daemon.reloadHostConfig()
    check answer.memoryBytes == 4'u64 * GiB
    # The file's cpu_milli was not pinned, so it is in force.
    check answer.cpuMilli == 8000'u32
    check daemon.config.namedPoolCaps["compile"] == 5'u32
    check daemon.config.namedPoolCaps["fetch"] == 1'u32
    check answer.pinnedByFlags == @["machine.memory_bytes", "pools.compile"]
    check "pinned by runquotad flags" in reloadReport(answer)

  test "the CPU share group of the local machine follows its CPU budget":
    let root = scratch("cpu")
    writeBudget(root / "runquotad.toml", 8)
    var daemon = testDaemon(root)
    writeFile(root / "runquotad.toml",
      "schema = \"runquota.host-config.v1\"\n[machine]\ncpu_milli = 2000\n")
    discard daemon.reloadHostConfig()
    check daemon.local.cpuSlots.value == 2000'u32
    check daemon.config.cpuShareGroups[daemon.local.cpuShareGroup].cpuSlots.value ==
      2000'u32
    let wide = daemon.offer(1, 1)
    check wide.state == leaseStateGranted
    let three = daemon.offer(1, 1)
    check three.state == leaseStateGranted
    let over = daemon.offer(2, 1)
    check over.state == leaseStateQueued

for root in scratchRoots:
  try:
    removeDir(root)
  except CatchableError:
    discard
