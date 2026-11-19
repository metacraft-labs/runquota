## A STALE OR MISSING APP BINARY FAILS THE TEST WITHOUT ORPHANING WHAT THE
## TEST ALREADY STARTED.
##
## `tests/support/daemon_binary` refuses a `build/bin` app that predates its
## sources, because such a binary makes a test report a result that belongs
## to the build. It used to refuse by calling `quit(1)`, and `quit` does not
## unwind: no `finally`, no `defer` runs. `daemonPath()` and `cliPath()` were
## resolved independently, so a test (or a fixture: the Windows fixture's
## `startDaemon` resolves the CLI only while waiting for the daemon it has
## just spawned) could start a real `runquotad` with a fresh daemon binary
## and THEN be refused the CLI -- exiting with the daemon still running,
## reparented and holding its endpoint. Leftover `runquotad.exe` processes
## accumulated on a Windows host this way (reprobuild-pm
## `issues/2026-11-16-daemon-binary-staleness-guard-quits-after-a-caller-already-spawned-a-daemon.md`;
## the sibling hazard in `unittest.require` is `unwinding_require.nim`).
##
## The properties protected here:
##   1. A refusal RAISES `AppBinaryUnusable`, a `CatchableError`, so the
##      caller's `finally` stops the process it already started.
##   2. `daemonPath()` refuses an unusable CLI too, so the common order --
##      daemon first, CLI later -- is refused before any daemon exists.
##   3. The refusal still names the binary and says STALE / not built.
##
## THE ONE STAND-IN, justified: the process the test "already started" is
## this test binary re-executed as a sleeper, not a real `runquotad`. The
## property is the control flow of `daemon_binary` after a process exists;
## what the process is does not enter into it, and a real daemon would make
## this test depend on built apps -- the very input whose staleness it
## fabricates. The binaries under `build/bin` in the scratch tree are never
## executed; only their modification times are read, which is all
## `daemon_binary` reads. Everything else is production code.

import std/[exitprocs, os, osproc, strutils, tempfiles, times, unittest]

import daemon_binary

const SleeperRole = "--stale-binary-test-sleeper"

if paramCount() >= 1 and paramStr(1) == SleeperRole:
  sleep(120_000)
  quit(0)

var sentinel: Process = nil
  ## The live child standing in for an already-spawned daemon. Module-level
  ## so the exit hook below can see it.
var liveTree = ""
  ## The scratch tree in use, for the exit hook to remove on a `quit`.

proc stopSentinel() =
  if sentinel != nil:
    try:
      if sentinel.running:
        sentinel.kill()
        discard sentinel.waitForExit(10_000)
      sentinel.close()
    except CatchableError:
      discard
    sentinel = nil

# `quit` runs exit procs even though it skips `finally`. Should the refusal
# ever go back to `quit`, this reports the orphan the test was built to
# provoke -- and still reaps it, so a red run leaves nothing behind.
addExitProc(proc () {.noconv.} =
  if sentinel != nil and sentinel.running:
    stderr.writeLine("ORPHANED: the stand-in daemon (pid " &
      $sentinel.processID & ") was still running when the process exited; " &
      "no `finally` ran")
    stopSentinel()
  if liveTree.len > 0:
    try: removeDir(liveTree) except CatchableError: discard)

proc touch(path: string; stamp: Time) =
  createDir(path.parentDir)
  writeFile(path, "")
  setLastModificationTime(path, stamp)

proc scratchTree(staleCli: bool): string =
  ## A tree shaped like a runquota checkout: one source under `apps`, a fresh
  ## `runquotad`, and a `runquota` that is fresh or predates the source.
  result = createTempDir("rq-stale-binary-", "")
  let source = getTime() - initDuration(hours = 1)
  touch(result / "apps" / "runquota" / "runquota.nim", source)
  touch(result / "build" / "bin" / addFileExt("runquotad", ExeExt),
    source + initDuration(minutes = 1))
  touch(result / "build" / "bin" / addFileExt("runquota", ExeExt),
    if staleCli: source - initDuration(minutes = 1)
    else: source + initDuration(minutes = 1))

template inTree(tree: string; body: untyped) =
  let previous = getCurrentDir()
  liveTree = tree
  setCurrentDir(tree)
  try:
    body
  finally:
    setCurrentDir(previous)
    removeDir(tree)
    liveTree = ""

suite "a refused app binary unwinds":
  test "a CLI refused after a process was started lets its finally stop it":
    # The first property in isolation: resolve the daemon without the
    # coupled CLI check by using a fresh CLI, start the process, then make
    # the CLI stale -- sources touched between the two resolutions, as in a
    # long session.
    let tree = scratchTree(staleCli = false)
    inTree tree:
      discard daemonPath()
      var raised = ""
      try:
        sentinel = startProcess(getAppFilename(), args = [SleeperRole])
        check sentinel.running
        setLastModificationTime(tree / "build" / "bin" /
          addFileExt("runquota", ExeExt), getTime() - initDuration(hours = 2))
        discard cliPath()
      except AppBinaryUnusable as refusal:
        raised = refusal.msg
      finally:
        # Reached only because the refusal raised; under `quit` the exit
        # hook reports the orphan instead.
        stopSentinel()
      check "runquota is STALE" in raised
      check "rebuild" in raised

  test "daemonPath refuses a stale CLI before any daemon exists":
    let tree = scratchTree(staleCli = true)
    inTree tree:
      var raised = ""
      try:
        discard daemonPath()
      except AppBinaryUnusable as refusal:
        raised = refusal.msg
      check "runquota is STALE" in raised

  test "a missing binary is refused by raising, with the build command":
    let tree = scratchTree(staleCli = false)
    inTree tree:
      removeFile(tree / "build" / "bin" / addFileExt("runquotad", ExeExt))
      var raised = ""
      try:
        discard daemonPath()
      except AppBinaryUnusable as refusal:
        raised = refusal.msg
      check "runquotad is not built" in raised
      check "scripts/build_apps.sh" in raised

  test "a missing CLI is refused by daemonPath before any daemon exists":
    let tree = scratchTree(staleCli = false)
    inTree tree:
      removeFile(tree / "build" / "bin" / addFileExt("runquota", ExeExt))
      var raised = ""
      try:
        discard daemonPath()
      except AppBinaryUnusable as refusal:
        raised = refusal.msg
      check "runquota is not built" in raised

  test "fresh binaries resolve to build/bin":
    let tree = scratchTree(staleCli = false)
    inTree tree:
      check daemonPath().endsWith(addFileExt("runquotad", ExeExt))
      check cliPath().endsWith(addFileExt("runquota", ExeExt))
