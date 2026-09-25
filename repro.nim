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

import std/[os]

import repro_project_dsl
import repro_dsl_stdlib/foreign_env
# ``shell(...)``, used by the documentation-book block at the end of
# ``build:``. ``"sh"`` is already declared in ``uses:`` below, so the tool the
# action runs through is provisioned by the same resolver as ``nim`` and
# ``gcc``.
import repro_dsl_stdlib/packages/sh

# ``nim.c(...)`` in the ``build:`` block resolves through the ``nim`` const
# the ``package`` macro auto-imports because ``"nim >=2.2 <3.0"`` appears in
# ``uses:`` (same mechanism reprobuild's repro.nim relies on).

# The RunQuota documentation book's sibling-path resolver. A RELATIVE import,
# deliberately: this file is compiled by the reprobuild engine with the project
# DSL on its path and none of RunQuota's own ``libs/`` tree, so a module name
# that had to be found on a ``--path:`` would not resolve. The module imports
# nothing but ``std``.
import "./docs/book-isonim/sibling_paths"

const projectRootPath = currentSourcePath().parentDir()
  ## This repository's checkout root: the directory holding this file. Used to
  ## locate ``docs/book-isonim`` and, through it, the workspace root the book's
  ## sibling source trees live in.

package runquota:
  # Provision every tool below rather than find it on PATH, so that
  # ``repro shell`` / ``repro exec`` is a complete development environment on
  # its own -- the reprobuild equivalent of ``nix develop``, not a layer over
  # it. Linux and macOS take the tools from Nix, as the flake does; Windows
  # takes release archives into the tool store.
  #
  # Override per invocation without editing this file:
  #   REPRO_TOOL_PROVISIONING=path repro exec -- just test
  defaultToolProvisioning(when defined(windows): tarball else: nix)

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

    # ``scripts/run_tests.sh`` and ``scripts/build_apps.sh`` are bash scripts.
    # On Windows this is Git for Windows' bash, whose launcher also puts its
    # coreutils (find, sort, timeout, ...) on the script's PATH.
    "bash >=4"

    # ``git``, which the static-helper gate's tool-store authority
    # (``scripts/static_helper_gate_toolstore.sh``, the arm ``just test`` runs
    # outside ``nix develop`` on Windows) uses to prove its source snapshot is
    # the tracked tree. It is pinned there, by identity, alongside ``nim`` and
    # ``gcc`` (``scripts/static_helper_gate_toolstore.pins``); on Windows this
    # realises the same PortableGit archive ``bash`` and ``sh`` come from.
    "git >=2"

    # THE ``sqlite3`` COMMAND-LINE TOOL, a runtime dependency of the
    # observation store and of ``runquota_persistence``: both reach SQLite by
    # spawning it rather than linking a library, so that its absence is a
    # catchable condition ("degrade, never fail") and not a load-time abort.
    # Without it on PATH the store opens as ``degraded-no-sqlite-tool`` and
    # roughly half the test suite asserts against a store that refused to
    # exist; ``scripts/run_tests.sh`` refuses to start for that reason. The
    # flake's dev shell carries ``pkgs.sqlite`` for the same reason. The
    # package is defined in reprobuild-packages
    # (``packages/interfaces/sqlite3``).
    "sqlite3 >=3"

    # Not yet here from the flake's dev shell: the lint tools (``shellcheck``
    # has no Windows realization; ``shfmt``, ``typos``, ``repomix`` and
    # ``nixfmt`` are not reachable from ``uses:``), so ``just lint`` still
    # needs ``nix develop`` or a PATH that has them.

  # ``repro shell`` / ``repro exec -- <cmd>``: the tools in ``uses:`` above,
  # provisioned per ``defaultToolProvisioning``. ``nim-shm-lease`` is found
  # the way ``config.nims`` always finds it -- ``SHM_LEASE_SRC`` or the
  # workspace sibling -- so it needs nothing here.
  devEnv:
    when not defined(windows):
      useFlakeDevShell()

    activity "default"
    task "test",
      command = "just test",
      description = "Build the apps and run the full test suite"

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

    # -------------------------------------------------------------------
    # Documentation (docs/book-isonim) as build-graph edges.
    #
    # The book is an `isonim-docs` static-site-generator site, and its build
    # needs nine sibling source trees on the Nim path (the framework, the
    # shared docs theme, isonim and its vendored serialization stack). Those
    # live in SIBLING REPOSITORIES, so Nim reaches them through `--path:`
    # entries in a generated `docs/book-isonim/nim.cfg`.
    #
    # WHY GRAPH EDGES RATHER THAN A SHELL SCRIPT. The obvious alternative --
    # and what CodeTracer's book started as -- is a deploy script that writes
    # `nim.cfg` immediately before building and deletes it after. The path set
    # then exists only for the duration of that script, and nothing else (an
    # editor, a test run, a developer typing `just build`) can reproduce it.
    # Declaring the file here makes it a TRACKED INPUT instead of a side
    # effect: editing one `content/*.md` re-runs the SSG and only what needs a
    # rendered `public/`, and the path set is the same one every caller sees.
    #
    # THE LIST ITSELF IS NOT HERE. It is `docs/book-isonim/sibling-paths.txt`,
    # read by this block and by the book's `just nim-cfg` recipe, so the two
    # cannot drift. CodeTracer kept two hand-maintained copies and they did
    # drift: `codetracer-design-system/nim` was added to the deploy script and
    # not to the graph, so the deploy lane built the book while the graph's
    # `docs-book` action failed with `cannot open file: metacraft_docs_theme`.
    #
    # THE BOOK IS SKIPPED, NOT FAILED, WHEN ITS SIBLINGS ARE ABSENT. Most of
    # them are not part of the RunQuota project manifest, so a normal RunQuota
    # workspace has no checkout to build against and every other target in
    # this file must still resolve. A MISSING SIBLING ABORTS THE WHOLE BLOCK
    # rather than emitting a partial path set: half a set produces a confusing
    # `cannot open file` deep inside the SSG instead of an honest skip.
    block docsBookIsonim:
      const bookDir = "docs/book-isonim"
      let bookRoot = projectRootPath / bookDir
      if not fileExists(bookRoot / BookSiblingSpecFile):
        # No book in this checkout (a source-subset materialisation, say).
        break docsBookIsonim

      let siblings =
        try: readBookSiblingSpec(bookRoot)
        except CatchableError: @[]
      if siblings.len == 0:
        break docsBookIsonim

      let resolved = resolveBookSiblings(projectRootPath, siblings)
      if not resolved.ok:
        # `resolved.missingRepo` names what was not found. Nothing is emitted
        # and nothing is written; the rest of the graph is unaffected.
        break docsBookIsonim

      # The path set as a real file on disk rather than `--path:` flags on the
      # command line below: `src/build.nim` shells out to a nested `nim js`
      # for the book's client bundle, and that child inherits the path set
      # only through `nim.cfg`.
      let bookNimCfg = fs.writeText(
        output = bookDir & "/nim.cfg",
        text = bookNimCfgText(resolved),
        actionId = "docs-book-nim-cfg")
      discard collect("docs-book-nim-cfg", @[bookNimCfg])

      let bookSite = shell(
        command = "cd " & bookDir & " && nim c -r --hints:off " &
          "-o:build/build src/build.nim",
        actionId = "docs-book-build",
        extraInputs = @[bookDir & "/" & BookSiblingSpecFile,
                        bookDir & "/nim.cfg"],
        after = @[bookNimCfg])
      discard collect("docs-book", @[bookNimCfg, bookSite])
