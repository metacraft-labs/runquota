import std/[heapqueue, locks, monotimes, os, strutils, tables, times]

import runquota_core/process_owned
import runquota_core/sqlite_inproc

import runquota_persistence/types

export types

const libraryName* = "runquota_persistence"
const EstimateSchemaVersion* = 1'u32

const DefaultEstimateRefreshIntervalMillis* = 30_000'i64
  ## How often, at most, the writer commits a key's row when nothing a
  ## decision reads has changed since that key was last committed -- when
  ## only the sample count, the recent peak, the outcome, the time or the
  ## time of a breach identical to the last one moved.
  ##
  ## With the memory cap on, every finish carries a measured peak and so
  ## changes its command's row. Committing each one made the writer's
  ## SQLite work, which is daemon CPU, grow with the finish rate of every
  ## command that repeats, while the figures admission and the cap read
  ## (`decisionFigures`) change on a small minority of finishes. Those are
  ## still committed with the next batch; the row in the daemon's memory,
  ## which is what admission reads, has every finish at once either way.
  ##
  ## The saving is for keys that finish more than once per interval; a key
  ## seen once is committed with the next batch as before. Thirty seconds
  ## bounds what a crash can lose to half a minute of sample counts per
  ## command, which the next finishes relearn; a clean stop loses nothing
  ## (`stopEstimateStore` commits every waiting row).

const DefaultEstimateWaitingCapacity* = 4096
  ## The most rows the writer holds back at once (one per key). A row that
  ## would make it more sends the longest-waiting one to the store with the
  ## current batch instead, so the held-back set never grows past this
  ## whatever the number of distinct command keys.

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
# but it is open, and it is open exactly when it matters: each pass writes
# to SQLite, so anything reported while a pass is in flight is still queued
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
var writerRowsWritten = 0'u64
var writerRefreshMillis = DefaultEstimateRefreshIntervalMillis
var writerWaitingCapacity = DefaultEstimateWaitingCapacity
  ## Set by `startEstimateStore` before the writer thread exists; read only
  ## by that thread.

proc ensureWriterLock() =
  ## THE SAME SHAPE AS THE GUARD ``runquota_observation_store/writer`` NO
  ## LONGER HAS -- a plain ``bool`` gating an ``initLock`` -- AND LEFT AS IT
  ## IS, because the reachability that condemned that one does not exist
  ## here.
  ##
  ## Every caller is on the main thread before any other thread exists.
  ## ``startEstimateStore`` is called UNCONDITIONALLY from ``initDaemon``,
  ## with no capture-enabled arm to miss, so the only other callers --
  ## ``estimateWriteFailures``, ``estimateWriteFailedRows`` and
  ## ``estimateRowsWritten``, reached from the status JSON on a connection
  ## worker -- cannot be the first. Every test that drives this module
  ## (``t_estimate_queue_ownership``, ``t_estimate_store_sqlite_streams``,
  ## ``t_rqm_estimate_columns``, ``t_estimate_refresh_interval``) calls
  ## ``startEstimateStore`` before it creates a thread or reads a counter.
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

type
  SqliteRun* = object
    ## What one call into SQLite left behind.
    ##
    ## ``ok`` means every statement ran. It is NOT a synonym for "``failure``
    ## is empty": a store that opened and then rejected the SQL has
    ## ``ok == false`` with the reason in ``failure``, and that is exactly the
    ## case ``discard runSqlite(...)`` used to lose.
    ok*: bool
    output*: string
      ## The rows, in the ``sqlite3`` tool's list format (``|`` between
      ## columns, one row per line). Every caller here parses it as rows.
    failure*: string
      ## Why the statements did not all run: SQLite's message, or why no
      ## library or connection could be had.

proc runSqlite*(path, sqlText: string): SqliteRun =
  ## Runs a script of SQL text against the estimate store, IN THIS PROCESS
  ## (``runquota_core/sqlite_inproc``), on a connection of its own, stopping
  ## at the first statement that fails. For SQL this module composes itself;
  ## the learned estimates, which carry client-reported keys, are written and
  ## read with bound values instead (``writeBatch``, ``loadLearnedEstimates``).
  ##
  ## This used to run the ``sqlite3`` tool, once per batch, which cost a
  ## fork and an exec on the writer thread every 50 ms of a build; the
  ## defects that path met (an argument past ``MAX_ARG_STRLEN``, a stderr
  ## pipe nobody read) have no counterpart here.
  ##
  ## Exported so the regression test can drive it in its production shape.
  let parent = parentDir(path)
  if parent.len > 0 and not dirExists(parent):
    try:
      createDir(parent)
    except CatchableError as error:
      return SqliteRun(ok: false, output: "", failure: error.msg)
  let outcome = runSqlScript(path, sqlText)
  SqliteRun(ok: outcome.ok, output: outcome.output, failure: outcome.error)

const MemoryCapColumns* = ["max_observed_peak_bytes", "declared_cap_bytes",
  "declared_by_uid", "declared_unix_millis", "last_breach_cap_bytes",
  "last_breach_peak_bytes", "last_breach_unix_millis"]
  ## The memory-cap figures of a row (see `LearnedEstimateRow`), in the
  ## order the reads and the upsert list them.

proc addMissingColumns(path: string): bool =
  ## ADDS THE MEMORY-CAP COLUMNS TO A STORE THAT PREDATES THEM, KEEPING ITS
  ## ROWS.
  ##
  ## `schema_version` is a KEY COLUMN of this table, so bumping
  ## `EstimateSchemaVersion` would not migrate anything: every row written
  ## under version 1 would simply stop being read (`loadLearnedEstimates`
  ## selects one version), and each host would forget every learned figure
  ## it has the day it upgraded. The new figures have an obvious value for an
  ## old row -- zero, "nothing recorded yet" -- which is exactly what SQLite's
  ## `ALTER TABLE ... ADD COLUMN ... DEFAULT 0` gives every existing row, so
  ## the change is additive and the version stays 1.
  ## https://www.sqlite.org/lang_altertable.html#altertabaddcol
  ##
  ## IDEMPOTENT BY ASKING FIRST. SQLite has no `ADD COLUMN IF NOT EXISTS`, so
  ## the columns the table has are read from `pragma table_info` and only the
  ## missing ones are added. A second writer racing this one (two daemons on
  ## one store, which the lifetime lock prevents in production) makes one
  ## `ALTER` fail with "duplicate column"; that answers false here, the batch
  ## is reported dropped, and the next batch's schema check finds the column
  ## present.
  let info = queryBound(path, "pragma table_info(learned_estimates)", [])
  if not info.ok:
    return false
  var present: seq[string] = @[]
  for line in info.output.splitLines():
    let fields = line.split('|')
    # cid|name|type|notnull|dflt_value|pk
    if fields.len >= 2:
      present.add(fields[1])
  var script = ""
  for column in MemoryCapColumns:
    if column notin present:
      script.add("alter table learned_estimates add column " & column &
        " integer not null default 0;\n")
  if script.len == 0:
    return true
  runSqlite(path, script).ok

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
      max_observed_peak_bytes integer not null default 0,
      declared_cap_bytes integer not null default 0,
      declared_by_uid integer not null default 0,
      declared_unix_millis integer not null default 0,
      last_breach_cap_bytes integer not null default 0,
      last_breach_peak_bytes integer not null default 0,
      last_breach_unix_millis integer not null default 0,
      primary key (scope, command_stats_id, schema_version)
    );
    pragma journal_mode = WAL;
    pragma synchronous = NORMAL;
  """).ok and addMissingColumns(path)

proc loadLearnedEstimates*(path: string): seq[LearnedEstimateRow] =
  if path.len == 0 or not fileExists(path):
    return @[]
  discard initEstimateSchema(path)
  let run = queryBound(path, """
    select scope, command_stats_id, conservative_memory_bytes,
           recent_peak_memory_bytes, sample_count, last_outcome,
           updated_unix_millis, max_observed_peak_bytes,
           declared_cap_bytes, declared_by_uid, declared_unix_millis,
           last_breach_cap_bytes, last_breach_peak_bytes,
           last_breach_unix_millis
      from learned_estimates
     where schema_version = ?""", [sqlInt(int64(EstimateSchemaVersion))])
  # A STORE THAT WOULD NOT ANSWER YIELDS NO ESTIMATES, not a partial set.
  # A read that failed part way has rows in ``output`` that belong to an
  # interrupted read, and presenting them would be a truncated answer
  # wearing a complete one's clothes. No learned estimates is the state
  # every machine starts in and every caller here already handles, which is
  # what OS-4's "degrade" means at this seam.
  if not run.ok:
    return @[]
  for line in run.output.splitLines():
    if line.len > 0:
      let row = line.split('|')
      if row.len == 14:
        try:
          result.add(LearnedEstimateRow(
            scope: row[0],
            commandStatsId: row[1],
            conservativeMemoryBytes: parseUInt(row[2]),
            recentPeakMemoryBytes: parseUInt(row[3]),
            sampleCount: uint32(parseUInt(row[4])),
            lastOutcome: uint32(parseUInt(row[5])),
            updatedUnixMillis: parseUInt(row[6]),
            maxObservedPeakBytes: parseUInt(row[7]),
            declaredCapBytes: parseUInt(row[8]),
            declaredByUid: parseUInt(row[9]),
            declaredUnixMillis: parseUInt(row[10]),
            lastBreachCapBytes: parseUInt(row[11]),
            lastBreachPeakBytes: parseUInt(row[12]),
            lastBreachUnixMillis: parseUInt(row[13])
          ))
        except ValueError:
          # A key holding the separator splits into the wrong fields; such
          # a row is skipped rather than read as someone else's figures.
          discard

const estimateUpsert = """
  insert into learned_estimates (
      scope, command_stats_id, schema_version,
      conservative_memory_bytes, recent_peak_memory_bytes,
      sample_count, last_outcome, updated_unix_millis,
      max_observed_peak_bytes, declared_cap_bytes, declared_by_uid,
      declared_unix_millis, last_breach_cap_bytes, last_breach_peak_bytes,
      last_breach_unix_millis
    ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    on conflict(scope, command_stats_id, schema_version) do update set
      conservative_memory_bytes = excluded.conservative_memory_bytes,
      recent_peak_memory_bytes = excluded.recent_peak_memory_bytes,
      sample_count = excluded.sample_count,
      last_outcome = excluded.last_outcome,
      updated_unix_millis = excluded.updated_unix_millis,
      max_observed_peak_bytes = excluded.max_observed_peak_bytes,
      declared_cap_bytes = excluded.declared_cap_bytes,
      declared_by_uid = excluded.declared_by_uid,
      declared_unix_millis = excluded.declared_unix_millis,
      last_breach_cap_bytes = excluded.last_breach_cap_bytes,
      last_breach_peak_bytes = excluded.last_breach_peak_bytes,
      last_breach_unix_millis = excluded.last_breach_unix_millis"""

proc storedInt(value: uint64): SqlValue =
  ## An unsigned figure as the store's signed 64-bit integer, SATURATING at
  ## `int64.high`. A plain `cast` turns 2^63 and above into a negative
  ## number, which `loadLearnedEstimates` cannot parse as unsigned and then
  ## skips -- so one oversized client-reported peak would make the whole row
  ## vanish at the next start. No real figure reaches the saturation.
  sqlInt(if value > uint64(high(int64)): high(int64) else: int64(value))

proc upsertStatement(row: LearnedEstimateRow): BoundStatement =
  ## The one upsert of a row, every value bound. Shared by the background
  ## writer and the synchronous write, so the two cannot store a row
  ## differently.
  bound(estimateUpsert,
    sqlText(row.scope), sqlText(row.commandStatsId),
    sqlInt(int64(EstimateSchemaVersion)),
    storedInt(row.conservativeMemoryBytes),
    storedInt(row.recentPeakMemoryBytes),
    sqlInt(int64(row.sampleCount)), sqlInt(int64(row.lastOutcome)),
    storedInt(row.updatedUnixMillis),
    storedInt(row.maxObservedPeakBytes),
    storedInt(row.declaredCapBytes),
    storedInt(row.declaredByUid),
    storedInt(row.declaredUnixMillis),
    storedInt(row.lastBreachCapBytes),
    storedInt(row.lastBreachPeakBytes),
    storedInt(row.lastBreachUnixMillis))

proc writeBatch(path: string; rows: seq[LearnedEstimateRow]): bool =
  ## Commits ``rows`` in one transaction on a pooled connection, every value
  ## bound. Returns whether they actually landed.
  if rows.len == 0:
    return true
  var statements: seq[BoundStatement] = @[]
  for row in rows:
    statements.add(upsertStatement(row))
  runBound(path, statements).ok

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

proc estimateRowsWritten*(): uint64 =
  ## Rows the background writer has committed since the process started:
  ## how often the store is actually written, which the refresh interval
  ## keeps below the finish rate. Rows written synchronously
  ## (`writeEstimateNow`) are not counted.
  ensureWriterLock()
  acquire(writerLock)
  try:
    writerRowsWritten
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
  ## The key, then the twelve numbers. Written and read in this module only.
  pendingKey(row.scope, row.commandStatsId) &
    $row.conservativeMemoryBytes & "," & $row.recentPeakMemoryBytes & "," &
    $row.sampleCount & "," & $row.lastOutcome & "," & $row.updatedUnixMillis &
    "," & $row.maxObservedPeakBytes & "," & $row.declaredCapBytes & "," &
    $row.declaredByUid & "," & $row.declaredUnixMillis & "," &
    $row.lastBreachCapBytes & "," & $row.lastBreachPeakBytes & "," &
    $row.lastBreachUnixMillis

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
    updatedUnixMillis: parseUInt(numbers[4]),
    maxObservedPeakBytes: parseUInt(numbers[5]),
    declaredCapBytes: parseUInt(numbers[6]),
    declaredByUid: parseUInt(numbers[7]),
    declaredUnixMillis: parseUInt(numbers[8]),
    lastBreachCapBytes: parseUInt(numbers[9]),
    lastBreachPeakBytes: parseUInt(numbers[10]),
    lastBreachUnixMillis: parseUInt(numbers[11]))

proc takePendingRows(): seq[LearnedEstimateRow] =
  ## Empties the queue. REQUIRES ``writerLock``. The rows come back as
  ## ordinary Nim values allocated on the CALLING thread, so the batch the
  ## writer then hands to SQLite is owned by the thread that frees it.
  for encoded in writerPending.takeAll():
    result.add(decodePending(encoded))

type
  DecisionFigures = object
    ## The figures of a row that some decision reads: the conservative
    ## figure (admission's fallback estimate), the largest measured peak
    ## (the learned memory cap) and the last breach's cap and peak (what a
    ## report says was exceeded). The breach's TIME is not among them: a
    ## command that keeps passing the same cap by the same amount records
    ## a new time on every finish, and that is bookkeeping like the sample
    ## count. A new breach, or one with a different cap or peak, differs
    ## here and is committed at once.
    ##
    ## The declaration figures are not compared: a declaration is written
    ## synchronously (`writeEstimateNow`) and never reaches this queue, and
    ## learning never changes them.
    conservative, maxPeak, breachCap, breachPeak: uint64

  KeyState = object
    committedAt: MonoTime
      ## When this key's last row was COMMITTED. Stamped only after the
      ## batch landed, so a row lost to a failed batch or to the pending
      ## queue's cap does not hold the key's next row back.
    committed: DecisionFigures
      ## The decision figures that commit carried. A row whose figures
      ## differ is committed at once, whatever the time.
    waiting: bool
    row: LearnedEstimateRow
      ## The newest held-back row of this key while `waiting`; reset to an
      ## empty row as soon as it stops waiting, so a key that is not
      ## waiting costs only its figures and its commit time.
    due: MonoTime

  DueEntry = object
    due: MonoTime
    key: string

  RefreshState = object
    ## The writer's own bookkeeping for the refresh interval. Created,
    ## used and freed on the writer thread alone -- never under
    ## `writerLock` and never by a connection worker -- so it may be
    ## ordinary Nim containers: the cross-thread ownership problem the
    ## pending queue has does not arise. A key absent from `keys` has not
    ## been committed within the interval, which is what lets `prune`
    ## forget it.
    ##
    ## SIZE. `keys` holds every key committed within about one interval
    ## (prune runs once per interval, so up to two), which is bounded by the
    ## rate at which distinct keys finish, NOT by
    ## `DefaultEstimateWaitingCapacity`: that caps only the keys holding a
    ## row back. A key not waiting holds no row. The table starts empty
    ## with each writer, so after a restart every key's first finish is
    ## committed at once.
    keys: Table[string, KeyState]
    dueOrder: HeapQueue[DueEntry]
      ## Waiting keys by due time. Entries are not removed when a key stops
      ## waiting; one whose key no longer waits with that due time is
      ## skipped when it reaches the top.
    waitingCount: int
    nextPrune: MonoTime

proc `<`(a, b: DueEntry): bool = a.due < b.due

proc decisionFigures(row: LearnedEstimateRow): DecisionFigures =
  DecisionFigures(conservative: row.conservativeMemoryBytes,
    maxPeak: row.maxObservedPeakBytes, breachCap: row.lastBreachCapBytes,
    breachPeak: row.lastBreachPeakBytes)

proc refreshInterval(): Duration =
  initDuration(milliseconds = writerRefreshMillis)

proc takeWaiting(state: var RefreshState; key: string;
                 batch: var seq[LearnedEstimateRow]) =
  ## Send `key`'s held-back row to the store with `batch`.
  state.keys.withValue(key, entry):
    if entry.waiting:
      batch.add(entry.row)
      entry.row = LearnedEstimateRow()
      entry.waiting = false
      dec state.waitingCount

proc popValid(state: var RefreshState): string =
  ## The waiting key due first, removed from `dueOrder`; "" when none
  ## waits. Stale entries are dropped on the way.
  while state.dueOrder.len > 0:
    let top = state.dueOrder.pop()
    state.keys.withValue(top.key, entry):
      if entry.waiting and entry.due == top.due:
        return top.key
  ""

proc admit(state: var RefreshState; rows: seq[LearnedEstimateRow];
           now: MonoTime; stopping: bool): seq[LearnedEstimateRow] =
  ## The rows to commit in this pass: each queued row that is new, carries
  ## changed decision figures, or whose key's last commit is an interval
  ## old; every held-back row that has come due (all of them when
  ## `stopping`); and, when holding a row back would pass the capacity,
  ## the longest-waiting one. The rest are held back, newest per key.
  for row in rows:
    let key = pendingKey(row.scope, row.commandStatsId)
    var holdBack = false
    state.keys.withValue(key, entry):
      holdBack = entry.committed == decisionFigures(row) and
        now - entry.committedAt < refreshInterval()
      if holdBack:
        if not entry.waiting:
          entry.waiting = true
          entry.due = entry.committedAt + refreshInterval()
          inc state.waitingCount
          state.dueOrder.push(DueEntry(due: entry.due, key: key))
        entry.row = row
      elif entry.waiting:
        # This row is newer than the held-back one and carries all of it;
        # the held-back one must never reach the store after it.
        entry.row = LearnedEstimateRow()
        entry.waiting = false
        dec state.waitingCount
    if not holdBack:
      result.add(row)
    while state.waitingCount > writerWaitingCapacity:
      let oldest = state.popValid()
      if oldest.len == 0: break
      state.takeWaiting(oldest, result)
  # The heap's top is the earliest due time, stale or not, so when it is not
  # due nothing is.
  while state.dueOrder.len > 0 and (stopping or state.dueOrder[0].due <= now):
    let top = state.dueOrder.pop()
    var current = false
    state.keys.withValue(top.key, entry):
      current = entry.waiting and entry.due == top.due
    if current:
      state.takeWaiting(top.key, result)

proc noteCommitted(state: var RefreshState; batch: seq[LearnedEstimateRow];
                   now: MonoTime) =
  ## Stamp each committed row's key: committed now, with these figures.
  for row in batch:
    let key = pendingKey(row.scope, row.commandStatsId)
    let figures = decisionFigures(row)
    var entry = addr state.keys.mgetOrPut(key, KeyState())
    entry.committedAt = now
    entry.committed = figures

proc prune(state: var RefreshState; now: MonoTime) =
  ## Forget keys committed more than an interval ago that hold nothing
  ## back: an absent key is treated exactly like one of them. Once per
  ## interval, in one pass over the table, on the writer thread.
  if now < state.nextPrune:
    return
  state.nextPrune = now + refreshInterval()
  var stale: seq[string] = @[]
  for key, entry in state.keys:
    if not entry.waiting and now - entry.committedAt >= refreshInterval():
      stale.add(key)
  for key in stale:
    state.keys.del(key)

proc writerMain() {.thread.} =
  {.cast(gcsafe).}:
    # THE SCHEMA IS ENSURED ONCE PER WRITER, not once per batch: it is a
    # `create table if not exists` and a journal-mode switch, and running
    # them every 50 ms was one more round trip into SQLite per batch for
    # nothing. A failure is retried with the next batch.
    var schemaReady = false
    var refresh = RefreshState()
    try:
      while true:
        sleep(50)
        var queued: seq[LearnedEstimateRow] = @[]
        var shouldStop = false
        acquire(writerLock)
        try:
          shouldStop = writerStop
          if writerPending.len > 0:
            queued = takePendingRows()
        finally:
          release(writerLock)
        # THE REFRESH INTERVAL IS APPLIED HERE, outside the lock, so a
        # finish's enqueue does no more than it did before it existed. The
        # stop takes every held-back row: a clean stop loses nothing.
        let now = getMonoTime()
        let batch = refresh.admit(queued, now, stopping = shouldStop)
        refresh.prune(now)
        if batch.len > 0 and writerDbPath.len > 0:
          # THE RESULT IS CHECKED. `discard writeBatch(...)` was the line
          # that made a whole batch failing to reach the store look exactly
          # like a batch that committed.
          if not schemaReady:
            schemaReady = initEstimateSchema(writerDbPath)
          let landed = schemaReady and writeBatch(writerDbPath, batch)
          if landed:
            refresh.noteCommitted(batch, getMonoTime())
            acquire(writerLock)
            try:
              writerRowsWritten += uint64(batch.len)
            finally:
              release(writerLock)
          else:
            noteEstimateWriteFailure(batch.len)
            # A FAILED BATCH RE-ENSURES THE SCHEMA ON THE NEXT ONE. The store
            # may have been deleted or replaced under the writer -- the pool
            # then reopens the path, onto a file with no table in it -- and
            # the per-batch ensure this replaced recreated it there.
            schemaReady = false
        if shouldStop:
          break
    finally:
      discard

proc startEstimateStore*(path: string; queueCapacity = 128;
    refreshIntervalMillis = DefaultEstimateRefreshIntervalMillis;
    waitingCapacity = DefaultEstimateWaitingCapacity): EstimateStore =
  ## Start the background writer for the store at `path` (none for an empty
  ## path: estimates are then kept in memory only). The interval and the
  ## held-back capacity are the defaults everywhere but the tests that
  ## exercise them.
  ensureWriterLock()
  if path.len == 0:
    return EstimateStore(mode: pmInMemory, dbPath: "", queueCapacity: 0)
  acquire(writerLock)
  try:
    writerDbPath = path
    writerCapacity = max(1, queueCapacity)
    writerStop = false
    writerRefreshMillis = refreshIntervalMillis
    writerWaitingCapacity = max(0, waitingCapacity)
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

proc durableWrite(store: EstimateStore;
                  statement: BoundStatement): string =
  ## Runs one statement against the store NOW, on the caller's thread, in
  ## its own committed transaction, and answers "" once it is durable or
  ## the reason it is not. A store in memory only (tests that disable
  ## persistence) has nothing to write and answers "".
  if store.isNil or store.mode != pmSqlite:
    return ""
  if not initEstimateSchema(store.dbPath):
    return "the estimate store " & store.dbPath & " has no usable schema"
  let outcome = runBound(store.dbPath, [statement])
  if outcome.ok: ""
  else: "the estimate store " & store.dbPath & " did not commit the write: " &
    outcome.error

proc writeEstimateNow*(store: EstimateStore; row: LearnedEstimateRow): string =
  ## Upsert `row` SYNCHRONOUSLY, bypassing the bounded writer queue, and
  ## answer "" only once it is committed (WAL), else why not.
  ##
  ## FOR ROWS THAT MUST NOT BE LOST. The queue drops its oldest row when it
  ## is full and loses what it holds if the daemon dies before a drain,
  ## which is right for learned figures -- a lost sample is relearned --
  ## and wrong for a growth declaration, which an operator made on purpose
  ## and expects to find recorded. Declarations are rare operator commands,
  ## not admission, so a write on their request path costs nothing that
  ## matters. A row written here is never also queued.
  durableWrite(store, upsertStatement(row))

proc deleteEstimateNow*(store: EstimateStore; scope,
                        commandStatsId: string): string =
  ## Delete one row SYNCHRONOUSLY, as `writeEstimateNow` writes one: a
  ## cleared declaration holds nothing else, so it leaves no row behind.
  durableWrite(store, bound("delete from learned_estimates where " &
    "scope = ? and command_stats_id = ? and schema_version = ?",
    sqlText(scope), sqlText(commandStatsId),
    sqlInt(int64(EstimateSchemaVersion))))

proc stopEstimateStore*(store: EstimateStore) =
  if store.isNil or store.mode != pmSqlite:
    return
  acquire(writerLock)
  try:
    writerStop = true
  finally:
    release(writerLock)
  joinThread(writerThread)
  # THE WRITER HAS STOPPED, so its pooled connection is idle and nothing
  # will take it again: closing it checkpoints the log into the estimate
  # store's file and releases the file for whoever opens it next.
  closePooledConnections(store.dbPath)
