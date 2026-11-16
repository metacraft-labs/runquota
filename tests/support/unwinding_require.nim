## A FATAL PRECONDITION THAT STILL RUNS THE FIXTURE'S CLEANUP.
##
## `std/unittest`'s `require` sets `abortOnError` and lets the failing
## `check` call `quit(1)`. `quit` does not unwind: no `finally`, no `defer`
## runs (the module's own documentation says teardown is skipped). A test
## that owns a real child process -- a private `runquotad` -- and fails a
## `require` inside the `try` that owns it therefore exits with the child
## still running, reparented to init and holding its socket. That is how
## `t_ambient_load_attribution` once left a daemon behind after rejecting a
## measurement on a busy host (reprobuild-pm
## `issues/2026-10-07-runquota-headroom-require-exits-before-test-daemon-cleanup.md`).
##
## `requireUnwinding` keeps the failure fatal for the test -- nothing after
## it in the test body runs, and the test is reported FAILED with the
## message -- but does it by RAISING, so every enclosing `finally` and
## `defer` stops what the test started before unittest records the failure.
## It is not a nonfatal `check`: an invalid measurement must not continue.
##
## Active in every build mode; it is not an `assert`.

type
  RequirementFailed* = object of CatchableError
    ## Raised by `requireUnwinding`. A `CatchableError`, so unittest's
    ## per-test handler catches it after the unwinding and marks the test
    ## failed with the message.

proc requireUnwinding*(condition: bool; message: string) =
  ## Fail the current test fatally, unwinding owned cleanup first.
  if not condition:
    raise newException(RequirementFailed, message)
