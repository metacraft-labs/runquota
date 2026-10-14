## `RUNQUOTA_EXIT_WITH_PARENT`: a daemon that stops when the process that
## started it is gone.
##
## WHO ASKS FOR THIS. `runquotad` is normally the host's one long-lived lease
## authority and outlives every client by design. But on an unprovisioned
## POSIX host `repro` starts a PRIVATE daemon for one invocation, on a per-PID
## socket, and that daemon is owned by the invocation: it must not outlive it,
## however the invocation ends (reprobuild-pm
## `spec/RunQuota-Host-Configuration.md`, "\"Terminated when the top-level
## build ends\" means however it ends"). `repro` forwards a terminating signal
## to the daemon itself, but no handler in `repro` can see SIGKILL or the OOM
## killer. Watching the parent from this side is the only half that covers
## those, which is why it lives here and not in the client.
##
## THE MECHANISM IS A RE-PARENTING CHECK, NOT `PR_SET_PDEATHSIG`. When a
## process's parent dies, the kernel re-parents it -- to init, or to the
## nearest subreaper -- so `getppid()` changes. That is POSIX, so it works the
## same on macOS, where `prctl` does not exist; and it is immune to the trap
## `PR_SET_PDEATHSIG` has on Linux, where the "parent" is the THREAD that
## forked, so a client that spawns from a short-lived worker thread would see
## its daemon killed when that thread exits.
##
## WHAT HAPPENS WHEN THE PARENT IS GONE. The watcher sends SIGTERM to its own
## process, so the stop takes EXACTLY the orderly path an operator's
## `kill -TERM` takes -- the drain, the joins, the store flush and exit 0 --
## rather than a second, less exercised way out. That path no longer depends
## on the socket file still existing
## (`tests/integration/t_sigterm_exits_with_the_socket_gone.nim`), which
## matters here: an orphan's caller has normally already removed its scratch
## directory.
##
## CALLERS MAY RECORD THE OWNER BEFORE SPAWN in
## `RUNQUOTA_EXIT_WITH_PARENT_PID`. This closes the startup race under a
## subreaper: if the caller dies before daemon entry, getppid() already names
## the subreaper, but the supplied expectation still names the real owner.
## Without this optional variable the daemon records getppid() at entry.
##
## A PARENT THAT IS ALREADY INIT AT START is treated as gone. With the variable
## set, the requester wanted this daemon tied to it; a `getppid()` of 1 at
## start means the requester died before the daemon got this far (or it never
## was the parent), and a daemon that adopted init as its owner would never
## stop.
##
## THE VARIABLE IS REMOVED FROM THE DAEMON'S OWN ENVIRONMENT as soon as it is
## read, so nothing this process starts -- the `sqlite3` children of the
## observation store, for one -- inherits a request that was addressed to this
## process alone.
##
## WINDOWS IGNORES THE VARIABLE. Its daemon serves the shared per-user pipe and
## is deliberately left running for invocations that adopted it, and it has no
## SIGTERM to route a stop through in any case.

import std/[atomics, os, strutils]

when defined(posix):
  import std/posix

const
  exitWithParentEnvVar* = "RUNQUOTA_EXIT_WITH_PARENT"
    ## Exactly the value `1` asks for the watch; any other value is removed
    ## from the environment and otherwise ignored.
  exitWithParentPidEnvVar* = "RUNQUOTA_EXIT_WITH_PARENT_PID"
    ## Optional expected parent, recorded by the caller BEFORE spawning.
    ## Avoids adopting a subreaper when the caller dies before main starts.
  parentWatchIntervalMillis* = 200
    ## How often the parent is checked. One `getppid()` per tick is nothing;
    ## the interval bounds how long an orphan lingers before its shutdown
    ## starts, and how long the watcher's join can delay a shutdown that
    ## started for another reason.

proc takeExitWithParentRequest*(): int =
  ## Reads and REMOVES `RUNQUOTA_EXIT_WITH_PARENT`. Answers the parent pid to
  ## watch -- supplied by the caller before spawning when
  ## `RUNQUOTA_EXIT_WITH_PARENT_PID` is present, otherwise recorded at entry
  ## -- or 0 when no watch was asked for (always 0 on Windows). Both variables
  ## are removed, so descendants cannot inherit the ownership request.
  ## Call it once, first thing in the daemon's entry point.
  when defined(posix):
    let requested = getEnv(exitWithParentEnvVar) == "1"
    let expectedParent = getEnv(exitWithParentPidEnvVar)
    delEnv(exitWithParentEnvVar)
    delEnv(exitWithParentPidEnvVar)
    if requested:
      result = int(getppid())
      if expectedParent.len > 0:
        # An invalid expectation must fail closed rather than adopt an
        # unrelated current parent and leave a daemon running indefinitely.
        try:
          result = parseInt(expectedParent)
          if result <= 0:
            result = 1
        except ValueError:
          result = 1
  else:
    result = 0

when defined(posix):
  var
    parentWatchThread: Thread[int]
    parentWatchRunning = false
    parentWatchStop: Atomic[bool]

  proc parentIsGone(parent: int): bool =
    parent <= 1 or int(getppid()) != parent

  proc parentWatchMain(parent: int) {.thread.} =
    while not parentWatchStop.load(moAcquire):
      if parentIsGone(parent):
        # THE OPERATOR'S STOP, self-addressed. See the module header.
        discard kill(getpid(), SIGTERM)
        return
      sleep(parentWatchIntervalMillis)

  proc startParentWatch*(parent: int) =
    ## Starts watching `parent` (as `takeExitWithParentRequest` answered it).
    ## A no-op for 0, and when a watch is already running. Call it only
    ## once the SIGTERM handler is armed: a watcher that fired earlier would
    ## meet SIGTERM's default disposition and end the process without the
    ## orderly shutdown.
    if parent == 0 or parentWatchRunning:
      return
    parentWatchStop.store(false, moRelease)
    createThread(parentWatchThread, parentWatchMain, parent)
    parentWatchRunning = true

  proc stopParentWatch*() =
    ## Stops and joins the watcher; costs at most one interval. Call it
    ## BEFORE the SIGTERM handler is disarmed, so a watcher firing in between
    ## cannot take the default disposition mid-shutdown.
    if not parentWatchRunning:
      return
    parentWatchStop.store(true, moRelease)
    joinThread(parentWatchThread)
    parentWatchRunning = false
else:
  proc startParentWatch*(parent: int) =
    discard parent

  proc stopParentWatch*() =
    discard
