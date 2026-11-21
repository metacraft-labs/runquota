## A REAL `runquotad` ON A PRIVATE SCRATCH ENDPOINT, for the tests of the
## shared per-user daemon (reprobuild-pm `spec/RunQuota-Host-Configuration.md`,
## "The shared per-user daemon (POSIX)"): `t_idle_exit`, `t_lifetime_lock` and
## `t_socket_activation`, and by the other POSIX integration tests that need a
## private daemon of their own.
##
## ISOLATION IS THE FIRST RULE HERE. These tests run on hosts shared with
## other sessions of the same uid, so nothing in this file computes or touches
## the real per-user endpoint (`runquota_ipc.userEndpoint`) or the host
## endpoint: every daemon gets an explicit `--socket` inside a fresh `0700`
## scratch directory, `RUNQUOTA_ENDPOINT_SCOPE=private`, and an environment
## from which every variable that could redirect it has been removed. Every
## process this file starts is one the caller owns and stops; nothing here
## signals a process it did not start. A helper that starts a daemon and
## waits for it owns it until it returns (`launchOwned`), so a failure inside
## the helper stops the daemon too.
##
## THE LOCK PROBE IS WRITTEN OUT HERE, NOT IMPORTED. The lifetime lock is the
## thing under test, so the test's observation of it must not go through the
## code that implements it: `lockState` opens the file and asks `flock(2)`
## directly, with the lock's file name spelled as a literal (`<socket>.lock`).
##
## No mocks: real processes, real sockets, real `flock(2)`.

when defined(posix):
  import std/[os, osproc, posix, streams, strtabs, strutils, tempfiles]

  import daemon_binary

  type
    LockState* = enum
      lockMissing  ## No file at the lock path.
      lockFree     ## The file exists and nobody holds an exclusive lock.
      lockHeld     ## A process holds an exclusive lock on it.
      lockUnreadable

  const
    LockSh = cint(1)
    LockEx = cint(2)
    LockNb = cint(4)
    LockUn = cint(8)
    ## The `flock(2)` operation bits. The same values on Linux, macOS and the
    ## BSDs (`<sys/file.h>`).

  proc flockCall(fd: cint; operation: cint): cint {.
    importc: "flock", header: "<sys/file.h>".}

  var ONoFollow {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint
    ## Not exported by `std/posix`.

  const IsolationKeys* = ["RUNQUOTA_ENDPOINT_SCOPE", "RUNQUOTA_ENDPOINT_OWNER_UID",
    "RUNQUOTA_ENDPOINT_GROUP", "RUNQUOTA_SOCKET", "RUNQUOTA_USER_ENDPOINT_DIR",
    "RUNQUOTA_EXIT_WITH_PARENT", "RUNQUOTA_EXIT_WITH_PARENT_PID",
    "LISTEN_PID", "LISTEN_FDS", "LISTEN_FDNAMES"]
    ## Removed from every child's environment before the fixture sets its
    ## own: an inherited value of any of them would point the daemon at
    ## something other than the scratch endpoint, or change its lifetime.

  proc prerequisite*(condition: bool; message = "fixture prerequisite failed") =
    ## Always active, in every build mode; raises so the test's own `defer`s
    ## still stop the daemons it started.
    if not condition: raise newException(IOError, message)

  proc scratchDir*(prefix: string): string =
    ## A fresh `0700` directory. Short prefix: `sun_path` is 108 bytes on
    ## Linux and 104 on macOS.
    result = createTempDir(prefix, "")
    setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})

  proc lockPathOf*(socket: string): string =
    ## The lifetime lock's name, as a LITERAL rule rather than through the
    ## library under test.
    socket & ".lock"

  proc isSocket*(path: string): bool =
    var info: Stat
    lstat(path.cstring, info) == 0 and S_ISSOCK(info.st_mode)

  proc pathExists*(path: string): bool =
    var info: Stat
    lstat(path.cstring, info) == 0

  proc lockState*(path: string): LockState =
    ## Whether a process holds the exclusive lock on `path`, asked the way
    ## the specification's launcher asks: a SHARED non-blocking lock that is
    ## released at once. It succeeds against nobody and fails against an
    ## exclusive holder.
    let fd = posix.open(path.cstring, O_RDONLY or O_CLOEXEC or ONoFollow)
    if fd < 0:
      return if errno == ENOENT: lockMissing else: lockUnreadable
    defer: discard posix.close(fd)
    if flockCall(fd, LockSh or LockNb) == 0:
      discard flockCall(fd, LockUn)
      return lockFree
    if errno == EWOULDBLOCK or errno == EAGAIN:
      return lockHeld
    lockUnreadable

  proc holdExclusiveLock*(path: string): cint =
    ## Take the exclusive lock on `path` the way a daemon would, for a test
    ## that has to stand in for one. Returns the descriptor; closing it
    ## releases the lock.
    result = posix.open(path.cstring, O_RDWR or O_CREAT or O_CLOEXEC or
      ONoFollow, Mode(0o600))
    prerequisite result >= 0, "cannot open " & path
    prerequisite flockCall(result, LockEx or LockNb) == 0,
      "cannot lock " & path

  proc cleanEnvironment*(): StringTableRef =
    result = newStringTable(modeCaseSensitive)
    for key, value in envPairs():
      if key notin IsolationKeys: result[key] = value

  proc privateEnv*(socket: string): StringTableRef =
    ## The environment the per-user launcher gives its daemon and every
    ## client: the explicit private policy and the socket.
    result = cleanEnvironment()
    result["RUNQUOTA_ENDPOINT_SCOPE"] = "private"
    result["RUNQUOTA_SOCKET"] = socket

  proc daemonArgs*(root, socket: string; extra: openArray[string] = []):
      seq[string] =
    ## Every mutable file the daemon would otherwise reach for on the host
    ## is redirected into `root`, and capture is off: these tests are about
    ## the daemon's lifetime, and the store's start-up check would only slow
    ## them down on a loaded host.
    ##
    ## The CPU pressure signal is read from a file in `root` that does not
    ## exist unless a test writes it: an unreadable signal leaves widening
    ## as it was before the pressure gate (and makes no reclaimed grant), so
    ## a widening test does not pass or fail with the shared host's own CPU
    ## pressure. A test about the gate writes the file (or passes its own
    ## `--cpu-pressure-file`, which comes later and wins).
    result = @["--socket", socket,
      "--host-config", root / "host.toml",
      "--host-identity-file", root / "host-id",
      "--estimate-db", root / "est.sqlite",
      "--no-write-stats",
      "--ambient-sample-interval-millis", "0",
      "--memory-pressure-source", "unavailable",
      "--cpu-pressure-file", root / "cpu-pressure"]
    for arg in extra: result.add(arg)

  proc launch*(root, socket: string; env: StringTableRef;
               extra: openArray[string] = []): Process =
    ## Starts `runquotad` and returns at once; the CALLER owns the process
    ## from here. A caller must register its stop (`defer: stopOwned(...)` or
    ## a `finally`) BEFORE any wait or check that can raise, or a daemon that
    ## has not bound yet outlives the failure. A helper that starts a daemon
    ## and waits for it before handing it back cannot do that -- its caller's
    ## `defer` does not exist yet -- and must use `launchOwned` instead.
    startProcess(daemonPath(), env = env, args = daemonArgs(root, socket, extra),
      options = {poStdErrToStdOut})

  proc awaitSocket*(daemon: Process; socket: string;
                    budgetMillis = 30_000): bool =
    ## Generous: the host these run on is shared and often loaded, and a
    ## daemon that exits ends the wait at once.
    var waited = 0
    while waited < budgetMillis:
      if isSocket(socket): return true
      if not daemon.running: return false
      sleep(25)
      waited += 25

  proc output*(daemon: Process): string =
    ## Everything the daemon printed; read only once it has exited.
    try: daemon.outputStream.readAll()
    except IOError, OSError: ""

  proc exitWithin*(daemon: Process; budgetMillis: int): int =
    ## The exit status. A daemon still running at the end of the budget is
    ## killed by `waitForExit` itself on POSIX, so a hang reads as 137 (or as
    ## -1 should it somehow survive), never as a clean exit.
    result = daemon.waitForExit(budgetMillis)
    if daemon.running: result = -1

  proc stopOwned*(daemon: Process) =
    ## Ends a daemon THIS TEST started, politely first. Never raises: it runs
    ## from `defer` and must not mask the failure being reported.
    try:
      if daemon.running:
        daemon.terminate()
        discard daemon.waitForExit(10_000)
      if daemon.running:
        daemon.kill()
        discard daemon.waitForExit(10_000)
      daemon.close()
    except CatchableError:
      discard

  proc cli*(env: StringTableRef; args: openArray[string] = ["status", "--json"]):
      tuple[code: int, output: string] =
    ## The real `runquota` CLI, with the given environment.
    var process = startProcess(cliPath(), env = env, args = args,
      options = {poStdErrToStdOut})
    defer: process.close()
    let text = process.outputStream.readAll()
    (process.waitForExit(), text)

  proc startupContext*(daemon: Process; what: string): string =
    ## A failure message that carries the daemon's own words, so a refusal
    ## on an old binary reads as what it is.
    let code = daemon.peekExitCode()
    what & " (daemon exit " & $code & "): " &
      (if code >= 0: daemon.output.strip() else: "still running")

  proc launchOwned*(root, socket: string; env: StringTableRef;
                    args: openArray[string]; launcher: openArray[string] = [];
                    what = "the daemon"; budgetMillis = 30_000): Process =
    ## Starts `runquotad` with `args` (the full argument list, normally from
    ## `daemonArgs`) and waits until it has bound `socket`. `launcher`, when
    ## given, is a command the daemon is started under (`unshare ...`): the
    ## daemon's path and `args` are appended to it.
    ##
    ## THE HELPER OWNS THE DAEMON UNTIL IT RETURNS. No `defer` of the caller
    ## can stop a daemon before the helper has handed it back, so anything
    ## that leaves this proc early once the process exists -- the bind wait
    ## running out on a loaded host while the daemon is still starting, a
    ## binary refused by `daemon_binary`, or a Defect -- stops it here and
    ## removes `root` while the exception propagates. Before this, the
    ## per-suite POSIX helpers raised from the wait and left the daemon
    ## running with its scratch root in place (reprobuild-pm
    ## `issues/2026-11-20-posix-daemon-fixtures-leak-a-running-daemon-when-the-bind-wait-times-out.md`);
    ## `windows_daemon_fixture.launchOwned` is the Windows counterpart.
    ##
    ## A `finally` guarded by a flag rather than `except CatchableError`, so
    ## the cleanup also runs for a Defect, which unittest reports and then
    ## carries on past.
    var bound = false
    try:
      let daemon = daemonPath()
      result =
        if launcher.len == 0:
          startProcess(daemon, env = env, args = args,
            options = {poStdErrToStdOut})
        else:
          startProcess(launcher[0], env = env,
            args = launcher[1 .. ^1] & @[daemon] & @args,
            options = {poStdErrToStdOut})
      prerequisite awaitSocket(result, socket, budgetMillis),
        result.startupContext(what & " did not bind " & socket)
      bound = true
    finally:
      if not bound:
        # No process to stop when resolving the binary or the spawn itself
        # raised; the scratch root is removed either way.
        if result != nil: stopOwned(result)
        try: removeDir(root)
        except CatchableError: discard
