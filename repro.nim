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
import repro_dsl_stdlib/packages/sh

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
    # build needs. ``nim`` + ``gcc`` build the executables; ``just``
    # is invoked by the nimble ``build``/``test`` tasks; ``sh`` runs
    # ``scripts/build_apps.sh``. These are sufficient for the
    # path-mode tool resolver to succeed under ``nix develop``.
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
    # Option (A) from the repo packaging memo: wrap
    # ``scripts/build_apps.sh`` byte-for-byte so the action's
    # behaviour is identical to ``just build`` today. The action
    # declares the union of source roots the script reads (``apps``,
    # ``libs``, ``config.nims``, ``runquota.nimble``,
    # ``scripts/build_apps.sh``, ``apps/entrypoints.txt``) as extra
    # inputs and every ``build/bin/<name>`` artifact as an extra
    # output so a future engine pass can cache-key correctly without
    # re-deriving the inputs.
    #
    # Env vars (``RUNQUOTA_BUILD_MODE`` / ``REPROBUILD_BUILD_MODE``)
    # are inherited from the caller. Both the flake.nix devShell and
    # the existing ``just build`` honour the same vars.
    shell(
      command = "bash scripts/build_apps.sh",
      actionId = "runquota.build_apps",
      extraInputs = @[
        "apps/entrypoints.txt",
        "apps",
        "libs",
        "config.nims",
        "runquota.nimble",
        "scripts/build_apps.sh",
      ],
      extraOutputs = @[
        "build/bin/runquota",
        "build/bin/runquotad",
      ])
