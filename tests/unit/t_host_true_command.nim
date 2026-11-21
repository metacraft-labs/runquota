## Tests find the trivial command they run; they do not assume `/bin/true`.
##
## WHAT IS GUARDED (reprobuild-pm
## `issues/2026-11-18-runquota-tests-exec-bin-true-which-nixos-does-not-have.md`).
##
## 1. THE RESOLUTION. `resolveTrueCommand` (`tests/support/host_true_command`)
##    finds `true` on the given `PATH` when neither conventional path
##    exists -- the NixOS layout -- prefers `PATH` over the conventional
##    paths, falls back to them when `PATH` has none, skips a file that is
##    not executable (POSIX only: Windows has no execute bit) and a relative
##    `PATH` element, and raises with a message naming what it looked for
##    when there is none at all. Falsifying mutation: return the first
##    conventional path without looking; the NixOS-layout case then gets a
##    path that does not exist.
## 2. WHAT IT RETURNS RUNS. `trueCommand()` on this host is absolute and
##    exits 0 when executed.
## 3. NO TEST FILE HOLDS THE LITERAL. No Nim file under `tests/` or
##    `libs/*/tests/` holds the string literal of either conventional path,
##    the support module excepted. Falsifying mutation: put the literal
##    back in any test; this case then names the file and line. It is a
##    check for that one literal, not for every way to spell the path (a
##    path inside a longer shell string is not seen).
##
## FIXTURE: scratch directories holding files this test writes. NO MOCKS:
## the real resolver, and for (2) the host's real command.

import std/[os, osproc, strutils, tempfiles, unittest]

import host_true_command

const
  repoRoot = currentSourcePath().parentDir.parentDir.parentDir
  supportModule = "tests" / "support" / "host_true_command.nim"

proc writeCommand(path: string; executable = true) =
  writeFile(path, "#!/bin/sh\nexit 0\n")
  setFilePermissions(path,
    if executable: {fpUserRead, fpUserWrite, fpUserExec}
    else: {fpUserRead, fpUserWrite})

suite "host_true_command":
  test "true is found on PATH where no conventional path exists":
    let root = createTempDir("rq-true-", "")
    defer: removeDir(root)
    createDir(root / "empty")
    createDir(root / "store")
    writeCommand(root / "store" / TrueFileName)
    let missing = [root / "usr-bin" / TrueFileName, root / "bin" / TrueFileName]
    check resolveTrueCommand(root / "empty" & $PathSep & root / "store",
                             missing) == root / "store" / TrueFileName

  test "PATH is preferred, and the conventional paths are the fallback":
    let root = createTempDir("rq-true-", "")
    defer: removeDir(root)
    createDir(root / "path")
    createDir(root / "conventional")
    writeCommand(root / "path" / TrueFileName)
    writeCommand(root / "conventional" / TrueFileName)
    let conventional = [root / "absent" / TrueFileName,
                        root / "conventional" / TrueFileName]
    check resolveTrueCommand(root / "path", conventional) ==
      root / "path" / TrueFileName
    check resolveTrueCommand(root / "absent", conventional) ==
      root / "conventional" / TrueFileName
    check resolveTrueCommand("", conventional) ==
      root / "conventional" / TrueFileName

  test "a file that is not executable is not the command":
    when defined(posix):
      let root = createTempDir("rq-true-", "")
      defer: removeDir(root)
      createDir(root / "first")
      createDir(root / "second")
      writeCommand(root / "first" / TrueFileName, executable = false)
      writeCommand(root / "second" / TrueFileName)
      check resolveTrueCommand(root / "first" & $PathSep & root / "second",
                               []) == root / "second" / TrueFileName
    else:
      # Windows has no execute bit to withhold: `setFilePermissions` only
      # toggles read-only, and the file runs by its extension.
      skip()

  test "a relative PATH element is not searched":
    # `.` or `bin` would be resolved from wherever the test runs.
    let root = createTempDir("rq-true-", "")
    defer: removeDir(root)
    createDir(root / "rel")
    createDir(root / "abs")
    writeCommand(root / "rel" / TrueFileName)
    writeCommand(root / TrueFileName)
    writeCommand(root / "abs" / TrueFileName)
    let previous = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(previous)
    check resolveTrueCommand("." & $PathSep & "rel" & $PathSep & root / "abs",
                             []) == root / "abs" / TrueFileName
    expect TrivialCommandMissing:
      discard resolveTrueCommand("." & $PathSep & "rel", [])

  test "a host with no true is named, not left to an exec failure":
    let root = createTempDir("rq-true-", "")
    defer: removeDir(root)
    createDir(root / "empty")
    let missing = [root / "bin" / TrueFileName]
    var message = ""
    try:
      discard resolveTrueCommand(root / "empty", missing)
    except TrivialCommandMissing as error:
      message = error.msg
    check ("no `" & TrueFileName & "` command on this host") in message
    check (root / "empty") in message
    check missing[0] in message

  test "the command resolved on this host is absolute and exits 0":
    let command = trueCommand()
    check command.isAbsolute
    let p = startProcess(command, options = {})
    defer: p.close()
    check p.waitForExit(10_000) == 0

  test "no test file holds the literal of a conventional path":
    # Built from parts, so this file does not hold what it looks for.
    let forbidden = ["\"/bin" & "/true\"", "\"/usr/bin" & "/true\""]
    var scanned: seq[string]
    var offenders: seq[string]
    proc scan(dir: string) =
      for path in walkDirRec(dir):
        if not path.endsWith(".nim"): continue
        if relativePath(path, repoRoot) == supportModule: continue
        scanned.add(relativePath(path, repoRoot))
        var number = 0
        for line in lines(path):
          inc number
          for literal in forbidden:
            if literal in line:
              offenders.add(relativePath(path, repoRoot) & ":" & $number)
    scan(repoRoot / "tests")
    for lib in walkDir(repoRoot / "libs"):
      if lib.kind == pcDir and dirExists(lib.path / "tests"):
        scan(lib.path / "tests")
    # The control: the scan read this file and the two tests that once
    # held the literal, and the excepted module does hold it.
    check scanned.len > 50
    check "tests" / "unit" / "t_host_true_command.nim" in scanned
    check "tests" / "unit" / "t_tree_sampler_cost_and_peak.nim" in scanned
    check "tests" / "integration" / "t_foreign_namespace_client.nim" in scanned
    check forbidden[0] in readFile(repoRoot / supportModule)
    checkpoint "use trueCommand() from tests/support/host_true_command: " &
      offenders.join(", ")
    check offenders.len == 0
