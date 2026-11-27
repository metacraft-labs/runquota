## The rules of cgroup placement below admission, and the launcher's
## behaviour when placement cannot happen.
##
## WHAT IS GUARDED, each with the change that makes it fail:
##
## * Priority to `cpu.weight` (low 25, normal 100, high 400, urgent 1600,
##   reclaimed 1), and the nice fallback (reclaimed +10, low +5, else 0).
##   Mutation: any other value.
## * A group name can never leave its directory: every byte outside
##   `[A-Za-z0-9_:@-]` is escaped, so `/`, `.`, `..`, `cgroup.procs`, control
##   bytes and non-ASCII bytes all become one plain component below the
##   root, distinct names stay distinct, and over-long names are shortened
##   with a hash and stay distinct. Mutation: keeping `.` or `/` unescaped
##   (the traversal cases fail).
## * `cpu.max` from a grant: quota = milli-CPU × 100 µs per 100 ms period,
##   never below the kernel's 1 ms. Mutation: a quota from whole CPUs.
## * The root: `off`, an explicit path (only inside the cgroup v2 mount, no
##   `.`/`..`), and the default below the caller's own `user@<uid>.service`
##   only. Mutation: accepting an explicit path outside the mount, or a
##   default for a process not inside its own user manager.
## * A root that would take the tree out of its caller's limits: the
##   launcher's own cgroup and its ancestors below the deepest cgroup the
##   root also lies in are checked, with a fake reader, and a
##   `memory.max`/`memory.high`/`memory.swap.max` other than `max`, a
##   `cpu.max` with a quota, or a `pids.max` below systemd's default task
##   limit (15% of the smaller of the kernel's `pid_max` and `threads-max`;
##   any `pids.max` other than `max` when those cannot be read) makes the
##   root unavailable with the cgroup, the file and the value in the
##   reason: a limit on the own
##   scope, on an intermediate ancestor (`app.slice`), the explicit root as
##   well as the default; a limit on a common ancestor (`user@.service`),
##   a root below the limited cgroup, `max` values and `cpu.max "max
##   100000"` leave it usable. Mutations: `resolveCgroupRoot` not calling
##   `limitLeftBehind` (every "unavailable" case fails), checking only the
##   own cgroup (the `app.slice` case), checking up to the mount instead of
##   stopping at the common ancestor (the `user@.service` case), comparing
##   paths by string prefix (the `app.slice-x` case), reading `cpu.max`'s
##   period instead of its quota or treating `max` as a limit (the `max`
##   case), checking only the default root (the explicit case), counting
##   every `pids.max` other than `max` (the systemd-default case: every
##   launcher in a systemd unit would decline), comparing with `<=` or
##   taking the larger kernel limit (the boundary and smaller-limit
##   cases), and ignoring `pids.max` when the kernel files cannot be read
##   (the unreadable cases).
## * The capability records for Linux (placement on, and unavailable with
##   its reason), macOS and Windows, and their JSON.
## * Degradation, with real processes: a placement whose directories cannot
##   be created, and a leaf the kernel refuses the child (one that enables a
##   domain controller for its own children, EBUSY), both still start the child,
##   report why it is not placed, and give it the fallback nice. Mutation:
##   not applying `placementFallbackNice` when the child is not placed.
## * Placement, where this user has a delegated cgroup v2 subtree: the
##   forked child writes itself into its leaf before it executes, and
##   `close` removes the leaf and the group directory once empty. Mutation:
##   the child skipping its write into `cgroup.procs`. (Reported SKIPPED
##   with the reason where there is no delegated subtree, or where this
##   process runs under a limit a tree placed in the test root would leave:
##   `delegatedTestRoot`.)
##
## * Concurrent launchers of one group: each tree lands in the shared leaf
##   although the others' clean-up keeps removing the leaf and the group
##   directory. Two mechanisms guard it, the root's lock (a clean-up never
##   runs between a launcher's preparation and its child's join) and the
##   retry of a directory that vanished anyway; the test fails when neither
##   is there. Mutation: launching and cleaning up without the root's lock
##   and without the retry (the reviewed implementation before both) -- 8
##   of 600 trees unplaced in one run.
##
## NO MOCKS: real processes, real cgroups of a test-owned root.
import std/[json, os, osproc, sets, strutils, unittest]
import runquota_core
import runquota_process
when defined(linux):
  import std/posix
  import cgroup_test_root

when defined(linux):
  proc getpriority(which: cint; who: Id): cint {.importc, header: "<sys/resource.h>".}
  var PRIO_PROCESS {.importc, header: "<sys/resource.h>".}: cint

  proc launchAndReport(target: CgroupTarget; fallback: int): string =
    ## Launch this binary in `--report` mode with `target` and `fallback`;
    ## return "<cgroupPath>|<problem>|<child's report>".
    var spec = commandSpec([getAppFilename(), "--report"])
    spec.cgroup = target
    spec.placementFallbackNice = fallback
    var child = launchProcess(spec)
    let info = child.info
    let completion = child.waitForCompletion()
    child.close()
    info.cgroupPath & "|" & info.cgroupProblem & "|" & completion.stdout.strip()

  if paramCount() >= 1 and paramStr(1) == "--report":
    # The child: its nice value and its cgroup.
    echo $getpriority(PRIO_PROCESS, Id(0)) & " " &
      cgroupOfPid(getCurrentProcessId())
    quit(0)

  if paramCount() >= 3 and paramStr(1) == "--churn":
    # One of several concurrent launchers of the same group: launch
    # `count` short children into the group's shared leaf, one after the
    # other, each removing the leaf and the group directory when it is the
    # last one out. Exit status: how many children were not placed, or
    # did not run in the leaf (0 = every one was).
    let target = targetFor(CgroupRoot(state: crsExplicit, path: paramStr(2)),
      "churn", sessionPriorityNormal, reclaimed = false)
    var misplaced = 0
    for _ in 0 ..< parseInt(paramStr(3)):
      let parts = launchAndReport(target, LowPriorityNiceIncrement).split('|')
      let report = parts[2].splitWhitespace()
      if parts[0] != target.leafPath or report.len < 2 or
          report[1] != target.leafPath[CgroupMountPoint.len .. ^1]:
        inc misplaced
        stderr.writeLine("misplaced: " & parts[0] & " | " & parts[1] &
          " | " & parts[2])
    quit(min(misplaced, 100))

const
  UserService = "/user.slice/user-1000.slice/user@1000.service"
  OwnScope = UserService & "/app.slice/run-1.scope"

var fakeLimits: seq[(string, string)]
  ## (absolute interface file path, contents) the fake reader answers; every
  ## other file reads as absent. Set by each case before it resolves.

proc fakeRead(path: string): string {.nimcall, gcsafe, raises: [].} =
  ## The cgroup interface files of a made-up hierarchy: what the limit check
  ## is to compare must not depend on the cgroups of the host running the
  ## test. Justified as a fake: the decision is pure over file contents, and
  ## the real-file path is driven end to end by
  ## `tests/integration/t_cgroup_placement_caller_limits.nim`.
  {.cast(gcsafe).}:
    for (file, text) in fakeLimits:
      if file == path:
        return text
  ""

proc noLimits(path: string): string {.nimcall, gcsafe, raises: [].} = ""

proc limitAt(cgroup, file, value: string) =
  fakeLimits.add((CgroupMountPoint & cgroup & "/" & file, value & "\n"))

suite "cgroup placement rules":
  test "priority to cpu.weight, and the nice fallback":
    check cpuWeightFor(sessionPriorityLow) == 25
    check cpuWeightFor(sessionPriorityNormal) == 100
    check cpuWeightFor(sessionPriorityHigh) == 400
    check cpuWeightFor(sessionPriorityUrgent) == 1600
    check ReclaimedCpuWeight == 1
    for p in SessionPriority:
      if p != high(SessionPriority):
        check cpuWeightFor(p) < cpuWeightFor(succ(p))
      check ReclaimedCpuWeight < cpuWeightFor(p)
    check fallbackNice(sessionPriorityUrgent, reclaimed = true) == 10
    check fallbackNice(sessionPriorityLow, reclaimed = false) == 5
    check fallbackNice(sessionPriorityNormal, reclaimed = false) == 0
    check fallbackNice(sessionPriorityHigh, reclaimed = false) == 0
    check fallbackNice(sessionPriorityUrgent, reclaimed = false) == 0

  test "Windows: priority to Job Object class, and the switch resolution":
    # The five classes below realtime, lowest to highest, no collision, each
    # one step above the one below -- the Windows analogue of the cpu.weight
    # tiers. Mutation: any other mapping, e.g. normal for every tier.
    check jobPriorityClassFor(sessionPriorityLow, false) == BelowNormalPriorityClass
    check jobPriorityClassFor(sessionPriorityNormal, false) == NormalPriorityClass
    check jobPriorityClassFor(sessionPriorityHigh, false) == AboveNormalPriorityClass
    check jobPriorityClassFor(sessionPriorityUrgent, false) == HighPriorityClass
    # A reclaimed grant goes to idle whatever its group.
    for p in SessionPriority:
      check jobPriorityClassFor(p, reclaimed = true) == IdlePriorityClass
    # No two tiers share a class.
    var seen: HashSet[uint32]
    for p in SessionPriority:
      seen.incl jobPriorityClassFor(p, false)
    seen.incl IdlePriorityClass
    check seen.len == 5
    # The switch: the variable's `off` wins; `on` turns it on; empty and any
    # other value defer to the host switch. Mutation: ignoring the `off`
    # override, or defaulting an empty value to on.
    check resolveJobPriority("off", hostSwitchOn = true) == false
    check resolveJobPriority("on", hostSwitchOn = false) == true
    check resolveJobPriority("", hostSwitchOn = false) == false
    check resolveJobPriority("", hostSwitchOn = true) == true
    check resolveJobPriority("  off  ", hostSwitchOn = true) == false
    check resolveJobPriority("garbage", hostSwitchOn = true) == true
    check resolveJobPriority("garbage", hostSwitchOn = false) == false

  test "a group name cannot leave its directory":
    let root = "/sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/runquota.slice"
    let hostile = ["..", ".", "../..", "a/../../b", "/etc", "x/", "cgroup.procs",
      "cpu.weight", "reclaimed", "shared", "a\nb", "a\0b", "tab\there",
      "ünïcode", "%2E%2E", "~", "-", "@", "a:b@c-d_e"]
    var seen = initHashSet[string]()
    for name in hostile:
      let dir = groupDirName(name)
      check '/' notin dir
      check '.' notin dir
      check '\0' notin dir and '\n' notin dir
      check dir.startsWith(GroupDirPrefix)
      check dir != ReclaimedDirName
      check dir.len <= 255
      for ch in dir[GroupDirPrefix.len .. ^1]:
        check ch in {'A'..'Z', 'a'..'z', '0'..'9', '_', ':', '@', '-', '%', '~'}
      let target = targetFor(CgroupRoot(state: crsExplicit, path: root), name,
        sessionPriorityNormal, reclaimed = false)
      check target.leafPath.parentDir.parentDir == root
      check normalizedPath(target.leafPath).startsWith(root & "/")
      check not seen.contains(dir)
      seen.incl(dir)
    check groupDirName("a:b@c-d_e") == "group-a:b@c-d_e"
    check groupDirName("..") == "group-%2E%2E"
    check groupDirName("%2E%2E") == "group-%252E%252E"
    check groupDirName("") == "group-" & InteractiveSessionGroup
    check groupDirName("reclaimed") == "group-reclaimed"

  test "long names are shortened and stay distinct":
    let a = repeat('/', 128)
    let b = repeat('/', 127) & "."
    let c = repeat('x', 128)
    for name in [a, b]:
      let escaped = escapeGroupName(name)
      check escaped.len <= MaxEscapedNameBytes
      check '~' in escaped
      check GroupDirPrefix.len + escaped.len <= 255
      # The cut never splits an escape: every `%` is followed by two hex
      # digits before the `~`.
      let body = escaped.split('~')[0]
      var i = 0
      while i < body.len:
        if body[i] == '%':
          check i + 2 < body.len + 1 and body.len >= i + 3
          i += 3
        else:
          i += 1
    check escapeGroupName(a) != escapeGroupName(b)
    check escapeGroupName(c) == c   # 128 plain bytes fit unshortened

  test "cpu.max from a grant":
    check cpuMaxFor(1000) == "100000 100000"
    check cpuMaxFor(2500) == "250000 100000"
    check cpuMaxFor(8000) == "800000 100000"
    check cpuMaxFor(10) == "1000 100000"     # the kernel's 1 ms minimum
    check cpuMaxFor(0) == "1000 100000"

  test "cap leaves and targets":
    let root = CgroupRoot(state: crsExplicit, path: "/sys/fs/cgroup/t/r")
    let capped = targetFor(root, "g", sessionPriorityHigh, reclaimed = false,
      capMilli = 2000, launcherPid = 42, capSequence = 7)
    check capped.leafPath == "/sys/fs/cgroup/t/r/group-g/cap-42-7"
    check capped.cpuMax == "200000 100000"
    check capped.cpuWeight == 400
    check capped.isCapLeaf
    let reclaimed = targetFor(root, "g", sessionPriorityHigh, reclaimed = true)
    check reclaimed.leafPath == "/sys/fs/cgroup/t/r/reclaimed/shared"
    check reclaimed.cpuWeight == ReclaimedCpuWeight
    check not reclaimed.isCapLeaf
    check not targetFor(CgroupRoot(state: crsOff), "g", sessionPriorityHigh,
      reclaimed = false).placed

  test "the root":
    const own = "0::/user.slice/user-1000.slice/user@1000.service/app.slice/x.scope\n"
    check resolveCgroupRoot("off", own, 1000, hostSwitchOn = true, isLinux = true, read = noLimits).state == crsOff
    check resolveCgroupRoot(" off ", own, 1000, hostSwitchOn = true, isLinux = true, read = noLimits).state == crsOff
    let default = resolveCgroupRoot("", own, 1000, hostSwitchOn = true, isLinux = true, read = noLimits)
    check default.state == crsDefault
    check default.path ==
      "/sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/runquota.slice"
    # Another uid's manager, a system service, cgroup v1 only: no default.
    check resolveCgroupRoot("", own, 1001, hostSwitchOn = true, isLinux = true, read = noLimits).state == crsUnavailable
    check resolveCgroupRoot("", "0::/system.slice/ci.service\n", 1000,
      hostSwitchOn = true, isLinux = true, read = noLimits).state == crsUnavailable
    check resolveCgroupRoot("", "1:cpu:/x\n", 1000,
      hostSwitchOn = true, isLinux = true, read = noLimits).state == crsUnavailable
    # The host switch: off by default; the variable's explicit root turns
    # placement on whatever the switch says, and its `off` wins over an on.
    check resolveCgroupRoot("", own, 1000, hostSwitchOn = false,
      isLinux = true, read = noLimits).state == crsOff
    let explicit = resolveCgroupRoot("/sys/fs/cgroup/a/b/", own, 1000,
      hostSwitchOn = false, isLinux = true, read = noLimits)
    check explicit.state == crsExplicit
    check explicit.path == "/sys/fs/cgroup/a/b"
    for bad in ["/tmp/x", "relative", "/sys/fs/cgroup", "/sys/fs/cgroup/",
                "/sys/fs/cgroup/../../etc", "/sys/fs/cgroup/a/./b",
                "/sys/fs/cgroupX/a", "/sys/fs/cgroup/a\nb"]:
      let resolved = resolveCgroupRoot(bad, own, 1000, hostSwitchOn = true, isLinux = true, read = noLimits)
      check resolved.state == crsUnavailable
      check resolved.reason.startsWith(CgroupRootEnvVar)
    check resolveCgroupRoot("", own, 1000, hostSwitchOn = true, isLinux = false, read = noLimits).state ==
      crsUnavailable

  test "a root that would take the tree out of its caller's limits":
    let own = "0::" & OwnScope & "\n"
    let defaultRoot = CgroupMountPoint & UserService & "/" & DefaultRootName
    proc resolved(env: string): CgroupRoot =
      resolveCgroupRoot(env, own, 1000, hostSwitchOn = true, isLinux = true,
        read = fakeRead)
    # A MemoryMax on the caller's own scope: the default root (a sibling
    # below user@1000.service) would leave it.
    fakeLimits = @[]
    limitAt(OwnScope, "memory.max", "4294967296")
    var root = resolved("")
    check root.state == crsUnavailable
    check "memory.max" in root.reason
    check "4294967296" in root.reason
    check CgroupMountPoint & OwnScope in root.reason
    check limitLeftBehind(OwnScope, defaultRoot, fakeRead) == root.reason
    # The explicit root is checked the same way.
    root = resolved(CgroupMountPoint & UserService & "/elsewhere.slice")
    check root.state == crsUnavailable
    check "memory.max" in root.reason
    # A root at or below the limited cgroup keeps the tree inside it.
    root = resolved(CgroupMountPoint & OwnScope & "/rq")
    check root.state == crsExplicit
    check limitLeftBehind(OwnScope, CgroupMountPoint & OwnScope, fakeRead) == ""
    # A limit on an intermediate ancestor the root is not in (app.slice).
    fakeLimits = @[]
    limitAt(UserService & "/app.slice", "memory.high", "8G")
    root = resolved("")
    check root.state == crsUnavailable
    check "memory.high" in root.reason
    check CgroupMountPoint & UserService & "/app.slice" in root.reason
    # A limit on a common ancestor (user@.service) stays over the tree.
    fakeLimits = @[]
    limitAt(UserService, "memory.max", "1073741824")
    limitAt(UserService, "pids.max", "100")
    limitAt(UserService, "cpu.max", "50000 100000")
    check resolved("").state == crsDefault
    # Component-wise, not by string prefix: `app.slice-x` is not inside
    # `app.slice`, so a root there still leaves app.slice's limit.
    fakeLimits = @[]
    limitAt(UserService & "/app.slice", "memory.max", "1073741824")
    check resolved(CgroupMountPoint & UserService & "/app.slice-x").state ==
      crsUnavailable
    check resolved(CgroupMountPoint & UserService & "/app.slice/rq").state ==
      crsExplicit
    # `max` everywhere, and a cpu.max with no quota, are no limit.
    fakeLimits = @[]
    for file in ["memory.max", "memory.high", "memory.swap.max", "pids.max"]:
      limitAt(OwnScope, file, "max")
    limitAt(OwnScope, "cpu.max", "max 100000")
    check resolved("").state == crsDefault
    # An empty file is no limit either (absent ones are covered above).
    fakeLimits = @[]
    limitAt(OwnScope, "memory.max", "")
    check resolved("").state == crsDefault
    # cpu.max with a quota, pids.max and memory.swap.max with a number.
    for (file, value) in [("cpu.max", "50000 100000"), ("pids.max", "100"),
                          ("memory.swap.max", "0")]:
      fakeLimits = @[]
      limitAt(OwnScope, file, value)
      root = resolved("")
      check root.state == crsUnavailable
      check file in root.reason
      check value in root.reason
    # pids.max against systemd's default task limit, 15% of the smaller of
    # the kernel's pid_max and threads-max (this host's figures: 1027717 *
    # 15 div 100 = 154157, the value systemd writes on every unit).
    proc withKernel(pidsMax: string) =
      fakeLimits = @[]
      fakeLimits.add((KernelPidMaxPath, "4194304\n"))
      fakeLimits.add((KernelThreadsMaxPath, "1027717\n"))
      limitAt(OwnScope, "pids.max", pidsMax)
    check defaultTasksMaxThreshold(fakeRead) == -1   # no kernel files yet
    withKernel("154157")
    check defaultTasksMaxThreshold(fakeRead) == 154157
    check resolved("").state == crsDefault           # the systemd default
    withKernel("200000")
    check resolved("").state == crsDefault           # above it
    withKernel("154156")
    root = resolved("")
    check root.state == crsUnavailable               # just below it
    check "pids.max is 154156" in root.reason
    withKernel("64")                                 # -p TasksMax=64
    root = resolved("")
    check root.state == crsUnavailable
    check "pids.max is 64" in root.reason
    check "154157" in root.reason
    # The smaller of the two kernel limits sets the threshold.
    fakeLimits = @[]
    fakeLimits.add((KernelPidMaxPath, "32768\n"))
    fakeLimits.add((KernelThreadsMaxPath, "1027717\n"))
    limitAt(OwnScope, "pids.max", "154157")
    check defaultTasksMaxThreshold(fakeRead) == 4915
    check resolved("").state == crsDefault
    # Either kernel file unreadable (or not a count): every pids.max other
    # than `max` counts.
    for (pidMax, threadsMax) in [("", "1027717\n"), ("4194304\n", ""),
                                 ("junk\n", "1027717\n")]:
      fakeLimits = @[]
      if pidMax.len > 0: fakeLimits.add((KernelPidMaxPath, pidMax))
      if threadsMax.len > 0: fakeLimits.add((KernelThreadsMaxPath, threadsMax))
      limitAt(OwnScope, "pids.max", "154157")
      root = resolved("")
      check root.state == crsUnavailable
      check "pids.max is 154157" in root.reason
      check "could not be read" in root.reason
    # pids.max `max` is no limit whatever the kernel files say.
    withKernel("max")
    check resolved("").state == crsDefault
    # Placement off reads nothing and checks nothing.
    fakeLimits = @[]
    limitAt(OwnScope, "memory.max", "4294967296")
    check resolveCgroupRoot("off", own, 1000, hostSwitchOn = true,
      isLinux = true, read = fakeRead).state == crsOff
    check resolveCgroupRoot("", own, 1000, hostSwitchOn = false,
      isLinux = true, read = fakeRead).state == crsOff
    # The process in the root cgroup itself, or with no cgroup v2 line,
    # leaves nothing.
    check limitLeftBehind("/", defaultRoot, fakeRead) == ""
    check limitLeftBehind("", defaultRoot, fakeRead) == ""
    fakeLimits = @[]

suite "capability records":
  test "Linux with placement, and without":
    let on = enforcementRecordFor("linux",
      CgroupRoot(state: crsDefault, path: "/sys/fs/cgroup/u/runquota.slice"), "")
    check on.placement == "on"
    check on.gaps.len == 1
    check on.gaps[0].mechanism == emMemoryCap
    let off = enforcementRecordFor("linux",
      CgroupRoot(state: crsDefault, path: "/sys/fs/cgroup/u/runquota.slice"),
      "the cpu controller is not delegated")
    check off.placement == "unavailable"
    check off.gaps.len == 4
    for item in off.gaps:
      if item.mechanism != emMemoryCap:
        check "the cpu controller is not delegated" in item.gap
    let turnedOff = enforcementRecordFor("linux", CgroupRoot(state: crsOff,
      reason: "off by default"))
    check turnedOff.placement == "off"
    # Off: nothing but the reclaimed nice; no nice for a low group.
    check turnedOff.entries[0].level == elAdmissionOnly
    check turnedOff.entries[1].level == elDegraded
    check "off by default" in turnedOff.entries[0].gap

  test "macOS and Windows name what they lack":
    # macOS with the qos switch OFF (default) enforces nothing below
    # admission (its nice +10 is applied but does not schedule); Windows
    # (job-priority OFF by default) enforces the width cap (Job Object CPU rate control) and the
    # reclaimed tree's unconditional below-normal class.
    for (os, enforced) in [("macos", newSeq[string]()),
                           ("windows", @["width-cap", "reclaimed"])]:
      let record = enforcementRecordFor(os)
      check record.gaps.len == 4 - enforced.len
      let parsed = parseJson(record.toJson())
      check parsed["os"].getStr == os
      check parsed["mechanisms"].len == 4
      for item in parsed["mechanisms"]:
        if item["mechanism"].getStr in enforced:
          check item["level"].getStr == "enforced"
          check item["gap"].getStr.len == 0
        else:
          check item["level"].getStr != "enforced"
          check item["gap"].getStr.len > 0
      check "not enforced: priority: " in record.summaryLine
    check "macOS has no hard CPU cap" in enforcementRecordFor("macos").summaryLine
    check "width-cap=enforced" in enforcementRecordFor("windows").summaryLine
    check "no backend for plan9" in enforcementRecordFor("plan9").summaryLine

  test "Windows job-priority switch: off is admission-only, on enforces the lower tiers and flags the urgent gap":
    # OFF (default): priority between a user's groups is admission-only, the
    # reclaimed tree keeps its unconditional below-normal class, the width cap
    # is enforced. Mutation: windowsRecord's off branch claiming priority is
    # enforced would make the gap checks below fail.
    let off = enforcementRecordFor("windows")
    check off.entries[0].mechanism == emPriority
    check off.entries[0].level == elAdmissionOnly
    check "job priority off:" in off.entries[0].gap
    check "off by default" in off.entries[0].gap
    check off.entries[1].mechanism == emReclaimed
    check off.entries[1].level == elEnforced
    check "below-normal" in off.entries[1].how
    check off.entries[2].level == elEnforced          # width-cap
    check off.gaps.len == 2                            # priority, memory-cap
    # ON: the lower tiers (idle/below-normal/normal/above-normal, i.e.
    # reclaimed/low/normal/high) are enforced by a Job Object priority class
    # per group and the reclaimed tree is forced all the way to idle; but the
    # urgent tier's high priority class needs a privilege an ordinary launcher
    # lacks, so priority is DEGRADED with that caveat as a structural gap, not
    # a bare "enforced". Mutation: marking priority enforced with no gap (or
    # dropping the on branch) fails here.
    let on = enforcementRecordFor("windows", jobPriorityOn = true)
    check on.entries[0].mechanism == emPriority
    check on.entries[0].level == elDegraded
    check "priority class" in on.entries[0].how
    check "urgent tier" in on.entries[0].gap
    check "SeIncreaseBasePriorityPrivilege" in on.entries[0].gap
    check on.entries[1].level == elEnforced
    check "idle" in on.entries[1].how
    check on.gaps.len == 2
    check on.gaps[0].mechanism == emPriority
    check on.gaps[1].mechanism == emMemoryCap
    # A reason the resolver supplies for the off state reaches the gap text.
    let offReason = enforcementRecordFor("windows", jobPriorityOn = false,
      jobPriorityProblem = "turned off by RUNQUOTA_JOB_PRIORITY=off")
    check "turned off by RUNQUOTA_JOB_PRIORITY=off" in offReason.entries[0].gap

  test "the JSON is valid with hostile text":
    var record = enforcementRecordFor("linux", CgroupRoot(state: crsUnavailable,
      reason: "quote \" backslash \\ newline \n control \x01"))
    let parsed = parseJson(record.toJson())
    check "quote \" backslash \\ newline \n control \x01" in
      parsed["placement_problem"].getStr

when defined(linux):
  suite "launching without and with a cgroup (Linux)":
    test "directories that cannot be created: started, reported, nice fallback":
      # The parent of this root does not exist, so nothing can be created
      # (and nothing is).
      let root = "/sys/fs/cgroup/runquota-test-absent-" & $getCurrentProcessId() &
        "/root"
      let target = targetFor(CgroupRoot(state: crsExplicit, path: root), "g",
        sessionPriorityLow, reclaimed = false)
      let parts = launchAndReport(target, LowPriorityNiceIncrement).split('|')
      check parts[0] == ""
      check "cannot create cgroup" in parts[1]
      check parts[2].splitWhitespace()[0] == $LowPriorityNiceIncrement
      check not dirExists(root.parentDir)

    test "no target: the fallback nice alone":
      let parts = launchAndReport(CgroupTarget(), ReclaimedNiceIncrement).split('|')
      check parts[0] == ""
      check parts[1] == ""
      check parts[2].splitWhitespace()[0] == $ReclaimedNiceIncrement

    var reason = ""
    let testRoot = delegatedTestRoot(reason)

    test "placed: the child is created in its leaf, and close removes it":
      if testRoot.len == 0:
        echo "SKIPPED: " & reason
        skip()
      else:
        let target = targetFor(CgroupRoot(state: crsExplicit, path: testRoot),
          "unit", sessionPriorityHigh, reclaimed = false)
        let parts = launchAndReport(target, LowPriorityNiceIncrement).split('|')
        check parts[0] == target.leafPath
        check parts[1] == ""
        let report = parts[2].splitWhitespace()
        check report[0] == "0"   # placed: no fallback nice
        check report[1] == target.leafPath[CgroupMountPoint.len .. ^1]
        check not dirExists(target.leafPath)
        check not dirExists(target.dirPath)

    test "concurrent launchers of one group never lose a tree to the other's clean-up":
      if testRoot.len == 0:
        echo "SKIPPED: " & reason
        skip()
      else:
        # Four launchers in one group, each starting short trees in the
        # shared leaf one after another: every tree's end lets its launcher
        # remove the leaf and the group directory while another launcher
        # is preparing them, opening the leaf's `cgroup.procs`, or has a
        # child writing itself into it. Every tree must still land in the
        # leaf. Mutation: no root lock and no retry of a directory removed
        # during preparation -- trees then run unplaced.
        const launchers = 4
        const launchesEach = 150
        var churners: seq[Process]
        for _ in 0 ..< launchers:
          churners.add(startProcess(getAppFilename(),
            args = ["--churn", testRoot, $launchesEach],
            options = {poParentStreams}))
        var misplaced = 0
        for churner in churners:
          misplaced += churner.waitForExit()
          churner.close()
        check misplaced == 0
        check cgroupDirsBelow(testRoot).len == 0

    test "a child that cannot join its leaf: started unplaced, reported, nice fallback":
      if testRoot.len == 0:
        echo "SKIPPED: " & reason
        skip()
      else:
        # A leaf that enables a DOMAIN controller (memory; cpu is threaded
        # and exempt) for children of its own refuses processes (cgroup v2's
        # no-internal-process rule: EBUSY), so the child's write into it
        # fails after the parent opened it. Only this test root's own
        # directories are changed.
        let target = targetFor(CgroupRoot(state: crsExplicit, path: testRoot),
          "refuses", sessionPriorityLow, reclaimed = false)
        var problem = ""
        check prepareTarget(target, problem)
        writeFile(testRoot / "cgroup.subtree_control", "+memory")
        writeFile(target.dirPath / "cgroup.subtree_control", "+memory")
        writeFile(target.leafPath / "cgroup.subtree_control", "+memory")
        let parts = launchAndReport(target, LowPriorityNiceIncrement).split('|')
        check parts[0] == ""
        check "the child could not join " & target.leafPath in parts[1]
        check parts[2].splitWhitespace()[0] == $LowPriorityNiceIncrement
        check parts[2].splitWhitespace()[1] !=
          target.leafPath[CgroupMountPoint.len .. ^1]
        # The failed attempt's empty directories were taken away.
        check cgroupDirsBelow(testRoot).len == 0

    if testRoot.len > 0:
      let problem = removeTestRoot(testRoot)
      doAssert problem.len == 0, problem
