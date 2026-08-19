## M9 gate, clause 4 (store half), and OS-4: a deliberately truncated or
## corrupted store degrades to no capture with a clear report.
##
## The "and a build over it still SUCCEEDS" half of the clause cannot be
## proven here — it needs a real daemon and a real build — and is in
## `tests/integration/t_observation_store_degraded_capture_build.nim`.
##
## Every degradation mode the daemon can meet is exercised against the real
## thing: a real truncated file, a real overwritten header, a real missing
## `sqlite3` on PATH, a real unwritable path. None of them may raise, and
## none of them may repair the file behind the operator's back.
##
## One fixture exists for a reason the others do not cover. Truncation and a
## smashed header also destroy page 1, so `pragma user_version` stops being
## readable and the store degrades through that path whether or not the
## integrity check runs at all — verified by mutation: deleting the
## `pragma quick_check` call leaves every one of those cases still reaching
## `ssCorrupt`, and only the wording of the report notices. "A page in the
## middle is corrupt while page 1 is intact" is the case where the integrity
## check is the ONLY thing standing between the daemon and a store it would
## otherwise open and write into.

import std/[os, strutils, times, unittest]

import runquota_observation_store

proc scratchDir(name: string): string =
  result = getTempDir() / ("runquota-obs-" & name & "-" &
    $getCurrentProcessId() & "-" & $epochTime())
  removeDir(result)
  createDir(result)

proc seed(path: string) =
  let store = openObservationStore(path)
  doAssert store.captureEnabled, store.report
  doAssert store.insertHost(HostRow(hostId: "h1", createdAtUnixMillis: 1,
    lastBootId: "b1"))
  doAssert store.insertRun(RunRow(runId: "r1", hostId: "h1", tool: "tool",
    toolVersion: "1", invocationKind: "build", startedAtUnixMillis: 1,
    captureCompleteness: ccComplete))
  var rows: seq[ExecutionRow] = @[]
  for i in 0 ..< 200:
    rows.add(ExecutionRow(executionId: "e" & $i,
      hostId: "h1", runId: "r1", commandStatsId: "c" & $i,
      startedAtUnixMillis: 10, finishedAtUnixMillis: 20, durationMillis: 10,
      exitStatus: 0, termination: tExited, attempt: 1, peakRssBytes: 1,
      maxProcesses: 1, majorPageFaults: 0, captureCompleteness: ccComplete))
  doAssert store.appendBatch([], rows)

proc truncateFile(path: string; newSize: int) =
  let data = readFile(path)
  writeFile(path, data[0 ..< min(newSize, data.len)])

proc healthyRow(store: ObservationStore): bool =
  store.insertHost(HostRow(hostId: "h-new", createdAtUnixMillis: 2,
    lastBootId: "b"))

suite "observation_store_degradation":
  test "a truncated store degrades to no capture with a clear report":
    let dir = scratchDir("truncated")
    defer: removeDir(dir)
    let path = dir / "observations.sqlite"
    seed(path)
    let originalSize = int(getFileSize(path))
    check originalSize > 8192
    truncateFile(path, originalSize div 2)
    let corruptSize = getFileSize(path)

    let store = openObservationStore(path)
    check store.status == ssCorrupt
    check not store.captureEnabled
    check path in store.report
    check "corrupt" in store.report
    check "capture disabled" in store.report

    # No capture, and no exception on the way there.
    check not store.healthyRow()
    check store.readExecutions().len == 0

    # Not silently repaired: the file is left exactly as it was found, and
    # a second open reaches the same verdict rather than a different one.
    check getFileSize(path) == corruptSize
    check openObservationStore(path).status == ssCorrupt

  test "a store whose header was overwritten degrades the same way":
    let dir = scratchDir("header")
    defer: removeDir(dir)
    let path = dir / "observations.sqlite"
    seed(path)
    var data = readFile(path)
    for i in 0 ..< 100:
      data[i] = 'Z'
    writeFile(path, data)

    let store = openObservationStore(path)
    check store.status == ssCorrupt
    check not store.captureEnabled
    check "capture disabled" in store.report
    check not store.healthyRow()

  test "a store filled with unrelated bytes degrades rather than throwing":
    let dir = scratchDir("garbage")
    defer: removeDir(dir)
    let path = dir / "observations.sqlite"
    writeFile(path, "this is not a database, it is a note to self\n")
    let store = openObservationStore(path)
    check store.status == ssCorrupt
    check not store.captureEnabled
    check not store.healthyRow()

  test "a corrupt page behind an intact header is still caught":
    let dir = scratchDir("midpage")
    defer: removeDir(dir)
    let path = dir / "observations.sqlite"
    seed(path)
    # Fold the WAL back so the damage below lands in the file SQLite reads.
    check runSqlite(path, "pragma wal_checkpoint(truncate);").ok

    var data = readFile(path)
    check data.len > 16384
    # Page-aligned, half way in, and well clear of page 1 — so the header,
    # `sqlite_master` and `user_version` all survive intact.
    let start = (data.len div 2) and not 0x1ff
    check start >= 4096
    for i in start ..< min(start + 512, data.len):
      data[i] = 'Z'
    writeFile(path, data)
    let corruptSize = getFileSize(path)

    # The distinguishing precondition: the schema version is still perfectly
    # readable, so nothing but the integrity check can notice the damage.
    let version = runSqlite(path, "pragma user_version;")
    check version.ok
    check version.output.strip() == $spineSchemaVersion

    let store = openObservationStore(path)
    check store.status == ssCorrupt
    check not store.captureEnabled
    check "corrupt" in store.report
    check "quick_check" in store.report
    check not store.healthyRow()
    check getFileSize(path) == corruptSize

  test "no sqlite3 on PATH degrades to no capture":
    let dir = scratchDir("nosqlite")
    defer: removeDir(dir)
    let emptyBin = dir / "empty-bin"
    createDir(emptyBin)
    let savedPath = getEnv("PATH")
    putEnv("PATH", emptyBin)
    defer: putEnv("PATH", savedPath)
    check not sqliteToolAvailable()
    let store = openObservationStore(dir / "observations.sqlite")
    check store.status == ssNoSqliteTool
    check not store.captureEnabled
    check "capture disabled" in store.report
    check not store.healthyRow()

  test "an unwritable location degrades to no capture":
    let dir = scratchDir("unwritable")
    defer: removeDir(dir)
    # The parent of the store path is a regular file, so the directory can
    # never be created.
    writeFile(dir / "blocker", "not a directory")
    let store = openObservationStore(dir / "blocker" / "observations.sqlite")
    check not store.captureEnabled
    check store.status in {ssUnwritable, ssCorrupt}
    check "capture disabled" in store.report
    check not store.healthyRow()

  test "no configured path is disabled, and says so without alarm":
    let store = openObservationStore("")
    check store.status == ssDisabled
    check not store.captureEnabled
    check "capture disabled" in store.report
    check not store.healthyRow()

  test "a healthy store is not degraded, which is what makes the rest mean something":
    let dir = scratchDir("control")
    defer: removeDir(dir)
    let path = dir / "observations.sqlite"
    seed(path)
    let store = openObservationStore(path)
    check store.status == ssOpen
    check store.captureEnabled
    check "capture enabled" in store.report
    check store.healthyRow()
    check store.readExecutions().len == 200

  test "a live store can be copied and the copy stands alone":
    # docs/database.md requires backup and restore to be stated before this
    # becomes a stable boundary. M15 gates them properly; this is the
    # primitive and the evidence that it produces a usable database.
    let dir = scratchDir("backup")
    defer: removeDir(dir)
    let path = dir / "observations.sqlite"
    seed(path)
    let store = openObservationStore(path)
    let copyPath = dir / "copy.sqlite"
    check store.backupTo(copyPath)
    let restored = openObservationStore(copyPath)
    check restored.status == ssOpen
    check restored.readExecutions().len == 200
    check restored.readHosts() == store.readHosts()
