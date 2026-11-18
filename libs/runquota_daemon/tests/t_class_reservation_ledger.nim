## Class reservations and the oversubscription target, on the daemon's own
## ledger: which grants the admission pass makes, and which it refuses to
## make, when the host file reserves capacity for a class of work or lets
## CPU grants exceed the budget.
##
## The rules pinned here (the admission policy's classes, reservations and
## oversubscription target; `docs/book-isonim/content/usage_guide/daemon.md`
## describes them for operators):
##
## * with no reservation and no target, admission is what it always was;
## * CPU grants sum to at most the budget x (1 + target), memory grants to
##   at most the memory budget, whatever the target;
## * work outside a class never takes the class's reserved memory, whether
##   or not the class is busy (memory is never lent);
## * a class that lends gives its idle reserved CPU to other work, and while
##   it has a request waiting every CPU freed up to its reservation is held
##   for it and granted to it first -- nothing is revoked;
## * a class that does not lend keeps its reserved CPU from other work;
## * the reserved pass runs before the order, so a starved request of other
##   work that is being held for does not stand between a class and its
##   reservation;
## * a class never holds more than its reservation plus what it borrowed,
##   and it borrows only what another class's reservation does not protect;
## * a request that other classes' reservations leave no room for, ever, is
##   refused with the figures;
## * a reload that shrinks a reservation or the target revokes nothing;
## * a registered VM's memory counts against its group's class.
##
## Each case names the change to the daemon that makes it fail. The same
## rules through a real `runquotad` and real clients are
## `tests/integration/t_class_reservations` (the end-to-end cases).
##
## NO MOCKS: a real `RunQuotaDaemon` object; leases are made and released
## through the daemon's own procedures, as its request handlers do.

import std/[os, posix, strutils, tables, unittest]

import runquota_core
import runquota_ipc
import runquota_protocol
import runquota_daemon {.all.}
import runquota_daemon/host_config

const
  GiB = 1024'u64 * 1024'u64 * 1024'u64
  Cpu = 1000'u32

var scratchRoots: seq[string] = @[]

proc reservation(cpu: uint64; memory = 0'u64; lend = true): ClassReservation =
  ClassReservation(cpuMilli: cpu, memoryBytes: memory, lend: lend)

proc testDaemon(tag: string; cpuMilli = 4000'u32; memory = 8'u64 * GiB;
                reservations: openArray[(string, ClassReservation)] = [];
                oversubscriptionPermille = 0'u32;
                maxWaitMillis = 120_000'i64): RunQuotaDaemon =
  let root = getTempDir() / ("runquota-classes-" & tag & "-" &
    $getCurrentProcessId())
  removeDir(root)
  createDir(root)
  scratchRoots.add(root)
  var table = initOrderedTable[string, ClassReservation]()
  for (name, r) in reservations:
    table[name] = r
  initDaemon(DaemonConfig(
    daemonId: 1'u64,
    cpuSlots: milliCpu(cpuMilli),
    memoryBytes: bytes(memory),
    ioSlots: 64'u32,
    machines: initTable[string, MachineCapacity](),
    cpuShareGroups: initTable[string, CpuShareGroup](),
    namedPoolCaps: initTable[string, uint32](),
    version: "test",
    pressureSource: pressureSourceUnavailable,
    estimateDbPath: root / "estimates.db",
    estimateQueueCapacity: 8,
    observationDbPath: root / "observations.db",
    admissionMaxWaitMillis: maxWaitMillis,
    reservations: table,
    oversubscriptionPermille: oversubscriptionPermille))

proc session(daemon: var RunQuotaDaemon; id: uint64; group: string;
             className = ""): SessionId =
  ## A session in `group` (of class `className` when it creates the group),
  ## placed the way `RegisterSession` places one.
  let key = daemon.joinSessionGroup(PeerIdentity(),
    SessionGroupDeclaration(name: group, priority: sessionPriorityNormal,
      className: className))
  daemon.sessions[id] = SessionRow(id: sessionId(id), name: group,
    groupKey: key)
  sessionId(id)

proc ask(daemon: var RunQuotaDaemon; session: SessionId; cpu: uint32;
         memory = 128'u64 * 1024'u64 * 1024'u64): uint64 =
  ## Queue one request and run the admission pass, as a request handler
  ## does. Returns the lease id.
  var reason = ""
  let resources = resourceVector(milliCpu(cpu), bytes(memory))
  doAssert daemon.possible(resources, "?", reason,
    daemon.sessionClass(session)), reason
  let lease = daemon.createQueuedLease(session, 1'u64, "t", "", resources,
    priorityNormal, leasePurposeWork)
  discard daemon.tryPromoteQueued()
  lease.id.value

proc granted(daemon: RunQuotaDaemon; id: uint64): bool =
  daemon.leases.hasKey(id) and daemon.leases[id].state.isResourceActive

proc release(daemon: var RunQuotaDaemon; id: uint64) =
  daemon.releaseLease(leaseId(id))

proc heldCpu(daemon: RunQuotaDaemon): uint32 =
  daemon.machineUsage.getOrDefault(DefaultMachineId, MachineUsage()).cpu

proc heldMemory(daemon: RunQuotaDaemon): uint64 =
  daemon.machineUsage.getOrDefault(DefaultMachineId, MachineUsage()).memory

proc classHeld(daemon: RunQuotaDaemon; name: string): MachineUsage =
  daemon.classUsage.getOrDefault(name, MachineUsage())

proc countGranted(daemon: RunQuotaDaemon; ids: openArray[uint64]): int =
  for id in ids:
    if daemon.granted(id): inc result

suite "defaults":
  test "no reservation and no target admit exactly the budget":
    # Mutation: an oversubscription default above 0, or a protected share
    # without a reservation, changes how much fits.
    var daemon = testDaemon("defaults")
    let s = daemon.session(1, "a")
    var ids: seq[uint64]
    for _ in 0 ..< 5:
      ids.add(daemon.ask(s, Cpu))
    check daemon.countGranted(ids) == 4
    check daemon.heldCpu() == 4000'u32
    check daemon.config.reservations.len == 0
    check daemon.oversubscribed(4000) == 4000'u32

suite "the oversubscription target":
  test "CPU grants reach the budget x (1 + target) and no further":
    # Mutation: ignoring the target grants 4 of 8; scaling the memory budget
    # too lets the memory request below fit.
    var daemon = testDaemon("oversub", oversubscriptionPermille = 500)
    let s = daemon.session(1, "a")
    var ids: seq[uint64]
    for _ in 0 ..< 8:
      ids.add(daemon.ask(s, Cpu, 512'u64 * 1024'u64 * 1024'u64))
    check daemon.countGranted(ids) == 6
    check daemon.heldCpu() == 6000'u32
    # Memory is never oversubscribed: 6 x 512 MiB held of 8 GiB, so a
    # request of 5.5 GiB does not fit although CPU would.
    let s2 = daemon.session(2, "b")
    for id in ids[0 ..< 6]:
      daemon.release(id)
    check daemon.heldCpu() == 2000'u32
    let big = daemon.ask(s2, Cpu, 7'u64 * GiB)
    check daemon.granted(big)
    let more = daemon.ask(s2, Cpu, 2'u64 * GiB)
    check not daemon.granted(more)
    check daemon.heldMemory() <= 8'u64 * GiB

  test "a single lease is never wider than the budget itself":
    var daemon = testDaemon("wide", oversubscriptionPermille = 1000)
    discard daemon.session(1, "a")
    var reason = ""
    check not daemon.possible(resourceVector(milliCpu(5000), bytes(GiB)), "?",
      reason)
    check "exceeds machine CPU budget" in reason

suite "reserved memory":
  test "work outside the class never takes the class's reserved memory":
    # Mutation: lending memory like CPU (protecting it only while the class
    # waits) grants the unclassed request the reserved 4 GiB.
    var daemon = testDaemon("memory", reservations = [("ci",
      reservation(1000, 4'u64 * GiB))])
    let other = daemon.session(1, "other")
    let first = daemon.ask(other, Cpu, 4'u64 * GiB)
    check daemon.granted(first)
    let second = daemon.ask(other, Cpu, 1'u64 * GiB)
    # 4 GiB held, 4 GiB reserved and idle: nothing more fits the others.
    check not daemon.granted(second)
    check daemon.heldMemory() == 4'u64 * GiB
    # The class itself gets its memory at once.
    let ci = daemon.session(2, "job", "ci")
    let job = daemon.ask(ci, Cpu, 4'u64 * GiB)
    check daemon.granted(job)

  test "a request the reservations leave no memory for is refused":
    var daemon = testDaemon("memory-refusal", reservations = [("ci",
      reservation(0, 6'u64 * GiB))])
    var reason = ""
    check not daemon.possible(resourceVector(milliCpu(Cpu), bytes(3'u64 * GiB)),
      "?", reason, "")
    check "reserved for other classes" in reason
    check "requested 3 GiB" in reason
    # The class itself may ask for it.
    check daemon.possible(resourceVector(milliCpu(Cpu), bytes(3'u64 * GiB)),
      "?", reason, "ci")

suite "reserved CPU":
  test "a class that does not lend keeps its CPU from other work":
    # Mutation: `protectedFrom` ignoring `lend` (treating every class as
    # lending) grants the other group all four CPUs.
    var daemon = testDaemon("nolend", reservations = [("ci",
      reservation(2000, lend = false))])
    let other = daemon.session(1, "other")
    var ids: seq[uint64]
    for _ in 0 ..< 4:
      ids.add(daemon.ask(other, Cpu))
    check daemon.countGranted(ids) == 2
    let ci = daemon.session(2, "job", "ci")
    let a = daemon.ask(ci, Cpu)
    let b = daemon.ask(ci, Cpu)
    check daemon.granted(a)
    check daemon.granted(b)

  test "an idle lending class's CPU is lent, and comes back as leases finish":
    # Mutation: admitting the class only from what is left after the order
    # (no reserved pass, no protection) hands every freed CPU to the other
    # group's earlier requests, and the class waits for all of them.
    var daemon = testDaemon("lend", reservations = [("ci",
      reservation(2000))])
    let other = daemon.session(1, "other")
    var running: seq[uint64]
    for _ in 0 ..< 4:
      running.add(daemon.ask(other, Cpu))
    check daemon.countGranted(running) == 4
    # The other group wants more still, and asked first.
    var behind: seq[uint64]
    for _ in 0 ..< 4:
      behind.add(daemon.ask(other, Cpu))
    check daemon.countGranted(behind) == 0
    let ci = daemon.session(2, "job", "ci")
    let a = daemon.ask(ci, Cpu)
    let b = daemon.ask(ci, Cpu)
    check not daemon.granted(a)
    check not daemon.granted(b)
    # Nothing is revoked.
    check daemon.countGranted(running) == 4
    # Each lease that finishes gives its CPU to the class, in that pass.
    daemon.release(running[0])
    check daemon.granted(a)
    check daemon.countGranted(behind) == 0
    daemon.release(running[1])
    check daemon.granted(b)
    check daemon.countGranted(behind) == 0
    check daemon.classHeld("ci").cpu == 2000'u32
    # Beyond its reservation the class borrows like anyone: the next freed
    # CPU goes in the ordinary order, to the request that came first.
    daemon.release(running[2])
    check daemon.countGranted(behind) == 1

  test "a starved request being held for does not block the reservation":
    # Mutation: running the reserved requests in the ordinary order (no
    # reserved pass) leaves the class behind the held request: nothing
    # behind a held request is granted in its pass.
    var daemon = testDaemon("starved", reservations = [("ci",
      reservation(1000))], maxWaitMillis = 1)
    let other = daemon.session(1, "other")
    var running: seq[uint64]
    for _ in 0 ..< 3:
      running.add(daemon.ask(other, Cpu))
    # A two-CPU request of other work that will be starved and held for.
    let wide = daemon.ask(other, 2 * Cpu)
    check not daemon.granted(wide)
    discard usleep(5_000)
    let ci = daemon.session(2, "job", "ci")
    let job = daemon.ask(ci, Cpu)
    check daemon.granted(job)

  test "other work's starvation bound still holds beside a class":
    # The reserved pass serves only a reserved class's own requests; the
    # starvation hold of other work is untouched by it. Mutation: putting
    # every queued request in the reserved pass (not only those of a class
    # with a reservation) grants the later one-CPU request of other work
    # past the starved two-CPU one it should wait behind.
    var daemon = testDaemon("starved-other", reservations = [("ci",
      reservation(1000, lend = false))], maxWaitMillis = 1)
    let other = daemon.session(1, "other")
    var running: seq[uint64]
    for _ in 0 ..< 3:
      running.add(daemon.ask(other, Cpu))
    check daemon.countGranted(running) == 3
    let wide = daemon.ask(other, 2 * Cpu)
    check not daemon.granted(wide)
    discard usleep(5_000)
    let late = daemon.session(2, "late")
    let small = daemon.ask(late, Cpu)
    check not daemon.granted(small)
    # One CPU frees: it would fit the later request, but the starved one is
    # held for, so nothing of other work behind it is granted.
    daemon.release(running[0])
    check not daemon.granted(wide)
    check not daemon.granted(small)
    # The class's reserved CPU is its own, held request or not.
    let ci = daemon.session(3, "job", "ci")
    let job = daemon.ask(ci, Cpu)
    check daemon.granted(job)
    check not daemon.granted(small)
    # The next CPU makes room for the starved request, which goes first.
    daemon.release(running[1])
    check daemon.granted(wide)
    check not daemon.granted(small)

  test "a class never holds more than its reservation plus what it borrowed":
    # Mutation: protecting another class's CPU only from unclassed work
    # (not from a class) lets `ci` take `gpu`'s reserved CPU.
    var daemon = testDaemon("borrow", reservations = [
      ("ci", reservation(1000, 1'u64 * GiB)),
      ("gpu", reservation(1000, 1'u64 * GiB, lend = false))])
    let ci = daemon.session(1, "job", "ci")
    var ids: seq[uint64]
    for _ in 0 ..< 4:
      ids.add(daemon.ask(ci, Cpu, 512'u64 * 1024'u64 * 1024'u64))
    check daemon.countGranted(ids) == 3
    let held = daemon.classHeld("ci")
    check held.cpu == 3000'u32
    # Its reservation (1000m) plus what it borrowed (2000m): the budget less
    # the other class's reservation, never more.
    check held.cpu <= 4000'u32 - 1000'u32
    # Memory too: the other class's reserved gigabyte is never reachable.
    var reason = ""
    check not daemon.possible(resourceVector(milliCpu(Cpu),
      bytes(7'u64 * GiB + GiB div 2)), "?", reason, "ci")
    check daemon.possible(resourceVector(milliCpu(Cpu), bytes(7'u64 * GiB)),
      "?", reason, "ci")

  test "reservations that do not fit the budget are refused":
    var table = initOrderedTable[string, ClassReservation]()
    table["ci"] = reservation(3000)
    table["gpu"] = reservation(2000)
    let problem = reservationProblem(table, milliCpu(4000), bytes(8'u64 * GiB))
    check "5000m CPU in all" in problem
    check "above the CPU budget of 4000m" in problem
    table["gpu"] = reservation(1000, 9'u64 * GiB)
    check "memory is never oversubscribed" in
      reservationProblem(table, milliCpu(4000), bytes(8'u64 * GiB))
    table["gpu"] = reservation(1000, 4'u64 * GiB)
    check reservationProblem(table, milliCpu(4000), bytes(8'u64 * GiB)) == ""
    # Figures whose sum does not fit 64 bits are refused, not wrapped round
    # to a small total. Mutation: summing without saturating passes these.
    table["ci"] = reservation(1000, high(uint64))
    table["gpu"] = reservation(1000, 2'u64)
    check "memory is never oversubscribed" in
      reservationProblem(table, milliCpu(4000), bytes(8'u64 * GiB))
    table["ci"] = reservation(high(uint64), 0)
    table["gpu"] = reservation(2'u64, 0)
    check "above the CPU budget" in
      reservationProblem(table, milliCpu(4000), bytes(8'u64 * GiB))

suite "reload":
  test "shrinking a reservation and the target revokes nothing":
    # Mutation: re-checking granted leases against the new limits (revoking
    # what no longer fits) drops leases here.
    var daemon = testDaemon("reload", reservations = [("ci",
      reservation(2000, lend = false))], oversubscriptionPermille = 500)
    let ci = daemon.session(1, "job", "ci")
    let other = daemon.session(2, "other")
    var all: seq[uint64]
    for _ in 0 ..< 2:
      all.add(daemon.ask(ci, Cpu))
    for _ in 0 ..< 4:
      all.add(daemon.ask(other, Cpu))
    check daemon.countGranted(all) == 6
    var next = daemon.config
    next.oversubscriptionPermille = 0
    next.reservations = initOrderedTable[string, ClassReservation]()
    daemon.config = next
    discard daemon.tryPromoteQueued()
    check daemon.countGranted(all) == 6
    check daemon.heldCpu() == 6000'u32
    # Above the new limit, so nothing more is granted until leases end.
    let more = daemon.ask(other, Cpu)
    check not daemon.granted(more)

suite "virtual machines and sub-leases":
  test "a registered VM's memory counts against its class":
    var daemon = testDaemon("vm", reservations = [("ci",
      reservation(2000, 4'u64 * GiB))])
    let ci = daemon.session(1, "pool", "ci")
    let vm = daemon.createQueuedLease(ci, 1'u64, "vm", "",
      resourceVector(milliCpu(2000), bytes(3'u64 * GiB)), priorityNormal,
      leasePurposeWork)
    daemon.virtualMachines[vm.id.value] = VirtualMachineRow(
      leaseId: vm.id.value, name: "vm", shapeCpuMilli: 2000,
      memoryBytes: 3'u64 * GiB)
    discard daemon.tryPromoteQueued()
    check daemon.granted(vm.id.value)
    check daemon.classHeld("ci").memory == 3'u64 * GiB
    check daemon.classHeld("ci").cpu == 2000'u32
    # One GiB of the reservation is left, and work outside the class still
    # cannot have it.
    let other = daemon.session(2, "other")
    let take = daemon.ask(other, Cpu, 4'u64 * GiB)
    check daemon.granted(take)
    let more = daemon.ask(other, Cpu, 1'u64 * GiB)
    check not daemon.granted(more)

  test "a session that names a class and no group joins the class's group":
    var daemon = testDaemon("classgroup")
    let s = daemon.session(1, "", "ci")
    let key = daemon.sessions[1'u64].groupKey
    check daemon.sessionGroups[key].name == "ci"
    check daemon.sessionGroups[key].className == "ci"
    # A session joining an existing group does not change its class.
    let key2 = daemon.joinSessionGroup(PeerIdentity(),
      SessionGroupDeclaration(name: "ci", className: "other"))
    check key2 == key
    check daemon.sessionGroups[key].className == "ci"
    check daemon.sessionClass(s) == "ci"

for root in scratchRoots:
  removeDir(root)
