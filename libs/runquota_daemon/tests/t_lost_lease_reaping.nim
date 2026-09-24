## A ``supervisor_lost`` lease must not hold its reservation forever.
##
## The state exists for a good reason. When a supervisor's connection dies
## mid-execution the child it launched may still be running, so the daemon
## keeps accounting that child's CPU and memory rather than handing the same
## capacity to a second tenant. What the reasoning never supplied was an
## END: nothing ever asked whether the orphan had exited, so the reservation
## outlived the process by the daemon's whole lifetime.
##
## THE FAILURE THAT FOLLOWS IS SILENT AND TOTAL, which is why this is worth
## a test of its own rather than a line in a lifecycle suite. A request that
## no longer fits is QUEUED, not denied — queuing is the correct response to
## "does not fit right now" — so a host with enough leaked leases stops
## admitting work while reporting itself healthy and idle. Observed: four
## killed clients left five leases in ``supervisor_lost``, and every
## subsequent lease request on that host waited forever.
##
## The reaper is deliberately one-directional. An unknown answer counts as
## ALIVE, because releasing a reservation a live process still consumes is
## the one outcome worse than holding it.
##
## TWO MORE WAYS THE RESERVATION OUTLIVED THE CHILD, both seen on a Windows
## host where two lost leases pinned 8.1 GiB of a 16 GiB budget for a day and
## queued a `repro exec` indefinitely:
##
## * The reaper ran only inside the ``RequestLease`` handler. A client that
##   WAITS -- ``requestLeaseWaiting``, and every reprobuild build -- offers
##   candidates and then polls ``GrantNext``, neither of which reaped, so the
##   daemon reported ``lost_leases_reaped: 0`` for its whole lifetime. The
##   admission-path cases below drive ``tryPromoteQueued`` directly;
##   ``tests/e2e/crash-recovery/t_e2e_runquota_killed_owner_lease_reclaimed``
##   drives the same thing through a real daemon and a real killed client.
## * The child was named by pid alone, and Windows recycles pids within
##   seconds. A pid that a later process inherited read as the child still
##   running. The daemon now records the child's start stamp at
##   ``LeaseRunning``; the pid-reuse cases forge a same-pid / different-stamp
##   identity to prove the stamp is consulted.

import std/[os, osproc, tables, unittest]

import runquota_core
import runquota_daemon {.all.}
import runquota_daemon/child_identity

const GiB = 1024'u64 * 1024'u64 * 1024'u64

var scratchRoots: seq[string] = @[]

proc testDaemon(tag: string; memoryBytes = 8'u64 * GiB): RunQuotaDaemon =
  ## A daemon object with no endpoint and its stores in a per-case scratch
  ## directory. Nothing here serves a socket: these cases drive the reaper
  ## and the admission loop directly.
  let root = getTempDir() / ("runquota-reap-" & tag & "-" &
    $getCurrentProcessId())
  removeDir(root)
  createDir(root)
  scratchRoots.add(root)
  let config = DaemonConfig(
    daemonId: 1'u64,
    cpuSlots: milliCpu(4000),
    memoryBytes: bytes(memoryBytes),
    ioSlots: 8'u32,
    machines: initTable[string, MachineCapacity](),
    cpuShareGroups: initTable[string, CpuShareGroup](),
    namedPoolCaps: initTable[string, uint32](),
    version: "test",
    # Admission here must depend on the ledger alone. The default source is
    # the HOST's memory pressure, which would make a waiter's grant a fact
    # about whatever else this machine is running.
    pressureSource: pressureSourceUnavailable,
    estimateDbPath: root / "estimates.db",
    estimateQueueCapacity: 8,
    observationDbPath: root / "observations.db")
  initDaemon(config)

proc lostLease(daemon: var RunQuotaDaemon; id: uint64; label: string;
               memoryBytes: uint64; childProcessId, childStartStamp: uint64) =
  ## A ``supervisor_lost`` lease holding a REAL reservation. It reaches the
  ## state through the state machine rather than by assignment, so the
  ## capacity is really taken: asserting that the lease DISAPPEARS would not
  ## catch a reaper that forgot to give the capacity back, and giving the
  ## capacity back is the entire point.
  var lease = LeaseRow(
    id: leaseId(id),
    sessionId: sessionId(1'u64),
    label: label,
    resources: resourceVector(milliCpu(1000), bytes(memoryBytes)),
    state: leaseStateQueued,
    childProcessId: childProcessId,
    childStartStamp: childStartStamp)
  daemon.transitionLeaseState(lease, leaseStateSupervisorLost)
  daemon.leases[id] = lease

proc queueWaiter(daemon: var RunQuotaDaemon; memoryBytes: uint64): LeaseRow =
  ## A second session's request, queued exactly as ``OfferCandidates`` queues
  ## one -- the waiting path, whose only follow-up is ``GrantNext``.
  daemon.sessions[2'u64] = SessionRow(id: sessionId(2'u64), name: "waiter")
  daemon.nextLeaseId = 100'u64
  daemon.createQueuedLease(sessionId(2'u64), 7'u64, "waiter", "",
    resourceVector(milliCpu(1000), bytes(memoryBytes)), priorityNormal,
    leasePurposeWork)

proc exitedChildPid(): uint64 =
  ## The pid of a real process THIS test watched terminate. A fabricated
  ## number cannot establish that the platform probe agrees with the OS.
  let child =
    when defined(windows):
      startProcess(findExe("cmd"), args = ["/c", "exit", "0"],
        options = {poUsePath})
    else:
      startProcess("/bin/sh", args = ["-c", "exit 0"])
  result = uint64(child.processID)
  discard child.waitForExit()
  child.close()

suite "supervisor-lost leases are reaped when their child is gone":

  test "a lease that never reported a child has nothing to wait for":
    # Zero is the value a lease carries until it reports LeaseRunning, so it
    # means "no child was ever launched", not "a child whose pid is zero".
    check childVerdict(0'u64, 0'u64) == cvNoChild
    check childVerdict(0'u64, 0'u64).childGone

  test "this very process is alive, with and without its stamp":
    # The positive control. Without it a predicate that answered "dead" to
    # everything would satisfy every other case here.
    let pid = uint64(getCurrentProcessId())
    let stamp = processStartStamp(pid)
    check stamp != 0'u64
    # Stable: the same process read twice is the same identity.
    check processStartStamp(pid) == stamp
    check childVerdict(pid, stamp) == cvAlive
    # An unknown stamp falls back to existence, which still says alive.
    check childVerdict(pid, 0'u64) == cvAlive

  test "a process that has exited is not alive":
    let pid = exitedChildPid()
    check pid != 0'u64
    # The pid is reusable the instant it is reaped, so this can only assert
    # the answer, never that the answer stays true -- which is exactly why
    # the stamp exists.
    check childVerdict(pid, 0'u64).childGone

  test "a pid that a later process inherited is not the child":
    # PID REUSE, FORGED: this process's own pid with a stamp that is not its
    # own is exactly what the reaper sees when the child exited and the OS
    # handed its pid to somebody else. Judged by pid alone this reads alive
    # and the reservation leaks until the daemon restarts.
    let pid = uint64(getCurrentProcessId())
    let stamp = processStartStamp(pid)
    check stamp != 0'u64
    check childVerdict(pid, stamp + 1'u64) == cvPidReused
    check childVerdict(pid, stamp - 1'u64) == cvPidReused
    check childVerdict(pid, stamp + 1'u64).childGone

  test "the reaper releases lost leases whose child is gone, and only those":
    var daemon = testDaemon("mixed")
    let pid = uint64(getCurrentProcessId())
    let stamp = processStartStamp(pid)
    # Four lost leases in ONE sweep. A reaper that cleared the table
    # wholesale would pass a single-lease test and lose a live reservation
    # in production, so the live child sits beside every kind of dead one.
    daemon.lostLease(1'u64, "alive", GiB, pid, stamp)
    daemon.lostLease(2'u64, "never-ran", GiB, 0'u64, 0'u64)
    daemon.lostLease(3'u64, "pid-reused", GiB, pid, stamp + 1'u64)
    daemon.lostLease(4'u64, "exited", GiB, exitedChildPid(), 0'u64)
    check daemon.activeLeaseCount == 4'u32

    check daemon.reapLostLeases() == 3
    check daemon.lostLeasesReaped == 3'u64
    check daemon.leases.hasKey(1'u64)
    check not daemon.leases.hasKey(2'u64)
    check not daemon.leases.hasKey(3'u64)
    check not daemon.leases.hasKey(4'u64)
    # The reservations the dead children held are back; the live one's is
    # not.
    check daemon.activeLeaseCount == 1'u32

  test "admission reaps on the waiting path, not only on RequestLease":
    # THE HOST FAILURE. A 4 GiB budget, 3 GiB of it held by a lost lease
    # whose child is gone, and a 2 GiB request queued behind it -- the shape
    # a waiting client produces with `OfferCandidates`, after which it only
    # ever sends `GrantNext`. Both of those decide admission through
    # `tryPromoteQueued`, so that is where the reservation has to come back.
    var daemon = testDaemon("waiting", memoryBytes = 4'u64 * GiB)
    daemon.lostLease(1'u64, "killed-build", 3'u64 * GiB, exitedChildPid(),
      0'u64)
    let queued = daemon.queueWaiter(2'u64 * GiB)

    let promoted = daemon.tryPromoteQueued()
    check promoted == @[queued.id.value]
    check daemon.leases[queued.id.value].state == leaseStateGranted
    check not daemon.leases.hasKey(1'u64)
    check daemon.lostLeasesReaped == 1'u64

  test "admission reclaims a lease whose child's pid was inherited":
    # The same waiting path, with the pid-reuse identity: the pid is alive
    # (it is this process) but it is not the child the lease recorded.
    var daemon = testDaemon("reused", memoryBytes = 4'u64 * GiB)
    let pid = uint64(getCurrentProcessId())
    daemon.lostLease(1'u64, "reused-pid", 3'u64 * GiB, pid,
      processStartStamp(pid) + 1'u64)
    let queued = daemon.queueWaiter(2'u64 * GiB)

    check daemon.tryPromoteQueued() == @[queued.id.value]
    check not daemon.leases.hasKey(1'u64)

  test "admission keeps a lost lease whose child is still running":
    # THE OTHER DIRECTION, on the same path: reaping from admission must not
    # turn into admitting over a live orphan. The waiter stays queued.
    var daemon = testDaemon("live", memoryBytes = 4'u64 * GiB)
    let pid = uint64(getCurrentProcessId())
    daemon.lostLease(1'u64, "live-orphan", 3'u64 * GiB, pid,
      processStartStamp(pid))
    let queued = daemon.queueWaiter(2'u64 * GiB)

    check daemon.tryPromoteQueued().len == 0
    check daemon.leases[queued.id.value].state == leaseStateQueued
    check daemon.leases.hasKey(1'u64)
    check daemon.lostLeasesReaped == 0'u64

  test "a host with no lost leases is untouched":
    # The common case must cost nothing and change nothing; a reaper that
    # reported work on an idle host would be reclaiming something real.
    var daemon = testDaemon("idle")
    check daemon.reapLostLeases() == 0
    check daemon.lostLeasesReaped == 0'u64

# Best effort: a store the daemon object still holds open cannot be removed
# on Windows, and a leftover scratch directory is not a test result.
for root in scratchRoots:
  try: removeDir(root) except CatchableError: discard
