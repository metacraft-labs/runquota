## A HELPER THAT STARTS A DAEMON OWNS IT UNTIL IT RETURNS.
##
## The POSIX per-suite helpers used to start `runquotad` and then
## `prerequisite awaitSocket(...)` before handing the process back. When the
## bind wait ran out -- a slow or wedged start on a loaded host -- the
## prerequisite raised while the daemon was still running, and the caller's
## `defer` that would have stopped it did not exist yet: the daemon and its
## scratch root were left behind (reprobuild-pm
## `issues/2026-11-20-posix-daemon-fixtures-leak-a-running-daemon-when-the-bind-wait-times-out.md`).
## `private_daemon_fixture.launchOwned` is the one helper every such site now
## goes through; this file holds its contract.
##
## No mocks. The daemon that cannot bind is a REAL `runquotad`, made slow in
## the one way that needs no change to it: its `--log-file` is a FIFO nobody
## reads, so opening it for writing blocks in start-up, before the daemon
## binds, for as long as the FIFO has no reader. The process is started
## through a `sh -c '... exec "$0" "$@"'` launcher only so that the test
## learns its pid: the shell writes `$$` to a file outside the scratch root
## and `exec`s the daemon under the same pid. Nothing is substituted for the
## daemon, the fixture or the wait.

when defined(posix):
  import std/[os, osproc, posix, strutils, unittest]

  import private_daemon_fixture

  const
    ShortBudgetMillis = 5_000
      ## The bind wait the case gives the blocked daemon; long enough for the
      ## launcher to have written its pid on a loaded host.
    PidFileBudgetMillis = 30_000
      ## How long a regression gets to show itself by writing the pid file
      ## late. Waited out only when the file is absent after the helper
      ## raised, which the fixed helper never leaves behind.

  proc readPid(path: string; budgetMillis: int): Pid =
    ## The pid the launcher recorded, or 0 if none appeared within the budget.
    var waited = 0
    while true:
      if fileExists(path):
        let text = readFile(path).strip()
        if text.len > 0:
          return Pid(parseInt(text))
      if waited >= budgetMillis: return 0
      sleep(25)
      waited += 25

  proc alive(pid: Pid): bool =
    ## Whether a process (a zombie included) still has this pid. The daemon
    ## is this test's child, so a pid that is gone here was really reaped by
    ## the fixture.
    kill(pid, 0) == 0 or errno != ESRCH

  proc reapLeak(pid: Pid) =
    ## A regression must not leave the daemon running past this test.
    discard kill(pid, SIGKILL)
    var status: cint
    discard waitpid(pid, status, 0)

  suite "a helper owns the daemon it starts until it returns":
    test "a daemon still starting when the bind wait runs out is stopped and its root removed":
      let sh = findExe("sh")
      require sh.len > 0
      let side = scratchDir("rqoside")
      defer: removeDir(side)
      let pidFile = side / "daemon.pid"
      let root = scratchDir("rqown")
      let socket = root / "d.sock"
      let fifo = root / "log.fifo"
      require mkfifo(fifo.cstring, Mode(0o600)) == 0
      let launcher = [sh, "-c",
        "echo $$ > " & quoteShell(pidFile) & "; exec \"$0\" \"$@\""]
      var raised = ""
      try:
        let daemon = launchOwned(root, socket, privateEnv(socket),
          daemonArgs(root, socket, ["--log-file", fifo]), launcher,
          budgetMillis = ShortBudgetMillis)
        # Bound after all: not the condition under test. Clean up and fail.
        stopOwned(daemon)
        removeDir(root)
        checkpoint "the daemon bound although its log file blocks start-up"
        fail()
      except IOError as failure:
        raised = failure.msg
      checkpoint "launchOwned raised: " & raised
      check "did not bind " & socket in raised
      check "still running" in raised
      # The pid the launcher wrote BEFORE the wait ran out. A missing file
      # is waited for, because a leaked launcher writes it late; it must not
      # read as a pass.
      let pid = readPid(pidFile,
        if fileExists(pidFile): 0 else: PidFileBudgetMillis)
      if pid == 0:
        checkpoint "the launcher never recorded the daemon's pid in " &
          $PidFileBudgetMillis & " ms after the helper raised"
        fail()
      else:
        let leaked = alive(pid)
        if leaked: reapLeak(pid)
        checkpoint "daemon pid " & $pid & " alive after the helper raised: " &
          $leaked
        check not leaked
      check not dirExists(root)
      if dirExists(root): removeDir(root)

    test "a launcher that cannot be started still leaves no root behind":
      let root = scratchDir("rqonox")
      let socket = root / "d.sock"
      var raised = false
      try:
        discard launchOwned(root, socket, privateEnv(socket),
          daemonArgs(root, socket),
          [root / "no-such-launcher"])
      except OSError:
        raised = true
      check raised
      check not dirExists(root)
      if dirExists(root): removeDir(root)

    test "a daemon that binds is handed back running, its root in place":
      let root = scratchDir("rqook")
      defer: removeDir(root)
      let socket = root / "d.sock"
      let daemon = launchOwned(root, socket, privateEnv(socket),
        daemonArgs(root, socket))
      defer: stopOwned(daemon)
      check daemon.running
      check isSocket(socket)
      check dirExists(root)
      let status = cli(privateEnv(socket))
      checkpoint status.output
      check status.code == 0
