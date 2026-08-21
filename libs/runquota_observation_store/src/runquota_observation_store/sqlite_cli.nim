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

import std/[os, osproc, strutils]

import runquota_core/child_process

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
#
# A busy timeout exists because the daemon now has TWO writers against one
# store: the observation writer draining executions and the ambient sampler
# flushing samples. Under WAL a second writer is refused immediately rather
# than queued, and that refusal is not a constraint rejection -- `execute`
# would read it as a store that has stopped working and turn capture off
# for everyone. Waiting is the correct response to a lock somebody else
# holds for the length of one batch.
#
# It is set with the `.timeout` DOT-COMMAND and not with `pragma
# busy_timeout`, because the pragma RETURNS A ROW: it would prepend "5000"
# to the output of every statement that followed it, and the first casualty
# was `pragma user_version`, which then read back as `5000\n0` and made
# every store on the machine look like it had an unreadable schema version.
const sqlitePreamble =
  ".timeout 5000\npragma foreign_keys = on;\npragma synchronous = normal;\n"

proc runSqlite*(dbPath, sql: string): SqliteOutcome =
  ## Runs ``sql`` against ``dbPath``. Never raises: a failure to even start
  ## the tool is reported as ``ok == false`` with the reason in ``error``.
  ##
  ## The statements go in over **stdin**, not as an argument. A drained
  ## batch of observations is easily larger than the operating system's
  ## argument limit, and passing it as `argv` made a large batch fail as a
  ## whole while a small one succeeded — a size-dependent failure with no
  ## natural test to catch it.
  ##
  ## All three pipes are serviced CONCURRENTLY, which is what
  ## `runquota_core/child_process` exists to guarantee, along with taking the
  ## spawn guard so a concurrent spawn elsewhere in the daemon cannot inherit
  ## these pipes. Both defects and the reasoning behind them are documented
  ## there; this proc is now only the `sqlite3`-specific part -- the argv, the
  ## preamble, and the outcome shape the store expects.
  let captured = runCapturedProcess(
    sqliteTool,
    args = ["-batch", "-noheader", "-bail", dbPath],
    input = sqlitePreamble & sql & "\n",
    options = {poUsePath}
  )
  if captured.failure.len > 0:
    return SqliteOutcome(
      ok: false, exitCode: -1, output: "", error: captured.failure)
  SqliteOutcome(
    ok: captured.ok,
    exitCode: captured.exitCode,
    output: captured.output,
    error: captured.error
  )

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
