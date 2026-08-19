## The background writer: the path the daemon's lease-finish handler
## actually takes.
##
## Two properties are load-bearing and were both broken at some point while
## this milestone was being written, which is why they are asserted rather
## than assumed:
##
## * A drained batch is written WHOLE, however large. Statements used to be
##   passed to `sqlite3` as an argument, so a batch above the operating
##   system's argument limit failed as a unit while a small one succeeded.
##   Every row was counted as dropped and nothing else noticed.
## * A store that is not open makes the writer inactive, and an enqueue
##   against an inactive writer is a counted no-op rather than an error
##   (OS-4).
##
## The writer is a process-wide singleton, like the learned-estimate writer
## beside it, so these tests start and stop it in sequence within one file.

import std/[os, strutils, times, unittest]

import runquota_observation_store

proc scratchDir(name: string): string =
  result = getTempDir() / ("runquota-obs-w-" & name & "-" &
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

proc execution(i: int): ExecutionRow =
  ExecutionRow(executionId: "e" & $i, hostId: "h1", runId: "r1",
    commandStatsId: "c" & $i, startedAtUnixMillis: 10,
    finishedAtUnixMillis: 20, durationMillis: 10, exitStatus: 0,
    termination: tExited, attempt: 1, peakRssBytes: 1, maxProcesses: 1,
    majorPageFaults: 0, captureCompleteness: ccComplete)

suite "observation_store_writer":
  test "a batch far larger than the argument limit is written whole":
    let dir = scratchDir("bigbatch")
    defer: removeDir(dir)
    let store = seededStore(dir)
    var rows: seq[ExecutionRow] = @[]
    for i in 0 ..< 6000:
      rows.add(execution(i))
    let statement = batchStatement([], rows)
    # Comfortably above a POSIX ARG_MAX of 1 MiB, which is what made the
    # argv-based implementation fail.
    check statement.len > 1_500_000
    let outcome = appendBatchAt(store.path, [], rows)
    check outcome.ok
    check outcome.error.strip() == ""
    check store.readExecutions().len == 6000

  test "enqueued rows reach the database and none are dropped":
    let dir = scratchDir("drain")
    defer: removeDir(dir)
    let store = seededStore(dir)
    startObservationWriter(store.path, 8192)
    check observationWriterActive()
    for i in 0 ..< 2000:
      check enqueueExecutionRow(execution(i))
    stopObservationWriter()
    check observationsDropped() == 0
    check observationsWritten() == 2000
    check store.readExecutions().len == 2000

  test "a full queue drops and counts rather than blocking":
    let dir = scratchDir("bounded")
    defer: removeDir(dir)
    let store = seededStore(dir)
    # A capacity of one with the drain paused by sheer volume: some rows
    # must be refused, and every refusal must be counted.
    startObservationWriter(store.path, 4)
    var accepted = 0
    for i in 0 ..< 500:
      if enqueueExecutionRow(execution(i)):
        inc accepted
    let dropped = observationsDropped()
    stopObservationWriter()
    check accepted < 500
    check dropped > 0
    check accepted + int(dropped) == 500

  test "a degraded store leaves the writer inactive and enqueues counted":
    let dir = scratchDir("degraded")
    defer: removeDir(dir)
    # The daemon starts the writer only for a store that opened; this is
    # that case expressed directly.
    startObservationWriter("", 1024)
    check not observationWriterActive()
    check not enqueueExecutionRow(execution(1))
    check not enqueueRunRow(RunRow(runId: "r", hostId: "h", tool: "t",
      toolVersion: "1", invocationKind: "build", startedAtUnixMillis: 1,
      captureCompleteness: ccComplete))
    check observationsDropped() == 2
    stopObservationWriter()
