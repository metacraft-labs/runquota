## A HOST-SCOPE `runquotad` MUST RESTART OVER THE SOCKET ITS KILLED
## PREDECESSOR LEFT BEHIND, and must refuse -- not displace -- one that is
## still being served.
##
## THE DEFECT THIS EXISTS FOR (reprobuild-pm
## `issues/2026-11-24-runquotad-cannot-restart-over-its-own-stale-socket.md`).
## The host service was stopped, overran systemd's stop timeout and was
## SIGKILLed, so it never unlinked `/run/runquota/runquotad.sock`. Every
## restart then died in `bindUnix` with "Address already in use": the bind
## cleared a leftover endpoint with `if fileExists(path): removeFile(path)`,
## and Nim's `fileExists` is false for a socket, so the one leftover that
## actually occurs was never cleared. The host's build-capacity governor stayed
## down until someone removed the socket by hand.
##
## THE HOST SCOPE, NOT THE PRIVATE ONE. A private-scope daemon takes a
## lifetime lock and refuses any existing endpoint; removing a stale private
## socket is its launcher's job (`t_lifetime_lock`). The host endpoint has no
## lock -- a service manager decides who serves it -- so the bind itself has
## to tell a stale socket from a live one, and these cases pin both halves:
##
##   1. **Killed, then restarted.** A daemon that served a round trip is
##      SIGKILLed; its socket inode is still at the path; a second daemon on
##      the same endpoint binds a NEW inode there and serves a round trip.
##      This is the field sequence, and the case that fails without the fix,
##      with the second daemon's "Address already in use".
##   2. **Started while the first is alive.** The second daemon is refused
##      (`endpointRefusedExitCode`, 3) with a message naming the path, and the
##      first one's socket -- the same inode -- still serves. A bind that
##      cleared ANY socket at the path would pass case 1 and fail this one by
##      stealing the endpoint from a live daemon.
##   3. **Something that is not a socket is at the path** (a regular file, a
##      symbolic link). Refused with a message naming the path, and left in
##      place: the rendezvous directory is the daemon's, but a file there
##      that the daemon did not create is evidence, not debris (the same rule
##      reprobuild-pm `spec/RunQuota-Host-Configuration.md` gives the
##      per-user launcher: "Anything else at the path is refused with an
##      error naming it, and is never removed").
##   4. **The bind is serialised by the start lock** (`<socket>.start`).
##      Between `bind(2)` and `listen(2)` a daemon's socket answers a connect
##      with `ECONNREFUSED`, exactly as a stale one does, so a second daemon
##      probing in that window would unlink a live daemon's socket and bind
##      its own. The test holds the lock itself and asserts the daemon
##      creates nothing at the path until it is released, then serves. A
##      bind that does not take the lock binds at once and fails this case.
##      The lock is taken with `flock(2)` directly
##      (`private_daemon_fixture.holdExclusiveLock`, the file name spelled as
##      a literal), not through the library under test.
##
## ISOLATION. Every daemon gets an explicit `--socket` inside a fresh scratch
## directory and an environment with every redirecting variable removed
## (`private_daemon_fixture.cleanEnvironment`). Host scope is selected by
## naming this process's uid as the endpoint owner and the scratch
## directory's own group as the endpoint group, so the policy is
## `rendezvousShared` on any host, whether or not it has a `runquota` group,
## and nothing touches the real host endpoint.
##
## NO MOCKS. The built `runquotad` and `runquota`, real sockets, a real
## `SIGKILL`, and the daemons' own exit statuses and words as the verdict.

when defined(posix):
  import std/[os, osproc, posix, strtabs, strutils, unittest]

  import private_daemon_fixture

  const
    ExitBudgetMillis = 60_000
    ServeBudgetMillis = 60_000
      ## Generous, as the fixture's own waits are: the host these run on is
      ## shared and often loaded, and a daemon that exits ends the wait at
      ## once, so a refusal costs nothing.
    HeldLockMillis = 5_000
      ## How long the start lock is held before it is released.

  type Inode = tuple[device, inode: uint64]

  proc inodeOf(path: string): Inode =
    var info: Stat
    if lstat(path.cstring, info) == 0:
      result = (uint64(info.st_dev), uint64(info.st_ino))

  proc hostScopeEndpoint(root: string): tuple[socket: string,
      env: StringTableRef] =
    ## `<root>/ep/d.sock` under the HOST policy: owner = this uid, group =
    ## the directory's own group, directory `0750`. The daemon re-verifies all
    ## of it; this only makes the verification pass on any host.
    let dir = root / "ep"
    createDir(dir)
    setFilePermissions(dir, {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec})
    var info: Stat
    prerequisite lstat(dir.cstring, info) == 0, "cannot inspect " & dir
    result.socket = dir / "d.sock"
    result.env = cleanEnvironment()
    result.env["RUNQUOTA_ENDPOINT_OWNER_UID"] = $getuid()
    result.env["RUNQUOTA_ENDPOINT_GROUP"] = $int64(info.st_gid)
    result.env["RUNQUOTA_SOCKET"] = result.socket

  proc awaitServing(daemon: Process; socket: string; env: StringTableRef;
                    notInode: Inode = (0'u64, 0'u64)): bool =
    ## A COMPLETED ROUND TRIP, through the real CLI, on a socket inode other
    ## than `notInode`. The inode clause is what makes this a test of the
    ## restart: the stale socket is a socket at the path from the first
    ## instant, so "a socket exists" says nothing about the second daemon.
    ## Retried because the inode exists before `listen` (a connect in that
    ## window is refused); a daemon that exits ends the wait.
    var waited = 0
    while waited < ServeBudgetMillis:
      if not daemon.running: return false
      if isSocket(socket) and inodeOf(socket) != notInode:
        if cli(env).code == 0: return true
      sleep(100)
      waited += 100

  suite "host endpoint restart over a stale socket":
    test "a daemon SIGKILLed on a host endpoint is replaced by the next one":
      let root = scratchDir("rqrs")
      defer: removeDir(root)
      let (socket, env) = hostScopeEndpoint(root)
      let first = launch(root, socket, env)
      defer: stopOwned(first)
      prerequisite awaitServing(first, socket, env),
        first.startupContext("the first daemon did not serve " & socket)

      # THE FIELD STATE: killed with no chance to tidy up.
      first.kill()
      discard first.waitForExit(ExitBudgetMillis)
      prerequisite not first.running, "SIGKILL did not end the daemon"
      check isSocket(socket)
      let stale = inodeOf(socket)
      checkpoint "first daemon output:\n" & first.output

      let next = launch(root, socket, env)
      defer: stopOwned(next)
      let served = awaitServing(next, socket, env, notInode = stale)
      checkpoint next.startupContext("the next daemon on " & socket)
      check served
      check next.running
      check isSocket(socket)
      check inodeOf(socket) != stale
      if served:
        next.terminate()
        check next.exitWithin(ExitBudgetMillis) == 0
        check not pathExists(socket)

    test "a second daemon on a live host endpoint is refused and the first keeps serving":
      let root = scratchDir("rqlv")
      defer: removeDir(root)
      let other = scratchDir("rqlv2")
      defer: removeDir(other)
      let (socket, env) = hostScopeEndpoint(root)
      let first = launch(root, socket, env)
      defer: stopOwned(first)
      prerequisite awaitServing(first, socket, env),
        first.startupContext("the first daemon did not serve " & socket)
      let live = inodeOf(socket)

      # Same endpoint, its own state files: the store is not under test.
      let second = launch(other, socket, env)
      defer: stopOwned(second)
      let code = second.exitWithin(ExitBudgetMillis)
      let refusal = second.output
      checkpoint "second daemon output:\n" & refusal
      check code == 3
      check socket in refusal
      check "serving" in refusal
      check "Address already in use" notin refusal

      # The live daemon's endpoint is untouched: the same inode, still served.
      check first.running
      check isSocket(socket)
      check inodeOf(socket) == live
      let status = cli(env)
      checkpoint status.output
      check status.code == 0

    test "a regular file at a host endpoint is refused and left in place":
      let root = scratchDir("rqrf")
      defer: removeDir(root)
      let (socket, env) = hostScopeEndpoint(root)
      const marker = "not a socket; must survive the daemon's start"
      writeFile(socket, marker)

      let daemon = launch(root, socket, env)
      defer: stopOwned(daemon)
      let code = daemon.exitWithin(ExitBudgetMillis)
      let refusal = daemon.output
      checkpoint "daemon output:\n" & refusal
      check code == 3
      check socket in refusal
      check "not a socket" in refusal
      check fileExists(socket)
      check readFile(socket) == marker

    test "a symbolic link at a host endpoint is refused and left in place":
      let root = scratchDir("rqsl")
      defer: removeDir(root)
      let (socket, env) = hostScopeEndpoint(root)
      let target = root / "elsewhere.sock"
      createSymlink(target, socket)

      let daemon = launch(root, socket, env)
      defer: stopOwned(daemon)
      let code = daemon.exitWithin(ExitBudgetMillis)
      let refusal = daemon.output
      checkpoint "daemon output:\n" & refusal
      check code == 3
      check socket in refusal
      check "not a socket" in refusal
      check symlinkExists(socket)
      check expandSymlink(socket) == target
      # Nothing was bound through the link either.
      check not pathExists(target)
    test "a host-scope daemon does not bind while another holds the endpoint's start lock":
      let root = scratchDir("rqst")
      defer: removeDir(root)
      let (socket, env) = hostScopeEndpoint(root)
      var lock = holdExclusiveLock(socket & ".start")
      defer:
        if lock >= 0: discard posix.close(lock)

      let daemon = launch(root, socket, env)
      defer: stopOwned(daemon)
      # LONG ENOUGH FOR AN UNSERIALISED DAEMON TO HAVE BOUND: one that does
      # not take the lock binds well inside a second even on a loaded host
      # (this file's other cases measure that), so five seconds with no
      # socket is the lock, not a slow start.
      var appeared = false
      var waited = 0
      while waited < HeldLockMillis:
        if pathExists(socket):
          appeared = true
          break
        if not daemon.running:
          break
        sleep(50)
        waited += 50
      checkpoint daemon.startupContext("the daemon while the start lock was held")
      check not appeared
      check daemon.running

      discard posix.close(lock)
      lock = -1
      let served = awaitServing(daemon, socket, env)
      checkpoint daemon.startupContext("the daemon after the start lock was released")
      check served
      if served:
        daemon.terminate()
        check daemon.exitWithin(ExitBudgetMillis) == 0
        check not pathExists(socket)
else:
  echo "t_host_endpoint_restart_over_stale_socket: POSIX only (the endpoint " &
    "is a named pipe on Windows, reached by name and never left behind)"
