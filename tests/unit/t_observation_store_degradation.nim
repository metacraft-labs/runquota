## M9 gate, clause 4 (store half), and OS-4: a deliberately truncated or
## corrupted store degrades to no capture with a clear report.
##
## The "and a build over it still SUCCEEDS" half of the clause cannot be
## proven here — it needs a real daemon and a real build — and is in
## `tests/integration/t_observation_store_degraded_capture_build.nim`.
##
## Every degradation mode the daemon can meet is exercised against the real
## thing: a real truncated file, a real overwritten header, a real missing
## SQLite library, a real unwritable path. None of them may raise, and
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

import std/[os, osproc, strtabs, strutils, times, unittest]

import runquota_observation_store

proc scratchDir(name: string): string =
  result = getTempDir() / ("runquota-obs-" & name & "-" &
    $getCurrentProcessId() & "-" & $epochTime())
  removeDir(result)
  createDir(result)

const noLibraryFlag = "--open-without-sqlite-library"

proc noLibraryEnv(library: string): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    result[key] = value
  result["RUNQUOTA_SQLITE_LIBRARY"] = library

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
  # THE STORE'S CONNECTIONS ARE CLOSED BEFORE ANY CASE TAMPERS WITH THE FILE,
  # as the daemon closes them when it stops. SQLite runs in this process and
  # keeps a pooled connection open, so until it is closed the committed rows
  # may still sit in the `-wal` sidecar and a later open would read page 1
  # from there rather than from the bytes a case has just overwritten. The
  # close checkpoints them into the main file, which is then what the
  # `sqlite3` tool's exits used to leave behind.
  closePooledConnections(path)

proc truncateFile(path: string; newSize: int) =
  let data = readFile(path)
  writeFile(path, data[0 ..< min(newSize, data.len)])

proc healthyRow(store: ObservationStore): bool =
  store.insertHost(HostRow(hostId: "h-new", createdAtUnixMillis: 2,
    lastBootId: "b"))

if paramCount() >= 2 and paramStr(1) == noLibraryFlag:
  # THE CHILD of "no SQLite library degrades to no capture".
  let store = openObservationStore(paramStr(2))
  echo "available=", sqliteToolAvailable()
  echo "status=", store.status
  echo "capture=", store.captureEnabled
  echo "report=", store.report
  echo "healthy=", store.healthyRow()
  quit(0)

suite "observation_store_degradation":
  test "a truncated store degrades to no capture with a clear report":
    let dir = scratchDir("truncated")
    defer:
      closePooledConnections()
      removeDir(dir)
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
    defer:
      closePooledConnections()
      removeDir(dir)
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
    defer:
      closePooledConnections()
      removeDir(dir)
    let path = dir / "observations.sqlite"
    writeFile(path, "this is not a database, it is a note to self\n")
    let store = openObservationStore(path)
    check store.status == ssCorrupt
    check not store.captureEnabled
    check not store.healthyRow()

  test "a corrupt page behind an intact header is still caught":
    let dir = scratchDir("midpage")
    defer:
      closePooledConnections()
      removeDir(dir)
    let path = dir / "observations.sqlite"
    seed(path)
    # Fold the WAL back so the damage below lands in the file SQLite reads.
    check runSqlite(path, "pragma wal_checkpoint(truncate);").ok

    var data = readFile(path)
    check data.len > 16384
    # A PAGE HEADER half way in, and well clear of page 1 — so the file
    # header, `sqlite_master` and `user_version` all survive intact.
    #
    # ALIGNED TO THE PAGE, not to 512 bytes, and the difference is the
    # point. The midpoint used to be sector-aligned only, which happened to
    # be a page boundary for as long as the file had an even number of
    # pages. Schema version 6 added a table, the file grew by one page, and
    # the same arithmetic landed 2048 bytes into an EMPTY index page -- in
    # bytes no cell and no header covers, where damage is legitimately
    # invisible to `quick_check`. Which bytes a midpoint hits is a property
    # of the schema, not of the store's corruption handling, so the damage
    # now always starts at a page boundary: every b-tree page has a header
    # there, and a damaged one is what `quick_check` reports.
    #
    # A NAMED PAGE, NOT THE MIDDLE ONE. Schema version 7 added a table and
    # an index, and the midpoint moved onto `extension_registry`, which the
    # store reads while it opens: the damage was then caught by that read
    # before `quick_check` ran, which is still a refusal but not the one
    # this case is about. The page is now the root of an index that nothing
    # reads at open (`executions_by_command_stats_id`), found by name, so
    # the next table a migration adds cannot move it.
    let pageSize = (int(byte(data[16])) shl 8) or int(byte(data[17]))
    check pageSize >= 1024
    check data.len mod pageSize == 0
    let root = runSqlite(path, "select rootpage from sqlite_master where " &
      "name = 'executions_by_command_stats_id';")
    check root.ok
    let start = (parseInt(root.output.strip()) - 1) * pageSize
    check start >= 4 * pageSize
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

  test "no SQLite library degrades to no capture":
    # The library is loaded once, when the process starts, so the absence is
    # arranged for a CHILD: this binary, re-executed with
    # `RUNQUOTA_SQLITE_LIBRARY` naming a file that does not exist, which
    # makes it the only candidate. The child opens a store and reports.
    let dir = scratchDir("nosqlite")
    defer:
      closePooledConnections()
      removeDir(dir)
    let (text, code) = execCmdEx(quoteShell(getAppFilename()) & " " &
      noLibraryFlag & " " & quoteShell(dir / "observations.sqlite"),
      env = noLibraryEnv(dir / "no-such-libsqlite3.so"))
    checkpoint text
    check code == 0
    check "available=false" in text
    check ("status=" & $ssNoSqliteTool) in text
    check "capture=false" in text
    check "capture disabled" in text
    check "no-such-libsqlite3.so" in text
    check "healthy=false" in text
    # Nothing was created: a store that could not be opened is not touched.
    check not fileExists(dir / "observations.sqlite")

  test "a library that is not SQLite is passed over, not called":
    # `RUNQUOTA_SQLITE_LIBRARY` names a library that loads but is not
    # SQLite: the C library, already mapped into every process. Every
    # binding must resolve before any is used, so the candidate is refused
    # by name and the store degrades. Falsifying mutation: accept a
    # candidate once `dlopen` succeeds, without resolving the bindings --
    # the child then calls a nil function pointer and dies.
    let dir = scratchDir("notsqlite")
    defer:
      closePooledConnections()
      removeDir(dir)
    # The C library's name is per-OS: `libc.so.6` is a glibc soname and does
    # not load on macOS, where the always-present non-SQLite library is
    # libSystem; Windows has no `.so`/glibc and no `dlopen` search for one,
    # but `kernel32.dll` is, the same way, already mapped into every
    # process. The case needs one that LOADS and lacks the bindings.
    when defined(macosx):
      const notSqlite = "/usr/lib/libSystem.B.dylib"
    elif defined(windows):
      const notSqlite = "kernel32.dll"
    else:
      const notSqlite = "libc.so.6"
    let (text, code) = execCmdEx(quoteShell(getAppFilename()) & " " &
      noLibraryFlag & " " & quoteShell(dir / "observations.sqlite"),
      env = noLibraryEnv(notSqlite))
    checkpoint text
    check code == 0
    check "available=false" in text
    check "capture=false" in text
    check (notSqlite & ": has no sqlite3_") in text
    check not fileExists(dir / "observations.sqlite")

  test "the library in use is reported with its version":
    # The other side of the two cases above: the library the dev shell and
    # the Nix build record loads, and the report names it and its version.
    let library = getEnv("RUNQUOTA_SQLITE_LIBRARY")
    check library.len > 0
    if library.len > 0:
      let dir = scratchDir("withsqlite")
      defer:
        closePooledConnections()
        removeDir(dir)
      let (text, code) = execCmdEx(quoteShell(getAppFilename()) & " " &
        noLibraryFlag & " " & quoteShell(dir / "observations.sqlite"),
        env = noLibraryEnv(library))
      checkpoint text
      check code == 0
      check "available=true" in text
      check "capture=true" in text
      check "SQLite 3." in sqliteLibraryReport()
      check library in sqliteLibraryReport()

  test "an unwritable location degrades to no capture":
    let dir = scratchDir("unwritable")
    defer:
      closePooledConnections()
      removeDir(dir)
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
    defer:
      closePooledConnections()
      removeDir(dir)
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
    defer:
      closePooledConnections()
      removeDir(dir)
    let path = dir / "observations.sqlite"
    seed(path)
    let store = openObservationStore(path)
    let copyPath = dir / "copy.sqlite"
    check store.backupTo(copyPath)
    let restored = openObservationStore(copyPath)
    check restored.status == ssOpen
    check restored.readExecutions().len == 200
    check restored.readHosts() == store.readHosts()
