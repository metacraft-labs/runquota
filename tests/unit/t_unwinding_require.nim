## `requireUnwinding` fails a test fatally AND runs the fixture's cleanup;
## `unittest.require` fails it fatally and does NOT. reprobuild-pm
## `issues/2026-10-07-runquota-headroom-require-exits-before-test-daemon-cleanup.md`:
## a `require` inside the `try` that owned a private `runquotad` quit the
## test process with the daemon still running.
##
## The behaviour is observed in a real child process -- this same binary,
## re-executed in a role -- because what is under test is what happens to
## the PROCESS: whether `finally` ran before it exited, and whether it
## exited failed. The child records each step in a file the parent reads.

import std/[os, osproc, sequtils, strutils, unittest]
import unwinding_require

const
  RoleVar = "RUNQUOTA_T_UNWINDING_REQUIRE_ROLE"
  MarkerVar = "RUNQUOTA_T_UNWINDING_REQUIRE_MARKER"

proc note(step: string) =
  let f = open(getEnv(MarkerVar), fmAppend)
  f.writeLine(step)
  f.close()

proc childRole(role: string) =
  suite "child":
    test "fatal precondition inside an owned fixture":
      note("enter")
      try:
        if role == "unwinding":
          requireUnwinding false, "controlled precondition failure"
        else:
          require false
        note("continued")
      finally:
        note("cleanup")
    test "a later test still runs":
      note("later")

proc runChild(role: string; marker: string): tuple[code: int, steps: seq[string]] =
  ## The child's own output (its deliberate FAILED report) is captured and
  ## shown only if an assertion here fails.
  removeFile(marker)
  writeFile(marker, "")
  putEnv(RoleVar, role)
  putEnv(MarkerVar, marker)
  let (output, code) = execCmdEx(quoteShell(getAppFilename()))
  delEnv(RoleVar)
  delEnv(MarkerVar)
  checkpoint("child " & role & " output:\n" & output)
  result.code = code
  result.steps = readFile(marker).splitLines().filterIt(it.len > 0)
  removeFile(marker)

when isMainModule:
  let role = getEnv(RoleVar)
  if role.len > 0:
    childRole(role)
  else:
    let marker = getTempDir() / ("t_unwinding_require_" & $getCurrentProcessId())

    suite "unwinding_require":
      test "a failed requireUnwinding runs cleanup, stops the test, fails the run":
        let (code, steps) = runChild("unwinding", marker)
        check code != 0
        check "continued" notin steps
        check steps == @["enter", "cleanup", "later"]

      test "NEGATIVE CONTROL: unittest.require quits past the cleanup":
        # The hazard the helper exists for. If this ever starts running
        # `finally`, the helper is no longer needed -- and this case says so.
        let (code, steps) = runChild("require", marker)
        check code != 0
        check steps == @["enter"]

      test "the ambient attribution fixture has no quitting or nonfatal failure":
        # It owns a private daemon inside try/finally. `require` and `quit`
        # exit past that cleanup and can orphan it; a bare `fail()` keeps
        # evaluating a measurement it has just declared invalid. Fatal
        # preconditions there go through `requireUnwinding`. The source is
        # read, not imported.
        let source = readFile(currentSourcePath().parentDir.parentDir /
          "integration" / "t_ambient_load_attribution.nim")
        var offending: seq[string] = @[]
        var lineNo = 0
        for line in source.splitLines():
          inc lineNo
          let code = line.split('#', 1)[0]
          var forbidden = false
          for token in code.split(AllChars - IdentChars):
            if token in ["require", "quit", "fail"]: forbidden = true
          if forbidden:
            offending.add("line " & $lineNo & ": " & line)
        checkpoint(offending.join("\n"))
        check offending.len == 0
