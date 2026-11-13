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
## The fix is to service every stream at once. HOW depends on the platform:
##
## * POSIX: one ``poll(2)`` loop on the CALLING thread that writes stdin as
##   the child makes room for it and reads stdout and stderr as they fill,
##   closing stdin once the input is written. No thread is created.
## * Windows: anonymous pipes cannot be waited on, so one drain thread per
##   output stream while the calling thread feeds stdin, and stdin closed
##   before the joins.
##
## WHY NOT THREADS EVERYWHERE. This used to be the thread shape on every
## platform, so there was one code path. It leaked. Under ``--mm:arc/orc``
## Nim 2.2's thread wrapper (``system/threadimpl.nim``,
## ``threadProcWrapStackFrame``) never calls ``deallocOsPages`` when a thread
## finishes -- only the non-destructor collectors do -- so every page a
## thread's allocator region took from the OS stays mapped after the thread
## is gone, and nothing can ever reuse it. A drain thread that allocated its
## 64 KiB read buffer as a Nim ``string`` left ~78 KB behind, two of them
## per child: ~156 KB per ``sqlite3`` the daemon ran, and the daemon runs
## ~170 of them per 64-action build with observation capture on. The
## daemon's RSS grew without bound, and every later ``fork`` got dearer with
## it. A thread that never touches the Nim heap leaks nothing, which is what
## the Windows drain below is now held to; on POSIX there is no thread to
## hold to anything.
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

when defined(posix):
  import std/posix
elif compileOption("threads"):
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


when defined(posix):
  proc errorText(code: cint): string =
    ## The C library's wording for ``code``, copied onto the calling thread.
    $strerror(code)

  proc closeInput(process: Process) =
    ## Close the child's stdin THROUGH osproc's input stream, never with a
    ## bare ``close(2)`` on the descriptor. ``Process.close`` closes
    ## ``inHandle`` itself unless a stream was opened over it; a descriptor
    ## closed here behind its back would be closed a second time there, and in
    ## a daemon with other threads opening files that second ``close`` can
    ## land on a descriptor some other thread has just been handed. A closed
    ## ``FileStream`` is a no-op to close again.
    try:
      process.inputStream.close()
    except CatchableError:
      discard
    except Defect:
      discard

  proc readReady(fd: cint; chunk: var string; sink: var string;
                 open: var bool; failure: var string; readError: var bool) =
    ## One ``read(2)`` on a descriptor ``poll`` reported ready, so it does
    ## not block. End of input is a read that returns nothing -- for the
    ## reason ``readToEnd`` gives -- and only that, or an error, closes the
    ## stream. A hang-up with data still buffered is reported as readable
    ## too, so the data is read before the zero-byte read that follows it.
    let count = read(fd, addr chunk[0], chunk.len)
    if count > 0:
      let start = sink.len
      sink.setLen(start + count)
      copyMem(addr sink[start], addr chunk[0], count)
    elif count == 0:
      open = false
    else:
      let code = errno
      if code == EINTR or code == EAGAIN or code == EWOULDBLOCK:
        return
      if failure.len == 0:
        failure = "cannot read child output: " & errorText(code)
      readError = true
      open = false

  proc pumpPipes(process: Process; input: string; merged: bool;
                 output, error: var string; drained: var bool): string =
    ## Feed ``input`` to the child and read both of its output pipes until
    ## each reports end of input, all from the calling thread. Returns why
    ## the exchange failed, or "" when it did not. ``drained`` says whether
    ## every output pipe reached end of input, so the child can no longer
    ## block on one and waiting for it to exit cannot hang.
    ##
    ## Deadlock-free for the same reason the drain threads were: no stream
    ## is ever waited on while another one is full. ``poll`` reports whichever
    ## pipe can move, the write end of stdin is non-blocking so a child that
    ## stops reading cannot stall the loop, and stdin is closed the moment the
    ## input is written (immediately when there is none), so a child that
    ## reads to end of input gets one.
    ##
    ## A write that fails -- typically ``EPIPE`` from a child that exited
    ## without reading its input -- is the call's failure, as it was when
    ## ``FileStream.write`` raised; the outputs are still read to end of
    ## input so the child is never left blocked on a full pipe.
    ##
    ## ``EINTR`` is retried everywhere. Nim's runtime ignores ``SIGPIPE``, so
    ## a write to a closed pipe is an ``EPIPE`` here and not a signal.
    const chunkSize = 64 * 1024
    result = ""
    var chunk = newString(chunkSize)
    let inputFd = process.inputHandle.cint
    let outputFd = process.outputHandle.cint
    let errorFd = process.errorHandle.cint
    var inputOpen = input.len > 0
    var outputOpen = true
    # Merged means stderr IS the stdout pipe (osproc hands back the same
    # descriptor), and one pipe gets one reader. See `runCapturedProcess`.
    var errorOpen = not merged
    var written = 0
    var readError = false
    drained = false

    if inputOpen:
      let flags = fcntl(inputFd, F_GETFL)
      if flags < 0 or fcntl(inputFd, F_SETFL, flags or O_NONBLOCK) < 0:
        result = "cannot make the child's stdin non-blocking: " &
          errorText(errno)
        inputOpen = false
    if not inputOpen:
      closeInput(process)

    while inputOpen or outputOpen or errorOpen:
      var fds: array[3, TPollfd]
      var count = 0
      var inputSlot = -1
      var outputSlot = -1
      var errorSlot = -1
      if inputOpen:
        fds[count] = TPollfd(fd: inputFd, events: POLLOUT, revents: 0)
        inputSlot = count
        inc count
      if outputOpen:
        fds[count] = TPollfd(fd: outputFd, events: POLLIN, revents: 0)
        outputSlot = count
        inc count
      if errorOpen:
        fds[count] = TPollfd(fd: errorFd, events: POLLIN, revents: 0)
        errorSlot = count
        inc count

      if poll(addr fds[0], Tnfds(count), -1) < 0:
        let code = errno
        if code == EINTR:
          continue
        if result.len == 0:
          result = "cannot wait on the child's pipes: " & errorText(code)
        if inputOpen:
          closeInput(process)
        return

      # Any event on stdin -- room to write, or the hang-up / error a pipe
      # whose reader has gone reports -- is answered by a write, which either
      # makes progress or says why it cannot.
      if inputSlot >= 0 and fds[inputSlot].revents != 0:
        let sent = write(inputFd, unsafeAddr input[written],
          input.len - written)
        if sent > 0:
          written += sent
          if written >= input.len:
            inputOpen = false
            closeInput(process)
        else:
          let code = errno
          if sent < 0 and (code == EINTR or code == EAGAIN or
              code == EWOULDBLOCK):
            discard
          else:
            if result.len == 0:
              result = "cannot write the child's input: " &
                (if sent < 0: errorText(code) else: "write returned 0")
            inputOpen = false
            closeInput(process)

      if outputSlot >= 0 and fds[outputSlot].revents != 0:
        readReady(outputFd, chunk, output, outputOpen, result, readError)
      if errorSlot >= 0 and fds[errorSlot].revents != 0:
        readReady(errorFd, chunk, error, errorOpen, result, readError)

    drained = not readError

elif compileOption("threads"):
  proc cMalloc(size: csize_t): pointer {.importc: "malloc",
    header: "<stdlib.h>".}
  proc cFree(p: pointer) {.importc: "free", header: "<stdlib.h>".}

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
    ## ``readToEnd`` gives.
    ##
    ## THE SUCCESS PATH ALLOCATES NOTHING FROM THE NIM HEAP. The read buffer
    ## comes from the C allocator and each chunk goes straight into
    ## ``OwnedStrings``, because every page a Nim thread's region takes from
    ## the OS outlives the thread (see the module comment): a 64 KiB Nim
    ## ``string`` here cost ~78 KB of resident memory per call, for the life
    ## of the process. Only a failure -- whose exception object is a Nim
    ## allocation -- still leaves its region behind, and that is rare.
    const chunkSize = 64 * 1024
    let chunk = cMalloc(csize_t(chunkSize))
    if chunk == nil:
      discard drain.failure.add("out of memory capturing child output")
      return
    try:
      while true:
        let count = drain.stream.readData(chunk, chunkSize)
        if count <= 0:
          break
        if not drain.chunks.addBytes(chunk, count):
          discard drain.failure.add("out of memory capturing child output")
          break
    except CatchableError as error:
      discard drain.failure.add(error.msg)
    except Defect as error:
      discard drain.failure.add(error.msg)
    finally:
      cFree(chunk)

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

  # `poStdErrToStdOut` is forced on a Windows build without threads, because
  # there is then only one reader and two pipes cannot be serviced at once.
  # Merging is the only deadlock-free single-reader shape; see the last
  # branch below. POSIX never needs it: the `poll` loop services both pipes
  # from one thread, with or without thread support.
  var spawnOptions = options
  when not defined(posix) and not compileOption("threads"):
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
  # MERGED MEANS ONE PIPE, AND ONE PIPE GETS ONE READER. With
  # `poStdErrToStdOut` osproc gives stderr the SAME handle as stdout (on
  # POSIX and on Windows alike), and `errorStream` wraps that handle in a
  # second stream. Draining both then put two readers on one pipe, each
  # taking whichever bytes it read first: the capture came back split
  # between `output` and `error`, both garbled -- "database is locked"
  # arrived as "databse islcked" in one field and the missing letters in
  # the other. The merged form is read as stdout alone.
  let merged = poStdErrToStdOut in spawnOptions
  # Whether the child can be waited for even though the exchange failed. See
  # the reap at the end.
  var reapable = false

  when defined(posix):
    try:
      failure = pumpPipes(process, input, merged, capturedOutput,
        capturedError, reapable)
    except CatchableError as error:
      failure = error.msg
    except Defect as error:
      failure = error.msg
  elif compileOption("threads"):
    var outputDrain = StreamDrain(stream: nil)
    var errorDrain = StreamDrain(stream: nil)
    var outputThread: Thread[ptr StreamDrain]
    var errorThread: Thread[ptr StreamDrain]
    var drainsStarted = 0

    try:
      outputDrain.stream = process.outputStream
      createThread(outputThread, drainStream, addr outputDrain)
      drainsStarted = 1
      if not merged:
        errorDrain.stream = process.errorStream
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
      if drainsStarted == 1 and not merged:
        if errorDrain.stream == nil:
          try:
            errorDrain.stream = process.errorStream
          except CatchableError:
            discard
        if errorDrain.stream != nil:
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
    # WINDOWS WITHOUT THREADS -- with one reader, no readiness wait on an
    # anonymous pipe, and two pipes there is no way to service both at once,
    # and servicing them in sequence is precisely the deadlock this module
    # exists to remove. So stderr is MERGED into stdout above: one pipe, one
    # reader, nothing to fill behind our back. `error` is therefore always
    # empty here and the diagnostic arrives in `output` -- stated rather than
    # hidden, because a caller that distinguishes the two would be wrong on
    # this build. Every RunQuota caller that does distinguish them
    # (`runquota_observation_store`, `runquota_persistence`) is outside the
    # static-helper set and always compiles with threads. (The static-helper
    # gate builds `runquota_core` and its closure with `--mm:arc
    # --app:staticlib` and no thread support; on POSIX that build takes the
    # `poll` branch above and keeps the streams apart.)
    discard merged
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
      # REAP IT ANYWAY when its outputs are at end of input. The common
      # failure is a write refused with EPIPE by a child that exited without
      # reading its input, and `Process.close` does not wait: unreaped, each
      # such child would stay a zombie for the life of a daemon that runs
      # for weeks. With both pipes at end of input the child cannot block on
      # us, so the wait returns. The exit code is not reported: the call
      # already failed, and `ok`/`exitCode` keep their failure values.
      if reapable:
        discard process.waitForExit()
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
