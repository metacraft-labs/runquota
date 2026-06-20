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
switch("path", "libs/runquota_daemon/src")
switch("path", "libs/runquota_cli_support/src")
switch("path", "libs/runquota_partition/src")
