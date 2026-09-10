## The observation writer's queue must outlive the connection workers that
## fill it.
##
## THE DEFECT THIS EXISTS FOR. `captureObservation` and the completion path
## call `enqueueRunRow`, `enqueueExecutionRow` and `enqueueExtensionInsert`
## on a CONNECTION WORKER. The queue is drained by `drainOnce`, which runs on
## the writer's own thread, on the aggregate publisher's thread through
## `flushObservationWriter`, and on whichever thread asks a question. `serve`
## joins the connection workers first and stops the writer last, so a row
## still queued when the workers go away is freed by a thread that did not
## allocate it, after the thread that did has ceased to exist.
##
## WHY IT IS AN OWNERSHIP BUG AND NOT A RACE, and why the producer count is
## what it is, is set out at length in
## `libs/runquota_daemon/tests/t_publication_queue_ownership.nim`: under ORC
## every chunk records the region that owns it, `addToSharedFreeList*`
## dereferences that pointer, and the region lives in the thread's TLS. The
## producer count pushes glibc's 40 MiB thread-stack cache past its ceiling
## so the dead regions are `munmap`ped rather than recycled, which is what
## makes the foreign free a SIGSEGV instead of silent corruption.
##
## THE DRAIN IS TAKEN ON THE MAIN THREAD, deliberately: `flushObservationWriter`
## is the shape the publisher and the read path both use, and running it here
## puts the free on a thread that provably did not allocate the rows.

import std/[options, os, strutils, tempfiles, unittest]

import runquota_observation_store
import runquota_observation_store/writer

const
  Producers = 64
  PerProducer = 4
  TextBaseBytes = 5000
    ## Past `SmallChunkSize`, so a row carries at least one big chunk.
  Rounds = 2

type Producer = object
  id: int

proc paddingFor(producer, index: int): string =
  "p-" & $producer & "-" & $index & "-" &
    repeat('t', TextBaseBytes + producer * PerProducer + index)

proc fillQueue(state: ptr Producer) {.thread.} =
  {.cast(gcsafe).}:
    for i in 0 ..< PerProducer:
      let padding = paddingFor(state.id, i)
      discard enqueueRunRow(RunRow(
        runId: "run-" & $state.id & "-" & $i,
        hostId: "host-0",
        tool: padding,
        toolVersion: "0.0.1",
        invocationKind: "build",
        startedAtUnixMillis: 1,
        captureCompleteness: ccComplete))
      discard enqueueExecutionRow(ExecutionRow(
        executionId: "exec-" & $state.id & "-" & $i,
        hostId: "host-0",
        runId: "run-" & $state.id & "-" & $i,
        commandStatsId: "stats-" & $state.id & "-" & $i,
        retryOf: some(padding),
        startedAtUnixMillis: 1,
        finishedAtUnixMillis: 2,
        durationMillis: 1,
        exitStatus: 0,
        termination: tExited,
        attempt: 1,
        peakRssBytes: 1024,
        maxProcesses: 1,
        majorPageFaults: 0,
        captureCompleteness: ccComplete))

var
  producers: array[Producers, Producer]
  producerThreads: array[Producers, Thread[ptr Producer]]

suite "observation writer ownership":
  test "rows queued by threads that have exited are drained without crashing":
    let dir = createTempDir("runquota_writer_ownership_", "")
    defer: removeDir(dir)
    for round in 0 ..< Rounds:
      let path = dir / ("observations-" & $round & ".sqlite3")
      let store = openObservationStore(path)
      check store.captureEnabled
      check store.ensureHostRow("host-0", "boot-0")
      startObservationWriter(path,
        capacity = Producers * PerProducer * 4)
      check observationWriterActive()

      for i in 0 ..< Producers:
        producers[i] = Producer(id: i)
        createThread(producerThreads[i], fillQueue, addr producers[i])
      for i in 0 ..< Producers:
        joinThread(producerThreads[i])

      # EVERY PRODUCER IS GONE BY THIS LINE. The drain below therefore frees
      # only rows some other thread allocated.
      flushObservationWriter()
      stopObservationWriter()
      echo "  round ", round, ": written=", observationsWritten(),
        " dropped=", observationsDropped(),
        " failures=", observationWriteFailures()

    # THE ROWS REALLY LANDED, so that "it did not crash" cannot be satisfied
    # by a queue that dropped everything.
    let last = openObservationStore(dir / ("observations-" & $(Rounds - 1) &
      ".sqlite3"))
    check last.readExecutions().len == Producers * PerProducer
    check observationWriteFailures() == 0'i64
