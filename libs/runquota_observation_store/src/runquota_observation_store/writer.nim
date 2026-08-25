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

import std/[locks, os]

import ./store, ./types

var
  writerLock: Lock
  writerLockReady = false
  writerThread: Thread[void]
  writerPath = ""
  writerCapacity = 0
  writerRuns: seq[RunRow] = @[]
  writerExecutions: seq[ExecutionRow] = @[]
  writerExtensionInserts: seq[string] = @[]
  writerDropped = 0'i64
  writerFailures = 0'i64
  writerQueued = 0'i64
  writerWritten = 0'i64
  writerStop = false
  writerActive = false

proc ensureWriterLock() =
  if not writerLockReady:
    initLock(writerLock)
    writerLockReady = true

proc drainOnce() {.gcsafe.} =
  {.cast(gcsafe).}:
    var runs: seq[RunRow] = @[]
    var executions: seq[ExecutionRow] = @[]
    var extensionInserts: seq[string] = @[]
    var path = ""
    acquire(writerLock)
    try:
      path = writerPath
      if writerRuns.len > 0:
        runs = writerRuns
        writerRuns = @[]
      if writerExecutions.len > 0:
        executions = writerExecutions
        writerExecutions = @[]
      if writerExtensionInserts.len > 0:
        extensionInserts = writerExtensionInserts
        writerExtensionInserts = @[]
    finally:
      release(writerLock)
    if path.len == 0 or
        (runs.len == 0 and executions.len == 0 and
         extensionInserts.len == 0):
      return
    let outcome = appendBatchAt(path, runs, executions, extensionInserts)
    acquire(writerLock)
    try:
      if outcome.ok:
        writerWritten += int64(runs.len + executions.len +
          extensionInserts.len)
      else:
        writerFailures += 1
        writerDropped += int64(runs.len + executions.len +
          extensionInserts.len)
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
    writerRuns = @[]
    writerExecutions = @[]
    writerExtensionInserts = @[]
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
  acquire(writerLock)
  try:
    if not writerActive or
        writerRuns.len + writerExecutions.len >= writerCapacity:
      # Counted either way: an observation offered while capture is off is
      # as lost as one offered to a full queue, and OS-2 wants the number.
      writerDropped += 1
      return false
    writerRuns.add(row)
    writerQueued += 1
    true
  finally:
    release(writerLock)

proc enqueueExecutionRow*(row: ExecutionRow): bool {.discardable.} =
  ensureWriterLock()
  acquire(writerLock)
  try:
    if not writerActive or
        writerRuns.len + writerExecutions.len >= writerCapacity:
      # Counted either way: an observation offered while capture is off is
      # as lost as one offered to a full queue, and OS-2 wants the number.
      writerDropped += 1
      return false
    writerExecutions.add(row)
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
    writerExtensionInserts.add(statement)
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
  ## Safe to call concurrently with the drain thread: the queue swap is
  ## under the same lock, so at worst one of the two callers finds nothing
  ## to write.
  ensureWriterLock()
  var running = false
  acquire(writerLock)
  try:
    running = writerActive
  finally:
    release(writerLock)
  if running:
    drainOnce()

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
