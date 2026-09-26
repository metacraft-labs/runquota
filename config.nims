import std/[os]

switch("styleCheck", "hint")

# Bootstrap-And-Self-Build B0: ``repro.nim`` at the repo root imports
# ``repro_project_dsl`` + ``repro_dsl_stdlib/packages/sh`` from the
# reprobuild repo, and the project-DSL ``package`` macro transitively
# reaches into several other reprobuild libs (notably ``repro_solver``
# for variant encoding, ``repro_core`` for the typed-tool primitives,
# plus the umbrella stdlib configurables).
#
# Scope: this block is only there so an interactive developer running
# ``nim check repro.nim`` from a workspace checkout gets a clean
# response. The reprobuild integration test that exercises the same
# file passes its own explicit ``--path:`` flags, so it does not depend
# on this block.
#
# Gating: opt-in via REPROBUILD_SRC. We deliberately do *not* fall back
# to a sibling ``../reprobuild/`` here, because that would silently put
# every reprobuild lib on the ``--path:`` of *normal* ``nim c`` compiles
# in runquota too — i.e. a runquota lib could start importing
# ``repro_core`` without surfacing a build break in standalone CI. By
# requiring REPROBUILD_SRC to be set explicitly, we keep the
# regular runquota build hermetic to its own ``libs/`` tree.
#
# When REPROBUILD_SRC is unset, ``nim check repro.nim`` will surface a
# clear "undeclared identifier: package" diagnostic rather than
# silently passing — this is intentional.
let reprobuildSrc = getEnv("REPROBUILD_SRC")
if reprobuildSrc.len > 0:
  # The project-DSL ``package`` macro expansion reaches transitively
  # into a large, *growing* set of reprobuild libs (currently the DSL
  # surface, the build engine, the binary-cache cache-key + server
  # types, the peer-cache auth layer, …). Rather than hand-maintain an
  # allow-list that silently drifts every time the DSL grows a new
  # dependency, put every ``libs/<name>/src`` directory in the
  # reprobuild checkout on the ``--path:``. This block is gated on
  # REPROBUILD_SRC and therefore only affects ``nim check repro.nim``
  # from a workspace checkout — the regular runquota build (with
  # REPROBUILD_SRC unset) stays hermetic to its own ``libs/`` tree.
  for libDir in listDirs(reprobuildSrc / "libs"):
    let candidate = libDir / "src"
    if dirExists(candidate):
      switch("path", candidate)

  # Third-party Nim packages the DSL closure reaches into (nimcrypto
  # for cache-key composition, bearssl via the peer-cache auth layer,
  # the status-im serialization stack, …). reprobuild's own
  # ``config.nims`` resolves each from an explicit ``*_SRC`` env var
  # (exported by the dev shell) with sibling-checkout fallbacks; mirror
  # that here against the reprobuild checkout root so the same packages
  # resolve when ``nim check`` runs inside the dev shell.
  proc addReprobuildPkgPath(envName: string; candidates: openArray[string];
                            marker: string) =
    let fromEnv = getEnv(envName)
    if fromEnv.len > 0 and fileExists(fromEnv / marker):
      switch("path", fromEnv)
      return
    for candidate in candidates:
      if fileExists(candidate / marker):
        switch("path", candidate)
        return

  addReprobuildPkgPath("NIMCRYPTO_SRC", [
    reprobuildSrc / ".." / "codetracer" / "libs" / "nimcrypto",
    reprobuildSrc / ".." / "nimcrypto",
  ], "nimcrypto" / "hash.nim")
  addReprobuildPkgPath("BEARSSL_SRC", [
    reprobuildSrc / ".." / "nim-bearssl",
    reprobuildSrc / "libs" / "nim-bearssl",
  ], "bearssl.nim")
  addReprobuildPkgPath("FASTSTREAMS_SRC", [
    reprobuildSrc / "libs" / "nim-faststreams" / "src",
    reprobuildSrc / ".." / "codetracer" / "libs" / "nim-faststreams",
    reprobuildSrc / ".." / "nim-faststreams",
  ], "faststreams" / "inputs.nim")
  addReprobuildPkgPath("NIM_STEW_SRC", [
    reprobuildSrc / "libs" / "nim-stew" / "src",
    reprobuildSrc / ".." / "codetracer" / "libs" / "nim-stew",
    reprobuildSrc / ".." / "nim-stew",
  ], "stew" / "objects.nim")
  addReprobuildPkgPath("RESULTS_SRC", [
    reprobuildSrc / "libs" / "results" / "src",
  ], "results.nim")
  addReprobuildPkgPath("STINT_SRC", [
    reprobuildSrc / "libs" / "stint" / "src",
  ], "stint.nim")

# `nim-shm-lease` — THE FIRST DEPENDENCY RUNQUOTA HAS ON THE SHARED-MEMORY
# LIBRARY, introduced by M13b's published aggregate table.
#
# Unlike the REPROBUILD_SRC block above, this one is NOT opt-in, and the
# difference is deliberate. The reprobuild block is a convenience for
# `nim check repro.nim`, and a silent sibling fallback there would let a
# runquota lib start importing `repro_core` without a standalone-CI build
# break. Here the dependency is real and load-bearing: `runquota_stats_table`
# does not compile without it and `runquotad` does not publish without it, so
# a build that silently dropped it would produce a daemon missing a feature
# rather than a clear failure. It is therefore resolved on EVERY compile,
# from `SHM_LEASE_SRC` (exported by the dev shell and by the Nix package
# build, both from the flake input) with a workspace-sibling fallback for an
# interactive `nim c` in a `repo` checkout.
#
# Nothing is added to the path when neither resolves: the compile then fails
# on the import with the module name in it, which is the diagnosis.
block shmLeasePath:
  let fromEnv = getEnv("SHM_LEASE_SRC")
  if fromEnv.len > 0 and fileExists(fromEnv / "shm_lease" / "anchor.nim"):
    switch("path", fromEnv)
    break shmLeasePath
  for candidate in ["../nim-shm-lease/src", "../../nim-shm-lease/src"]:
    if fileExists(candidate / "shm_lease" / "anchor.nim"):
      switch("path", candidate)
      break shmLeasePath

switch("path", "libs/runquota_core/src")
switch("path", "libs/runquota_codec/src")
switch("path", "libs/runquota_protocol/src")
switch("path", "libs/runquota_ipc/src")
switch("path", "libs/runquota_client/src")
switch("path", "libs/runquota_c/src")
switch("path", "libs/runquota_process/src")
switch("path", "libs/runquota_exec/src")
switch("path", "libs/runquota_admission/src")
switch("path", "libs/runquota_host/src")
switch("path", "libs/runquota_host_linux/src")
switch("path", "libs/runquota_host_macos/src")
switch("path", "libs/runquota_host_windows/src")
switch("path", "libs/runquota_persistence/src")
switch("path", "libs/runquota_observation_store/src")
switch("path", "libs/runquota_daemon/src")
switch("path", "libs/runquota_cli_support/src")
switch("path", "libs/runquota_partition/src")
switch("path", "libs/runquota_stats_table/src")

# Shared test support. `tests/support/daemon_binary` resolves `build/bin`
# paths and refuses a binary older than the sources it is built from --
# every integration and e2e file that starts `runquotad` or shells out to
# `runquota` takes those binaries as INPUTS, so a stale one turns a green
# run into a wrong answer rather than a missing one.
switch("path", "tests/support")

## Worktree-local nimcache: every Nim compile inside this checkout keeps its
## intermediate files (its nimcache) INSIDE this checkout.
##
## WHY.  Nim's default nimcache is `$XDG_CACHE_HOME/nim/<project>_d` (`_r` for
## -d:release; `%USERPROFILE%\nimcache\<project>_d` on Windows).  It is keyed by
## the project NAME only, and the generated file names inside it do not depend
## on the checkout path either.  So two worktrees or clones of this repository
## that build the same project at the same time write, compile and link each
## other's intermediate files.  Measured on 2026-09-26 in a sibling repository:
## ten concurrent builds of two worktrees that differed in a few places gave
## four correct binaries, two that exited 0 with the OTHER worktree's code
## linked in (one of them a mix of both), two compile failures on
## half-rewritten generated C and two link failures.
##
## WHAT.  `<checkout>/.nimcache/<directory of the main module, relative to the
## checkout>/<module name><suffix>`, where the suffix is Nim's own: `_check`
## for `nim check`, `_r` for -d:release or -d:danger, `_d` otherwise.  The
## directory is part of the key, so same-named modules in different directories
## no longer share a cache either.  Only the intermediates move; build outputs
## stay where they were.  An explicit `--nimcache:` on the command line still
## wins, because Nim applies the command line again after the config files.
## `nim js` and project-less invocations are left alone.
##
## HOW IT IS PICKED UP.  Nim runs the `config.nims` of every PARENT directory of
## the compiled module, outermost first, then the one in the module's own
## directory.  So this file applies to every compile under this checkout,
## `just`, `nimble`, CI and a bare `nim c` alike, whatever the working directory.
## `--skipParentCfg` switches it off for modules below the checkout root, so a
## recipe that passes that flag must name its own checkout-local `--nimcache:`.
## The scripts that pass `--skipParentCfg` (the static-helper gate and the
## ref-token-scanner bootstrap) already name their own `--nimcache:`, and so do
## `scripts/run_tests.sh` and `scripts/build_apps.sh` (`build/nimcache/<name>`).
## `tests/t_nimcache_is_worktree_local.nim` checks the layout, and fails if the
## config is bypassed; its `--skipParentCfg` negative control proves the probe
## can see a shared cache at all.
##
## WINDOWS.  Nim turns the `/` below into `\` on a Windows host.  The layout adds
## `\.nimcache\<module dir>\<module>_d\` in front of Nim's own object file names,
## so keep the checkout root short (about 80 characters) to stay inside MAX_PATH.
block worktreeLocalNimcache:
  var project = projectName()
  if project.len > 4 and project[^4 .. ^1] == ".nim":
    project = project[0 ..< ^4]
  # No project (`nim dump` with no file): nothing to place.  The JS backend
  # has its own convention (a cache next to its output).  `nim e` never
  # generates C, so it never creates the directory.
  if project.len == 0 or getCommand() == "js":
    break worktreeLocalNimcache

  # Plain "/" joins, NOT std/os `/`: NimScript's `/` follows the TARGET OS,
  # so a `--os:windows` cross-compile on a POSIX host would get backslashes.
  let root = thisDir()
  let projDir = projectDir()
  var rel = ""
  if projDir.len >= root.len and projDir[0 ..< root.len] == root:
    rel = projDir[root.len .. ^1]
  else:
    # Cannot happen for a project Nim found this file for (this file is read
    # because it sits in a parent of the project directory).  Stay inside
    # the checkout and stay unique anyway.
    rel = "_outside/"
    for c in projDir:
      rel.add(if c in {'/', '\\', ':'}: '_' else: c)
  while rel.len > 0 and rel[0] in {'/', '\\'}:
    rel = rel[1 .. ^1]

  let suffix =
    if getCommand() == "check": "_check"
    elif defined(release) or defined(danger): "_r"
    else: "_d"
  var cacheDir = root & "/.nimcache"
  if rel.len > 0:
    cacheDir.add("/" & rel)
  switch("nimcache", cacheDir & "/" & project & suffix)
