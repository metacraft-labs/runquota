## The estimate store's ``sqlite3`` call must reach its child, must not wedge
## on it, and must not lose a batch quietly when something goes wrong.
##
## TWO DEFECTS, ONE CALL SITE.
##
## THE TRANSPORT. ``writeBatch`` builds one ``insert`` per queued row -- about
## 800 bytes each -- and ``runSqlite`` handed the whole batch to ``execve`` as
## a SINGLE argv element. Linux caps one argument at ``MAX_ARG_STRLEN``,
## 131_072 bytes, independently of the much larger total-argv limit: measured
## on the development host, an argument of 131_071 bytes spawns and one of
## 131_072 fails with ``E2BIG``. A batch past roughly 160 rows therefore never
## reached ``sqlite3`` at all while a shorter one committed -- and macOS,
## which has no per-argument cap, never saw it. The statements now go in over
## stdin, which is what ``runquota_observation_store/sqlite_cli`` had already
## had to do for the same reason.
##
## THE DIAGNOSTIC. ``runSqlite`` was ``execProcess("sqlite3", args = [path,
## sqlText], options = {poUsePath})``. The explicit ``options`` is that
## defect. ``execProcess``'s body loops on ``outputStream`` and reads no other
## stream; its *default* options include ``poStdErrToStdOut``, which folds
## stderr into the stream it does read. Passing ``options`` explicitly replaces
## that default wholesale, so stderr gets a pipe of its own that nobody will
## ever read. A pipe holds a bounded amount before a write to it blocks --
## 65_536 bytes as measured on the development host -- so a ``sqlite3`` with
## more than that to say on stderr blocks in ``write(2)``, never exits, and
## ``execProcess``'s loop, which only breaks when the child stops running,
## spins forever. The call runs on the estimate store's writer thread, which
## ``stopEstimateStore`` joins.
##
## WHY THE FIRST TEST IS WRITTEN THE WAY IT IS. Its deadlock clause is only
## worth anything if the flood is real, so the control measures the flood
## through the SAME transport production uses and the test asserts the size it
## measured. That assertion used to be unsatisfiable by construction: the
## control drove 300_000 bytes of SQL through *argv*, which Linux refuses
## outright, so ``sqlite3`` never ran, ``stderrBytes`` was 0, and the clause it
## guards was vacuous on the only platform where the deadlock is reachable.
## With the transport corrected the statement arrives, ``sqlite3`` quotes the
## unparseable text back, and the flood is a measured 300_148 bytes against a
## 65_536-byte pipe.
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

  ## Linux's `MAX_ARG_STRLEN`: the cap on ONE argv element, distinct from the
  ## much larger cap on the whole argument block. Measured on the development
  ## host with a bare `execv`: 131_071 bytes spawns, 131_072 fails with
  ## `E2BIG`. Named here because two tests below are about being on the far
  ## side of it, and a test that drifted under it would pass without
  ## exercising anything.
  ArgumentLimitBytes = 131_072

  ## Enough `insert`s to put the batch well past that limit -- ~800 bytes of
  ## SQL per row, so 400 rows is roughly 2.4x it. The test asserts the size it
  ## actually built rather than trusting this arithmetic.
  OversizedBatchRows = 400

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
  ## The direct `runSqlite` call above the subject is not a second subject: the
  ## FIRST call is the control that proves this SQL really does put more than a
  ## pipe holds on stderr, and it is only able to prove that because it now
  ## reaches `sqlite3` the way production does. It runs first so that a run in
  ## which the flood failed to materialise reports a small `stderrBytes` rather
  ## than a green deadlock test.
  let control = runCapturedProcess(
    "sqlite3",
    args = ["-batch", "-noheader", "-bail", dbPath],
    input = malformedSql() & "\n",
    options = {poUsePath})
  let run = runSqlite(dbPath, malformedSql())

  var report = ""
  report.add("stderrBytes=" & $control.error.len & "\n")
  report.add("controlExit=" & $control.exitCode & "\n")
  report.add("controlFailure=" & $control.failure.len & "\n")
  report.add("outputBytes=" & $run.output.len & "\n")
  report.add("ok=" & $run.ok & "\n")
  report.add("failureBytes=" & $run.failure.len & "\n")
  writeFile(resultPath, report)

proc reportField(report: string; key: string): string =
  for line in report.splitLines():
    let separator = line.find('=')
    if separator > 0 and line[0 ..< separator] == key:
      return line[separator + 1 .. ^1]
  ""

proc oversizedBatchSql(rows: int): string =
  ## `rows` inserts into a table of this test's own, shaped like the estimate
  ## writer's batch -- one transaction, one statement per row -- and padded so
  ## a row costs what a learned estimate costs.
  result = "create table if not exists probe (id integer primary key, " &
    "payload text not null);\nbegin immediate;\n"
  for i in 0 ..< rows:
    result.add("insert into probe (id, payload) values (" & $i & ",'" &
      repeat('p', 700) & "');\n")
  result.add("commit;\n")

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

        # THE CONTROL, and what it now pins. `sqlite3` really was reached --
        # `controlFailure` is the length of `runCapturedProcess`'s "could not
        # run it at all" reason, and an argv-borne 300_000-byte statement puts
        # `E2BIG` there and 0 in `stderrBytes`. Given it was reached, it really
        # did put more than four pipefuls on stderr. Without both of these the
        # deadlock assertion above would be vacuous, and before the transport
        # was corrected the second one could not be satisfied on Linux at all.
        check report.reportField("controlFailure").parseInt() == 0
        check report.reportField("stderrBytes").parseInt() >
          4 * MeasuredPipeCapacityBytes
        check report.reportField("controlExit").parseInt() != 0

        # And none of it came back as an estimate. Every caller of `runSqlite`
        # parses `output` as rows, so a diagnostic folded into that stream
        # would be read as data -- which is what merely adding
        # `poStdErrToStdOut` would have done.
        check report.reportField("outputBytes").parseInt() == 0

        # THE FAILURE IS REPORTED, not swallowed. `sqlite3` ran and rejected
        # the statement, so `ok` is false and `failure` -- which is only for a
        # tool that could not be run at all -- is empty. `runSqlite` used to
        # return a bare stdout string, in which those two outcomes and a clean
        # commit were the same value.
        check report.reportField("ok") == "false"
        check report.reportField("failureBytes").parseInt() == 0

      # Asserted on both paths: a run that wedges `sqlite3` and then walks away
      # leaves processes that outlive the suite entirely.
      let survivors = awaitNoSurvivors(work, SurvivorGraceSeconds)
      if survivors.len > 0:
        checkpoint("processes still alive after the test: " &
          survivors.join("; "))
      check survivors.len == 0

  test "a batch past the argument limit reaches sqlite3 and commits":
    ## THE SIZE-DEPENDENT FAILURE, pinned at the size. A batch under
    ## `MAX_ARG_STRLEN` committed and one over it vanished, so this test is
    ## only meaningful while the batch it builds is over the limit -- which is
    ## asserted rather than assumed.
    let work = createTempDir("runquota_estimate_argv_", "")
    defer: removeDir(work)
    let dbPath = work / "estimates.db"

    let sqlText = oversizedBatchSql(OversizedBatchRows)
    check sqlText.len > ArgumentLimitBytes

    let write = runSqlite(dbPath, sqlText)
    check write.failure.len == 0
    check write.ok

    let readBack = runSqlite(dbPath, "select count(*) from probe;")
    check readBack.ok
    check readBack.output.strip() == $OversizedBatchRows

  test "a batch the store cannot commit is counted, not discarded":
    ## `writeBatch`'s result used to be `discard`ed, so a batch that never ran
    ## was indistinguishable from one that committed. The store is pointed at a
    ## file that is not a database, which `sqlite3` refuses; the enqueued row
    ## therefore cannot land, and the point is that the store SAYS SO instead
    ## of returning to the caller as though it had.
    let work = createTempDir("runquota_estimate_failure_", "")
    defer: removeDir(work)
    let dbPath = work / "not-a-database.db"
    writeFile(dbPath, repeat('Z', 4096))

    let before = estimateWriteFailures()
    let store = startEstimateStore(dbPath, queueCapacity = 8)
    check enqueueEstimateWrite(store, LearnedEstimateRow(
      scope: "probe",
      commandStatsId: "probe-command",
      conservativeMemoryBytes: 1024'u64,
      recentPeakMemoryBytes: 2048'u64,
      sampleCount: 1'u32,
      lastOutcome: 0'u32,
      updatedUnixMillis: nowUnixMillis()))
    # `stopEstimateStore` joins the writer thread, so by the time it returns
    # the drain either committed or was counted. No sleep is needed and none
    # would be sound: a sleep would be asserting on a schedule.
    stopEstimateStore(store)

    check estimateWriteFailures() > before
    check estimateWriteFailedRows() > 0'u64
    check loadLearnedEstimates(dbPath).len == 0
