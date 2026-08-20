## Hardware-profile detection: what this machine *is*, in exactly the
## descriptive columns of ``host_profiles``.
##
## Normative specification:
## ``reprobuild-specs/RunQuota-Observation-Store.md`` §"`hosts` and
## `host_profiles`". The daemon detects its profile at startup, hashes the
## descriptive columns, and reuses the existing row when the hash is
## unchanged (``ensureHostProfile`` in ``store.nim``).
##
## Two rules bind everything below.
##
## * **Nothing here raises.** Detection runs on the daemon's startup path
##   and a machine that will not answer a question yields the documented
##   ``unknown`` for that field, never an exception and never a plausible
##   guess. OS-4 applies to observation, and hardware detection is
##   observation.
## * **Only stable facts.** Every field feeds ``profileHash``, so a value
##   that moves on its own forks the machine's history into two profiles
##   that describe the same hardware — the accumulation the specification
##   forbids. Capacities belong here; utilisation does not. The one field
##   where the line is genuinely blurred is swap, handled below.
##
## PLATFORM STATUS. macOS/arm64 is the only platform this has been run on.
## The Linux branch is written from ``/proc`` and ``/sys`` semantics and
## has NEVER EXECUTED; the Windows branch is deliberately a stub that
## reports what the Nim runtime already knows and ``unknown`` for the
## rest. Treat a failure on either as a first observation, not a
## regression.

import std/[os, osproc, streams, strutils]

import ./sha256, ./types

const
  gibiByte = 1024'i64 * 1024'i64 * 1024'i64
  unknownField* = "unknown"
    ## What every string field holds when the machine would not say. It is
    ## a value, not an absence: the columns are ``not null`` and a store
    ## that cannot distinguish "nobody asked" from "the answer is empty"
    ## produces the same class of silent lie as a zero standing in for a
    ## missing measurement.

proc quantizeSwapBytes*(raw: int64): int64 =
  ## Swap rounded to the nearest whole GiB.
  ##
  ## Swap is the one column that is not purely a capacity. Linux reports a
  ## configured ``SwapTotal`` and is stable; macOS has no configured size
  ## at all — the dynamic pager grows swap files on demand, so
  ## ``vm.swapusage`` reports utilisation wearing a capacity's name. Byte
  ## exactness there would mint a fresh hardware profile every time the
  ## pager grew a file, which is precisely the accumulation the
  ## specification forbids, so the value is quantized before it is stored
  ## AND before it is hashed — the stored column and the hash always agree.
  ##
  ## Residual, stated rather than hidden: on a macOS host under sustained
  ## memory pressure, swap crossing a GiB boundary still forks the
  ## profile. The real fix is a configured capacity that macOS does not
  ## expose.
  if raw <= 0:
    return 0
  ((raw + gibiByte div 2) div gibiByte) * gibiByte

proc hardwareProfile*(row: HostProfileRow): HardwareProfile =
  ## The descriptive half of a stored row, so a detected profile and a
  ## stored one can be compared as values.
  HardwareProfile(
    cpuModel: row.cpuModel,
    physicalCores: row.physicalCores,
    logicalCores: row.logicalCores,
    ramBytes: row.ramBytes,
    swapBytes: row.swapBytes,
    diskClass: row.diskClass,
    fsType: row.fsType,
    arch: row.arch,
    os: row.os,
    osVersion: row.osVersion,
    kernelVersion: row.kernelVersion,
    virtualization: row.virtualization,
    cpuShareGroup: row.cpuShareGroup)

proc canonicalEncoding*(profile: HardwareProfile): string =
  ## The exact bytes ``profileHash`` digests.
  ##
  ## Every field is named and length-prefixed, so no value can forge a
  ## field boundary by containing a separator, and two profiles differing
  ## only in which field holds a string cannot encode identically. The
  ## version tag is first: if the field set ever changes, every profile
  ## hash changes with it, which is a visible profile transition rather
  ## than a silent collision between two schema generations.
  var parts: seq[string] = @["runquota-host-profile/1"]
  proc field(name, value: string) =
    parts.add(name & "=" & $value.len & ":" & value)
  field("cpu_model", profile.cpuModel)
  field("physical_cores", $profile.physicalCores)
  field("logical_cores", $profile.logicalCores)
  field("ram_bytes", $profile.ramBytes)
  field("swap_bytes", $profile.swapBytes)
  field("disk_class", $profile.diskClass)
  field("fs_type", profile.fsType)
  field("arch", profile.arch)
  field("os", profile.os)
  field("os_version", profile.osVersion)
  field("kernel_version", profile.kernelVersion)
  field("virtualization", profile.virtualization)
  field("cpu_share_group", profile.cpuShareGroup)
  parts.join("\n")

proc profileHash*(profile: HardwareProfile): string =
  ## Content hash of the descriptive columns, and of nothing else. The
  ## identity of the row that records the profile, and the interval over
  ## which it was current, are deliberately not inputs: they are what the
  ## hash is used to decide.
  "sha256:" & sha256Hex(canonicalEncoding(profile))

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

proc networkFsType(fsType: string): bool =
  fsType.toLowerAscii in [
    "nfs", "nfs4", "smbfs", "cifs", "smb3", "afpfs", "webdav", "ftp",
    "fuse.sshfs", "9p", "afs"]

proc runTool(command: string; args: openArray[string]): string =
  ## A detection tool's stdout, or the empty string if it would not run.
  ## Never raises: a machine without the tool answers "unknown", it does
  ## not take the daemon down.
  if not fileExists(command):
    return ""
  try:
    let process = startProcess(command, args = @args, options = {})
    let output = process.outputStream.readAll()
    let code = process.waitForExit()
    process.close()
    if code != 0: "" else: output
  except CatchableError:
    ""
  except Defect:
    ""

# ---------------------------------------------------------------------------
# macOS
# ---------------------------------------------------------------------------

when defined(macosx):
  proc sysctlbyname(name: cstring; oldp: pointer; oldlenp: ptr csize_t;
                    newp: pointer; newlen: csize_t): cint
    {.importc: "sysctlbyname", header: "<sys/sysctl.h>".}

  type
    Statfs {.importc: "struct statfs", header: "<sys/mount.h>",
             final, pure.} = object
      f_fstypename {.importc.}: array[16, char]
      f_mntfromname {.importc.}: array[1024, char]
      f_mntonname {.importc.}: array[1024, char]

  proc statfsC(path: cstring; buf: ptr Statfs): cint
    {.importc: "statfs", header: "<sys/mount.h>".}

  proc sysctlRaw(name: string): string =
    var size: csize_t = 0
    if sysctlbyname(name.cstring, nil, addr size, nil, 0) != 0 or size == 0:
      return ""
    result = newString(int(size))
    if sysctlbyname(name.cstring, addr result[0], addr size, nil, 0) != 0:
      return ""
    result.setLen(int(size))

  proc sysctlString(name: string): string =
    result = sysctlRaw(name)
    while result.len > 0 and result[^1] == '\0':
      result.setLen(result.len - 1)

  proc sysctlInt(name: string): int64 =
    let raw = sysctlRaw(name)
    case raw.len
    of 4: int64(cast[ptr uint32](unsafeAddr raw[0])[])
    of 8: int64(cast[ptr uint64](unsafeAddr raw[0])[])
    else: 0

  proc cString(field: openArray[char]): string =
    for c in field:
      if c == '\0':
        return
      result.add(c)

  proc parseSwapTotalBytes(usage: string): int64 =
    ## ``vm.swapusage`` reads ``total = 1024.00M  used = ...``.
    let parts = usage.split('=')
    if parts.len < 2:
      return 0
    let field = parts[1].strip().split()[0]
    if field.len < 2:
      return 0
    let scale =
      case field[^1]
      of 'K', 'k': 1024.0
      of 'M', 'm': 1024.0 * 1024.0
      of 'G', 'g': 1024.0 * 1024.0 * 1024.0
      else: 1.0
    try:
      int64(parseFloat(field[0 ..< field.len - 1]) * scale)
    except ValueError:
      0

  proc existingAncestor(path: string): string =
    ## ``statfs`` needs a path that exists; the store's directory may be
    ## about to be created. Walk up until something does.
    var probe = if path.len > 0: path else: "/"
    while probe.len > 1 and not fileExists(probe) and not dirExists(probe):
      probe = probe.parentDir
    probe

  # `statfs` copies out of the path before it returns, so the borrowed
  # `cstring` cannot outlive the string it came from. Nim's lifetime
  # analysis cannot see that through a call, and the resulting warning
  # would be indistinguishable from a real one somewhere else in this
  # file, so it is silenced here and only here.
  {.push warning[CStringConv]: off.}
  proc mountedFilesystem(path: string): tuple[fsType, device: string] =
    let probe = existingAncestor(path)
    var buffer: Statfs
    if statfsC(probe.cstring, addr buffer) != 0:
      return (unknownField, "")
    (cString(buffer.f_fstypename), cString(buffer.f_mntfromname))
  {.pop.}

  proc diskClassOf(fsType, device: string): DiskClass =
    if networkFsType(fsType):
      return dcNetwork
    if device.len == 0:
      return dcUnknown
    # `diskutil` is the only interface that answers "is this rotating
    # rust" on macOS without linking IOKit. It runs once, at daemon
    # startup, and a machine without it degrades to `unknown`.
    let info = runTool("/usr/sbin/diskutil", ["info", device])
    if info.len == 0:
      return dcUnknown
    var solidState = ""
    var protocol = ""
    for line in info.splitLines():
      let parts = line.split(':', maxsplit = 1)
      if parts.len != 2:
        continue
      case parts[0].strip()
      of "Solid State": solidState = parts[1].strip()
      of "Protocol": protocol = parts[1].strip()
      else: discard
    if solidState.startsWith("No"):
      return dcHdd
    if not solidState.startsWith("Yes"):
      return dcUnknown
    if protocol in ["Apple Fabric", "PCI-Express", "NVMe", "PCI"]:
      dcNvme
    else:
      dcSsd

  proc detectPlatform(referencePath: string; profile: var HardwareProfile) =
    let cpuModel = sysctlString("machdep.cpu.brand_string")
    profile.cpuModel = if cpuModel.len > 0: cpuModel else: unknownField
    profile.physicalCores = sysctlInt("hw.physicalcpu")
    profile.logicalCores = sysctlInt("hw.logicalcpu")
    profile.ramBytes = sysctlInt("hw.memsize")
    profile.swapBytes =
      quantizeSwapBytes(parseSwapTotalBytes(sysctlString("vm.swapusage")))
    let machine = sysctlString("hw.machine")
    profile.arch = if machine.len > 0: machine else: unknownField
    profile.os = "darwin"
    let productVersion = sysctlString("kern.osproductversion")
    profile.osVersion =
      if productVersion.len > 0: productVersion else: unknownField
    let release = sysctlString("kern.osrelease")
    let build = sysctlString("kern.osversion")
    profile.kernelVersion =
      if release.len == 0: unknownField
      elif build.len == 0: release
      else: release & " (" & build & ")"
    # `kern.hv_vmm_present` is macOS's own answer to "am I a guest". There
    # is no container runtime on macOS that this daemon can be inside.
    profile.virtualization =
      if sysctlInt("kern.hv_vmm_present") != 0: "vm" else: "bare-metal"
    let mounted = mountedFilesystem(referencePath)
    profile.fsType =
      if mounted.fsType.len > 0: mounted.fsType else: unknownField
    profile.diskClass = diskClassOf(mounted.fsType, mounted.device)

# ---------------------------------------------------------------------------
# Linux
# ---------------------------------------------------------------------------

elif defined(linux):
  # NOT EXECUTED ANYWHERE YET. Everything in this branch is written from
  # the documented contents of `/proc` and `/sys` and has never run on a
  # Linux host: no field below has been compared against a real machine,
  # and the campaign's rule is that a finding only counts on the OS it was
  # reproduced on. Treat a wrong value here as a first observation, not a
  # regression. What macOS does prove is the shape: detection feeds
  # `profileHash`, `ensureHostProfile` reuses on an unchanged hash, and
  # both are platform-independent.
  import std/posix

  proc readFileOrEmpty(path: string): string =
    try:
      if fileExists(path): readFile(path) else: ""
    except CatchableError:
      ""

  proc keyValue(text, key, separator: string): string =
    for line in text.splitLines():
      let parts = line.split(separator, maxsplit = 1)
      if parts.len == 2 and parts[0].strip() == key:
        return parts[1].strip()
    ""

  proc kilobytesField(text, key: string): int64 =
    let value = keyValue(text, key, ":")
    if value.len == 0:
      return 0
    let digits = value.split()[0]
    try:
      parseBiggestInt(digits) * 1024
    except ValueError:
      0

  proc coreCounts(cpuinfo: string): tuple[physical, logical: int64] =
    var logical = 0'i64
    var pairs: seq[string] = @[]
    var physicalId = ""
    var coreId = ""
    for line in cpuinfo.splitLines():
      let parts = line.split(':', maxsplit = 1)
      if parts.len != 2:
        if line.strip().len == 0 and physicalId.len > 0 and coreId.len > 0:
          let key = physicalId & "/" & coreId
          if key notin pairs:
            pairs.add(key)
          physicalId = ""
          coreId = ""
        continue
      case parts[0].strip()
      of "processor": logical += 1
      of "physical id": physicalId = parts[1].strip()
      of "core id": coreId = parts[1].strip()
      else: discard
    if physicalId.len > 0 and coreId.len > 0:
      let key = physicalId & "/" & coreId
      if key notin pairs:
        pairs.add(key)
    let physical = if pairs.len > 0: int64(pairs.len) else: logical
    (physical, logical)

  proc cpuModelOf(cpuinfo: string): string =
    for key in ["model name", "Model", "Hardware", "cpu model", "cpu"]:
      let value = keyValue(cpuinfo, key, ":")
      if value.len > 0:
        return value
    unknownField

  proc mountedFilesystem(path: string): tuple[fsType, device: string] =
    ## The longest mount point in `/proc/self/mountinfo` that is a prefix
    ## of `path`. Longest wins because mounts nest.
    var probe = if path.len > 0: path else: "/"
    while probe.len > 1 and not fileExists(probe) and not dirExists(probe):
      probe = probe.parentDir
    result = (unknownField, "")
    var bestLength = -1
    for line in readFileOrEmpty("/proc/self/mountinfo").splitLines():
      let halves = line.split(" - ", maxsplit = 1)
      if halves.len != 2:
        continue
      let left = halves[0].split()
      let right = halves[1].split()
      if left.len < 5 or right.len < 2:
        continue
      let mountPoint = left[4]
      if not (probe == mountPoint or probe.startsWith(
          if mountPoint.endsWith("/"): mountPoint else: mountPoint & "/")):
        continue
      if mountPoint.len > bestLength:
        bestLength = mountPoint.len
        result = (right[0], right[1])

  proc diskClassOf(fsType, device: string): DiskClass =
    if networkFsType(fsType):
      return dcNetwork
    if not device.startsWith("/dev/"):
      return dcUnknown
    var name = device[5 .. ^1]
    if name.startsWith("nvme"):
      return dcNvme
    # Strip a partition suffix: sda1 -> sda, mmcblk0p1 -> mmcblk0.
    while name.len > 1 and name[^1] in {'0' .. '9'}:
      name.setLen(name.len - 1)
    let rotational =
      readFileOrEmpty("/sys/block/" & name & "/queue/rotational").strip()
    case rotational
    of "1": dcHdd
    of "0": dcSsd
    else: dcUnknown

  proc virtualizationOf(): string =
    if fileExists("/.dockerenv") or
        "docker" in readFileOrEmpty("/proc/1/cgroup") or
        "libpod" in readFileOrEmpty("/proc/1/cgroup"):
      return "container"
    let hypervisor = readFileOrEmpty("/sys/hypervisor/type").strip()
    if hypervisor.len > 0:
      return "vm"
    let product =
      readFileOrEmpty("/sys/class/dmi/id/product_name").strip().toLowerAscii
    for marker in ["kvm", "qemu", "vmware", "virtualbox", "bochs", "xen",
                   "hyper-v", "virtual machine"]:
      if marker in product:
        return "vm"
    "bare-metal"

  proc detectPlatform(referencePath: string; profile: var HardwareProfile) =
    let cpuinfo = readFileOrEmpty("/proc/cpuinfo")
    let meminfo = readFileOrEmpty("/proc/meminfo")
    let counts = coreCounts(cpuinfo)
    profile.cpuModel = cpuModelOf(cpuinfo)
    profile.physicalCores = counts.physical
    profile.logicalCores = counts.logical
    profile.ramBytes = kilobytesField(meminfo, "MemTotal")
    profile.swapBytes = quantizeSwapBytes(kilobytesField(meminfo, "SwapTotal"))
    var name: Utsname
    if uname(name) == 0:
      profile.arch = $cast[cstring](addr name.machine)
      profile.os = ($cast[cstring](addr name.sysname)).toLowerAscii
      profile.kernelVersion = $cast[cstring](addr name.release)
    else:
      profile.arch = unknownField
      profile.os = "linux"
      profile.kernelVersion = unknownField
    let osRelease = readFileOrEmpty("/etc/os-release")
    var version = keyValue(osRelease, "PRETTY_NAME", "=").strip(chars = {'"'})
    if version.len == 0:
      version = keyValue(osRelease, "VERSION_ID", "=").strip(chars = {'"'})
    profile.osVersion = if version.len > 0: version else: unknownField
    profile.virtualization = virtualizationOf()
    let mounted = mountedFilesystem(referencePath)
    profile.fsType =
      if mounted.fsType.len > 0: mounted.fsType else: unknownField
    profile.diskClass = diskClassOf(mounted.fsType, mounted.device)

# ---------------------------------------------------------------------------
# Everything else
# ---------------------------------------------------------------------------

else:
  # NOT EXECUTED ANYWHERE YET, and deliberately not written speculatively
  # either. Windows detection wants `GetLogicalProcessorInformationEx`,
  # `GlobalMemoryStatusEx` and an `IOCTL_STORAGE_QUERY_PROPERTY` for the
  # media type; guessing at them here would produce a profile that looks
  # detected and is not. Reporting `unknown` is a worse profile and an
  # honest one: `ensureHostProfile` still reuses rather than accumulates,
  # because `unknown` is stable.
  import std/cpuinfo

  proc detectPlatform(referencePath: string; profile: var HardwareProfile) =
    discard referencePath
    profile.cpuModel = unknownField
    profile.logicalCores = int64(countProcessors())
    profile.physicalCores = profile.logicalCores
    profile.ramBytes = 0
    profile.swapBytes = 0
    profile.arch = hostCPU
    profile.os = hostOS
    profile.osVersion = unknownField
    profile.kernelVersion = unknownField
    profile.virtualization = unknownField
    profile.fsType = unknownField
    profile.diskClass = dcUnknown

proc detectHardwareProfile*(referencePath = "";
                            cpuShareGroup = "local"): HardwareProfile =
  ## Detects this machine's hardware profile.
  ##
  ## ``referencePath`` selects which filesystem ``fs_type`` and
  ## ``disk_class`` describe — the daemon passes the observation database's
  ## own directory, because the disk that matters to a build's duration is
  ## the one the work happens on, and that is the one the store lives on.
  ## An empty path means the root filesystem.
  ##
  ## ``cpu_share_group`` is not a detectable fact: it is RunQuota's own
  ## machine-model grouping, supplied by the daemon from its topology so a
  ## merged database can tell a pinned VM from a co-tenant guest.
  result = HardwareProfile(
    cpuModel: unknownField,
    physicalCores: 0,
    logicalCores: 0,
    ramBytes: 0,
    swapBytes: 0,
    diskClass: dcUnknown,
    fsType: unknownField,
    arch: unknownField,
    os: unknownField,
    osVersion: unknownField,
    kernelVersion: unknownField,
    virtualization: unknownField,
    cpuShareGroup: cpuShareGroup)
  try:
    detectPlatform(referencePath, result)
  except CatchableError:
    discard
  if result.logicalCores <= 0:
    result.logicalCores = 1
  if result.physicalCores <= 0:
    result.physicalCores = result.logicalCores
