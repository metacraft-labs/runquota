## Virtual machines on the host daemon, and the host link a guest daemon
## speaks (protocol minor 11, `VirtualMachinesMinor`).
##
## A VM that runs a RunQuota daemon of its own is a sub-machine of the host:
## the host daemon holds the VM's whole memory for the VM's life, and charges
## the VM's vCPUs at what the guest daemon says its own leases hold, while the
## guest daemon is linked to it, or at the VM's full shape while it is not.
##
## * `RegisterVirtualMachine` asks for that lease (the VM's shape) before the
##   VM starts; it is answered like `RequestSubLease`, with one decision.
## * `VirtualMachineStarted` names the VM's host process (watched as the
##   lease's child, so a lost holder's reservation lasts exactly as long as
##   the VM) and the address the guest's link will come from.
## * `MachineLink` / `MachineLinked` / `MachineReport` travel only on the
##   link transport (vsock on Linux), where the peer's address -- assigned by
##   the hypervisor -- is what identifies the VM.

import runquota_core
import runquota_codec

type
  VmLinkKind* = enum
    vmLinkNone = 0
      ## The VM has no link address: it is always charged its full shape.
    vmLinkVsock = 1
      ## virtio-vsock: the guest connects from this context id (CID).

  RegisterVirtualMachineMessage* = object
    sessionId*: SessionId
    clientCandidateId*: uint64
      ## Echoed in the decision, as for `RequestSubLease`.
    name*: string
      ## The VM's name, as its provider knows it. 1 to
      ## `MaxVirtualMachineNameBytes` bytes, no control characters.
    label*: string
    resources*: ResourceVector
      ## `machineId` (the host machine charged), `cpu` = the VM's vCPUs in
      ## milli-CPU, `memory` = its RAM. Other fields are not read.

  VirtualMachineStartedMessage* = object
    sessionId*: SessionId
    leaseId*: LeaseId
    processId*: uint64
      ## The VM's own host process (the hypervisor process that runs it).
    linkKind*: VmLinkKind
    vsockCid*: uint32
      ## Meaningful for `vmLinkVsock`.

  VirtualMachineStartedAckMessage* = object
    sessionId*: SessionId
    leaseId*: LeaseId

  MachineLinkMessage* = object
    ## The guest daemon's opening frame on a link.
    guestVersion*: string
    name*: string
      ## Informational only: the host identifies the VM by the transport's
      ## peer address, never by anything the guest sends.
    budgetCpuMilli*: uint32
    budgetMemoryBytes*: uint64
    grantedCpuMilli*: uint32
      ## What the guest's leases hold at the moment of linking.

  MachineLinkedMessage* = object
    accepted*: bool
    name*: string
      ## The registration the link was attached to (empty when refused).
    diagnostic*: Diagnostic

  MachineReportMessage* = object
    sequence*: uint64
    grantedCpuMilli*: uint32
    usedPresent*: bool
    usedCpuMilli*: uint32
      ## The guest's busy CPU over its last sample, in milli-CPU.
    pressurePresent*: bool
    cpuSomePermille*: uint32
      ## CPU *some* pressure (avg10), in tenths of a percent.

const
  MaxVirtualMachineNameBytes* = 64
  MaxLinkFrameBytes* = 4096
    ## The largest frame a link may carry, header included. Every link
    ## message is a few dozen bytes; a larger one ends the link.
  DefaultVmLinkVsockPort* = 21073'u32
    ## The vsock port a guest daemon links to when it names none ("RQ").
  VsockHostCid* = 2'u32
    ## `VMADDR_CID_HOST`: the host, as a guest addresses it.

  usedPresentBit = 1'u32
  pressurePresentBit = 2'u32

proc virtualMachineNameProblem*(name: string): string =
  ## Why `name` cannot name a registered VM, or "".
  if name.len == 0:
    return "a virtual machine needs a name"
  if name.len > MaxVirtualMachineNameBytes:
    return "a virtual machine name is at most " &
      $MaxVirtualMachineNameBytes & " bytes, got " & $name.len
  for c in name:
    if ord(c) < 32 or ord(c) == 127:
      return "a virtual machine name must not contain control characters"
  ""

proc encodeRegisterVirtualMachine*(msg: RegisterVirtualMachineMessage): string =
  var w = writer()
  w.writeU64(msg.sessionId.value)
  w.writeU64(msg.clientCandidateId)
  w.writeString(msg.name)
  w.writeString(msg.label)
  w.writeResourceVector(msg.resources)
  w.data

proc decodeRegisterVirtualMachine*(payload: string;
    msg: var RegisterVirtualMachineMessage): bool =
  ## Structural. Whether the name and the vector are acceptable is the
  ## daemon's to answer with a decision the client can show.
  var r = reader(payload)
  var decoded: RegisterVirtualMachineMessage
  var sessionRaw: uint64
  if not r.readU64(sessionRaw): return false
  if not r.readU64(decoded.clientCandidateId): return false
  if not r.readString(decoded.name): return false
  if not r.readString(decoded.label): return false
  if not r.readResourceVector(decoded.resources): return false
  if r.remaining != 0: return false
  decoded.sessionId = sessionId(sessionRaw)
  msg = decoded
  true

proc encodeVirtualMachineStarted*(msg: VirtualMachineStartedMessage): string =
  var w = writer()
  w.writeU64(msg.sessionId.value)
  w.writeU64(msg.leaseId.value)
  w.writeU64(msg.processId)
  w.writeU8(uint8(ord(msg.linkKind)))
  w.writeU32(msg.vsockCid)
  w.data

proc decodeVirtualMachineStarted*(payload: string;
    msg: var VirtualMachineStartedMessage): bool =
  var r = reader(payload)
  var sessionRaw, leaseRaw, processId: uint64
  var kind: uint8
  var cid: uint32
  if not r.readU64(sessionRaw): return false
  if not r.readU64(leaseRaw): return false
  if not r.readU64(processId): return false
  if not r.readU8(kind): return false
  if int(kind) > ord(high(VmLinkKind)): return false
  if not r.readU32(cid): return false
  if r.remaining != 0: return false
  msg = VirtualMachineStartedMessage(sessionId: sessionId(sessionRaw),
    leaseId: leaseId(leaseRaw), processId: processId,
    linkKind: VmLinkKind(int(kind)), vsockCid: cid)
  true

proc encodeVirtualMachineStartedAck*(
    msg: VirtualMachineStartedAckMessage): string =
  var w = writer()
  w.writeU64(msg.sessionId.value)
  w.writeU64(msg.leaseId.value)
  w.data

proc decodeVirtualMachineStartedAck*(payload: string;
    msg: var VirtualMachineStartedAckMessage): bool =
  var r = reader(payload)
  var sessionRaw, leaseRaw: uint64
  if not r.readU64(sessionRaw): return false
  if not r.readU64(leaseRaw): return false
  if r.remaining != 0: return false
  msg = VirtualMachineStartedAckMessage(sessionId: sessionId(sessionRaw),
    leaseId: leaseId(leaseRaw))
  true

proc encodeMachineLink*(msg: MachineLinkMessage): string =
  var w = writer()
  w.writeString(msg.guestVersion)
  w.writeString(msg.name)
  w.writeU32(msg.budgetCpuMilli)
  w.writeU64(msg.budgetMemoryBytes)
  w.writeU32(msg.grantedCpuMilli)
  w.data

proc decodeMachineLink*(payload: string; msg: var MachineLinkMessage): bool =
  var r = reader(payload)
  var decoded: MachineLinkMessage
  if not r.readString(decoded.guestVersion): return false
  if not r.readString(decoded.name): return false
  if not r.readU32(decoded.budgetCpuMilli): return false
  if not r.readU64(decoded.budgetMemoryBytes): return false
  if not r.readU32(decoded.grantedCpuMilli): return false
  if r.remaining != 0: return false
  msg = decoded
  true

proc encodeMachineLinked*(msg: MachineLinkedMessage): string =
  var w = writer()
  w.writeBool(msg.accepted)
  w.writeString(msg.name)
  w.writeDiagnostic(msg.diagnostic)
  w.data

proc decodeMachineLinked*(payload: string; msg: var MachineLinkedMessage): bool =
  var r = reader(payload)
  var decoded: MachineLinkedMessage
  if not r.readBool(decoded.accepted): return false
  if not r.readString(decoded.name): return false
  if not r.readDiagnostic(decoded.diagnostic): return false
  if r.remaining != 0: return false
  msg = decoded
  true

proc encodeMachineReport*(msg: MachineReportMessage): string =
  var w = writer()
  w.writeU64(msg.sequence)
  w.writeU32(msg.grantedCpuMilli)
  var flags = 0'u32
  if msg.usedPresent: flags = flags or usedPresentBit
  if msg.pressurePresent: flags = flags or pressurePresentBit
  w.writeU32(flags)
  w.writeU32(if msg.usedPresent: msg.usedCpuMilli else: 0'u32)
  w.writeU32(if msg.pressurePresent: msg.cpuSomePermille else: 0'u32)
  w.data

proc decodeMachineReport*(payload: string; msg: var MachineReportMessage): bool =
  ## Structural. Reserved flag bits are ignored, so a later guest can add a
  ## figure an older host reads as absent.
  var r = reader(payload)
  var decoded: MachineReportMessage
  var flags: uint32
  if not r.readU64(decoded.sequence): return false
  if not r.readU32(decoded.grantedCpuMilli): return false
  if not r.readU32(flags): return false
  if not r.readU32(decoded.usedCpuMilli): return false
  if not r.readU32(decoded.cpuSomePermille): return false
  if r.remaining != 0: return false
  decoded.usedPresent = (flags and usedPresentBit) != 0'u32
  decoded.pressurePresent = (flags and pressurePresentBit) != 0'u32
  if not decoded.usedPresent: decoded.usedCpuMilli = 0'u32
  if not decoded.pressurePresent: decoded.cpuSomePermille = 0'u32
  msg = decoded
  true

proc vmCpuCharge*(shapeMilli: uint32; linked: bool; grantedMilli: uint32;
                  usedPresent: bool; usedMilli: uint32): uint32 =
  ## What the host charges a registered VM's CPU: its whole shape without a
  ## link; with one, what the guest uses -- the larger of what its leases
  ## hold and what it measured busy, when it measures -- and never more than
  ## the shape, whatever the guest claims.
  if not linked:
    return shapeMilli
  let used = if usedPresent: max(grantedMilli, usedMilli) else: grantedMilli
  min(shapeMilli, used)
