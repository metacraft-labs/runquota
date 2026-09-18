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

import std/[options, os, osproc, strutils, tables, unittest]

import runquota_core
import runquota_daemon {.all.}
import runquota_protocol

suite "supervisor-lost leases are reaped when their child exits":

  test "a pid that never existed is not alive":
    # Zero is the value a lease carries until it reports LeaseRunning, so it
    # means "no child was ever launched", not "a child whose pid is zero".
    check not orphanStillRunning(0'u64)

  test "this very process is alive":
    # The positive control. Without it a predicate that answered "dead" to
    # everything would satisfy every other case here.
    check orphanStillRunning(uint64(getCurrentProcessId()))

  test "a process that has exited is not alive":
    # A real spawn-and-wait rather than a made-up pid: the point is that the
    # platform probe agrees with the OS about a process THIS test watched
    # terminate, which a fabricated number cannot establish.
    let child = startProcess(
      findExe("cmd"),
      args = ["/c", "exit", "0"],
      options = {poUsePath})
    let pid = uint64(child.processID)
    check pid != 0'u64
    discard child.waitForExit()
    child.close()
    # The pid is reusable the instant it is reaped, so this can only assert
    # the answer, never that the answer stays true.
    check not orphanStillRunning(pid)

  test "the reaper releases a lost lease whose child is gone":
    let root = getTempDir() / "runquota-reap-test"
    removeDir(root)
    createDir(root)
    defer:
      try: removeDir(root) except CatchableError: discard

    var config = DaemonConfig(
      daemonId: 1'u64,
      cpuSlots: milliCpu(4000),
      memoryBytes: bytes(8_000_000_000'u64),
      ioSlots: 8'u32,
      machines: initTable[string, MachineCapacity](),
      cpuShareGroups: initTable[string, CpuShareGroup](),
      namedPoolCaps: initTable[string, uint32](),
      version: "test",
      estimateDbPath: root / "estimates.db",
      estimateQueueCapacity: 8,
      observationDbPath: root / "observations.db")
    var daemon = initDaemon(config)

    # Two lost leases: one whose child is this process (alive, must be
    # kept) and one whose child never existed (must go). Keeping them in the
    # same sweep is the point — a reaper that cleared the table wholesale
    # would pass a single-lease test and lose a live reservation in
    # production.
    let liveResources = resourceVector(milliCpu(1000), bytes(1_000_000_000'u64))
    var alive = LeaseRow(
      id: leaseId(1'u64),
      sessionId: sessionId(1'u64),
      label: "alive",
      resources: liveResources,
      state: leaseStateSupervisorLost,
      childProcessId: uint64(getCurrentProcessId()))
    var gone = LeaseRow(
      id: leaseId(2'u64),
      sessionId: sessionId(1'u64),
      label: "gone",
      resources: liveResources,
      state: leaseStateSupervisorLost,
      childProcessId: 0'u64)
    # Reach `supervisor_lost` through the state machine rather than by
    # assignment, so the reservation is really taken. Asserting that the
    # lease DISAPPEARS would not have caught a reaper that forgot to give
    # the capacity back, and giving the capacity back is the entire point.
    alive.state = leaseStateQueued
    gone.state = leaseStateQueued
    daemon.transitionLeaseState(alive, leaseStateSupervisorLost)
    daemon.transitionLeaseState(gone, leaseStateSupervisorLost)
    daemon.leases[1'u64] = alive
    daemon.leases[2'u64] = gone
    check daemon.activeLeaseCount == 2'u32

    let reaped = daemon.reapLostLeases()
    check reaped == 1
    check daemon.lostLeasesReaped == 1'u64
    check daemon.leases.hasKey(1'u64)
    check not daemon.leases.hasKey(2'u64)
    # The reservation the dead child held is back, and the live one's is not.
    check daemon.activeLeaseCount == 1'u32

  test "a host with no lost leases is untouched":
    # The common case must cost nothing and change nothing; a reaper that
    # reported work on an idle host would be reclaiming something real.
    let root = getTempDir() / "runquota-reap-test-idle"
    removeDir(root)
    createDir(root)
    defer:
      try: removeDir(root) except CatchableError: discard
    var config = DaemonConfig(
      daemonId: 2'u64,
      cpuSlots: milliCpu(4000),
      memoryBytes: bytes(8_000_000_000'u64),
      ioSlots: 8'u32,
      machines: initTable[string, MachineCapacity](),
      cpuShareGroups: initTable[string, CpuShareGroup](),
      namedPoolCaps: initTable[string, uint32](),
      version: "test",
      estimateDbPath: root / "estimates.db",
      estimateQueueCapacity: 8,
      observationDbPath: root / "observations.db")
    var daemon = initDaemon(config)
    check daemon.reapLostLeases() == 0
    check daemon.lostLeasesReaped == 0'u64
