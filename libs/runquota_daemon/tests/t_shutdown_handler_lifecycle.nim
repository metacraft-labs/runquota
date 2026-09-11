## The SIGTERM path must not be able to HANG, and must not be able to write
## into somebody else's descriptor.
##
## Both defects are on the shutdown `kill -TERM` now takes, and both are in
## the small amount of machinery that exists because a handler may call only
## async-signal-safe functions: the handler records the request and writes
## one byte, a waker thread parked on that pipe dials the daemon's own
## socket to make `accept` return, and `uninstallShutdownHandler` disarms
## the signal and joins the waker.
##
## THE HANG. `dialOwnEndpoint` used a BLOCKING `connect`. An AF_UNIX
## `connect` to a socket whose backlog is full does not fail; it waits for
## room, and the room is made by the accept loop -- which by then is inside
## `serve`'s shutdown, waiting for `joinThread(shutdownWakerThread)`. The
## join never returns and `listener.close()` never runs. It needs
## `SOMAXCONN` unaccepted connections at the instant of the signal, so it is
## rare; a hang is still worse to diagnose than a crash.
##
## THE STALE DESCRIPTOR. `onShutdownSignal` runs on whichever thread the
## kernel picked, concurrently with `uninstallShutdownHandler` on another.
## It loads `shutdownPipe[1]`, finds it non-negative, and writes one byte.
## The old uninstall then CLOSED that descriptor, so a handler already past
## its load wrote its byte into whatever the process opened next.
##
## HOW BOTH ARE MADE DETERMINISTIC. Neither is raced. The backlog is filled
## deliberately, with non-blocking connects, until one is refused for want
## of room -- which is exactly the condition a blocking connect would sit
## and wait out. And the stale write is not raced either: the test IS the
## handler, performing the write a handler that had already loaded the
## descriptor would perform, after the disarm that used to invalidate it.

import std/[atomics, os, posix, tempfiles, unittest]

import runquota_daemon {.all.}

const
  BacklogProbes = 64
    ## Enough non-blocking connects that one of them must be refused for
    ## want of room on a listener whose backlog is 1.

type DialState = object
  path: string
  done: Atomic[bool]

proc bindListener(path: string): SocketHandle =
  ## A listening AF_UNIX socket with the smallest backlog the kernel will
  ## take, non-blocking so `accept` answers "nothing waiting" rather than
  ## parking this thread.
  result = socket(cint(AF_UNIX), cint(SOCK_STREAM), 0.cint)
  doAssert cint(result) >= 0, "socket() failed"
  doAssert path.len < Sockaddr_un_path_length, "socket path too long: " & path
  var address: Sockaddr_un
  address.sun_family = TSa_Family(AF_UNIX)
  copyMem(addr address.sun_path[0], unsafeAddr path[0], path.len)
  doAssert bindSocket(result, cast[ptr SockAddr](addr address),
    SockLen(sizeof(address))) == 0, "bind() failed"
  doAssert listen(result, 1.cint) == 0, "listen() failed"
  let flags = fcntl(cint(result), F_GETFL)
  doAssert flags != -1
  doAssert fcntl(cint(result), F_SETFL, flags or O_NONBLOCK) != -1

proc fillBacklog(path: string): seq[SocketHandle] =
  ## Non-blocking connects until one is refused, and the sockets that got
  ## in. AF_UNIX reports a full backlog as an immediate failure on a
  ## non-blocking socket; a BLOCKING connect in the same position waits.
  result = @[]
  for _ in 0 ..< BacklogProbes:
    let handle = socket(cint(AF_UNIX), cint(SOCK_STREAM), 0.cint)
    doAssert cint(handle) >= 0
    let flags = fcntl(cint(handle), F_GETFL)
    doAssert flags != -1
    doAssert fcntl(cint(handle), F_SETFL, flags or O_NONBLOCK) != -1
    var address: Sockaddr_un
    address.sun_family = TSa_Family(AF_UNIX)
    copyMem(addr address.sun_path[0], unsafeAddr path[0], path.len)
    if connect(handle, cast[ptr SockAddr](addr address),
        SockLen(sizeof(address))) != 0:
      discard close(handle)
      return
    result.add(handle)

proc acceptedWithin(listener: SocketHandle; budgetMillis: int): bool =
  ## Did anything connect inside the budget. The listener is non-blocking,
  ## so this is a bounded wait on a condition and not a parked thread.
  var waited = 0
  while true:
    var address: Sockaddr_un
    var length = SockLen(sizeof(address))
    let accepted = accept(listener, cast[ptr SockAddr](addr address),
      addr length)
    if cint(accepted) >= 0:
      discard close(accepted)
      return true
    if waited >= budgetMillis:
      return false
    sleep(10)
    waited += 10

proc wakeToken() =
  ## THE WHOLE OF WHAT `onShutdownSignal` DOES to the pipe, performed here
  ## so the waker can be exercised without raising a signal at a test
  ## process that is also running every other test in this binary.
  var token = '\0'
  doAssert shutdownPipe[1] >= 0, "the shutdown pipe is not armed"
  doAssert write(shutdownPipe[1], addr token, 1) == 1

proc dialInBackground(state: ptr DialState) {.thread.} =
  {.cast(gcsafe).}:
    dialOwnEndpoint(state.path)
    state.done.store(true, moRelease)

var dialState: DialState
var dialThread: Thread[ptr DialState]

suite "shutdown handler lifecycle":

  test "the waker's dial comes back even when the backlog is full":
    let dir = createTempDir("runquota_shutdown_dial_", "")
    defer: removeDir(dir)
    let path = dir / "d.sock"
    let listener = bindListener(path)

    let pending = fillBacklog(path)
    # THE PRECONDITION IS ASSERTED, not assumed. If every probe got in, the
    # backlog was never full and the rest of this case would be measuring
    # an ordinary connect.
    check pending.len > 0
    check pending.len < BacklogProbes

    dialState.path = path
    dialState.done.store(false, moRelease)
    createThread(dialThread, dialInBackground, addr dialState)

    var waited = 0
    while waited < 3000 and not dialState.done.load(moAcquire):
      sleep(10)
      waited += 10
    let returned = dialState.done.load(moAcquire)
    echo "  dial against a full backlog: returned=", returned,
      " after ", waited, " ms, backlog admitted ", pending.len,
      " of ", BacklogProbes

    # NOT JOINED UNLESS IT CAME BACK. With a blocking connect this thread is
    # parked inside `connect(2)` for as long as the listener lives, and
    # `joinThread` here would turn a failing test into a hanging one --
    # which is the very substitution the fix exists to prevent.
    if returned:
      joinThread(dialThread)
    for handle in pending:
      discard close(handle)
    discard close(listener)
    check returned

  test "disarming leaves the handler's descriptor valid rather than reusable":
    let dir = createTempDir("runquota_shutdown_fd_", "")
    defer: removeDir(dir)

    installShutdownHandler("")
    # WHAT A HANDLER LOADS. `onShutdownSignal` reads this value, and may be
    # preempted between reading it and writing to it.
    let handlerFd = shutdownPipe[1]
    check handlerFd >= 0
    uninstallShutdownHandler()

    # TWO SCRATCH DESCRIPTORS, because a closed pipe frees TWO numbers and
    # the lower is handed out first. If either of these is the number the
    # handler is holding, the next byte that handler writes lands in a file.
    var scratch: seq[cint] = @[]
    var scratchPaths: seq[string] = @[]
    for i in 0 .. 1:
      let scratchPath = dir / ("scratch-" & $i)
      let fd = posix.open(scratchPath.cstring, O_CREAT or O_RDWR, 0o600.Mode)
      check fd >= 0
      scratch.add(fd)
      scratchPaths.add(scratchPath)
    for fd in scratch:
      check fd != handlerFd

    # THE WRITE THE STRANDED HANDLER PERFORMS.
    var token = '\0'
    discard write(handlerFd, addr token, 1)
    for fd in scratch:
      discard close(fd)
    for scratchPath in scratchPaths:
      check getFileSize(scratchPath) == 0

  test "the handler's write cannot block, however full the pipe is":
    # WHAT RUNS IN SIGNAL CONTEXT IS ONE ATOMIC STORE AND ONE `write`, and
    # a `write` to a full pipe BLOCKS unless the descriptor says otherwise.
    # The pipe now lives for the whole process, so bytes nobody read
    # accumulate across armings rather than going away with the old pipe;
    # 64 KiB of them is absurd, and "absurd" is not "impossible" for a
    # blocking call inside a signal handler.
    #
    # THIS CASE HANGS RATHER THAN FAILS if the write end is blocking: the
    # fill loop below is the first thing to sit down on a full pipe. That
    # is the honest shape of the defect -- a handler that blocks does not
    # report anything either.
    installShutdownHandler("")
    var chunk: array[4096, char]
    var filled = 0
    while true:
      let wrote = write(shutdownPipe[1], addr chunk[0], chunk.len)
      if wrote <= 0:
        break
      filled += int(wrote)
    check filled > 0
    echo "  pipe filled with ", filled, " bytes before the write was refused"

    # THE HANDLER ITSELF, on a pipe with no room left.
    onShutdownSignal(SIGTERM)
    check shutdownWasRequested()
    uninstallShutdownHandler()

    # AND THE NEXT ARMING CLEARS IT, however much was left behind.
    installShutdownHandler("")
    check write(shutdownPipe[1], addr chunk[0], chunk.len) > 0
    uninstallShutdownHandler()

  test "a wake token left by one disarm does not disarm the next waker":
    let dir = createTempDir("runquota_shutdown_token_", "")
    defer: removeDir(dir)
    let path = dir / "d.sock"
    let listener = bindListener(path)

    installShutdownHandler(path)
    wakeToken()
    # The waker woke, dialled, and exited -- the SIGTERM path.
    check acceptedWithin(listener, 3000)
    # This disarm writes a token of its own, for the paths where no signal
    # arrived and the waker is still parked. Here nobody is left to read it.
    uninstallShutdownHandler()

    installShutdownHandler(path)
    # THE FRESH WAKER MUST STILL BE PARKED. Woken by the leftover it would
    # have dialled at once and exited, leaving the accept loop with nothing
    # to wake it -- the hang this whole mechanism exists to prevent,
    # reintroduced by its own tidying.
    check not acceptedWithin(listener, 300)
    wakeToken()
    check acceptedWithin(listener, 3000)

    uninstallShutdownHandler()
    discard close(listener)

  test "a byte from a stranded handler does not disarm the next waker":
    # THE OTHER SOURCE OF A LEFTOVER, and the reason the ARMING drains as
    # well as the disarm. After `signal(SIGTERM, SIG_DFL)` no new handler
    # runs, but one that was already past its load of `shutdownPipe[1]` on
    # another thread still has a byte to write, and it may write it after
    # the disarm has tidied up. The pipe is no longer closed, so that byte
    # is harmless where it lands -- which is only true if somebody empties
    # it before the next waker parks on it.
    let dir = createTempDir("runquota_shutdown_late_", "")
    defer: removeDir(dir)
    let path = dir / "d.sock"
    let listener = bindListener(path)

    installShutdownHandler(path)
    uninstallShutdownHandler()
    # THE DISARM'S OWN TOKEN woke a waker that was still parked, and it
    # dialled on its way out. Consumed here so that what the next arming
    # does is unambiguous.
    check acceptedWithin(listener, 3000)
    # THE STRANDED HANDLER, arriving after everything was cleaned up.
    wakeToken()

    installShutdownHandler(path)
    check not acceptedWithin(listener, 300)
    wakeToken()
    check acceptedWithin(listener, 3000)

    uninstallShutdownHandler()
    discard close(listener)
