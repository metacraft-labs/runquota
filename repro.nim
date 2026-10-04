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

import std/[algorithm, os, sets, strutils]
import ct_test_nim_unittest
import repro_resources/run_edge
import ./repro_support/timeout
when defined(posix):
  import ./repro_support/process_tools

import repro_project_dsl
import repro_dsl_stdlib/foreign_env
import repro_dsl_stdlib/fs as dslfs
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
    when defined(macosx):
      "clang"
    else:
      "gcc >=12"
    "just >=1"
    "sh"

    # ``scripts/run_tests.sh`` and ``scripts/build_apps.sh`` are bash scripts.
    # On Windows this is Git for Windows' bash, whose launcher also puts its
    # coreutils (find, sort, timeout, ...) on the script's PATH.
    "bash >=4"
    "timeout"
    "sleep"
    "mkdir"
    when not defined(windows):
      "chmod"
      "cp"
      "mv"
      "rm"
      "echo"
      "dirname"
      "uname"
      "ps"
      "find"
      "nix"

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

    # The published stats table imports shm_lease/anchor. Carry the producer's
    # source identity and import root into each typed Nim compile.
    "nim-shm-lease"

    # The lint and formatting tools the flake's dev shell carries, defined in
    # reprobuild-packages (``packages/interfaces/<name>``). Windows takes
    # upstream's release archives for all four below.
    "shellcheck"
    "shfmt"
    "typos"
    # ``prek`` runs ``prek.toml`` -- the same ``just lint`` hook the flake's
    # git-hooks.nix installs through pre-commit on Linux and macOS -- so the
    # pre-commit hook also works from a Windows ``repro shell`` (install it
    # once with ``repro exec -- prek install``). pre-commit itself stays the
    # flake shell's: it is a Python application with no release binary.
    "prek"
    # ``repomix`` everywhere: on Windows, where nobody publishes a binary, it
    # is upstream's npm package with its pinned dependency closure
    # (reprobuild-packages ``packages/interfaces/repomix``), run under the
    # ``node`` this list declares; repomix needs node 22 or newer.
    "repomix"
    "node >=22"
    # ``nixfmt`` has no Windows realization yet: nobody publishes a Windows
    # binary, and building it from source needs reprobuild to fall through
    # from tarball provisioning to a source recipe, which has not landed.
    # ``just format`` says so on Windows rather than skipping silently.
    when not defined(windows):
      "nixfmt"

  # ``repro shell`` / ``repro exec -- <cmd>``: the tools in ``uses:`` above,
  # provisioned per ``defaultToolProvisioning``. The source-library producer
  # above supplies nim-shm-lease to engine builds; config.nims retains its
  # explicit environment/sibling lookup for direct Nim and Just invocations.
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

    # Match scripts/run_tests.sh: sorted, complete discovery with unique output
    # names. Compile each program separately; both shipping apps precede every
    # execution edge because integration tests start real daemons and clients.
    const backendCompiler = (when defined(macosx): "clang" else: "gcc")
    const exeSuffix = (when defined(windows): ".exe" else: "")
    var testSources: seq[string] = @[]
    var libraryPaths: seq[string] = @[]
    for kind, path in walkDir("libs"):
      if kind == pcDir and dirExists(path / "src"):
        libraryPaths.add(path / "src")
    libraryPaths.sort()
    for root in ["tests", "libs"]:
      for source in walkDirRec(root):
        let normalized = source.replace('\\', '/')
        if normalized.endsWith(".nim") and normalized.extractFilename.startsWith("t") and
            (root == "tests" or "/tests/t" in normalized):
          testSources.add(normalized)
    testSources.sort()
    const measurementTests = [
      "t_e2e_runquota_client_exit_releases_lease",
      "t_observation_retention_scheduled",
      "t_observation_store_retention_crash",
      "t_ambient_sample_atomicity",
      "t_ambient_writer_contention",
      "t_host_load_reading_invariants",
      "t_completion_report_does_not_wait_on_the_store",
      "t_ambient_load_attribution",
      "t_runquota_host_macos_native_process_telemetry"]
    # These programs saturate the CPU or measure startup, retention, live
    # timing and process memory. Lifecycle helpers have bounded startup waits.
    # Run them after compilation and the rest of the suite, one at a time,
    # so our own load generators do not invalidate another test's control.
    for name in measurementTests:
      for i, source in testSources:
        if source.extractFilename.changeFileExt("") == name:
          testSources.delete(i)
          testSources.add(source)
          break
    doAssert testSources.len > 0, "No RunQuota tests found"
    var names = initHashSet[string]()
    var testBuilds, testRuns: seq[BuildActionDef] = @[]
    var testPrograms: seq[tuple[name, output: string, compiled: BuildActionDef]] = @[]
    for source in testSources:
      let name = source.extractFilename.changeFileExt("")
      doAssert name notin names, "Duplicate test binary name: " & name
      names.incl(name)
      let output = "build/test-bin/" & name & exeSuffix
      let compiled = buildNimUnittest.build(
        source = source, binary = output, paths = libraryPaths,
        extraInputs = @["config.nims", "tests/support"],
        actionId = "runquota.test_build." & name)
      appendRegisteredActionToolIdentityRefs(compiled.action.id, [backendCompiler])
      testBuilds.add(compiled.action)
      testPrograms.add((name, output, compiled.action))
    for program in testPrograms:
      let (name, output, compiled) = program
      let isolatesEnvironment = name == "t_isolated_environment"
      var executeAfter = runquotaAppsActions & @[compiled] &
        (if name in measurementTests: testBuilds & testRuns else: @[])
      var executePolicy = automaticMonitorPolicy(captureBreadth = mcbFullCapture)
      if isolatesEnvironment:
        # This fixture asserts the child's exact environment. An outer shim
        # injects its own loader/session variables and changes that premise.
        # Preserve every assertion and monitored compilation. The depfile
        # supplies ordering, not complete runtime reads, so never cache this
        # execution. See issues/2026-09-30-isolated-environment-fixture-
        # inherits-monitor-injection.md and Monitor-Hook-Shim / Failure Semantics.
        let depfile = "build/test-deps/" & name & ".d"
        executeAfter.add(dslfs.unmonitorableActionDepfile(
          output = depfile, inputs = @[output],
          reason = "Exact child-environment fixture owns its environment; " &
            "outer monitor injection adds variables. Execution always reruns.",
          actionId = "runquota.test_dependencies." & name))
        executePolicy = makeDepfilePolicy(depfile, suppressMonitorShimSeed = true)
      # Preserve the native harness's bound, kill grace and closed stdin.
      # GNU timeout places the child tree in its own process group.
      let executed = shell(
        command = "timeout --kill-after=10 600 " & quoteShell(output) & " </dev/null",
        after = executeAfter,
        extraInputs = @[output, "build/bin/runquota" & exeSuffix,
                         "build/bin/runquotad" & exeSuffix],
        cacheable = not isolatesEnvironment,
        dependencyPolicy = executePolicy,
        actionId = "runquota.test_execute." & name)
      appendRegisteredActionToolIdentityRefs(executed.id,
        ["timeout", "sleep", "nim", backendCompiler, "sqlite3", "sh", "bash", "git", "mkdir"])
      when not defined(windows):
        appendRegisteredActionToolIdentityRefs(executed.id, ["dirname", "uname", "ps", "find", "nix"])
      when not defined(windows):
        if name == "t_shared_endpoint_second_uid":
          appendRegisteredActionToolIdentityRefs(executed.id, ["chmod", "cp", "mv", "rm", "echo"])
      run("test-" & name, build = executed.id, owningPackage = "runquota")
      testRuns.add(executed)
    discard collect("test-builds", testBuilds)
    discard collect("test", testRuns)

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
