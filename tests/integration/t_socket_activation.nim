## systemd socket activation: a `runquotad` handed a listening socket on
## descriptor 3 serves it instead of binding one.
##
## WHY THIS EXISTS. A provisioned host can run the service on demand -- systemd
## holds the socket, starts the daemon on the first connection, and, with
## `--idle-exit-after`, lets it exit when idle and starts it again on the next
## connection (reprobuild-pm `spec/RunQuota-Host-Configuration.md`, "Socket
## activation (systemd)"; the protocol is
## [`sd_listen_fds(3)`](https://www.freedesktop.org/software/systemd/man/latest/sd_listen_fds.html)).
## The clauses, each observed from outside:
##
## * a daemon started with `LISTEN_PID` = its pid and `LISTEN_FDS=1` serves the
##   socket on descriptor 3 (the real CLI gets an answer through the path);
## * it refuses (exit 3) a descriptor bound at a path other than its
##   configured endpoint, and `LISTEN_FDS=2`;
## * it exits when idle WITHOUT unlinking the socket (systemd owns it), and on
##   `SIGTERM` too;
## * it LEAVES NO QUEUED CONNECTION BEHIND: a daemon that woke its accept loop
##   by dialling its own endpoint would leave that connection queued on the
##   listener after it exits, and systemd would start it again at once. The
##   listener the test holds -- standing in for systemd's -- is polled after
##   each exit and must have nothing to accept.
##
## THE TEST PLAYS SYSTEMD, AND THAT IS NOT A MOCK OF THE DAEMON. It creates
## the listening socket itself and hands it over the way `systemd` does:
## a shell moves it to descriptor 3, sets `LISTEN_PID=$$`, and `exec`s the
## daemon, so the pid the daemon sees IS `$$`. That is the whole of what the
## daemon can observe of systemd, and doing it here rather than through
## `systemd-socket-activate` keeps the test on every POSIX host and lets it
## hand over the malformed cases (`LISTEN_FDS=2`, a mismatched path) that the
## real tool would not.
##
## A PRIVATE DAEMON, ALWAYS, on an explicit scratch socket
## (`tests/support/private_daemon_fixture`).
##
## NO MOCKS of anything RunQuota ships: the built `runquotad` and `runquota`.

when defined(posix):
  import std/[os, osproc, posix, strtabs, strutils, unittest]

  import daemon_binary
  import private_daemon_fixture

  const ExitBudgetMillis = 60_000

  proc listenAt(path: string): cint =
    ## A listening AF_UNIX stream socket bound at `path`, mode `0600`, in a
    ## `0700` directory -- what the systemd unit would hand over under the
    ## private policy. NOT close-on-exec: it has to survive into the daemon.
    let directory = parentDir(path)
    createDir(directory)
    setFilePermissions(directory, {fpUserRead, fpUserWrite, fpUserExec})
    let handle = posix.socket(AF_UNIX, SOCK_STREAM, 0)
    prerequisite cint(handle) >= 0, "socket(2) failed"
    result = cint(handle)
    var address: Sockaddr_un
    address.sun_family = TSa_Family(AF_UNIX)
    prerequisite path.len < address.sun_path.len, "socket path too long"
    copyMem(addr address.sun_path[0], unsafeAddr path[0], path.len)
    prerequisite bindSocket(SocketHandle(result), cast[ptr SockAddr](addr address),
      SockLen(sizeof(address))) == 0, "bind(2) failed for " & path
    prerequisite chmod(path.cstring, Mode(0o600)) == 0
    prerequisite listen(SocketHandle(result), 16) == 0, "listen(2) failed"

  proc queuedConnections(listener: cint): bool =
    ## True when a connection is waiting to be accepted on `listener`.
    var descriptor = TPollfd(fd: listener, events: POLLIN, revents: 0)
    poll(addr descriptor, Tnfds(1), 0.cint) > 0 and
      (descriptor.revents and POLLIN) != 0

  proc launchActivated(root, configured: string; fds: openArray[cint];
                       env: StringTableRef; extra: openArray[string] = [];
                       listenFds = -1): Process =
    ## The daemon, started as systemd starts it: the handed descriptors at
    ## 3, 4, ... and `LISTEN_PID` naming the process that runs `runquotad`.
    ##
    ## Moved in two steps, through descriptors 8 and up, so that a handed
    ## descriptor that already sits at one of the targets is never
    ## overwritten before it has been moved. POSIX `sh` guarantees single
    ## digit descriptors only, hence the bound on how many may be handed.
    prerequisite fds.len <= 2, "at most two descriptors can be handed over"
    var script = ""
    for index, fd in fds:
      prerequisite int(fd) < 8, "handed descriptor " & $fd & " is too high"
      script.add("exec " & $(8 + index) & "<&" & $fd & "; ")
    for fd in fds:
      script.add("exec " & $fd & "<&-; ")
    for index in 0 ..< fds.len:
      script.add("exec " & $(3 + index) & "<&" & $(8 + index) & " " &
        $(8 + index) & "<&-; ")
    let count = if listenFds >= 0: listenFds else: fds.len
    script.add("LISTEN_PID=$$ LISTEN_FDS=" & $count &
      " LISTEN_FDNAMES=runquotad exec \"$0\" \"$@\"")
    var args = @["-c", script, daemonPath()]
    for arg in daemonArgs(root, configured, extra): args.add(arg)
    startProcess("/bin/sh", env = env, args = args,
      options = {poStdErrToStdOut})

  proc awaitAnswer(daemon: Process; env: StringTableRef): bool =
    ## The socket exists from the start, so "bound" says nothing here: wait
    ## for the real CLI to get an answer through it.
    for _ in 0 ..< 120:
      if not daemon.running: return false
      if cli(env).code == 0: return true
      sleep(250)

  suite "socket activation":
    test "serves the handed socket and leaves it, with nothing queued, on SIGTERM":
      let root = scratchDir("rqsa")
      defer: removeDir(root)
      let socket = root / "ep" / "d.sock"
      let listener = listenAt(socket)
      defer: discard posix.close(listener)
      let env = privateEnv(socket)
      let daemon = launchActivated(root, socket, [listener], env)
      defer: stopOwned(daemon)
      prerequisite awaitAnswer(daemon, env),
        daemon.startupContext("the activated daemon never answered on " & socket)
      let status = cli(env)
      check status.code == 0
      check "active_sessions" in status.output
      # No lifetime lock: systemd, not a lock, says who serves this socket.
      check lockState(lockPathOf(socket)) == lockMissing

      daemon.terminate()
      let code = daemon.exitWithin(ExitBudgetMillis)
      checkpoint "daemon output:\n" & daemon.output
      check code == 0
      check isSocket(socket)
      check not queuedConnections(listener)

    test "exits when idle without unlinking the socket or leaving a connection queued":
      let root = scratchDir("rqsi")
      defer: removeDir(root)
      let socket = root / "ep" / "d.sock"
      let listener = listenAt(socket)
      defer: discard posix.close(listener)
      let env = privateEnv(socket)
      let daemon = launchActivated(root, socket, [listener], env,
        ["--idle-exit-after", "2"])
      defer: stopOwned(daemon)
      prerequisite awaitAnswer(daemon, env),
        daemon.startupContext("the activated daemon never answered on " & socket)
      let code = daemon.exitWithin(ExitBudgetMillis)
      let log = daemon.output
      checkpoint "daemon output:\n" & log
      check code == 0
      check "idle exit" in log
      check isSocket(socket)
      check not queuedConnections(listener)

    test "refuses a descriptor bound at another path":
      let root = scratchDir("rqsp")
      defer: removeDir(root)
      let configured = root / "ep" / "d.sock"
      let other = root / "ep" / "other.sock"
      let listener = listenAt(other)
      defer: discard posix.close(listener)
      let daemon = launchActivated(root, configured, [listener],
        privateEnv(configured))
      defer: stopOwned(daemon)
      let code = daemon.exitWithin(ExitBudgetMillis)
      let log = daemon.output
      checkpoint "daemon output:\n" & log
      check code == 3
      check other in log
      check configured in log
      # Neither path was touched: the handed socket is still there, and
      # nothing was bound at the configured one.
      check isSocket(other)
      check not pathExists(configured)

    test "refuses LISTEN_FDS=2":
      let root = scratchDir("rqs2")
      defer: removeDir(root)
      let socket = root / "ep" / "d.sock"
      let first = listenAt(socket)
      defer: discard posix.close(first)
      let second = listenAt(root / "ep" / "e.sock")
      defer: discard posix.close(second)
      let daemon = launchActivated(root, socket, [first, second],
        privateEnv(socket))
      defer: stopOwned(daemon)
      let code = daemon.exitWithin(ExitBudgetMillis)
      let log = daemon.output
      checkpoint "daemon output:\n" & log
      check code == 3
      check "LISTEN_FDS" in log
      check isSocket(socket)
      check not queuedConnections(first)
else:
  echo "t_socket_activation: POSIX only (systemd socket activation)"
