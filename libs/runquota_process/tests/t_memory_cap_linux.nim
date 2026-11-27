## The Linux memory cap of a launched tree: a cgroup v2 leaf of its own with
## `memory.max`, `memory.swap.max` = 0 and `memory.oom.group` = 1, entered
## by `clone3(CLONE_INTO_CGROUP)`, and classified after the tree's root is
## reaped from the leaf's own `memory.events.local` and `memory.peak`.
##
## WHAT IS GUARDED, each with the change that makes it fail (the falsifying
## mutation, applied to the launcher and observed to fail here):
##
## * `test_rqm_cap_kills_only_the_tree`: a shell whose child allocates past
##   the cap dies with the child (SIGKILL), the launcher lives on, and a
##   sibling tree in another leaf of the same group keeps running to its own
##   end. Mutation: `memory.oom.group` not written to the leaf -- the kernel
##   then kills the allocator alone and the parent shell survives.
## * `test_rqm_cap_exceeded_is_classified`: the completion says the cap was
##   exceeded and the tree killed, with the cap and the leaf's peak; the
##   control, a tree killed by a limit set on the directory ABOVE its leaf,
##   is not. Mutation: classify from `oom_kill` alone -- the control then
##   reads as cap-exceeded.
## * `test_rqm_host_oom_is_not_cap_exceeded`: a kill from an ancestor's
##   `memory.max`, with the leaf under its own larger cap, is a kill from
##   outside the cap -- also for a tree that earlier ran something in a
##   sub-cgroup of its own leaf that hit a limit of its own. Mutation: take
##   `oom` from the hierarchical `memory.events` -- the sub-cgroup's OOM
##   then counts as the leaf's, and the tree reads as cap-exceeded.
## * A cap kill of an allocator the tree moved into a sub-cgroup of its own
##   leaf is the cap's (capKilled), both without a memory controller below
##   the leaf (the kill is counted on the leaf itself) and with one (it is
##   counted in the sub-cgroup, which only the leaf's HIERARCHICAL
##   `oom_kill` includes); and the sub-cgroups go with the leaf. Mutations:
##   `oom_kill` from `memory.events.local` (the controlled case reads as
##   cap reached); not removing the tree's sub-cgroups (they and the leaf
##   are left behind). The classification is the leaf's LOCAL `oom` (its
##   own limit, the cap, was hit) with its HIERARCHICAL `oom_kill`; the
##   host-OOM case above is what the local `oom` is for.
## * Swap is taken away only by an enforced cap: kill mode writes
##   `memory.swap.max` = 0, advisory and measure-only leaves leave it at
##   `max` (all three set `memory.oom.group` = 1). Mutation: writing 0 for
##   every leaf.
## * `test_rqm_no_ancestor_sets_oom_group`: after placement only the leaf
##   has `memory.oom.group` = 1, and a simulated host OOM (a limit on the
##   group directory) kills only its victim's tree while a sibling tree of
##   the same group survives. Mutation: write `memory.oom.group` = 1 to the
##   group directory -- the check fails and the kernel kills the sibling.
## * `test_rqm_clone3_spawns_into_the_leaf`: a capped child's first read of
##   `/proc/self/cgroup` names its own leaf and the launch says it used
##   `clone3`; with `LD_PRELOAD` set in the LAUNCHER's environment it uses
##   the ordinary fork and the child is still in the leaf before it
##   executes. Mutation: clone into the group directory instead of the leaf
##   (the kernel refuses a directory with controllers enabled for its
##   children, the launch falls back to the fork, and the test sees no
##   `clone3`).
## * The gate's stages (`RUNQUOTA_MEMORY_CAP_STAGE`) apply cumulatively:
##   `controller` enables the memory controller and leaves the tree in the
##   shared leaf; `leaf` adds a leaf of its own with no limit; `limits` adds
##   the limits and `clone3`; `classify` adds the measurement. Mutation:
##   ignoring the stage (every stage then looks like `classify`).
## * The pure rules: the stage names, the leaf's `memory.max` text, the
##   target of each stage, the `memory.events.local` parser and the verdict
##   table (including `capReached`), and the capability record's memory
##   entry.
##
## CAP REACHED WITHOUT A KILL is covered by the verdict table only. The
## kernel refuses a charge with ENOMEM instead of killing only for
## allocations that may not invoke the OOM killer (`__GFP_NORETRY`,
## high-order and non-blocking kernel allocations); none of them can be
## provoked reliably from an unprivileged test, and an unkillable task
## (`oom_score_adj` -1000) needs privilege.
##
## NO MOCKS: real processes (this test binary in helper modes, and `sh`),
## real cgroups of a test-owned root below the user's delegated subtree
## (`delegatedMemoryTestRoot`). Where the host gives the user no delegated
## memory controller, the host tests are reported SKIPPED with the reason.
import std/[os, strutils, unittest]
import runquota_core
import runquota_process
when defined(linux):
  import std/posix
  import cgroup_test_root

const MiB = 1'u64 shl 20

when defined(linux):
  var MAP_ANONYMOUS_FLAG {.importc: "MAP_ANONYMOUS", header: "<sys/mman.h>".}: cint

  proc allocateAndTouch(mib: int): bool =
    ## Anonymous memory the kernel must charge: every page written.
    let size = mib * 1024 * 1024
    let base = mmap(nil, size, PROT_READ or PROT_WRITE,
      MAP_PRIVATE or MAP_ANONYMOUS_FLAG, -1, 0)
    if base == MAP_FAILED:
      return false
    let bytes = cast[ptr UncheckedArray[byte]](base)
    var i = 0
    while i < size:
      bytes[i] = 1
      i += 4096
    true

  proc writeOrQuit(path, text: string; code: int) =
    try:
      writeFile(path, text)
    except IOError, OSError:
      stderr.writeLine("cannot write '" & text & "' to " & path & ": " &
        getCurrentExceptionMsg())
      quit(code)

  # ------------------------------------------------------------------------
  # Helper modes: this binary is also the trees' programs.
  # ------------------------------------------------------------------------
  if paramCount() >= 2 and paramStr(1) == "--alloc":
    # Allocate N MiB and touch it; "allocated" when that survived.
    if not allocateAndTouch(parseInt(paramStr(2))):
      quit(3)
    echo "allocated"
    quit(0)

  if paramCount() >= 2 and paramStr(1) == "--hold":
    # Stay alive for N milliseconds, holding little memory.
    sleep(parseInt(paramStr(2)))
    echo "held"
    quit(0)

  if paramCount() >= 1 and paramStr(1) == "--report-cgroup":
    # The first thing this program does: read its own cgroup.
    echo cgroupOfPid(getCurrentProcessId())
    quit(0)

  if paramCount() >= 3 and paramStr(1) == "--sub-alloc":
    # A tree that runs its allocator in a sub-cgroup of its own leaf and
    # passes the leaf's cap there. `plain`: the sub-cgroup has no memory
    # controller (none enabled below the leaf), so its memory is the
    # leaf's own. `controlled`: the tree parks itself in a second
    # sub-cgroup and enables the memory controller below the leaf, so the
    # allocator's memory -- and its OOM kill -- is counted in the
    # sub-cgroup's memory cgroup, not the leaf's. Exits non-zero, saying
    # what failed, when a step of the scenario does not work.
    let controlled = paramStr(2) == "controlled"
    let mib = parseInt(paramStr(3))
    let leaf = CgroupMountPoint & cgroupOfPid(getCurrentProcessId())
    let sub = leaf / "allocator"
    createDir(sub)
    if controlled:
      createDir(leaf / "parked")
      writeOrQuit(leaf / "parked" / "cgroup.procs", $getCurrentProcessId(), 40)
      writeOrQuit(leaf / "cgroup.subtree_control", "+memory", 41)
    let pid = fork()
    if pid == 0:
      if posix.write(posix.open(cstring(sub / "cgroup.procs"), O_WRONLY),
          cstring("0"), 1) != 1:
        exitnow(30)
      discard allocateAndTouch(mib)
      exitnow(0)
    var status: cint
    discard waitpid(pid, status, 0)
    echo "parent-survived"
    quit(0)

  if paramCount() >= 3 and paramStr(1) == "--nested-oom":
    # A tree that runs something in a sub-cgroup of its own leaf with a
    # limit of its own, which that something exceeds (an OOM counted in the
    # sub-cgroup, which the leaf's HIERARCHICAL memory.events also counts),
    # and then, back in its leaf, allocates past the limit of the directory
    # above its leaf. Every step must work or the tree exits non-zero with
    # what failed, so a broken scenario never passes as a classification.
    let innerMiB = parseInt(paramStr(2))
    let finalMiB = parseInt(paramStr(3))
    let leaf = CgroupMountPoint & cgroupOfPid(getCurrentProcessId())
    let parked = leaf / "parked"
    let limited = leaf / "limited"
    createDir(parked)
    createDir(limited)
    writeOrQuit(parked / "cgroup.procs", $getCurrentProcessId(), 20)
    writeOrQuit(leaf / "cgroup.subtree_control", "+memory", 21)
    writeOrQuit(limited / "memory.max", $(innerMiB * 1024 * 1024), 22)
    if fileExists(limited / "memory.swap.max"):
      writeOrQuit(limited / "memory.swap.max", "0", 23)
    let pid = fork()
    if pid == 0:
      if posix.write(posix.open(cstring(limited / "cgroup.procs"), O_WRONLY),
          cstring("0"), 1) != 1:
        exitnow(30)
      discard allocateAndTouch(innerMiB * 2)
      exitnow(0)
    var status: cint
    discard waitpid(pid, status, 0)
    if not (WIFSIGNALED(status) and WTERMSIG(status) == SIGKILL):
      stderr.writeLine("the inner allocator was not OOM-killed: " & $status)
      quit(24)
    writeOrQuit(leaf / "cgroup.subtree_control", "-memory", 25)
    writeOrQuit(leaf / "cgroup.procs", $getCurrentProcessId(), 26)
    if not (removeEmptyCgroup(parked) and removeEmptyCgroup(limited)):
      stderr.writeLine("cannot remove the sub-cgroups")
      quit(27)
    echo "inner-oom-done"
    stdout.flushFile()
    discard allocateAndTouch(finalMiB)
    echo "allocated"
    quit(0)

  # ------------------------------------------------------------------------
  # The launcher side
  # ------------------------------------------------------------------------
  proc cappedSpec(argv: openArray[string]; root, group: string;
                  capBytes: uint64;
                  action = mcaKill): CommandSpec =
    result = commandSpec(argv)
    result.cgroup = targetFor(CgroupRoot(state: crsExplicit, path: root),
      group, sessionPriorityNormal, reclaimed = false)
    result.memoryCapBytes = capBytes
    result.memoryCapAction = action

  proc runToEnd(spec: CommandSpec; info: var LaunchResult;
                timeout = 60_000): ProcessCompletion =
    var child = launchProcess(spec)
    info = child.info
    result = child.waitForCompletion(timeout)
    child.close()

  proc countersOf(leaf: string): string =
    ## The leaf's oom / oom_kill counts, local and hierarchical, as text for
    ## the test output (the evidence behind each classification).
    proc pick(path: string): string =
      let events = parseMemoryEvents(try: readFile(path)
        except IOError, OSError: "")
      "oom=" & $events.oom & " oom_kill=" & $events.oomKill
    "local " & pick(leaf / "memory.events.local") & "; hierarchical " &
      pick(leaf / "memory.events")

  proc runReporting(spec: CommandSpec; label: string;
                    info: var LaunchResult): ProcessCompletion =
    ## `runToEnd`, printing the leaf's counters after the root is reaped
    ## and before the leaf is removed.
    var child = launchProcess(spec)
    info = child.info
    result = child.waitForCompletion(60_000)
    echo "    counters (", label, "): ", countersOf(child.cgroupTarget.leafPath)
    child.close()

  proc groupDir(root, group: string): string =
    targetFor(CgroupRoot(state: crsExplicit, path: root), group,
      sessionPriorityNormal, reclaimed = false).dirPath

  proc limitGroup(root, group: string; limitBytes: uint64) =
    ## The group directory with a memory limit of its own, ABOVE the leaves
    ## of its trees: the stand-in for a host-wide OOM (or any ancestor's
    ## limit) that the cap did not cause. The directory is prepared as a
    ## launch would (`controller` stage) so the memory controller is on.
    let target = memoryCapTarget(targetFor(CgroupRoot(state: crsExplicit,
      path: root), group, sessionPriorityNormal, reclaimed = false), 0'u64,
      mcaKill, mcsController, 0, 0)
    var problem = ""
    doAssert prepareTarget(target, problem), problem
    writeFile(target.dirPath / "memory.max", $limitBytes)
    if fileExists(target.dirPath / "memory.swap.max"):
      writeFile(target.dirPath / "memory.swap.max", "0")
    # The preparation made the group's shared leaf too; no tree uses it,
    # and the group directory goes with its last tree only once it is gone.
    doAssert removeEmptyCgroup(target.leafPath)

  var savedPreload = ""
  var hadPreload = false

  proc clearLauncherPreload() =
    ## The launcher's own `LD_PRELOAD` decides between `clone3` and the
    ## fork, and the environment the suite runs in may well set one (an
    ## agent harness's command-trace shim, for one). Cleared for the cases
    ## that expect `clone3`, and restored by `restoreLauncherPreload`.
    hadPreload = existsEnv("LD_PRELOAD")
    savedPreload = getEnv("LD_PRELOAD")
    delEnv("LD_PRELOAD")

  proc restoreLauncherPreload() =
    if hadPreload:
      putEnv("LD_PRELOAD", savedPreload)
    else:
      delEnv("LD_PRELOAD")

  proc readTrim(path: string): string =
    try: readFile(path).strip() except IOError, OSError: "<unreadable>"

suite "memory cap rules":
  test "stage names":
    var stage: MemoryCapStage
    check parseMemoryCapStage("", stage) and stage == mcsClassify
    check parseMemoryCapStage("controller", stage) and stage == mcsController
    check parseMemoryCapStage(" leaf ", stage) and stage == mcsLeaf
    check parseMemoryCapStage("limits", stage) and stage == mcsLimits
    check parseMemoryCapStage("classify", stage) and stage == mcsClassify
    # An unknown stage is the whole mechanism, never "off".
    check not parseMemoryCapStage("none", stage)
    check stage == mcsClassify

  test "memory.max text":
    check memoryMaxFor(32 * MiB, mcaKill) == $(32 * MiB)
    check memoryMaxFor(32 * MiB, mcaAdvisory) == "max"
    check memoryMaxFor(0, mcaKill) == "max"

  test "each stage's target":
    let root = CgroupRoot(state: crsExplicit, path: "/sys/fs/cgroup/t/r")
    let shared = targetFor(root, "g", sessionPriorityNormal, reclaimed = false)
    let controller = memoryCapTarget(shared, 32 * MiB, mcaKill, mcsController,
      42, 7)
    check controller.memory
    check controller.leafName == SharedLeafName
    check not controller.freshLeaf
    check controller.memoryMax == ""
    let leaf = memoryCapTarget(shared, 32 * MiB, mcaKill, mcsLeaf, 42, 7)
    check leaf.leafPath == "/sys/fs/cgroup/t/r/group-g/cap-42-7"
    check leaf.freshLeaf
    check leaf.memoryMax == ""
    let limits = memoryCapTarget(shared, 32 * MiB, mcaKill, mcsLimits, 42, 7)
    check limits.memoryMax == $(32 * MiB)
    check memoryCapTarget(shared, 32 * MiB, mcaKill, mcsClassify, 42, 7) ==
      limits
    # A CPU cap leaf carries the memory cap too: one leaf, both caps.
    let cpuCapped = targetFor(root, "g", sessionPriorityNormal,
      reclaimed = false, capMilli = 2000, launcherPid = 9, capSequence = 3)
    let both = memoryCapTarget(cpuCapped, 32 * MiB, mcaKill, mcsClassify,
      42, 7)
    check both.leafName == "cap-9-3"
    check both.cpuMax == cpuCapped.cpuMax
    check both.memoryMax == $(32 * MiB)
    # No root: nothing to cap.
    check not memoryCapTarget(CgroupTarget(), 32 * MiB, mcaKill, mcsClassify,
      1, 1).placed

  test "memory.events.local":
    let events = parseMemoryEvents("low 0\nhigh 0\nmax 12\noom 1\n" &
      "oom_kill 2\noom_group_kill 1\n")
    check events.known and events.oom == 1 and events.oomKill == 2
    check not parseMemoryEvents("oom 1\n").known
    check not parseMemoryEvents("").known
    check not parseMemoryEvents("oom x\noom_kill 1\n").known

  test "the verdict table":
    proc v(oom, kill: uint64; evidence = true; peak = 0'u64; cap = 0'u64;
           action = mcaKill): MemoryCapVerdict =
      memoryCapVerdict(MemoryEvents(known: true, oom: oom, oomKill: kill),
        peak, cap, action, evidence)
    check v(1, 1).capKilled and v(1, 1).capExceeded
    check not v(1, 1, evidence = false).capKilled
    check v(1, 0).capReached and not v(1, 0).capKilled
    check v(0, 3).oomKilledOutsideCap and not v(0, 3).capExceeded
    check v(0, 0) == MemoryCapVerdict()
    let advisory = v(0, 0, peak = 40 * MiB, cap = 32 * MiB,
      action = mcaAdvisory)
    check advisory.capExceeded and not advisory.capKilled
    check not v(0, 0, peak = 30 * MiB, cap = 32 * MiB,
      action = mcaAdvisory).capExceeded
    check memoryCapVerdict(MemoryEvents(), 0, 0, mcaKill, true) ==
      MemoryCapVerdict()

  test "the capability record's memory entry":
    let root = CgroupRoot(state: crsDefault, path: "/sys/fs/cgroup/u/runquota.slice")
    proc memoryEntry(record: EnforcementRecord): EnforcementEntry =
      for item in record.entries:
        if item.mechanism == emMemoryCap:
          return item
    let available = MemoryProbe(available: true)
    check memoryEntry(enforcementRecordFor("linux", root, "", memory = available,
      memoryCapMode = mcmKill)).level == elEnforced
    check memoryEntry(enforcementRecordFor("linux", root, "", memory = available,
      memoryCapMode = mcmAdvisory)).level == elDegraded
    let off = memoryEntry(enforcementRecordFor("linux", root, "",
      memory = available))
    check off.level == elAdmissionOnly
    check "memory cap off" in off.gap
    let missing = memoryEntry(enforcementRecordFor("linux", root, "",
      memory = MemoryProbe(problem: "the memory controller is not available in x"),
      memoryCapMode = mcmKill))
    check missing.level == elAdmissionOnly
    check "the memory controller is not available in x" in missing.gap
    let noRoot = memoryEntry(enforcementRecordFor("linux",
      CgroupRoot(state: crsOff, reason: "off by default"),
      memoryCapMode = mcmKill))
    check "memory cap not enforced: no cgroup root" in noRoot.gap
    let trapped = memoryEntry(enforcementRecordFor("linux", root, "",
      memory = MemoryProbe(available: true,
        oomGroupAncestors: @["/sys/fs/cgroup/u"]), memoryCapMode = mcmKill))
    check trapped.level == elDegraded
    check "/sys/fs/cgroup/u" in trapped.gap

when defined(linux):
  suite "the memory cap on this host (Linux)":
    var reason = ""
    let testRoot = delegatedMemoryTestRoot(reason)
    let app = getAppFilename()

    test "test_rqm_cap_kills_only_the_tree":
      if testRoot.len == 0:
        echo "SKIPPED: " & reason
        skip()
      else:
        var siblingSpec = cappedSpec([app, "--hold", "4000"], testRoot,
          "kills-only", 256 * MiB)
        var sibling = launchProcess(siblingSpec)
        check sibling.info.memoryCapApplied
        var info: LaunchResult
        let victim = runToEnd(cappedSpec(["/bin/sh", "-c",
          "\"$0\" --alloc 96; echo parent-survived", app], testRoot,
          "kills-only", 32 * MiB), info)
        check info.memoryCapApplied
        check info.cgroupPath != sibling.info.cgroupPath
        # The whole tree died together: the shell too, by SIGKILL.
        check victim.signaled
        check victim.signal == int(SIGKILL)
        check "parent-survived" notin victim.stdout
        check victim.capKilled
        # The sibling in its own leaf is still running, and runs to its end.
        check sibling.running
        let held = sibling.waitForCompletion(30_000)
        sibling.close()
        check held.exited and held.exitCode == 0
        check held.stdout.strip() == "held"
        check not held.capExceeded and not held.oomKilledOutsideCap

    test "test_rqm_cap_exceeded_is_classified":
      if testRoot.len == 0:
        echo "SKIPPED: " & reason
        skip()
      else:
        var info: LaunchResult
        let killed = runToEnd(cappedSpec([app, "--alloc", "96"], testRoot,
          "classified", 32 * MiB), info)
        check info.memoryCapApplied
        check killed.memoryCapMeasured
        check killed.memoryCapBytes == 32 * MiB
        check killed.memoryPeakSource == mpsCgroup
        # The leaf's high-water mark: at the cap (the kernel let it reach
        # the limit, then killed), never above it.
        check killed.memoryPeakBytes > 24 * MiB
        check killed.memoryPeakBytes <= 32 * MiB
        check killed.capExceeded and killed.capKilled
        check not killed.capReached and not killed.oomKilledOutsideCap
        # The control: killed for memory by the limit of the directory
        # ABOVE its leaf, under a cap of its own it never reached.
        limitGroup(testRoot, "classified-control", 48 * MiB)
        let outside = runToEnd(cappedSpec([app, "--alloc", "128"], testRoot,
          "classified-control", 256 * MiB), info)
        check outside.signaled
        check outside.memoryCapMeasured
        check not outside.capKilled
        check not outside.capExceeded
        check outside.oomKilledOutsideCap

    test "test_rqm_host_oom_is_not_cap_exceeded":
      if testRoot.len == 0:
        echo "SKIPPED: " & reason
        skip()
      else:
        var info: LaunchResult
        limitGroup(testRoot, "host-oom", 48 * MiB)
        let plain = runToEnd(cappedSpec([app, "--alloc", "128"], testRoot,
          "host-oom", 256 * MiB), info)
        check plain.signaled
        check plain.oomKilledOutsideCap
        check not plain.capExceeded and not plain.capKilled
        # The same kill, of a tree whose own sub-cgroup earlier hit a limit
        # of its own: the leaf's hierarchical counters then include that
        # OOM, its local ones do not.
        limitGroup(testRoot, "host-oom-nested", 48 * MiB)
        let nested = runReporting(cappedSpec([app, "--nested-oom", "16",
          "128"], testRoot, "host-oom-nested", 256 * MiB),
          "ancestor kill after an inner OOM", info)
        check "inner-oom-done" in nested.stdout
        check nested.signaled
        check nested.signal == int(SIGKILL)
        check nested.oomKilledOutsideCap
        check not nested.capExceeded and not nested.capKilled
        if not nested.signaled:
          echo "nested tree: ", nested.exitCode, " ", nested.stderr

    test "swap is taken away only by an enforced cap":
      if testRoot.len == 0:
        echo "SKIPPED: " & reason
        skip()
      else:
        # Advisory and measure-only runs must not change how the tree uses
        # memory: memory.max stays max and swap stays as it was; only kill
        # mode with a cap writes memory.swap.max = 0. All three set
        # memory.oom.group = 1.
        proc leafFiles(capBytes: uint64; action: MemoryCapAction;
                       measure = false): string =
          var spec = cappedSpec(["/bin/sh", "-c",
            "d=/sys/fs/cgroup$(sed -n 's/^0:://p' /proc/self/cgroup); " &
            "echo $(cat $d/memory.max) $(cat $d/memory.swap.max) " &
            "$(cat $d/memory.oom.group)"], testRoot, "swap", capBytes, action)
          spec.memoryCapMeasure = measure
          var info: LaunchResult
          runToEnd(spec, info).stdout.strip()
        if not fileExists(testRoot.parentDir / "memory.swap.max"):
          echo "SKIPPED: this kernel does not account swap"
          skip()
        else:
          check leafFiles(64 * MiB, mcaKill) == $(64 * MiB) & " 0 1"
          check leafFiles(64 * MiB, mcaAdvisory) == "max max 1"
          check leafFiles(0, mcaKill, measure = true) == "max max 1"

    test "a cap kill inside a sub-cgroup of the tree's own leaf is the cap's":
      if testRoot.len == 0:
        echo "SKIPPED: " & reason
        skip()
      else:
        # The allocator runs in a sub-cgroup of the leaf, the tree passes
        # the LEAF's cap (the limit hit is the leaf's: local `oom`), and the
        # kill is counted where the victim's memory is charged. Without a
        # memory controller below the leaf that is the leaf itself; with
        # one it is the sub-cgroup, which only the leaf's HIERARCHICAL
        # `oom_kill` includes. Both are the cap's kill.
        var info: LaunchResult
        for mode in ["plain", "controlled"]:
          let killed = runReporting(cappedSpec([app, "--sub-alloc", mode,
            "96"], testRoot, "sub-" & mode, 32 * MiB),
            "cap kill in a " & mode & " sub-cgroup", info)
          checkpoint mode & ": " & killed.stdout & killed.stderr
          check killed.signaled
          check "parent-survived" notin killed.stdout
          check killed.capKilled
          check killed.capExceeded
          check not killed.capReached
          check not killed.oomKilledOutsideCap
        # The sub-cgroups the trees made are gone with their leaves.
        check cgroupDirsBelow(testRoot) == newSeq[string]()

    test "test_rqm_no_ancestor_sets_oom_group":
      if testRoot.len == 0:
        echo "SKIPPED: " & reason
        skip()
      else:
        # After placement: the leaf has memory.oom.group, nothing above it.
        limitGroup(testRoot, "no-ancestor", 64 * MiB)
        var sibling = launchProcess(cappedSpec([app, "--hold", "4000"],
          testRoot, "no-ancestor", 256 * MiB))
        let leaf = sibling.info.cgroupPath
        check leaf.len > 0
        check readTrim(leaf / "memory.oom.group") == "1"
        check readTrim(leaf.parentDir / "memory.oom.group") == "0"
        check readTrim(testRoot / "memory.oom.group") == "0"
        let probe = probeMemory(CgroupRoot(state: crsExplicit, path: testRoot))
        check probe.available
        check probe.oomGroupAncestors.len == 0
        # A host-OOM stand-in: the group directory's limit, which the victim
        # passes. Only the victim's leaf is killed.
        var info: LaunchResult
        let victim = runToEnd(cappedSpec([app, "--alloc", "128"], testRoot,
          "no-ancestor", 256 * MiB), info)
        check victim.signaled
        check victim.oomKilledOutsideCap
        check sibling.running
        let held = sibling.waitForCompletion(30_000)
        sibling.close()
        check held.exited and held.exitCode == 0
        check held.stdout.strip() == "held"

    test "test_rqm_clone3_spawns_into_the_leaf":
      if testRoot.len == 0:
        echo "SKIPPED: " & reason
        skip()
      else:
        clearLauncherPreload()
        defer: restoreLauncherPreload()
        var info: LaunchResult
        let viaClone3 = runToEnd(cappedSpec([app, "--report-cgroup"],
          testRoot, "clone3", 64 * MiB), info)
        check info.spawnedByClone3
        check info.memoryCapApplied
        check info.cgroupPath.extractFilename.startsWith(CapLeafPrefix)
        check viaClone3.stdout.strip() ==
          info.cgroupPath[CgroupMountPoint.len .. ^1]
        # LD_PRELOAD in the LAUNCHER's environment: the ordinary fork, and
        # the child is still in its leaf before it executes. The child does
        # not inherit the variable (`unsetEnv`), so nothing is preloaded
        # into it; only the launcher's own environment decides the path.
        putEnv("LD_PRELOAD", "/nonexistent-runquota-test-preload.so")
        var spec = cappedSpec([app, "--report-cgroup"], testRoot, "clone3",
          64 * MiB)
        spec.unsetEnv = @["LD_PRELOAD"]
        let viaFork = runToEnd(spec, info)
        clearLauncherPreload()
        check not info.spawnedByClone3
        check info.memoryCapApplied
        check info.cgroupPath.extractFilename.startsWith(CapLeafPrefix)
        check viaFork.stdout.strip() ==
          info.cgroupPath[CgroupMountPoint.len .. ^1]
        # An uncapped tree: the shared leaf, the ordinary fork.
        var uncapped = commandSpec([app, "--report-cgroup"])
        uncapped.cgroup = targetFor(CgroupRoot(state: crsExplicit,
          path: testRoot), "clone3", sessionPriorityNormal, reclaimed = false)
        let plain = runToEnd(uncapped, info)
        check not info.spawnedByClone3
        check info.cgroupPath.extractFilename == SharedLeafName
        check plain.stdout.strip() == info.cgroupPath[CgroupMountPoint.len .. ^1]

    test "the gate's stages apply cumulatively":
      if testRoot.len == 0:
        echo "SKIPPED: " & reason
        skip()
      else:
        proc staged(stage: string; info: var LaunchResult;
                    leafMax: var string): ProcessCompletion =
          putEnv(MemoryCapStageEnvVar, stage)
          clearLauncherPreload()
          defer:
            delEnv(MemoryCapStageEnvVar)
            restoreLauncherPreload()
          let spec = cappedSpec(["/bin/sh", "-c",
            "cat /sys/fs/cgroup$(sed -n 's/^0:://p' /proc/self/cgroup)/memory.max"],
            testRoot, "stages", 64 * MiB)
          result = runToEnd(spec, info)
          leafMax = result.stdout.strip()
        var info: LaunchResult
        var leafMax = ""
        let controller = staged("controller", info, leafMax)
        check info.cgroupPath.extractFilename == SharedLeafName
        check leafMax == "max"      # the memory files exist: controller on
        check not info.spawnedByClone3 and not info.memoryCapApplied
        check not controller.memoryCapMeasured
        let leaf = staged("leaf", info, leafMax)
        check info.cgroupPath.extractFilename.startsWith(CapLeafPrefix)
        check leafMax == "max"
        check not info.spawnedByClone3 and not info.memoryCapApplied
        check not leaf.memoryCapMeasured
        let limits = staged("limits", info, leafMax)
        check leafMax == $(64 * MiB)
        check info.spawnedByClone3 and info.memoryCapApplied
        check not limits.memoryCapMeasured
        let classify = staged("classify", info, leafMax)
        check leafMax == $(64 * MiB)
        check info.spawnedByClone3 and info.memoryCapApplied
        check classify.memoryCapMeasured
        check classify.memoryPeakBytes > 0

    test "a measured-only tree (cap lifted) gets max and its peak":
      if testRoot.len == 0:
        echo "SKIPPED: " & reason
        skip()
      else:
        var spec = cappedSpec([app, "--alloc", "48"], testRoot, "lifted", 0)
        spec.memoryCapMeasure = true
        var info: LaunchResult
        let lifted = runToEnd(spec, info)
        check info.memoryCapApplied
        check lifted.exited and lifted.exitCode == 0
        check lifted.memoryCapMeasured
        check lifted.memoryCapBytes == 0
        check lifted.memoryPeakBytes >= 48 * MiB
        check not lifted.capExceeded and not lifted.capKilled

    test "advisory: measured past the cap, nothing killed":
      if testRoot.len == 0:
        echo "SKIPPED: " & reason
        skip()
      else:
        var info: LaunchResult
        let advisory = runToEnd(cappedSpec([app, "--alloc", "64"], testRoot,
          "advisory", 32 * MiB, mcaAdvisory), info)
        check advisory.exited and advisory.exitCode == 0
        check advisory.memoryCapMeasured
        check advisory.capExceeded
        check not advisory.capKilled

    test "a memory controller that cannot be enabled: placed, uncapped, reported":
      if testRoot.len == 0:
        echo "SKIPPED: " & reason
        skip()
      else:
        # A root whose parent does not enable memory for its children: the
        # test root with the memory controller switched off again (every
        # earlier test's directories are gone, so nothing below it uses
        # it), and a sub-root below it that has only cpu.
        let parentRoot = testRoot / "cpu-only.slice"
        check cgroupDirsBelow(testRoot) == newSeq[string]()
        writeFile(testRoot / "cgroup.subtree_control", "-memory")
        createDir(parentRoot)
        var info: LaunchResult
        let spec = cappedSpec([app, "--report-cgroup"], parentRoot, "nomem",
          32 * MiB)
        let completion = runToEnd(spec, info)
        check info.cgroupPath.len > 0
        check not info.memoryCapApplied
        check "memory" in info.memoryCapProblem
        check completion.exited and completion.exitCode == 0
        check not completion.memoryCapMeasured
        check completion.memoryCapProblem.len > 0
        discard removeEmptyCgroup(parentRoot)

    test "close removes every leaf":
      if testRoot.len == 0:
        echo "SKIPPED: " & reason
        skip()
      else:
        check cgroupDirsBelow(testRoot).len == 0

    if testRoot.len > 0:
      let problem = removeTestRoot(testRoot)
      doAssert problem.len == 0, problem
