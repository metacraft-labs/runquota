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
##
## OWNERS COME FIRST, BEFORE ALL THREE. An execution whose ``owner_uid``
## names no ``users`` row is refused by the schema (version 6), so the
## ``users`` upserts the daemon queues when a principal connects are drained
## ahead of the runs, executions and extension rows of the same batch. The
## daemon queues them at Hello, before any lease that connection can
## finish, so an execution's owner is always in the same batch or an
## earlier one.
##
## A FLUSH MEANS "EVERY ROW QUEUED BEFORE THIS CALL IS COMMITTED", and
## for a while it meant "the queue was empty when I looked". The two differ
## for exactly as long as a drain pass takes, because ``drainOnce`` swaps
## the queues under ``writerLock`` and then spawns ``sqlite3`` OUTSIDE it:
## in that window the queue is EMPTY and the rows are UNWRITTEN, and a
## second drainer arriving found nothing and returned. ``writerQueued`` and
## ``writerSettled`` close it -- see ``flushObservationWriter``.

import std/[locks, os]

import ./store, ./types
import runquota_core/process_owned

var
  writerLock: Lock
  writerSettledCond: Cond
    ## Broadcast whenever a drain pass has recorded the outcome of the rows
    ## it took. Waited on only by ``flushObservationWriter``; see there.
  writerThread: Thread[void]
  writerPath = ""
  writerCapacity = 0
  writerUsers: OwnedStrings
    ## ``users`` upserts. Not bounded by ``writerCapacity``: there is one per
    ## distinct principal the daemon has seen plus one per rename, and a
    ## dropped one would make every later execution of that owner a
    ## rejected row rather than one lost observation.
  writerRuns: OwnedStrings
  writerExecutions: OwnedStrings
  writerExtensionInserts: OwnedStrings
  writerDropped = 0'i64
  writerOwnersWritten = 0'i64
  writerOwnersLost = 0'i64
    ## ``users`` upserts committed, and lost with a failed batch or refused
    ## at the door. Kept apart from ``writerWritten``/``writerDropped``,
    ## which count OBSERVATIONS: an owner row is bookkeeping about who, and a
    ## count that mixed the two would report one more observation per user
    ## than any lease produced.
  writerFailures = 0'i64
  writerQueued = 0'i64
  writerWritten = 0'i64
  writerStop = false
  writerActive = false
  writerEpoch = 0'i64
    ## Incremented by every ``startObservationWriter``. A flush that is
    ## waiting when the writer is stopped and started again is waiting for
    ## a target belonging to a queue that no longer exists; the epoch is
    ## what lets it notice instead of waiting forever. Nothing in the
    ## daemon does that -- ``serve`` stops the writer only after every
    ## thread that could flush has been joined -- but "the shutdown order
    ## happens to save us" is not a property a waiting thread should
    ## depend on.
  writerSettled = 0'i64
    ## ROWS THAT HAVE LEFT THE QUEUE AND HAD AN OUTCOME RECORDED, written
    ## or failed. The partner of ``writerQueued``, which counts rows
    ## ACCEPTED into the queue: every accepted row settles exactly once, so
    ## ``writerSettled >= n`` means every one of the first ``n`` rows
    ## has reached the database or definitively has not. A row REFUSED at
    ## the door never enters either count, which is what keeps a flush's
    ## wait finite when the queue is overflowing.
  writerFlushes = 0'i64
    ## HOW MANY TIMES SOMEBODY DRAINED THIS QUEUE ON THEIR OWN THREAD.
    ## Counted because the rule below — read path only, never the write
    ## path — was broken once and nothing could see it: a synchronous drain
    ## on the completion path is invisible in every functional assertion
    ## the suite makes and shows up only as latency. A count turns "the
    ## completion path does not wait on the store" into something a test
    ## can assert instead of time.

# ARMED HERE, AT MODULE INITIALISATION, AND NEVER LAZILY.
#
# This was a lazy `ensure` proc called from the top of every proc below and
# guarded by a plain ``bool``. The guard could not do the job it was given:
# two threads reaching it before anybody had armed the writer would BOTH run
# ``initLock``, and the loser's lock would be the one every later caller
# failed to take. ``initLock`` on a mutex another thread may already hold is
# undefined, and the ``initCond`` beside it raised the consequence from an
# unsynchronised counter to a waiter parked on a condition variable nobody
# will ever signal.
#
# THE LIFECYCLE ARGUMENT THAT STOOD HERE WAS NOT TRUE OF EVERY REACHABLE
# CONFIGURATION. It said ``startObservationWriter`` runs on the main thread
# before a connection worker exists, so the first call is always
# single-threaded. ``initDaemon`` calls ``startObservationWriter`` only in
# the arm it takes when the store has a host identity AND ``ensureHostRow``
# succeeds; on every capture-disabled path -- no identity, an unwritable
# host row, ``--no-write-stats``, a store that would not open -- it is never
# called at all.
#
# THE ENQUEUES ARE NOT THE DOOR THAT LEAVES OPEN, and it is worth being
# exact about which is: ``openObservationRun`` and its siblings all return
# early on ``observationCaptureEnabled``. What is NOT gated is the READ
# side. ``statsAnswer`` calls ``flushObservationWriter`` unconditionally so
# that a query sees what the daemon has recorded, and the status JSON reads
# ``observationWriterFlushes``, ``observationsWritten``,
# ``observationsDropped`` and ``observationWriteFailures`` unconditionally.
# Both run on a CONNECTION WORKER, of which the daemon starts several, so on
# a capture-disabled daemon two concurrent ``stats`` or ``status`` requests
# were this module's first touch -- and both would have armed it.
#
# Module initialisation runs inside ``NimMain``, before ``main`` and
# therefore before this process has created any thread, so the invariant is
# structural rather than a lifecycle argument to be re-checked whenever the
# daemon's start-up order changes: EVERY ``acquire(writerLock)`` below runs
# against a lock that was initialised single-threaded.
# ``runquota_core/spawn_guard`` arms its process-wide lock the same way.
initLock(writerLock)
initCond(writerSettledCond)

proc drainOnce() {.gcsafe.} =
  {.cast(gcsafe).}:
    # THE STATEMENTS COME BACK AS THIS THREAD'S OWN STRINGS. ``takeAll``
    # copies them out of process-owned storage, so what this proc frees on
    # its way out is what this proc allocated; see the head of this module.
    var statements: seq[string] = @[]
    var ownerStatements = 0
    var path = ""
    acquire(writerLock)
    try:
      path = writerPath
      # RUNS, THEN EXECUTIONS, THEN EXTENSION ROWS. The order is the one
      # `batchStatement` has always emitted and it is load-bearing: an
      # extension row's foreign key names its execution, and `foreign_keys`
      # is on, so a row placed before its parent aborts the transaction and
      # takes the parent with it.
      statements = writerUsers.takeAll()
      ownerStatements = statements.len
      for statement in writerRuns.takeAll():
        statements.add(statement)
      for statement in writerExecutions.takeAll():
        statements.add(statement)
      for statement in writerExtensionInserts.takeAll():
        statements.add(statement)
    finally:
      release(writerLock)
    if statements.len == 0:
      return
    if path.len == 0:
      # TAKEN OUT OF THE QUEUE WITH NOWHERE TO PUT THEM. Unreachable while
      # the writer is running -- an enqueue needs ``writerActive`` and the
      # path is cleared only after the drain thread has been joined -- but
      # these rows are gone either way, and a flush waiting on an outcome
      # that has already happened must not wait for it forever.
      acquire(writerLock)
      try:
        writerDropped += int64(statements.len - ownerStatements)
        writerOwnersLost += int64(ownerStatements)
        writerSettled += int64(statements.len)
        broadcast(writerSettledCond)
      finally:
        release(writerLock)
      return
    # THE SETTLE BELOW IS NOT IN A ``try``/``finally``, AND THAT IS A
    # COUPLING RATHER THAN AN OVERSIGHT. These rows have already left the
    # queue; if this call could raise, they would never settle and every
    # flush waiting on them would park until the epoch changed. It cannot:
    # ``appendStatementsAt`` reaches SQLite through ``runSqlite``, which
    # documents "never raises" and honours it -- a tool that will not even
    # start comes back as ``ok == false`` with the reason in ``error``. If
    # that ever stops being true, ``writerSettled`` and its broadcast have
    # to move into a ``finally`` before the raise is allowed.
    let outcome = appendStatementsAt(path, statements)
    acquire(writerLock)
    try:
      if outcome.ok:
        writerWritten += int64(statements.len - ownerStatements)
        writerOwnersWritten += int64(ownerStatements)
      else:
        writerFailures += 1
        writerDropped += int64(statements.len - ownerStatements)
        writerOwnersLost += int64(ownerStatements)
      # EVERY ROW TAKEN ABOVE NOW HAS AN OUTCOME. Counted and announced
      # under the same lock that holds the counters, so a waiter cannot see
      # the wake without the count that justifies it.
      writerSettled += int64(statements.len)
      broadcast(writerSettledCond)
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
  acquire(writerLock)
  try:
    if writerActive:
      return
    writerPath = path
    writerCapacity = max(1, capacity)
    writerUsers.clear()
    writerRuns.clear()
    writerExecutions.clear()
    writerExtensionInserts.clear()
    writerStop = false
    writerDropped = 0
    writerOwnersWritten = 0
    writerOwnersLost = 0
    writerFailures = 0
    writerQueued = 0
    writerWritten = 0
    writerSettled = 0
    # A NEW QUEUE, AND ANY WAITER IS WAITING FOR THE OLD ONE. Bumped and
    # announced under the lock that holds the counters it invalidates.
    writerEpoch += 1
    broadcast(writerSettledCond)
    if path.len == 0:
      return
    writerActive = true
  finally:
    release(writerLock)
  createThread(writerThread, writerMain)

proc observationWriterActive*(): bool =
  acquire(writerLock)
  try:
    writerActive
  finally:
    release(writerLock)

proc enqueueUserRecord*(statement: string): bool {.discardable.} =
  ## Queue one ``users`` upsert (``userUpsertStatement``), composed by the
  ## caller from the connection's PEER CREDENTIALS.
  ##
  ## Drained before every other row -- see the head of this module -- and
  ## not subject to the shared capacity, for the reason given at
  ## ``writerUsers``. Returns false when the writer is inactive or the
  ## allocator refused; the caller then leaves the owner unrecorded and
  ## tries again at its next connection. Counted in ``ownerRecordsLost``,
  ## never in ``observationsDropped``: it is not an observation.
  acquire(writerLock)
  try:
    if not writerActive or statement.len == 0:
      writerOwnersLost += 1
      return false
    if not writerUsers.add(statement):
      writerOwnersLost += 1
      return false
    writerQueued += 1
    true
  finally:
    release(writerLock)

proc enqueueRunRow*(row: RunRow): bool {.discardable.} =
  ## Returns false when the row was dropped (writer inactive or queue
  ## full). Never blocks on IO.
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
  ## THE CONTRACT IS "EVERY ROW QUEUED BEFORE THIS CALL IS COMMITTED", and
  ## it used to be "the queue was empty when I looked". ``drainOnce`` swaps
  ## the queues under ``writerLock`` and then spawns ``sqlite3`` OUTSIDE it,
  ## so for the length of that spawn the queue is EMPTY and the rows are
  ## UNWRITTEN. A second drainer arriving in that window found nothing and
  ## returned, and the writer's own thread is always a second drainer.
  ##
  ## WHAT THAT COST. ``publishDirtyAggregates`` flushes and then computes an
  ## aggregate, so it computed one over a row that had not committed -- and
  ## the wrong figure was PERMANENT, not late: the key was consumed by the
  ## drain that published it and nothing re-dirties it. ``statsAnswer`` has
  ## the same exposure on the read path, where a client would be told its
  ## own execution never happened.
  ##
  ## HOW IT IS ANSWERED. Every accepted enqueue increments ``writerQueued``;
  ## every row a pass takes settles exactly once into ``writerSettled``.
  ## A flush reads ``writerQueued``, drains whatever is still queued itself,
  ## and then waits for ``writerSettled`` to catch up with what it read.
  ## Rows queued AFTER the call are none of its business, which is what
  ## bounds the wait.
  ##
  ## WHY NOT HOLD ``writerLock`` ACROSS THE SPAWN. That is the other way to
  ## make the queue and the database agree, and it puts every connection
  ## worker's ``enqueueRunRow`` behind a 25-40 ms batch -- the hot-path
  ## perturbation OS-1 forbids, and the one M13b was spent removing.
  ##
  ## WHAT THE WAIT COSTS. In the ordinary case one batch write, which is what
  ## this caller would have paid had it been the thread that took those rows:
  ## the two cases are "I spawn ``sqlite3``" and "I wait for the ``sqlite3``
  ## somebody else spawned a moment ago", and with nothing in flight there is
  ## no wait at all.
  ##
  ## ONE BATCH IS NOT A CEILING, and this comment used to say it was. Several
  ## drainers can be in flight against ONE SQLite file -- the writer's own
  ## thread, the aggregate publisher, and every thread that has just asked a
  ## question -- and SQLite serialises writers, so under the ``.timeout 5000``
  ## in ``sqlite_cli``'s preamble each of those batches waits for the one
  ## ahead of it. A flush's target can therefore settle only after several
  ## batches have run IN SEQUENCE. That is a latency nuance and not a defect:
  ## the wait is still finite, because ``writerQueued`` is read ONCE and rows
  ## queued after that reading are none of this call's business, and every
  ## caller on this path is a reader who is already waiting for an answer.
  var running = false
  var target = 0'i64
  var epoch = 0'i64
  acquire(writerLock)
  try:
    writerFlushes += 1
    running = writerActive
    target = writerQueued
    epoch = writerEpoch
  finally:
    release(writerLock)
  if not running:
    return
  drainOnce()
  acquire(writerLock)
  try:
    while writerSettled < target and writerEpoch == epoch:
      wait(writerSettledCond, writerLock)
  finally:
    release(writerLock)

proc observationWriterFlushes*(): int64 =
  ## Synchronous drains taken so far, by anybody, on any thread.
  ##
  ## THE POINT IS THAT IT MUST NOT SCALE WITH COMPLETED WORK. One drain per
  ## query and one per publication batch are expected; one per finished
  ## lease is the defect this counter was added to make visible.
  acquire(writerLock)
  try:
    writerFlushes
  finally:
    release(writerLock)

proc observationsDropped*(): int64 =
  acquire(writerLock)
  try:
    writerDropped
  finally:
    release(writerLock)

proc observationsWritten*(): int64 =
  acquire(writerLock)
  try:
    writerWritten
  finally:
    release(writerLock)

proc ownerRecordsWritten*(): int64 =
  ## ``users`` upserts committed by this writer.
  acquire(writerLock)
  try:
    writerOwnersWritten
  finally:
    release(writerLock)

proc ownerRecordsLost*(): int64 =
  ## ``users`` upserts refused at the door or lost with a failed batch.
  acquire(writerLock)
  try:
    writerOwnersLost
  finally:
    release(writerLock)

proc observationWriteFailures*(): int64 =
  acquire(writerLock)
  try:
    writerFailures
  finally:
    release(writerLock)

proc stopObservationWriter*() =
  ## Flushes what is queued and joins the drain thread.
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
