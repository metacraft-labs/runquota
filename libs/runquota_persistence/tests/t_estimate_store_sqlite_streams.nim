## The estimate store's ``sqlite3`` call must not wedge on its own child.
##
## ``runSqlite`` was ``execProcess("sqlite3", args = [path, sqlText], options =
## {poUsePath})``. The explicit ``options`` is the defect. ``execProcess``'s
## body loops on ``outputStream`` and reads no other stream; its *default*
## options include ``poStdErrToStdOut``, which folds stderr into the stream it
## does read. Passing ``options`` explicitly replaces that default wholesale,
## so stderr gets a pipe of its own that nobody will ever read. A pipe holds a
## bounded amount before a write to it blocks -- 65_536 bytes as measured on
## the development host -- so a ``sqlite3`` with more than that to say on
## stderr blocks in ``write(2)``, never exits, and ``execProcess``'s loop,
## which only breaks when the child stops running, spins forever.
##
## That this is reachable and not hypothetical: ``writeBatch`` passes a whole
## batch of ``insert``s as ONE argv argument, ~800 bytes per queued row, and
## ``sqlite3`` echoes the statement text back when it cannot prepare it. The
## size of the diagnostic tracks the size of the batch. The call runs on the
## estimate store's writer thread, which ``stopEstimateStore`` joins.
##
## The first test establishes that the flood is real before it asserts that
## ``runSqlite`` survives it -- a deadlock test whose child quietly wrote
## nothing to stderr would pass against the defect it is supposed to catch.
##
## Structure, as in the other deadlock regression tests: a wedged call cannot
## report its own failure, so the work runs in a re-executed child that the
## parent waits on with a bounded deadline, turning a hang into a red result.
##
## No mocks: the production helper spawns the production ``sqlite3``.

import std/[os, osproc, strutils, tempfiles, unittest]

import runquota_core/child_process
import runquota_persistence

import ../../../tests/support/child_watchdog

const
  FloodFlag = "--estimate-sqlite-flood-child"

  ## A single statement `sqlite3` cannot prepare. It echoes the offending text
  ## back on stderr, so the diagnostic is as long as the statement: 300_000
  ## bytes is more than 4x the measured pipe capacity, which keeps the test
  ## honest on a host whose pipes are somewhat larger than this one's.
  MalformedStatementBytes = 300_000
  MeasuredPipeCapacityBytes = 65_536

  ChildDeadlineSeconds = 60
  SurvivorGraceSeconds = 10

proc malformedSql(): string =
  ## `select <300_000 identifier characters>;` -- one statement, unparseable
  ## because the identifier does not resolve, and `sqlite3` quotes the whole
  ## thing back at the caller.
  "select " & repeat('x', MalformedStatementBytes) & ";"

proc runFloodChild(dbPath, resultPath: string) =
  ## The half that deadlocks against the unfixed `runSqlite`.
  ##
  ## The direct `runCapturedProcess` call is not the subject; it is the control
  ## that proves this SQL really does put more than a pipe holds on stderr. It
  ## runs FIRST so that a run in which the flood failed to materialise reports
  ## a small `stderrBytes` rather than a green deadlock test.
  let control = runCapturedProcess(
    "sqlite3", args = [dbPath, malformedSql()], options = {poUsePath})
  let output = runSqlite(dbPath, malformedSql())

  var report = ""
  report.add("stderrBytes=" & $control.error.len & "\n")
  report.add("controlExit=" & $control.exitCode & "\n")
  report.add("outputBytes=" & $output.len & "\n")
  writeFile(resultPath, report)

proc reportField(report: string; key: string): string =
  for line in report.splitLines():
    let separator = line.find('=')
    if separator > 0 and line[0 ..< separator] == key:
      return line[separator + 1 .. ^1]
  ""

# The child role must be dispatched before `unittest` takes over the process.
if paramCount() >= 3 and paramStr(1) == FloodFlag:
  runFloodChild(paramStr(2), paramStr(3))
  quit(0)

suite "estimate store sqlite streams":
  test "a diagnostic past the pipe buffer neither wedges nor reaches stdout":
    when defined(windows):
      skip()
    else:
      let work = createTempDir("runquota_estimate_streams_", "")
      defer: removeDir(work)
      let dbPath = work / "estimates.db"
      let resultPath = work / "result.txt"

      let child = startSupervisedChild(
        getAppFilename(), [FloodFlag, dbPath, resultPath])
      let code = waitBounded(child, ChildDeadlineSeconds)
      if code == -1:
        # The blocked `sqlite3` is a grandchild; signalling only `child` can
        # strand it on pid 1.
        killProcessTree(child)
        child.close()
        checkpoint(
          "runSqlite did not return within " & $ChildDeadlineSeconds &
          "s. sqlite3 filled the " & $MeasuredPipeCapacityBytes &
          "-byte stderr pipe and blocked in write(2) while execProcess " &
          "looped on stdout waiting for a child that can no longer exit.")
        fail()
      else:
        child.close()
        check code == 0
        check fileExists(resultPath)
        let report = readFile(resultPath)

        # The control: this SQL really does flood stderr, and really does fail.
        # Without these two the deadlock assertion above would be vacuous.
        check report.reportField("stderrBytes").parseInt() >
          4 * MeasuredPipeCapacityBytes
        check report.reportField("controlExit").parseInt() != 0

        # And none of it came back as an estimate. Every caller of `runSqlite`
        # parses its return value as rows, so a diagnostic folded into that
        # stream would be read as data -- which is what merely adding
        # `poStdErrToStdOut` would have done.
        check report.reportField("outputBytes").parseInt() == 0

      # Asserted on both paths: a run that wedges `sqlite3` and then walks away
      # leaves processes that outlive the suite entirely.
      let survivors = awaitNoSurvivors(work, SurvivorGraceSeconds)
      if survivors.len > 0:
        checkpoint("processes still alive after the test: " &
          survivors.join("; "))
      check survivors.len == 0
