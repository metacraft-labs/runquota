## What the host daemon charges a registered virtual machine, and when.
##
## A VM with a RunQuota daemon of its own is a sub-machine of the host: its
## memory is reserved for its whole life, linked or not, and its vCPUs are
## charged at its full shape until its guest daemon links, then at what the
## guest's leases hold. These cases drive the daemon's own procedures --
## the ones the RQSP handlers and the vsock link listener call -- on a daemon
## object with no endpoint, so each rule is checked against the real ledger
## (`fitsNow`, `freeCpuFor`) and nothing else. The link transport itself and
## a real guest are exercised end to end in gosti's VM test.
##
## NO MOCKS: the real daemon state machine and the real admission check.

import std/[os, posix, tables, unittest]

import runquota_core
import runquota_protocol
import runquota_daemon {.all.}

const
  GiB = 1024'u64 * 1024'u64 * 1024'u64
  BudgetCpu = 4000'u32
  VmCpu = 2000'u32
  VmCid = 42'u32

var scratchRoots: seq[string] = @[]

proc testDaemon(tag: string): RunQuotaDaemon =
  let root = getTempDir() / ("runquota-vm-" & tag & "-" &
    $getCurrentProcessId())
  removeDir(root)
  createDir(root)
  scratchRoots.add(root)
  initDaemon(DaemonConfig(
    daemonId: 1'u64,
    cpuSlots: milliCpu(BudgetCpu),
    memoryBytes: bytes(8'u64 * GiB),
    ioSlots: 8'u32,
    machines: initTable[string, MachineCapacity](),
    cpuShareGroups: initTable[string, CpuShareGroup](),
    namedPoolCaps: initTable[string, uint32](),
    version: "test",
    pressureSource: pressureSourceUnavailable,
    estimateDbPath: root / "estimates.db",
    estimateQueueCapacity: 8,
    observationDbPath: root / "observations.db"))

proc registerVm(daemon: var RunQuotaDaemon; memoryBytes = 2'u64 * GiB;
                cid = VmCid): uint64 =
  ## What `RegisterVirtualMachine` and `VirtualMachineStarted` leave behind:
  ## a granted, running lease of the VM's shape and its row.
  daemon.sessions[1'u64] = SessionRow(id: sessionId(1'u64), name: "holder")
  let resources = resourceVector(milliCpu(VmCpu), bytes(memoryBytes))
  let lease = daemon.createQueuedLease(sessionId(1'u64), 1'u64, "vm test", "",
    resources, priorityNormal, leasePurposeWork)
  result = lease.id.value
  daemon.virtualMachines[result] = VirtualMachineRow(leaseId: result,
    name: "vm", shapeCpuMilli: VmCpu, memoryBytes: memoryBytes)
  discard daemon.tryPromoteQueued()
  require daemon.leases[result].state == leaseStateGranted
  # `VirtualMachineStarted`, through the handler's own procedure.
  require daemon.startVirtualMachine(result, uint64(getCurrentProcessId()),
    vmLinkVsock, cid) == ""
  require daemon.leases[result].state == leaseStateRunning

proc cpuFits(daemon: RunQuotaDaemon; milli: uint32): bool =
  daemon.fitsNow(resourceVector(milliCpu(milli), bytes(1'u64 * GiB)), "")

proc memoryFits(daemon: RunQuotaDaemon; memoryBytes: uint64): bool =
  daemon.fitsNow(resourceVector(milliCpu(1), bytes(memoryBytes)), "")

proc link(daemon: var RunQuotaDaemon; cid = VmCid; granted = 0'u32;
          linkId = 7'u64): tuple[answer: MachineLinkedMessage; lease: uint64] =
  var lease = 0'u64
  let answer = daemon.attachVmLink(linkId, cid, MachineLinkMessage(
    guestVersion: "g", budgetCpuMilli: VmCpu, grantedCpuMilli: granted),
    lease)
  (answer, lease)

proc report(daemon: var RunQuotaDaemon; lease: uint64; granted: uint32;
            linkId = 7'u64; usedPresent = false; used = 0'u32): bool =
  daemon.applyVmReport(linkId, lease, MachineReportMessage(sequence: 1,
    grantedCpuMilli: granted, usedPresent: usedPresent, usedCpuMilli: used))

suite "what a registered VM is charged":
  test "the charge rule":
    check vmCpuCharge(2000, false, 0, false, 0) == 2000
    check vmCpuCharge(2000, true, 0, false, 0) == 0
    check vmCpuCharge(2000, true, 1500, false, 0) == 1500
    check vmCpuCharge(2000, true, 500, true, 1200) == 1200
    check vmCpuCharge(2000, true, 1200, true, 500) == 1200
    # The guest cannot be charged beyond its shape, whatever it claims.
    check vmCpuCharge(2000, true, 9000, true, 9000) == 2000

  test "unlinked, a VM counts at its full shape":
    var daemon = testDaemon("unlinked")
    let id = daemon.registerVm()
    check daemon.leases[id].resources.cpu.value == VmCpu
    check daemon.cpuFits(BudgetCpu - VmCpu)
    check not daemon.cpuFits(BudgetCpu - VmCpu + 1)
    check daemon.virtualMachines[id].vmCapabilityText.len > 0

  test "a link from another CID is refused and changes nothing":
    var daemon = testDaemon("othercid")
    let id = daemon.registerVm()
    let (answer, lease) = daemon.link(cid = VmCid + 1)
    check not answer.accepted
    check lease == 0'u64
    check daemon.vmLinksRefused == 1'u64
    check daemon.leases[id].resources.cpu.value == VmCpu
    check not daemon.cpuFits(BudgetCpu - VmCpu + 1)

  test "an idle linked VM's vCPUs are usable by the host":
    var daemon = testDaemon("idle")
    let id = daemon.registerVm()
    let (answer, lease) = daemon.link()
    check answer.accepted
    check lease == id
    check daemon.leases[id].resources.cpu.value == 0'u32
    check daemon.cpuFits(BudgetCpu)
    check daemon.virtualMachines[id].vmCapabilityText.len == 0

  test "a busy guest takes its vCPUs back from the next decision on":
    var daemon = testDaemon("busy")
    let id = daemon.registerVm()
    discard daemon.link()
    # A host lease takes the whole budget while the guest idles.
    daemon.sessions[2'u64] = SessionRow(id: sessionId(2'u64), name: "host")
    let host = daemon.createQueuedLease(sessionId(2'u64), 2'u64, "host", "",
      resourceVector(milliCpu(BudgetCpu), bytes(1'u64 * GiB)),
      priorityNormal, leasePurposeWork)
    discard daemon.tryPromoteQueued()
    check daemon.leases[host.id.value].state == leaseStateGranted
    # The guest gets busy: never revoked, the host lease keeps its grant,
    # and nothing more is admitted.
    check daemon.report(id, VmCpu)
    check daemon.leases[id].resources.cpu.value == VmCpu
    check daemon.leases[host.id.value].state == leaseStateGranted
    check daemon.freeCpuFor(resourceVector(milliCpu(1), bytes(1))) == 0'u32
    check not daemon.cpuFits(1)
    # The host lease ends: the host is back to its budget minus the guest.
    daemon.releaseLease(host.id)
    check daemon.cpuFits(BudgetCpu - VmCpu)
    check not daemon.cpuFits(BudgetCpu - VmCpu + 1)
    # The guest idles again.
    check daemon.report(id, 0)
    check daemon.cpuFits(BudgetCpu)

  test "a lowered charge admits a waiting request at once":
    var daemon = testDaemon("admits")
    let id = daemon.registerVm()
    discard daemon.link(granted = VmCpu)
    daemon.sessions[2'u64] = SessionRow(id: sessionId(2'u64), name: "host")
    let waiter = daemon.createQueuedLease(sessionId(2'u64), 2'u64, "host",
      "", resourceVector(milliCpu(BudgetCpu), bytes(1'u64 * GiB)),
      priorityNormal, leasePurposeWork)
    discard daemon.tryPromoteQueued()
    check daemon.leases[waiter.id.value].state == leaseStateQueued
    check daemon.report(id, 0)
    check daemon.leases[waiter.id.value].state == leaseStateGranted

  test "a lost link puts the full shape back":
    var daemon = testDaemon("lost")
    let id = daemon.registerVm()
    discard daemon.link()
    check daemon.cpuFits(BudgetCpu)
    daemon.detachVmLink(7'u64, id)
    check daemon.leases[id].resources.cpu.value == VmCpu
    check not daemon.cpuFits(BudgetCpu - VmCpu + 1)
    # A report on the dead link changes nothing.
    check not daemon.report(id, 0)
    check daemon.leases[id].resources.cpu.value == VmCpu

  test "a newer link replaces the older one":
    var daemon = testDaemon("replace")
    let id = daemon.registerVm()
    discard daemon.link(linkId = 7)
    discard daemon.link(linkId = 8, granted = 500)
    check not daemon.report(id, 0, linkId = 7)
    check daemon.report(id, 300, linkId = 8)
    check daemon.leases[id].resources.cpu.value == 300'u32
    # Only the current link's end puts the shape back.
    daemon.detachVmLink(7'u64, id)
    check daemon.leases[id].resources.cpu.value == 300'u32

  test "the VM's memory is never lent, linked or not":
    var daemon = testDaemon("memory")
    let id = daemon.registerVm(memoryBytes = 3'u64 * GiB)
    check daemon.memoryFits(5'u64 * GiB)
    check not daemon.memoryFits(5'u64 * GiB + 1)
    discard daemon.link()
    check daemon.report(id, 0)
    check daemon.memoryFits(5'u64 * GiB)
    check not daemon.memoryFits(5'u64 * GiB + 1)
    daemon.releaseLease(leaseId(id))
    check daemon.memoryFits(8'u64 * GiB)

  test "the VM goes with its lease, and so does its link":
    var daemon = testDaemon("forget")
    let id = daemon.registerVm()
    discard daemon.link()
    daemon.releaseLease(leaseId(id))
    check not daemon.virtualMachines.hasKey(id)
    check not daemon.vmLinkStillAttached(7'u64, id)
    check not daemon.report(id, 0)
    check daemon.cpuFits(BudgetCpu)

  test "a supervisor-lost VM keeps its link and its reservation":
    var daemon = testDaemon("lostholder")
    let id = daemon.registerVm()
    var row = daemon.leases[id]
    # This process stands in for the VM process: alive, so the reaper holds.
    row.childProcessId = uint64(getCurrentProcessId())
    daemon.transitionLeaseState(row, leaseStateSupervisorLost)
    daemon.leases[id] = row
    discard daemon.tryPromoteQueued()
    check daemon.leases.hasKey(id)
    let (answer, _) = daemon.link()
    check answer.accepted
    check daemon.cpuFits(BudgetCpu)
    check not daemon.memoryFits(6'u64 * GiB + 1)

  # This case takes the test's PARENT process as "another live process" for
  # the restarted VM (`getppid`), and the standard library has no portable
  # parent query: it exists only where `defined(posix)`. The Windows legs build
  # this file, so the case is POSIX-only rather than inventing a process id.
  when defined(posix):
    test "a VM restarted in place stays registered, watched on its new process":
      var daemon = testDaemon("restart")
      let id = daemon.registerVm(memoryBytes = 3'u64 * GiB)
      discard daemon.link()
      check daemon.virtualMachines[id].linked
      # A guest reboot: a new hypervisor process for the same VM. The parent
      # of this test stands in for it (alive, and not the first one).
      let next = uint64(getppid())
      check daemon.startVirtualMachine(id, next, vmLinkVsock, VmCid) == ""
      check daemon.leases[id].state == leaseStateRunning
      check daemon.leases[id].childProcessId == next
      check daemon.virtualMachines[id].processId == next
      check daemon.virtualMachines[id].restarts == 1'u64
      # The old process's link is dropped: full shape until the guest relinks.
      check not daemon.virtualMachines[id].linked
      check daemon.leases[id].resources.cpu.value == VmCpu
      check not daemon.memoryFits(5'u64 * GiB + 1)
      let (again, _) = daemon.link(linkId = 9)
      check again.accepted
      check daemon.cpuFits(BudgetCpu)
      # Neither a pid of 0 nor a CID another VM holds is accepted.
      check daemon.startVirtualMachine(id, 0'u64, vmLinkVsock, VmCid).len > 0
      let other = daemon.registerVm(memoryBytes = 1'u64 * GiB, cid = VmCid + 1)
      check daemon.startVirtualMachine(other, next, vmLinkVsock, VmCid).len > 0
      check daemon.virtualMachines[other].vsockCid == VmCid + 1

for root in scratchRoots:
  removeDir(root)
