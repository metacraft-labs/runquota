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
  for dslLib in [
    # Project DSL surface ``repro.nim`` imports directly.
    "repro_project_dsl",
    "repro_dsl_stdlib",
    # Transitive deps reached by the ``package`` macro expansion.
    "repro_core",
    "repro_platform",
    "repro_diagnostics",
    "repro_domain_types",
    "repro_hash",
    "repro_solver",
    "blake3",
    "xxh3",
    "gxhash",
    "cbor",
    "repro_infra",
    "repro_interface_artifacts",
    "repro_tool_profiles",
    "repro_build_engine",
    "repro_launch_plan",
    "repro_local_store",
    "repro_runquota",
    "repro_workspace_manifests",
  ]:
    let candidate = reprobuildSrc / "libs" / dslLib / "src"
    if dirExists(candidate):
      switch("path", candidate)

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
