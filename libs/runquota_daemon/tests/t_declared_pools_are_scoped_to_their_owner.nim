## A pool a session declares (`DeclarePools`) belongs to the principal that
## declared it -- the owner the daemon reads from peer credentials -- unless
## the host file's `[pools]` or a `runquotad --pool` flag names it, in which
## case it is one host-wide pool (reprobuild-specs/RunQuota-Host-Configuration.md,
## "Pools a build declares").
##
## WHY THIS EXISTS. Until this test, a declared pool was one host-global name,
## capped at the smallest capacity any open session on the host declared. On
## the host-wide daemon that meant (reprobuild-pm issue
## `2026-11-12-declared-pools-are-one-host-global-namespace-that-any-session-can-shrink.md`):
##
## * any user who declared `compile = 1` throttled every other user's
##   `compile` leases;
## * unrelated recipes of two users that both named a pool `serial`
##   serialised against each other;
## * a declaration below another user's queued demand got that user's lease
##   denied permanently.
##
## Each of the first three cases below is one of those, and each failed on
## runquota `fca17597` for exactly that reason. The last three hold what must
## NOT change: one user's sessions still share the smallest figure (the
## out-of-process helper path declares on a session per action, so a
## per-session scope would make `serial = 1` serialise nothing), a pool the
## operator names stays one host-wide pool, and the answers say whose cap
## they report.
##
## NO MOCKS. A real `RunQuotaDaemon` object reads a real TOML file in a
## scratch directory, and the admission procs are the ones `RequestLease`,
## `DeclarePools` and `GrantNext` use. The only thing constructed by hand is
## each session's `PeerIdentity`, which in the daemon comes from
## `SO_PEERCRED` / the pipe client's token: a test process cannot connect as
## two different uids without root, and the owner key the daemon derives
## from that identity (`ownerKeyOf`) is the production one.

import std/[os, strutils, tables, unittest]

import runquota_core
import runquota_daemon {.all.}
import runquota_daemon/host_config
import runquota_ipc
import runquota_protocol

const GiB = 1024'u64 * 1024'u64 * 1024'u64

const
  alice = 1001'u64
  bob = 1002'u64

var scratchRoots: seq[string] = @[]

proc scratch(tag: string): string =
  result = getTempDir() / ("runquota-pool-owner-" & tag & "-" &
    $getCurrentProcessId())
  removeDir(result)
  createDir(result)
  scratchRoots.add(result)

proc writePools(root: string; pools: string) =
  writeFile(root / "runquotad.toml",
    "schema = \"runquota.host-config.v1\"\n[pools]\n" & pools)

proc userPeer(uid: uint64): PeerIdentity =
  PeerIdentity(kind: peerIdentityUser, processId: 4242'u64, userId: uid,
    groupId: uid)

proc testDaemon(root: string): RunQuotaDaemon =
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
    hostConfigPath: root / "runquotad.toml")
  let host = readHostConfig(config.hostConfigPath)
  config.resolveBudget(host)
  config.hostConfigSource = host.sourcePath
  result = initDaemon(config)
  # Sessions 1 and 3 are alice's (two builds of one user, or a build and
  # its helper's session); session 2 is bob's.
  result.sessions[1'u64] = SessionRow(id: sessionId(1'u64), name: "alice-1",
    peer: userPeer(alice))
  result.sessions[2'u64] = SessionRow(id: sessionId(2'u64), name: "bob",
    peer: userPeer(bob))
  result.sessions[3'u64] = SessionRow(id: sessionId(3'u64), name: "alice-2",
    peer: userPeer(alice))

proc poolDemand(pool: string; units = 1'u32): ResourceVector =
  result = resourceVector(milliCpu(100), bytes(GiB))
  result.namedPools.add(namedPoolDemand(pool, units))

proc offer(daemon: var RunQuotaDaemon; session: uint64; pool: string;
           units = 1'u32): LeaseRow =
  let lease = daemon.createQueuedLease(sessionId(session),
    daemon.nextLeaseId, "offer", "", poolDemand(pool, units), priorityNormal,
    leasePurposeWork)
  discard daemon.tryPromoteQueued()
  daemon.leases[lease.id.value]

proc stateOf(daemon: RunQuotaDaemon; lease: LeaseRow): string =
  ## The lease's state now, or `gone` once the daemon has dropped it (a
  ## denial removes a queued lease from the table).
  if daemon.leases.hasKey(lease.id.value): $daemon.leases[lease.id.value].state
  else: "gone"

proc declare(daemon: var RunQuotaDaemon; session: uint64;
             pools: openArray[(string, uint32)]): PoolsDeclaredMessage =
  var wire: seq[NamedPoolCapWire] = @[]
  for (name, units) in pools:
    wire.add(NamedPoolCapWire(name: name, units: units))
  daemon.declarePools(sessionId(session), wire)

suite "a declared pool is scoped to the principal that declared it":

  test "another user's smaller declaration does not shrink mine":
    let root = scratch("shrink")
    var daemon = testDaemon(root)
    discard daemon.declare(1, [("compile", 4'u32)])
    let bobs = daemon.declare(2, [("compile", 1'u32)])
    check bobs.pools[0].inForce == 1'u32
    # Alice declared four: four of her compile leases run at once, whatever
    # bob's build declared for his own.
    for i in 1 .. 4:
      let lease = daemon.offer(1, "compile")
      checkpoint "alice's compile lease " & $i & " is " & $lease.state
      check lease.state == leaseStateGranted
    # And bob's one unit is his: he is not starved by alice's four.
    check daemon.offer(2, "compile").state == leaseStateGranted
    check daemon.offer(2, "compile").state == leaseStateQueued

  test "two users' pools of one name do not serialise against each other":
    let root = scratch("serial")
    var daemon = testDaemon(root)
    discard daemon.declare(1, [("serial", 1'u32)])
    discard daemon.declare(2, [("serial", 1'u32)])
    check daemon.offer(1, "serial").state == leaseStateGranted
    let bobsLease = daemon.offer(2, "serial")
    checkpoint "bob's serial lease is " & $bobsLease.state &
      " while alice holds her own serial"
    check bobsLease.state == leaseStateGranted
    # Each still means "never two at once" for its own user.
    check daemon.offer(1, "serial").state == leaseStateQueued
    check daemon.offer(2, "serial").state == leaseStateQueued

  test "another user's declaration cannot strand my queued lease":
    let root = scratch("strand")
    var daemon = testDaemon(root)
    discard daemon.declare(1, [("wide", 2'u32)])
    check daemon.offer(1, "wide", 2'u32).state == leaseStateGranted
    let waiting = daemon.offer(1, "wide", 2'u32)
    check waiting.state == leaseStateQueued
    discard daemon.declare(2, [("wide", 1'u32)])
    checkpoint "after bob declared wide = 1, alice's queued lease is " &
      daemon.stateOf(waiting)
    check daemon.stateOf(waiting) == $leaseStateQueued
    let decisions = daemon.grantNextDecisions(sessionId(1'u64))
    for decision in decisions:
      checkpoint "alice was told: " & $decision.kind & " " &
        decision.diagnostic.message
      check decision.kind != leaseDecisionDenied
    # Bob leaving changes nothing for alice either.
    daemon.cleanupLostSession(sessionId(2'u64))
    check daemon.stateOf(waiting) == $leaseStateQueued

  test "one user's sessions still share the smallest declaration":
    let root = scratch("same-owner")
    var daemon = testDaemon(root)
    discard daemon.declare(1, [("serial", 1'u32)])
    let second = daemon.declare(3, [("serial", 3'u32)])
    check second.pools[0].declared == 3'u32
    check second.pools[0].inForce == 1'u32
    check daemon.offer(3, "serial").state == leaseStateGranted
    let waiting = daemon.offer(3, "serial")
    check waiting.state == leaseStateQueued
    # Bob's declaration of the same name is no part of alice's cap.
    discard daemon.declare(2, [("serial", 5'u32)])
    check daemon.stateOf(waiting) == $leaseStateQueued
    # Session 1 leaves (it holds no lease): alice's cap becomes session 3's
    # figure, and her queued lease is promoted.
    daemon.cleanupLostSession(sessionId(1'u64))
    check daemon.stateOf(waiting) == $leaseStateGranted

  test "a pool the host file names is one pool for every user":
    let root = scratch("host-file")
    writePools(root, "gpu = 1\n")
    var daemon = testDaemon(root)
    let alices = daemon.declare(1, [("gpu", 4'u32)])
    check alices.pools[0].inForce == 1'u32
    check alices.pools[0].source == "host-file"
    discard daemon.declare(2, [("gpu", 4'u32)])
    check daemon.offer(1, "gpu").state == leaseStateGranted
    let bobsLease = daemon.offer(2, "gpu")
    check bobsLease.state == leaseStateQueued
    # `runquota config unset pools.gpu` + reload: each user is back to the
    # figure they declared, separately. Bob's queued lease now fits his own
    # pool, which alice's running lease does not occupy.
    writePools(root, "")
    discard daemon.reloadHostConfig()
    check daemon.stateOf(bobsLease) == $leaseStateGranted
    check daemon.offer(1, "gpu").state == leaseStateGranted
    # And the other way: naming it in the file makes it host-wide again.
    # Alice's two and bob's one running leases all count against the file's
    # figure, so nothing more is admitted until they finish.
    writePools(root, "gpu = 3\n")
    discard daemon.reloadHostConfig()
    check daemon.offer(2, "gpu").state == leaseStateQueued

  test "the answers say whose declared cap they report":
    let root = scratch("answers")
    var daemon = testDaemon(root)
    discard daemon.declare(1, [("serial", 2'u32)])
    let bobs = daemon.declare(2, [("serial", 1'u32)])
    check bobs.pools[0].inForce == 1'u32
    check bobs.pools[0].source == "declared"
    let alices = daemon.declare(3, [("serial", 2'u32)])
    check alices.pools[0].inForce == 2'u32
    let json = daemon.topologyJson()
    check ("{\"name\":\"serial\",\"units\":2,\"source\":\"declared\"," &
      "\"owner\":\"" & $alice & "\"}") in json
    check ("{\"name\":\"serial\",\"units\":1,\"source\":\"declared\"," &
      "\"owner\":\"" & $bob & "\"}") in json
    # A reload answers with the pools in force for the owner who asked:
    # alice sees her own `serial = 2`, never bob's figure, and an owner
    # that declared nothing sees no declared pool at all.
    let alicesReload = daemon.reloadHostConfig($alice)
    check alicesReload.pools.len == 1
    check alicesReload.pools[0].name == "serial"
    check alicesReload.pools[0].units == 2'u32
    check daemon.reloadHostConfig($bob).pools[0].units == 1'u32
    check daemon.reloadHostConfig("1003").pools.len == 0

for root in scratchRoots:
  removeDir(root)
