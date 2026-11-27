import std/[locks, os, strutils, times]

import runquota_core/process_owned
import runquota_core/sqlite_inproc

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

proc writerMain() {.thread.} =
  {.cast(gcsafe).}:
    # THE SCHEMA IS ENSURED ONCE PER WRITER, not once per batch: it is a
    # `create table if not exists` and a journal-mode switch, and running
    # them every 50 ms was one more round trip into SQLite per batch for
    # nothing. A failure is retried with the next batch.
    var schemaReady = false
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
          # THE RESULT IS CHECKED. `discard writeBatch(...)` was the line
          # that made a whole batch failing to reach the store look exactly
          # like a batch that committed.
          if not schemaReady:
            schemaReady = initEstimateSchema(writerDbPath)
          let landed = schemaReady and writeBatch(writerDbPath, batch)
          if not landed:
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
