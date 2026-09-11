import std/[locks, os, osproc, strutils, times]

import runquota_core/child_process
import runquota_core/process_owned

import runquota_persistence/types

export types

const libraryName* = "runquota_persistence"
const EstimateSchemaVersion* = 1'u32

proc libraryInfo*(): LibraryInfo =
  LibraryInfo(name: libraryName)

var writerLock: Lock
var writerReady = false
var writerStop = false
var writerDbPath = ""
var writerCapacity = 0
# THE PENDING QUEUE IS NOT A `seq[LearnedEstimateRow]`, and under ORC it
# cannot be.
#
# `enqueueEstimateWrite` is reached from `updateEstimateFromFinish`, which
# `handleRequest` calls when a client reports a lease finished -- so a row is
# allocated on a CONNECTION WORKER. It is freed by `writerMain`'s drain, and
# `serve` calls `stopEstimateStore` (which joins that writer) only AFTER every
# connection worker has been joined. A row still queued at that moment is
# therefore freed by a thread that did not allocate it, after the thread that
# did has ceased to exist.
#
# The window is narrower than the publisher's -- the drain runs every 50 ms --
# but it is open, and it is open exactly when it matters: each pass spawns
# `sqlite3`, so anything reported while a pass is in flight is still queued
# when the workers go away. An earlier report of this queue called it
# unreachable; it is not.
#
# Under ORC each thread has its own allocator region and every chunk records
# the region that owns it; freeing a foreign chunk dereferences `chunk.owner`,
# which lives in the owning thread's TLS and dies with it. `writerLock`
# serialises ACCESS and cannot help with OWNERSHIP; neither can `allocShared`,
# which under ORC is `allocImpl` verbatim. `OwnedStrings` puts the rows in the
# C allocator -- one arena for the whole process, no owning thread -- so which
# thread frees them, and when, stops mattering.
#
# The rows are held ENCODED, one blob each, because the queue's only lookup is
# by (scope, command_stats_id): `encodePending` puts that pair in front as a
# length-prefixed key, so `startsWithAt` answers the lookup with a byte
# compare and no allocation at all.
var writerPending: OwnedStrings
var writerThread: Thread[void]
var writerFailedBatches = 0'u64
var writerFailedRows = 0'u64

proc ensureWriterLock() =
  ## THE SAME SHAPE AS THE GUARD ``runquota_observation_store/writer`` NO
  ## LONGER HAS -- a plain ``bool`` gating an ``initLock`` -- AND LEFT AS IT
  ## IS, because the reachability that condemned that one does not exist
  ## here.
  ##
  ## Every caller is on the main thread before any other thread exists.
  ## ``startEstimateStore`` is called UNCONDITIONALLY from ``initDaemon``,
  ## with no capture-enabled arm to miss, so the only other two callers --
  ## ``estimateWriteFailures`` and ``estimateWriteFailedRows``, reached from
  ## the status JSON on a connection worker -- cannot be the first. Both
  ## tests that drive this module (``t_estimate_queue_ownership``,
  ## ``t_estimate_store_sqlite_streams``) call ``startEstimateStore`` before
  ## they create a thread.
  ##
  ## ``enqueueEstimateWrite`` AND ``stopEstimateStore`` take ``writerLock``
  ## without calling this, and neither needs to: BOTH return early unless
  ## ``store.mode == pmSqlite``, and ``startEstimateStore`` -- which does call
  ## this, on the main thread -- is the only thing in the module that produces
  ## such a store. Holding a ``pmSqlite`` handle is therefore proof the lock
  ## was already armed.
  ##
  ## If a second unconditional entry point is ever added to this module, the
  ## repair is the one the observation writer took: arm the lock at module
  ## initialisation, where no thread exists yet, and delete this guard.
  if not writerReady:
    initLock(writerLock)
    writerReady = true

proc nowUnixMillis*(): uint64 =
  uint64(epochTime() * 1000)

proc sqlQuote(value: string): string =
  "'" & value.replace("'", "''") & "'"

type
  SqliteRun* = object
    ## What one ``sqlite3`` invocation left behind.
    ##
    ## ``ok`` means the tool ran to completion and exited zero. It is NOT a
    ## synonym for "``failure`` is empty": a tool that started fine and then
    ## rejected the SQL has an empty ``failure`` and ``ok == false``, and that
    ## is exactly the case ``discard runSqlite(...)`` used to lose.
    ok*: bool
    output*: string
      ## What ``sqlite3`` put on stdout, and only that. Every caller here
      ## parses it as rows.
    failure*: string
      ## Why the tool could not be RUN at all -- an absent binary, a spawn
      ## that would not start. Empty when the child ran, whatever it exited
      ## with. This is not the child's stderr; see ``runSqlite``.

proc runSqlite*(path, sqlText: string): SqliteRun =
  ## Run ``sqlText`` against the estimate store and report what happened.
  ##
  ## THE STATEMENTS GO IN OVER STDIN, NOT AS AN ARGUMENT, and that is the
  ## defect this shape exists for. `writeBatch` builds one `insert` per queued
  ## row -- about 800 bytes each -- and handed the whole batch to `execve` as a
  ## SINGLE argv element. Linux caps one argument at `MAX_ARG_STRLEN`, 131_072
  ## bytes, independently of the much larger limit on the argument block as a
  ## whole: measured on the development host with a bare `execv`, an argument
  ## of 131_071 bytes spawns and one of 131_072 fails with `E2BIG`. A batch
  ## past roughly 160 rows therefore never reached `sqlite3` AT ALL, while a
  ## shorter one committed -- a size-dependent failure with no natural test to
  ## catch it, and one that does not exist on macOS, which has no
  ## per-argument cap. `runquota_observation_store/sqlite_cli` had already met
  ## this and already moved to stdin; this is the same move for the same
  ## reason.
  ##
  ## AND THE FAILURE IS RETURNED RATHER THAN DROPPED. This proc used to end in
  ## `.output`, which threw `failure` away, and its one write-side caller then
  ## `discard`ed even that. A batch that never ran was therefore
  ## indistinguishable here from a batch that committed. Whether a lost write
  ## may be ignored is a decision the caller has to take out loud, and
  ## `writerMain` now takes it.
  ##
  ## `-batch` and `-bail` keep stdin behaving the way argv did: no interactive
  ## prompting whatever stdin turns out to be, and stop at the first statement
  ## that fails rather than running the rest of a batch whose `begin immediate`
  ## has already gone wrong. `-noheader` because every reader here parses
  ## stdout as rows and a column header would be read as an estimate.
  ##
  ## `runCapturedProcess` services stdin, stdout and stderr AT ONCE, closes
  ## stdin, and takes the spawn guard so this thread and the observation
  ## store's writer cannot hand each other's pipes to their children. It
  ## replaced `execProcess(..., options = {poUsePath})`, whose body loops on
  ## `outputStream` and reads no other stream: passing `options` explicitly
  ## replaces the default `poStdErrToStdOut` wholesale, stderr gets a pipe of
  ## its own that nobody will ever read, and a `sqlite3` with more than the
  ## 65_536 bytes a pipe holds to say blocks in write(2) while the parent
  ## spins waiting for a child that can no longer exit. That runs on the
  ## estimate store's WRITER THREAD, which `stopEstimateStore` joins.
  ##
  ## Exported so the regression test can drive it in its production shape.
  ## The child's stderr is deliberately still discarded rather than folded
  ## into ``output``: every caller here parses ``output`` as rows, and a
  ## diagnostic mixed into that stream would be read as an estimate.
  let parent = parentDir(path)
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)
  let captured = runCapturedProcess(
    "sqlite3",
    args = ["-batch", "-noheader", "-bail", path],
    input = sqlText & "\n",
    options = {poUsePath})
  SqliteRun(
    ok: captured.failure.len == 0 and captured.ok,
    output: captured.output,
    failure: captured.failure)

proc initEstimateSchema(path: string): bool =
  ## Whether the schema is there to be written to. A store whose schema could
  ## not be created cannot take a batch either, so the caller folds this into
  ## the same reported failure rather than pressing on into a write it already
  ## knows cannot land.
  runSqlite(path, """
    create table if not exists learned_estimates (
      scope text not null,
      command_stats_id text not null,
      schema_version integer not null,
      conservative_memory_bytes integer not null,
      recent_peak_memory_bytes integer not null,
      sample_count integer not null,
      last_outcome integer not null,
      updated_unix_millis integer not null,
      primary key (scope, command_stats_id, schema_version)
    );
    pragma journal_mode = WAL;
    pragma synchronous = NORMAL;
  """).ok

proc loadLearnedEstimates*(path: string): seq[LearnedEstimateRow] =
  if path.len == 0 or not fileExists(path):
    return @[]
  discard initEstimateSchema(path)
  let run = runSqlite(path, """
    select scope, command_stats_id, conservative_memory_bytes,
           recent_peak_memory_bytes, sample_count, last_outcome,
           updated_unix_millis
      from learned_estimates
     where schema_version = """ & $EstimateSchemaVersion & """;
  """)
  # A STORE THAT WOULD NOT ANSWER YIELDS NO ESTIMATES, not a partial set.
  # `-bail` stops at the failing statement, so anything already on stdout
  # belongs to an interrupted read, and presenting it would be a truncated
  # answer wearing a complete one's clothes. No learned estimates is the
  # state every machine starts in and every caller here already handles,
  # which is what OS-4's "degrade" means at this seam.
  if not run.ok:
    return @[]
  for line in run.output.splitLines():
    if line.len > 0:
      let row = line.split('|')
      if row.len == 7:
        result.add(LearnedEstimateRow(
          scope: row[0],
          commandStatsId: row[1],
          conservativeMemoryBytes: parseUInt(row[2]),
          recentPeakMemoryBytes: parseUInt(row[3]),
          sampleCount: uint32(parseUInt(row[4])),
          lastOutcome: uint32(parseUInt(row[5])),
          updatedUnixMillis: parseUInt(row[6])
        ))

proc writeBatch(path: string; rows: seq[LearnedEstimateRow]): bool =
  ## Commits ``rows``. Returns whether they actually landed.
  if rows.len == 0:
    return true
  var sqlText = "begin immediate;\n"
  for row in rows:
    sqlText.add("""
      insert into learned_estimates (
          scope, command_stats_id, schema_version,
          conservative_memory_bytes, recent_peak_memory_bytes,
          sample_count, last_outcome, updated_unix_millis
        ) values (""" &
          sqlQuote(row.scope) & "," &
          sqlQuote(row.commandStatsId) & "," &
          $EstimateSchemaVersion & "," &
          $row.conservativeMemoryBytes & "," &
          $row.recentPeakMemoryBytes & "," &
          $row.sampleCount & "," &
          $row.lastOutcome & "," &
          $row.updatedUnixMillis & """)
        on conflict(scope, command_stats_id, schema_version) do update set
          conservative_memory_bytes = excluded.conservative_memory_bytes,
          recent_peak_memory_bytes = excluded.recent_peak_memory_bytes,
          sample_count = excluded.sample_count,
          last_outcome = excluded.last_outcome,
          updated_unix_millis = excluded.updated_unix_millis;
    """)
  sqlText.add("commit;\n")
  runSqlite(path, sqlText).ok

proc noteEstimateWriteFailure(rows: int) =
  ## A DROPPED BATCH IS COUNTED AND SAID ONCE -- NEVER SWALLOWED.
  ##
  ## The two obvious alternatives are both wrong here. Raising would put a
  ## cache's problem on the writer thread `stopEstimateStore` joins, and a
  ## learned estimate IS a cache: OS-4 is "degrade, never fail", and a daemon
  ## that stopped granting leases because it could not remember how much
  ## memory a command used last time has failed at its actual job.
  ## Discarding is what was here before, and it is how a whole batch could
  ## vanish on Linux for want of an argument shorter than `MAX_ARG_STRLEN`
  ## with nothing anywhere saying so. So: counted where a test and an
  ## operator can both read it, and the first one printed with its size.
  ##
  ## Said once for the same reason the daemon's connection counter is said
  ## once: a store that is failing fails on every batch, and an unbounded log
  ## is an outage of its own.
  var first = false
  acquire(writerLock)
  try:
    writerFailedBatches += 1
    writerFailedRows += uint64(rows)
    first = writerFailedBatches == 1'u64
  finally:
    release(writerLock)
  if first:
    echo "runquota estimate store dropped a batch of " & $rows &
      " learned estimates (counted as estimateWriteFailures and not " &
      "printed again)"
    flushFile(stdout)

proc estimateWriteFailures*(): uint64 =
  ## Batches the estimate writer could not commit. Zero is the only value a
  ## healthy store produces; a value that tracks the batch count is a store
  ## writing nothing at all.
  ensureWriterLock()
  acquire(writerLock)
  try:
    writerFailedBatches
  finally:
    release(writerLock)

proc estimateWriteFailedRows*(): uint64 =
  ## Rows inside those batches, reported separately because one dropped batch
  ## is not one dropped estimate.
  ensureWriterLock()
  acquire(writerLock)
  try:
    writerFailedRows
  finally:
    release(writerLock)

proc pendingKey(scope, commandStatsId: string): string =
  ## The identity the queue deduplicates on, LENGTH-PREFIXED so that no pair
  ## can spell another pair's key: without the lengths a scope ending in the
  ## separator would collide with the next field, and a queue that replaced
  ## the wrong row would publish one command's estimate under another's name.
  $scope.len & ":" & scope & ":" & $commandStatsId.len & ":" &
    commandStatsId & ":"

proc encodePending(row: LearnedEstimateRow): string =
  ## The key, then the five numbers. Written and read in this module only.
  pendingKey(row.scope, row.commandStatsId) &
    $row.conservativeMemoryBytes & "," & $row.recentPeakMemoryBytes & "," &
    $row.sampleCount & "," & $row.lastOutcome & "," & $row.updatedUnixMillis

proc decodePending(encoded: string): LearnedEstimateRow =
  ## Inverse of ``encodePending``. Total on anything ``encodePending``
  ## produced, which is the only thing that ever reaches it.
  var at = 0
  var fields: array[2, string]
  for f in 0 ..< 2:
    let colon = encoded.find(':', at)
    let width = parseInt(encoded[at ..< colon])
    fields[f] = encoded[colon + 1 ..< colon + 1 + width]
    at = colon + 1 + width + 1
  let numbers = encoded[at .. ^1].split(',')
  LearnedEstimateRow(
    scope: fields[0],
    commandStatsId: fields[1],
    conservativeMemoryBytes: parseUInt(numbers[0]),
    recentPeakMemoryBytes: parseUInt(numbers[1]),
    sampleCount: uint32(parseUInt(numbers[2])),
    lastOutcome: uint32(parseUInt(numbers[3])),
    updatedUnixMillis: parseUInt(numbers[4]))

proc takePendingRows(): seq[LearnedEstimateRow] =
  ## Empties the queue. REQUIRES ``writerLock``. The rows come back as
  ## ordinary Nim values allocated on the CALLING thread, so the batch the
  ## writer then hands to ``sqlite3`` is owned by the thread that frees it.
  for encoded in writerPending.takeAll():
    result.add(decodePending(encoded))

proc writerMain() {.thread.} =
  {.cast(gcsafe).}:
    try:
      while true:
        sleep(50)
        var batch: seq[LearnedEstimateRow] = @[]
        var shouldStop = false
        acquire(writerLock)
        try:
          shouldStop = writerStop
          if writerPending.len > 0:
            batch = takePendingRows()
        finally:
          release(writerLock)
        if batch.len > 0 and writerDbPath.len > 0:
          # THE RESULT IS CHECKED. `discard writeBatch(...)` is the second
          # half of the defect above: it is the line that made a whole batch
          # failing to reach `sqlite3` look exactly like a batch that
          # committed.
          let landed =
            initEstimateSchema(writerDbPath) and
            writeBatch(writerDbPath, batch)
          if not landed:
            noteEstimateWriteFailure(batch.len)
        if shouldStop:
          break
    finally:
      discard

proc startEstimateStore*(path: string; queueCapacity = 128): EstimateStore =
  ensureWriterLock()
  if path.len == 0:
    return EstimateStore(mode: pmInMemory, dbPath: "", queueCapacity: 0)
  acquire(writerLock)
  try:
    writerDbPath = path
    writerCapacity = max(1, queueCapacity)
    writerStop = false
    writerPending.clear()
  finally:
    release(writerLock)
  createThread(writerThread, writerMain)
  EstimateStore(mode: pmSqlite, dbPath: path, queueCapacity: queueCapacity)

proc enqueueEstimateWrite*(store: EstimateStore; row: LearnedEstimateRow): bool =
  if store.isNil or store.mode != pmSqlite:
    return true
  # ENCODED OUTSIDE THE LOCK, on the thread that will free the intermediate
  # string. This is the observation path, and OS-1 says it must not perturb
  # the work being observed; a lock held across a formatting call is a lock
  # every other connection worker waits behind.
  let key = pendingKey(row.scope, row.commandStatsId)
  let encoded = encodePending(row)
  acquire(writerLock)
  try:
    for i in 0 ..< writerPending.len:
      if writerPending.startsWithAt(i, key):
        # SAME PAIR: the newer figures replace the older ones rather than
        # queueing a second write of the same row.
        result = writerPending.setAt(i, encoded)
        return
    if writerPending.len >= writerCapacity:
      # THE OLDEST GOES, which is why `removeAt` keeps order.
      writerPending.removeAt(0)
    result = writerPending.add(encoded)
  finally:
    release(writerLock)

proc stopEstimateStore*(store: EstimateStore) =
  if store.isNil or store.mode != pmSqlite:
    return
  acquire(writerLock)
  try:
    writerStop = true
  finally:
    release(writerLock)
  joinThread(writerThread)
