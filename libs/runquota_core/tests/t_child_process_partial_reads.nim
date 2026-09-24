## ``runCapturedProcess`` must return EVERYTHING a child wrote, however the
## child's writes were split, and the strings it returns must be safe to free
## on the calling thread.
##
## BOTH DEFECTS THIS PINS WERE FOUND ON WINDOWS, AND NEITHER IS WINDOWS-ONLY
## CODE. They are in the one helper every platform uses.
##
## THE TRUNCATION. The drain threads used ``streams.readAll``, which stops at
## the first read that returns fewer bytes than it asked for. On POSIX osproc
## hands out a buffered C ``FILE*`` and ``fread`` only comes back short at end
## of file, so the stop condition happened to be right. On Windows osproc
## hands out the raw pipe handle, and ``ReadFile`` on a pipe returns whatever
## the child has written SO FAR -- so a child that wrote in more than one
## piece was captured up to its first piece and no further. ``sqlite3``'s
## ``Error: FOREIGN KEY constraint failed`` arrived as ``E``; a query answer
## split across writes came back empty. The child below writes in deliberate,
## separately flushed pieces with pauses between them, so a reader that stops
## at a short read cannot pass.
##
## THE CROSS-THREAD FREE. The drain threads filled ordinary Nim strings that
## the caller freed after joining them -- a block allocated on one thread's
## ORC region and released after that thread has exited, which dereferences
## the dead region (``runquota_core/process_owned`` documents the mechanism).
## On Windows a thread's TLS block goes away when it exits and this crashed
## ``runSqlite``'s callers with a SIGSEGV inside ``rawDealloc``. That crash is
## TIMING-DEPENDENT, so the second case below is a net, not a proof: it runs
## enough captures back to back that the old shape crashed reliably on the
## Windows host it was found on, and it asserts every one of them whole.
##
## No mocks: the child is this test binary re-executed, so the case needs no
## shell and runs the same way on every platform.

import std/[os, osproc, strutils, unittest]

import runquota_core/child_process

const
  PiecesFlag = "--partial-read-pieces"
  Pieces = 6
  PieceBytes = 400
    ## Small enough that a whole stream (Pieces x PieceBytes = 2400 bytes)
    ## fits the 4 KiB default pipe buffer osproc gets on Windows. A reader
    ## that stopped early then leaves the child able to finish, and the
    ## defect shows as a truncated capture rather than as a hang -- with a
    ## larger stream the child blocks writing to a pipe nobody reads.
  PausePerPieceMillis = 30
  Captures = 100

proc piece(stream: char; index: int): string =
  ## A piece that names its stream and position, so a capture that lost,
  ## repeated or reordered one is visible in the comparison and not only in
  ## the length.
  let label = $stream & $index & ":"
  label & repeat(stream, PieceBytes - label.len - 1) & "\n"

proc expected(stream: char): string =
  for index in 0 ..< Pieces:
    result.add(piece(stream, index))

if paramCount() >= 2 and paramStr(1) == PiecesFlag:
  let pauseMillis = parseInt(paramStr(2))
  # EACH PIECE IS ITS OWN WRITE, flushed and followed by a pause, so the
  # reader on the other side sees them arrive separately.
  for index in 0 ..< Pieces:
    stdout.write(piece('o', index))
    stdout.flushFile()
    stderr.write(piece('e', index))
    stderr.flushFile()
    if pauseMillis > 0:
      sleep(pauseMillis)
  quit(0)

suite "runCapturedProcess reads to end of input":
  test "output written in separate pieces is captured whole":
    let captured = runCapturedProcess(getAppFilename(),
      [PiecesFlag, $PausePerPieceMillis],
      options = {})
    check captured.failure == ""
    check captured.ok
    check captured.output == expected('o')
    check captured.error == expected('e')

  test "back-to-back captures are each whole and safe to free here":
    var intact = 0
    for _ in 0 ..< Captures:
      # No pause: this case is about how many captures run, not how each
      # one is split, and the pieces are still separate writes.
      let captured = runCapturedProcess(getAppFilename(), [PiecesFlag, "0"],
        options = {})
      if captured.ok and captured.output == expected('o') and
          captured.error == expected('e'):
        intact += 1
    check intact == Captures

  test "a merged capture holds every byte of both streams, in one field":
    # `poStdErrToStdOut` gives stderr the same pipe as stdout. It used to be
    # read by BOTH drain threads at once, which split the bytes between
    # `output` and `error` and garbled each; merged, `output` must hold
    # every piece of both streams intact and `error` nothing.
    let captured = runCapturedProcess(getAppFilename(),
      [PiecesFlag, $PausePerPieceMillis], options = {poStdErrToStdOut})
    check captured.failure == ""
    check captured.ok
    check captured.error == ""
    check captured.output.len == expected('o').len + expected('e').len
    for stream in ['o', 'e']:
      for index in 0 ..< Pieces:
        check piece(stream, index) in captured.output
