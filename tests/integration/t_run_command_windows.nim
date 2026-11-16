## `runquota run --cap` end to end on WINDOWS: the built CLI, a real private
## `runquotad` on a scratch named pipe, and a real CPU-bound process tree run
## under a Job Object CPU-rate cap.
##
## The Windows arm of the `--cap` story. On every other platform `--cap` is
## refused with exit 2 (asserted in `t_run_command.nim`); here it enforces the
## grant, so this file proves two things: that `run --cap` no longer refuses,
## and that the cap actually bounds the tree's CPU. Enforcement is read from the
## daemon's own `cpu_used_micros` counter -- the figure `lease.finish` reports
## from Job Object accounting -- taken as a delta across each run, so the
## capped run's CPU can be compared with an uncapped control of the same work.
##
## NO MOCKS: a real daemon, a real cap, a real multi-process CPU burn. The burn
## worker is THIS BINARY re-invoked (as the portable `t_child_process_*` tests
## already do), so there is no shell and no external tool.

when defined(windows):
  import std/[json, os, osproc, strutils, times, unittest]

  import windows_daemon_fixture

  # -------------------------------------------------------------------
  # The burn worker (runs before any test)
  # -------------------------------------------------------------------

  var burnSink {.global.}: uint64 = 0

  proc burnFor(seconds: float) =
    let deadline = epochTime() + seconds
    var x = 1'u64
    while epochTime() < deadline:
      for _ in 0 ..< 200_000:
        x = x * 6364136223846793005'u64 + 1442695040888963407'u64
      burnSink = burnSink xor x

  proc runWorkerOrReturn() =
    let params = commandLineParams()
    if params.len == 0:
      return
    case params[0]
    of "--rqrun-burn":
      burnFor(parseFloat(params[1]))
      quit(0)
    of "--rqrun-burn-tree":
      # The leased command: spawn four burner children and wait. A one-core
      # cap must bound their combined CPU however many they are.
      var kids: seq[Process] = @[]
      for _ in 0 ..< 4:
        kids.add startProcess(getAppFilename(),
          args = @["--rqrun-burn", params[1]], options = {poParentStreams})
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

  proc cpuUsedMicros(daemon: Daemon): int64 =
    ## The daemon's cumulative tree-CPU counter, from `status --json`.
    let status = parseJson(runq(daemon.env, ["status", "--json"]).output)
    status["capacity"]["host"]["cpu_used_micros"].getBiggestInt()

  proc cores(): int = max(1, countProcessors())

  suite "runquota run --cap (windows)":

    test "cap_enforced_end_to_end: --cap holds a four-burner tree near one " &
        "core; the uncapped control of the same work uses several":
      if cores() < 3:
        checkpoint "a CPU cap is only observable on a multi-core host"
        skip()
      else:
        var daemon = startDaemon("rqrunw", 8000)
        defer: daemon.stop()
        let self = getAppFilename()

        # Capped at the width (1 slot = 1000 milli-CPU = one core).
        let before1 = cpuUsedMicros(daemon)
        let capped = runq(daemon.env, ["run", "--cap", "--width", "1",
          "--verbose", "--", self, "--rqrun-burn-tree", "2.0"])
        checkpoint capped.output
        check capped.code == 0
        # The wiring fired: `--cap` was not refused, and the launcher applied
        # the grant as a cap.
        check "CPU cap 1000 milli-CPU" in capped.output
        let capMicros = cpuUsedMicros(daemon) - before1

        # The same work with no cap: the control.
        let before2 = cpuUsedMicros(daemon)
        let free = runq(daemon.env, ["run", "--width", "1", "--", self,
          "--rqrun-burn-tree", "2.0"])
        check free.code == 0
        let freeMicros = cpuUsedMicros(daemon) - before2

        checkpoint "capped CPU micros: " & $capMicros &
          "; uncapped CPU micros: " & $freeMicros
        # The cap holds the tree near one core: ~2 s of wall gives ~2 s of CPU,
        # well under the four burners it ran. 1.8x of the wall window (2 s)
        # absorbs the brief pre-cap window and scheduler slop.
        check capMicros < 3_600_000'i64
        # NOT VACUOUS: the uncapped control really used several cores, so the
        # cap is what made the difference. Skipping SetInformationJobObject
        # makes the capped run look like this one.
        check freeMicros > capMicros * 2'i64
else:
  echo "t_run_command_windows: Windows only"
