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

  when defined(runquotaChildProcessFaults):
    # TEST-ONLY FAULT INJECTION, compiled in only under
    # `-d:runquotaChildProcessFaults` (which a test sets through its own
    # `.nims`); the production build has none of this. The failures it stands
    # in for -- `poll` refusing to allocate its table, a read on a pipe
    # failing -- have no way to be provoked from outside the process, and
    # they are exactly the paths where an untested helper left a child
    # blocked and unreaped. Single-threaded use only.
    type ChildProcessFaultSite* = enum
      faultPoll  ## the next ``poll`` fails with the injected errno
      faultRead  ## the next ``read`` of an output pipe fails with it

    type PendingFault = object
      code: cint
      times: int

    var pendingFaults: array[ChildProcessFaultSite, array[8, PendingFault]]
    var pendingFaultCounts: array[ChildProcessFaultSite, int]

    proc injectChildProcessFault*(site: ChildProcessFaultSite; code: cint;
                                  times = 1) =
      ## Queue ``times`` consecutive failures with errno ``code`` at ``site``,
      ## after any already queued there.
      doAssert times > 0
      doAssert pendingFaultCounts[site] < pendingFaults[site].len
      pendingFaults[site][pendingFaultCounts[site]] =
        PendingFault(code: code, times: times)
      inc pendingFaultCounts[site]

    proc clearChildProcessFaults*() =
      ## Drop every queued failure, so one test case cannot inherit another's.
      for site in ChildProcessFaultSite:
        pendingFaultCounts[site] = 0

    proc takeFault(site: ChildProcessFaultSite): cint =
      if pendingFaultCounts[site] == 0:
        return 0
      result = pendingFaults[site][0].code
      dec pendingFaults[site][0].times
      if pendingFaults[site][0].times == 0:
        for i in 1 ..< pendingFaultCounts[site]:
          pendingFaults[site][i - 1] = pendingFaults[site][i]
        dec pendingFaultCounts[site]

  proc pollPipes(fds: ptr TPollfd; count: Tnfds): cint =
    ## ``poll(2)`` with no timeout.
    when defined(runquotaChildProcessFaults):
      let code = takeFault(faultPoll)
      if code != 0:
        errno = code
        return -1
    poll(fds, count, -1)

  proc readPipe(fd: cint; buffer: pointer; size: int): int =
    ## ``read(2)`` of an output pipe.
    when defined(runquotaChildProcessFaults):
      let code = takeFault(faultRead)
      if code != 0:
        errno = code
        return -1
    read(fd, buffer, size)

  const PollRetryMillis = 1
    ## How long to wait before asking ``poll`` again after a transient
    ## allocation failure.
  const PollRetryLimit = 1000
    ## How many transient ``poll`` failures IN A ROW are retried before the
    ## exchange is abandoned as if the failure were permanent: at least a
    ## second of waiting. Unbounded, a failure that never clears would spin
    ## the calling thread forever while the child stayed blocked on a full
    ## pipe -- the hang this retry exists to avoid, only slower.

  when defined(runquotaChildProcessFaults):
    proc childProcessPollRetryLimit*(): int =
      ## ``PollRetryLimit``, for the test that drives the retry past it.
      PollRetryLimit

  proc abandonChild(process: Process; drained: var bool) =
    ## Stop a child whose output pipes we are no longer reading, so that it
    ## can be waited for.
    ##
    ## Once a pipe is abandoned before end of input -- ``poll`` itself failed,
    ## or a read on the pipe did -- nothing reads it any more, and a child
    ## that keeps writing blocks on it forever. ``Process.close`` does not
    ## wait, so such a child would also stay in the process table for the
    ## life of the daemon. Killing it makes the wait in ``runCapturedProcess``
    ## certain to return, and the wait reaps it. Killing a child that has
    ## already exited is harmless: it stays a zombie until that wait.
    try:
      process.kill()
    except CatchableError:
      discard
    except Defect:
      discard
    drained = true

  proc readReady(fd: cint; chunk: var string; sink: var string;
                 open: var bool; failure: var string; readError: var bool) =
    ## One ``read(2)`` on a descriptor ``poll`` reported ready, so it does
    ## not block. End of input is a read that returns nothing -- for the
    ## reason ``readToEnd`` gives -- and only that, or an error, closes the
    ## stream. A hang-up with data still buffered is reported as readable
    ## too, so the data is read before the zero-byte read that follows it.
    let count = readPipe(fd, addr chunk[0], chunk.len)
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
    ## waiting for the child is now certain to return: every output pipe
    ## reached end of input, or the exchange was abandoned and the child
    ## killed (``abandonChild``). It is false only when this proc raised.
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
    var pollRetries = 0
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

      if pollPipes(addr fds[0], Tnfds(count)) < 0:
        let code = errno
        if code == EINTR:
          continue
        # The kernel could not allocate poll's table this time (`EAGAIN` in
        # POSIX, `ENOMEM` on Linux); a later call may succeed, so wait a
        # moment and ask again rather than abandon a child that may already
        # be blocked on a full pipe -- up to `PollRetryLimit` times in a row.
        # https://pubs.opengroup.org/onlinepubs/9799919799/functions/poll.html
        if (code == EAGAIN or code == ENOMEM) and pollRetries < PollRetryLimit:
          inc pollRetries
          discard poll(nil, 0, PollRetryMillis)
          continue
        if result.len == 0:
          result = "cannot wait on the child's pipes: " & errorText(code)
        if inputOpen:
          closeInput(process)
        abandonChild(process, drained)
        return
      pollRetries = 0

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
      # A pipe that failed a read is no longer read, so a child still writing
      # to it would block there forever -- and never close the OTHER pipe this
      # loop is still waiting on. Stop it now, not after the loop: then every
      # pipe it held reaches end of input and the loop ends.
      if readError and not drained:
        abandonChild(process, drained)

    drained = true

elif compileOption("threads"):
  # Windows only: every POSIX build takes the `poll` branch above.
  import std/[os, winlean]

  proc cMalloc(size: csize_t): pointer {.importc: "malloc",
    header: "<stdlib.h>".}
  proc cFree(p: pointer) {.importc: "free", header: "<stdlib.h>".}

  const ErrorBrokenPipe = 109'i32
    ## ``ERROR_BROKEN_PIPE``, which ``std/winlean`` does not export.
    ## https://learn.microsoft.com/windows/win32/debug/system-error-codes--0-499-

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
      ## timing-dependent fraction of calls.
      ##
      ## A FAILURE IS RECORDED AS A CODE, NOT A MESSAGE: building the message
      ## would allocate on the drain thread (see ``drainHandle``). The caller
      ## turns the code into text on its own thread, in ``drainFailure``.
      handle: Handle
      chunks: OwnedStrings
      readError: int32
        ## The OS error code of the read that failed; 0 when none did.
      outOfMemory: bool
        ## The C allocator refused the read buffer or what was read.

  proc drainHandle(drain: ptr StreamDrain) {.thread, raises: [].} =
    ## Read one pipe to end of input into ``drain.chunks``.
    ##
    ## NOTHING HERE ALLOCATES FROM THE NIM HEAP, ON ANY PATH. Every page a Nim
    ## thread's region takes from the OS outlives the thread (see the module
    ## comment): a 64 KiB Nim ``string`` here cost ~78 KB of resident memory
    ## per call, for the life of the process. So the buffer comes from the C
    ## allocator, each chunk goes straight into ``OwnedStrings``, and the read
    ## is a raw ``ReadFile`` rather than osproc's stream, whose error path
    ## RAISES -- an exception object is a Nim allocation, and with the stream
    ## every failed read left a region behind.
    ##
    ## ``ReadFile`` on an anonymous pipe returns whatever the child has written
    ## so far, so end of input is a read that returns nothing, for the reason
    ## ``readToEnd`` gives. The writer closing its end is reported as a
    ## FAILURE with ``ERROR_BROKEN_PIPE`` rather than as a zero-byte success,
    ## so that error is end of input too. Any other failure is reported, which
    ## is stricter than osproc's ``hsReadData``: it treats every failed read
    ## that returned nothing as end of input, turning a real read error into a
    ## silently truncated capture.
    ## https://learn.microsoft.com/windows/win32/api/fileapi/nf-fileapi-readfile
    const chunkSize = 64 * 1024
    let chunk = cMalloc(csize_t(chunkSize))
    if chunk == nil:
      drain.outOfMemory = true
      return
    while true:
      var bytesRead: int32 = 0
      if readFile(drain.handle, chunk, int32(chunkSize), addr bytesRead,
          nil) == 0:
        let code = getLastError()
        if code != ErrorBrokenPipe and code != ERROR_HANDLE_EOF:
          drain.readError = code
        break
      if bytesRead <= 0:
        break
      if not drain.chunks.addBytes(chunk, int(bytesRead)):
        drain.outOfMemory = true
        break
    cFree(chunk)

  proc drainFailure(drain: StreamDrain): string =
    ## Why ``drain`` stopped early, as text built on the CALLING thread;
    ## empty when it read to end of input.
    if drain.outOfMemory:
      "out of memory capturing child output"
    elif drain.readError != 0:
      "cannot read child output: " & osErrorMsg(OSErrorCode(drain.readError))
    else:
      ""

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
    var outputDrain = StreamDrain()
    var errorDrain = StreamDrain()
    var outputThread: Thread[ptr StreamDrain]
    var errorThread: Thread[ptr StreamDrain]
    var drainsStarted = 0
    # The drains read the raw handles and no `outputStream`/`errorStream` is
    # ever created over them: `Process.close` closes a handle that has no
    # stream around it, so ownership stays with `process` either way.
    # osproc stores each handle as a 32-bit `FileHandle`; widening it back to
    # a `Handle` sign-extends, which is exactly how Windows defines a 32-bit
    # handle's 64-bit value, so nothing is lost.
    # https://learn.microsoft.com/windows/win32/winprog64/interprocess-communication
    outputDrain.handle = Handle(process.outputHandle)
    errorDrain.handle = Handle(process.errorHandle)

    try:
      createThread(outputThread, drainHandle, addr outputDrain)
      drainsStarted = 1
      if not merged:
        createThread(errorThread, drainHandle, addr errorDrain)
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
        drainHandle(addr errorDrain)
      if drainsStarted >= 1:
        joinThread(outputThread)
      if drainsStarted >= 2:
        joinThread(errorThread)

    let outputFailure = outputDrain.drainFailure()
    let errorFailure = errorDrain.drainFailure()
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
      # REAP IT ANYWAY when the wait is certain to return. The common
      # failure is a write refused with EPIPE by a child that exited without
      # reading its input, and `Process.close` does not wait: unreaped, each
      # such child would stay a zombie for the life of a daemon that runs
      # for weeks. With both pipes at end of input the child cannot block on
      # us, and a child whose pipes were abandoned has been killed, so either
      # way the wait returns. The exit code is not reported: the call
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
