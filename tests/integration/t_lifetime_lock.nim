## The lifetime lock: a daemon that binds a private-scope endpoint holds
## `flock(LOCK_EX)` on `<socket>.lock` for as long as it lives.
##
## WHY THIS EXISTS. The per-user daemon outlives the invocation that started
## it, so the next invocation has to tell "a daemon is alive here" from "a
## daemon was here". The socket file cannot say: a daemon killed by `SIGKILL`
## leaves it behind, and `ECONNREFUSED` is no test either -- on macOS a full
## listen backlog answers it too. A lock the kernel releases with the process
## can (reprobuild-pm `spec/RunQuota-Host-Configuration.md`, "The shared
## per-user daemon (POSIX)", `runquotad.sock.lock`). The clauses:
##
## * while the first daemon lives, its lock is held, and a second daemon on
##   the same private endpoint is refused with `endpointRefusedExitCode` (3)
##   and a message naming the lock -- and the first one keeps serving;
## * after the first is killed with `SIGKILL`, its socket remains and its lock
##   is free, which is exactly the state a launcher reads as "stale"; once the
##   stale socket is removed (the launcher's job, never the daemon's), the
##   next daemon takes the lock and serves.
##
## Take the lock after binding instead of before, or not at all, and the
## first case fails (no lock held, and the refusal names no lock); hold it in
## a way the kernel does not release on SIGKILL and the second case fails.
##
## A PRIVATE DAEMON, ALWAYS, on an explicit scratch socket
## (`tests/support/private_daemon_fixture`). The lock is observed with
## `flock(2)` directly, not through the library that takes it.
##
## NO MOCKS. The built `runquotad` and `runquota`, real sockets, real locks.

when defined(posix):
  import std/[os, osproc, strutils, unittest]

  import private_daemon_fixture

  const ExitBudgetMillis = 60_000

  suite "lifetime lock":
    test "a second daemon on the same private endpoint is refused while the first lives":
      let root = scratchDir("rqlock")
      defer: removeDir(root)
      let socket = root / "ep" / "d.sock"
      let env = privateEnv(socket)
      let first = launch(root, socket, env)
      defer: stopOwned(first)
      prerequisite awaitSocket(first, socket),
        first.startupContext("the first daemon did not bind " & socket)
      check lockState(lockPathOf(socket)) == lockHeld

      let second = launch(root, socket, env)
      defer: stopOwned(second)
      let code = second.exitWithin(ExitBudgetMillis)
      let refusal = second.output
      checkpoint "second daemon output:\n" & refusal
      check code == 3
      check lockPathOf(socket) in refusal
      # The refusal is the lock's, not the bind's: the first daemon's socket
      # and its service are untouched.
      check isSocket(socket)
      check first.running
      let status = cli(env)
      checkpoint status.output
      check status.code == 0
      check "active_sessions" in status.output

      first.terminate()
      check first.exitWithin(ExitBudgetMillis) == 0
      check not pathExists(socket)
      check lockState(lockPathOf(socket)) == lockFree

    test "after SIGKILL the socket remains and the lock is free":
      let root = scratchDir("rqkill")
      defer: removeDir(root)
      let socket = root / "ep" / "d.sock"
      let env = privateEnv(socket)
      let first = launch(root, socket, env)
      defer: stopOwned(first)
      prerequisite awaitSocket(first, socket),
        first.startupContext("the first daemon did not bind " & socket)
      check lockState(lockPathOf(socket)) == lockHeld

      first.kill()
      discard first.waitForExit(ExitBudgetMillis)
      prerequisite not first.running, "SIGKILL did not end the daemon"
      # What a launcher finds: a socket nobody serves, and a free lock.
      check isSocket(socket)
      check lockState(lockPathOf(socket)) == lockFree

      # The launcher removes the stale socket; the next daemon then takes the
      # lock and serves the same endpoint.
      removeFile(socket)
      let next = launch(root, socket, env)
      defer: stopOwned(next)
      prerequisite awaitSocket(next, socket),
        next.startupContext("the next daemon did not bind " & socket)
      check lockState(lockPathOf(socket)) == lockHeld
      let status = cli(env)
      checkpoint status.output
      check status.code == 0
      next.terminate()
      check next.exitWithin(ExitBudgetMillis) == 0
else:
  echo "t_lifetime_lock: POSIX only (the per-user daemon is the POSIX row)"
