## In-process SQLite for the daemon's stores.
##
## RunQuota used to reach SQLite by running the ``sqlite3`` command-line
## tool once per batch, per query and per publication. Each run is a fork,
## an exec, a dynamic link and a schema parse, and the daemon made about
## 170 of them for one 64-action build: most of the cost of recording
## observations at all. This module replaces them with the library itself,
## called in this process.
##
## HOW THE LIBRARY IS FOUND, AND WHY IT IS LOADED RATHER THAN LINKED.
##
## ``libsqlite3`` is opened with ``dlopen`` at module initialisation, not
## named on the link line. A missing library must stay what a missing
## ``sqlite3`` tool was: an ordinary condition that turns capture off and
## says why, while the daemon goes on admitting and releasing leases
## (observation store invariant "degrade, never fail"). A library on the
## link line would make its absence a load-time abort of the whole daemon,
## and the packages ship SQLite as a recommended, not a required, dependency
## for exactly that reason. Vendoring the amalgamation was the other option;
## it would compile about nine megabytes of C into every binary and test
## that touches a store, and make this project responsible for SQLite's
## security fixes.
##
## The candidates, first match wins:
##
## 1. ``RUNQUOTA_SQLITE_LIBRARY`` in this process's environment. When it is
##    set it is the ONLY candidate, so an operator (or a test) can point the
##    daemon at one library, or at none. Loading a library runs its code in
##    this process, so the variable carries exactly the trust of
##    ``LD_PRELOAD``: whoever sets the daemon's environment (its service
##    unit) may already run code as the daemon's user, and nothing is gained
##    or lost. The one case where that is not so is a process the kernel
##    marks secure-execution (set-user-ID, set-group-ID or file
##    capabilities: ``AT_SECURE``, see getauxval(3)), whose environment came
##    from a less trusted caller; there the variable is IGNORED, as the
##    dynamic loader ignores ``LD_PRELOAD``, and the report says so.
## 2. The path the build recorded: ``RUNQUOTA_SQLITE_LIBRARY`` in the
##    BUILD's environment, or ``-d:runquotaSqliteLibrary=PATH``. The Nix
##    package and dev shell set it to nixpkgs' ``libsqlite3``, which also
##    makes that library part of the package's runtime closure.
## 3. The platform's usual names (``libsqlite3.so.0``, ``libsqlite3.dylib``,
##    ``sqlite3.dll``), resolved by the system loader.
##
## A candidate is ACCEPTED only when every function below resolves, its
## version is at least ``minimumSqliteVersion`` (the newest SQL feature the
## stores use is ``vacuum into``, 3.27.0; upserts need 3.24.0), and it was
## built thread-safe (``sqlite3_threadsafe() != 0``): a library built with
## ``SQLITE_THREADSAFE=0`` has no mutexes at all and is unsafe with two
## connections on two threads, which is exactly how the daemon uses it
## (https://www.sqlite.org/threadsafe.html). A candidate that fails any
## check is passed over, and the next one tried.
##
## CONNECTIONS AND THREADS.
##
## Two kinds of call, with two connection rules:
##
## * ``runSqlScript`` runs a script of SQL text and is the drop-in for what
##   the tool did. It opens a FRESH connection, runs the script and closes
##   it, which is exactly the tool's semantics: a script that fails half
##   way through a transaction is rolled back by the close, an ``attach``
##   or a temporary table dies with the connection, and nothing a script
##   does can leak into the next one. It is used for schema work,
##   migrations, maintenance and the offline tools, none of which is on a
##   per-build path.
## * ``runBound`` and ``queryBound`` run statements with BOUND PARAMETERS on
##   a POOLED connection. They are the per-build paths: the observation
##   writer's batches, ambient samples, learned estimates and the aggregate
##   publisher's reads. Values never become SQL text there.
##
## A pooled connection belongs to one thread at a time: it is taken out of
## the pool for one call and put back afterwards, so no two threads ever use
## it at once. It is opened in SQLite's serialized mode
## (``SQLITE_OPEN_FULLMUTEX``) all the same, so a connection handed from one
## thread to the next needs nothing of the threading mode the library was
## built with. A connection is put back only when it is clean -- no
## transaction open -- and is checked against the file it was opened on
## (device and inode) before it is reused, so a store that was deleted or
## replaced underneath it is reopened rather than written into a file that
## no longer has a name.
##
## Every connection sets what the tool's preamble set on each run: a 5 s
## busy timeout (the daemon has several writers against one store, and under
## WAL a second writer is refused at once rather than queued), foreign keys
## on, and ``synchronous = normal``.
##
## NOTHING HERE RAISES. Every failure, including a library that could not be
## loaded, comes back as ``ok == false`` with the reason in ``error``.
##
## The C interface used is documented at https://www.sqlite.org/c3ref/intro.html.

import std/[dynlib, locks, os, strutils]

when defined(posix):
  import std/posix

const runquotaSqliteLibrary {.strdefine.} = ""
  ## The build-recorded library path; see the module header.

const builtSqliteLibrary =
  when runquotaSqliteLibrary.len > 0: runquotaSqliteLibrary
  else: getEnv("RUNQUOTA_SQLITE_LIBRARY")

const sqliteLibraryVariable* = "RUNQUOTA_SQLITE_LIBRARY"

const
  minimumSqliteVersion* = 3_027_000
    ## ``sqlite3_libversion_number()`` of 3.27.0, for ``vacuum into``.
  minimumSqliteVersionText = "3.27.0"

when defined(linux):
  proc getauxval(kind: culong): culong {.importc, header: "<sys/auxv.h>".}
  const AT_SECURE = 23.culong
elif defined(macosx) or defined(bsd):
  proc issetugid(): cint {.importc, header: "<unistd.h>".}

proc secureExecution(): bool =
  ## Whether this process was started set-user-ID, set-group-ID or with
  ## file capabilities, so that its environment is not to be trusted.
  when defined(linux):
    getauxval(AT_SECURE) != 0
  elif defined(macosx) or defined(bsd):
    issetugid() != 0
  else:
    false

const platformSqliteNames =
  when defined(windows): ["sqlite3.dll", "winsqlite3.dll"]
  elif defined(macosx): ["libsqlite3.dylib", "/usr/lib/libsqlite3.dylib"]
  else: ["libsqlite3.so.0", "libsqlite3.so"]

const
  SQLITE_OK = 0.cint
  SQLITE_ROW = 100.cint
  SQLITE_DONE = 101.cint
  SQLITE_INTEGER = 1.cint
  SQLITE_FLOAT = 2.cint
  SQLITE_TEXT = 3.cint
  SQLITE_BLOB = 4.cint
  SQLITE_NULL = 5.cint
  SQLITE_OPEN_READWRITE = 0x00000002.cint
  SQLITE_OPEN_CREATE = 0x00000004.cint
  SQLITE_OPEN_FULLMUTEX = 0x00010000.cint
  busyTimeoutMillis = 5000.cint

let SQLITE_TRANSIENT = cast[pointer](-1)

type
  Db = pointer
  Stmt = pointer

  OpenV2 = proc (filename: cstring; db: ptr Db; flags: cint;
                 vfs: cstring): cint {.cdecl, gcsafe.}
  CloseV2 = proc (db: Db): cint {.cdecl, gcsafe.}
  PrepareV2 = proc (db: Db; sql: cstring; nbytes: cint; stmt: ptr Stmt;
                    tail: ptr cstring): cint {.cdecl, gcsafe.}
  StepFn = proc (stmt: Stmt): cint {.cdecl, gcsafe.}
  StmtFn = proc (stmt: Stmt): cint {.cdecl, gcsafe.}
  BindNull = proc (stmt: Stmt; index: cint): cint {.cdecl, gcsafe.}
  BindInt64 = proc (stmt: Stmt; index: cint; value: int64): cint {.cdecl, gcsafe.}
  BindDouble = proc (stmt: Stmt; index: cint; value: float64): cint {.cdecl, gcsafe.}
  BindBytes = proc (stmt: Stmt; index: cint; value: pointer; n: cint;
                    destructor: pointer): cint {.cdecl, gcsafe.}
  ColumnCount = proc (stmt: Stmt): cint {.cdecl, gcsafe.}
  ColumnInt = proc (stmt: Stmt; index: cint): cint {.cdecl, gcsafe.}
  ColumnInt64 = proc (stmt: Stmt; index: cint): int64 {.cdecl, gcsafe.}
  ColumnDouble = proc (stmt: Stmt; index: cint): float64 {.cdecl, gcsafe.}
  ColumnPtr = proc (stmt: Stmt; index: cint): pointer {.cdecl, gcsafe.}
  DbText = proc (db: Db): cstring {.cdecl, gcsafe.}
  DbInt = proc (db: Db): cint {.cdecl, gcsafe.}
  BusyTimeout = proc (db: Db; ms: cint): cint {.cdecl, gcsafe.}
  ExtendedCodes = proc (db: Db; onoff: cint): cint {.cdecl, gcsafe.}
  LibVersion = proc (): cstring {.cdecl, gcsafe.}
  LibInt = proc (): cint {.cdecl, gcsafe.}

var
  sqlOpen: OpenV2
  sqlClose: CloseV2
  sqlPrepare: PrepareV2
  sqlStep: StepFn
  sqlReset: StmtFn
  sqlClearBindings: StmtFn
  sqlFinalize: StmtFn
  sqlBindNull: BindNull
  sqlBindInt64: BindInt64
  sqlBindDouble: BindDouble
  sqlBindText: BindBytes
  sqlBindBlob: BindBytes
  sqlColumnCount: ColumnCount
  sqlColumnType: ColumnInt
  sqlColumnInt64: ColumnInt64
  sqlColumnDouble: ColumnDouble
  sqlColumnText: ColumnPtr
  sqlColumnBlob: ColumnPtr
  sqlColumnBytes: ColumnInt
  sqlErrmsg: DbText
  sqlExtendedErrcode: DbInt
  sqlGetAutocommit: DbInt
  sqlBusyTimeout: BusyTimeout
  sqlExtendedResultCodes: ExtendedCodes
  sqlLibVersion: LibVersion
  sqlLibVersionNumber: LibInt
  sqlThreadsafe: LibInt
  libraryLoaded = false
  libraryReportBuffer: array[1024, char]
    ## Which library was loaded, or why none was. A fixed buffer and not a
    ## ``string`` so that the module-level state holds no reference into any
    ## thread's heap; see ``process_owned`` for why that matters here.

proc setReport(text: string) =
  let n = min(text.len, libraryReportBuffer.len - 1)
  for i in 0 ..< n:
    libraryReportBuffer[i] = text[i]
  libraryReportBuffer[n] = '\0'

proc sqliteLibraryReport*(): string =
  ## One line: the library in use and its version, or why there is none.
  $cast[cstring](addr libraryReportBuffer[0])

proc sqliteAvailable*(): bool =
  ## Whether a SQLite library was loaded. When this is false every call
  ## below fails, cleanly, and the stores degrade to no capture.
  libraryLoaded

proc loadFrom(path: string; problem: var string): bool =
  let handle = loadLib(path)
  if handle.isNil:
    problem = path & ": cannot be loaded"
    return false
  template bindSym(target: untyped; name: string) =
    let address = handle.symAddr(name)
    if address.isNil:
      problem = path & ": has no " & name
      unloadLib(handle)
      return false
    target = cast[typeof(target)](address)
  bindSym(sqlOpen, "sqlite3_open_v2")
  bindSym(sqlClose, "sqlite3_close_v2")
  bindSym(sqlPrepare, "sqlite3_prepare_v2")
  bindSym(sqlStep, "sqlite3_step")
  bindSym(sqlReset, "sqlite3_reset")
  bindSym(sqlClearBindings, "sqlite3_clear_bindings")
  bindSym(sqlFinalize, "sqlite3_finalize")
  bindSym(sqlBindNull, "sqlite3_bind_null")
  bindSym(sqlBindInt64, "sqlite3_bind_int64")
  bindSym(sqlBindDouble, "sqlite3_bind_double")
  bindSym(sqlBindText, "sqlite3_bind_text")
  bindSym(sqlBindBlob, "sqlite3_bind_blob")
  bindSym(sqlColumnCount, "sqlite3_column_count")
  bindSym(sqlColumnType, "sqlite3_column_type")
  bindSym(sqlColumnInt64, "sqlite3_column_int64")
  bindSym(sqlColumnDouble, "sqlite3_column_double")
  bindSym(sqlColumnText, "sqlite3_column_text")
  bindSym(sqlColumnBlob, "sqlite3_column_blob")
  bindSym(sqlColumnBytes, "sqlite3_column_bytes")
  bindSym(sqlErrmsg, "sqlite3_errmsg")
  bindSym(sqlExtendedErrcode, "sqlite3_extended_errcode")
  bindSym(sqlGetAutocommit, "sqlite3_get_autocommit")
  bindSym(sqlBusyTimeout, "sqlite3_busy_timeout")
  bindSym(sqlExtendedResultCodes, "sqlite3_extended_result_codes")
  bindSym(sqlLibVersion, "sqlite3_libversion")
  bindSym(sqlLibVersionNumber, "sqlite3_libversion_number")
  bindSym(sqlThreadsafe, "sqlite3_threadsafe")
  let version = int(sqlLibVersionNumber())
  if version < minimumSqliteVersion:
    problem = path & ": SQLite " & $sqlLibVersion() & " is older than " &
      minimumSqliteVersionText
    unloadLib(handle)
    return false
  if sqlThreadsafe() == 0:
    problem = path & ": SQLite was built without thread safety " &
      "(SQLITE_THREADSAFE=0)"
    unloadLib(handle)
    return false
  # The handle is deliberately never unloaded: the bindings above point
  # into it for the rest of the process's life.
  true

proc loadSqliteLibrary() =
  ## Runs once, at module initialisation, before this process has created
  ## any thread -- so the bindings are written single-threaded and only ever
  ## read afterwards.
  var candidates: seq[string] = @[]
  var overridden = getEnv(sqliteLibraryVariable)
  var ignored = ""
  if overridden.len > 0 and secureExecution():
    ignored = "; " & sqliteLibraryVariable &
      " ignored in a secure-execution process"
    overridden = ""
  if overridden.len > 0:
    candidates.add(overridden)
  else:
    if builtSqliteLibrary.len > 0:
      candidates.add(builtSqliteLibrary)
    for name in platformSqliteNames:
      candidates.add(name)
  var problems: seq[string] = @[]
  for candidate in candidates:
    var problem = ""
    if loadFrom(candidate, problem):
      libraryLoaded = true
      setReport("SQLite " & $sqlLibVersion() & " from " & candidate & ignored)
      return
    problems.add(problem)
  let reason =
    if overridden.len > 0:
      sqliteLibraryVariable & "=" & overridden & " (" & problems.join("; ") & ")"
    else:
      "no SQLite library could be loaded (" & problems.join("; ") & ")"
  setReport(reason & ignored)

loadSqliteLibrary()

# ---------------------------------------------------------------------------
# Values and bound statements
# ---------------------------------------------------------------------------

type
  SqlValueKind* = enum
    svNull, svInt, svFloat, svText, svBlob

  SqlValue* = object
    case kind*: SqlValueKind
    of svNull: discard
    of svInt: intValue*: int64
    of svFloat: floatValue*: float64
    of svText, svBlob: bytes*: string

  BoundStatement* = object
    ## One statement and the values for its ``?`` parameters, in order.
    sql*: string
    params*: seq[SqlValue]

  SqlOutcome* = object
    ## What a call left behind. ``output`` is the rows in the tool's list
    ## format: columns joined by ``|``, one row per line, SQL ``NULL`` as
    ## the empty string.
    ok*: bool
    output*: string
    error*: string
    errorCode*: int
      ## SQLite's extended result code for the failure; 0 when ``ok`` or
      ## when no connection could be had at all.

proc sqlNull*(): SqlValue = SqlValue(kind: svNull)
proc sqlInt*(value: int64): SqlValue = SqlValue(kind: svInt, intValue: value)
proc sqlFloat*(value: float64): SqlValue =
  SqlValue(kind: svFloat, floatValue: value)
proc sqlText*(value: string): SqlValue = SqlValue(kind: svText, bytes: value)
proc sqlBlob*(value: string): SqlValue = SqlValue(kind: svBlob, bytes: value)

proc bound*(sql: string; params: varargs[SqlValue]): BoundStatement =
  BoundStatement(sql: sql, params: @params)

# THE BYTE FORM. The observation writer's queues hold bytes in the C heap
# (``process_owned``), never Nim objects, so a bound statement has to be
# written down as bytes to travel through them. Each record starts with
# ``boundMarker``, which no SQL text starts with, and records CONCATENATE:
# the bytes of two lists, appended, are the bytes of the joined list. That
# is what lets a batch be assembled by appending what each row produced.
const boundMarker* = '\x01'

proc putU32(target: var string; value: int) =
  let v = uint32(value)
  for shift in [0, 8, 16, 24]:
    target.add(char((v shr shift) and 0xff'u32))

proc putU64(target: var string; value: uint64) =
  for shift in countup(0, 56, 8):
    target.add(char((value shr shift) and 0xff'u64))

proc getU32(source: string; at: var int; value: var int): bool =
  if at + 4 > source.len:
    return false
  var v = 0'u32
  for i in 0 .. 3:
    v = v or (uint32(ord(source[at + i])) shl (8 * i))
  at += 4
  value = int(v)
  true

proc getU64(source: string; at: var int; value: var uint64): bool =
  if at + 8 > source.len:
    return false
  var v = 0'u64
  for i in 0 .. 7:
    v = v or (uint64(ord(source[at + i])) shl (8 * i))
  at += 8
  value = v
  true

proc encodeBound*(statement: BoundStatement): string =
  ## The byte form of one statement; see ``decodeBound``.
  result = newStringOfCap(statement.sql.len + 16 * statement.params.len + 9)
  result.add(boundMarker)
  result.putU32(statement.sql.len)
  result.add(statement.sql)
  result.putU32(statement.params.len)
  for value in statement.params:
    result.add(char(ord(value.kind)))
    case value.kind
    of svNull: discard
    of svInt: result.putU64(cast[uint64](value.intValue))
    of svFloat: result.putU64(cast[uint64](value.floatValue))
    of svText, svBlob:
      result.putU32(value.bytes.len)
      result.add(value.bytes)

proc encodeBound*(statements: openArray[BoundStatement]): string =
  for statement in statements:
    result.add(encodeBound(statement))

proc isBound*(text: string): bool =
  ## Whether ``text`` is the byte form of bound statements rather than SQL.
  text.len > 0 and text[0] == boundMarker

proc decodeBound*(encoded: string; statements: var seq[BoundStatement]): bool =
  ## Appends the statements ``encoded`` holds. False on bytes that are not a
  ## complete encoding, in which case nothing reliable was decoded.
  var at = 0
  while at < encoded.len:
    if encoded[at] != boundMarker:
      return false
    inc at
    var length = 0
    if not getU32(encoded, at, length) or at + length > encoded.len:
      return false
    var statement = BoundStatement(sql: encoded[at ..< at + length])
    at += length
    var count = 0
    if not getU32(encoded, at, count):
      return false
    for _ in 0 ..< count:
      if at >= encoded.len:
        return false
      let tag = ord(encoded[at])
      inc at
      if tag > ord(high(SqlValueKind)):
        return false
      case SqlValueKind(tag)
      of svNull:
        statement.params.add(sqlNull())
      of svInt, svFloat:
        var raw = 0'u64
        if not getU64(encoded, at, raw):
          return false
        statement.params.add(
          if SqlValueKind(tag) == svInt: sqlInt(cast[int64](raw))
          else: sqlFloat(cast[float64](raw)))
      of svText, svBlob:
        var n = 0
        if not getU32(encoded, at, n) or at + n > encoded.len:
          return false
        let bytes = encoded[at ..< at + n]
        at += n
        statement.params.add(
          if SqlValueKind(tag) == svText: sqlText(bytes) else: sqlBlob(bytes))
    statements.add(statement)
  true

proc renderSql*(statement: BoundStatement): string =
  ## A readable rendering, for diagnostics and tests only: the SQL with its
  ## parameter values listed after it. Never executed.
  result = statement.sql
  if statement.params.len > 0:
    var shown: seq[string] = @[]
    for value in statement.params:
      shown.add(case value.kind
        of svNull: "null"
        of svInt: $value.intValue
        of svFloat: $value.floatValue
        of svText: value.bytes
        of svBlob: "blob(" & $value.bytes.len & ")")
    result.add(" -- [" & shown.join(", ") & "]")

# ---------------------------------------------------------------------------
# Connections
# ---------------------------------------------------------------------------

proc failure(db: Db; context: string): SqlOutcome =
  let message =
    if db.isNil: "out of memory"
    else: $sqlErrmsg(db)
  let code = if db.isNil: 7 else: int(sqlExtendedErrcode(db))
  SqlOutcome(ok: false, error:
    (if context.len > 0: context & ": " else: "") & message &
      " (" & $code & ")", errorCode: code)

proc configure(db: Db): SqlOutcome =
  discard sqlExtendedResultCodes(db, 1)
  discard sqlBusyTimeout(db, busyTimeoutMillis)
  for pragma in ["pragma foreign_keys = on", "pragma synchronous = normal"]:
    var stmt: Stmt = nil
    if sqlPrepare(db, cstring(pragma), -1, addr stmt, nil) != SQLITE_OK:
      return failure(db, "")
    let rc = sqlStep(stmt)
    discard sqlFinalize(stmt)
    if rc != SQLITE_DONE and rc != SQLITE_ROW:
      return failure(db, "")
  result = SqlOutcome(ok: true)

proc openConnection(path: string; db: var Db): SqlOutcome =
  db = nil
  if not libraryLoaded:
    return SqlOutcome(ok: false, error: sqliteLibraryReport())
  let rc = sqlOpen(cstring(path), addr db,
    SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE or SQLITE_OPEN_FULLMUTEX, nil)
  if rc != SQLITE_OK:
    result = failure(db, "cannot open " & path)
    if not db.isNil:
      discard sqlClose(db)
      db = nil
    return
  result = configure(db)
  if not result.ok:
    discard sqlClose(db)
    db = nil

proc closeConnection(db: Db) =
  if not db.isNil:
    discard sqlClose(db)

# THE POOL. Plain values only -- raw pointers, numbers, and the path in the
# C heap -- so this module-level state belongs to no thread's heap and any
# thread may take a connection out of it or put one back. ``poolLock`` is
# armed at module initialisation, before any thread exists.
proc cMalloc(size: csize_t): pointer {.importc: "malloc", header: "<stdlib.h>".}
proc cFree(p: pointer) {.importc: "free", header: "<stdlib.h>".}

const poolCapacity = 8

type
  FileIdentity = object
    known: bool
    device: uint64
    inode: uint64
    writable: bool
      ## Whether this process may write the file now (``access(W_OK)``). A
      ## store made read-only while a connection is open would otherwise
      ## keep accepting writes through the descriptor opened earlier, where
      ## the tool, opening the path afresh on every run, failed -- and that
      ## failure is how a store that stopped accepting writes degrades.

  PoolEntry = object
    db: Db
    path: ptr UncheckedArray[char]
    pathLen: int
    identity: FileIdentity
    busy: bool
    lastUsed: int64
      ## ``useClock`` when the entry was last put back, for eviction.

  Lease = object
    db: Db
    slot: int
    identity: FileIdentity

var
  poolLock: Lock
  pool: array[poolCapacity, PoolEntry]
  useClock = 0'i64
  connectionsOpened = 0'i64
    ## Connections opened by ``runBound``/``queryBound``, for the tests that
    ## assert the per-build paths reuse rather than reopen.

initLock(poolLock)

proc fileIdentity(path: string): FileIdentity =
  when defined(posix):
    var info: Stat
    if stat(cstring(path), info) == 0:
      return FileIdentity(known: true, device: uint64(info.st_dev),
        inode: uint64(info.st_ino),
        writable: access(cstring(path), W_OK) == 0)
  FileIdentity(known: false)

proc samePath(entry: PoolEntry; path: string): bool =
  if entry.path.isNil or entry.pathLen != path.len:
    return false
  for i in 0 ..< path.len:
    if entry.path[i] != path[i]:
      return false
  true

proc pooledConnectionsOpened*(): int64 =
  ## How many pooled connections this process has opened so far.
  {.cast(gcsafe).}:
    acquire(poolLock)
    try:
      connectionsOpened
    finally:
      release(poolLock)

proc acquireConnection(path: string; lease: var Lease): SqlOutcome =
  ## A connection to ``path`` for this thread's exclusive use until
  ## ``releaseConnection``.
  {.cast(gcsafe).}:
    let identity = fileIdentity(path)
    var stale: seq[Db] = @[]
    lease = Lease(db: nil, slot: -1)
    acquire(poolLock)
    try:
      for i in 0 ..< poolCapacity:
        if pool[i].db.isNil or pool[i].busy or not pool[i].samePath(path):
          continue
        let current = pool[i].identity
        if identity.known and current.known and
            identity.device == current.device and
            identity.inode == current.inode and
            identity.writable == current.writable:
          pool[i].busy = true
          lease = Lease(db: pool[i].db, slot: i, identity: current)
          break
        # THE FILE CHANGED UNDER THIS CONNECTION -- deleted, replaced by
        # another file of the same name, or made (un)writable. The tool opened the path afresh on
        # every run and so always wrote into the file the name names now; a
        # cached connection must do the same, not keep writing into an
        # unlinked inode.
        stale.add(pool[i].db)
        pool[i].db = nil
    finally:
      release(poolLock)
    for db in stale:
      closeConnection(db)
    if not lease.db.isNil:
      return SqlOutcome(ok: true)
    var db: Db = nil
    result = openConnection(path, db)
    if not result.ok:
      return
    acquire(poolLock)
    try:
      inc connectionsOpened
    finally:
      release(poolLock)
    lease = Lease(db: db, slot: -1, identity: fileIdentity(path))

proc releaseConnection(path: string; lease: var Lease; reusable: bool) =
  ## Puts the connection back, or closes it. A connection with a transaction
  ## still open (a failed statement whose rollback also failed) is never put
  ## back: the next caller would find itself inside someone else's
  ## transaction.
  {.cast(gcsafe).}:
    if lease.db.isNil:
      return
    let clean = reusable and sqlGetAutocommit(lease.db) != 0
    var toClose: Db = nil
    acquire(poolLock)
    try:
      inc useClock
      if lease.slot >= 0:
        if clean:
          pool[lease.slot].busy = false
          pool[lease.slot].lastUsed = useClock
        else:
          pool[lease.slot].db = nil
          pool[lease.slot].busy = false
          toClose = lease.db
      elif clean:
        # A FREE SLOT, or else the least recently used IDLE one, whose
        # connection is closed to make room. Without eviction a pool filled
        # by stores nobody uses any more -- a test's scratch stores, a
        # store that was merged from once -- would leave every NEW store
        # unpooled, reopened on every call, and closed (checkpointing its
        # log) after each.
        var target = -1
        for i in 0 ..< poolCapacity:
          if pool[i].db.isNil:
            target = i
            break
        var evicted: Db = nil
        if target < 0:
          for i in 0 ..< poolCapacity:
            if not pool[i].busy and
                (target < 0 or pool[i].lastUsed < pool[target].lastUsed):
              target = i
          if target >= 0:
            evicted = pool[target].db
            pool[target].db = nil
        if target < 0:
          # Every slot is in use by another thread: this one is not kept.
          toClose = lease.db
        else:
          if not pool[target].path.isNil:
            cFree(pool[target].path)
          pool[target].path = cast[ptr UncheckedArray[char]](
            cMalloc(csize_t(max(1, path.len))))
          if pool[target].path.isNil:
            # No memory to remember the path in: close both rather than
            # keep a connection nothing can find again.
            pool[target].pathLen = 0
            toClose = lease.db
            if not evicted.isNil:
              closeConnection(evicted)
              evicted = nil
          else:
            for j in 0 ..< path.len:
              pool[target].path[j] = path[j]
            pool[target].pathLen = path.len
            pool[target].db = lease.db
            pool[target].identity = lease.identity
            pool[target].busy = false
            pool[target].lastUsed = useClock
            toClose = evicted
      else:
        toClose = lease.db
    finally:
      release(poolLock)
    closeConnection(toClose)
    lease = Lease(db: nil, slot: -1)

proc closePooledConnections*(path = "") =
  ## Closes every idle pooled connection (to ``path`` only, when given). The
  ## daemon calls it once its writers have stopped, so the last close
  ## checkpoints the write-ahead log as the tool's exits used to; tests call
  ## it before they move or inspect a store's files.
  {.cast(gcsafe).}:
    var toClose: seq[Db] = @[]
    acquire(poolLock)
    try:
      for i in 0 ..< poolCapacity:
        if pool[i].db.isNil or pool[i].busy:
          continue
        if path.len > 0 and not pool[i].samePath(path):
          continue
        toClose.add(pool[i].db)
        pool[i].db = nil
    finally:
      release(poolLock)
    for db in toClose:
      closeConnection(db)

# ---------------------------------------------------------------------------
# Running statements
# ---------------------------------------------------------------------------

proc appendRow(stmt: Stmt; output: var string) =
  let columns = sqlColumnCount(stmt)
  for column in 0 ..< columns:
    if column > 0:
      output.add('|')
    let kind = sqlColumnType(stmt, column)
    if kind == SQLITE_NULL:
      continue
    let data =
      if kind == SQLITE_BLOB: sqlColumnBlob(stmt, column)
      else: sqlColumnText(stmt, column)
    let n = sqlColumnBytes(stmt, column)
    if data.isNil or n <= 0:
      continue
    let start = output.len
    output.setLen(start + n)
    copyMem(addr output[start], data, n)
  output.add('\n')

proc stepAll(db: Db; stmt: Stmt; output: var string): SqlOutcome =
  while true:
    let rc = sqlStep(stmt)
    if rc == SQLITE_ROW:
      appendRow(stmt, output)
    elif rc == SQLITE_DONE:
      return SqlOutcome(ok: true)
    else:
      return failure(db, "")

var emptyBytes: array[1, char]
  ## What an EMPTY text or blob is bound from. ``sqlite3_bind_text`` and
  ## ``sqlite3_bind_blob`` with a nil pointer bind SQL NULL, not an empty
  ## value (https://www.sqlite.org/c3ref/bind_blob.html), and an empty
  ## string is a real value here -- a host with no share group, a run with
  ## no workspace -- that a NOT NULL column accepts and NULL it refuses.

proc bytesOf(value: SqlValue): pointer =
  if value.bytes.len > 0: unsafeAddr value.bytes[0]
  else: addr emptyBytes[0]

proc bindParams(db: Db; stmt: Stmt; params: openArray[SqlValue]): SqlOutcome =
  for i, value in params:
    let index = cint(i + 1)
    let rc =
      case value.kind
      of svNull: sqlBindNull(stmt, index)
      of svInt: sqlBindInt64(stmt, index, value.intValue)
      of svFloat: sqlBindDouble(stmt, index, value.floatValue)
      of svText:
        sqlBindText(stmt, index, bytesOf(value), cint(value.bytes.len),
          SQLITE_TRANSIENT)
      of svBlob:
        sqlBindBlob(stmt, index, bytesOf(value), cint(value.bytes.len),
          SQLITE_TRANSIENT)
    if rc != SQLITE_OK:
      return failure(db, "binding parameter " & $(i + 1))
  result = SqlOutcome(ok: true)

proc execSimple(db: Db; sql: string): SqlOutcome =
  var stmt: Stmt = nil
  if sqlPrepare(db, cstring(sql), -1, addr stmt, nil) != SQLITE_OK:
    return failure(db, "")
  var output = ""
  result = stepAll(db, stmt, output)
  discard sqlFinalize(stmt)

proc rollbackIfOpen(db: Db) =
  if not db.isNil and sqlGetAutocommit(db) == 0:
    discard execSimple(db, "rollback")

proc runSqlScript*(path, sql: string): SqlOutcome {.gcsafe.} =
  ## Runs a script of SQL text against ``path`` on a fresh connection, the
  ## way the ``sqlite3`` tool ran it with ``-batch -bail``: statement by
  ## statement, stopping at the first that fails, every row of every
  ## statement in ``output``. Bound statements (``isBound``) are accepted
  ## too and run as ``runBound`` does.
  ##
  ## The script is SQL the caller composed itself -- schema, migrations,
  ## maintenance, the offline tools. A value that came from a client goes
  ## through ``runBound`` or ``queryBound`` instead.
  {.cast(gcsafe).}:
    var db: Db = nil
    result = openConnection(path, db)
    if not result.ok:
      return
    defer: closeConnection(db)
    var output = ""
    var remaining = 0
    let text = cstring(sql)
    var cursor = text
    let total = sql.len
    while true:
      remaining = total - (cast[int](cursor) - cast[int](text))
      if remaining <= 0:
        break
      var stmt: Stmt = nil
      var tail: cstring = nil
      # THE LENGTH INCLUDES THE TERMINATOR (a Nim string is NUL-terminated).
      # Without it SQLite cannot tell the text is terminated and copies the
      # whole remainder before compiling one statement, which made a script
      # of N statements cost O(N^2): a seeded store of a hundred thousand
      # rows took minutes to write.
      if sqlPrepare(db, cursor, cint(remaining + 1), addr stmt, addr tail) !=
          SQLITE_OK:
        result = failure(db, "")
        result.output = output
        return
      if tail.isNil or tail == cursor:
        if not stmt.isNil:
          discard sqlFinalize(stmt)
        break
      cursor = tail
      if stmt.isNil:
        # Whitespace or a comment: nothing to run.
        continue
      let stepped = stepAll(db, stmt, output)
      discard sqlFinalize(stmt)
      if not stepped.ok:
        # The close in the ``defer`` rolls back whatever was open, exactly as
        # the tool's exit did.
        result = stepped
        result.output = output
        return
    result = SqlOutcome(ok: true, output: output)

proc runOnLease(db: Db; statements: openArray[BoundStatement];
                transaction: bool; output: var string): SqlOutcome =
  # ONE PREPARED STATEMENT PER DISTINCT TEXT IN THE CALL. A batch is mostly
  # many rows of the same few inserts; each is compiled once and then reset
  # and re-bound per row.
  var prepared: seq[(string, Stmt)] = @[]
  defer:
    for (_, stmt) in prepared:
      discard sqlFinalize(stmt)
  if transaction:
    let began = execSimple(db, "begin immediate")
    if not began.ok:
      return began
  for statement in statements:
    var stmt: Stmt = nil
    for (text, candidate) in prepared:
      if text == statement.sql:
        stmt = candidate
        break
    if stmt.isNil:
      var tail: cstring = nil
      let text = cstring(statement.sql)
      if sqlPrepare(db, text, cint(statement.sql.len + 1),
          addr stmt, addr tail) != SQLITE_OK or stmt.isNil:
        result = failure(db, "")
        rollbackIfOpen(db)
        return
      prepared.add((statement.sql, stmt))
      # ONE STATEMENT PER BOUND STATEMENT. ``sqlite3_prepare_v2`` compiles
      # the first statement and reports where the rest begins; running only
      # the first of several would be a silent partial write, so anything
      # after it but whitespace and semicolons is refused.
      if not tail.isNil:
        let consumed = cast[int](tail) - cast[int](text)
        for i in consumed ..< statement.sql.len:
          if statement.sql[i] notin {' ', '\t', '\n', '\r', ';'}:
            result = SqlOutcome(ok: false, error:
              "a bound statement holds more than one statement: " &
                statement.sql)
            rollbackIfOpen(db)
            return
    else:
      discard sqlReset(stmt)
      discard sqlClearBindings(stmt)
    result = bindParams(db, stmt, statement.params)
    if result.ok:
      result = stepAll(db, stmt, output)
    if not result.ok:
      rollbackIfOpen(db)
      return
  if transaction:
    result = execSimple(db, "commit")
    if not result.ok:
      rollbackIfOpen(db)
      return
  result = SqlOutcome(ok: true)

proc runBound*(path: string; statements: openArray[BoundStatement];
               transaction = true): SqlOutcome {.gcsafe.} =
  ## Runs ``statements`` with their bound values on a pooled connection, in
  ## one ``begin immediate`` transaction unless ``transaction`` is false. On
  ## any failure the transaction is rolled back and nothing is written.
  {.cast(gcsafe).}:
    if statements.len == 0:
      return SqlOutcome(ok: true)
    var lease: Lease
    result = acquireConnection(path, lease)
    if not result.ok:
      return
    var output = ""
    result = runOnLease(lease.db, statements, transaction, output)
    result.output = output
    releaseConnection(path, lease, reusable = true)

proc runBoundEncoded*(path, encoded: string;
                      transaction = true): SqlOutcome {.gcsafe.} =
  ## ``runBound`` over the byte form (``encodeBound``).
  var statements: seq[BoundStatement] = @[]
  if not decodeBound(encoded, statements):
    return SqlOutcome(ok: false, error: "malformed bound statement bytes")
  runBound(path, statements, transaction)

proc queryBound*(path, sql: string;
                 params: openArray[SqlValue]): SqlOutcome {.gcsafe.} =
  ## One read with bound values on a pooled connection, rows in ``output``.
  {.cast(gcsafe).}:
    var lease: Lease
    result = acquireConnection(path, lease)
    if not result.ok:
      return
    var output = ""
    result = runOnLease(lease.db, [BoundStatement(sql: sql, params: @params)],
      transaction = false, output)
    result.output = output
    releaseConnection(path, lease, reusable = true)
