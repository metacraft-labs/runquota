## ``runSqlite`` must not deadlock against its own child, no matter how much
## either stream produces.
##
## A child process gets one pipe per stream and each pipe holds a fixed amount
## before a write to it blocks. Measured on the development host, that
## capacity is 65_536 bytes and it does not grow with the size of the write.
## So a parent that drains stdout to EOF *before* it reads stderr has a
## deadlock in it: once the child has put 64 KiB into stderr, the child blocks
## in ``write`` and stops producing stdout, while the parent blocks in ``read``
## waiting for a stdout EOF that can only arrive after the child exits.
## Neither side can move. The same argument applies to stdin, which is why the
## fix drains all three concurrently rather than just swapping two reads.
##
## The test drives the real ``runSqlite`` -- not a stand-in -- and makes the
## real ``sqlite3`` emit 500 rows of 512 bytes to stderr via ``.output
## /dev/stderr`` while still returning rows on stdout. That is ~250 KiB of
## stderr against a 64 KiB pipe, so the pre-fix ordering cannot survive it.
##
## Structure: a hanging test cannot report a failure, so the call under test
## runs in a **child process** (this same binary, re-executed with
## ``ChildFlag``) and the parent waits on it with a bounded deadline. A wedged
## implementation is killed at the deadline and reported as a normal red test
## instead of stalling the suite forever.
##
## No mocks are used. The child is the production ``sqlite3`` binary reached
## through the production helper; only the *scheduling* of the call is
## test-owned.

import std/[os, osproc, strutils, tempfiles, times, unittest]

import runquota_observation_store/sqlite_cli

const
  ChildFlag = "--stderr-flood-child"
  StdoutHead = "STDOUT-HEAD"
  StdoutTail = "STDOUT-TAIL"

  ## 600 rows x (512 payload bytes + newline) = 307_800 bytes. Chosen to clear
  ## the measured 65_536-byte pipe capacity by more than 4x, so the test
  ## cannot pass by accident on a host whose pipes are somewhat larger than
  ## this one's.
  StderrRows = 600
  StderrPayloadBytes = 512
  MeasuredPipeCapacityBytes = 65_536

  ## Generous relative to a call that takes milliseconds when it works. The
  ## point of the bound is to convert a hang into a red result, not to police
  ## latency.
  ChildDeadlineSeconds = 60

proc floodSql(): string =
  ## stdout, then a flood on stderr, then stdout again. The trailing stdout
  ## row is what proves the child was still able to make progress after the
  ## stderr pipe had been filled.
  "select '" & StdoutHead & "';\n" &
  ".output /dev/stderr\n" &
  "with recursive n(i) as (select 1 union all select i + 1 from n where i < " &
    $StderrRows & ")\n" &
  "select replace(hex(zeroblob(" & $(StderrPayloadBytes div 2) &
    ")), '0', 'e') from n;\n" &
  ".output stdout\n" &
  "select '" & StdoutTail & "';"

proc runFloodChild(dbPath, resultPath: string) =
  ## The half that deadlocks against an unfixed ``runSqlite``. Writes what it
  ## observed where the parent can read it, then exits.
  let outcome = runSqlite(dbPath, floodSql())
  var report = ""
  report.add("ok=" & $outcome.ok & "\n")
  report.add("exit=" & $outcome.exitCode & "\n")
  report.add("outputBytes=" & $outcome.output.len & "\n")
  report.add("errorBytes=" & $outcome.error.len & "\n")
  report.add("head=" & $(StdoutHead in outcome.output) & "\n")
  report.add("tail=" & $(StdoutTail in outcome.output) & "\n")
  report.add("errorPayloadBytes=" & $outcome.error.count('e') & "\n")
  writeFile(resultPath, report)

proc reportField(report: string; key: string): string =
  for line in report.splitLines():
    let separator = line.find('=')
    if separator > 0 and line[0 ..< separator] == key:
      return line[separator + 1 .. ^1]
  ""

proc waitBounded(process: Process; seconds: int): int =
  ## The child's exit code, or -1 if it was still running at the deadline.
  let deadline = epochTime() + float(seconds)
  while epochTime() < deadline:
    let code = process.peekExitCode()
    if code != -1:
      return code
    sleep(25)
  -1

# The child role must be dispatched before `unittest` takes over the process.
if paramCount() >= 3 and paramStr(1) == ChildFlag:
  runFloodChild(paramStr(2), paramStr(3))
  quit(0)

suite "sqlite_cli stream backpressure":
  test "stderr past the pipe buffer neither deadlocks nor is lost":
    when defined(windows):
      skip()
    else:
      let work = createTempDir("runquota_sqlite_backpressure_", "")
      defer: removeDir(work)
      let dbPath = work / "store.db"
      let resultPath = work / "result.txt"

      let child = startProcess(
        getAppFilename(),
        args = [ChildFlag, dbPath, resultPath],
        options = {poParentStreams}
      )
      let code = waitBounded(child, ChildDeadlineSeconds)
      if code == -1:
        kill(child)
        discard child.waitForExit()
        child.close()
        checkpoint(
          "runSqlite did not return within " & $ChildDeadlineSeconds &
          "s. The child filled the " & $MeasuredPipeCapacityBytes &
          "-byte stderr pipe and blocked in write(2) while the parent " &
          "blocked in read(2) draining stdout to EOF.")
        fail()
      else:
        child.close()
        check code == 0
        check fileExists(resultPath)
        let report = readFile(resultPath)

        # The call has to have succeeded, not merely returned.
        check report.reportField("ok") == "true"
        check report.reportField("exit") == "0"

        # stdout is still delivered whole: the row before the flood and the
        # row after it. The trailing row is the one an ordering fix that
        # simply read stderr first would lose.
        check report.reportField("head") == "true"
        check report.reportField("tail") == "true"

        # stderr is still available for diagnostics, in full. This is also
        # what keeps the test non-vacuous: had `.output /dev/stderr` quietly
        # failed to route anything to the stderr pipe, the child would never
        # have filled it and the assertion below would fail rather than let a
        # deadlock-prone implementation pass.
        let errorBytes = report.reportField("errorBytes").parseInt()
        check errorBytes > 4 * MeasuredPipeCapacityBytes
        check report.reportField("errorPayloadBytes").parseInt() ==
          StderrRows * StderrPayloadBytes

        # stderr must not have been merged into stdout.
        check report.reportField("outputBytes").parseInt() <
          MeasuredPipeCapacityBytes
