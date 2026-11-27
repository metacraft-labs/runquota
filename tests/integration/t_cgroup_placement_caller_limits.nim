## A launcher whose cgroup carries a limit does not place its tree where the
## tree would leave that limit.
##
## THE DEFECT (reprobuild-pm issue
## `2026-11-26-runquota-cgroup-placement-moves-a-tree-out-of-the-callers-cgroup-and-its-cap`).
## RunQuota's placement root is a sibling of the caller's cgroup: the
## default `runquota.slice`, and the test roots beside it, sit directly in
## `user@<uid>.service`, while a caller that ran under
## `systemd-run --user --scope -p MemoryMax=...` is in
## `user@<uid>.service/app.slice/run-....scope`. A tree moved into the root
## left the scope and every limit on it. The rule now
## (Build-Engine-And-Scheduler.md § Enforcement below admission, "A root that
## would take a tree out of its caller's limits"): the launcher declines
## placement, says which limit it would have left, and runs the tree where
## it is, with the fallback nice.
##
## WHAT IS GUARDED, with the change that makes it fail. The test starts a
## copy of itself as the CALLER, through a real
## `systemd-run --user --scope -q -p MemoryMax=4G`, exactly as an operator
## caps a build. The caller names a test-owned root in
## `RUNQUOTA_CGROUP_ROOT` (an explicit root, so this covers the explicit
## path, and the default root is the same sibling of the scope), resolves
## it with `currentCgroupRoot` and launches a `--report` child the way a
## launcher does (`targetFor`, the fallback nice of a `low` group, then
## `launchProcess`). The child must run in the caller's capped scope (equal
## to it or below it), unplaced, at the fallback nice +5, the resolved root
## must be `unavailable` with a reason that names the scope and
## `memory.max`, and nothing may have been created at the test root. A
## second case does the same under `-p TasksMax=64` and requires `pids.max`
## in the reason: a task limit the caller set counts, though the
## `pids.max` systemd writes on every unit by default (on the first case's
## scope too) does not. Mutation for the second case: not counting
## `pids.max` at all.
## Mutation: `resolveCgroupRoot` not applying `limitLeftBehind` (the unfixed
## tree) -- the child lands in `<root>/group-capped-caller/shared`, outside
## the scope, at nice 0.
##
## SKIPPED, with the reason, where the host gives this user no
## `systemd-run --user` (no user manager), no delegated cgroup v2 subtree
## with the cpu controller for the test root, or a scope on which systemd
## did not apply the limit (the controller not delegated).
##
## NO MOCKS: a real user-manager scope with a real memory limit, real
## `/proc/self/cgroup`, real cgroup interface files and a real child. The
## test root is this test's own (`cgroup_test_root`), never the user's
## `runquota.slice`, and the scope ends with the caller.

when defined(linux):
  import std/[os, osproc, posix, strutils, unittest]

  import runquota_core
  import runquota_process
  import cgroup_test_root

  proc getpriority(which: cint; who: Id): cint {.importc, header: "<sys/resource.h>".}
  var PRIO_PROCESS {.importc, header: "<sys/resource.h>".}: cint


  if paramCount() >= 1 and paramStr(1) == "--report":
    # The launched child: its nice value and its cgroup.
    echo $getpriority(PRIO_PROCESS, Id(0)) & " " &
      cgroupOfPid(getCurrentProcessId())
    quit(0)

  if paramCount() >= 2 and paramStr(1) == "--capped-caller":
    # The caller, inside its capped scope: what a RunQuota launcher does
    # with an explicit root, then one `key=value` line per fact.
    putEnv(CgroupRootEnvVar, paramStr(2))
    let root = currentCgroupRoot()
    let target = targetFor(root, "capped-caller", sessionPriorityLow,
      reclaimed = false)
    var spec = commandSpec([getAppFilename(), "--report"])
    spec.cgroup = target
    spec.placementFallbackNice = fallbackNice(sessionPriorityLow,
      reclaimed = false)
    var child = launchProcess(spec)
    let info = child.info
    let completion = child.waitForCompletion()
    child.close()
    let own = cgroupOfPid(getCurrentProcessId())
    echo "caller_cgroup=" & own
    for file in ["memory.max", "pids.max"]:
      let value =
        try: readFile(CgroupMountPoint & own / file).strip()
        except IOError, OSError: ""
      echo "caller_" & file & "=" & value
    echo "caller_nice=" & $getpriority(PRIO_PROCESS, Id(0))
    echo "root_state=" & $root.state
    echo "root_reason=" & root.reason.replace("\n", " ")
    echo "child_cgroup_path=" & info.cgroupPath
    echo "child_problem=" & info.cgroupProblem.replace("\n", " ")
    echo "child_report=" & completion.stdout.strip()
    quit(0)

  proc field(output, key: string): string =
    for line in output.splitLines():
      if line.startsWith(key & "="):
        return line[key.len + 1 .. ^1]
    ""

  proc systemdRunProblem(): string =
    ## "" when `systemd-run --user --scope` works for this user, else why
    ## not.
    if findExe("systemd-run").len == 0:
      return "no systemd-run on PATH"
    let (output, code) = execCmdEx("systemd-run --user --scope -q -- true")
    if code != 0:
      return "systemd-run --user --scope does not work here (exit " & $code &
        "): " & output.strip()
    ""

  template declinesUnder(property, file, value: string) =
    ## Start the caller in a `systemd-run --user --scope -p <property>`
    ## scope whose `<file>` the kernel then shows as `<value>`, and check
    ## that it declined the test root, naming that limit.
    let unavailable = systemdRunProblem()
    var reason = ""
    # The root is needed whatever limits THIS process runs under: the
    # caller below runs in a scope of its own, beside this one.
    let testRoot =
      if unavailable.len == 0: delegatedTestRoot(reason, checkLimits = false)
      else: ""
    if unavailable.len > 0:
      echo "SKIPPED: " & unavailable
      skip()
    elif testRoot.len == 0:
      echo "SKIPPED: " & reason
      skip()
    else:
      try:
        let (output, code) = execCmdEx(
          "systemd-run --user --scope -q -p " & property & " -- " &
          quoteShell(getAppFilename()) & " --capped-caller " &
          quoteShell(testRoot))
        echo output
        check code == 0
        let callerCgroup = output.field("caller_cgroup")
        let rootReason = output.field("root_reason")
        if code == 0 and output.field("caller_" & file) != value:
          # The positive control: a scope systemd did not limit (the
          # controller not delegated to the user manager) tests nothing.
          echo "SKIPPED: systemd-run -p " & property & " left the scope's " &
            file & " at '" & output.field("caller_" & file) & "'"
          skip()
        else:
          check callerCgroup.len > 0
          check callerCgroup.endsWith(".scope")
          let report = output.field("child_report").splitWhitespace()
          check report.len == 2
          if report.len == 2:
            # The child stays inside the caller's limited scope.
            check report[1] == callerCgroup or
              report[1].startsWith(callerCgroup & "/")
            # Unplaced: the fallback nice of a `low` group, an increment
            # over the nice the caller itself runs at (a placed child
            # would have the caller's).
            let callerNice = parseInt(output.field("caller_nice"))
            check report[0] == $min(callerNice + LowPriorityNiceIncrement, 19)
          check output.field("child_cgroup_path") == ""
          check output.field("root_state") == $crsUnavailable
          check (file & " is " & value) in rootReason
          check callerCgroup in rootReason
          # Nothing was created at the test root.
          check not dirExists(testRoot)
      finally:
        let problem = removeTestRoot(testRoot)
        check problem.len == 0
        if problem.len > 0:
          echo problem

  suite "a launcher under a limit":
    test "a memory-capped caller's tree stays in the caller's scope, unplaced, at the fallback nice":
      declinesUnder("MemoryMax=4G", "memory.max", "4294967296")

    test "a task-capped caller's tree stays in the caller's scope, naming pids.max":
      # Far below systemd's default task limit (15% of the kernel's), so it
      # counts; the default itself, which systemd writes on the scope of
      # the memory case too, does not.
      declinesUnder("TasksMax=64", "pids.max", "64")
