## A very small SQLite access layer built on the ``sqlite3`` command-line
## tool.
##
## Why the CLI and not a linked library: ``runquota_persistence`` already
## reaches SQLite this way for learned estimates, so this adds no new build
## or link dependency to a daemon that must keep working when the store does
## not. A missing tool is an ordinary, catchable condition here, which is
## what OS-4 ("degrade, never fail") needs; a missing shared library would
## be a load-time abort.
##
## Values crossing this boundary are encoded so that no textual delimiter
## can ever appear inside a value: text is written as ``cast(x'..' as text)``
## and read back as ``hex()``, integers and reals are written and read as
## digits, and SQL ``NULL`` is read back as a single ``~``. The column
## separator is therefore never ambiguous.

import std/[os, osproc, streams, strutils]

const
  sqliteTool* = "sqlite3"
  nullMarker* = "~"

type
  SqliteOutcome* = object
    ok*: bool
    exitCode*: int
    output*: string
    error*: string

proc sqliteToolAvailable*(): bool =
  findExe(sqliteTool).len > 0

# `foreign_keys` keeps the spine's parent links real; `synchronous = normal`
# trades a crash-window of recent observations for not fsyncing on every
# batch. Both are per-connection settings and so must be repeated on every
# invocation. Losing the last few observations to a power cut is precisely
# the trade OS-1 already makes on the hot path.
const sqlitePreamble =
  "pragma foreign_keys = on;\npragma synchronous = normal;\n"

proc runSqlite*(dbPath, sql: string): SqliteOutcome =
  ## Runs ``sql`` against ``dbPath``. Never raises: a failure to even start
  ## the tool is reported as ``ok == false`` with the reason in ``error``.
  ##
  ## The statements go in over **stdin**, not as an argument. A drained
  ## batch of observations is easily larger than the operating system's
  ## argument limit, and passing it as `argv` made a large batch fail as a
  ## whole while a small one succeeded — a size-dependent failure with no
  ## natural test to catch it.
  result = SqliteOutcome(ok: false, exitCode: -1, output: "", error: "")
  var process: Process
  try:
    process = startProcess(
      sqliteTool,
      args = ["-batch", "-noheader", "-bail", dbPath],
      options = {poUsePath}
    )
  except CatchableError as error:
    result.error = "cannot run " & sqliteTool & ": " & error.msg
    return
  except Defect as error:
    result.error = "cannot run " & sqliteTool & ": " & error.msg
    return
  try:
    let input = process.inputStream
    input.write(sqlitePreamble)
    input.write(sql)
    input.write("\n")
    input.flush()
    input.close()
    result.output = process.outputStream.readAll()
    result.error = process.errorStream.readAll()
    result.exitCode = process.waitForExit()
    result.ok = result.exitCode == 0
  except CatchableError as error:
    result.error = "running " & sqliteTool & " failed: " & error.msg
  finally:
    process.close()

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
