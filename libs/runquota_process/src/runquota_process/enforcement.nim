## The capability record of enforcement BELOW admission: what RunQuota's
## launchers make the operating system enforce on the trees they start, and,
## for everything they do not, what is missing and why.
##
## WHY A RECORD. Admission bounds what is granted; whether a tree that
## ignores its grant is held to its group's priority, whether reclaimed work
## really yields, and whether `runquota run --cap` really caps, depends on
## the operating system and on the host (a Linux host without a delegated CPU
## controller enforces none of it). A gap that nobody can see is a gap
## nobody can act on, so each mechanism is stated, enforced or not, and the
## record is printed by `runquota status` and by builds.
##
## THE RECORD IS THE CLIENT'S. The cgroups belong to the launching client
## and to its user, not to the daemon, so the record is computed by the
## process that prints it, for its own host and user.
##
## One builder per operating system (`enforcementRecordFor`), pure over its
## inputs, so the macOS and Windows records can be checked on any host; the
## Linux one takes the result of probing the cgroup root.
##
## Static-helper library rules apply (no `ref` types).

import std/strutils

import runquota_process/cgroup_placement
import runquota_process/job_priority
import runquota_process/qos_priority

type
  EnforcementMechanism* = enum
    emPriority = "priority"
      ## One user's session groups held to their priorities when a tree
      ## uses more CPU than it was granted.
    emReclaimed = "reclaimed"
      ## Work admitted into predicted slack runs at a lower weight.
    emWidthCap = "width-cap"
      ## `runquota run --cap` holds a tree to its granted width.
    emMemoryCap = "memory-cap"
      ## A hard memory limit on a tree.

  EnforcementLevel* = enum
    elEnforced = "enforced"
      ## The kernel enforces it.
    elDegraded = "degraded"
      ## A weaker mechanism stands in (nice instead of a cgroup weight).
    elAdmissionOnly = "admission-only"
      ## Only admission bounds it: nothing holds a tree that exceeds its
      ## grant.
    elNone = "none"
      ## Not enforced at all.

  EnforcementEntry* = object
    mechanism*: EnforcementMechanism
    level*: EnforcementLevel
    how*: string
      ## The mechanism in force, in words.
    gap*: string
      ## "" when enforced; otherwise what is missing and why.

  EnforcementRecord* = object
    os*: string
      ## `linux`, `macos` or `windows`.
    placement*: string
      ## Linux cgroup placement: `on`, `off` or `unavailable`; `n/a`
      ## elsewhere.
    cgroupRoot*: string
      ## The root trees are placed under (Linux, placement on), else "".
    placementProblem*: string
      ## Why placement is off or unavailable, else "".
    entries*: seq[EnforcementEntry]

const
  MemoryCapGap = "no RunQuota launcher sets a hard memory limit on a tree " &
    "yet; a tree that outgrows its reservation is not stopped"

proc entry(mechanism: EnforcementMechanism; level: EnforcementLevel;
           how: string; gap = ""): EnforcementEntry =
  EnforcementEntry(mechanism: mechanism, level: level, how: how, gap: gap)

proc linuxRecord(root: CgroupRoot; probeProblem: string): EnforcementRecord =
  result.os = "linux"
  let available = root.usable and probeProblem.len == 0
  if available:
    result.placement = "on"
    result.cgroupRoot = root.path
    result.entries = @[
      entry(emPriority, elEnforced, "cgroup v2 cpu.weight of " &
        root.path & "/" & GroupDirPrefix & "<group> (low 25, normal 100, " &
        "high 400, urgent 1600)"),
      entry(emReclaimed, elEnforced, "cgroup v2 cpu.weight " &
        $ReclaimedCpuWeight & " of " & root.path & "/" & ReclaimedDirName &
        ", and nice +" & $ReclaimedNiceIncrement),
      entry(emWidthCap, elEnforced,
        "cgroup v2 cpu.max of the tree's own leaf (runquota run --cap)"),
      entry(emMemoryCap, elAdmissionOnly, "admission (memory reservation)",
        MemoryCapGap),
    ]
  elif root.state == crsOff:
    # Off (by default, or by the variable): the launchers change nothing
    # below admission except the reclaimed tree's nice.
    result.placement = "off"
    result.placementProblem = root.reason
    let gap = "cgroup placement off: " & root.reason
    result.entries = @[
      entry(emPriority, elAdmissionOnly, "admission", gap),
      entry(emReclaimed, elDegraded, "nice +" & $ReclaimedNiceIncrement, gap),
      entry(emWidthCap, elNone, "runquota run --cap runs the command uncapped",
        gap),
      entry(emMemoryCap, elAdmissionOnly, "admission (memory reservation)",
        MemoryCapGap),
    ]
  else:
    let reason = if probeProblem.len > 0: probeProblem else: root.reason
    result.placement = "unavailable"
    result.placementProblem = reason
    result.entries = @[
      entry(emPriority, elDegraded, "nice +" & $LowPriorityNiceIncrement &
        " for low-priority groups; no weight between normal, high and urgent",
        "cgroup placement " & result.placement & ": " & reason),
      entry(emReclaimed, elDegraded, "nice +" & $ReclaimedNiceIncrement,
        "cgroup placement " & result.placement & ": " & reason),
      entry(emWidthCap, elNone, "runquota run --cap runs the command uncapped",
        "cgroup placement " & result.placement & ": " & reason),
      entry(emMemoryCap, elAdmissionOnly, "admission (memory reservation)",
        MemoryCapGap),
    ]

const
  MacosWidthCapGap = "macOS has no hard CPU cap for a process tree"
  MacosMemoryCapGap = "macOS has no hard memory cap for a process tree"
  MacosNiceGap = "nice +" & $ReclaimedNiceIncrement & " is applied but " &
    "measured not to change the CPU share of an exec'd tree on macOS, " &
    "which schedules by QoS class"
  MacosTwoLevelsGap = "macOS can lower a forked-and-exec'd tree only to the " &
    "background policy: a low group is held as hard as reclaimed work, and " &
    "high and urgent cannot be raised above normal (no QoS class can be " &
    "set without posix_spawn, nice does not schedule an exec'd tree, and a " &
    "negative nice needs root)"

proc macosRecord(qosOn: bool; problem = ""): EnforcementRecord =
  ## Two layers, as on Linux and Windows. A RECLAIMED tree always runs at
  ## nice +10 (unconditional), which on macOS does not change the CPU share
  ## of an exec'd tree (measured, `qos_priority`), so `reclaimed` is only
  ## `degraded` while the switch is off. With `qos` on, a reclaimed tree and
  ## a `low` group's tree run under the background policy, which the
  ## scheduler does honour (reclaimed `enforced`); priority is `degraded`
  ## because it has two levels, not four (`MacosTwoLevelsGap`).
  result.os = "macos"
  result.placement = "n/a"
  if qosOn:
    result.entries = @[
      entry(emPriority, elDegraded,
        "background policy (setpriority PRIO_DARWIN_BG) for low-priority " &
        "groups and reclaimed trees; normal, high and urgent unchanged",
        MacosTwoLevelsGap),
      entry(emReclaimed, elEnforced,
        "background policy (setpriority PRIO_DARWIN_BG: lowest CPU " &
        "priority, throttled IO), inherited by every process of the tree"),
      entry(emWidthCap, elNone, "runquota run --cap runs the command uncapped",
        MacosWidthCapGap),
      entry(emMemoryCap, elNone, "admission (memory reservation)",
        MacosMemoryCapGap),
    ]
  else:
    let reason = if problem.len > 0: problem
      else: "off by default (the host file does not set [enforcement] " &
        "qos = \"on\")"
    result.placementProblem = reason
    let gap = "qos priority off: " & reason
    result.entries = @[
      entry(emPriority, elAdmissionOnly, "admission", gap),
      entry(emReclaimed, elDegraded, "nice +" & $ReclaimedNiceIncrement,
        gap & "; " & MacosNiceGap),
      entry(emWidthCap, elNone, "runquota run --cap runs the command uncapped",
        MacosWidthCapGap),
      entry(emMemoryCap, elNone, "admission (memory reservation)",
        MacosMemoryCapGap),
    ]

const WindowsWidthCapHow = "Job Object CPU rate control, a hard cap at the " &
  "granted width (runquota run --cap)"

proc windowsRecord(jobPriorityOn: bool; problem = ""): EnforcementRecord =
  ## Two layers, as on Linux. The RECLAIMED tree always runs at least at
  ## `BELOW_NORMAL_PRIORITY_CLASS` (unconditional, like Linux's nice +10), so
  ## `reclaimed` is enforced whether or not the switch is on. PRIORITY between
  ## a user's groups needs the switchable Job Object priority-class limit: it
  ## is enforced when `job-priority` is on (degraded only for the urgent tier,
  ## whose high priority class an unprivileged launcher cannot set), and
  ## admission-only when off.
  result.os = "windows"
  result.placement = "n/a"
  if jobPriorityOn:
    result.entries = @[
      entry(emPriority, elDegraded,
        "Job Object priority class of each tree (idle for reclaimed, " &
        "below-normal/normal/above-normal/high for low/normal/high/urgent)",
        "only the urgent tier's high priority class needs " &
        "SeIncreaseBasePriorityPrivilege enabled, which the Job Object path " &
        "requires and an ordinary launcher does not hold, so an urgent " &
        "group's tree is held at normal; the idle, below-normal, normal and " &
        "above-normal tiers (reclaimed, low, normal, high) all take with no " &
        "privilege"),
      entry(emReclaimed, elEnforced,
        "Job Object priority-class limit of idle, below the unconditional " &
        "below-normal class a reclaimed tree already runs at"),
      entry(emWidthCap, elEnforced, WindowsWidthCapHow),
      entry(emMemoryCap, elAdmissionOnly, "admission (memory reservation)",
        "launchWindowsProcess reads CommandSpec.memoryCapBytes/memoryCapAction " &
        "and enforces it, but the host file's [enforcement] memoryCap " &
        "switch (and the per-run RUNQUOTA_MEMORY_CAP) are not read yet, " &
        "so no caller sets those fields"),
    ]
  else:
    let reason = if problem.len > 0: problem
      else: "off by default (the host file does not set [enforcement] " &
        "job-priority = \"on\")"
    result.placementProblem = reason
    let gap = "job priority off: " & reason
    result.entries = @[
      entry(emPriority, elAdmissionOnly, "admission", gap),
      entry(emReclaimed, elEnforced,
        "below-normal priority class of the whole tree (inherited by every " &
        "process it spawns)"),
      entry(emWidthCap, elEnforced, WindowsWidthCapHow),
      entry(emMemoryCap, elAdmissionOnly, "admission (memory reservation)",
        "launchWindowsProcess reads CommandSpec.memoryCapBytes/memoryCapAction " &
        "and enforces it, but the host file's [enforcement] memoryCap " &
        "switch (and the per-run RUNQUOTA_MEMORY_CAP) are not read yet, " &
        "so no caller sets those fields"),
    ]

proc enforcementRecordFor*(os: string; root = CgroupRoot();
                           probeProblem = "";
                           jobPriorityOn = false;
                           jobPriorityProblem = "";
                           qosOn = false;
                           qosProblem = ""): EnforcementRecord =
  ## The record for `os` (`linux`, `macos`, `windows`). On Linux `root` is
  ## the resolved cgroup root and `probeProblem` what probing it found ("" =
  ## trees can be placed there). On Windows `jobPriorityOn` is the
  ## `[enforcement] job-priority` switch in force and `jobPriorityProblem`
  ## why it is off (for the gap text); on macOS `qosOn` and `qosProblem` are
  ## the `[enforcement] qos` switch the same way. Any other OS is recorded as enforcing
  ## nothing below admission.
  case os
  of "linux": linuxRecord(root, probeProblem)
  of "macos": macosRecord(qosOn, qosProblem)
  of "windows": windowsRecord(jobPriorityOn, jobPriorityProblem)
  else:
    EnforcementRecord(os: os, placement: "n/a", entries: @[
      entry(emPriority, elAdmissionOnly, "admission", "no backend for " & os),
      entry(emReclaimed, elAdmissionOnly, "admission", "no backend for " & os),
      entry(emWidthCap, elNone, "none", "no backend for " & os),
      entry(emMemoryCap, elAdmissionOnly, "admission", "no backend for " & os)])

proc hostOsName*(): string =
  when defined(linux): "linux"
  elif defined(macosx): "macos"
  elif defined(windows): "windows"
  else: hostOS

proc hostEnforcementRecord*(root = currentCgroupRoot();
                            jobPriorityOn = currentJobPriorityOn();
                            jobPriorityProblem = jobPriorityOffReason(false);
                            qosOn = currentQosOn();
                            qosProblem = qosOffReason(false)):
    EnforcementRecord =
  ## This process's record for the enforcement its launchers would use (a
  ## launcher that reads the host file passes the root and the switch it
  ## resolved with it); on Linux the cgroup root is probed without creating
  ## anything, on Windows `jobPriorityOn` is the job-priority switch, on
  ## macOS `qosOn` the qos switch. The
  ## defaults read only the environment, as `currentCgroupRoot` does.
  enforcementRecordFor(hostOsName(), root, probeRoot(root),
    jobPriorityOn, jobPriorityProblem, qosOn, qosProblem)

proc gaps*(record: EnforcementRecord): seq[EnforcementEntry] =
  for item in record.entries:
    if item.level != elEnforced:
      result.add(item)

proc renderLines*(record: EnforcementRecord): seq[string] =
  ## One `enforcement: ...` line per mechanism, for `runquota status`.
  result.add("enforcement_os: " & record.os & " placement=" &
    record.placement & (if record.cgroupRoot.len > 0:
      " cgroup_root=" & record.cgroupRoot else: ""))
  for item in record.entries:
    result.add("enforcement: " & $item.mechanism & " " & $item.level &
      " (" & item.how & ")" &
      (if item.gap.len > 0: " gap: " & item.gap else: ""))

proc summaryLine*(record: EnforcementRecord): string =
  ## One line for a build header: every mechanism's level, then the gaps.
  var levels: seq[string]
  for item in record.entries:
    levels.add($item.mechanism & "=" & $item.level)
  result = "enforcement below admission (" & record.os & "): " &
    levels.join(" ")
  let missing = record.gaps
  if missing.len > 0:
    var reasons: seq[string]
    for item in missing:
      reasons.add($item.mechanism & ": " & item.gap)
    result.add("; not enforced: " & reasons.join("; "))

proc jsonString(text: string): string =
  ## A JSON string literal (RFC 8259 § 7). Written here rather than through
  ## `std/json`, whose tree is made of `ref` nodes this library may not use.
  result = "\""
  for ch in text:
    case ch
    of '"': result.add("\\\"")
    of '\\': result.add("\\\\")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    elif ord(ch) < 0x20:
      result.add("\\u" & toHex(ord(ch), 4).toLowerAscii)
    else:
      result.add(ch)
  result.add('"')

proc toJson*(record: EnforcementRecord): string =
  ## `{"os", "placement", "cgroup_root", "placement_problem", "mechanisms":
  ## [{"mechanism", "level", "how", "gap"}]}`: inspection output, never wire
  ## or persistent state.
  var items: seq[string]
  for item in record.entries:
    items.add("{\"mechanism\":" & jsonString($item.mechanism) &
      ",\"level\":" & jsonString($item.level) &
      ",\"how\":" & jsonString(item.how) &
      ",\"gap\":" & jsonString(item.gap) & "}")
  "{\"os\":" & jsonString(record.os) &
    ",\"placement\":" & jsonString(record.placement) &
    ",\"cgroup_root\":" & jsonString(record.cgroupRoot) &
    ",\"placement_problem\":" & jsonString(record.placementProblem) &
    ",\"mechanisms\":[" & items.join(",") & "]}"

# ---------------------------------------------------------------------------
# The capability record of MEASUREMENT
# ---------------------------------------------------------------------------
#
# What `sizing-data` can measure of a tree differs by operating system, and a
# figure that is a floor must not read as a complete one. The enforcement
# record above covers what is held below admission; this one covers what is
# measured, and is printed by `runquota status`, `runquota profile` and
# `runquota sizing` (text and JSON) and carried in the header of `runquota
# observations export --format sizing`.
#
# IT DESCRIBES THE HOST THE QUERY RAN ON, which is the daemon's host (the
# socket is local), computed from the OS at query time. It is NOT a property
# of the stored rows: those are scoped per host profile (`--host-profile
# all` can include rows another host recorded), and a row carries no
# provenance, so the record states the capability of this host's launchers
# only. No schema field is involved.

type
  MeasurementCoverage* = enum
    mcFull = "full"
      ## The figure covers the whole process tree.
    mcPartial = "partial"
      ## The figure is a lower bound: part of the tree is not counted.
    mcNone = "none"
      ## Not measured on this host.

  MeasurementQuantity* = enum
    mqWriteBytes = "write-bytes"
      ## `executions.io_write_bytes` and the write bandwidth derived from it.
    mqMemory = "memory"
      ## The tree's peak and profiled memory.

  MeasurementEntry* = object
    quantity*: MeasurementQuantity
    coverage*: MeasurementCoverage
    how*: string
    gap*: string
      ## "" when full; otherwise what the figure leaves out.

  MeasurementRecord* = object
    os*: string
    entries*: seq[MeasurementEntry]

const
  MeasurementDescribes* = "the host the daemon runs on, not the host that " &
    "recorded stored rows"

proc measurementRecordFor*(os: string): MeasurementRecord =
  ## The record for `os` (`linux`, `macos`, `windows`); pure, so every
  ## record can be checked on any host.
  result.os = os
  case os
  of "linux":
    result.entries = @[
      MeasurementEntry(quantity: mqWriteBytes, coverage: mcFull,
        how: "the whole tree: wait4 ru_oublock of the root at its " &
          "exit, in 512-byte units, which includes the descendants it " &
          "waited for"),
      MeasurementEntry(quantity: mqMemory, coverage: mcFull,
        how: "the whole tree: the sum of VmRSS over its processes")]
  of "macos":
    result.entries = @[
      MeasurementEntry(quantity: mqWriteBytes, coverage: mcPartial,
        how: "the launched root process's own writes " &
          "(proc_pid_rusage ri_diskio_byteswritten)",
        gap: "children's writes are not counted (macOS keeps no " &
          "reaped-children share of storage IO), so a root that only " &
          "forks writers reads low, often 0"),
      MeasurementEntry(quantity: mqMemory, coverage: mcPartial,
        how: "resident size summed over the tree (pti_resident_size)",
        gap: "pages the memory compressor holds are excluded, so a tree " &
          "under memory pressure reads low: the figure is a floor")]
  of "windows":
    result.entries = @[
      MeasurementEntry(quantity: mqWriteBytes, coverage: mcNone,
        how: "not measured", gap: "sizing-data is inert on windows"),
      MeasurementEntry(quantity: mqMemory, coverage: mcNone,
        how: "not measured", gap: "sizing-data is inert on windows")]
  else:
    result.entries = @[
      MeasurementEntry(quantity: mqWriteBytes, coverage: mcNone,
        how: "not measured", gap: "no backend for " & os),
      MeasurementEntry(quantity: mqMemory, coverage: mcNone,
        how: "not measured", gap: "no backend for " & os)]

proc hostMeasurementRecord*(): MeasurementRecord =
  measurementRecordFor(hostOsName())

proc renderLines*(record: MeasurementRecord): seq[string] =
  ## `measurement_os:` then one `measurement:` line per quantity, for the
  ## text of `status`, `profile` and `sizing`.
  result.add("measurement_os: " & record.os & " (describes " &
    MeasurementDescribes & ")")
  for item in record.entries:
    result.add("measurement: " & $item.quantity & " " & $item.coverage &
      " (" & item.how & ")" &
      (if item.gap.len > 0: " gap: " & item.gap else: ""))

proc toJson*(record: MeasurementRecord): string =
  ## `{"os", "describes", "measurements": [{"quantity", "coverage", "how",
  ## "gap"}]}`. Every key is present on every OS ("gap" is "" when
  ## coverage is "full") so a consumer never infers from absence.
  var items: seq[string]
  for item in record.entries:
    items.add("{\"quantity\":" & jsonString($item.quantity) &
      ",\"coverage\":" & jsonString($item.coverage) &
      ",\"how\":" & jsonString(item.how) &
      ",\"gap\":" & jsonString(item.gap) & "}")
  "{\"os\":" & jsonString(record.os) &
    ",\"describes\":" & jsonString(MeasurementDescribes) &
    ",\"measurements\":[" & items.join(",") & "]}"

proc withMeasurementKey*(objectJson: string; record: MeasurementRecord): string =
  ## `objectJson` (a JSON object) with `"measurement": <record>` as its
  ## first member, by text insertion so every other byte, number spelling
  ## included, is the daemon's. Anything that is not a non-empty object is
  ## returned unchanged.
  if objectJson.len < 2 or objectJson[0] != '{':
    return objectJson
  let rest = objectJson[1 .. ^1]
  let separator = if rest.strip().startsWith("}"): "" else: ","
  "{\"measurement\":" & record.toJson() & separator & rest
