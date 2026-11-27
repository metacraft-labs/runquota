## The learned-estimate store gains the memory-cap figures WITHOUT FORGETTING
## WHAT IT HAD LEARNED.
##
## `schema_version` is a key column of `learned_estimates`, so bumping
## `EstimateSchemaVersion` would orphan every row a host had learned: the
## reader selects one version. The memory-cap figures (the largest successful
## peak, the declaration with its uid and time, the last breach) are added as
## columns with a default of 0 instead, and the version stays 1.
##
## WHAT IS GUARDED.
##
## 1. A store written by the schema as it shipped before the change -- the
##    DDL below is a frozen copy, so this test cannot pass by the library
##    agreeing with itself -- keeps its rows when the current library opens
##    it: they load with their old figures and 0 in every new one.
## 2. The writer then upserts the new figures into those same rows, and
##    they read back exactly, through the real background writer.
## 3. Opening twice adds nothing twice (the schema step is idempotent).
##
## Falsifying mutation: bump `EstimateSchemaVersion` to 2 (the obvious
## "migration") -- case 1 then loads no rows at all.
##
## NO MOCKS: real SQLite files, the production writer thread.

import std/[os, sequtils, strutils, tempfiles, unittest]

import runquota_core/sqlite_inproc
import runquota_persistence

const shippedSchema = """
create table learned_estimates (
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
insert into learned_estimates values
  ('session:runquota run', 'cc foo.c', 1, 1250, 1000, 3, 0, 1700000000000);
"""

proc waitForRow(path, key: string; field: proc(row: LearnedEstimateRow): bool):
    bool =
  ## The writer drains every 50 ms; give it a generous bound on a loaded host.
  for _ in 0 ..< 400:
    for row in loadLearnedEstimates(path):
      if row.commandStatsId == key and field(row):
        return true
    sleep(25)
  false

suite "the memory-cap columns of the learned-estimate store":
  test "an old store keeps its rows and takes the new figures":
    let dir = createTempDir("rqmest", "")
    defer: removeDir(dir)
    let path = dir / "est.sqlite"
    check runSqlScript(path, shippedSchema).ok

    let loaded = loadLearnedEstimates(path)
    check loaded.len == 1
    let row = loaded[0]
    check row.scope == "session:runquota run"
    check row.commandStatsId == "cc foo.c"
    check row.conservativeMemoryBytes == 1250'u64
    check row.recentPeakMemoryBytes == 1000'u64
    check row.sampleCount == 3'u32
    check row.maxObservedPeakBytes == 0'u64
    check row.declaredCapBytes == 0'u64
    check row.lastBreachUnixMillis == 0'u64

    # Opening again adds no column twice.
    check loadLearnedEstimates(path).len == 1
    let columns = queryBound(path, "pragma table_info(learned_estimates)", [])
    check columns.ok
    var names: seq[string] = @[]
    for line in columns.output.splitLines():
      let fields = line.split('|')
      if fields.len >= 2: names.add(fields[1])
    for column in MemoryCapColumns:
      check names.count(column) == 1

    var updated = row
    updated.maxObservedPeakBytes = 4_000'u64
    updated.declaredCapBytes = 8_000'u64
    updated.declaredByUid = 1000'u64
    updated.declaredUnixMillis = 1_800_000_000_000'u64
    updated.lastBreachCapBytes = 2_000'u64
    updated.lastBreachPeakBytes = 2_100'u64
    updated.lastBreachUnixMillis = 1_800_000_000_001'u64
    let store = startEstimateStore(path)
    check enqueueEstimateWrite(store, updated)
    check waitForRow(path, "cc foo.c",
      proc(r: LearnedEstimateRow): bool = r.declaredCapBytes == 8_000'u64)
    stopEstimateStore(store)
    let after = loadLearnedEstimates(path)
    check after.len == 1
    check after[0] == updated
