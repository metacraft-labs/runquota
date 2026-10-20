## `tests/support/child_watchdog` keeps the promise its callers rely on, on
## every platform it is compiled for.
##
## Every deadlock regression test here runs the call under test in a
## re-executed child and, when the child wedges, calls `killProcessTree` and
## then asserts `awaitNoSurvivors`. Both halves are only worth anything if the
## helper really reaches the GRANDchildren -- the processes a deadlock test
## actually wedges -- and really sees them in its survivor inventory. On
## Windows it did neither: `killProcessTree` ended the direct child alone, and
## `survivingProcesses` ran `ps -axo pid=,command=`, which MSYS `ps` rejects
## (`unknown option -- x`) and which in any case does not list native Windows
## command lines. A wedged grandchild therefore outlived the test, and the
## survivor check that was meant to report it answered "none".
##
## So this file builds the real shape: a supervised child that starts a
## grandchild carrying the run's marker in its argv, publishes both pids, and
## then wedges. The grandchild's pid is checked INDEPENDENTLY of the helper --
## with the operating system's own liveness query, not with
## `survivingProcesses` -- before and after `killProcessTree`, so neither half
## of the helper can vouch for the other.
##
## No mocks, no daemon, no `sqlite3`: the processes are this binary,
## re-executed in three roles.

import std/[os, osproc, strutils, tempfiles, times, unittest]

import child_watchdog

when defined(windows):
  import std/winlean
else:
  import std/posix

const
  GrandchildFlag = "--watchdog-grandchild"
  WedgedChildFlag = "--watchdog-wedged-child"
  OrphaningChildFlag = "--watchdog-orphaning-child"
  CleanChildFlag = "--watchdog-clean-child"

  ## How long a role sleeps in total. Far longer than any assertion below
  ## waits, so a process that is gone at the end was ended, not finished.
  RoleLifetimeSeconds = 300

  PublishDeadlineSeconds = 60
  SurvivorGraceSeconds = 10

proc publish(path, text: string) =
  ## The parent's existence check must never see a half-written record.
  let pending = path & ".pending"
  writeFile(pending, text)
  moveFile(pending, path)

proc awaitFile(path: string; seconds: int): bool =
  let deadline = epochTime() + float(seconds)
  while epochTime() < deadline:
    if fileExists(path):
      return true
    sleep(20)
  false

proc wedge() =
  for _ in 0 ..< RoleLifetimeSeconds * 20:
    sleep(50)

# The roles must be dispatched before `unittest` takes over the process.
if paramCount() >= 3 and paramStr(1) == GrandchildFlag:
  # `paramStr(2)` is the marker: it is in this process's argv for as long as
  # it lives, which is what `survivingProcesses` searches.
  publish(paramStr(3), $getCurrentProcessId())
  wedge()
  quit(0)

if paramCount() >= 3 and paramStr(1) == WedgedChildFlag:
  let marker = paramStr(2)
  let readyPath = paramStr(3)
  let grandchildReady = marker / "grandchild-ready"
  let grandchild = startProcess(getAppFilename(),
    args = [GrandchildFlag, marker, grandchildReady],
    options = {poParentStreams})
  if not awaitFile(grandchildReady, PublishDeadlineSeconds):
    quit(2)
  publish(readyPath, $getCurrentProcessId() & "\n" &
    readFile(grandchildReady).strip() & "\n" & $grandchild.processID & "\n")
  # Never reaps or closes the grandchild: this is the wedged shape.
  wedge()
  quit(0)

if paramCount() >= 3 and paramStr(1) == OrphaningChildFlag:
  # Starts the same wedged grandchild and then exits at once, leaving it with
  # a parent that no longer exists. Windows never reparents, so no parent-pid
  # walk can reach it any more; the POSIX process group outlives its leader.
  let marker = paramStr(2)
  let readyPath = paramStr(3)
  let grandchildReady = marker / "grandchild-ready"
  let grandchild = startProcess(getAppFilename(),
    args = [GrandchildFlag, marker, grandchildReady],
    options = {poParentStreams})
  if not awaitFile(grandchildReady, PublishDeadlineSeconds):
    quit(2)
  publish(readyPath, $getCurrentProcessId() & "\n" &
    readFile(grandchildReady).strip() & "\n" & $grandchild.processID & "\n")
  quit(0)

if paramCount() >= 3 and paramStr(1) == CleanChildFlag:
  let marker = paramStr(2)
  let readyPath = paramStr(3)
  # A grandchild that exits on its own, so the clean path has descendants
  # too and the survivor check has something it must NOT report.
  let grandchild = startProcess(getAppFilename(),
    args = [GrandchildFlag & "-exit", marker], options = {poParentStreams})
  let code = grandchild.waitForExit()
  grandchild.close()
  publish(readyPath, "grandchild-exit=" & $code & "\n")
  quit(if code == 0: 0 else: 3)

if paramCount() >= 2 and paramStr(1) == GrandchildFlag & "-exit":
  quit(0)

# ---------------------------------------------------------------------------
# The independent control: the operating system's own answer
# ---------------------------------------------------------------------------

when defined(windows):
  proc pidIsAlive(pid: int): bool =
    ## Asked of the kernel through a fresh handle. A process that has exited
    ## but is still referenced reports signalled; one that is fully gone
    ## cannot be opened at all. Both are "not alive".
    let handle = openProcess(PROCESS_QUERY_LIMITED_INFORMATION or SYNCHRONIZE,
      0, DWORD(pid))
    if handle == 0:
      return false
    defer: discard closeHandle(handle)
    waitForSingleObject(handle, 0) == WAIT_TIMEOUT

  proc forceKillPid(pid: int) =
    ## Cleanup only, so a red run against a helper that misses descendants
    ## does not leave this file's own processes behind.
    if pid <= 0:
      return
    let handle = openProcess(PROCESS_TERMINATE or SYNCHRONIZE, 0, DWORD(pid))
    if handle != 0:
      discard terminateProcess(handle, 1)
      discard waitForSingleObject(handle, 5000)
      discard closeHandle(handle)
else:
  proc pidIsAlive(pid: int): bool =
    ## `kill(pid, 0)` delivers nothing and only asks whether the pid exists.
    ## A zombie still exists, so reap it first if it is ours to reap.
    var status: cint
    discard waitpid(Pid(pid), status, WNOHANG)
    posix.kill(Pid(pid), 0) == 0

  proc forceKillPid(pid: int) =
    if pid > 0:
      discard posix.kill(Pid(pid), SIGKILL)

proc awaitDead(pid: int; seconds: int): bool =
  let deadline = epochTime() + float(seconds)
  while true:
    if not pidIsAlive(pid):
      return true
    if epochTime() >= deadline:
      return false
    sleep(50)

proc mentions(survivors: seq[string]; pid: int): bool =
  ## Each survivor line starts with its pid, as `ps -o pid=,command=` prints.
  for line in survivors:
    let fields = line.splitWhitespace()
    if fields.len > 0 and fields[0] == $pid:
      return true
  false

suite "child_watchdog":
  test "a wedged child's grandchild is seen alive and is ended with the tree":
    let work = createTempDir("runquota_child_watchdog_", "")
    defer: removeDir(work)
    let readyPath = work / "ready"

    var childPid = 0
    var grandchildPid = 0
    defer:
      forceKillPid(grandchildPid)
      forceKillPid(childPid)

    let child = startSupervisedChild(getAppFilename(),
      [WedgedChildFlag, work, readyPath])
    childPid = child.processID
    require awaitFile(readyPath, PublishDeadlineSeconds)
    let published = readFile(readyPath).splitLines()
    require published.len >= 3
    check parseInt(published[0]) == childPid
    grandchildPid = parseInt(published[1])
    # The pid the grandchild reported for itself and the pid its parent's
    # `startProcess` returned are the same process: the control names the
    # process it means.
    check parseInt(published[2]) == grandchildPid
    check grandchildPid > 0
    check grandchildPid != childPid

    # THE CONTROL: both really are alive, by the kernel's account.
    check pidIsAlive(childPid)
    check pidIsAlive(grandchildPid)

    # The survivor inventory sees them -- by the marker in their argv. If it
    # cannot see a process the kernel says is alive, its "no survivors"
    # below would mean nothing.
    let before = survivingProcesses(work)
    checkpoint("survivors before the kill: " & before.join("; "))
    check before.mentions(childPid)
    check before.mentions(grandchildPid)

    # The child is wedged, which is the path every caller takes.
    check waitBounded(child, 1) == -1
    killProcessTree(child)
    child.close()

    # The whole tree is gone, by both accounts.
    check awaitDead(childPid, SurvivorGraceSeconds)
    check awaitDead(grandchildPid, SurvivorGraceSeconds)
    let after = awaitNoSurvivors(work, SurvivorGraceSeconds)
    checkpoint("survivors after the kill: " & after.join("; "))
    check after.len == 0

  test "a grandchild orphaned by its exited parent is ended with the tree":
    let work = createTempDir("runquota_child_watchdog_orphan_", "")
    defer: removeDir(work)
    let readyPath = work / "ready"

    var grandchildPid = 0
    defer: forceKillPid(grandchildPid)

    let child = startSupervisedChild(getAppFilename(),
      [OrphaningChildFlag, work, readyPath])
    let childPid = child.processID
    require awaitFile(readyPath, PublishDeadlineSeconds)
    let published = readFile(readyPath).splitLines()
    require published.len >= 3
    check parseInt(published[0]) == childPid
    grandchildPid = parseInt(published[1])
    check parseInt(published[2]) == grandchildPid
    check grandchildPid > 0
    check grandchildPid != childPid

    # The child really has gone, and the grandchild really has not.
    check waitBounded(child, PublishDeadlineSeconds) == 0
    check pidIsAlive(grandchildPid)
    let before = survivingProcesses(work)
    checkpoint("survivors before the kill: " & before.join("; "))
    check before.mentions(grandchildPid)

    killProcessTree(child)
    child.close()

    check awaitDead(grandchildPid, SurvivorGraceSeconds)
    let after = awaitNoSurvivors(work, SurvivorGraceSeconds)
    checkpoint("survivors after the kill: " & after.join("; "))
    check after.len == 0

  test "a child that exits cleanly reports its code and leaves no survivors":
    let work = createTempDir("runquota_child_watchdog_clean_", "")
    defer: removeDir(work)
    let readyPath = work / "ready"

    let child = startSupervisedChild(getAppFilename(),
      [CleanChildFlag, work, readyPath])
    let code = waitBounded(child, PublishDeadlineSeconds)
    if code == -1:
      killProcessTree(child)
    child.close()
    check code == 0
    check fileExists(readyPath)
    if fileExists(readyPath):
      check readFile(readyPath).strip() == "grandchild-exit=0"
    let survivors = awaitNoSurvivors(work, SurvivorGraceSeconds)
    checkpoint("survivors: " & survivors.join("; "))
    check survivors.len == 0
