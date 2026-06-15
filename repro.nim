## Runquota repo project file.
##
## A Mode 1 / Mode 3 hybrid (per
## ``reprobuild-specs/Three-Mode-Convention-System.md``) modelled on
## reprobuild's own ``repro.nim``:
##
## * Declares the upstream tool dependencies via ``uses:`` so a
##   consumer that depends on ``runquota`` (notably reprobuild, whose
##   integration tests spawn ``runquotad`` as a subprocess) can pick up
##   the same toolchain floor that the existing ``flake.nix`` /
##   ``just build`` already provision today.
## * Declares ``library runquota`` so consumers can express a
##   workspace dependency on this repo with ``uses: "runquota"``. The
##   library is the umbrella view of every ``libs/<name>/src`` tree
##   (see ``config.nims`` for the active path list); there is no single
##   ``src/runquota.nim`` umbrella because the repo is a fan-out of
##   independent libs the apps wire together explicitly.
## * Declares the two shipping executables one-for-one with
##   ``apps/entrypoints.txt``: ``runquota`` (the CLI) and ``runquotad``
##   (the per-user lease authority daemon). The Nim-identifier names
##   match the binary names; ``name: "<bin>"`` inside each
##   ``executable`` body pins the on-disk artifact.
## * Wraps the existing ``scripts/build_apps.sh`` byte-for-byte in a
##   single ``build:`` action so today's build behaviour is preserved.
##   This is the option-(A) cut described in the repo packaging memo —
##   coarse-grained, opaque, but immediately consistent with what
##   ``just build`` / ``flake.nix`` already do. Option (B) — one
##   ``nim c`` per entrypoint via the DSL's per-entry ``buildAction``
##   primitive — is deferred to a follow-on milestone.
##
## The ``build:`` action inherits ``RUNQUOTA_BUILD_MODE`` /
## ``REPROBUILD_BUILD_MODE`` from the calling environment, the same
## way the ``flake.nix`` devShell and the existing ``just build``
## drop-in do.
##
## Bootstrap-And-Self-Build milestone B0: this file is consumed by
## reprobuild's ``repro.nim`` via ``uses: "runquotad"`` so future
## milestones can drive the cross-repo dependency through the engine's
## typed-tool resolver instead of the out-of-band ``build_sibling
## ../runquota`` shell step in ``scripts/run_tests.sh``.

import repro_project_dsl

# ``nim.c(...)`` in the ``build:`` block resolves through the ``nim`` const
# the ``package`` macro auto-imports because ``"nim >=2.2 <3.0"`` appears in
# ``uses:`` (same mechanism reprobuild's repro.nim relies on). No explicit
# ``import repro_dsl_stdlib/packages/sh`` is needed any more now that the
# build is expressed natively instead of through a ``shell(...)`` wrapper.

package runquota:
  # Declare ``path``-mode tool provisioning so the engine adopts it
  # automatically. Without this, ``repro build`` refuses to run with
  # "typed tool provisioning is required for uses declarations" unless
  # the caller passes ``--tool-provisioning=path`` explicitly. The
  # runquota dev shell (``nix develop``) and ``just build`` both
  # furnish every tool we need via PATH, so the weak-local PATH mode
  # is the right default for this repo (mirrors reprobuild's choice).
  defaultToolProvisioning "path"

  uses:
    # Toolchain floor — the PATH-resolvable binaries the runquota
    # build needs. ``nim`` + ``gcc`` build the executables (the two
    # ``nim.c(...)`` edges in the ``build:`` block below); ``just`` is
    # invoked by the nimble ``build``/``test`` tasks and ``sh`` by the
    # repo's helper scripts (``scripts/*.sh``) that the non-engine build
    # paths still use. These are sufficient for the path-mode tool
    # resolver to succeed under ``nix develop``.
    "nim >=2.2 <3.0"
    "gcc >=12"
    "just >=1"
    "sh"

    # Note: runquota has no system shared-library or source-only
    # dependencies of its own — the build is pure Nim against the
    # in-repo ``libs/<name>/src`` trees. If/when runquota grows a
    # system dep (sqlite, libsodium, etc.) it would be listed here
    # alongside the env-var-based provisioning shape that reprobuild
    # uses for libblake3 / xxhash / sqlite.

  # Library declaration — every ``.nim`` file under ``libs/<name>/src``
  # that ``config.nims`` adds to ``--path`` is importable when this
  # package is consumed via ``uses: "runquota"``. The umbrella is
  # implicit (no single ``src/runquota.nim``); consumers import the
  # individual lib modules they need (``import runquota_client``,
  # ``import runquota_protocol``, ...).
  library runquota

  # Two shipping executables, one entry per non-comment line in
  # ``apps/entrypoints.txt``. The Nim identifiers match the binary
  # names; ``name: "<bin>"`` is redundant but kept for symmetry with
  # reprobuild's repro.nim and to make the on-disk contract explicit.
  executable runquota:
    name: "runquota"

  executable runquotad:
    name: "runquotad"

  build:
    # Option (B) from the repo packaging memo: express the build natively
    # in the DSL with one ``nim.c(...)`` typed-tool edge per shipping
    # executable instead of wrapping the opaque ``scripts/build_apps.sh``
    # in a single ``shell(...)`` action. This gives the engine a real
    # per-binary dependency edge — each ``nim.c`` edge declares its source
    # entrypoint as a typed input and ``build/bin/<name>`` as its output —
    # so the engine's monitor discovers the transitive ``libs/<name>/src``
    # inputs per binary and can invalidate/rebuild each executable
    # independently. The previous coarse ``shell`` wrapper rebuilt both
    # binaries whenever any input under ``apps``/``libs`` changed; the
    # per-edge form keys each compile on just the inputs it actually reads.
    #
    # The two edges reproduce the per-entry loop in
    # ``scripts/build_apps.sh`` one-for-one (the script does nothing else —
    # no dylib/DLL side artifacts, unlike reprobuild's). ``--threads:on``
    # is Nim 2.2's default so it is not passed explicitly. Build-mode
    # selection (``-d:release`` via ``RUNQUOTA_BUILD_MODE`` /
    # ``REPROBUILD_BUILD_MODE``) stays an engine-level build configuration
    # concern rather than a baked-at-extraction define, matching the
    # option-(B) edges in reprobuild's own ``repro.nim``; ``just build`` /
    # ``flake.nix`` continue to honour the env vars through the unchanged
    # ``scripts/build_apps.sh`` for the non-engine build path.
    #
    # The edges aggregate into an ``apps`` build graph collection so
    # ``repro build .#apps`` materialises both binaries in one engine pass
    # (the fragment form ``.#apps`` is required because the CLI's
    # path-vs-name classifier treats bare ``apps`` as the on-disk
    # ``apps/`` directory).
    var runquotaAppsActions: seq[BuildActionDef] = @[]

    runquotaAppsActions.add(nim.c(
      source = "apps/runquota/runquota.nim",
      binary = "build/bin/runquota",
      actionId = "runquota.apps.runquota"))

    runquotaAppsActions.add(nim.c(
      source = "apps/runquotad/runquotad.nim",
      binary = "build/bin/runquotad",
      actionId = "runquota.apps.runquotad"))

    discard collect("apps", runquotaAppsActions)
