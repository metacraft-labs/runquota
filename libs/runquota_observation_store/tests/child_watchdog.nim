## Supervising a test child that is *expected* to be able to wedge.
##
## Both deadlock regression tests in this directory run the call under test in
## a re-executed child, because a hung call cannot report its own failure. That
## makes the child's own children this test's responsibility.
##
## Killing the direct child is not enough. The processes a deadlock test wedges
## are its GRANDchildren, and the interesting ones are wedged precisely because
## they hold each other's pipes open -- so when the direct child dies they do
## not see end of input, do not exit, and are reparented to pid 1 where they sit
## forever. A red test that leaves two immortal `sqlite3` processes behind is a
## gate failure in a campaign whose rule is that a milestone leaves nothing
## running, and it is also actively misleading: the leftovers look like a live
## defect long after the run that produced them is gone.
##
## So the child is started as its own process-group leader and the whole group
## is signalled, which reaches every descendant however deep. `awaitNoSurvivors`
## then makes the absence of leftovers a checked property rather than a hope --
## it is asserted on the passing path too, where a leak would otherwise be
## invisible.

import std/[os, osproc, strutils, times]

when defined(posix):
  import std/posix

proc startSupervisedChild*(command: string; args: openArray[string]): Process =
  ## Start ``command`` as the leader of a new process group, so that everything
  ## it spawns can be signalled as a unit.
  ##
  ## ``poDaemon`` is what asks for the new process group; on POSIX that is all
  ## it does. ``poParentStreams`` keeps the child on this process's own stdio,
  ## so supervising it needs no pipes of our own -- which matters in tests
  ## whose entire subject is pipes.
  startProcess(
    command,
    args = @args,
    options = {poParentStreams, poDaemon}
  )

proc waitBounded*(process: Process; seconds: int): int =
  ## The child's exit code, or -1 if it was still running at the deadline.
  let deadline = epochTime() + float(seconds)
  while epochTime() < deadline:
    let code = process.peekExitCode()
    if code != -1:
      return code
    sleep(25)
  -1

proc killProcessTree*(process: Process) =
  ## SIGKILL the child's whole process group, then reap the child.
  ##
  ## The group is the point: a wedged grandchild holding a sibling's pipe will
  ## not exit just because its parent did, so signalling only the direct child
  ## is what strands it on pid 1.
  when defined(posix):
    discard posix.kill(Pid(-process.processID), SIGKILL)
  try:
    kill(process)
  except CatchableError:
    discard
  discard process.waitForExit()

proc survivingProcesses*(marker: string): seq[string] =
  ## Every process whose command line still mentions ``marker``.
  ##
  ## ``marker`` should be the run's unique temporary directory, which appears
  ## in the arguments of anything the child launched against it. Deleting that
  ## directory does not erase it from a running process's argv, so this still
  ## finds leftovers after cleanup.
  ##
  ## stderr is folded into stdout rather than left on an unread pipe -- the
  ## defect these tests exist for.
  let listing = execProcess(
    "ps",
    args = ["-axo", "pid=,command="],
    options = {poUsePath, poStdErrToStdOut}
  )
  for line in listing.splitLines():
    if marker in line and line.len > 0:
      result.add(line.strip())

proc awaitNoSurvivors*(marker: string; seconds: int): seq[string] =
  ## Poll until nothing mentioning ``marker`` is left, or the deadline passes.
  ## Returns whatever is still alive, so a caller can report it.
  let deadline = epochTime() + float(seconds)
  while true:
    result = survivingProcesses(marker)
    if result.len == 0:
      return
    if epochTime() >= deadline:
      return
    sleep(100)
