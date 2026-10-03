## Pools a session declares (`DeclarePools`), and how they layer under the
## host file and the `runquotad` flags.
##
## WHY THIS EXISTS. A recipe's named pools used to reach the daemon only as
## `runquotad --pool NAME=UNITS` flags, passed by whichever reprobuild
## happened to start it. A flag pins its key for the daemon's whole life, so
## `runquota config set pools.compile 4` reloaded and changed nothing; and a
## daemon somebody else had started -- the installed service, or the one a
## previous build left running on Windows -- knew none of the pools the next
## build used, so its leases were refused (`lease request exceeds named-pool
## budget`). The decision (reprobuild-specs/RunQuota-Host-Configuration.md,
## "Pools a build declares"):
##
## * a declared pool is the BOTTOM layer: the host file overrides it, and a
##   flag overrides both;
## * `unset` of a pool in the file takes it back to the declared capacity;
## * two open sessions declaring one pool share the SMALLEST capacity;
## * a declaration leaves with its session, and a queued lease that can then
##   never be admitted is denied rather than left waiting.
##
## Revert `recomputePoolCaps` to "file, then flags" and the first case fails:
## the declared pool has no cap and the lease is impossible.
##
## NO MOCKS. A real `RunQuotaDaemon` object reads a real TOML file in a
## scratch directory; the admission procs are the ones `RequestLease` and
## `GrantNext` use. `tests/integration/t_runquota_config_reload.nim` drives
## the same through a real `runquotad`, the client library and `runquota
## config`.

import std/[os, strutils, tables, unittest]

import runquota_core
import runquota_daemon {.all.}
import runquota_daemon/host_config
import runquota_protocol

const GiB = 1024'u64 * 1024'u64 * 1024'u64

var scratchRoots: seq[string] = @[]

proc scratch(tag: string): string =
  result = getTempDir() / ("runquota-pools-" & tag & "-" &
    $getCurrentProcessId())
  removeDir(result)
  createDir(result)
  scratchRoots.add(result)

proc writePools(root: string; pools: string) =
  writeFile(root / "runquotad.toml",
    "schema = \"runquota.host-config.v1\"\n[pools]\n" & pools)

proc testDaemon(root: string; flags = BudgetFlags()): RunQuotaDaemon =
  var config = DaemonConfig(
    daemonId: 1'u64,
    cpuSlots: milliCpu(64000),
    memoryBytes: bytes(64'u64 * GiB),
    builtinCpuSlots: milliCpu(64000),
    builtinMemoryBytes: bytes(64'u64 * GiB),
    ioSlots: 64'u32,
    machines: initTable[string, MachineCapacity](),
    cpuShareGroups: initTable[string, CpuShareGroup](),
    namedPoolCaps: initTable[string, uint32](),
    version: "test",
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

proc poolDemand(pool: string; units = 1'u32): ResourceVector =
  result = resourceVector(milliCpu(100), bytes(GiB))
  result.namedPools.add(namedPoolDemand(pool, units))

proc admissible(daemon: RunQuotaDaemon; pool: string; units = 1'u32):
    tuple[ok: bool; reason: string] =
  ## What `RequestLease` asks first: could this ever be admitted?
  var reason = ""
  result.ok = daemon.possible(poolDemand(pool, units), reason)
  result.reason = reason

proc offer(daemon: var RunQuotaDaemon; session: uint64; pool: string):
    LeaseRow =
  let lease = daemon.createQueuedLease(sessionId(session),
    daemon.nextLeaseId, "offer", "", poolDemand(pool), priorityNormal,
    leasePurposeWork)
  discard daemon.tryPromoteQueued()
  daemon.leases[lease.id.value]

proc declare(daemon: var RunQuotaDaemon; session: uint64;
             pools: openArray[(string, uint32)]): PoolsDeclaredMessage =
  var wire: seq[NamedPoolCapWire] = @[]
  for (name, units) in pools:
    wire.add(NamedPoolCapWire(name: name, units: units))
  daemon.declarePools(sessionId(session), wire)

proc cap(daemon: RunQuotaDaemon; pool: string): uint32 =
  daemon.config.namedPoolCaps.getOrDefault(pool, 0'u32)

suite "pools a session declares":

  test "a declared pool is admitted where nothing else sizes it":
    let root = scratch("declared")
    var daemon = testDaemon(root)
    # No file, no flag: the pool does not exist, and a lease in it can
    # never be admitted -- the refusal reprobuild used to hit on a daemon
    # it had not started itself.
    check not daemon.admissible("nim_pty.pty-serial").ok
    check "named-pool budget: nim_pty.pty-serial" in
      daemon.admissible("nim_pty.pty-serial").reason
    let answer = daemon.declare(1, [("nim_pty.pty-serial", 1'u32)])
    check answer.pools.len == 1
    check answer.pools[0].name == "nim_pty.pty-serial"
    check answer.pools[0].declared == 1'u32
    check answer.pools[0].inForce == 1'u32
    check answer.pools[0].source == "declared"
    check daemon.admissible("nim_pty.pty-serial").ok
    # And it is a cap, not a hint: one unit, so a second lease waits.
    check daemon.offer(1, "nim_pty.pty-serial").state == leaseStateGranted
    check daemon.offer(1, "nim_pty.pty-serial").state == leaseStateQueued

  test "the host file overrides a declaration, and unset falls back to it":
    let root = scratch("file")
    writePools(root, "compile = 4\n")
    var daemon = testDaemon(root)
    let answer = daemon.declare(1, [("compile", 8'u32)])
    check answer.pools[0].declared == 8'u32
    check answer.pools[0].inForce == 4'u32
    check answer.pools[0].source == "host-file"
    check daemon.cap("compile") == 4'u32
    # `runquota config set pools.compile 6` + reload: the file still wins.
    writePools(root, "compile = 6\n")
    discard daemon.reloadHostConfig()
    check daemon.cap("compile") == 6'u32
    check daemon.config.poolCapSource("compile") == "host-file"
    # `runquota config unset pools.compile` + reload: back to what the open
    # session declared, not to "no such pool".
    writePools(root, "")
    discard daemon.reloadHostConfig()
    check daemon.cap("compile") == 8'u32
    check daemon.config.poolCapSource("compile") == "declared"
    # A reload pins nothing: nothing in the reply claims a flag.
    check daemon.reloadHostConfig().pinnedByFlags.len == 0

  test "a runquotad flag still overrides both":
    let root = scratch("flag")
    writePools(root, "compile = 4\n")
    var flags = BudgetFlags()
    flags.pools["compile"] = 2'u32
    var daemon = testDaemon(root, flags)
    let answer = daemon.declare(1, [("compile", 8'u32)])
    check answer.pools[0].inForce == 2'u32
    check answer.pools[0].source == "flag"
    check "pools.compile" in daemon.reloadHostConfig().pinnedByFlags

  test "two sessions share the smallest declaration, until it leaves":
    let root = scratch("smallest")
    var daemon = testDaemon(root)
    discard daemon.declare(1, [("serial", 1'u32)])
    let second = daemon.declare(2, [("serial", 3'u32)])
    check second.pools[0].declared == 3'u32
    check second.pools[0].inForce == 1'u32
    check daemon.offer(2, "serial").state == leaseStateGranted
    let waiting = daemon.offer(2, "serial")
    check waiting.state == leaseStateQueued
    # Session 1 closes: its declaration goes with it, the cap becomes
    # session 2's 3, and the queued lease is promoted at once.
    daemon.cleanupLostSession(sessionId(1'u64))
    check daemon.cap("serial") == 3'u32
    check daemon.leases[waiting.id.value].state == leaseStateGranted

  test "a pool whose only declarer left is gone; a lease queued in it is denied":
    let root = scratch("gone")
    var daemon = testDaemon(root)
    discard daemon.declare(1, [("serial", 1'u32)])
    check daemon.offer(1, "serial").state == leaseStateGranted
    # Session 2 never declared the pool but queued behind it.
    let stranded = daemon.offer(2, "serial")
    check stranded.state == leaseStateQueued
    daemon.cleanupLostSession(sessionId(1'u64))
    check daemon.cap("serial") == 0'u32
    check daemon.config.poolCapSource("serial") == ""
    check not daemon.leases.hasKey(stranded.id.value)
    let decisions = daemon.grantNextDecisions(sessionId(2'u64))
    check decisions.len == 1
    check decisions[0].kind == leaseDecisionDenied
    check "named-pool budget: serial" in decisions[0].diagnostic.message

  test "a session re-declaring a pool replaces its own figure":
    let root = scratch("redeclare")
    var daemon = testDaemon(root)
    discard daemon.declare(1, [("compile", 8'u32), ("fetch", 2'u32)])
    let answer = daemon.declare(1, [("compile", 16'u32)])
    check answer.pools.len == 1
    check daemon.cap("compile") == 16'u32
    # Merged, not replaced wholesale: `fetch` is still declared.
    check daemon.cap("fetch") == 2'u32

  test "the topology subject says where each cap comes from":
    let root = scratch("topology")
    writePools(root, "compile = 4\n")
    var daemon = testDaemon(root)
    discard daemon.declare(1, [("compile", 8'u32), ("serial", 1'u32)])
    let json = daemon.topologyJson()
    check "{\"name\":\"compile\",\"units\":4,\"source\":\"host-file\"}" in json
    check "{\"name\":\"serial\",\"units\":1,\"source\":\"declared\"}" in json

suite "the DeclarePools wire":

  test "DeclarePools and PoolsDeclared round-trip":
    let request = DeclarePoolsMessage(sessionId: sessionId(7'u64), pools: @[
      NamedPoolCapWire(name: "compile", units: 8'u32),
      NamedPoolCapWire(name: "nim_pty.pty-serial", units: 1'u32)])
    var decodedRequest: DeclarePoolsMessage
    check decodeDeclarePools(encodeDeclarePools(request), decodedRequest)
    check decodedRequest.sessionId.value == 7'u64
    check decodedRequest.pools.len == 2
    check decodedRequest.pools[1].name == "nim_pty.pty-serial"
    check decodedRequest.pools[1].units == 1'u32
    let answer = PoolsDeclaredMessage(promotedLeases: 3'u32, pools: @[
      DeclaredPoolWire(name: "compile", declared: 8'u32, inForce: 4'u32,
        source: "host-file")])
    var decodedAnswer: PoolsDeclaredMessage
    check decodePoolsDeclared(encodePoolsDeclared(answer), decodedAnswer)
    check decodedAnswer.promotedLeases == 3'u32
    check decodedAnswer.pools.len == 1
    check decodedAnswer.pools[0].inForce == 4'u32
    check decodedAnswer.pools[0].source == "host-file"
    # Trailing bytes are a malformed frame, not a longer message.
    check not decodeDeclarePools(encodeDeclarePools(request) & "x",
      decodedRequest)

  test "a daemon announces the minor that carries the message":
    check RqspProtocolMinor >= PoolDeclarationsMinor

for root in scratchRoots:
  removeDir(root)
