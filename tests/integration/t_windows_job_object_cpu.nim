## Windows Job Object CPU accounting and the `--cap` CPU-rate ceiling, at the
## `runquota_process` launcher level -- no daemon, no sqlite, no external tool.
##
## Each case launches a process TREE through `launchProcess` and reads the
## tree's CPU totals back from `completion.totals`, the same `readJobAccounting`
## path `lease.finish` reports to the daemon. The tree is THIS TEST BINARY
## re-invoked in a worker mode: cargo-style re-execution (as the portable
## `t_child_process_*` tests already do) keeps the fixture to one binary and
## needs no shell. The worker dispatch runs below before any test.
##
## WHAT TWO THINGS ARE PROVEN, each with a control that a falsifying mutation
## turns red:
##   * a grandchild's CPU is counted against the tree, not just the direct
##     child's -- the direct child here only idle-waits, so a launcher that
##     read the leader's `GetProcessTimes` alone would under-report to ~0;
##   * a hard `--cap` of one core bounds the whole tree's CPU rate however many
##     burners it spawns -- the uncapped control of the same workload uses
##     several cores' worth over the same wall-clock window.

when defined(windows):
  import std/[os, osproc, strutils, times, unittest]

  import runquota_process

  # -------------------------------------------------------------------
  # The worker arms of this binary (run before any test)
  # -------------------------------------------------------------------

  var burnSink {.global.}: uint64 = 0

  proc burnFor(seconds: float) =
    ## Keep one core busy for `seconds` of wall clock.
    let deadline = epochTime() + seconds
    var x = 1'u64
    while epochTime() < deadline:
      # A tight integer loop between clock reads; the sink defeats dead-code
      # elimination in an optimised build.
      for _ in 0 ..< 200_000:
        x = x * 6364136223846793005'u64 + 1442695040888963407'u64
      burnSink = burnSink xor x

  proc spawnSelf(args: seq[string]): Process =
    startProcess(getAppFilename(), args = args, options = {poParentStreams})

  proc runWorkerOrReturn() =
    let params = commandLineParams()
    if params.len == 0:
      return
    case params[0]
    of "--rqtest-burn":
      burnFor(parseFloat(params[1]))
      quit(0)
    of "--rqtest-run-grandchild":
      # The leased command: spawn ONE burner grandchild and wait for it,
      # itself doing essentially no CPU work. The Job Object must still
      # account the grandchild's burn.
      var child = spawnSelf(@["--rqtest-burn", params[1]])
      let code = child.waitForExit()
      child.close()
      quit(code)
    of "--rqtest-spawn-burners":
      # Spawn `count` burner children at once and wait for all. A cap must
      # bound their combined CPU rate.
      let count = parseInt(params[1])
      let seconds = params[2]
      var kids: seq[Process] = @[]
      for _ in 0 ..< count:
        kids.add spawnSelf(@["--rqtest-burn", seconds])
      for kid in kids:
        discard kid.waitForExit()
        kid.close()
      quit(0)
    else:
      return

  runWorkerOrReturn()

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  proc selfSpec(args: seq[string]): CommandSpec =
    var argv = @[getAppFilename()]
    argv.add args
    commandSpec(argv, stdio = inheritStdio, createProcessGroup = false)

  proc cores(): int = max(1, countProcessors())

  suite "windows job object cpu":

    test "job_object_accounts_grandchild_cpu: a grandchild's CPU burn is " &
        "counted against the tree, not only the direct child":
      # The direct child only waits on the grandchild; the grandchild burns a
      # core for ~1.5 s. The tree's totals must reflect that burn.
      var child = launchProcess(selfSpec(@["--rqtest-run-grandchild", "1.5"]))
      let completion = child.waitForCompletion()
      child.close()
      check completion.exited
      check completion.exitCode == 0
      check completion.totals.known
      let cpuMillis = completion.totals.totalCpuMicros div 1000'u64
      checkpoint "tree CPU millis: " & $cpuMillis &
        "; processes: " & $completion.processCount
      # The grandchild really ran as a separate process in the tree.
      check completion.processCount >= 2'u32
      # ~1.5 s of CPU was burned by the grandchild; a leader-only reading
      # would be ~0. A generous floor (0.7 s) absorbs a slow or loaded host
      # while staying far above the direct child's idle wait.
      check cpuMillis >= 700'u64

    test "cap_bounds_tree_cpu_rate: a one-core --cap holds a multi-burner " &
        "tree near one core, where the uncapped control uses several":
      if cores() < 3:
        checkpoint "a CPU cap is only observable on a multi-core host"
        skip()
      else:
        let burners = min(4, cores() - 1)
        let seconds = "2.0"

        # Capped at one core (1000 milli-CPU).
        var capSpec = selfSpec(@["--rqtest-spawn-burners", $burners, seconds])
        capSpec.cpuRateCapMilli = 1000'u32
        var capped = launchProcess(capSpec)
        let capDone = capped.waitForCompletion()
        capped.close()
        check capDone.exited
        check capDone.totals.known
        let capCpuMillis = capDone.totals.totalCpuMicros div 1000'u64
        let capWallMillis = capDone.elapsedMillis
        checkpoint "capped CPU millis: " & $capCpuMillis &
          "; wall millis: " & $capWallMillis & "; burners: " & $burners

        # The same workload with no cap: the control.
        var freeSpec = selfSpec(@["--rqtest-spawn-burners", $burners, seconds])
        var free = launchProcess(freeSpec)
        let freeDone = free.waitForCompletion()
        free.close()
        check freeDone.exited
        check freeDone.totals.known
        let freeCpuMillis = freeDone.totals.totalCpuMicros div 1000'u64
        let freeWallMillis = freeDone.elapsedMillis
        checkpoint "uncapped CPU millis: " & $freeCpuMillis &
          "; wall millis: " & $freeWallMillis

        # The cap holds the tree near one core: its CPU time stays close to
        # the wall-clock window (one core busy), well under the burners it
        # spawned. 1.8x of wall absorbs the brief window before the job cap is
        # applied and scheduler slop.
        check capCpuMillis.float <= capWallMillis.float * 1.8
        # NOT VACUOUS: the uncapped control really used several cores, so the
        # cap is what produced the difference. The mutation that skips
        # SetInformationJobObject makes the capped run look like this one.
        check freeCpuMillis >= capCpuMillis * 2'u64
        check freeCpuMillis.float >= freeWallMillis.float * 2.0
else:
  echo "t_windows_job_object_cpu: Windows only"
