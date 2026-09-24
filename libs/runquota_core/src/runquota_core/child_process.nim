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

when compileOption("threads"):
  import ./process_owned

type
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

proc readToEnd*(stream: Stream): string =
  ## Read ``stream`` until the child closes its end, and return everything.
  ##
  ## NOT ``streams.readAll``. That proc stops at the first read that returns
  ## fewer bytes than it asked for, which is end of input for a file and for
  ## the buffered C stream osproc hands out on POSIX -- ``fread`` only comes
  ## back short at EOF -- but not for the pipe handle osproc hands out on
  ## Windows. There ``ReadFile`` returns whatever the child has written SO
  ## FAR, so ``readAll`` returned the first fragment and dropped the rest:
  ## ``sqlite3`` wrote ``Error: FOREIGN KEY constraint failed`` to stderr in
  ## pieces and the caller saw ``E``; a query answer that did not arrive in
  ## one write came back empty or truncated. The only end of input a pipe has
  ## is a read that returns nothing, so that is the only stop condition here,
  ## on every platform.
  const chunkSize = 64 * 1024
  result = ""
  var chunk = newString(chunkSize)
  while true:
    let count = stream.readData(addr chunk[0], chunkSize)
    if count <= 0:
      break
    let start = result.len
    result.setLen(start + count)
    copyMem(addr result[start], addr chunk[0], count)

when compileOption("threads"):
  type
    StreamDrain = object
      ## One end of a child pipe plus what was read from it. Passed to a drain
      ## thread by ``ptr``, so the thread argument itself carries no managed
      ## memory.
      ##
      ## WHAT THE THREAD READ IS HELD IN PROCESS-OWNED STORAGE, not in a Nim
      ## ``string``. The drain thread has exited by the time the caller looks
      ## at the result, and a block allocated on a thread's ORC region and
      ## freed after that thread is gone dereferences a dead region inside
      ## ``addToSharedFreeList`` -- see ``runquota_core/process_owned`` for
      ## the mechanism. This held a ``string`` filled on the drain thread and
      ## freed by the caller, which is exactly that shape: on Windows, where
      ## a thread's TLS block is released when it exits, it crashed
      ## ``runSqlite``'s caller with a SIGSEGV in ``rawDealloc`` on a
      ## timing-dependent fraction of calls. Chunks are copied into
      ## ``OwnedStrings`` on the drain thread and copied back out into
      ## ordinary strings on the caller's.
      stream: Stream
      chunks: OwnedStrings
      failure: OwnedStrings

  proc drainStream(drain: ptr StreamDrain) {.thread.} =
    ## Read one stream to EOF. Never propagates: a thread that let an exception
    ## escape would terminate the process, and this runs inside a daemon whose
    ## whole contract is to degrade rather than fail.
    ##
    ## End of input is a read that returns nothing, for the reason
    ## ``readToEnd`` gives; every string allocated here is also freed here.
    const chunkSize = 64 * 1024
    try:
      var chunk = newString(chunkSize)
      while true:
        let count = drain.stream.readData(addr chunk[0], chunkSize)
        if count <= 0:
          break
        if not drain.chunks.add(chunk[0 ..< count]):
          discard drain.failure.add("out of memory capturing child output")
          break
    except CatchableError as error:
      discard drain.failure.add(error.msg)
    except Defect as error:
      discard drain.failure.add(error.msg)

  proc takeText(store: var OwnedStrings): string =
    ## Everything in ``store``, concatenated into a string allocated on the
    ## CALLING thread, and the store released.
    result = ""
    for piece in store.takeAll():
      result.add(piece)

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

  # `poStdErrToStdOut` is forced on a build without threads, because there is
  # then only one reader and two pipes cannot be serviced at once. Merging is
  # the only deadlock-free single-reader shape; see the note above the
  # `compileOption` branch below.
  var spawnOptions = options
  when not compileOption("threads"):
    spawnOptions.incl(poStdErrToStdOut)

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
        options = spawnOptions
      )
      process.protectSpawnedPipes()
  except CatchableError as error:
    result.failure = "cannot run " & command & ": " & error.msg
    return
  except Defect as error:
    result.failure = "cannot run " & command & ": " & error.msg
    return

  var failure = ""
  var capturedOutput = ""
  var capturedError = ""

  when compileOption("threads"):
    var outputDrain = StreamDrain(stream: nil)
    var errorDrain = StreamDrain(stream: nil)
    var outputThread: Thread[ptr StreamDrain]
    var errorThread: Thread[ptr StreamDrain]
    var drainsStarted = 0

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
      # thread waiting for EOF on stdout would otherwise wait on a child that
      # is itself waiting on us. It runs even when `input` was empty -- an
      # unread, unclosed stdin is exactly the hang -- and on the failure path,
      # where stdin may not have been written at all.
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

    let outputFailure = outputDrain.failure.takeText()
    let errorFailure = errorDrain.failure.takeText()
    if failure.len == 0 and outputFailure.len > 0:
      failure = outputFailure
    if failure.len == 0 and errorFailure.len > 0:
      failure = errorFailure
    capturedOutput = outputDrain.chunks.takeText()
    capturedError = errorDrain.chunks.takeText()
  else:
    # NO THREADS -- the static-helper gate builds `runquota_core`,
    # `runquota_host_macos` and their closure with `--mm:arc --app:staticlib`
    # and no thread support, so this branch is what those archives contain.
    #
    # With one reader and two pipes there is no way to service both at once,
    # and servicing them in sequence is precisely the deadlock this module
    # exists to remove. So stderr is MERGED into stdout above: one pipe, one
    # reader, nothing to fill behind our back. `error` is therefore always
    # empty here and the diagnostic arrives in `output` -- stated rather than
    # hidden, because a caller that distinguishes the two would be wrong on
    # this build. Every RunQuota caller that does distinguish them
    # (`runquota_observation_store`, `runquota_persistence`) is outside the
    # static-helper set and always compiles with threads.
    try:
      if input.len > 0:
        let stdinStream = process.inputStream
        stdinStream.write(input)
        stdinStream.flush()
    except CatchableError as error:
      failure = error.msg
    except Defect as error:
      failure = error.msg
    finally:
      try:
        process.inputStream.close()
      except CatchableError:
        discard
      except Defect:
        discard

    if failure.len == 0:
      try:
        capturedOutput = process.outputStream.readToEnd()
      except CatchableError as error:
        failure = error.msg
      except Defect as error:
        failure = error.msg

  try:
    if failure.len > 0:
      result.failure = "running " & command & " failed: " & failure
    else:
      result.output = capturedOutput
      result.error = capturedError
      result.exitCode = process.waitForExit()
      result.ok = result.exitCode == 0
  except CatchableError as error:
    result.failure = "running " & command & " failed: " & error.msg
  except Defect as error:
    result.failure = "running " & command & " failed: " & error.msg
  finally:
    process.close()
