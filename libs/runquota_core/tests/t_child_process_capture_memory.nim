## ``runCapturedProcess`` must not cost the caller memory that outlives the
## call. The daemon calls it for every ``sqlite3`` it runs -- about 170 times
## per 64-action build with observation capture on -- and it runs for weeks.
##
## THE DEFECT THIS PINS. The helper used to start one drain thread per output
## stream, per child, and each drain allocated its 64 KiB read buffer as a
## Nim ``string``. Under ``--mm:arc/orc`` Nim 2.2 never returns a finished
## thread's allocator pages to the OS (``system/threadimpl.nim``'s
## ``threadProcWrapStackFrame`` calls ``deallocOsPages`` only for the
## non-destructor collectors), so each drain left ~78 KB mapped for the life
## of the process: ~156 KB per call. 2,000 calls grew the resident set by
## ~300 MB, and every later ``fork`` got dearer with it, which is how the
## daemon's CPU per build came to grow round after round.
##
## THE FALSIFYING MUTATION. Put a short-lived thread back on the capture path
## that allocates from the Nim heap -- the old ``drainStream`` with its
## ``newString(chunkSize)`` buffer, or any per-call ``createThread`` whose
## body builds a Nim string -- and the first case fails by more than an
## order of magnitude: the bound is 20 MiB, the old shape measured ~300 MB.
## The bound is generous on purpose; what passes measures well under 1 MB.
##
## WHY PEAK RESIDENT SIZE. A leak of mapped, touched pages only ever raises
## the peak, so a growth in the peak between a warmed-up start and the end is
## a lower bound on the leak, and the peak is one call on every platform
## (``getrusage`` on POSIX, ``K32GetProcessMemoryInfo`` on Windows) where the
## current size is not.
##
## The second case pins the property the thread-free rewrite had to keep: a
## child that echoes its input as it reads it, fed far more than a pipe holds,
## must not deadlock against the caller. A caller that wrote all of stdin
## before reading anything would wedge here, so the case runs in a
## re-executed child under a deadline and a hang turns into a red result.
##
## The third case (POSIX) pins that a failed exchange does not leave a
## zombie behind: a child that exits without reading its input makes the
## stdin write fail with ``EPIPE``, and ``Process.close`` does not wait, so a
## helper that skips the wait on failure leaks one process-table entry per
## such call for the life of the daemon. FALSIFYING MUTATION: drop the
## ``waitForExit`` on the failure path of ``runCapturedProcess`` and
## ``waitpid(-1, WNOHANG)`` reaps the leftover child here, failing the case.
##
## No mocks: the child is this test binary re-executed, with real pipes.

import std/[os, strutils, unittest]

import runquota_core/child_process

import ../../../tests/support/child_watchdog

when defined(posix):
  import std/posix
else:
  # `SupervisedChild` is osproc's `Process` there, closed by osproc's `close`.
  import std/osproc

const
  EchoChildFlag = "--capture-memory-echo-child"
  ExitAtOnceFlag = "--capture-memory-exit-at-once"
  LargeInputCaseFlag = "--capture-memory-large-input-case"
  StderrMarker = "capture-memory-stderr"

  WarmupCalls = 50
    ## Calls made before the baseline is taken, so the caller's own heap has
    ## grown to its steady size and only what the calls leave behind counts.
  MeasuredCalls = 2_000
  GrowthBoundBytes = 20 * 1024 * 1024
    ## The unfixed helper grew the peak by ~156 KB per call, ~300 MB over
    ## `MeasuredCalls`; the fixed one by well under 1 MB.

  LargeInputBytes = 4 * 1024 * 1024
    ## 64x the 65_536-byte pipe capacity measured on the development host.
  LargeInputDeadlineSeconds = 60

when defined(windows):
  type ProcessMemoryCounters = object
    ## ``PROCESS_MEMORY_COUNTERS``:
    ## https://learn.microsoft.com/en-us/windows/win32/api/psapi/ns-psapi-process_memory_counters
    cb: uint32
    pageFaultCount: uint32
    peakWorkingSetSize: csize_t
    workingSetSize: csize_t
    quotaPeakPagedPoolUsage: csize_t
    quotaPagedPoolUsage: csize_t
    quotaPeakNonPagedPoolUsage: csize_t
    quotaNonPagedPoolUsage: csize_t
    pagefileUsage: csize_t
    peakPagefileUsage: csize_t

  proc getCurrentProcess(): pointer {.importc: "GetCurrentProcess", stdcall,
    dynlib: "kernel32".}
  proc k32GetProcessMemoryInfo(process: pointer;
    counters: ptr ProcessMemoryCounters; size: uint32): int32 {.
    importc: "K32GetProcessMemoryInfo", stdcall, dynlib: "kernel32".}

proc peakResidentBytes(): int64 =
  ## The largest resident set this process has had so far, in bytes.
  when defined(windows):
    var counters = ProcessMemoryCounters(
      cb: uint32(sizeof(ProcessMemoryCounters)))
    doAssert k32GetProcessMemoryInfo(getCurrentProcess(), addr counters,
      counters.cb) != 0, "K32GetProcessMemoryInfo failed"
    int64(counters.peakWorkingSetSize)
  else:
    var usage: Rusage
    doAssert getrusage(RUSAGE_SELF, addr usage) == 0, "getrusage failed"
    # `ru_maxrss` is in kilobytes on Linux and in bytes on macOS:
    # https://man7.org/linux/man-pages/man2/getrusage.2.html
    when defined(macosx):
      int64(usage.ru_maxrss)
    else:
      int64(usage.ru_maxrss) * 1024

proc echoChild() =
  ## Copy stdin to stdout piece by piece, writing each piece BEFORE reading
  ## the next, then say one line on stderr. A caller that does not read
  ## stdout while it is still writing stdin wedges against this.
  var buffer = newString(16 * 1024)
  while true:
    let count = stdin.readBuffer(addr buffer[0], buffer.len)
    if count <= 0:
      break
    if stdout.writeBuffer(addr buffer[0], count) != count:
      quit(1)
    stdout.flushFile()
  stderr.write(StderrMarker & "\n")
  stderr.flushFile()
  quit(0)

proc largeInputCase() =
  ## Runs in a re-executed child so the parent can bound it. Exit 0 means the
  ## echo came back whole on stdout and the marker on stderr.
  var input = newString(LargeInputBytes)
  for i in 0 ..< input.len:
    input[i] = char(ord('a') + i mod 26)
  let captured = runCapturedProcess(getAppFilename(), [EchoChildFlag],
    input = input, options = {})
  if not captured.ok:
    stderr.writeLine("capture failed: exit ", captured.exitCode, " ",
      captured.failure)
    quit(1)
  if captured.output != input:
    stderr.writeLine("echo came back with ", captured.output.len,
      " bytes, expected ", input.len)
    quit(1)
  if captured.error.strip() != StderrMarker:
    stderr.writeLine("stderr was ", captured.error.escape())
    quit(1)
  quit(0)

if paramCount() >= 1 and paramStr(1) == EchoChildFlag:
  echoChild()
if paramCount() >= 1 and paramStr(1) == ExitAtOnceFlag:
  quit(0)
if paramCount() >= 1 and paramStr(1) == LargeInputCaseFlag:
  largeInputCase()

proc captureOnce(index: int) =
  ## One capture shaped like a daemon `sqlite3` run: input on stdin, an
  ## answer on stdout, a diagnostic on stderr, separate streams.
  let input = "row " & $index & "\n"
  let captured = runCapturedProcess(getAppFilename(), [EchoChildFlag],
    input = input, options = {})
  check captured.ok
  check captured.failure == ""
  check captured.output == input
  check captured.error.strip() == StderrMarker

suite "runCapturedProcess memory":
  test "thousands of captures leave the caller's resident set flat":
    for index in 0 ..< WarmupCalls:
      captureOnce(index)
    let baseline = peakResidentBytes()
    for index in 0 ..< MeasuredCalls:
      captureOnce(index)
    let growth = peakResidentBytes() - baseline
    let report = "peak resident set grew by " & $growth & " bytes over " &
      $MeasuredCalls & " captures (" & $(growth div MeasuredCalls) &
      " bytes per call); bound " & $GrowthBoundBytes
    # Printed on a pass too: the margin under the bound is the evidence.
    echo "  ", report
    checkpoint(report)
    check growth < GrowthBoundBytes

  when defined(posix):
    test "a child that exits without reading its input is still reaped":
      # More than a pipe holds, so the write fails with EPIPE whether the
      # child is gone before the first write or after the pipe fills.
      let input = newString(LargeInputBytes)
      let captured = runCapturedProcess(getAppFilename(), [ExitAtOnceFlag],
        input = input, options = {})
      check not captured.ok
      check captured.failure.len > 0
      # Every earlier capture in this process waited for its child, so any
      # child still waitable now is the one this call left behind.
      var status: cint = 0
      let leftover = waitpid(Pid(-1), status, WNOHANG)
      checkpoint("waitpid(-1, WNOHANG) returned " & $leftover &
        ": a positive pid is a child runCapturedProcess did not reap")
      check leftover <= 0

  test "input far larger than a pipe is echoed back without a deadlock":
    let child = startSupervisedChild(getAppFilename(), [LargeInputCaseFlag])
    let code = waitBounded(child, LargeInputDeadlineSeconds)
    if code == -1:
      killProcessTree(child)
      child.close()
      checkpoint("the capture did not return within " &
        $LargeInputDeadlineSeconds & "s: the caller stopped reading the " &
        "child's stdout while it was still writing the child's stdin")
      fail()
    else:
      child.close()
      check code == 0
