## `flushObservationWriter` must mean "every row queued before this call is
## committed", not "the queue was empty when I looked".
##
## THE DEFECT THIS EXISTS FOR. `drainOnce` swaps the queues under
## `writerLock` and then spawns `sqlite3` OUTSIDE it. That is deliberate and
## must stay that way: holding the lock across the spawn would put every
## connection worker's `enqueueRunRow` behind a 25-40 ms batch, which is the
## hot-path perturbation OS-1 forbids and the one M13b was spent removing.
## The consequence is a window, as long as the spawn, in which the queue is
## EMPTY and the rows are UNWRITTEN, and a second drainer arriving in it
## found nothing and returned.
##
## `publishDirtyAggregates` is that second drainer. Its own comment -- "one
## drain writes every queued row, so a second would find nothing" -- assumed
## it was the only one; the writer's own thread is the other. The aggregate
## was then computed over a row that had not committed, and the wrong figure
## was PERMANENT rather than late: `waitForPublished` returns on the first
## `stlHit`, the key is consumed by the drain that published it, and nothing
## re-dirties it, so the 10 s budget cannot rescue it. `statsAnswer` has the
## same exposure on the READ path, where the caller is a client that has just
## asked a question and would be told its own execution never happened.
##
## A real SQLite connection holds BEGIN IMMEDIATE while two callers flush.
## Both calls must remain pending until that transaction releases its lock,
## then each must see all accepted rows before either thread is joined.
## No mocks: the barrier is a real database writer lock, not an assumed
## minimum duration for a large batch on a particular disk.

import std/[atomics, monotimes, options, os, osproc, streams, strutils, tempfiles, times, unittest]

import runquota_observation_store

const
  Rows = 32
  PaddingBytes = 64
  BarrierWindowMillis = 200
  SmallCapacity = 16

type DrainReport = object
  done: Atomic[bool]
  flushMillis: int64

proc paddingFor(index: int): string =
  "row-" & $index & "-" & repeat('p', PaddingBytes + index)

proc runRowFor(index: int): RunRow =
  RunRow(
    runId: "run-" & $index,
    hostId: "host-0",
    tool: paddingFor(index),
    toolVersion: "0.0.1",
    invocationKind: "build",
    startedAtUnixMillis: 1,
    captureCompleteness: ccComplete)

proc executionRowFor(index: int): ExecutionRow =
  ExecutionRow(
    executionId: "exec-" & $index,
    hostId: "host-0",
    runId: "run-" & $index,
    commandStatsId: "stats-" & $index,
    retryOf: some(paddingFor(index)),
    startedAtUnixMillis: 1,
    finishedAtUnixMillis: 2,
    durationMillis: 1,
    exitStatus: 0,
    termination: tExited,
    attempt: 1,
    peakRssBytes: 1024,
    maxProcesses: 1,
    majorPageFaults: 0,
    captureCompleteness: ccComplete)

proc inFlightDrain(report: ptr DrainReport) {.thread.} =
  {.cast(gcsafe).}:
    let started = getMonoTime()
    flushObservationWriter()
    report.flushMillis = (getMonoTime() - started).inMilliseconds
    report.done.store(true, moRelease)

suite "observation flush contract":

  test "a flush waits for a drain already in flight on another thread":
    let dir = createTempDir("runquota_flush_contract_", "")
    defer: removeDir(dir)
    let path = dir / "observations.sqlite3"
    let store = openObservationStore(path)
    check store.captureEnabled
    check store.ensureHostRow("host-0", "boot-0")

    # Hold the database writer lock before accepting any rows. The SELECT
    # is acknowledged over a pipe only after BEGIN IMMEDIATE has succeeded.
    let blocker = startProcess("sqlite3",
      args = ["-batch", "-noheader", "-bail", path],
      options = {poUsePath, poStdErrToStdOut})
    defer: blocker.close()
    blocker.inputStream.write("BEGIN IMMEDIATE; SELECT 'locked';\n")
    blocker.inputStream.flush()
    require blocker.outputStream.readLine() == "locked"

    var statements: seq[string] = @[]
    for i in 0 ..< Rows:
      statements.add(runInsertStatement(runRowFor(i)))
      statements.add(executionInsertStatement(executionRowFor(i)))

    startObservationWriter(path, capacity = statements.len * 2)
    check observationWriterActive()
    var accepted = 0
    for statement in statements:
      if enqueueExtensionInsert(statement):
        accepted += 1
    check accepted == statements.len

    let flushesBefore = observationWriterFlushes()
    var reports: array[2, DrainReport]
    var threads: array[2, Thread[ptr DrainReport]]
    for i in 0 ..< threads.len:
      createThread(threads[i], inFlightDrain, addr reports[i])
    let deadline = getMonoTime() + initDuration(seconds = 2)
    while observationWriterFlushes() < flushesBefore + 2 and getMonoTime() < deadline:
      sleep(1)
    check observationWriterFlushes() >= flushesBefore + 2

    # Give both entered calls a scheduling window while the external writer
    # lock makes it impossible for the accepted rows to commit. A flush
    # that merely sees an empty queue would return during this window.
    sleep(BarrierWindowMillis)
    check observationsWritten() == 0'i64
    for report in reports.mitems:
      check not report.done.load(moAcquire)

    blocker.inputStream.write("COMMIT;\n.quit\n")
    blocker.inputStream.flush()
    blocker.inputStream.close()
    check blocker.waitForExit(5000) == 0
    for i in 0 ..< threads.len:
      let settledBy = getMonoTime() + initDuration(seconds = 10)
      while not reports[i].done.load(moAcquire) and getMonoTime() < settledBy:
        sleep(1)
      check reports[i].done.load(moAcquire)
      # Read before joining either thread. Joining cannot supply the wait
      # that the API itself promises to its caller.
      check openObservationStore(path).readExecutions().len == Rows
    for thread in threads.mitems: joinThread(thread)
    stopObservationWriter()

    check observationWriteFailures() == 0'i64
    check observationsWritten() == int64(statements.len)

  test "a flush returns when rows were refused rather than queued":
    # THE OTHER HALF OF A WAIT IS THAT IT ENDS. A flush waits for the rows
    # ACCEPTED into the queue; a row refused at the door was never one of
    # them and will never have an outcome recorded. If a refusal were
    # counted as queued this case would HANG rather than fail, which is why
    # it is here and why it is small.
    let dir = createTempDir("runquota_flush_refusals_", "")
    defer: removeDir(dir)
    let path = dir / "observations.sqlite3"
    let store = openObservationStore(path)
    check store.captureEnabled
    check store.ensureHostRow("host-0", "boot-0")

    startObservationWriter(path, capacity = SmallCapacity)
    check observationWriterActive()
    for i in 0 ..< SmallCapacity * 4:
      discard enqueueRunRow(runRowFor(i))

    let started = getMonoTime()
    flushObservationWriter()
    let elapsed = (getMonoTime() - started).inMilliseconds
    echo "  flush over an overflowing queue returned in ", elapsed,
      " ms; dropped=", observationsDropped(), " written=",
      observationsWritten()
    check observationsDropped() > 0'i64
    check observationsWritten() > 0'i64
    stopObservationWriter()

  test "an inactive writer's flush is a no-op and does not wait":
    # `startObservationWriter("")` is how a disabled or degraded store is
    # represented. A flush against it must return rather than park on a
    # counter nothing will ever advance.
    startObservationWriter("")
    check not observationWriterActive()
    let started = getMonoTime()
    flushObservationWriter()
    check (getMonoTime() - started).inMilliseconds < 1000'i64
