## THE TRIVIAL COMMAND A TEST RUNS IS FOUND, NOT ASSUMED.
##
## Several tests need a command that does nothing and exits 0, to have
## something to launch or lease. Writing it as `/bin/true` holds on most
## distributions and not on NixOS, where `/bin` holds `sh` and `/usr/bin`
## holds `env` and nothing else: `true` is on `PATH` there, at a store path.
## The exec then fails with ENOENT and the test reports a failure that has
## nothing to do with what it checks -- or, worse, passes while measuring a
## launch that never ran its command (reprobuild-pm
## `issues/2026-11-18-runquota-tests-exec-bin-true-which-nixos-does-not-have.md`).
##
## `trueCommand` resolves `true` the way a client would, on `PATH`, then
## tries the two conventional places, and RAISES when none is found: a host
## without the command is a prerequisite the test must name, not an exec
## failure for the reader to decode. The result is an absolute path, so it
## can be handed to a child whose `PATH` differs from this process's. It is
## NOT resolved through symlinks: Nix provides `true` as a link to the
## multicall `coreutils`, which decides what to be from `argv[0]`.
##
## `/bin/sh` is not covered here: POSIX hosts, NixOS included, have it.
##
## `tests/unit/t_host_true_command.nim` checks the resolution, and that no
## test file holds the string literal of a conventional path again.
##
## This file's name does not begin with `t`: the runners take every
## `t*.nim` under `tests/` for a test.

import std/[os, strutils]

const
  TrueFileName* = "true".addFileExt(ExeExt)
    ## `true` on POSIX, `true.exe` on Windows (Git for Windows ships one
    ## beside its `sleep` and `timeout`), so a `PATH` lookup finds it there.
  ConventionalTruePaths* = ["/usr/bin/true", "/bin/true"]
    ## Tried after `PATH`, for a caller whose `PATH` is empty or stripped.

type
  TrivialCommandMissing* = object of CatchableError
    ## A `CatchableError`, so `unittest` reports the test FAILED with the
    ## message instead of the process dying.

proc isRunnableFile(path: string): bool =
  ## A regular file (or a link to one) that the OS would run. On POSIX that
  ## means an execute bit. Not `access`: which bit applies to this user is
  ## the exec's business, and a `true` this user may not run is no host this
  ## suite meets. Windows has no execute bit -- Nim's `getFilePermissions`
  ## reports all three for every file -- and runs a file by its extension,
  ## which `TrueFileName` already carries.
  if not fileExists(path): return false
  when defined(posix):
    getFilePermissions(path) * {fpUserExec, fpGroupExec, fpOthersExec} != {}
  else:
    true

proc resolveTrueCommand*(searchPath: string;
                         conventional: openArray[string]): string =
  ## `true` from `searchPath` (a `PATH` value), then from `conventional`.
  ## Absolute. Raises `TrivialCommandMissing` when there is none.
  for directory in searchPath.split(PathSep):
    # An empty or relative element (`.`, `bin`) is looked up from the
    # current directory by `execvp`; a test must not pick up a `true` from
    # wherever it happens to be run, so only absolute elements count.
    if not directory.isAbsolute: continue
    # Not `expandSymlink`d: Nix links `true` to the multicall `coreutils`,
    # which decides what to be from the name it was run by.
    let candidate = directory / TrueFileName
    if isRunnableFile(candidate):
      return candidate
  for candidate in conventional:
    if isRunnableFile(candidate):
      return candidate
  raise newException(TrivialCommandMissing,
    "no `" & TrueFileName & "` command on this host: not on PATH (" &
    searchPath & ") and not at " & conventional.join(" or ") &
    "; the test needs a command that exits 0")

proc trueCommand*(): string =
  ## The host's `true`, by absolute path.
  resolveTrueCommand(getEnv("PATH"), ConventionalTruePaths)
