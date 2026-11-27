## A cgroup root that belongs to one test run, below the user's own
## systemd-delegated subtree, and its removal.
##
## WHY A ROOT OF ITS OWN. RunQuota's launchers place trees below
## `runquota.slice` in the user's `user@<uid>.service` subtree by default. A
## test must never write there: that is the user's real root, shared with
## every RunQuota launcher the user runs while the suite runs. Each test run
## therefore gets `runquota-test-<pid>-<n>.slice` beside it, names it in
## `RUNQUOTA_CGROUP_ROOT` for the clients it starts, and removes it at the
## end. The suite runner sets `RUNQUOTA_CGROUP_ROOT=off` for every other
## test (`scripts/run_tests.sh`).
##
## REMOVAL KILLS NOTHING. The processes in a test root are the test's own
## burners, which end by their own deadlines; removal waits for each cgroup
## to empty (`cgroup.events` `populated 0`) and only then removes it, deepest
## first. A cgroup still populated at the end of the wait is reported, with
## its path, rather than killed.

when defined(linux):
  import std/[algorithm, os, posix, strutils, times]

  import runquota_process

  var rootSequence = 0

  proc noCgroupLimits(path: string): string {.nimcall, gcsafe, raises: [].} =
    ## A reader that finds no limit: resolves the default root's PATH, which
    ## `delegatedTestRoot` then checks against this process's limits itself.
    ""

  proc delegatedTestRoot*(reason: var string; checkLimits = true): string =
    ## A fresh, test-owned root below this user's delegated subtree, or ""
    ## with `reason` when this host gives the user no delegated cgroup v2
    ## subtree with the cpu controller (a CI container, a system service).
    ## The root is not created here: the first launch creates it, as in
    ## production, and `removeTestRoot` takes it away.
    ##
    ## THE TEST PROCESS'S OWN LIMITS. The root is a sibling of the user's
    ## `runquota.slice`, so a tree placed in it leaves every cgroup between
    ## this process and `user@<uid>.service`. A launcher keeps a tree under a
    ## limited one of those (`limitingCgroup`), unless it is the agent
    ## session's scope that `RUNQUOTA_AGENT_SESSION_SCOPE` names. So with
    ## `checkLimits` (the default) this returns "" with that limit as the
    ## reason, and the test reports SKIPPED, when the suite runs under a
    ## limited cgroup the marker does not name: an agent session whose
    ## harness does not set the marker, or a `systemd-run -p MemoryMax=...`
    ## around the suite. Set the marker to the session's scope unit name to
    ## run these tests there. `checkLimits = false` is for the test that
    ## starts its launchers in scopes of their own.
    let own = readFile("/proc/self/cgroup")
    let default = resolveCgroupRoot("", own, int(getuid()),
      hostSwitchOn = true, read = noCgroupLimits)
    if not default.usable:
      reason = default.reason
      return ""
    if checkLimits:
      let limited = limitingCgroup(parseOwnCgroup(own), default.path,
        getEnv(AgentSessionScopeEnvVar).strip(), readCgroupInterfaceFile)
      if limited.dir.len > 0:
        reason = "this test runs under cgroup " & limited.dir & " (" &
          limited.limit & "), which a tree placed beside runquota.slice " &
          "would leave; if it is the agent session's scope, name its unit " &
          "in " & AgentSessionScopeEnvVar
        return ""
    inc rootSequence
    let root = default.path.parentDir / ("runquota-test-" & $getCurrentProcessId() &
      "-" & $rootSequence & "-" & $int64(epochTime() * 1000) & ".slice")
    let problem = probeRoot(CgroupRoot(state: crsExplicit, path: root))
    if problem.len > 0:
      reason = problem
      return ""
    root

  proc delegatedMemoryTestRoot*(reason: var string): string =
    ## `delegatedTestRoot`, for tests of the memory cap: also "" with
    ## `reason` when the memory controller is not delegated to the user's
    ## subtree (`probeMemory`), so a memory test is reported skipped rather
    ## than failed on a host that cannot cap.
    let root = delegatedTestRoot(reason)
    if root.len == 0:
      return ""
    let probe = probeMemory(CgroupRoot(state: crsExplicit, path: root))
    if not probe.available:
      reason = probe.problem
      return ""
    root

  proc populated(dir: string): bool =
    try:
      for line in readFile(dir / "cgroup.events").splitLines():
        if line.startsWith("populated "):
          return line.endsWith(" 1")
    except IOError, OSError:
      discard
    false

  proc cgroupDirsBelow*(root: string): seq[string] =
    ## Every cgroup directory below `root` (not `root` itself).
    if not dirExists(root):
      return
    for path in walkDirRec(root, yieldFilter = {pcDir}, followFilter = {pcDir}):
      result.add(path)

  proc removeTestRoot*(root: string; waitMillis = 30_000): string =
    ## Remove `root` and everything below it once empty, deepest first.
    ## Returns "" when it is gone, else what is left and why.
    if root.len == 0 or not dirExists(root):
      return ""
    if not root.contains("/runquota-test-"):
      return "refusing to remove " & root & ": not a test root"
    var dirs = cgroupDirsBelow(root)
    dirs.sort(proc (a, b: string): int = cmp(b.len, a.len))
    dirs.add(root)
    let deadline = epochTime() + float(waitMillis) / 1000.0
    for dir in dirs:
      while populated(dir) and epochTime() < deadline:
        sleep(50)
      if populated(dir):
        return "cgroup " & dir & " still holds processes after " &
          $waitMillis & " ms"
      if not removeEmptyCgroup(dir):
        return "cannot remove cgroup " & dir
    ""
