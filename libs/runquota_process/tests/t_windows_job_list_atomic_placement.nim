## Windows: `PROC_THREAD_ATTRIBUTE_JOB_LIST` places a leased tree's leader in
## its Job Object AT CREATION, so there is no window between the process
## existing and its membership taking effect. The previous
## `CreateJobObjectW`-then-`AssignProcessToJobObject` sequence had exactly
## that window, and its own comment accepted it: "if it was launched
## without CREATE_SUSPENDED it may have spawned a grandchild before we get
## here. We accept this race for now."
##
## THE INSTRUMENT is the production launcher (`launchProcess`) on a real
## worker process: this test binary re-invoked, cargo-style, as the other
## `t_windows_*` tests already do.
##
## FALSIFYING MUTATION: reverting `launchWindowsProcess` to the old
## `CreateJobObjectW` + assign-after-start sequence removes the guarantee
## this test checks -- membership is then established shortly AFTER the
## child's first instruction runs, not before it, which is the window the
## prior implementation's own comment accepted. `IsProcessInJob`, checked by
## the worker as its very first action, would then be able to read `FALSE`
## on a fast enough host or a loaded one.
##
## MOCKS: none. Real processes, launched by the production launcher.

when defined(windows):
  import std/[os, strutils, unittest]
  import std/winlean

  import runquota_process

  proc isProcessInJob(processHandle, jobHandle: Handle;
                      result: var WINBOOL): WINBOOL {.
    stdcall, dynlib: "kernel32.dll", importc: "IsProcessInJob".}

  proc runWorkerOrReturn() =
    let params = commandLineParams()
    if params.len == 0:
      return
    case params[0]
    of "--rqtest-report-job-membership":
      # The absolute first thing this process does: ask whether it is
      # already a member of ANY job (jobHandle = NULL). Nothing else runs
      # before this check.
      var inJob: WINBOOL = 0
      discard isProcessInJob(getCurrentProcess(), 0, inJob)
      echo (if inJob != 0: "1" else: "0")
      quit(0)
    else:
      return

  runWorkerOrReturn()

  suite "windows job list atomic placement":
    test "job_list_places_the_child_before_its_first_instruction: " &
        "the worker already observes itself in a job the instant it checks":
      var spec = commandSpec(@[getAppFilename(),
        "--rqtest-report-job-membership"])
      var child = launchProcess(spec)
      let completion = child.waitForCompletion(timeout = 10_000)
      child.close()
      checkpoint "stdout: " & completion.stdout & "; exit: " &
        $completion.exitCode
      check completion.exited
      check completion.exitCode == 0
      check completion.stdout.strip() == "1"
else:
  echo "t_windows_job_list_atomic_placement: Windows only"
