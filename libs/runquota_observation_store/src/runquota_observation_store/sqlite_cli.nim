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

import ./spawn_guard

const
  sqliteTool* = "sqlite3"
  nullMarker* = "~"

type
  StreamDrain = object
    ## One end of a child pipe plus the text read from it. Passed to a drain
    ## thread by ``ptr``, so the thread argument itself carries no managed
    ## memory.
    stream: Stream
    text: string
    failure: string

proc drainStream(drain: ptr StreamDrain) {.thread.} =
  ## Read one stream to EOF. Never propagates: a thread that let an exception
  ## escape would terminate the process, and this runs inside a daemon whose
  ## whole contract is to degrade rather than fail.
  try:
    drain.text = drain.stream.readAll()
  except CatchableError as error:
    drain.failure = error.msg
  except Defect as error:
    drain.failure = error.msg

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
  ## All three pipes are serviced CONCURRENTLY, one drain thread per output
  ## stream while this thread feeds stdin. Each pipe holds a bounded amount
  ## before a write to it blocks — 65_536 bytes as measured on the
  ## development host — so any implementation that finishes with one stream
  ## before it starts on another has a deadlock in it: the child blocks
  ## writing to the pipe nobody is reading, and so stops reading the pipe
  ## this side is blocked writing to, or stops producing the stream this side
  ## is blocked reading. Draining stdout to EOF and only then reading stderr
  ## was exactly that shape, and a `sqlite3` that put more than 64 KiB on
  ## stderr wedged the daemon for as long as anyone was willing to wait.
  ##
  ## Threads rather than `poll`/`select` because this is one code path on
  ## every platform: a POSIX-only readiness loop would leave Windows on a
  ## second implementation that the suite never exercises. The cost is two
  ## thread creations against a process spawn that already costs milliseconds.
  result = SqliteOutcome(ok: false, exitCode: -1, output: "", error: "")
  var process: Process
  try:
    # Guarded because osproc's pipes are inheritable for the length of this
    # call: a concurrent spawn would hand them to its own child and neither
    # side would ever see EOF again. See `spawn_guard`. The guard covers
    # process creation only, not the child's lifetime.
    withSpawnGuard:
      process = startProcess(
        sqliteTool,
        args = ["-batch", "-noheader", "-bail", dbPath],
        options = {poUsePath}
      )
      process.protectSpawnedPipes()
  except CatchableError as error:
    result.error = "cannot run " & sqliteTool & ": " & error.msg
    return
  except Defect as error:
    result.error = "cannot run " & sqliteTool & ": " & error.msg
    return

  var outputDrain = StreamDrain(stream: nil, text: "", failure: "")
  var errorDrain = StreamDrain(stream: nil, text: "", failure: "")
  var outputThread: Thread[ptr StreamDrain]
  var errorThread: Thread[ptr StreamDrain]
  var drainsStarted = 0
  var failure = ""

  try:
    outputDrain.stream = process.outputStream
    errorDrain.stream = process.errorStream
    createThread(outputThread, drainStream, addr outputDrain)
    drainsStarted = 1
    createThread(errorThread, drainStream, addr errorDrain)
    drainsStarted = 2
    let input = process.inputStream
    input.write(sqlitePreamble)
    input.write(sql)
    input.write("\n")
    input.flush()
  except CatchableError as error:
    failure = error.msg
  except Defect as error:
    failure = error.msg
  finally:
    # Closing stdin before joining is what guarantees the joins terminate:
    # `sqlite3 -batch` runs until end of input, so a drain thread waiting for
    # EOF on stdout would otherwise wait on a child that is itself waiting on
    # us. This runs on the failure path too, where stdin may not have been
    # written at all.
    try:
      process.inputStream.close()
    except CatchableError:
      discard
    except Defect:
      discard
    # If the stderr drain never started -- `createThread` is the only thing
    # here that can fail after the stdout drain is running -- then nothing
    # would ever read that pipe, the child would block once it filled, and
    # the stdout drain would wait on EOF from a child that can no longer
    # reach it. Read stderr on this thread instead, so both streams are still
    # serviced at the same time and the join below is guaranteed to return.
    if drainsStarted == 1:
      drainStream(addr errorDrain)
    if drainsStarted >= 1:
      joinThread(outputThread)
    if drainsStarted >= 2:
      joinThread(errorThread)

  try:
    if failure.len == 0 and outputDrain.failure.len > 0:
      failure = outputDrain.failure
    if failure.len == 0 and errorDrain.failure.len > 0:
      failure = errorDrain.failure
    if failure.len > 0:
      result.error = "running " & sqliteTool & " failed: " & failure
    else:
      result.output = outputDrain.text
      result.error = errorDrain.text
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
