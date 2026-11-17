## What the host daemon keeps about each registered virtual machine, beside
## the lease that holds the VM's shape (`RegisterVirtualMachine`).
##
## The lease is the accounting: its memory is the VM's RAM, held for the
## lease's life, and its CPU charge is what `vmCpuCharge` says -- the VM's
## whole shape until a guest daemon links, then what the guest reports its
## leases hold. This row is what the charge is computed from and what
## `runquota status --json` shows. It lives exactly as long as its lease:
## whatever removes the lease removes the row (`removeLeaseFromTable`).

import runquota_codec
import runquota_protocol

type
  VirtualMachineRow* = object
    leaseId*: uint64
    name*: string
    ownerKey*: string
    shapeCpuMilli*: uint32
    memoryBytes*: uint64
    started*: bool
      ## `VirtualMachineStarted` arrived: the lease watches the VM process.
    processId*: uint64
    restarts*: uint64
      ## How many times the VM was restarted in place (a new hypervisor
      ## process reported for the same registration).
    linkKind*: VmLinkKind
    vsockCid*: uint32
    linkId*: uint64
      ## The link connection attached now; 0 when none.
    linkedAtMillis*: int64
    lastReportAtMillis*: int64
    reports*: uint64
    linksAttached*: uint64
      ## How many times a guest link was attached, so a link that keeps
      ## dropping is visible.
    guestVersion*: string
    guestName*: string
    guestBudgetCpuMilli*: uint32
    guestBudgetMemoryBytes*: uint64
    guestGrantedCpuMilli*: uint32
    guestUsedPresent*: bool
    guestUsedCpuMilli*: uint32
    guestPressurePresent*: bool
    guestCpuSomePermille*: uint32
    lastSequence*: uint64

proc linked*(row: VirtualMachineRow): bool =
  row.linkId != 0'u64

proc chargeMilli*(row: VirtualMachineRow): uint32 =
  vmCpuCharge(row.shapeCpuMilli, row.linked, row.guestGrantedCpuMilli,
    row.guestUsedPresent, row.guestUsedCpuMilli)

proc vmCapabilityText*(row: VirtualMachineRow): string =
  ## The capability line for a VM the host cannot see into, or "" when it is
  ## linked. AN UNLINKED VM IS A GAP IN WHAT THE HOST KNOWS, and is said so.
  if row.linked:
    ""
  elif not row.started:
    "not started yet: counted at its full shape (" & $row.shapeCpuMilli &
      "m CPU)"
  elif row.linkKind == vmLinkNone:
    "no link address: counted at its full shape (" & $row.shapeCpuMilli &
      "m CPU); its guest daemon cannot report what it uses"
  else:
    "no guest daemon link: counted at its full shape (" &
      $row.shapeCpuMilli & "m CPU) until its guest daemon links"

proc virtualMachineJson*(row: VirtualMachineRow; nowMillis: int64;
                         leaseState: string; ownerUid: string;
                         chargedMilli: uint32): string =
  ## `chargedMilli` is what the lease charges the ledger NOW, read from the
  ## lease rather than recomputed, so the figure shown is the one admission
  ## uses.
  let capability = row.vmCapabilityText
  "{\"name\":" & jsonEscape(row.name) &
    ",\"lease_id\":" & $row.leaseId &
    ",\"lease_state\":" & jsonEscape(leaseState) &
    ",\"owner_uid\":" & ownerUid &
    ",\"shape_cpu_milli\":" & $row.shapeCpuMilli &
    ",\"memory_bytes\":" & $row.memoryBytes &
    ",\"charged_cpu_milli\":" & $chargedMilli &
    ",\"started\":" & $row.started &
    ",\"process_id\":" & $row.processId &
    ",\"restarts\":" & $row.restarts &
    ",\"link_kind\":" & jsonEscape(
      case row.linkKind
      of vmLinkNone: "none"
      of vmLinkVsock: "vsock") &
    ",\"vsock_cid\":" & $row.vsockCid &
    ",\"link\":" & jsonEscape(if row.linked: "linked" else: "unlinked") &
    ",\"counted_at\":" &
      jsonEscape(if row.linked: "guest-use" else: "full-shape") &
    ",\"links_attached\":" & $row.linksAttached &
    ",\"reports\":" & $row.reports &
    ",\"last_report_age_millis\":" &
      (if row.lastReportAtMillis == 0'i64: "null"
       else: $(max(0'i64, nowMillis - row.lastReportAtMillis))) &
    ",\"guest\":{\"version\":" & jsonEscape(row.guestVersion) &
      ",\"name\":" & jsonEscape(row.guestName) &
      ",\"budget_cpu_milli\":" & $row.guestBudgetCpuMilli &
      ",\"budget_memory_bytes\":" & $row.guestBudgetMemoryBytes &
      ",\"granted_cpu_milli\":" & $row.guestGrantedCpuMilli &
      ",\"used_cpu_milli\":" &
        (if row.guestUsedPresent: $row.guestUsedCpuMilli else: "null") &
      ",\"cpu_some_permille\":" &
        (if row.guestPressurePresent: $row.guestCpuSomePermille
         else: "null") & "}" &
    ",\"capability\":" &
      (if capability.len == 0: "null" else: jsonEscape(capability)) &
    "}"
