import std/[locks, os, osproc, strutils, times]

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
var writerPending: seq[LearnedEstimateRow] = @[]
var writerThread: Thread[void]

proc ensureWriterLock() =
  if not writerReady:
    initLock(writerLock)
    writerReady = true

proc nowUnixMillis*(): uint64 =
  uint64(epochTime() * 1000)

proc sqlQuote(value: string): string =
  "'" & value.replace("'", "''") & "'"

proc runSqlite(path, sqlText: string): string =
  let parent = parentDir(path)
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)
  execProcess("sqlite3", args = [path, sqlText], options = {poUsePath})

proc initEstimateSchema(path: string) =
  discard runSqlite(path, """
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
  """)

proc loadLearnedEstimates*(path: string): seq[LearnedEstimateRow] =
  if path.len == 0 or not fileExists(path):
    return @[]
  initEstimateSchema(path)
  let output = runSqlite(path, """
    select scope, command_stats_id, conservative_memory_bytes,
           recent_peak_memory_bytes, sample_count, last_outcome,
           updated_unix_millis
      from learned_estimates
     where schema_version = """ & $EstimateSchemaVersion & """;
  """)
  for line in output.splitLines():
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

proc writeBatch(path: string; rows: seq[LearnedEstimateRow]) =
  if rows.len == 0:
    return
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
  discard runSqlite(path, sqlText)

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
            batch = writerPending
            writerPending = @[]
        finally:
          release(writerLock)
        if batch.len > 0 and writerDbPath.len > 0:
          initEstimateSchema(writerDbPath)
          writeBatch(writerDbPath, batch)
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
    writerPending = @[]
  finally:
    release(writerLock)
  createThread(writerThread, writerMain)
  EstimateStore(mode: pmSqlite, dbPath: path, queueCapacity: queueCapacity)

proc enqueueEstimateWrite*(store: EstimateStore; row: LearnedEstimateRow): bool =
  if store.isNil or store.mode != pmSqlite:
    return true
  acquire(writerLock)
  try:
    for i, pending in writerPending:
      if pending.scope == row.scope and pending.commandStatsId == row.commandStatsId:
        writerPending[i] = row
        return true
    if writerPending.len >= writerCapacity:
      writerPending.delete(0)
    writerPending.add(row)
    true
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
