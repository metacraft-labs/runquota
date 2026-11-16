## Priority enforcement BELOW admission on Windows, the switchable layer: a
## Job Object priority-class LIMIT holds each leased tree to its group's
## priority, so a tool that over-spawns beyond its grant competes at its
## group's priority, not at its process count. The Windows analogue of the
## Linux cgroup-weight test (`t_priority_enforcement.nim`), at the
## `runquota_process` launcher level -- no daemon, no sqlite, no external
## tool.
##
## WHAT IS GUARDED, with the change that makes it fail:
##   A low-priority tool that ignores its grant and starts one process per
##   logical CPU gets LESS CPU time than a normal-priority group's build of
##   two processes running beside it, over the same window, when the two trees
##   contend for ONE logical CPU. The low tree's Job Object is held to
##   BELOW_NORMAL, so the normal tree's two processes preempt the low tree's
##   swarm: the split follows the classes (the mapping of
##   `jobPriorityClassFor`), not the process counts (one-per-CPU against two).
##   Each burner reads its own class (`GetPriorityClass`) -- forced by the Job
##   Object limit -- and its own CPU time over the window (`GetProcessTimes`),
##   and writes them to a file. Mutation: the launcher not applying the Job
##   Object priority-class limit (`applyJobPriorityClass` a no-op, or
##   `jobPriorityClassFor` returning the normal class for every tier) leaves
##   every burner at NORMAL, so the split follows the counts and the many low
##   burners take most of the CPU.
##
## ONLY THE LOWERING IS TESTED, which an unprivileged launcher can always do.
## The idle, below-normal, normal and above-normal classes (reclaimed, low,
## normal, high) all take with no privilege through the Job Object path; only
## the urgent tier's `HIGH_PRIORITY_CLASS` needs `SeIncreaseBasePriorityPrivilege`
## enabled, which that path requires and an ordinary launcher lacks, so an
## urgent group's tree is held at normal (confirmed by a standalone probe, not
## by this test). The contest here is `low` (lowered to below-normal) against
## `normal` (unchanged), which needs no privilege and is what a RunQuota
## launcher running as an ordinary user actually gets.
##
## ONE CPU. Priority classes only decide a contest when the work contends for
## the same processor, so every burner pins itself to the host's last logical
## CPU (`SetProcessAffinityMask`). The comparison is then between trees sharing
## one CPU, independent of how many other CPUs the host has free. A host with
## one CPU is reported SKIPPED. Foreign load on that CPU takes from both trees
## in proportion to their classes, so it cannot reverse the comparison.
##
## FIXTURE: this test binary re-invoked as the over-spawning tool and as the
## burners, so the workload depends on nothing outside this file (as
## `t_windows_job_object_cpu` and `t_windows_reclaimed_priority` already do).

when defined(windows):
  import std/[monotimes, os, osproc, strutils, tempfiles, unittest]
  import std/winlean

  import runquota_core
  import runquota_process

  # `getCurrentProcess`, `getProcessTimes` (var FILETIME) and `rdFileTime`
  # come from `std/winlean`; only these two are not there.
  proc getPriorityClass(hProcess: Handle): uint32
    {.stdcall, dynlib: "kernel32.dll", importc: "GetPriorityClass".}
  proc setProcessAffinityMask(hProcess: Handle; mask: uint): WINBOOL
    {.stdcall, dynlib: "kernel32.dll", importc: "SetProcessAffinityMask".}

  proc monoNs(): int64 = getMonoTime().ticks

  proc waitUntil(ns: int64) =
    let now = monoNs()
    if ns > now:
      sleep(int((ns - now) div 1_000_000))
    while monoNs() < ns:
      discard

  proc pinSelfTo(cpu: int) =
    discard setProcessAffinityMask(getCurrentProcess(), 1'u shl uint(cpu))

  proc ownCpu100ns(): uint64 =
    ## This process's user + kernel CPU time so far, in 100 ns ticks.
    var creation, exit, kernel, user: FILETIME
    if getProcessTimes(getCurrentProcess(), creation, exit, kernel, user) == 0:
      return 0
    uint64(rdFileTime(kernel)) + uint64(rdFileTime(user))

  var burnSink {.global.}: uint64 = 0

  proc burnWindow(cpu: int; startNs, endNs: int64; output: string) =
    ## Pin to `cpu`, spin from `startNs` to `endNs` (monotonic), and record the
    ## CPU time used in that window and this process's priority class (forced
    ## by the Job Object limit when the switch is on).
    pinSelfTo(cpu)
    waitUntil(startNs)
    let before = ownCpu100ns()
    var x = 1'u64
    while monoNs() < endNs:
      for _ in 0 ..< 200_000:
        x = x * 6364136223846793005'u64 + 1442695040888963407'u64
      burnSink = burnSink xor x
    let used = ownCpu100ns() - before
    writeFile(output, $used & " " & $getPriorityClass(getCurrentProcess()))

  proc runTool(cpu, count: int; startNs, endNs: int64; prefix: string) =
    ## Pin, wait briefly so the launcher has assigned the Job Object and its
    ## priority-class limit before any burner is spawned (the limit is applied
    ## inside `launchProcess`, best effort, just after the child starts), then
    ## start `count` burners and wait for them all.
    pinSelfTo(cpu)
    sleep(500)
    var kids: seq[Process] = @[]
    for i in 0 ..< count:
      kids.add startProcess(getAppFilename(),
        args = @["--rqtest-burn-window", $cpu, $startNs, $endNs,
          prefix & "-" & $i], options = {poParentStreams})
    var failed = 0
    for kid in kids:
      if kid.waitForExit() != 0: inc failed
      kid.close()
    quit(if failed == 0: 0 else: 1)

  # Worker arms, before any test.
  block:
    let params = commandLineParams()
    if params.len >= 5 and params[0] == "--rqtest-burn-window":
      burnWindow(parseInt(params[1]), parseBiggestInt(params[2]),
        parseBiggestInt(params[3]), params[4])
      quit(0)
    if params.len >= 6 and params[0] == "--rqtest-tool":
      runTool(parseInt(params[1]), parseInt(params[2]),
        parseBiggestInt(params[3]), parseBiggestInt(params[4]), params[5])

  proc cores(): int = max(1, countProcessors())

  type Reading = object
    cpu100ns: uint64
    class: uint32

  proc readings(dir, prefix: string): seq[Reading] =
    for kind, path in walkDir(dir):
      if kind == pcFile and path.extractFilename.startsWith(prefix & "-"):
        let parts = readFile(path).splitWhitespace()
        if parts.len >= 2:
          result.add Reading(cpu100ns: parseBiggestUInt(parts[0]).uint64,
            class: parseUInt(parts[1]).uint32)

  proc sumCpu(items: seq[Reading]): uint64 =
    for item in items: result += item.cpu100ns

  proc toolSpec(cpu, count: int; startNs, endNs: int64; prefix: string;
                jobPriorityClass: uint32): CommandSpec =
    result = commandSpec(@[getAppFilename(), "--rqtest-tool", $cpu, $count,
      $startNs, $endNs, prefix], stdio = inheritStdio,
      createProcessGroup = false)
    result.jobPriorityClass = jobPriorityClass

  const
    WindowSeconds = 3.0
    StartDelaySeconds = 2.0

  suite "windows priority tiering below admission":
    test "an over-spawning low-priority tool yields to a high-priority build":
      if cores() < 2:
        checkpoint "priority classes only decide a contest under CPU contention"
        skip()
      else:
        let cpu = cores() - 1
        let dir = createTempDir("rqtier", "")
        defer: removeDir(dir)
        let t0 = monoNs() + int64(StartDelaySeconds * 1e9)
        let t1 = t0 + int64(WindowSeconds * 1e9)
        # Low group over-spawns one burner per logical CPU; the normal group
        # runs two. The low tree is LOWERED to below-normal (unprivileged); the
        # normal tree keeps the normal class (no raise, so no privilege needed).
        let lowClass = jobPriorityClassFor(sessionPriorityLow, reclaimed = false)
        let highClass = jobPriorityClassFor(sessionPriorityNormal, reclaimed = false)
        var low = launchProcess(toolSpec(cpu, cores(), t0, t1,
          dir / "low", lowClass))
        var high = launchProcess(toolSpec(cpu, 2, t0, t1,
          dir / "high", highClass))
        let lowDone = low.waitForCompletion(); low.close()
        let highDone = high.waitForCompletion(); high.close()
        check lowDone.exited and lowDone.exitCode == 0
        check highDone.exited and highDone.exitCode == 0
        let lows = readings(dir, "low")
        let highs = readings(dir, "high")
        check lows.len == cores()
        check highs.len == 2
        # The Job Object limit forced every process in each tree to its class.
        # Mutation (no limit / normal class for every tier) leaves them at
        # normal and these fail.
        for r in lows: check r.class == lowClass
        for r in highs: check r.class == highClass
        let lowCpu = sumCpu(lows)
        let highCpu = sumCpu(highs)
        checkpoint "over " & $WindowSeconds & " s on one CPU: low tool (" &
          $lows.len & " procs) " & $(lowCpu div 10_000) & " ms, normal build (" &
          $highs.len & " procs) " & $(highCpu div 10_000) & " ms"
        # The normal build, two processes, takes more CPU than the low tool's
        # one-per-CPU swarm: the split follows the priority classes, not the
        # counts. On one CPU, NORMAL preempts BELOW_NORMAL, so the build gets
        # the large majority; a generous 2x margin absorbs a loaded host and
        # Windows's periodic anti-starvation boosts of the below-normal swarm.
        check highCpu > lowCpu * 2'u64
else:
  echo "t_windows_priority_tiering: Windows only"
