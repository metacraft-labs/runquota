## THE DAEMON BINARY IS AN INPUT, SO STALENESS IS A WRONG ANSWER RATHER
## THAN A MISSING ONE.
##
## Three integration files start `build/bin/runquotad` as a real process
## over a real socket, and each one used to resolve the path with its own
## private `daemonPath()`. Every one of them carried a comment saying the
## binary is an INPUT to the test and not an output of compiling it --
## `scripts/run_tests.sh` builds the apps first, an ad-hoc `nim c -r` of a
## test file does not. Documenting the hazard is all any of them did.
##
## THE DEFECT THAT MOTIVATED THIS, and it is not hypothetical. A change
## that spans the client and the daemon -- a new `LeaseFinishKind`, say --
## recompiles the test and the client library but leaves an older
## `runquotad` in place. `leaseFinishFromWire` bounds the wire ordinal by
## the RECEIVER's `high()`, so the old daemon refuses the new frame and the
## lease strands. The test then reports a failure that belongs to the
## build, and the failure looks exactly like a defect in the code under
## test. It was misattributed as a pre-existing failure of an unrelated
## test before this check existed.
##
## WHY REFUSE RATHER THAN REBUILD. A helper that quietly rebuilt would fix
## the run and hide the fact that the run was about to lie, which leaves
## the next person to rediscover it. The stale binary is a statement about
## how the suite was invoked, so the repair belongs at the invocation.
##
## WHY MTIME AND NOT A HASH. The comparison only has to be conservative in
## the safe direction. A checkout that stamps sources newer than a valid
## binary reports stale and costs a rebuild; nothing reports fresh when it
## is not, which is the only direction that can produce a wrong green.
##
## WHY RAISE AND NOT QUIT. A refusal used to `quit(1)`, and `quit` does not
## unwind: no `finally`, no `defer` runs. A test that had already started a
## `runquotad` and was then refused the CLI exited with the daemon still
## running, reparented and holding its endpoint; leftover `runquotad.exe`
## processes accumulated on a Windows host that way (reprobuild-pm
## `issues/2026-11-16-daemon-binary-staleness-guard-quits-after-a-caller-already-spawned-a-daemon.md`,
## the same shape as the `unittest.require` hazard `unwinding_require`
## answers). A refusal now raises `AppBinaryUnusable`, a `CatchableError`:
## every enclosing `finally` stops what the test started, and unittest's
## per-test handler reports the test failed with the message, so nothing is
## lost in reporting. And `daemonPath()` checks the CLI as well, so the usual
## order -- daemon first, CLI later -- is refused before a daemon exists.
## `tests/unit/t_stale_binary_refusal_unwinds.nim` holds both properties.

import std/[os, strutils, times]

type
  AppBinaryUnusable* = object of CatchableError
    ## An app under `build/bin` is missing or older than its sources.

proc newestSourceTime(dir: string): (Time, string) =
  ## Newest modification time under `dir`, with the file that carries it.
  result = (fromUnix(0), "")
  if not dirExists(dir):
    return
  for path in walkDirRec(dir):
    if not path.endsWith(".nim") and not path.endsWith(".nims"):
      continue
    let stamp = getLastModificationTime(path)
    if stamp > result[0]:
      result = (stamp, path)

proc checkedBinary(name: string): string =
  ## `build/bin/<name>`, checked to be at least as new as every source it
  ## is built from. Raises `AppBinaryUnusable` with an actionable message
  ## otherwise -- never `quit`, which would skip the caller's cleanup.
  # `addFileExt`, not `name & ExeExt`: Nim's `ExeExt` has no dot ("exe" on
  # Windows, "" elsewhere), and `nim c --out:build/bin/runquotad` writes
  # `runquotad.exe` on Windows. Without the extension this looked for a file
  # the build never writes -- and found a stray extensionless one when a
  # host had one lying about, which it then reported as stale.
  result = getCurrentDir() / "build" / "bin" / addFileExt(name, ExeExt)

  if not fileExists(result):
    raise newException(AppBinaryUnusable, name & " is not built.\n" &
      "  expected: " & result & "\n" &
      "  build it: scripts/run_tests.sh (builds the apps first), or\n" &
      "            scripts/build_apps.sh\n" &
      "This file is an INPUT to the integration tests, not an output of " &
      "compiling them.")

  let binaryTime = getLastModificationTime(result)
  var stalest = fromUnix(0)
  var culprit = ""
  for sourceDir in ["libs", "apps"]:
    let (stamp, path) = newestSourceTime(getCurrentDir() / sourceDir)
    if stamp > binaryTime and stamp > stalest:
      stalest = stamp
      culprit = path

  if culprit.len > 0:
    raise newException(AppBinaryUnusable, name & " is STALE -- it predates the sources it is built from, " &
      "so this test would exercise an old binary and report a result that " &
      "belongs to the build rather than to the code.\n" &
      "  binary: " & result & " (" & $binaryTime.utc & ")\n" &
      "  newer source: " & culprit & " (" & $stalest.utc & ")\n" &
      "  rebuild: scripts/run_tests.sh, or scripts/build_apps.sh\n" &
      "An `nim c -r` of a test file recompiles the test and the client " &
      "library but NOT the apps.")

proc cliPath*(): string = checkedBinary("runquota")

proc daemonPath*(): string =
  ## The daemon, refused unless the CLI is usable too: a test that starts a
  ## daemon and only later resolves the CLI to talk to it must be refused
  ## BEFORE the daemon exists. (`scripts/build_apps.sh` builds both.) A
  ## refusal after it exists -- sources touched mid-session -- still raises,
  ## so the caller's `finally` stops it.
  discard cliPath()
  checkedBinary("runquotad")
