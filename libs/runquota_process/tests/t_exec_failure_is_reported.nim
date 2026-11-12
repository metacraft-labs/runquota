## A child that cannot be exec'd reports why, on its own stderr, instead of
## exiting 127 with no output.
##
## The case that motivated it: a recipe's `sh -c <script>` edge whose script
## grew past Linux's per-argument limit (`MAX_ARG_STRLEN`, 131072 bytes) failed
## `execve` with E2BIG and the child left through `_exit(127)` having said
## nothing, so the build reported an exit code and an empty log.
##
## The instrument is the production launcher on real programs: an argument
## larger than the kernel accepts (Linux only: other kernels size it
## differently) and a program that does not exist. The child's stderr must name
## the program, the errno, and the size of the argument vector it tried to pass.
##
## MOCKS: none. Real processes, launched by the production launcher.

import std/[strutils, unittest]

import runquota_process

proc launch(argv: seq[string]): ProcessCompletion =
  var child = launchProcess(commandSpec(argv))
  defer: child.close()
  child.waitForCompletion(timeout = 10_000)

suite "exec failure reporting":
  when defined(linux):
    test "an argument over MAX_ARG_STRLEN names E2BIG and the argument size":
      let script = "exit 0; " & repeat('x', 140_000)
      let completion = launch(@["/bin/sh", "-c", script])
      check completion.exited
      check completion.exitCode == 127
      check "E2BIG" in completion.stderr
      check "/bin/sh" in completion.stderr
      # Total bytes of argv: the script plus "/bin/sh" and "-c", each with a NUL.
      check ("argv bytes " & $(script.len + 1 + len("/bin/sh") + 1 + 3)) in
        completion.stderr

  test "a program that does not exist names ENOENT":
    let completion = launch(@["/nonexistent/rq-test-program"])
    check completion.exited
    check completion.exitCode == 127
    check "ENOENT" in completion.stderr
    check "/nonexistent/rq-test-program" in completion.stderr
