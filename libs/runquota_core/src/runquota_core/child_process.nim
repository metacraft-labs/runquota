## Running a child process and capturing what it wrote, without deadlocking
## against it and without stealing another thread's pipes.
##
## This is the one place in RunQuota that turns a command into its output.
## Everything that used to reach for ``osproc.execProcess`` goes through here
## instead, because ``execProcess`` gets two things wrong and neither can be
## fixed by passing it different arguments.
##
## DEFECT 1 -- STDERR IS NEVER READ. ``execProcess`` loops on ``outputStream``
## and on nothing else. Its *default* options include ``poStdErrToStdOut``, so
## in the default shape stderr is folded into the stream it does read and the
## omission is invisible. Pass ``options`` explicitly -- ``{poUsePath}``, say --
## and the default is replaced wholesale: stderr now has a pipe of its own that
## no one will ever read. A pipe holds a bounded amount before a write to it
## blocks; measured on the development host that capacity is 65_536 bytes and
## it does not grow with the size of the write. A child that puts more than
## that on stderr blocks in ``write(2)`` forever, never exits, and so never
## closes stdout -- and ``execProcess``'s loop, which only breaks when the
## child stops running, spins until someone kills one of them. The same
## argument applies in the other direction to stdin, which ``execProcess``
## never closes at all: a child that reads to end of input never gets one.
##
## The fix is to service every stream at once -- one drain thread per output
## stream while the calling thread feeds stdin, and stdin closed before the
## joins. Threads rather than ``poll``/``select`` because this is then one code
## path on every platform; a POSIX-only readiness loop would leave Windows on a
## second implementation the suite never exercises. The cost is two thread
## creations against a process spawn that already costs milliseconds.
##
## DEFECT 2 -- CONCURRENT SPAWNS TAKE EACH OTHER'S PIPES. See ``spawn_guard``
## for the mechanism. This helper takes the guard around process creation and
## marks the returned descriptors close-on-exec immediately, which is what
## makes a site "guarded". A site that keeps calling ``execProcess`` is not
## guarded and can still steal from a site that is, because the theft happens
## inside the *other* call's ``startProcess``.
##
## NEVER RAISES. Every RunQuota caller of this helper is on a degrade-never-
## fail path: the daemon's hardware detection, the estimate store's writer
## thread, the macOS pressure backend. A tool that will not start is an
## ordinary, catchable condition, so it is reported in ``failure`` rather than
## thrown.

import std/[osproc, streams, strtabs]

import ./spawn_guard

type
  StreamDrain = object
    ## One end of a child pipe plus the text read from it. Passed to a drain
    ## thread by ``ptr``, so the thread argument itself carries no managed
    ## memory.
    stream: Stream
    text: string
    failure: string

  CapturedProcess* = object
    ## What a finished child left behind.
    ##
    ## ``ok`` means the tool ran to completion and exited zero -- it is not a
    ## synonym for "``failure`` is empty", because a child that starts fine and
    ## exits 1 has an empty ``failure`` and ``ok == false``.
    ok*: bool
    exitCode*: int
    output*: string
    error*: string
    failure*: string
      ## Why the command could not be run or could not be drained. Empty when
      ## the child ran, whatever it exited with.

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

proc runCapturedProcess*(
    command: string;
    args: openArray[string] = [];
    input = "";
    workingDir = "";
    env: StringTableRef = nil;
    options: set[ProcessOption] = {poUsePath}
): CapturedProcess =
  ## Run ``command`` to completion, feed it ``input`` on stdin, and return
  ## everything it wrote.
  ##
  ## ``options`` is passed through to ``startProcess`` unchanged, except that
  ## ``poParentStreams`` is rejected: it gives the child this process's own
  ## stdio and leaves nothing to capture. ``poStdErrToStdOut`` is allowed and
  ## does what it says -- but it is no longer *needed* to avoid a deadlock,
  ## which is the point of this helper. Keeping the two streams apart is now
  ## free, so a caller that wants to distinguish a diagnostic from a result can.
  result = CapturedProcess(
    ok: false, exitCode: -1, output: "", error: "", failure: "")

  if poParentStreams in options:
    result.failure =
      "cannot capture output from " & command &
      ": poParentStreams leaves no pipes to read"
    return

  var process: Process
  try:
    # Guarded because osproc's pipes are inheritable for the length of this
    # call: a concurrent spawn would hand them to its own child and neither
    # side would ever see EOF again. See `spawn_guard`. The guard covers
    # process creation only, not the child's lifetime, so a slow child never
    # blocks another thread's spawn.
    withSpawnGuard:
      process = startProcess(
        command,
        workingDir = workingDir,
        args = args,
        env = env,
        options = options
      )
      process.protectSpawnedPipes()
  except CatchableError as error:
    result.failure = "cannot run " & command & ": " & error.msg
    return
  except Defect as error:
    result.failure = "cannot run " & command & ": " & error.msg
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
    if input.len > 0:
      let stdinStream = process.inputStream
      stdinStream.write(input)
      stdinStream.flush()
  except CatchableError as error:
    failure = error.msg
  except Defect as error:
    failure = error.msg
  finally:
    # Closing stdin before joining is what guarantees the joins terminate: a
    # tool that reads to end of input runs until it gets one, so a drain
    # thread waiting for EOF on stdout would otherwise wait on a child that is
    # itself waiting on us. It runs even when `input` was empty -- an unread,
    # unclosed stdin is exactly the hang -- and on the failure path, where
    # stdin may not have been written at all.
    try:
      process.inputStream.close()
    except CatchableError:
      discard
    except Defect:
      discard
    # If the stderr drain never started -- `createThread` is the only thing
    # here that can fail after the stdout drain is running -- then nothing
    # would ever read that pipe, the child would block once it filled, and the
    # stdout drain would wait on EOF from a child that can no longer reach it.
    # Read stderr on this thread instead, so both streams are still serviced
    # at the same time and the join below is guaranteed to return.
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
      result.failure = "running " & command & " failed: " & failure
    else:
      result.output = outputDrain.text
      result.error = errorDrain.text
      result.exitCode = process.waitForExit()
      result.ok = result.exitCode == 0
  except CatchableError as error:
    result.failure = "running " & command & " failed: " & error.msg
  except Defect as error:
    result.failure = "running " & command & " failed: " & error.msg
  finally:
    process.close()
