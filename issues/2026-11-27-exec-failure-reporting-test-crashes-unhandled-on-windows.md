# `exec failure reporting`'s "names ENOENT" case crashes unhandled on Windows instead of failing the check

| Field | Value |
| --- | --- |
| Status | Open |
| Observed in | `runquota` @ `7c98da54` (`agents` tip); repro 0.2.19, Nim 2.2.8, eli-pc (Windows 11 x86_64) |
| Area | `libs/runquota_process/tests/t_exec_failure_is_reported.nim`; `launchProcess`'s Windows arm in `libs/runquota_process/src/runquota_process.nim` |
| Expectation | The test file's own docstring: "The child's stderr must name the program, the errno... MOCKS: none." |

## Observed

`t_exec_failure_is_reported.nim` has two cases. The first is correctly
guarded `when defined(linux):` (it names `E2BIG`, a Linux-specific
`execve` failure). The second, "a program that does not exist names
ENOENT", has no platform guard and runs on every OS:

```nim
test "a program that does not exist names ENOENT":
  let completion = launch(@["/nonexistent/rq-test-program"])
  check completion.exited
  check completion.exitCode == 127
  check "ENOENT" in completion.stderr
  check "/nonexistent/rq-test-program" in completion.stderr
```

On Windows this does not fail a `check` — it crashes the whole test binary
with an unhandled `OSError` before the suite can report anything:

```
[Suite] exec failure reporting
oserrors.nim(92)         raiseOSError

    Unhandled exception: The system cannot find the file specified.
Additional info: Requested command not found: '/nonexistent/rq-test-program'. OS error: [OSError]
  [FAILED] a program that does not exist names ENOENT
```

Confirmed present on **both** sides of the rq-memcap-win Windows memory-cap
work: it fails identically against the pre-change launcher (`startProcess`
raising inside `launchWindowsProcess`'s `try`/`except`/`raise`) and against
the rewritten one (`raiseOSError` at the end of `launchWindowsProcess` on a
failed `CreateProcessW`). Neither launcher has ever caught a failed launch
and turned it into a 127-exit completion with a reported reason on Windows;
that mechanism (`childReportExecFailure`, `execFailurePrefix`) is POSIX-only.
This is a pre-existing gap, not a regression from that work.

## Why it is a mistake, not a limitation to document

1. `/nonexistent/rq-test-program` is a POSIX-style absolute path. It is not
   a meaningful Windows test input at all (Windows has no such root), so the
   case does not even exercise a realistic Windows scenario.
2. Even if it did, an unhandled exception out of `launchProcess` is not what
   this test file is checking for: every other `runquota_process` caller
   (the CLI, the daemon's lease launcher) must already tolerate
   `launchProcess` raising on Windows when a command does not exist, since
   nothing catches it today. Whether that is the right contract for Windows
   (raise vs. a 127 completion with a reason) is unsettled, but a test
   silently crashing instead of asserting it either way hides the gap.

## Suggested direction

Either:
- Guard the second case `when defined(posix):` too, next to a note that
  Windows has no analogous mechanism yet (parking the Windows case rather
  than asserting nothing); or
- Decide the Windows contract (raise, documented, vs. catch and report a
  127 completion) and add a Windows-specific case that exercises it instead
  of silently falling through to a crash.
