## Windows memory-cap mechanism, at the `runquota_process` launcher level --
## no daemon, no CommandSpec wiring yet (the shared `memoryCapBytes` /
## `memoryCapAction` fields land separately): this exercises
## `applyMemoryCapHard`, `startMemoryCapWatcher` / `stopMemoryCapWatcher`,
## and `readPeakJobMemoryUsed` directly against a real Job Object a real
## launch created (`child.winJobHandle`), matching exactly how `kill` mode
## will apply them once CommandSpec carries the cap.
##
## Each case launches a worker (this test binary re-invoked, cargo-style)
## that commits real memory slowly and deliberately -- one 1 MiB chunk at a
## time with a short pause between chunks -- so the threshold is crossed
## well after the watcher has had time to arm, never before. The chunks are
## touched (one byte per page) to force real commit, not just reservation.
##
## WHAT THREE THINGS ARE PROVEN, each with a control that a falsifying
## mutation turns red:
##   * `startMemoryCapWatcher`'s notification threshold terminates the job
##     the moment the committed total crosses it, with the reserved exit
##     code, while the SAME workload with no watcher at all survives and
##     exits normally;
##   * `applyMemoryCapHard`'s enforced limit fails the next commit once the
##     job-wide total would exceed it, WITHOUT killing anything, while the
##     same workload with no limit commits all of it;
##   * `readPeakJobMemoryUsed` reports (at least) what an uncapped worker
##     is known to have committed while it is still holding it.
##
## MOCKS: none. Real processes, launched by the production launcher.

when defined(windows):
  import std/[os, strutils, unittest]
  import std/winlean

  import runquota_process

  # -------------------------------------------------------------------
  # The worker arm of this binary (run before any test)
  # -------------------------------------------------------------------

  proc virtualAlloc(lpAddress: pointer; dwSize: csize_t;
                    flAllocationType, flProtect: int32): pointer {.
    stdcall, dynlib: "kernel32.dll", importc: "VirtualAlloc".}

  const
    MemCommit = 0x00001000'i32
    MemReserve = 0x00002000'i32
    PageReadWrite = 0x04'i32
    PageSizeBytes = 4096
    ChunkBytes = 1024 * 1024 # 1 MiB

  proc commitSlowlyMiB(totalMiB, delayMsPerMiB: int): bool =
    ## Commits `totalMiB` one 1 MiB chunk at a time, touching every page in
    ## each chunk, pausing `delayMsPerMiB` between chunks. Never frees what
    ## it commits: each chunk must stay charged to the job until the
    ## process ends (naturally, or cut short by a watcher's
    ## `TerminateJobObject`) for the job's total to keep growing. Returns
    ## false the instant a chunk's commit is refused.
    for _ in 0 ..< totalMiB:
      let p = virtualAlloc(nil, csize_t(ChunkBytes),
        MemCommit or MemReserve, PageReadWrite)
      if p.isNil:
        return false
      var off = 0
      while off < ChunkBytes:
        cast[ptr byte](cast[int](p) + off)[] = 1'u8
        off += PageSizeBytes
      sleep(delayMsPerMiB)
    true

  proc runWorkerOrReturn() =
    let params = commandLineParams()
    if params.len == 0:
      return
    case params[0]
    of "--rqtest-commit-slowly":
      # <totalMiB> <delayMsPerMiB> <holdMsAfter>
      let totalMiB = parseInt(params[1])
      let delayMs = parseInt(params[2])
      let holdMs = parseInt(params[3])
      let ok = commitSlowlyMiB(totalMiB, delayMs)
      echo (if ok: "committed" else: "alloc-failed")
      sleep(holdMs)
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
    commandSpec(argv, createProcessGroup = false)

  const
    CapMiB = 32
    TotalMiB = 128
    DelayMsPerMiB = 10 # ~1.28 s to commit it all: ample time to arm first
    HoldMsAfterCommit = 3000

  suite "windows memory cap watcher":
    test "watcher_kills_only_on_the_notification_threshold: a watcher " &
        "armed below the workload's total terminates the job, where the " &
        "same workload with no watcher survives and exits normally":
      var cappedSpec = selfSpec(@["--rqtest-commit-slowly", $TotalMiB,
        $DelayMsPerMiB, $HoldMsAfterCommit])
      var capped = launchProcess(cappedSpec)
      check capped.winJobHandle != 0
      let watcher = startMemoryCapWatcher(Handle(capped.winJobHandle),
        uint64(CapMiB) * 1024 * 1024)
      let cappedCompletion = capped.waitForCompletion(timeout = 15_000)
      let killed = stopMemoryCapWatcher(watcher.threadHandle, watcher.state)
      capped.close()
      checkpoint "capped exit: " & $cappedCompletion.exitCode &
        "; stdout: " & cappedCompletion.stdout
      check killed
      check cappedCompletion.exited
      check cappedCompletion.exitCode == int(windowsCapExceededExitCode)

      # NOT VACUOUS: the identical workload with no watcher at all commits
      # everything and exits cleanly -- the watcher is what killed the run
      # above, not the workload itself.
      var freeSpec = selfSpec(@["--rqtest-commit-slowly", $TotalMiB,
        $DelayMsPerMiB, "50"])
      var free = launchProcess(freeSpec)
      let freeCompletion = free.waitForCompletion(timeout = 15_000)
      free.close()
      checkpoint "uncapped exit: " & $freeCompletion.exitCode &
        "; stdout: " & freeCompletion.stdout
      check freeCompletion.exited
      check freeCompletion.exitCode == 0
      check "committed" in freeCompletion.stdout

    test "hard_cap_fails_the_commit_without_killing_anything: a job-wide " &
        "limit below the workload's total refuses the commit partway, " &
        "and the process survives to report it":
      const hardCapMiB = 16
      var spec = selfSpec(@["--rqtest-commit-slowly", $TotalMiB,
        $DelayMsPerMiB, "200"])
      var child = launchProcess(spec)
      check child.winJobHandle != 0
      # Applied right after creation, well before the slow ramp (160 ms in,
      # at ~10 ms/MiB) reaches the cap -- no watcher, no notification.
      applyMemoryCapHard(Handle(child.winJobHandle),
        uint64(hardCapMiB) * 1024 * 1024)
      let completion = child.waitForCompletion(timeout = 15_000)
      child.close()
      checkpoint "exit: " & $completion.exitCode & "; stdout: " &
        completion.stdout
      check completion.exited
      check completion.exitCode == 0 # nothing killed it
      check "alloc-failed" in completion.stdout # but the commit did fail

    test "peak_job_memory_used_reports_what_an_uncapped_worker_committed":
      const holdMiB = 24
      var spec = selfSpec(@["--rqtest-commit-slowly", $holdMiB, "5", "1500"])
      var child = launchProcess(spec)
      check child.winJobHandle != 0
      # Give the worker time to finish its ramp (holdMiB * 5 ms) and enter
      # its hold before reading the peak, while it is still alive.
      sleep(holdMiB * 5 + 300)
      let peak = readPeakJobMemoryUsed(Handle(child.winJobHandle))
      discard child.waitForCompletion(timeout = 15_000)
      child.close()
      checkpoint "peak bytes: " & $peak
      check peak >= uint64(holdMiB - 2) * 1024 * 1024
else:
  echo "t_windows_memory_cap_watcher: Windows only"
