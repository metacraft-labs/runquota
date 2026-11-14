## The observation store's SQLite access layer.
##
## The module keeps its historical name: it used to run the ``sqlite3``
## command-line tool once per call. It now runs SQLite IN THIS PROCESS,
## through ``runquota_core/sqlite_inproc``, which documents how the library
## is found, why it is loaded rather than linked (a missing library degrades
## to no capture, as a missing tool did), and the connection and threading
## rules.
##
## Two shapes of call reach it:
##
## * SQL text this library composed itself -- schema, migrations,
##   maintenance, the offline tools. ``runSqlite`` runs it on a fresh
##   connection with the tool's ``-bail`` semantics, and returns the rows in
##   the tool's list format, so every reader written against the tool reads
##   the same bytes.
## * Statements with BOUND VALUES (``sqlite_inproc.BoundStatement`` in its
##   byte form). Every value that arrives from a client -- an observed row,
##   an extension row, a stats key in a query -- travels this way and never
##   becomes SQL text. ``runSqlite`` recognises the byte form and runs it on
##   a pooled connection in one transaction.
##
## The text encoders below remain for the first shape: text is written as
## ``cast(x'..' as text)`` and read back as ``hex()``, integers and reals as
## digits, and SQL ``NULL`` reads back as a single ``~``, so the column
## separator is never ambiguous.

import std/strutils

import runquota_core/sqlite_inproc

export sqlite_inproc

const
  nullMarker* = "~"
  sqliteTool* = "sqlite3"
    ## The command-line tool's name. Nothing in RunQuota runs it any more;
    ## it is kept for tests that drive the tool directly against a store.

type
  SqliteOutcome* = object
    ok*: bool
    exitCode*: int
      ## 0 on success, 1 on a failure -- what the tool's exit status said,
      ## kept so the callers written against it read the same.
    output*: string
    error*: string

proc sqliteToolAvailable*(): bool =
  ## Whether SQLite can be used at all. The name is historical; it now asks
  ## whether the library was loaded (``sqlite_inproc.sqliteAvailable``).
  sqliteAvailable()

proc toOutcome(outcome: SqlOutcome): SqliteOutcome =
  SqliteOutcome(ok: outcome.ok, exitCode: (if outcome.ok: 0 else: 1),
    output: outcome.output, error: outcome.error)

proc runSqlite*(dbPath, sql: string): SqliteOutcome {.gcsafe.} =
  ## Runs ``sql`` against ``dbPath``. Never raises. SQL text runs on a fresh
  ## connection, statement by statement, stopping at the first failure,
  ## which rolls back whatever that script had open. Bound statements
  ## (``isBound``) run on a pooled connection in one transaction.
  if sql.isBound:
    toOutcome(runBoundEncoded(dbPath, sql))
  else:
    toOutcome(runSqlScript(dbPath, sql))

proc querySqlite*(dbPath, sql: string;
                  params: openArray[SqlValue]): SqliteOutcome {.gcsafe.} =
  ## One read whose ``?`` parameters are bound to ``params``, on a pooled
  ## connection. For a read that carries a client's value.
  toOutcome(queryBound(dbPath, sql, params))

proc encodeText*(value: string): string =
  ## SQL literal for a text value, immune to quoting and to embedded
  ## newlines, quotes and separators.
  if value.len == 0:
    return "''"
  "cast(x'" & value.toHex() & "' as text)"

proc encodeInt*(value: int64): string =
  $value

proc encodeFloat*(value: float64): string =
  ## Nim renders floats with the shortest round-tripping representation.
  $value

proc selectText*(column: string): string =
  "case when " & column & " is null then '" & nullMarker &
    "' else 'x' || hex(" & column & ") end"

proc selectInt*(column: string): string =
  "case when " & column & " is null then '" & nullMarker &
    "' else cast(" & column & " as text) end"

proc selectFloat*(column: string): string =
  "case when " & column & " is null then '" & nullMarker &
    "' else printf('%!.17g', " & column & ") end"

proc decodeText*(field: string): string =
  if field == nullMarker or field.len == 0:
    return ""
  parseHexStr(field[1 .. ^1])

proc isNullField*(field: string): bool =
  field == nullMarker

proc splitRows*(output: string): seq[seq[string]] =
  for line in output.splitLines():
    if line.len > 0:
      result.add(line.split('|'))
