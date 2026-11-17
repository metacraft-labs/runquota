## The wire form of virtual machine registration and the host link
## (protocol minor 11, `VirtualMachinesMinor`), and what it leaves alone.
##
## * The six new kinds take the numbers after the last minor-10 kind and
##   round trip; each decoder refuses trailing bytes, and the report's
##   decoder ignores reserved flag bits (so a later guest can add a figure
##   an older host reads as absent) and zeroes a figure whose presence bit
##   is clear.
## * Minor 11 changes no existing message: a client that sends none of the
##   new kinds sends the bytes it sent at minor 10. Checked for the frames
##   every client sends (Hello, RegisterSession, RequestLease), written field
##   by field here rather than through the current encoder, so "unchanged"
##   cannot pass by the encoder agreeing with itself.
##
## NO MOCKS: the real codec over real byte strings.

import std/unittest

import runquota_codec
import runquota_core
import runquota_protocol

suite "virtual machine codec":
  test "minor 11 announces the kinds, numbered after minor 10's":
    check RqspProtocolMinor >= VirtualMachinesMinor
    check ord(rqRegisterVirtualMachine) == 50
    check ord(rqVirtualMachineStarted) == 51
    check ord(rqVirtualMachineStartedAck) == 52
    check ord(rqMachineLink) == 53
    check ord(rqMachineLinked) == 54
    check ord(rqMachineReport) == 55
    var kind: RqspMessageKind
    check messageKindFromWire(55'u16, kind)
    check kind == rqMachineReport

  test "RegisterVirtualMachine round trips and refuses trailing bytes":
    var resources = resourceVector(milliCpu(2000), bytes(1073741824))
    resources.machineId = "local"
    let sent = RegisterVirtualMachineMessage(sessionId: sessionId(3),
      clientCandidateId: 9, name: "rqvm-a", label: "vm rqvm-a",
      resources: resources)
    var got: RegisterVirtualMachineMessage
    let bytes = encodeRegisterVirtualMachine(sent)
    check decodeRegisterVirtualMachine(bytes, got)
    check got.sessionId.value == 3'u64
    check got.clientCandidateId == 9'u64
    check got.name == "rqvm-a"
    check got.resources.cpu.value == 2000'u32
    check got.resources.memory.value == 1073741824'u64
    check got.resources.machineId == "local"
    check not decodeRegisterVirtualMachine(bytes & "x", got)

  test "VirtualMachineStarted round trips and refuses an unknown link kind":
    let sent = VirtualMachineStartedMessage(sessionId: sessionId(1),
      leaseId: leaseId(2), processId: 12345, linkKind: vmLinkVsock,
      vsockCid: 2171611009'u32)
    var got: VirtualMachineStartedMessage
    var bytes = encodeVirtualMachineStarted(sent)
    check decodeVirtualMachineStarted(bytes, got)
    check got.processId == 12345'u64
    check got.linkKind == vmLinkVsock
    check got.vsockCid == 2171611009'u32
    # The kind byte follows three u64s.
    bytes[24] = char(7)
    check not decodeVirtualMachineStarted(bytes, got)
    var ack: VirtualMachineStartedAckMessage
    check decodeVirtualMachineStartedAck(encodeVirtualMachineStartedAck(
      VirtualMachineStartedAckMessage(sessionId: sessionId(1),
        leaseId: leaseId(2))), ack)
    check ack.leaseId.value == 2'u64

  test "MachineLink and MachineLinked round trip":
    let link = MachineLinkMessage(guestVersion: "1.2", name: "guest",
      budgetCpuMilli: 2000, budgetMemoryBytes: 900 * 1024 * 1024,
      grantedCpuMilli: 1000)
    var gotLink: MachineLinkMessage
    check decodeMachineLink(encodeMachineLink(link), gotLink)
    check gotLink.name == "guest"
    check gotLink.budgetMemoryBytes == 900'u64 * 1024 * 1024
    check gotLink.grantedCpuMilli == 1000'u32
    check not decodeMachineLink(encodeMachineLink(link) & "\0", gotLink)
    let linked = MachineLinkedMessage(accepted: false, name: "",
      diagnostic: diagnostic(diagInvalidArgument, "no such VM", "detail"))
    var gotLinked: MachineLinkedMessage
    check decodeMachineLinked(encodeMachineLinked(linked), gotLinked)
    check not gotLinked.accepted
    check gotLinked.diagnostic.message == "no such VM"

  test "MachineReport: presence bits, reserved bits ignored":
    let sent = MachineReportMessage(sequence: 4, grantedCpuMilli: 1500,
      usedPresent: true, usedCpuMilli: 1700, pressurePresent: false,
      cpuSomePermille: 99)
    var got: MachineReportMessage
    let bytes = encodeMachineReport(sent)
    check decodeMachineReport(bytes, got)
    check got.sequence == 4'u64
    check got.usedPresent
    check got.usedCpuMilli == 1700'u32
    check not got.pressurePresent
    check got.cpuSomePermille == 0'u32
    # A later guest's flag bit is ignored; a figure without its bit is read
    # as absent, whatever its bytes.
    var w = writer()
    w.writeU64(5)
    w.writeU32(10)
    w.writeU32(0x80'u32)
    w.writeU32(777)
    w.writeU32(888)
    check decodeMachineReport(w.data, got)
    check got.grantedCpuMilli == 10'u32
    check not got.usedPresent and got.usedCpuMilli == 0'u32
    check not got.pressurePresent and got.cpuSomePermille == 0'u32
    check not decodeMachineReport(bytes & "x", got)

  test "a VM name is 1 to 64 bytes without control characters":
    check virtualMachineNameProblem("rqvm-1").len == 0
    check virtualMachineNameProblem("").len > 0
    check virtualMachineNameProblem(newString(65)).len > 0
    check virtualMachineNameProblem("a\nb").len > 0

  test "a client that sends no new kind sends minor 10's bytes":
    # Hello.
    var w = writer()
    w.writeString("c")
    w.writeString("1")
    w.writeU16(2)
    w.writeU16(2)
    w.writeU64(10)
    w.writeU64(1004)
    w.writeString("")
    check encodeHello(HelloMessage(clientName: "c", clientVersion: "1",
      minProtocolMajor: 2, maxProtocolMajor: 2, processId: 10,
      userId: 1004)) == w.data
    # RegisterSession without a group or sizing declaration.
    w = writer()
    w.writeString("s")
    w.writeString("1")
    w.writeMetadata(metadataNone())
    check encodeRegisterSession(RegisterSessionMessage(name: "s",
      version: "1", metadata: metadataNone())) == w.data
    # RequestLease without an estimate's width block.
    let resources = resourceVector(milliCpu(1000), bytes(4096))
    w = writer()
    w.writeU64(1)
    w.writeString("l")
    w.writeBytes("")
    w.writeResourceVector(resources)
    w.writeDeadline(Deadline())
    w.writeU32(uint32(ord(priorityNormal)))
    w.writeU32(uint32(ord(leasePurposeWork)))
    w.writeMetadata(metadataNone())
    w.writeBool(false)
    w.writeU64(0)
    check encodeLeaseRequest(LeaseRequestMessage(sessionId: sessionId(1),
      label: "l", resources: resources, priority: priorityNormal,
      purpose: leasePurposeWork, metadata: metadataNone())) == w.data
