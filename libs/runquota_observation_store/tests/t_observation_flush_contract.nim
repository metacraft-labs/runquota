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
## HOW THIS TEST MAKES IT DETERMINISTIC. It does not race the writer
## thread's 25 ms tick; it arranges both drainers itself.
##
##  * The statements are composed BEFORE the writer exists, so filling the
##    queue is one lock and one memcpy per row and fits inside `writerMain`'s
##    FIRST sleep -- it sleeps 25 ms before its first pass -- and the batch
##    is therefore taken by one drain rather than split across two.
##  * A second thread enters `flushObservationWriter` and the main thread
##    waits for `observationWriterFlushes()` to show that it did, so the
##    handoff is a condition rather than a guess, and only then sleeps
##    `HandoffDelayMillis` to let the queue swap happen.
##  * TWO CLAUSES REFUSE A VACUOUS RUN. `observationsWritten()` sampled the
##    instant before the flush under test must be ZERO -- nothing had
##    reached the database yet -- and the other thread's flush must have
##    lasted longer than the handoff, which is what proves IT was the one
##    holding the rows. A run where the window was shut fails on those
##    clauses instead of passing while measuring nothing.

import std/[monotimes, options, os, strutils, tempfiles, times, unittest]

import runquota_observation_store

const
  Rows = 1200
    ## Two statements each. With `PaddingBytes` hex-encoded on the way to
    ## `sqlite3` this is a batch of several megabytes, which takes far
    ## longer to write than `HandoffDelayMillis`.
  PaddingBytes = 1024
  HandoffDelayMillis = 25
    ## What the main thread waits after the other thread has entered its
    ## flush. It has to outlast a queue swap -- a lock and 2400 pointer
    ## moves -- and be dwarfed by the batch write that follows it.
  MinimumWindowMillis = 100'i64
    ## The margin below which this file declines to claim it measured
    ## anything; see the head of the module.
  SmallCapacity = 16

type DrainReport = object
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
  ## THE PASS THAT IS STILL IN FLIGHT when the main thread flushes. It is a
  ## `flushObservationWriter` and not the writer thread only because this
  ## way the window opens when the test says so; both reach the same
  ## `drainOnce`, and the writer thread is welcome to take part of the
  ## batch as well -- that only widens what the main thread must wait for.
  {.cast(gcsafe).}:
    let started = getMonoTime()
    flushObservationWriter()
    report.flushMillis = (getMonoTime() - started).inMilliseconds

var report: DrainReport
var drainThread: Thread[ptr DrainReport]

suite "observation flush contract":

  test "a flush waits for a drain already in flight on another thread":
    let dir = createTempDir("runquota_flush_contract_", "")
    defer: removeDir(dir)
    let path = dir / "observations.sqlite3"
    let store = openObservationStore(path)
    check store.captureEnabled
    check store.ensureHostRow("host-0", "boot-0")

    # COMPOSED BEFORE THE WRITER EXISTS. `enqueueExtensionInsert` takes an
    # already-composed statement and the queues hold BYTES, so these go in
    # at memcpy speed. They are the same bytes `enqueueRunRow` and
    # `enqueueExecutionRow` would have produced, in the order `drainOnce`
    # emits -- each run immediately before the execution whose foreign key
    # names it.
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
    report = DrainReport(flushMillis: 0)
    createThread(drainThread, inFlightDrain, addr report)
    # THE HANDOFF IS A CONDITION, NOT A GUESS: the counter is incremented
    # inside `flushObservationWriter` before it drains, so once it moves the
    # other thread is in the flush and about to take the queue.
    var handoffWait = 0
    while observationWriterFlushes() == flushesBefore and handoffWait < 2000:
      sleep(1)
      handoffWait += 1
    check observationWriterFlushes() > flushesBefore
    sleep(HandoffDelayMillis)

    # NOTHING HAS REACHED THE DATABASE YET. Sampled the instant before the
    # flush under test, this is what says the window really is open: the
    # rows exist only inside a `sqlite3` that has not committed.
    let writtenBeforeFlush = observationsWritten()

    let mainStarted = getMonoTime()
    flushObservationWriter()
    let mainMillis = (getMonoTime() - mainStarted).inMilliseconds

    # READ BACK BEFORE THE JOIN, so that joining the other thread cannot be
    # what makes the rows appear. This is the contract, whole.
    let readBack = openObservationStore(path).readExecutions().len

    joinThread(drainThread)
    echo "  in-flight drain took ", report.flushMillis, " ms; the flush ",
      "under test waited ", mainMillis, " ms; written before it: ",
      writtenBeforeFlush, "; read back ", readBack, " of ", Rows
    stopObservationWriter()

    check writtenBeforeFlush == 0'i64
    check report.flushMillis >= MinimumWindowMillis
    check readBack == Rows
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
