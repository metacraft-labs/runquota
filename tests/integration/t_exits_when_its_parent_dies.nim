## `RUNQUOTA_EXIT_WITH_PARENT=1`: a daemon started for one caller stops when
## that caller is gone, even when the caller was SIGKILLed.
##
## WHY THIS EXISTS. `repro` starts a private `runquotad` for one invocation on
## an unprovisioned POSIX host, and that daemon must not outlive the
## invocation however it ends (reprobuild-pm
## `spec/RunQuota-Host-Configuration.md`, "\"Terminated when the top-level
## build ends\" means however it ends"; issue
## `2026-09-28-auto-started-runquotad-outlives-a-terminated-repro-and-holds-its-callers-pipe`).
## `repro` forwards SIGTERM/SIGINT/SIGHUP/SIGQUIT itself, but nothing in
## `repro` runs on SIGKILL or the OOM killer: those leave a `runquotad` with
## `ppid 1` serving nobody for hours. The daemon's own parent watch is the
## only thing that can cover them, and this file is its contract.
##
## THE SHAPE. A real `/bin/sh` is the parent: it starts the real `runquotad`
## in the background, prints its pid and `wait`s, which is the
## process-tree shape of `repro` holding its daemon. The test then SIGKILLs
## the shell -- the signal no handler can intercept -- and watches the daemon.
##
## THE VERDICT IS THE DAEMON'S EXIT STATUS, NOT MERELY ITS ABSENCE. This
## process makes itself a CHILD SUBREAPER (Linux `PR_SET_CHILD_SUBREAPER`), so
## the orphaned daemon is re-parented to the test rather than to init and the
## test can `waitpid` it. Exit 0 is only reachable by returning from `serve`,
## so it says the watch went through the orderly SIGTERM shutdown and not
## around it; a daemon killed by a default-disposition SIGTERM would report
## the signal instead. Re-parenting to a subreaper rather than to init is
## still a change of `getppid()`, which is all the watch looks for -- the same
## thing happens under a test runner or a `systemd --user` that is a
## subreaper. On other POSIX hosts there is no subreaper, so the case checks
## only that the daemon is gone.
##
## THE CONTROL. The same tree WITHOUT the variable must leave the daemon
## running after the shell dies. Without it the positive case would also
## pass for a daemon that died for some unrelated reason when its parent did
## (a write to a closed pipe, say) -- which is why the daemon's output goes to
## a file here and not to the shell's pipe.
##
## NO MOCKS. A real shell, the real `runquotad` binary on a real socket, a
## real SIGKILL from `kill(2)`, and the kernel's own exit status. Every
## process a case starts is killed and reaped in a `finally`.
##
## NOT TESTED HERE: that the variable is removed from the daemon's
## environment. `/proc/<pid>/environ` shows the environment block the process
## was EXECUTED with, which `unsetenv` does not rewrite, so it cannot answer
## the question; only a child the daemon spawns could, and the daemon spawns
## none on a path a test can steer.

import std/[monotimes, os, osproc, streams, strtabs, strutils, times, unittest]

when defined(posix):
  import std/posix

from runquota_ipc import endpointDirectoryPermissions
import daemon_binary
import daemon_endpoint

const
  ExitBudgetMillis = 15_000
    ## The orderly shutdown's budget, the same one the SIGTERM tests allow,
    ## plus far more than the watch's 200 ms poll. A watch that never fires
    ## overruns it by an unbounded margin.
  BindBudgetMillis = 10_000
  SurvivalWindowMillis = 2_000
    ## How long the control waits for a daemon that must NOT stop: ten
    ## watch intervals, so a watch that wrongly ran without the variable
    ## would have fired several times over.

when defined(linux):
  const PR_SET_CHILD_SUBREAPER = cint(36)
  proc prctl(option: cint; arg2: culong): cint
    {.importc: "prctl", header: "<sys/prctl.h>", varargs.}

when defined(posix):
  type Tree = object
    root: string
    shell: Process
    daemonPid: int
    reaped: bool
    exitStatus: cint

  proc startTree(result: var Tree; tag: string; exitWithParent: bool;
                 dieBeforeExec = false) =
    ## `/bin/sh` starting `runquotad` in the background and waiting for it.
    # Short on purpose: `Sockaddr_un_path_length` is 104 on macOS.
    result.root = getTempDir() / ("rq-pw-" & $getCurrentProcessId() & "-" & tag)
    removeDir(result.root)
    createDir(result.root)
    let endpointDir = result.root / "ep"
    createDir(endpointDir)
    setFilePermissions(endpointDir, endpointDirectoryPermissions())
    let state = result.root / "state"
    createDir(state)
    let socketPath = endpointDir / "d.sock"
    let env = newStringTable(modeCaseSensitive)
    for key, value in envPairs():
      env[key] = value
    if exitWithParent:
      env["RUNQUOTA_EXIT_WITH_PARENT"] = "1"
    else:
      # The control must not inherit the variable from whoever ran the suite.
      env.del("RUNQUOTA_EXIT_WITH_PARENT")
    env.del("RUNQUOTA_EXIT_WITH_PARENT_PID")
    # The daemon's output goes to a FILE, not to the shell's pipe: see the
    # header's paragraph on the control.
    let script = if dieBeforeExec:
      # The daemon's real owner dies while its launcher is still waiting
      # to exec. A subreaper adopts the launcher, so getppid() at daemon
      # entry alone would identify the wrong owner and never stop it.
      "export RUNQUOTA_EXIT_WITH_PARENT_PID=$$; " &
      "(sleep 0.3; exec \"$0\" \"$@\") >\"$RQ_PW_LOG\" 2>&1 & " &
      "echo $!; kill -KILL $$"
    else:
      "\"$0\" \"$@\" >\"$RQ_PW_LOG\" 2>&1 & echo $!; wait"
    env["RQ_PW_LOG"] = result.root / "daemon.log"
    result.shell = startProcess("/bin/sh",
      args = ["-c", script, daemonPath(),
              "--socket", socketPath,
              "--host-identity-file", state / "host-id",
              "--observation-db", state / "observations.db",
              "--ambient-sample-interval-millis", "0"],
      env = env, options = {})
    let line = result.shell.outputStream.readLine().strip()
    result.daemonPid = parseInt(line)
    if dieBeforeExec:
      discard result.shell.waitForExit()
      return
    var waited = 0
    while waited < BindBudgetMillis and not endpointIsBound(socketPath):
      sleep(25)
      waited += 25
    doAssert endpointIsBound(socketPath),
      "runquotad did not bind its endpoint; its log:\n" &
      readFile(result.root / "daemon.log")

  proc daemonExists(tree: Tree): bool =
    tree.daemonPid > 0 and not tree.reaped and
      kill(Pid(tree.daemonPid), 0) == 0

  proc reapWithin(tree: var Tree; budgetMillis: int): bool =
    ## Linux: the daemon is OUR child once re-parented (subreaper), so it
    ## is reaped and its status kept. Elsewhere: true once it is gone.
    let deadline = getMonoTime() + initDuration(milliseconds = budgetMillis)
    while getMonoTime() < deadline:
      when defined(linux):
        var status: cint
        let got = waitpid(Pid(tree.daemonPid), status, WNOHANG)
        if got == Pid(tree.daemonPid):
          tree.reaped = true
          tree.exitStatus = status
          return true
      else:
        if kill(Pid(tree.daemonPid), 0) != 0:
          tree.reaped = true
          return true
      sleep(25)
    false

  proc killShell(tree: var Tree) =
    doAssert kill(Pid(processID(tree.shell)), SIGKILL) == 0,
      "could not SIGKILL the daemon's parent shell"
    discard tree.shell.waitForExit()

  proc cleanUp(tree: var Tree) =
    if tree.shell != nil:
      if tree.shell.running:
        discard kill(Pid(processID(tree.shell)), SIGKILL)
      discard tree.shell.waitForExit()
      tree.shell.close()
      tree.shell = nil
    if daemonExists(tree):
      discard kill(Pid(tree.daemonPid), SIGKILL)
      discard reapWithin(tree, 5_000)
    removeDir(tree.root)

  proc daemonLog(tree: Tree): string =
    try:
      readFile(tree.root / "daemon.log")
    except IOError:
      "<no log>"

suite "exits_when_its_parent_dies":

  setup:
    when defined(linux):
      # See the header: makes an orphaned daemon this test's child.
      doAssert prctl(PR_SET_CHILD_SUBREAPER, 1) == 0,
        "could not make the test a child subreaper"

  test "with RUNQUOTA_EXIT_WITH_PARENT=1, a SIGKILLed parent stops the daemon cleanly":
    when defined(posix):
      doAssert fileExists(daemonPath())
      var tree: Tree
      try:
        startTree(tree, "on", exitWithParent = true)
        doAssert daemonExists(tree)
        killShell(tree)
        let started = getMonoTime()
        let ended = reapWithin(tree, ExitBudgetMillis)
        checkpoint("daemon ended=" & $ended & " after " &
          $(getMonoTime() - started).inMilliseconds & " ms; log:\n" &
          daemonLog(tree))
        check ended
        when defined(linux):
          if ended:
            checkpoint("wait status=" & $tree.exitStatus)
            check WIFEXITED(tree.exitStatus)
            check WEXITSTATUS(tree.exitStatus) == 0
      finally:
        cleanUp(tree)
    else:
      echo "skip: POSIX only: Windows ignores RUNQUOTA_EXIT_WITH_PARENT by design"
      skip()

  test "without the variable, the daemon outlives its parent (control)":
    when defined(posix):
      doAssert fileExists(daemonPath())
      var tree: Tree
      try:
        startTree(tree, "off", exitWithParent = false)
        doAssert daemonExists(tree)
        killShell(tree)
        let ended = reapWithin(tree, SurvivalWindowMillis)
        checkpoint("daemon ended=" & $ended & "; log:\n" & daemonLog(tree))
        check not ended
        check daemonExists(tree)
      finally:
        cleanUp(tree)
    else:
      echo "skip: POSIX only: Windows ignores RUNQUOTA_EXIT_WITH_PARENT by design"
      skip()

  test "the recorded owner dying before daemon entry is still detected":
    when defined(linux):
      doAssert fileExists(daemonPath())
      var tree: Tree
      try:
        startTree(tree, "startup", exitWithParent = true, dieBeforeExec = true)
        let ended = reapWithin(tree, ExitBudgetMillis)
        checkpoint("daemon ended=" & $ended & "; log:\n" & daemonLog(tree))
        check ended
        if ended:
          check WIFEXITED(tree.exitStatus)
          check WEXITSTATUS(tree.exitStatus) == 0
      finally:
        cleanUp(tree)
    else:
      echo "skip: Linux only: this case requires the test to adopt the launcher"
      skip()
