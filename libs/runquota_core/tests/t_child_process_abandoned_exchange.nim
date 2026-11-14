## When ``runCapturedProcess`` cannot finish reading a child's output, it must
## still leave no child behind: not one blocked on a pipe nobody reads, and not
## one sitting unreaped in the process table of a daemon that runs for weeks.
##
## THE GAP THIS PINS. The POSIX capture is one ``poll(2)`` loop. Two failures
## used to abandon it with an output pipe not yet at end of input -- ``poll``
## itself failing with anything but ``EINTR``, and a ``read`` of an output
## pipe failing -- and both then skipped the wait, because a child still
## writing to an abandoned pipe could block forever and the wait with it. So
## the child was left alive and blocked, and ``Process.close`` (which does not
## wait) left it in the process table after it died. ``poll``'s transient
## allocation failure (``EAGAIN`` in POSIX, ``ENOMEM`` on Linux) was treated
## the same way, failing a capture that a retry would have completed; the
## retry it now gets is bounded, so a failure that never clears is abandoned
## like a permanent one rather than spinning forever.
##
## WHY FAULT INJECTION, which this suite otherwise avoids. Neither failure can
## be provoked from outside the process: ``poll`` on three descriptors does not
## run out of table, and a pipe ``read`` does not fail with ``EIO``. The
## helper's ``-d:runquotaChildProcessFaults`` hook (set for this binary alone
## by ``t_child_process_abandoned_exchange.nims``, absent from every
## production build) makes the NEXT ``poll`` or ``read`` fail with a chosen
## errno, and nothing else: the child is real, its pipes are real, and so are
## the kill and the wait the helper performs.
##
## HOW "NOTHING LEFT BEHIND" IS CHECKED. Every capture in this process that
## completes waits for its child, so after a case ``waitpid(-1, WNOHANG)`` must
## report ``ECHILD`` -- no children at all. A child left blocked would answer
## 0 (alive, not exited) and one left dead but unreaped would answer its pid;
## both fail the case. The blocked child is this test binary re-executed,
## writing four pipe-fulls to stdout and then sleeping, so on the old code it
## is alive and blocked when the check runs.
##
## THE READ CASE HANGS ON THE OLD CODE, so it runs in a re-executed copy of
## this binary under a deadline (``tests/support/child_watchdog``), turning the
## hang into a red result. The hang is the worse half of the defect: the child
## blocks writing the stdout pipe nobody reads any more, never exits, and so
## never closes the stderr pipe the loop is still polling.
##
## Measured against runquota ``agents`` ``1701577`` with only the hook added:
## every poll case fails -- a transient failure fails the capture and leaves
## its child running, and a permanent one leaves its child running -- and the
## read case is still running at its deadline.
##
## FALSIFYING MUTATIONS: make ``abandonChild`` a no-op and both poll-failure
## cases that give up fail on ``waitpid`` and the read case hangs past its
## deadline; move
## the read-failure ``abandonChild`` back after the loop and the read case
## hangs; drop the ``EAGAIN``/``ENOMEM`` retry and the first two cases fail
## on ``captured.ok``; drop its bound and the never-clearing case retries
## past it, then captures the writer to the end of its 60 s sleep and fails
## on ``not captured.ok``.

import std/[os, strutils, unittest]

import runquota_core/child_process

import ../../../tests/support/child_watchdog

when defined(posix):
  import std/posix

const
  EchoFlag = "--abandoned-exchange-echo"
  BlockingWriterFlag = "--abandoned-exchange-blocking-writer"
  ReadFailureCaseFlag = "--abandoned-exchange-read-failure-case"
  ReadFailureDeadlineSeconds = 30
    ## The fixed helper returns in milliseconds; the old one never does.
  BlockedWriteBytes = 4 * 65_536
    ## Four times the 65_536-byte pipe capacity measured on the development
    ## host, so the writer is certainly blocked once nobody reads.
  WriterSleepSeconds = 60
    ## Long enough that a child the helper failed to stop is still alive when
    ## the case checks for it; short enough not to outlive a failed run long.

if paramCount() >= 1 and paramStr(1) == EchoFlag:
  stdout.write(stdin.readAll())
  stdout.flushFile()
  quit(0)
if paramCount() >= 1 and paramStr(1) == BlockingWriterFlag:
  stdout.write(repeat('w', BlockedWriteBytes))
  stdout.flushFile()
  sleep(WriterSleepSeconds * 1000)
  quit(0)

when defined(posix):
  proc childrenLeft(): string =
    ## "" when this process has no children; otherwise what is left.
    var status: cint = 0
    let pid = waitpid(Pid(-1), status, WNOHANG)
    if pid < 0 and errno == ECHILD:
      return ""
    if pid == 0:
      return "a child is still running: runCapturedProcess neither stopped " &
        "nor waited for it"
    if pid > 0:
      return "child " & $pid & " had exited but was never reaped"
    "waitpid(-1, WNOHANG) failed: " & $strerror(errno)

  proc reapLeftovers() =
    ## Reap any child an EARLIER, failed case left dead, so that each case's
    ## ``childrenLeft`` verdict is about its own child alone. Without this, a
    ## failing case's zombie is reported again -- by pid, as if it were
    ## the next case's -- by every case after it. A child still running
    ## cannot be reaped without blocking and is left to fail the next check.
    var status: cint = 0
    while waitpid(Pid(-1), status, WNOHANG) > 0:
      discard

  proc readFailureCase() =
    ## Runs in a re-executed child so the parent can bound it. Exit 0 means
    ## the capture returned, reported the read failure, and left no child.
    injectChildProcessFault(faultRead, EIO)
    let captured = runCapturedProcess(getAppFilename(),
      [BlockingWriterFlag], options = {})
    if captured.ok or "cannot read child output" notin captured.failure:
      stderr.writeLine("unexpected result: ok=", captured.ok, " failure=",
        captured.failure)
      quit(1)
    let left = childrenLeft()
    if left.len > 0:
      stderr.writeLine(left)
      quit(1)
    quit(0)

  if paramCount() >= 1 and paramStr(1) == ReadFailureCaseFlag:
    readFailureCase()

  suite "runCapturedProcess leaves no child behind an abandoned exchange":
    setup:
      clearChildProcessFaults()
      reapLeftovers()

    test "a transient poll failure is retried and the capture completes":
      injectChildProcessFault(faultPoll, ENOMEM)
      injectChildProcessFault(faultPoll, EAGAIN)
      let captured = runCapturedProcess(getAppFilename(), [EchoFlag],
        input = "retried\n", options = {})
      checkpoint("failure: " & captured.failure)
      check captured.ok
      check captured.output == "retried\n"
      check childrenLeft() == ""

    test "transient poll failures are retried up to the limit":
      injectChildProcessFault(faultPoll, ENOMEM,
        times = childProcessPollRetryLimit())
      let captured = runCapturedProcess(getAppFilename(), [EchoFlag],
        input = "limit\n", options = {})
      checkpoint("failure: " & captured.failure)
      check captured.ok
      check captured.output == "limit\n"
      check childrenLeft() == ""

    test "a transient poll failure that never clears stops and reaps the child":
      injectChildProcessFault(faultPoll, ENOMEM,
        times = childProcessPollRetryLimit() + 1)
      let captured = runCapturedProcess(getAppFilename(),
        [BlockingWriterFlag], options = {})
      check not captured.ok
      check "cannot wait on the child's pipes" in captured.failure
      check childrenLeft() == ""

    test "a poll failure stops and reaps the child":
      injectChildProcessFault(faultPoll, EINVAL)
      let captured = runCapturedProcess(getAppFilename(),
        [BlockingWriterFlag], options = {})
      check not captured.ok
      check "cannot wait on the child's pipes" in captured.failure
      check childrenLeft() == ""

    test "a failed read stops and reaps the child":
      let child = startSupervisedChild(getAppFilename(),
        [ReadFailureCaseFlag])
      let code = waitBounded(child, ReadFailureDeadlineSeconds)
      if code == -1:
        killProcessTree(child)
        child.close()
        checkpoint("the capture did not return within " &
          $ReadFailureDeadlineSeconds & "s: the child was left blocked on " &
          "the pipe whose read failed, holding the other pipe open")
        fail()
      else:
        child.close()
        check code == 0
