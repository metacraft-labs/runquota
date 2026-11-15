## `runCapturedProcess` must not grow the caller's Windows handle table, call
## after call. The daemon runs this helper for every `sqlite3` it invokes --
## about 170 times per 64-action build with observation capture on -- and it
## runs for weeks.
##
## THE DEFECT THIS PINS. On Windows, `runCapturedProcess` starts one or two
## drain threads per captured child (anonymous pipes cannot be `poll`ed, so
## the calling thread cannot service both streams itself) and joins them with
## `joinThread`. `std/typedthreads`'s Windows `joinThread` is only
## `WaitForSingleObject(t.sys, -1)`; nothing in Nim's runtime ever calls
## `CloseHandle` on the handle `CreateThread` returned, on any memory
## management strategy. Every join therefore left the `CreateThread` handle
## open for the life of the process: two handles per captured child, forever.
##
## THE FALSIFYING MUTATION. Drop the `closeHandle(handle(...))` calls this
## defect's fix added after `joinThread(outputThread)` /
## `joinThread(errorThread)` in `child_process.nim`, and this case fails:
## `GetProcessHandleCount` grows by exactly two handles per call (measured
## 100 over 50 calls on this host before the fix), where the bound below
## allows room for the daemon's own bookkeeping but not for a per-call leak.
##
## No mocks: a real child (`cmd.exe`) and the real Windows handle table of
## this process, read through `GetProcessHandleCount`.
## https://learn.microsoft.com/windows/win32/api/processthreadsapi/nf-processthreadsapi-getprocesshandlecount
##
## WINDOWS ONLY: POSIX's `runCapturedProcess` is the `poll` loop in the same
## module, which creates no thread at all, so this defect shape does not
## exist there.
when defined(windows):
  import std/[unittest, winlean]

  import runquota_core/child_process

  const
    WarmupCalls = 10
      ## Calls made before the baseline is taken, so the caller's own
      ## one-time handle use (first pipe creation, CRT lazy init) does not
      ## count against the bound below.
    MeasuredCalls = 50
    HandleGrowthBound = 10
      ## The unfixed helper grows the table by exactly 2 handles per call --
      ## 100 over `MeasuredCalls`. The bound is generous on purpose; what
      ## passes measures 0.

  proc getCurrentProcessHandle(): Handle {.importc: "GetCurrentProcess",
    stdcall, dynlib: "kernel32".}
  proc getProcessHandleCount(process: Handle; count: ptr int32): WINBOOL {.
    importc: "GetProcessHandleCount", stdcall, dynlib: "kernel32".}

  proc processHandleCount(): int32 =
    doAssert getProcessHandleCount(getCurrentProcessHandle(), addr result) != 0,
      "GetProcessHandleCount failed"

  proc captureOnce() =
    let captured = runCapturedProcess("cmd.exe", ["/c", "echo handle-leak-probe"])
    check captured.ok
    check captured.failure == ""

  suite "runCapturedProcess Windows handle table":
    test "captures leave the process handle table flat":
      for _ in 0 ..< WarmupCalls:
        captureOnce()
      let before = processHandleCount()
      for _ in 0 ..< MeasuredCalls:
        captureOnce()
      let after = processHandleCount()
      let growth = after - before
      let report = "process handle count grew by " & $growth & " over " &
        $MeasuredCalls & " captures (before=" & $before & " after=" & $after &
        "); bound " & $HandleGrowthBound
      # Printed on a pass too: the margin under the bound is the evidence.
      echo "  ", report
      checkpoint(report)
      check growth < HandleGrowthBound
