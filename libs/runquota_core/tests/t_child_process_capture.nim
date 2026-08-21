## ``runCapturedProcess`` is the seam every RunQuota spawner was converted
## onto, so its contract is asserted here rather than only through each
## caller.
##
## THE SHAPE IT REPLACED. ``execProcess(command, args = ..., options =
## {poUsePath})`` looks like it only asks for a PATH lookup. It does much more:
## ``options`` defaults to ``{poStdErrToStdOut, poUsePath, poEvalCommand}`` and
## passing it replaces that default wholesale. ``execProcess``'s body loops on
## ``outputStream`` and reads no other stream, so with ``poStdErrToStdOut``
## gone stderr has a pipe of its own that nobody will ever read. A pipe holds a
## bounded amount before a write to it blocks -- 65_536 bytes as measured on
## the development host, and it does not grow with the size of the write -- so
## a child with more than that to say on stderr blocks in ``write(2)``, never
## exits, and the loop, which only breaks when the child stops running, spins
## forever. ``execProcess`` also never closes stdin, so a child that reads to
## end of input never gets one.
##
## Both are exercised below against a real ``/bin/sh``, because a build script
## or a compiler is exactly the kind of child that has a lot to say on stderr
## and exactly the kind this repository runs through the helper.
##
## Structure, as in every deadlock regression test here: a wedged call cannot
## report its own failure, so the work runs in a re-executed child that the
## parent waits on with a bounded deadline, turning a hang into a red result.
##
## No mocks. The subject is a real child process with real pipes; only the
## scheduling of the call is test-owned.

import std/[os, osproc, strutils, tempfiles, unittest]

import runquota_core/child_process

import ../../../tests/support/child_watchdog

const
  ChildFlag = "--captured-process-child"

  Shell = "/bin/sh"
  StdoutHead = "CAPTURE-STDOUT-HEAD"
  StdoutTail = "CAPTURE-STDOUT-TAIL"
  StdinEcho = "CAPTURE-STDIN-SEEN-EOF"
  StdinPayload = "captured-process-stdin-payload"

  ## 600 x (512 payload bytes + newline) = 307_800 bytes on stderr, more than
  ## 4x the measured pipe capacity, so the test cannot pass by accident on a
  ## host whose pipes are somewhat larger than this one's.
  StderrRows = 600
  StderrPayloadBytes = 512
  MeasuredPipeCapacityBytes = 65_536

  ChildDeadlineSeconds = 60
  SurvivorGraceSeconds = 10

proc floodScript(workDir: string): string =
  ## stdout, then a flood on stderr, then stdout again. The trailing stdout
  ## line is what proves the child was still able to make progress after the
  ## stderr pipe had been filled -- an "ordering fix" that merely read stderr
  ## first would lose it. The temporary directory rides along in a shell
  ## comment so a wedged shell still carries the marker `awaitNoSurvivors`
  ## looks for in its argv.
  "echo " & StdoutHead & "; " &
  "i=0; while [ $i -lt " & $StderrRows & " ]; do " &
  "printf '%0" & $StderrPayloadBytes & "d\\n' $i >&2; " &
  "i=$((i+1)); done; " &
  "echo " & StdoutTail & " # " & workDir

proc stdinScript(workDir: string): string =
  ## Reads to end of input before it answers. Nobody writes to this child, so
  ## the only thing that can produce that end of input is the caller closing
  ## the pipe -- which `execProcess` never did.
  "cat >/dev/null; echo " & StdinEcho & " # " & workDir

proc runCaptureChild(workDir, resultPath: string) =
  let flood = runCapturedProcess(
    Shell, args = ["-c", floodScript(workDir)], options = {})

  # No `input`: the point is that stdin is closed even when there was nothing
  # to write, which is the case `execProcess` could never satisfy.
  let silent = runCapturedProcess(
    Shell, args = ["-c", stdinScript(workDir)], options = {})

  # And with input, the child must see exactly what was written and then EOF.
  let fed = runCapturedProcess(
    Shell, args = ["-c", "cat; echo ' # " & workDir & "' >/dev/null"],
    input = StdinPayload, options = {})

  let failed = runCapturedProcess(
    Shell, args = ["-c", "echo oops >&2; exit 3 # " & workDir], options = {})

  let missing = runCapturedProcess(
    workDir / "no-such-tool", args = [], options = {})

  var report = ""
  report.add("floodOk=" & $flood.ok & "\n")
  report.add("floodHead=" & $(StdoutHead in flood.output) & "\n")
  report.add("floodTail=" & $(StdoutTail in flood.output) & "\n")
  report.add("floodOutputBytes=" & $flood.output.len & "\n")
  report.add("floodErrorBytes=" & $flood.error.len & "\n")
  report.add("silentOk=" & $silent.ok & "\n")
  report.add("silentSawEof=" & $(StdinEcho in silent.output) & "\n")
  report.add("fedOutput=" & fed.output.strip() & "\n")
  report.add("failedOk=" & $failed.ok & "\n")
  report.add("failedExit=" & $failed.exitCode & "\n")
  report.add("failedError=" & failed.error.strip() & "\n")
  report.add("failedFailureLen=" & $failed.failure.len & "\n")
  report.add("missingOk=" & $missing.ok & "\n")
  report.add("missingFailureLen=" & $missing.failure.len & "\n")
  writeFile(resultPath, report)

proc reportField(report: string; key: string): string =
  for line in report.splitLines():
    let separator = line.find('=')
    if separator > 0 and line[0 ..< separator] == key:
      return line[separator + 1 .. ^1]
  ""

# The child role must be dispatched before `unittest` takes over the process.
if paramCount() >= 3 and paramStr(1) == ChildFlag:
  runCaptureChild(paramStr(2), paramStr(3))
  quit(0)

suite "runCapturedProcess":
  test "every stream is serviced and stdin is closed even with nothing to say":
    when defined(windows):
      skip()
    else:
      let work = createTempDir("runquota_captured_process_", "")
      defer: removeDir(work)
      let resultPath = work / "result.txt"

      let child = startSupervisedChild(
        getAppFilename(), [ChildFlag, work, resultPath])
      let code = waitBounded(child, ChildDeadlineSeconds)
      if code == -1:
        # The blocked shells are grandchildren; signalling only `child` strands
        # them on pid 1, where they look like a live defect forever.
        killProcessTree(child)
        child.close()
        checkpoint(
          "runCapturedProcess did not return within " &
          $ChildDeadlineSeconds & "s. Either a child filled the " &
          $MeasuredPipeCapacityBytes &
          "-byte stderr pipe while the caller drained stdout to EOF, or a " &
          "child that reads to end of input never got one because stdin was " &
          "left open.")
        fail()
      else:
        child.close()
        check code == 0
        check fileExists(resultPath)
        let report = readFile(resultPath)

        # A child that floods stderr still completes, and stdout arrives whole
        # -- the line before the flood and the line after it.
        check report.reportField("floodOk") == "true"
        check report.reportField("floodHead") == "true"
        check report.reportField("floodTail") == "true"

        # The flood was real. Without this the deadlock assertion above could
        # pass on a run where the shell wrote nothing.
        check report.reportField("floodErrorBytes").parseInt() >
          4 * MeasuredPipeCapacityBytes

        # And it stayed on stderr. Merging the two streams would also avoid
        # the deadlock, and would silently corrupt every caller that parses
        # stdout as data.
        check report.reportField("floodOutputBytes").parseInt() <
          MeasuredPipeCapacityBytes

        # Stdin is closed even when the caller had nothing to write.
        check report.reportField("silentOk") == "true"
        check report.reportField("silentSawEof") == "true"

        # And when it did, the child saw exactly that and then end of input.
        check report.reportField("fedOutput") == StdinPayload

        # A child that runs and exits non-zero is not a failure to run: the
        # exit code and the diagnostic are both reported, and `failure` -- the
        # field that means "could not run it at all" -- stays empty.
        check report.reportField("failedOk") == "false"
        check report.reportField("failedExit") == "3"
        check report.reportField("failedError") == "oops"
        check report.reportField("failedFailureLen") == "0"

        # A tool that will not start is reported, never raised: the daemon
        # paths on the other side of this helper must degrade, not fail.
        check report.reportField("missingOk") == "false"
        check report.reportField("missingFailureLen").parseInt() > 0

      # Asserted on both paths: a run that wedges a shell and then walks away
      # leaves processes that outlive the suite entirely.
      let survivors = awaitNoSurvivors(work, SurvivorGraceSeconds)
      if survivors.len > 0:
        checkpoint("processes still alive after the test: " &
          survivors.join("; "))
      check survivors.len == 0
