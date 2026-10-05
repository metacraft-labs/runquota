## `kill -TERM` must reach the exit WHEN THE SOCKET FILE IS NO LONGER THERE.
##
## THE DEFECT THIS EXISTS FOR, and it is not the one `t_sigterm_drains_before
## _exit` pins. That file asserts the orderly shutdown runs at all; this one
## asserts it can be STARTED on a daemon whose rendezvous state has been
## deleted underneath it, which is the ordinary condition of every orphaned
## `runquotad` on a build host.
##
## HOW THE WAKE USED TO WORK. A SIGTERM handler may call only
## async-signal-safe functions, so it records the request and writes one byte
## to a pipe; a waker thread parked on that pipe then opens ONE CONNECTION TO
## THE DAEMON'S OWN SOCKET, which makes the blocked `accept` return so the
## accept loop can look at the flag and break into `serve`'s `finally`.
##
## AND AN AF_UNIX `connect` NAMES THE ENDPOINT BY PATH. Unlink the socket and
## the dial fails with ENOENT; `dialOwnEndpoint` ignores every failure by
## design, so the waker exits having woken nobody and the accept loop stays
## parked in a listening socket that is otherwise in perfect health. The
## handler ran -- SIGTERM is caught, neither blocked nor ignored -- and never
## reached the exit. Only SIGKILL ends such a process.
##
## WHY THAT IS THE COMMON CASE AND NOT THE EXOTIC ONE. An auto-started daemon
## outlives the caller that started it, and the caller's scratch directory is
## removed on its way out -- so the orphans that persist are exactly the ones
## whose socket is gone, which is exactly the population that could not be
## stopped politely. Measured on one x86_64-linux host: of 22 leaked
## `runquotad` processes, the five that ignored SIGTERM and needed SIGKILL
## were EXACTLY the five whose `--socket` path no longer existed, and the
## seventeen whose socket was intact all terminated cleanly.
##
## WHAT THE TWO CASES ASSERT, and why each is separate:
##
##   1. **The socket file alone is removed**, the rendezvous directory and
##      everything else left in place. This isolates the socket as the
##      discriminator: nothing else about the daemon's world has changed, so
##      a failure here is about the wake and about nothing else.
##   2. **The whole scratch tree is removed** -- rendezvous directory,
##      published stats table, host identity file and observation database
##      together. This is the field shape, and it extends the claim from "the
##      socket" to "any scratch state": the shutdown that follows the wake
##      must also tolerate the absence of every path it would tidy.
##
## THE CLAUSE IN BOTH IS THE SAME ONE, and it is the strongest available: the
## daemon must reach `exit(0)` inside a bounded window. 0 is only reachable
## by returning from `serve`, so it says the accept loop broke AND the
## `finally` ran to completion. A daemon that never left `accept` is SIGKILLed
## when the window closes and reports 137 -- which is literally the field
## observation this file is about.
##
## NO MOCKS AND NO SEAMS. The real `runquotad` binary, a real AF_UNIX socket
## it bound itself, a real `unlink`, a real `SIGTERM` from `kill(2)`, and the
## process's own exit status as the verdict. The daemon's output is inherited
## rather than piped (`poParentStreams`): a pipe nobody drains is a second way
## for a shutdown to wedge, and a wedge introduced by the test's own plumbing
## would be indistinguishable from the defect. The cost is that the daemon's
## startup lines appear in this file's output, which is evidence rather than
## noise.
##
## READINESS IS A COMPLETED ROUND TRIP AND NOT A BOUND SOCKET, and the
## distinction is load-bearing rather than fastidious. The endpoint is bound
## several steps BEFORE the SIGTERM handler is armed and the accept loop
## starts, so a signal sent as soon as the socket appears lands in a window
## where SIGTERM still has its default disposition -- the first draft of this
## file did exactly that and watched the daemon die of 143 without ever
## reaching the code under test, and watched the other case exit 0 from the
## flag check the loop makes before its first `accept`. A served request is
## the only readiness signal that rules both out: the reply cannot exist
## unless the accept loop accepted the connection and a worker answered it,
## and both of those are downstream of the arming.

import std/[monotimes, os, osproc, strutils, times, unittest]

when defined(posix):
  import std/posix

from runquota_ipc import endpointDirectoryPermissions
import runquota_client
import daemon_binary
import daemon_endpoint

const
  ShutdownBudgetMillis = 15_000
    ## The same budget `t_sigterm_drains_before_exit` allows, and for the
    ## same reason: the shutdown joins a worker pool, lets the aggregate
    ## publisher take one more pass and drains two SQLite writers, each of
    ## which spawns a child. The clause is "it finishes", not "it finishes
    ## fast". A hang overruns this by an unbounded margin -- the processes
    ## this file is about sat on a host for hours -- so no margin is being
    ## cut fine here.
  BindBudgetMillis = 10_000

proc scratchRoot(name: string): string =
  # Short on purpose: `Sockaddr_un_path_length` is 104 on macOS.
  result = getTempDir() / ("rq-sg-" & $getCurrentProcessId() & "-" & name)
  removeDir(result)
  createDir(result)

proc rendezvousDir(root: string): string =
  result = root / "ep"
  createDir(result)
  setFilePermissions(result, endpointDirectoryPermissions())

proc hostStateDir(root: string): string =
  result = root / "state"
  createDir(result)
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc startDaemon(socketPath, stateDir: string): Process =
  ## A REAL DAEMON, waited for by the endpoint it binds rather than by its
  ## own account of having bound it.
  result = startProcess(daemonPath(),
    args = ["--socket", socketPath,
            "--host-identity-file", stateDir / "host-id",
            "--ambient-sample-interval-millis", "0"],
    options = {poParentStreams})
  var waited = 0
  while waited < BindBudgetMillis and not endpointIsBound(socketPath):
    sleep(25)
    waited += 25

proc requestServing(socketPath: string) =
  ## ONE REAL REQUEST, ANSWERED. `connect` already waits for `HelloOk` and
  ## `registerSession` for `SessionRegistered`, so returning from here means
  ## the accept loop accepted a connection and a worker replied to two
  ## frames on it -- which is only reachable after `installShutdownHandler`
  ## has run and the loop has gone back round to wait for the next
  ## connection. Raises rather than reports: a daemon that will not serve is
  ## not a daemon this file has anything to say about.
  putEnv("RUNQUOTA_SOCKET", socketPath)
  try:
    var client = connectDefault()
    try:
      var session = client.registerSession("sigterm-socket-gone", "0.1.0")
      session.closeSession()
    finally:
      client.close()
  finally:
    delEnv("RUNQUOTA_SOCKET")


proc proveServing(socketPath: string; deadline: MonoTime) =
  ## Binding publishes the inode before listen/worker readiness. Retry ONLY
  ## transport-not-ready errors; protocol refusals and all other errors remain
  ## failures. All three original real control exchanges must finish inside
  ## the ORIGINAL bind budget, counted from before the daemon was started.
  var lastFailure: ref OSError
  while getMonoTime() < deadline:
    let remaining = int((deadline - getMonoTime()).inMilliseconds)
    if remaining <= 0:
      break
    if not endpointIsBound(socketPath):
      sleep(min(25, remaining))
      continue
    let hadTimeout = existsEnv("RUNQUOTA_HANDSHAKE_TIMEOUT_MS")
    let oldTimeout = getEnv("RUNQUOTA_HANDSHAKE_TIMEOUT_MS")
    # Each of Hello/Register/Close has header and payload reads. Give those
    # six reads only the remaining original budget; no unbounded fallback.
    var readBudget = max(1, remaining div 6)
    if hadTimeout:
      try:
        let requested = parseInt(oldTimeout)
        if requested > 0:
          readBudget = min(readBudget, requested)
      except ValueError:
        discard
    putEnv("RUNQUOTA_HANDSHAKE_TIMEOUT_MS", $readBudget)
    try:
      requestServing(socketPath)
      doAssert getMonoTime() <= deadline,
        "daemon served the real request only after its original bind budget"
      return
    except OSError as exc:
      when defined(posix):
        if exc.errorCode != ECONNREFUSED and exc.errorCode != ENOENT:
          raise
      else:
        raise
      lastFailure = exc
    finally:
      if hadTimeout:
        putEnv("RUNQUOTA_HANDSHAKE_TIMEOUT_MS", oldTimeout)
      else:
        delEnv("RUNQUOTA_HANDSHAKE_TIMEOUT_MS")
    let left = int((deadline - getMonoTime()).inMilliseconds)
    if left > 0:
      sleep(min(25, left))
  if lastFailure != nil:
    raise lastFailure
  raise newException(OSError,
    "daemon did not serve the real request within the original bind budget")

when defined(linux):
  proc parkedAt(pid: int): string =
    ## Where the daemon's MAIN THREAD is parked, which is the whole
    ## diagnosis when this file goes red: a hang under this defect reads
    ## `__skb_wait_for_more_packets`, the wait inside `unix_accept`. Linux
    ## only, and absent rather than fatal anywhere else -- it is evidence
    ## for a failure, never part of the verdict.
    try:
      result = readFile("/proc/" & $pid & "/wchan").strip()
    except CatchableError:
      result = "unavailable"
else:
  proc parkedAt(pid: int): string = "unavailable"

type Ending = object
  exitCode: int
  elapsedMillis: float
  parked: string
    ## Non-empty only when the budget was overrun.

when defined(posix):
  proc removeStartingDaemonTree(root: string) =
    # Hello is served while the observation store opens, so SQLite can create
    # another file between recursive removal's directory walk and rmdir.
    # Complete the real removal before asserting absence and sending SIGTERM;
    # keep unexpected filesystem errors fatal and this setup phase bounded.
    let deadline = getMonoTime() + initDuration(milliseconds = BindBudgetMillis)
    while true:
      try:
        removeDir(root)
        return
      except OSError as error:
        if error.errorCode != ENOTEMPTY or getMonoTime() >= deadline:
          raise
        sleep(10)

  proc termAndWait(daemon: Process; budgetMillis: int): Ending =
    ## SIGTERM, then a bounded wait for the process to go.
    ##
    ## THE WAIT IS OURS RATHER THAN `waitForExit`'s because the interesting
    ## run is the one that overruns, and that is the run in which the daemon
    ## has to be INSPECTED before it is killed. `waitForExit(timeout)` kills
    ## on its own deadline and hands back 137 with nothing said about where
    ## the process was; this does the same escalation and records the wchan
    ## first. The escalation itself is not optional: an unbounded wait here
    ## would turn a failing case into a wedged binary.
    doAssert kill(Pid(daemon.processID), SIGTERM) == 0,
      "could not send SIGTERM to the daemon"
    let started = epochTime()
    var waited = 0
    while waited < budgetMillis and daemon.running:
      sleep(10)
      waited += 10
    if daemon.running:
      result.parked = parkedAt(daemon.processID)
      doAssert kill(Pid(daemon.processID), SIGKILL) == 0,
        "could not SIGKILL a daemon that outlasted its shutdown budget"
    result.exitCode = daemon.waitForExit()
    result.elapsedMillis = (epochTime() - started) * 1000.0

proc report(label: string; ending: Ending) =
  echo "  ", label, ": exit=", ending.exitCode, " after ",
    ending.elapsedMillis.formatFloat(ffDecimal, 1), " ms",
    (if ending.parked.len > 0:
       " -- OVERRAN THE BUDGET, main thread parked in " & ending.parked
     else: "")

suite "sigterm_exits_with_the_socket_gone":

  test "a TERMed daemon exits after its socket file has been unlinked":
    # POSIX ONLY, BY DESIGN: there is no SIGTERM on Windows, and no socket
    # file to unlink either -- the Windows endpoint is a named pipe, reached
    # by name rather than through the filesystem, so the hazard has no form
    # there. See the section headed "WINDOWS HAS NO SIGTERM, AND THAT IS NOT
    # THE SAME AS HAVING NO STOP" in `runquota_daemon`.
    when defined(posix):
      let root = scratchRoot("sock")
      let endpointDir = rendezvousDir(root)
      let socketPath = endpointDir / "d.sock"
      let state = hostStateDir(root)
      require fileExists(daemonPath())

      let bindDeadline = getMonoTime() + initDuration(milliseconds = BindBudgetMillis)
      var daemon = startDaemon(socketPath, state)
      var ending: Ending
      try:
        # THE PRECONDITION IS ASSERTED, not assumed. A daemon that never
        # reached its accept loop would pass every clause below by never
        # having been in `accept` at all.
        require endpointIsBound(socketPath)
        proveServing(socketPath, bindDeadline)
        removeFile(socketPath)
        require not fileExists(socketPath)
        # AND THE DIRECTORY IS STILL THERE, which is what makes this case
        # about the socket and nothing else.
        require dirExists(endpointDir)
        ending = termAndWait(daemon, ShutdownBudgetMillis)
      finally:
        if daemon.running:
          daemon.kill()
          discard daemon.waitForExit(5000)
        daemon.close()

      report("socket unlinked", ending)
      check ending.exitCode == 0
      check ending.elapsedMillis < float(ShutdownBudgetMillis)

      removeDir(root)
    else:
      skip()

  test "a TERMed daemon exits after its whole scratch tree has been removed":
    when defined(posix):
      let root = scratchRoot("tree")
      let endpointDir = rendezvousDir(root)
      let socketPath = endpointDir / "d.sock"
      let state = hostStateDir(root)
      require fileExists(daemonPath())

      let bindDeadline = getMonoTime() + initDuration(milliseconds = BindBudgetMillis)
      var daemon = startDaemon(socketPath, state)
      var ending: Ending
      try:
        require endpointIsBound(socketPath)
        proveServing(socketPath, bindDeadline)
        # EVERYTHING THE DAEMON WAS GIVEN, gone in one stroke: the socket,
        # the published stats table beside it, the host identity file and
        # the observation database. This is what happens to an orphan when
        # the caller that started it removes its scratch directory.
        removeStartingDaemonTree(root)
        require not fileExists(socketPath)
        require not dirExists(endpointDir)
        require not dirExists(state)
        ending = termAndWait(daemon, ShutdownBudgetMillis)
      finally:
        if daemon.running:
          daemon.kill()
          discard daemon.waitForExit(5000)
        daemon.close()

      report("scratch tree removed", ending)
      check ending.exitCode == 0
      check ending.elapsedMillis < float(ShutdownBudgetMillis)

      removeDir(root)
    else:
      skip()
