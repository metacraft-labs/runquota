## Background observation writer.
##
## OS-1 ("observation never perturbs") forbids the recording path from
## blocking or fsyncing. Recording here is an in-memory append under an
## uncontended lock; a background thread drains the queue and writes
## batches, exactly the pattern ``runquota_persistence`` already uses for
## learned estimates.
##
## The queue is bounded. When it is full the new row is DROPPED and
## counted: losing an observation is always preferable to perturbing the
## work being observed. The count is the raw material for OS-2's
## ``capture_completeness`` verdict, which is wired up in M13.
##
## Single-writer-per-process, like the learned-estimate writer next to it:
## the state below is module-level so no ``ref`` crosses a thread boundary.
##
## THE QUEUES HOLD BYTES, NOT ROWS, and under ORC they have to.
##
## ``enqueueRunRow``, ``enqueueExecutionRow`` and ``enqueueExtensionInsert``
## are called on a CONNECTION WORKER -- that is where an observation is
## recorded. The queues are drained by ``drainOnce``, which runs on the
## writer's own thread, on the aggregate publisher's thread through
## ``flushObservationWriter``, and on whichever thread has just asked a
## question. ``serve`` joins the connection workers first and stops this
## writer last, so a row still queued when the workers go away is freed by a
## thread that did not allocate it, after the thread that did has ceased to
## exist.
##
## Under ORC every thread has its own allocator region and every chunk
## records the region that owns it; freeing a foreign chunk dereferences
## ``chunk.owner``, which lives in the owning thread's TLS and dies with it.
## ``writerLock`` serialises ACCESS and cannot answer OWNERSHIP, and
## ``allocShared`` is ``allocImpl`` verbatim under ORC, with the same
## per-thread ownership. So the queues are ``OwnedStrings``: the C
## allocator, one arena for the whole process, no owning thread.
##
## THE ROW BECOMES ITS STATEMENT AT THE ENQUEUE, on the recording thread.
## That is what lets one storage shape serve all three queues, and it is
## work this path was going to do anyway -- pure string formatting, no IO, no
## lock held across it. ``drainOnce`` then concatenates the three in the
## order ``batchStatement`` always used: runs, executions, extension rows.
## That order is load-bearing, because an extension row carries a foreign key
## to its execution.

import std/[locks, os]

import ./store, ./types
import runquota_core/process_owned

var
  writerLock: Lock
  writerLockReady = false
  writerThread: Thread[void]
  writerPath = ""
  writerCapacity = 0
  writerRuns: OwnedStrings
  writerExecutions: OwnedStrings
  writerExtensionInserts: OwnedStrings
  writerDropped = 0'i64
  writerFailures = 0'i64
  writerQueued = 0'i64
  writerWritten = 0'i64
  writerStop = false
  writerActive = false
  writerFlushes = 0'i64
    ## HOW MANY TIMES SOMEBODY DRAINED THIS QUEUE ON THEIR OWN THREAD.
    ## Counted because the rule below — read path only, never the write
    ## path — was broken once and nothing could see it: a synchronous drain
    ## on the completion path is invisible in every functional assertion
    ## the suite makes and shows up only as latency. A count turns "the
    ## completion path does not wait on the store" into something a test
    ## can assert instead of time.

proc ensureWriterLock() =
  if not writerLockReady:
    initLock(writerLock)
    writerLockReady = true

proc drainOnce() {.gcsafe.} =
  {.cast(gcsafe).}:
    # THE STATEMENTS COME BACK AS THIS THREAD'S OWN STRINGS. ``takeAll``
    # copies them out of process-owned storage, so what this proc frees on
    # its way out is what this proc allocated; see the head of this module.
    var statements: seq[string] = @[]
    var path = ""
    acquire(writerLock)
    try:
      path = writerPath
      # RUNS, THEN EXECUTIONS, THEN EXTENSION ROWS. The order is the one
      # `batchStatement` has always emitted and it is load-bearing: an
      # extension row's foreign key names its execution, and `foreign_keys`
      # is on, so a row placed before its parent aborts the transaction and
      # takes the parent with it.
      statements = writerRuns.takeAll()
      for statement in writerExecutions.takeAll():
        statements.add(statement)
      for statement in writerExtensionInserts.takeAll():
        statements.add(statement)
    finally:
      release(writerLock)
    if path.len == 0 or statements.len == 0:
      return
    let outcome = appendStatementsAt(path, statements)
    acquire(writerLock)
    try:
      if outcome.ok:
        writerWritten += int64(statements.len)
      else:
        writerFailures += 1
        writerDropped += int64(statements.len)
    finally:
      release(writerLock)

proc writerMain() {.thread.} =
  while true:
    sleep(25)
    drainOnce()
    var shouldStop = false
    {.cast(gcsafe).}:
      acquire(writerLock)
      try:
        shouldStop = writerStop
      finally:
        release(writerLock)
    if shouldStop:
      drainOnce()
      break

proc startObservationWriter*(path: string; capacity = 1024) =
  ## Starts the drain thread for ``path``. Passing an empty path leaves the
  ## writer inactive, which is how a degraded or disabled store is
  ## represented: every enqueue then becomes a counted no-op.
  ensureWriterLock()
  acquire(writerLock)
  try:
    if writerActive:
      return
    writerPath = path
    writerCapacity = max(1, capacity)
    writerRuns.clear()
    writerExecutions.clear()
    writerExtensionInserts.clear()
    writerStop = false
    writerDropped = 0
    writerFailures = 0
    writerQueued = 0
    writerWritten = 0
    if path.len == 0:
      return
    writerActive = true
  finally:
    release(writerLock)
  createThread(writerThread, writerMain)

proc observationWriterActive*(): bool =
  ensureWriterLock()
  acquire(writerLock)
  try:
    writerActive
  finally:
    release(writerLock)

proc enqueueRunRow*(row: RunRow): bool {.discardable.} =
  ## Returns false when the row was dropped (writer inactive or queue
  ## full). Never blocks on IO.
  ensureWriterLock()
  # COMPOSED OUTSIDE THE LOCK, on the thread that will free the intermediate
  # string. OS-1 forbids the recording path from perturbing the work being
  # observed, and a lock held across a formatting call is a lock every other
  # connection worker waits behind.
  let statement = runInsertStatement(row)
  acquire(writerLock)
  try:
    if not writerActive or
        writerRuns.len + writerExecutions.len >= writerCapacity:
      # Counted either way: an observation offered while capture is off is
      # as lost as one offered to a full queue, and OS-2 wants the number.
      writerDropped += 1
      return false
    if not writerRuns.add(statement):
      # The allocator refused. A row nobody can store is as lost as one
      # offered to a full queue, and is counted the same way.
      writerDropped += 1
      return false
    writerQueued += 1
    true
  finally:
    release(writerLock)

proc enqueueExecutionRow*(row: ExecutionRow): bool {.discardable.} =
  ensureWriterLock()
  # Composed outside the lock; see `enqueueRunRow`.
  let statement = executionInsertStatement(row)
  acquire(writerLock)
  try:
    if not writerActive or
        writerRuns.len + writerExecutions.len >= writerCapacity:
      # Counted either way: an observation offered while capture is off is
      # as lost as one offered to a full queue, and OS-2 wants the number.
      writerDropped += 1
      return false
    if not writerExecutions.add(statement):
      writerDropped += 1
      return false
    writerQueued += 1
    true
  finally:
    release(writerLock)

proc enqueueExtensionInsert*(statement: string): bool {.discardable.} =
  ## Queue one already-admitted extension insert (M17).
  ##
  ## THE STATEMENT ARRIVES COMPOSED, and that is the boundary working
  ## rather than a shortcut around it. Composing it needs the registry,
  ## which lives behind the ``ObservationStore`` ref the daemon thread
  ## owns and this writer must never touch; ``admitExtensionRow`` does the
  ## composing on that thread, having made every check
  ## ``insertExtensionRow`` makes. What reaches here is opaque to the
  ## writer, which is exactly what an extension is supposed to be.
  ##
  ## The queue is shared with runs and executions and bounded by the same
  ## capacity, so an extension row can be dropped like any other
  ## observation, and is counted like one.
  ensureWriterLock()
  acquire(writerLock)
  try:
    if not writerActive or statement.len == 0 or
        writerRuns.len + writerExecutions.len + writerExtensionInserts.len >=
          writerCapacity:
      writerDropped += 1
      return false
    if not writerExtensionInserts.add(statement):
      writerDropped += 1
      return false
    writerQueued += 1
    true
  finally:
    release(writerLock)

proc flushObservationWriter*() =
  ## Drains whatever is queued, synchronously, on the CALLER's thread.
  ##
  ## FOR THE READ PATH, NEVER FOR THE WRITE PATH. A query that could not
  ## see an execution the daemon has already recorded would make the store
  ## a system of record only after an unspecified delay, and a caller
  ## cannot tell "not yet flushed" from "never happened". OS-1 is
  ## untouched: this is not on the observation-recording path, it is on the
  ## path of somebody who has just asked a question and is waiting for the
  ## answer anyway.
  ##
  ## "NOBODY IS WAITING" IS THE REAL TEST, and it is what admits the
  ## aggregate publisher's background thread as well as a query: that
  ## thread flushes so the aggregate it is about to compute includes the
  ## run that dirtied the key, and no client's reply is behind it. What the
  ## rule excludes is a caller who is holding up work that has already
  ## finished — a completion report did exactly that for the whole of
  ## M13b, at a cost of tens of milliseconds per finished action, and the
  ## count below exists so a test can say so.
  ##
  ## Safe to call concurrently with the drain thread: the queue swap is
  ## under the same lock, so at worst one of the two callers finds nothing
  ## to write.
  ensureWriterLock()
  var running = false
  acquire(writerLock)
  try:
    writerFlushes += 1
    running = writerActive
  finally:
    release(writerLock)
  if running:
    drainOnce()

proc observationWriterFlushes*(): int64 =
  ## Synchronous drains taken so far, by anybody, on any thread.
  ##
  ## THE POINT IS THAT IT MUST NOT SCALE WITH COMPLETED WORK. One drain per
  ## query and one per publication batch are expected; one per finished
  ## lease is the defect this counter was added to make visible.
  ensureWriterLock()
  acquire(writerLock)
  try:
    writerFlushes
  finally:
    release(writerLock)

proc observationsDropped*(): int64 =
  ensureWriterLock()
  acquire(writerLock)
  try:
    writerDropped
  finally:
    release(writerLock)

proc observationsWritten*(): int64 =
  ensureWriterLock()
  acquire(writerLock)
  try:
    writerWritten
  finally:
    release(writerLock)

proc observationWriteFailures*(): int64 =
  ensureWriterLock()
  acquire(writerLock)
  try:
    writerFailures
  finally:
    release(writerLock)

proc stopObservationWriter*() =
  ## Flushes what is queued and joins the drain thread.
  ensureWriterLock()
  var running = false
  acquire(writerLock)
  try:
    running = writerActive
    writerStop = true
  finally:
    release(writerLock)
  if not running:
    return
  joinThread(writerThread)
  acquire(writerLock)
  try:
    writerActive = false
    writerPath = ""
  finally:
    release(writerLock)
