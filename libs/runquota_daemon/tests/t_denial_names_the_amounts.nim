## What a budget refusal says: the scope, the AMOUNT ASKED FOR, the BUDGET IN
## FORCE, and WHICH DAEMON refused
## (`reprobuild-pm/spec/RunQuota-Protocol-And-Client-Libraries.md`,
## §"What A Budget Refusal Says").
##
## `possible` has every one of those numbers in scope at the moment it builds
## the reason, and it used to print none of them:
##
##   $ runquota acquire --cpu 1000 --mem 34359738368 -- true
##   lease request exceeds machine memory budget: local
##
## Neither 32 GiB (asked for) nor 16 GiB (the budget) is there, so a reader
## cannot tell which side is wrong -- and the remedy depends entirely on that:
## lower the request, or raise the budget. Nor does anything name the daemon,
## and since ONE runquotad SERVES THE WHOLE HOST the one that refused is
## routinely another workspace's, holding a budget this workspace never set;
## establishing that took finding the process and reading its command line
## (`reprobuild-pm/issues/2026-09-24-runquota-denial-omits-the-amounts.md`).
##
## THE ASSERTIONS HERE COMPARE THE WHOLE REASON WITH `==`, on purpose. The
## amounts are a contract, not decoration: a `contains("budget")` would pass
## again the moment somebody drops them, which is the state this file exists
## to end. The texts are the specification's table, verbatim.
##
## NO MOCKS. A real `RunQuotaDaemon` object, built the way `runquotad` builds
## one, in a scratch directory of its own; admission is driven directly
## because none of these cases needs an endpoint. `t_host_config_reload.nim`
## drives the same object through a reload, and
## `tests/integration/t_runquota_config_reload.nim` through a real daemon.

import std/[os, tables, unittest]

import runquota_core
import runquota_daemon {.all.}
import runquota_protocol

const GiB = 1024'u64 * 1024'u64 * 1024'u64

# The daemon every case here claims to be: a pid and an executable path that
# could not have been read off this test process, so an assertion on them is
# an assertion that the DENIAL carried them rather than that something else
# recomputed them.
const
  TestDaemonId = 4242'u64
  TestDaemonPath = "/opt/other-workspace/runquota/build/bin/runquotad"
  TestDaemonSaysSo =
    "refused by runquotad pid 4242 at " &
    "/opt/other-workspace/runquota/build/bin/runquotad; one runquotad " &
    "serves the whole host, so this may be another workspace's daemon and " &
    "another workspace's budget -- `runquota topology --json` reports the " &
    "budget in force and where it came from"

var scratchRoots: seq[string] = @[]

proc scratch(tag: string): string =
  result = getTempDir() / ("runquota-denial-" & tag & "-" &
    $getCurrentProcessId())
  removeDir(result)
  createDir(result)
  scratchRoots.add(result)

proc testDaemon(tag: string; cpuMilli = 8000'u32;
                memoryBytes = 16'u64 * GiB; ioSlots = 1'u32;
                sharedCpuMilli = 0'u32;
                poolCaps: openArray[(string, uint32)] = [];
                daemonPath = TestDaemonPath): RunQuotaDaemon =
  ## A daemon holding exactly the budget one case needs: no host file, no
  ## flags, no learned estimates, and memory pressure reported unavailable so
  ## admission depends on the ledger alone and not on how busy this host is.
  let root = scratch(tag)
  var config = DaemonConfig(
    daemonId: TestDaemonId,
    daemonPath: daemonPath,
    cpuSlots: milliCpu(cpuMilli),
    memoryBytes: bytes(memoryBytes),
    ioSlots: ioSlots,
    machines: initTable[string, MachineCapacity](),
    cpuShareGroups: initTable[string, CpuShareGroup](),
    namedPoolCaps: initTable[string, uint32](),
    version: "test",
    pressureSource: pressureSourceUnavailable,
    estimateDbPath: root / "estimates.db",
    estimateQueueCapacity: 8,
    observationDbPath: root / "observations.db")
  for entry in poolCaps:
    config.namedPoolCaps[entry[0]] = entry[1]
  if sharedCpuMilli > 0'u32:
    # SET BEFORE `initDaemon`, which is what makes the shared-CPU branch
    # reachable at all: `normalizeTopology` invents a share group at the
    # machine's own size when none exists, and a request over a group that
    # wide is already over the MACHINE and refused one branch earlier. A
    # group narrower than its machine is the real shape -- several machines
    # pinned to one socket -- and the only one that reaches the branch.
    config.cpuShareGroups[DefaultMachineId] =
      cpuShareGroup(DefaultMachineId, milliCpu(sharedCpuMilli))
  initDaemon(config)

proc refusal(daemon: RunQuotaDaemon; resources: ResourceVector): string =
  ## The reason `possible` refuses `resources` with -- the
  ## `Diagnostic.message` every denial path builds from it. `doAssert` rather
  ## than `check`, because a case whose request was ADMITTED is asserting
  ## about a reason that was never produced, and continuing past that would
  ## compare two empty strings and pass.
  var reason = ""
  doAssert not daemon.possible(resources, reason),
    "the daemon admitted a request this case requires it to refuse"
  reason

proc asking(cpuMilli: uint32; memoryBytes: uint64): ResourceVector =
  resourceVector(milliCpu(cpuMilli), bytes(memoryBytes))

proc queued(daemon: var RunQuotaDaemon; session: uint64;
            memoryGiB: uint64): LeaseRow =
  ## A lease offered and decided the way `OfferCandidates` decides one.
  let lease = daemon.createQueuedLease(sessionId(session),
    daemon.nextLeaseId, "offer", "", asking(1000'u32, memoryGiB * GiB),
    priorityNormal, leasePurposeWork)
  discard daemon.tryPromoteQueued()
  daemon.leases[lease.id.value]

proc shrinkMemoryTo(daemon: var RunQuotaDaemon; memoryBytes: uint64) =
  ## The budget a reload would put in force, applied directly: these cases
  ## are about the DENIAL a shrink produces, and `t_host_config_reload.nim`
  ## already pins the reload that produces it.
  var local = daemon.config.machines[DefaultMachineId]
  local.memoryBytes = bytes(memoryBytes)
  daemon.config.machines[DefaultMachineId] = local
  daemon.config.memoryBytes = bytes(memoryBytes)

proc doomedByShrink(tag: string; because: string;
                    daemonPath = TestDaemonPath): Diagnostic =
  ## The denial a SHRINK produces, as its session's next `GrantNext` delivers
  ## it: a 16 GiB daemon holds 10 GiB and queues 12 GiB more, then the budget
  ## drops to 8 GiB and waiting for the queued lease could never end.
  ##
  ## This path is driven because it is the one that hands back a whole
  ## `Diagnostic` -- message and detail -- with no endpoint in the way. The
  ## `RequestLease` and `OfferCandidates` denials fill their detail from the
  ## same helper, and `tests/integration/t_runquota_config_reload.nim` sees
  ## those two through a real daemon.
  var daemon = testDaemon(tag, daemonPath = daemonPath)
  daemon.sessions[1'u64] = SessionRow(id: sessionId(1'u64), name: "one")
  let holder = daemon.queued(1, 10)
  doAssert holder.state == leaseStateGranted
  let doomed = daemon.queued(1, 12)
  doAssert doomed.state == leaseStateQueued,
    "the 12 GiB lease has to be WAITING for a shrink to doom it"
  daemon.shrinkMemoryTo(8'u64 * GiB)
  discard daemon.rebudgetQueuedLeases(because)
  for decision in daemon.grantNextDecisions(sessionId(1'u64)):
    if decision.leaseId.value == doomed.id.value:
      doAssert decision.kind == leaseDecisionDenied
      return decision.diagnostic
  doAssert false, "the doomed lease got no decision"

suite "a budget refusal names the amounts and the daemon":

  test "machine memory: the request and the budget, as `runquota config` spells them":
    # The issue's own command: 32 GiB asked of a 16 GiB daemon.
    var daemon = testDaemon("memory")
    check daemon.refusal(asking(1000'u32, 32'u64 * GiB)) ==
      "lease request exceeds machine memory budget: local " &
      "(requested 32 GiB, budget 16 GiB)"

  test "machine memory: a size no power of two divides is given in bytes":
    # `humanBytes` abbreviates only exact multiples, so nothing is rounded
    # away -- a reader comparing a request against a budget has to be able to
    # trust both figures to the byte.
    var daemon = testDaemon("memory-odd", memoryBytes = 17_000_000_000'u64)
    check daemon.refusal(asking(1000'u32, 34_359_738_369'u64)) ==
      "lease request exceeds machine memory budget: local " &
      "(requested 34359738369 bytes, budget 17000000000 bytes)"

  test "machine CPU: milli-CPU, the unit the flag takes":
    var daemon = testDaemon("cpu")
    check daemon.refusal(asking(12000'u32, 1'u64 * GiB)) ==
      "lease request exceeds machine CPU budget: local " &
      "(requested 12000m, budget 8000m)"

  test "shared CPU: the group's budget, not the machine's":
    var daemon = testDaemon("shared-cpu", sharedCpuMilli = 4000'u32)
    # 6000m fits the 8000m machine and not the 4000m group it shares, so the
    # reason has to be the GROUP's -- naming the machine's 8000m here would
    # send a reader to raise a budget that is not the one refusing.
    check daemon.refusal(asking(6000'u32, 1'u64 * GiB)) ==
      "lease request exceeds shared CPU budget: local " &
      "(requested 6000m, budget 4000m)"

  test "machine IO: slots, counted, and singular at one":
    # AN UNSIZED IO BUDGET IS THE ONLY SHAPE THAT REACHES THIS BRANCH:
    # `ioSlots` maps an exclusive request to the cap ITSELF and a heavy one
    # to a single slot, so the demand can only exceed a cap of zero -- a
    # machine with no IO budget at all. The reason has to say that it is
    # zero, or the reader cannot tell this from a request that was too big.
    var daemon = testDaemon("io", ioSlots = 0'u32)
    var heavy = asking(1000'u32, 1'u64 * GiB)
    heavy.ioClass = ioHeavy
    check daemon.refusal(heavy) ==
      "lease request exceeds machine IO budget: local " &
      "(requested 1 slot, budget 0 slots)"

  test "named pool: the units asked of it and the units it has":
    var daemon = testDaemon("pool", poolCaps = [("compile", 1'u32)])
    check daemon.refusal(asking(1000'u32, 1'u64 * GiB)
      .withNamedPool("compile", 4'u32)) ==
      "lease request exceeds named-pool budget: compile " &
      "(requested 4 units, budget 1 unit)"

  test "named pool: one nothing sizes says so, instead of `budget 0 units`":
    # A pool at cap 0 is one that NEITHER the host file's `[pools]`, NOR a
    # `--pool` flag, NOR an open session's declaration names, and the remedy
    # is to name it in one of the three. `budget 0 units` would read as a
    # budget somebody deliberately set to zero and send the reader to edit a
    # number that does not exist.
    var daemon = testDaemon("pool-unsized")
    check daemon.refusal(asking(1000'u32, 1'u64 * GiB)
      .withNamedPool("compile", 4'u32)) ==
      "lease request exceeds named-pool budget: compile " &
      "(requested 4 units, no layer sizes this pool)"

  test "named pool: zero demand names the pool it came from":
    # The loop walks every pool the request declares, so a reason that named
    # none of them leaves the reader unable to tell which demand is at fault.
    var daemon = testDaemon("pool-zero", poolCaps = [("compile", 2'u32),
      ("fetch", 2'u32)])
    check daemon.refusal(asking(1000'u32, 1'u64 * GiB)
      .withNamedPool("compile", 1'u32)
      .withNamedPool("fetch", 0'u32)) ==
      "named-pool demand must be non-zero: fetch"

  test "a reservation left at zero says what it asked for":
    var daemon = testDaemon("zero")
    check daemon.refusal(asking(0'u32, 0'u64)) ==
      "lease request must reserve CPU and memory " &
      "(requested 0m CPU and 0 bytes)"

  test "a reservation with one side at zero says which side":
    # Both halves are printed rather than only the missing one: a client that
    # asked for CPU and forgot memory has to see that its CPU figure did
    # arrive, or the obvious reading is that the whole request was lost.
    var daemon = testDaemon("zero-memory")
    check daemon.refusal(asking(1000'u32, 0'u64)) ==
      "lease request must reserve CPU and memory " &
      "(requested 1000m CPU and 0 bytes)"

  test "the denial's detail names the daemon that refused, by pid and path":
    # THE DENIAL CARRIES IT, which is the claim: the pid and the path here
    # are this daemon's config, and no client could have derived either from
    # its own process.
    check doomedByShrink("detail", "host budget reloaded").detail ==
      "host budget reloaded; " & TestDaemonSaysSo

  test "a daemon whose own path is unknown still names its pid":
    # A DIAGNOSTIC MUST NEVER BE THE THING THAT FAILS. `getAppFilename` can
    # refuse on a platform RunQuota supports, and an empty path then drops
    # one clause rather than the whole denial.
    check doomedByShrink("detail-no-path", "host budget reloaded",
        daemonPath = "").detail ==
      "host budget reloaded; " &
      "refused by runquotad pid 4242; one runquotad serves the whole host, " &
      "so this may be another workspace's daemon and another workspace's " &
      "budget -- `runquota topology --json` reports the budget in force and " &
      "where it came from"

  test "a shrink that dooms a queued lease keeps its cause AND names the daemon":
    # The two facts answer different questions -- WHY NOW (the budget changed
    # under it) and WHO (which daemon holds that budget) -- so the daemon's
    # identity is appended to the cause rather than replacing it.
    let denial = doomedByShrink("rebudget",
      "host configuration reloaded: memory_bytes 16 GiB -> 8 GiB")
    # The reason is the one a FRESH request of that size would get, amounts
    # and all, measured against the budget now in force.
    check denial.message ==
      "lease request exceeds machine memory budget: local " &
      "(requested 12 GiB, budget 8 GiB)"
    check denial.detail ==
      "host configuration reloaded: memory_bytes 16 GiB -> 8 GiB; " &
      TestDaemonSaysSo

  test "a request that fits is still admitted with no reason at all":
    # The guard against a fix that formats its way into refusing everything.
    var daemon = testDaemon("admitted")
    var reason = "untouched"
    check daemon.possible(asking(1000'u32, 1'u64 * GiB), reason)
    check reason == "untouched"

for root in scratchRoots:
  try:
    removeDir(root)
  except CatchableError:
    discard
