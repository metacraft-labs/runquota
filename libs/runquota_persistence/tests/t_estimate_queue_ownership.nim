## The learned-estimate queue must outlive the connection workers that fill
## it.
##
## THE DEFECT THIS EXISTS FOR. `enqueueEstimateWrite` is reached from
## `updateEstimateFromFinish`, which `handleRequest` calls when a client
## reports a lease finished -- so the rows are allocated on a CONNECTION
## WORKER. They are freed by `writerMain`'s drain, and `serve` calls
## `stopEstimateStore` (which joins that writer) only after every connection
## worker has already been joined. A row still queued at that point was
## therefore freed on a thread that did not allocate it, after the thread
## that did had ceased to exist.
##
## An earlier report of this queue called the window unreachable. It is not:
## the drain runs on a 50 ms cadence and each pass spawns `sqlite3`, so
## anything reported in the last pass -- or while a pass is in flight -- is
## still queued when the workers go away.
##
## WHY IT IS AN OWNERSHIP BUG AND NOT A RACE, and why the numbers below are
## what they are, is set out at length in
## `libs/runquota_daemon/tests/t_publication_queue_ownership.nim`: under ORC
## every chunk records the region that owns it, `addToSharedFreeList*`
## dereferences that pointer, and the region dies with its thread. The
## producer count is chosen to push glibc's 40 MiB thread-stack cache over
## its ceiling so the dead regions are really `munmap`ped rather than merely
## recycled, which is what turns silent corruption into a SIGSEGV.
##
## NO `ref` CROSSES A THREAD BOUNDARY HERE, AND THAT IS DELIBERATE.
## `EstimateStore` is a `ref object` and ORC's reference counts are NOT
## atomic. Handing one handle to 64 threads works today for a reason that is
## a property of the CALL and not of this file: a non-`sink`, non-`var`
## parameter is a borrow, so `enqueueEstimateWrite(store, row)` performs no
## refcount traffic at all. One `let mine = state.store` inside the producer
## would put 64 threads on one non-atomic counter, in a file whose entire
## subject is what happens when a heap cell and its owning thread disagree,
## and nothing would say so. So each producer builds its own handle out of
## the three value fields that describe one: the queue it appends to is
## process-wide module state, and `enqueueEstimateWrite` reads `mode` and
## nothing else, so these are the same store by every meaning this test
## depends on.

import std/[os, strutils, tempfiles, unittest]

import runquota_persistence

const
  Producers = 64
  PerProducer = 16
  IdBaseBytes = 8192
    ## Past `SmallChunkSize`, so a row's strings are big chunks.
  Rounds = 3

type Producer = object
  id: int
  dbPath: string
  queueCapacity: int

proc statsIdFor(producer, index: int): string =
  ## Unique content AND unique length: `enqueueEstimateWrite` scans the queue
  ## for a matching (scope, statsId) pair, and distinct lengths keep that
  ## scan from turning into a megabyte-wide `==` per entry.
  "stats-" & $producer & "-" & $index & "-" &
    repeat('c', IdBaseBytes + producer * PerProducer + index)

proc fillQueue(state: ptr Producer) {.thread.} =
  {.cast(gcsafe).}:
    # THIS THREAD'S OWN HANDLE, allocated and freed here; see the head of
    # the module for why it is not the main thread's.
    let store = EstimateStore(mode: pmSqlite, dbPath: state.dbPath,
      queueCapacity: state.queueCapacity)
    for i in 0 ..< PerProducer:
      discard enqueueEstimateWrite(store, LearnedEstimateRow(
        scope: "ownership-scope-" & $state.id,
        commandStatsId: statsIdFor(state.id, i),
        conservativeMemoryBytes: 1024'u64,
        recentPeakMemoryBytes: 512'u64,
        sampleCount: 1'u32,
        lastOutcome: 0'u32,
        updatedUnixMillis: nowUnixMillis()))

var
  producers: array[Producers, Producer]
  producerThreads: array[Producers, Thread[ptr Producer]]

suite "estimate queue ownership":
  test "rows queued by threads that have exited are drained without crashing":
    let dir = createTempDir("runquota_estimate_ownership_", "")
    defer: removeDir(dir)
    for round in 0 ..< Rounds:
      # A STORE PER ROUND, so each round ends with the shutdown drain the
      # daemon performs: `stopEstimateStore` joins the writer, and the
      # writer's last pass frees whatever the dead producers left queued.
      let dbPath = dir / ("estimates-" & $round & ".sqlite3")
      let capacity = Producers * PerProducer
      let store = startEstimateStore(dbPath, queueCapacity = capacity)
      for i in 0 ..< Producers:
        producers[i] = Producer(id: i, dbPath: dbPath, queueCapacity: capacity)
        createThread(producerThreads[i], fillQueue, addr producers[i])
      for i in 0 ..< Producers:
        joinThread(producerThreads[i])
      stopEstimateStore(store)
      echo "  round ", round, ": store stopped, failures=",
        estimateWriteFailures()

    # THE ROWS REALLY LANDED. "It did not crash" would also be satisfied by a
    # queue that quietly dropped everything, so the last round's store is
    # read back.
    let rows = loadLearnedEstimates(dir / ("estimates-" & $(Rounds - 1) &
      ".sqlite3"))
    check rows.len == Producers * PerProducer
    check estimateWriteFailures() == 0'u64
    check estimateWriteFailedRows() == 0'u64
