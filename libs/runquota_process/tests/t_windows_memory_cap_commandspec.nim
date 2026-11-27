## Windows memory cap, wired through `CommandSpec`/`ProcessCompletion` --
## the real integration point `launchProcess` and `waitForCompletion` use,
## on top of the Stage B mechanism `t_windows_memory_cap_watcher.nim`
## exercises directly against a job handle. This is what a caller that
## sets `CommandSpec.memoryCapBytes` / `memoryCapAction` / `memoryCapMeasure`
## (the fields `runquota_core/memory_cap.nim` and `agents` commit `d6bf86be`
## share across OSes) actually gets back.
##
## MOCKS: none. Real processes, launched by the production launcher.

when defined(windows):
  import std/[os, strutils, unittest]
  import std/winlean

  import runquota_process

  proc virtualAlloc(lpAddress: pointer; dwSize: csize_t;
                    flAllocationType, flProtect: int32): pointer {.
    stdcall, dynlib: "kernel32.dll", importc: "VirtualAlloc".}

  const
    MemCommit = 0x00001000'i32
    MemReserve = 0x00002000'i32
    PageReadWrite = 0x04'i32
    PageSizeBytes = 4096
    ChunkBytes = 1024 * 1024

  proc commitSlowlyMiB(totalMiB, delayMsPerMiB: int): bool =
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

  proc commitIgnoringFailureMiB(totalMiB, delayMsPerMiB: int) =
    ## A badly-behaved worker: never checks whether a chunk's commit
    ## succeeded, so the hard limit's own refusal does not stop it on its
    ## own -- only the watcher's `TerminateJobObject` can. Proves the
    ## watcher is a real backstop, not just the thing that wins a race a
    ## well-behaved worker would have lost to the hard limit anyway.
    for _ in 0 ..< totalMiB:
      let p = virtualAlloc(nil, csize_t(ChunkBytes),
        MemCommit or MemReserve, PageReadWrite)
      if not p.isNil:
        var off = 0
        while off < ChunkBytes:
          cast[ptr byte](cast[int](p) + off)[] = 1'u8
          off += PageSizeBytes
      sleep(delayMsPerMiB)

  proc runWorkerOrReturn() =
    let params = commandLineParams()
    if params.len == 0:
      return
    case params[0]
    of "--rqtest-commit-slowly":
      let totalMiB = parseInt(params[1])
      let delayMs = parseInt(params[2])
      let holdMs = parseInt(params[3])
      let ok = commitSlowlyMiB(totalMiB, delayMs)
      echo (if ok: "committed" else: "alloc-failed")
      sleep(holdMs)
      quit(0)
    of "--rqtest-commit-ignoring-failure":
      let totalMiB = parseInt(params[1])
      let delayMs = parseInt(params[2])
      let holdMs = parseInt(params[3])
      commitIgnoringFailureMiB(totalMiB, delayMs)
      echo "finished-ignoring-failure"
      sleep(holdMs)
      quit(0)
    else:
      return

  runWorkerOrReturn()

  const
    TotalMiB = 96
    DelayMsPerMiB = 10
    CapMiB = 24

  proc capSpec(action: MemoryCapAction; capBytes: uint64;
              measure = false; holdMs = 2000): CommandSpec =
    result = commandSpec(@[getAppFilename(), "--rqtest-commit-slowly",
      $TotalMiB, $DelayMsPerMiB, $holdMs])
    result.memoryCapBytes = capBytes
    result.memoryCapAction = action
    result.memoryCapMeasure = measure

  suite "windows memory cap via CommandSpec":
    test "kill_mode_terminates_or_refuses_the_commit_but_never_both_" &
        "silently_passes_the_cap":
      # The design's own words (RunQuota-Memory-Caps.md, Windows): the hard
      # limit's synchronous commit refusal and the watcher's
      # notification-triggered TerminateJobObject "are not ordered against
      # each other". A well-behaved worker that checks its own allocation
      # failures (this one does) usually sees the hard limit's refusal
      # first -- capReached -- because that is a synchronous kernel check,
      # while the watcher needs an IOCP round trip and a thread wake-up.
      # Either classification is a correct outcome; silently exceeding the
      # cap with neither is not.
      var spec = capSpec(mcaKill, uint64(CapMiB) * 1024 * 1024)
      var child = launchProcess(spec)
      let completion = child.waitForCompletion(timeout = 15_000)
      child.close()
      checkpoint "exit: " & $completion.exitCode & "; peak: " &
        $completion.memoryPeakBytes & "; cap: " & $completion.memoryCapBytes &
        "; killed: " & $completion.capKilled &
        "; reached: " & $completion.capReached &
        "; stdout: " & completion.stdout
      check completion.exited
      check completion.memoryCapMeasured
      check completion.memoryCapBytes == uint64(CapMiB) * 1024 * 1024
      check completion.memoryPeakSource == mpsJob
      check completion.capExceeded
      check completion.capKilled or completion.capReached
      if completion.capKilled:
        check completion.exitCode == int(windowsCapExceededExitCode)
      else:
        check completion.exitCode == 0
        check "alloc-failed" in completion.stdout

    test "kill_mode_watcher_is_a_real_backstop_for_a_worker_that_ignores_" &
        "its_own_allocation_failures":
      # No "or capReached" escape here: this worker never checks whether a
      # commit succeeded, so the hard limit's refusal alone cannot stop it
      # -- it would otherwise run to its full TotalMiB and exit 0. Only the
      # watcher's TerminateJobObject can end it before that.
      var spec = commandSpec(@[getAppFilename(),
        "--rqtest-commit-ignoring-failure", $TotalMiB, $DelayMsPerMiB, "2000"])
      spec.memoryCapBytes = uint64(CapMiB) * 1024 * 1024
      spec.memoryCapAction = mcaKill
      var child = launchProcess(spec)
      let completion = child.waitForCompletion(timeout = 15_000)
      child.close()
      checkpoint "exit: " & $completion.exitCode & "; killed: " &
        $completion.capKilled & "; stdout: " & completion.stdout
      check completion.exited
      check completion.capKilled
      check completion.exitCode == int(windowsCapExceededExitCode)
      check "finished-ignoring-failure" notin completion.stdout

    test "advisory_mode_measures_and_reports_without_killing":
      var spec = capSpec(mcaAdvisory, uint64(CapMiB) * 1024 * 1024,
        holdMs = 200)
      var child = launchProcess(spec)
      let completion = child.waitForCompletion(timeout = 15_000)
      child.close()
      checkpoint "exit: " & $completion.exitCode & "; peak: " &
        $completion.memoryPeakBytes
      check completion.exited
      check completion.exitCode == 0 # nothing killed it
      check not completion.capKilled
      check completion.capExceeded # the workload passed CapMiB well before holding
      check completion.memoryPeakSource == mpsJob

    test "measure_only_with_no_cap_bytes_reports_the_peak_and_no_breach":
      var spec = capSpec(mcaAdvisory, 0'u64, measure = true, holdMs = 200)
      var child = launchProcess(spec)
      let completion = child.waitForCompletion(timeout = 15_000)
      child.close()
      checkpoint "peak: " & $completion.memoryPeakBytes
      check completion.exited
      check completion.exitCode == 0
      check completion.memoryCapMeasured
      check completion.memoryCapBytes == 0
      check not completion.capExceeded # no cap bytes to compare the peak against
      check completion.memoryPeakBytes >=
        uint64(TotalMiB - 2) * 1024 * 1024 # the full, uncapped workload

    test "no_cap_requested_measures_nothing":
      var spec = commandSpec(@[getAppFilename(), "--rqtest-commit-slowly",
        "4", "5", "50"])
      # memoryCapBytes/memoryCapMeasure default to 0/false; memoryCapAction's
      # zero value is mcaAdvisory, which is irrelevant here since nothing
      # asks to measure at all.
      var child = launchProcess(spec)
      let completion = child.waitForCompletion(timeout = 10_000)
      child.close()
      check completion.exited
      check not completion.memoryCapMeasured
      check completion.memoryPeakBytes == 0
      check completion.memoryPeakSource == mpsNone
else:
  echo "t_windows_memory_cap_commandspec: Windows only"
