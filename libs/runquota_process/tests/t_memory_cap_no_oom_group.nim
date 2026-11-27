## A kernel without `memory.oom.group` (Linux 4.5 to 4.18): the memory cap
## cannot be applied safely (a limit without the group kill would let the
## kernel kill one process and leave its parent running), and that must
## cost the tree nothing else.
##
## WHAT IS GUARDED: the capped tree still runs IN ITS OWN LEAF, with the CPU
## cap it was given (`cpu.max` written), `memoryCapApplied` false and a
## reason naming `memory.oom.group`; the launch creates exactly one cap
## leaf (a missing interface file is not a vanished leaf, so the leaf is
## neither prepared again nor renamed), and `close` removes it. Mutation:
## treating ENOENT on the interface file as a vanished leaf -- the launch
## then retries and renames, leaks empty cap leaves, and runs the tree
## unplaced, losing its CPU cap.
##
## THE ONE STAND-IN, and why: no kernel this old is available to the suite,
## so this binary is compiled (`t_memory_cap_no_oom_group.nims`) with the
## launcher looking for `memory.oom.group` under a name that does not
## exist. The open then fails with ENOENT, which is exactly what such a
## kernel answers; everything else is the real launcher, real processes and
## real cgroups of a test-owned root.
import std/[os, strutils, unittest]
import runquota_core
import runquota_process
when defined(linux):
  import cgroup_test_root

when defined(linux):
  if paramCount() >= 1 and paramStr(1) == "--report-cgroup":
    let own = cgroupOfPid(getCurrentProcessId())
    echo own & " " & readFile(CgroupMountPoint & own / "cpu.max").strip()
    quit(0)

  suite "a kernel without memory.oom.group":
    var reason = ""
    let root = delegatedMemoryTestRoot(reason)

    test "the tree runs in its own leaf with its CPU cap, uncapped for memory":
      if root.len == 0:
        echo "SKIPPED: " & reason
        skip()
      else:
        var spec = commandSpec([getAppFilename(), "--report-cgroup"])
        spec.cgroup = targetFor(CgroupRoot(state: crsExplicit, path: root),
          "old-kernel", sessionPriorityNormal, reclaimed = false,
          capMilli = 1500, launcherPid = getCurrentProcessId(),
          capSequence = 1)
        spec.memoryCapBytes = 64'u64 shl 20
        spec.memoryCapAction = mcaKill
        var child = launchProcess(spec)
        let info = child.info
        let leaves = cgroupDirsBelow(root)
        let completion = child.waitForCompletion(30_000)
        child.close()
        check info.cgroupPath == spec.cgroup.leafPath
        check info.cgroupProblem == ""
        check not info.memoryCapApplied
        check "memory.oom.group" in info.memoryCapProblem
        let report = completion.stdout.strip().splitWhitespace()
        check report.len == 3
        check report[0] == spec.cgroup.leafPath[CgroupMountPoint.len .. ^1]
        check report[1 .. 2].join(" ") == spec.cgroup.cpuMax
        # One group directory and one leaf, nothing renamed or left over.
        check leaves.len == 2
        check not completion.memoryCapMeasured
        check cgroupDirsBelow(root).len == 0
        check removeTestRoot(root) == ""
