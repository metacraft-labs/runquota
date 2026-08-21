## ``hardware.runTool`` must survive both ways a child process can wedge it.
##
## It runs on the daemon's STARTUP path -- ``detectHardwareProfile`` calls it
## once per detection tool -- so a wedge here is a daemon that never finishes
## starting, with nothing on a timer to notice.
##
## TWO DEFECTS, ONE PER TEST.
##
## * Stderr was never read. The old body read ``outputStream`` to EOF and
##   touched no other stream. A pipe holds a bounded amount before a write to
##   it blocks -- 65_536 bytes as measured on the development host, and it does
##   not grow with the size of the write -- so a tool that puts more than that
##   on stderr blocks in ``write(2)``, never exits, never closes stdout, and
##   the ``readAll`` never returns.
## * Concurrent spawns took each other's pipes. ``osproc`` creates the
##   parent-side pipes with a plain ``pipe(2)`` -- Darwin has no ``pipe2`` --
##   and hands them to ``posix_spawn``, whose file actions close only its own
##   descriptors. Two threads spawning at the same instant each inherit the
##   other's pipes and both block in ``read(2)`` for as long as the process
##   lives.
##
## The second test races ``runTool`` against ``runSqlite``, not against itself.
## That is the case a guard taken by only *some* callers does not cover: the
## theft happens inside the other call's ``startProcess``, so one unguarded
## spawner anywhere in the process is enough to wedge a guarded one. Both
## sides have to be on the shared guarded helper for this to pass.
##
## Structure, as in the two ``sqlite_cli`` deadlock tests: a wedged call cannot
## report its own failure, so the work runs in a re-executed child that the
## parent waits on with a bounded deadline, turning a hang into a red result.
##
## No mocks. ``runTool`` spawns the real ``/bin/sh``; the concurrency test
## spawns the real ``sqlite3`` alongside it. Only the *scheduling* of the calls
## is test-owned.

import std/[atomics, os, osproc, strutils, tempfiles, unittest]

import runquota_observation_store/hardware
import runquota_observation_store/sqlite_cli

import ./child_watchdog

const
  FloodFlag = "--run-tool-flood-child"
  RaceFlag = "--run-tool-race-child"

  Shell = "/bin/sh"
  StdoutMarker = "RUNTOOL-STDOUT"

  ## 600 x (512 payload bytes + newline) = 307_800 bytes on stderr, more than
  ## 4x the measured pipe capacity, so the test cannot pass by accident on a
  ## host whose pipes are somewhat larger than this one's.
  StderrRows = 600
  StderrPayloadBytes = 512
  MeasuredPipeCapacityBytes = 65_536

  ## Two threads is what the daemon actually runs, and the spawn window is
  ## entered on essentially every iteration. Against an unguarded helper this
  ## wedges well inside this count.
  RaceIterations = 200

  ChildDeadlineSeconds = 60
  SurvivorGraceSeconds = 10

proc floodScript(workDir: string): string =
  ## One line of stdout, then a flood on stderr, then stdout again. The
  ## trailing stdout line is what proves the tool was still able to make
  ## progress after the stderr pipe had been filled -- an "ordering fix" that
  ## merely read stderr first would lose it.
  "echo " & StdoutMarker & "-HEAD; " &
  "i=0; while [ $i -lt " & $StderrRows & " ]; do " &
  "printf '%0" & $StderrPayloadBytes & "d\\n' $i >&2; " &
  "i=$((i+1)); done; " &
  "echo " & StdoutMarker & "-TAIL" &
  # The run's temporary directory, in a shell comment, so that a wedged shell
  # still carries the marker `awaitNoSurvivors` looks for in its argv.
  " # " & workDir

proc runFloodChild(workDir, resultPath: string) =
  let output = runTool(Shell, ["-c", floodScript(workDir)])
  var report = ""
  report.add("head=" & $((StdoutMarker & "-HEAD") in output) & "\n")
  report.add("tail=" & $((StdoutMarker & "-TAIL") in output) & "\n")
  report.add("outputBytes=" & $output.len & "\n")
  writeFile(resultPath, report)

type
  RacePlan = object
    dbPath: string
    workDir: string
    iterations: int
    completed: Atomic[int]
    failures: Atomic[int]

var
  toolPlan: RacePlan
  sqlitePlan: RacePlan
  toolWorker: Thread[ptr RacePlan]
  sqliteWorker: Thread[ptr RacePlan]

proc toolRaceWorker(plan: ptr RacePlan) {.thread.} =
  for _ in 0 ..< plan.iterations:
    # The tool READS TO END OF INPUT before it answers, which is what makes
    # this a test of descriptor inheritance rather than of process startup.
    # A stolen stdin write end is only fatal to a child that waits for EOF;
    # one that exits regardless releases the descriptor on its own and the
    # theft heals itself. Both sides of this race wait for EOF -- `sqlite3
    # -batch` does too -- so when they take each other's pipes neither can
    # ever exit, which is the shape of the observed daemon stall.
    let script = "cat >/dev/null; echo " & StdoutMarker & " # " & plan.workDir
    if runTool(Shell, ["-c", script]).strip() != StdoutMarker:
      plan.failures.atomicInc()
    plan.completed.atomicInc()

proc sqliteRaceWorker(plan: ptr RacePlan) {.thread.} =
  for _ in 0 ..< plan.iterations:
    if not runSqlite(plan.dbPath, "select 1;").ok:
      plan.failures.atomicInc()
    plan.completed.atomicInc()

proc runRaceChild(workDir, resultPath: string) =
  toolPlan.workDir = workDir
  toolPlan.iterations = RaceIterations
  sqlitePlan.dbPath = workDir / "race.db"
  sqlitePlan.iterations = RaceIterations
  createThread(toolWorker, toolRaceWorker, addr toolPlan)
  createThread(sqliteWorker, sqliteRaceWorker, addr sqlitePlan)
  joinThread(toolWorker)
  joinThread(sqliteWorker)

  var report = ""
  report.add("completed=" &
    $(toolPlan.completed.load() + sqlitePlan.completed.load()) & "\n")
  report.add("failures=" &
    $(toolPlan.failures.load() + sqlitePlan.failures.load()) & "\n")
  writeFile(resultPath, report)

proc reportField(report: string; key: string): string =
  for line in report.splitLines():
    let separator = line.find('=')
    if separator > 0 and line[0 ..< separator] == key:
      return line[separator + 1 .. ^1]
  ""

# The child roles must be dispatched before `unittest` takes over the process.
if paramCount() >= 3 and paramStr(1) == FloodFlag:
  runFloodChild(paramStr(2), paramStr(3))
  quit(0)
if paramCount() >= 3 and paramStr(1) == RaceFlag:
  runRaceChild(paramStr(2), paramStr(3))
  quit(0)

suite "hardware runTool stream hygiene":
  test "a tool flooding stderr past the pipe buffer does not wedge detection":
    when defined(windows):
      skip()
    else:
      let work = createTempDir("runquota_run_tool_flood_", "")
      defer: removeDir(work)
      let resultPath = work / "result.txt"

      let child = startSupervisedChild(
        getAppFilename(), [FloodFlag, work, resultPath])
      let code = waitBounded(child, ChildDeadlineSeconds)
      if code == -1:
        # The blocked shell is a grandchild; signalling only `child` strands it.
        killProcessTree(child)
        child.close()
        checkpoint(
          "runTool did not return within " & $ChildDeadlineSeconds &
          "s. The tool filled the " & $MeasuredPipeCapacityBytes &
          "-byte stderr pipe and blocked in write(2) while runTool blocked " &
          "in read(2) draining stdout to EOF.")
        fail()
      else:
        child.close()
        check code == 0
        check fileExists(resultPath)
        let report = readFile(resultPath)

        # stdout is delivered whole: the line before the flood and the line
        # after it.
        check report.reportField("head") == "true"
        check report.reportField("tail") == "true"

        # stderr must not have been merged into stdout. `runTool` feeds
        # `profileHash`, so folding a tool's diagnostics into its answer would
        # fork the machine's history on every warning it ever emitted.
        check report.reportField("outputBytes").parseInt() <
          MeasuredPipeCapacityBytes

      let survivors = awaitNoSurvivors(work, SurvivorGraceSeconds)
      if survivors.len > 0:
        checkpoint("processes still alive after the test: " &
          survivors.join("; "))
      check survivors.len == 0

  test "runTool racing another RunQuota spawner does not steal its pipes":
    when defined(windows):
      skip()
    else:
      let work = createTempDir("runquota_run_tool_race_", "")
      defer: removeDir(work)
      let resultPath = work / "result.txt"

      let child = startSupervisedChild(
        getAppFilename(), [RaceFlag, work, resultPath])
      let code = waitBounded(child, ChildDeadlineSeconds)
      if code == -1:
        killProcessTree(child)
        child.close()
        checkpoint(
          "two threads x " & $RaceIterations &
          " spawns did not finish within " & $ChildDeadlineSeconds &
          "s. Concurrent startProcess calls leaked each other's pipe " &
          "descriptors into the spawned children, so the children never saw " &
          "end of input and the callers never saw EOF.")
        fail()
      else:
        child.close()
        check code == 0
        check fileExists(resultPath)
        let report = readFile(resultPath)

        # Every call has to have completed *and* succeeded. Counting
        # completions is what keeps this from passing on a child that exited
        # early.
        check report.reportField("completed").parseInt() == 2 * RaceIterations
        check report.reportField("failures").parseInt() == 0

      let survivors = awaitNoSurvivors(work, SurvivorGraceSeconds)
      if survivors.len > 0:
        checkpoint("processes still alive after the test: " &
          survivors.join("; "))
      check survivors.len == 0
