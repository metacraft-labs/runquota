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
    ## A reader that finds no limit anywhere: resolves the default root's
    ## PATH without the limit check, which `delegatedTestRoot` then makes
    ## against the test root itself (or, opted out, does not make).
    ""

  proc delegatedTestRoot*(reason: var string; checkLimits = true): string =
    ## A fresh, test-owned root below this user's delegated subtree, or ""
    ## with `reason` when this host gives the user no delegated cgroup v2
    ## subtree with the cpu controller (a CI container, a system service).
    ## The root is not created here: the first launch creates it, as in
    ## production, and `removeTestRoot` takes it away.
    ##
    ## THE CALLER'S LIMITS. The root is a sibling of the user's
    ## `runquota.slice`, so placing a tree in it takes the tree out of every
    ## cgroup between this process and `user@<uid>.service` -- the scope of
    ## a `systemd-run --user --scope -p MemoryMax=...` around the suite, for
    ## one. A launcher declines such a root (`limitLeftBehind`), so a
    ## placement test run under a limit could not place anything: with
    ## `checkLimits` (the default) this returns "" with the limit as the
    ## reason, and the test reports SKIPPED. `checkLimits = false` is for
    ## the test that asserts the decline itself: it starts its launcher in a
    ## capped scope of its own and needs the root regardless of the limits
    ## on its own process.
    let own = readFile("/proc/self/cgroup")
    let default = resolveCgroupRoot("", own, int(getuid()),
      hostSwitchOn = true, read = noCgroupLimits)
    if not default.usable:
      reason = default.reason
      return ""
    inc rootSequence
    let root = default.path.parentDir / ("runquota-test-" & $getCurrentProcessId() &
      "-" & $rootSequence & "-" & $int64(epochTime() * 1000) & ".slice")
    if checkLimits:
      let left = limitLeftBehind(parseOwnCgroup(own), root,
        readCgroupInterfaceFile)
      if left.len > 0:
        reason = left
        return ""
    let problem = probeRoot(CgroupRoot(state: crsExplicit, path: root))
    if problem.len > 0:
      reason = problem
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
