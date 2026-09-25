## THE WINDOWS COMPILE GATE, RUN FROM A LINUX OR macOS RUNNER.
##
## Two Windows-only compile errors reached `dev` within two days of each
## other and were caught only by a DOWNSTREAM CONSUMER's Windows leg:
##
##   * `runquota_ipc.nim` released a just-accepted unix-socket handle with
##     `posix.close(...)`, and `std/posix` is imported only
##     `when defined(posix)` -- fixed by 16184d1 with `nativesockets.close`.
##   * `runquota_stats_table/publisher.nim` imported `std/posix` and two
##     `shm_lease/*` modules unconditionally, above the
##     `statsPublisherSupported` const its whole body is already gated on --
##     fixed by fee60f4.
##
## Neither fix shipped a test, and neither could have: `.github/workflows/ci.yml`
## had no Windows runner on any job. This file is the half of the answer that
## runs on the runners the repository ALREADY has. The other half is the
## `windows-compile-gate` job in that workflow, which does the real native
## `nim c` on `eph-win-x64`.
##
## WHY `--os:windows` FROM LINUX, AND NOT `--os:linux` FROM WINDOWS. The
## reverse direction is a meaningless control: cross-checking a POSIX target
## from a Windows host trips on `DirSep` artifacts in the vendored bearssl
## paths long before it reaches anything about this repository's own code. The
## direction that carries information is the one that asks the question the
## downstream consumer asked -- "does this tree type-check for Windows?" --
## from a host that is cheap and always present in CI.
##
## WHAT IT COVERS. Every entrypoint in `apps/entrypoints.txt` and every
## library in `libs/libraries.txt`: the same two manifests
## `scripts/check_nim_sources.sh` sweeps for the HOST os, swept again for
## Windows. The libraries are not redundant with the entrypoints:
## `runquota_c` is a `--app:staticlib` surface that no entrypoint and no other
## library imports, so it is reached by nothing else in either gate. (The
## other unbuilt-for-Windows library, `runquota_host_macos`, IS in the
## entrypoints' import closure -- `runquota_process` and `runquota_daemon`
## import it -- so it is type-checked either way; it is merely absent from the
## generated C.)
##
## HERMETICITY, AND WHAT CHANGED ABOUT IT. The check runs from a working
## directory three levels below the repository root, with `REPROBUILD_SRC`
## removed and `SHM_LEASE_SRC` set EXPLICITLY to the one `nim-shm-lease` this
## tree builds against -- resolved the way `config.nims` resolves it, from
## this repository's root rather than from wherever the compiler happens to
## run -- so the compiler reaches that dependency through the variable and
## through no accident of the workspace layout.
##
## It used to REMOVE `SHM_LEASE_SRC`, and the reason is worth keeping. When
## the gate was written nothing in this tree needed `shm_lease` for Windows:
## the published stats table was an inert stub there, so an unguarded
## `shm_lease` import in it (fee60f4) was a defect, and the way to see one was
## to make `shm_lease` unresolvable. The table now has a Windows arm, and it
## reuses `nim-shm-lease`'s anchor exactly as the POSIX arms do -- so for
## Windows `nim-shm-lease` is a DEPENDENCY, not an accident, and a gate that
## hid it would fail every correct tree. `.github/workflows/ci.yml` said in
## advance what to do then ("the fix is to provide it here, not to weaken the
## gate"), and this is that: the dependency is provided, by name, and what the
## gate asserts -- every entrypoint and every library type-checks for
## Windows -- is unchanged.
##
## WHAT IT DOES NOT COVER. `nim check` type-checks; it does not run the C
## compiler or the linker, and it uses the HOST's stdlib sources, so a
## Windows-only defect that lives in generated C, in a `{.link.}`/import
## clause, or in a stdlib module whose Windows branch differs from the file
## on this host will pass here. That is the `windows-compile-gate` CI job's
## job, and it is a separate required job for exactly that reason.

import std/[os, osproc, strtabs, streams, strutils, unittest]

# `readToEnd`, not `streams.readAll`: on Windows `readAll` stops at the
# first short pipe read and returns only what the child had written so far.
from runquota_core/child_process import readToEnd

const gateSourceDir = currentSourcePath().parentDir()

type
  CheckTarget = object
    ## One `nim check` invocation: a label for the report and the project
    ## file to type-check.
    label: string
    projectFile: string

  CheckOutcome = object
    label: string
    exitCode: int
    output: string

proc repoRoot(): string =
  ## `tests/unit/<this file>` -> the repository root. Derived from the source
  ## path rather than from `getCurrentDir()` so the gate cannot silently read
  ## a DIFFERENT tree's manifests when the binary is run from somewhere other
  ## than the root.
  result = gateSourceDir.parentDir().parentDir()
  doAssert fileExists(result / "apps" / "entrypoints.txt"),
    "repo root " & result & " has no apps/entrypoints.txt"
  doAssert fileExists(result / "libs" / "libraries.txt"),
    "repo root " & result & " has no libs/libraries.txt"

proc manifestRows(path: string): seq[seq[string]] =
  ## Whitespace-separated fields of every non-blank, non-comment line. A
  ## trailing CR is stripped, matching `scripts/build_apps.sh`.
  result = @[]
  for rawLine in lines(path):
    let stripped = rawLine.strip(chars = {' ', '\t', '\r', '\n'})
    if stripped.len == 0 or stripped.startsWith("#"):
      continue
    result.add stripped.splitWhitespace()

proc gateTargets(root: string): seq[CheckTarget] =
  ## The two manifests, in manifest order: entrypoints first, then libraries.
  result = @[]
  for fields in manifestRows(root / "apps" / "entrypoints.txt"):
    doAssert fields.len >= 2,
      "apps/entrypoints.txt row needs a name and a path: " & $fields
    result.add CheckTarget(label: fields[0], projectFile: root / fields[1])
  for fields in manifestRows(root / "libs" / "libraries.txt"):
    let lib = fields[0]
    result.add CheckTarget(
      label: lib,
      projectFile: root / "libs" / lib / "src" / (lib & ".nim"))

proc shmLeaseSource(root: string): string =
  ## The `nim-shm-lease` source this tree builds against, found the way
  ## `config.nims` finds it -- `SHM_LEASE_SRC`, then the workspace siblings --
  ## but anchored at the REPOSITORY ROOT and returned absolute, or "" when
  ## there is none. "" is a finding, not a skip: the Windows arm of the
  ## published stats table imports it.
  let fromEnv = getEnv("SHM_LEASE_SRC")
  if fromEnv.len > 0 and fileExists(fromEnv / "shm_lease" / "anchor.nim"):
    return absolutePath(fromEnv)
  for candidate in [root / ".." / "nim-shm-lease" / "src",
                    root / ".." / ".." / "nim-shm-lease" / "src"]:
    if fileExists(candidate / "shm_lease" / "anchor.nim"):
      return absolutePath(candidate).normalizedPath()
  ""

proc hermeticChildEnv(root: string): StringTableRef =
  ## The current environment with `REPROBUILD_SRC` removed and
  ## `SHM_LEASE_SRC` set to exactly the dependency `shmLeaseSource` found --
  ## so the compiler reaches `nim-shm-lease` by name, and never through a
  ## path that happens to resolve from its working directory.
  const mode =
    when defined(windows): modeCaseInsensitive else: modeCaseSensitive
  result = newStringTable(mode)
  for key, value in envPairs():
    if key == "SHM_LEASE_SRC" or key == "REPROBUILD_SRC":
      continue
    result[key] = value
  let shmLease = shmLeaseSource(root)
  if shmLease.len > 0:
    result["SHM_LEASE_SRC"] = shmLease

proc runChecks(root: string; targets: seq[CheckTarget]): seq[CheckOutcome] =
  ## Type-check every target for Windows, a bounded number at a time, and
  ## return one outcome per target in target order.
  ##
  ## Output is read to end BEFORE `waitForExit`: `readToEnd` returns at
  ## EOF, which the child's exit produces, so the pipe cannot fill and
  ## deadlock the way a `waitForExit`-then-read would. The children of one
  ## batch still run concurrently; only the reads are serialised.
  let nimExe = findExe("nim")
  doAssert nimExe.len > 0,
    "no `nim` on PATH; the gate cannot type-check anything"

  # Three levels below the root: neither `../nim-shm-lease/src` nor
  # `../../nim-shm-lease/src` can resolve from here.
  let workDir = root / "build" / "windows-compile-gate" / "cwd"
  createDir(workDir)
  let cacheRoot = root / "build" / "nimcache" / "windows-compile-gate"
  let childEnv = hermeticChildEnv(root)

  var workers = osproc.countProcessors()
  if workers < 2:
    workers = 2
  if workers > 8:
    workers = 8

  result = @[]
  var index = 0
  while index < targets.len:
    let batchEnd = min(index + workers, targets.len)
    var running: seq[Process] = @[]
    for i in index ..< batchEnd:
      let target = targets[i]
      running.add startProcess(
        nimExe,
        workingDir = workDir,
        args = @[
          "check",
          "--os:windows",
          "--threads:on",
          "--hints:off",
          "--warnings:off",
          "--colors:off",
          "--nimcache:" & (cacheRoot / target.label),
          target.projectFile,
        ],
        env = childEnv,
        options = {poStdErrToStdOut})
    for i in index ..< batchEnd:
      let process = running[i - index]
      let output = process.outputStream.readToEnd()
      let code = process.waitForExit()
      process.close()
      result.add CheckOutcome(
        label: targets[i].label, exitCode: code, output: output)
    index = batchEnd

proc failureReport(outcomes: seq[CheckOutcome]): string =
  ## Every failing target with its diagnostics, or "" when all passed.
  var failed: seq[string] = @[]
  for outcome in outcomes:
    if outcome.exitCode != 0:
      failed.add outcome.label & " (exit " & $outcome.exitCode & ")\n" &
        outcome.output.strip()
  if failed.len == 0:
    return ""
  result = $failed.len & " target(s) do not type-check for Windows:\n" &
    failed.join("\n\n")

suite "windows_compile_gate":

  let root = repoRoot()
  let targets = gateTargets(root)

  # ---------------------------------------------------------------------------
  # The gate covers something
  # ---------------------------------------------------------------------------
  #
  # A gate that swept an empty target list would pass forever while proving
  # nothing, which is the exact shape of the hole this file was written to
  # close. Assert the manifests were really read and that every project file
  # it is about to hand the compiler exists.

  test "the manifests yield every entrypoint and every library":
    check targets.len ==
      manifestRows(root / "apps" / "entrypoints.txt").len +
      manifestRows(root / "libs" / "libraries.txt").len
    # The count in the tree today: 2 entrypoints + 19 libraries. A floor
    # below it would let rows disappear from a manifest while this test
    # still passed, which is the failure mode the whole file is about.
    check targets.len >= 21
    for target in targets:
      check fileExists(target.projectFile)

  test "the child environment names nim-shm-lease explicitly, and nothing else":
    # THE DEPENDENCY IS PRESENT, BY NAME. Without it every target that
    # reaches the published stats table fails for a reason that is not a
    # Windows defect, and the report below would say so -- this says it first
    # and names the cause.
    let childEnv = hermeticChildEnv(root)
    check shmLeaseSource(root).len > 0
    check childEnv.hasKey("SHM_LEASE_SRC")
    if childEnv.hasKey("SHM_LEASE_SRC"):
      let source = childEnv["SHM_LEASE_SRC"]
      check source.isAbsolute
      check fileExists(source / "shm_lease" / "anchor.nim")
    check not childEnv.hasKey("REPROBUILD_SRC")
    # The removal only means something if PATH survived it: an empty
    # environment would fail every check for an unrelated reason and look
    # like a Windows defect.
    check childEnv.hasKey("PATH") or childEnv.hasKey("Path")

  # ---------------------------------------------------------------------------
  # The gate itself
  # ---------------------------------------------------------------------------

  test "every entrypoint and library type-checks for --os:windows":
    let outcomes = runChecks(root, targets)
    check outcomes.len == targets.len
    let report = failureReport(outcomes)
    checkpoint(report)
    check report.len == 0
