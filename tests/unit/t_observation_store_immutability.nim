## M9 gate, clause 3, and OS-3: an attempt to update a written execution
## row fails.
##
## The assertion is made at the SQL level rather than through the library's
## API, because "the API offers no update proc" is not the property that
## matters. Idempotent merge, safe concurrent readers and append-only
## retention all depend on the row being immutable against ANY writer,
## including a person with `sqlite3` and the file path. The `before update`
## trigger is what makes that true, so the test attacks the database
## directly.

import std/[os, strutils, times, unittest]

import runquota_observation_store

proc scratchDir(name: string): string =
  result = getTempDir() / ("runquota-obs-" & name & "-" &
    $getCurrentProcessId() & "-" & $epochTime())
  removeDir(result)
  createDir(result)

proc seededStore(dir: string): ObservationStore =
  result = openObservationStore(dir / "observations.sqlite")
  doAssert result.captureEnabled, result.report
  doAssert result.insertHost(HostRow(hostId: "h1", createdAtUnixMillis: 1,
    lastBootId: "b1"))
  doAssert result.insertRun(RunRow(runId: "r1", hostId: "h1", tool: "tool",
    toolVersion: "1", invocationKind: "build", startedAtUnixMillis: 1,
    captureCompleteness: ccComplete))
  doAssert result.insertExecution(ExecutionRow(executionId: "e1",
    hostId: "h1", runId: "r1", commandStatsId: "c1",
    startedAtUnixMillis: 10, finishedAtUnixMillis: 20, durationMillis: 10,
    exitStatus: 0, termination: tExited, attempt: 1, peakRssBytes: 1234,
    maxProcesses: 2, majorPageFaults: 0, captureCompleteness: ccComplete))

suite "observation_store_immutability":
  test "updating a written execution row fails and changes nothing":
    let dir = scratchDir("immutable")
    defer: removeDir(dir)
    let store = seededStore(dir)
    let path = store.path

    let update = runSqlite(path,
      "update executions set exit_status = 99 where execution_id = 'e1';")
    check not update.ok
    check "immutable" in update.error

    let after = store.readExecutions()
    check after.len == 1
    check after[0].exitStatus == 0
    check after[0].peakRssBytes == 1234

  test "the abort names the row, the rule and the invariant":
    let dir = scratchDir("message")
    defer: removeDir(dir)
    let store = seededStore(dir)
    let update = runSqlite(store.path,
      "update executions set peak_rss_bytes = 0;")
    check not update.ok
    check "executions" in update.error
    check "OS-3" in update.error

  test "an update inside a transaction is rolled back whole":
    let dir = scratchDir("txn")
    defer: removeDir(dir)
    let store = seededStore(dir)
    let attempt = runSqlite(store.path, """
      begin immediate;
      insert into executions (
        execution_id, host_id, run_id, command_stats_id,
        started_at_unix_millis, finished_at_unix_millis, duration_millis,
        exit_status, termination, attempt, peak_rss_bytes, max_processes,
        major_page_faults, capture_completeness, dropped_observations
      ) values (
        'e2', 'h1', 'r1', 'c2', 30, 40, 10, 0, 'exited', 1, 1, 1, 0,
        'complete', 0);
      update executions set exit_status = 7 where execution_id = 'e1';
      commit;
    """)
    check not attempt.ok
    # The aborted statement takes the whole transaction with it, so the
    # companion insert is not left behind either.
    let executions = store.readExecutions()
    check executions.len == 1
    check executions[0].executionId == "e1"

  test "deletion stays possible, because retention has to prune":
    # Immutability is about the CONTENT of a row, not its existence.
    # Append-only retention (M15) deletes whole rows and cascades to
    # extension tables; a trigger that blocked deletes would make the
    # store unbounded.
    let dir = scratchDir("delete")
    defer: removeDir(dir)
    let store = seededStore(dir)
    let deletion = runSqlite(store.path,
      "delete from executions where execution_id = 'e1';")
    check deletion.ok
    check store.readExecutions().len == 0

  test "the trigger is part of the schema, not of the library":
    let dir = scratchDir("trigger")
    defer: removeDir(dir)
    let store = seededStore(dir)
    let triggers = runSqlite(store.path,
      "select name from sqlite_master where type = 'trigger' " &
        "and tbl_name = 'executions';")
    check triggers.ok
    check "executions_immutable" in triggers.output
