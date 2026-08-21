## Two threads calling ``runSqlite`` at the same moment must both finish.
##
## ``std/osproc`` creates the three parent-side pipes for a child with a plain
## ``pipe(2)`` -- Darwin has no ``pipe2`` -- and then hands them to
## ``posix_spawn``, whose file actions close only the descriptors belonging to
## that one call. Descriptors another thread created moments earlier are still
## inheritable, so its child gets them too. A child holding the write end of
## another child's stdin keeps that child from ever seeing end of input, so it
## never exits; a child holding the write end of another child's stdout keeps
## the reading parent from ever seeing EOF. Both threads then block in
## ``read(2)`` for as long as the process lives.
##
## This is the defect behind the observed 27-minute stall in the daemon, which
## began running the ambient sampler alongside the spine writer -- two threads
## reaching SQLite through this helper.
##
## The two threads here use **separate database files**, so there is no lock
## to contend for and ``.timeout`` never comes into it. That is deliberate:
## it isolates descriptor inheritance from busy-timeout contention, which is a
## different subject entirely.
##
## Structure, as in ``t_sqlite_cli_stream_backpressure``: a wedged call cannot
## report its own failure, so the work runs in a re-executed child that the
## parent waits on with a bounded deadline, turning a hang into a red result.
##
## No mocks: the production helper spawns the production ``sqlite3``.

import std/[atomics, os, osproc, strutils, tempfiles, times, unittest]

import runquota_observation_store/sqlite_cli

const
  ChildFlag = "--concurrent-spawn-child"

  ## Two is the number that matters -- it is what the daemon actually runs --
  ## and the window is entered on essentially every iteration, so a few dozen
  ## rounds is ample. Against the unguarded helper this wedges within the
  ## first handful.
  SpawnThreads = 2
  IterationsPerThread = 50

  ChildDeadlineSeconds = 60

type
  SpawnPlan = object
    dbPath: string
    iterations: int
    completed: Atomic[int]
    failures: Atomic[int]

var
  plans: array[SpawnThreads, SpawnPlan]
  workers: array[SpawnThreads, Thread[ptr SpawnPlan]]

proc spawnWorker(plan: ptr SpawnPlan) {.thread.} =
  for _ in 0 ..< plan.iterations:
    let outcome = runSqlite(plan.dbPath, "select 1;")
    if not outcome.ok:
      plan.failures.atomicInc()
    plan.completed.atomicInc()

proc runConcurrentChild(workDir, resultPath: string) =
  for index in 0 ..< SpawnThreads:
    plans[index].dbPath = workDir / ("store-" & $index & ".db")
    plans[index].iterations = IterationsPerThread
  for index in 0 ..< SpawnThreads:
    createThread(workers[index], spawnWorker, addr plans[index])
  for index in 0 ..< SpawnThreads:
    joinThread(workers[index])

  var completed = 0
  var failures = 0
  for index in 0 ..< SpawnThreads:
    completed += plans[index].completed.load()
    failures += plans[index].failures.load()

  var report = ""
  report.add("completed=" & $completed & "\n")
  report.add("failures=" & $failures & "\n")
  writeFile(resultPath, report)

proc reportField(report: string; key: string): string =
  for line in report.splitLines():
    let separator = line.find('=')
    if separator > 0 and line[0 ..< separator] == key:
      return line[separator + 1 .. ^1]
  ""

proc waitBounded(process: Process; seconds: int): int =
  ## The child's exit code, or -1 if it was still running at the deadline.
  let deadline = epochTime() + float(seconds)
  while epochTime() < deadline:
    let code = process.peekExitCode()
    if code != -1:
      return code
    sleep(25)
  -1

# The child role must be dispatched before `unittest` takes over the process.
if paramCount() >= 3 and paramStr(1) == ChildFlag:
  runConcurrentChild(paramStr(2), paramStr(3))
  quit(0)

suite "sqlite_cli concurrent spawn":
  test "two threads spawning at once do not inherit each other's pipes":
    let work = createTempDir("runquota_sqlite_concurrent_", "")
    defer: removeDir(work)
    let resultPath = work / "result.txt"

    let child = startProcess(
      getAppFilename(),
      args = [ChildFlag, work, resultPath],
      options = {poParentStreams}
    )
    let code = waitBounded(child, ChildDeadlineSeconds)
    if code == -1:
      kill(child)
      discard child.waitForExit()
      child.close()
      checkpoint(
        $SpawnThreads & " threads x " & $IterationsPerThread &
        " runSqlite calls did not finish within " & $ChildDeadlineSeconds &
        "s. Concurrent startProcess calls leaked each other's pipe " &
        "descriptors into the spawned children, so the children never saw " &
        "end of input and the callers never saw EOF.")
      fail()
    else:
      child.close()
      check code == 0
      check fileExists(resultPath)
      let report = readFile(resultPath)

      # Every call has to have completed *and* succeeded. Counting completions
      # is what keeps this from passing on a child that exited early.
      check report.reportField("completed").parseInt() ==
        SpawnThreads * IterationsPerThread
      check report.reportField("failures").parseInt() == 0
