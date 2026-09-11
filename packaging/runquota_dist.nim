## RunQuota's `Distribution` — the one definition every package format
## is produced from.
##
## Reprobuild's `Distribution-And-Packaging.md` §6: "one source of truth
## for package metadata, components, service wiring, and the runtime
## contract; per-format producers only translate." This module is that
## source of truth for RunQuota, and it lives in RUNQUOTA's repository
## rather than in reprobuild's standard library, which is the shape §6
## intends — "the layer is general and extensible (any project can
## package with it)". Reprobuild packaging reprobuild is one consumer of
## the producers, not a privileged path, and this file is the evidence:
## it imports nothing from reprobuild except the packaging layer's
## public surface.
##
## What is here and what is in `repro.nim` follows the same split
## reprobuild's own recipe uses. Everything below is a fact about
## RunQuota's RUNTIME CONTRACT and is the same on every host and in
## every format — the service topology, the state directory, the
## dependency posture, the metadata. Which binaries exist, and which
## edges produced them, is a fact about a particular build and belongs
## in the recipe.

import repro_dsl_stdlib/packaging

const
  RunQuotaPackageName* = "runquota"

  RunQuotaPackageVersion* = "0.1.0"
    ## The version every package format carries.
    ##
    ## A THIRD copy of a string that already exists twice, and the
    ## duplication is forced rather than chosen: `runquota.nimble`'s
    ## `version` is read by nimble, `runquota_core`'s `RunQuotaVersion`
    ## is what `--version` prints, and this one is read by `repro build`
    ## under a Nim invocation that has neither of the others on its
    ## path. `scripts/bump_version.sh` rewrites all three in one act and
    ## `tests/unit/t_version_sources_agree` refuses a drift between
    ## them, which is what keeps three copies from being three answers.

  RunQuotaUpgradeCode* = "{15A44E77-C288-4B55-8FA6-6A90AA289295}"
    ## Generated once and pasted, per the MSI producer's refusal to
    ## invent one: it is what makes two releases of this product an
    ## upgrade rather than two side-by-side installs. It must never
    ## change for as long as the package is called `runquota`.

  RunQuotaDaemonServiceName* = "runquotad"
    ## The systemd unit name, the launchd label and the SCM service
    ## name, which are deliberately the same string.
    ##
    ## The binary writes it too — `apps/runquotad/runquotad.nim`'s
    ## `windowsServiceName`, which is what it hands
    ## `StartServiceCtrlDispatcherW`. `tests/unit/t_packaging_contract`
    ## reads that file and refuses a drift, because the two are only
    ## ever compared by a machine at `sc start` time and a mismatch
    ## there is a service that registers and cannot run.

  PosixStateDir* = "/var/lib/runquota"
    ## Where `runquotad` keeps this machine's `host_id` and its
    ## observation store on Linux. The FHS answer for machine-local
    ## variable state a system service owns.

  DarwinStateDir* = "/var/db/runquota"
    ## The same fact on macOS, where `/var/lib` is not a thing.

  WindowsStateDir* = r"C:\ProgramData\runquota"
    ## The same fact on Windows.
    ##
    ## Reprobuild's M1 learned this one the hard way (its N22): the MSI
    ## registered its cache service with the POSIX spelling, so `sc qc`
    ## answered `--root=/var/lib/repro-binary-cache` on a system with no
    ## such path. `ServiceDef.execArgs` is passed through VERBATIM by
    ## every renderer, so one list has to be right for three service
    ## mechanisms at once.
    ##
    ## RunQuota answers that differently and more strongly: see
    ## `runQuotaDaemonService`, whose `execArgs` is EMPTY. These three
    ## constants exist to be compared against the daemon's own
    ## compiled-in `hostWideStateDir`, not to be passed to it.

func runQuotaStateDir*(targetOs: TargetOs): string =
  ## The daemon's state root FOR THE TARGET. A per-target value rather
  ## than a constant, because that is the shape of the defect reprobuild
  ## met: one literal cannot be correct for a filesystem with a root
  ## directory and one with drive letters.
  case targetOs
  of toWindows: WindowsStateDir
  of toDarwin: DarwinStateDir
  of toLinux: PosixStateDir

proc runQuotaDaemonService*(targetOs: TargetOs): ServiceDef =
  ## `runquotad`, the host-wide lease authority.
  ##
  ## ## `ssSystem` on every platform, and it is not a preference
  ##
  ## RunQuota's own `AGENTS.md` states the boundary: "`apps/runquotad/`
  ## is the host-wide lease authority daemon: ONE PER HOST, serving
  ## every user. Bounding load on a machine requires a single authority
  ## over that machine's resources, and per-user daemons would each
  ## admit against their own view of a budget they in fact share."
  ## A `ssUser` service is therefore not a lighter-weight variant of
  ## this one, it is a different product with the opposite correctness
  ## property — and the failure is silent, because every user sees a
  ## working system while the machine is oversubscribed N times over.
  ##
  ## This is the one place RunQuota's topology diverges from
  ## reprobuild's, and the divergence runs the way the products do.
  ## Reprobuild's build daemon is `ssUser` because it owns per-user
  ## build sessions and a store under `~/.cache/repro`; its cache SERVER
  ## is `ssSystem`. RunQuota has one daemon and it is the second kind.
  ##
  ## The practical consequence on Windows is that the service crosses
  ## into the MSI intact. `msiServiceRows` drops `ssUser` services
  ## because the SCM has no per-user services; a `ssUser` RunQuota would
  ## have produced a Windows package with no service at all.
  ##
  ## ## NOT started at boot, and that is a decision rather than caution
  ##
  ## `defaultDaemonConfig` guesses this host's capacity —
  ## `countProcessors() * 1000` milli-CPU and a flat 16 GiB — because it
  ## has to answer something. Those are placeholders for the numbers an
  ## operator measures, and a daemon started at boot with them would
  ## begin governing a machine's build capacity against a budget nobody
  ## chose, on the first reboot after installation. Installing the
  ## software and handing it authority over a machine are two decisions,
  ## and the package makes only the first. The runbook's post-install
  ## step is where the second one is made.
  ##
  ## ## `execArgs` IS EMPTY, deliberately
  ##
  ## Reprobuild's cache service names its state root in `execArgs`, and
  ## its M1 N22 is what happens when that string is right for POSIX and
  ## wrong for Windows. RunQuota does not need the argument at all: the
  ## daemon's compiled-in default IS already per-target
  ## (`runquota_observation_store/identity.nim`'s `hostWideStateDir`,
  ## whose three arms are the three constants above), so a hand-run and
  ## the service agree on where the state lives BY CONSTRUCTION rather
  ## than by two strings being kept equal. An empty argument list cannot
  ## carry a POSIX path onto a Windows host.
  ##
  ## Capacity flags are absent for the same reason they keep the service
  ## out of boot: they are the operator's numbers, and a package that
  ## baked its guesses into `BINARY_PATH_NAME` would make changing them
  ## a reinstall.
  ##
  ## ## `after` is empty
  ##
  ## The rendezvous is a Unix socket under `/run/runquota` or a named
  ## pipe in the NPFS namespace. Neither needs the network, so
  ## `network.target` would be an ordering nothing requires — and
  ## `MsiServiceRow` drops `after` anyway, so a value here would be a
  ## fact that is true in two formats out of three.
  ServiceDef(
    name: RunQuotaDaemonServiceName,
    displayName: "RunQuota lease authority",
    description: "RunQuota host-wide resource lease authority daemon",
    scope: ssSystem,
    # The component's INSTALL NAME, which carries the platform's
    # executable suffix. `validate` matches a service against the
    # distribution's executables by that name and refuses a mismatch.
    execComponent: RunQuotaDaemonServiceName &
      (if targetOs == toWindows: ".exe" else: ""),
    execArgs: @[],
    environment: @[],
    startAtBoot: false,
    restartOnFailure: true,
    after: @[])

proc newRunQuotaDistribution*(version: string; targetOs: TargetOs;
                              prefix = "/usr";
                              release = "1";
                              architecture = "x86_64";
                              stagingRoot = "";
                              outputDir = ""): Distribution =
  ## RunQuota's `Distribution`, with the §5 contract filled in and no
  ## components yet — the recipe adds those, because only the recipe has
  ## the build edges that produce them.
  ##
  ## ## ONE package, not two
  ##
  ## Reprobuild ships `reprobuild` and `reprobuild-binary-cache`
  ## separately, and the reason it gives is specific: the cache server
  ## "opens a port and a developer laptop should be able to install the
  ## CLI without acquiring one". RunQuota has no such asymmetry. Its
  ## daemon opens a local rendezvous endpoint and nothing else, the CLI
  ## is an empty gesture without a daemon to talk to, and the two speak
  ## a wire protocol versioned in lockstep inside one repository.
  ## Splitting them would create a supported combination — CLI vN with
  ## daemon vM — that nothing in the suite ever exercises.
  ##
  ## ## The §5 runtime contract, and why RunQuota's arm of it is empty
  ##
  ## §5 exists because reprobuild's Nix build wraps every binary with
  ## ~18 `--set-default` env vars and an RPATH into a runtime library
  ## closure, and "every non-Nix package must reproduce this, or the
  ## binary won't run off-Nix". RunQuota's binaries have neither half,
  ## and that is measured rather than assumed:
  ##
  ## * NO ENV DEFAULTS. `RUNQUOTA_SOCKET`, `RUNQUOTA_STATS_TABLE` and
  ##   `RUNQUOTA_REPORT_ESTIMATE_SOURCE` are all OVERRIDES read from the
  ##   caller's environment, and each has a documented default computed
  ##   from the host. Baking `RUNQUOTA_SOCKET` into a wrapper would pin
  ##   every installed client to one endpoint and defeat
  ##   `defaultEndpoint()`, which exists precisely so two users compute
  ##   the same rendezvous path. So `envDefaults` is empty, and
  ##   `wrapExecutables` follows it to `false` — `wrapExecutables`' own
  ##   contract says false is the right choice for a distribution with
  ##   no env defaults, and a wrapper here would be a script that
  ##   resolves a prefix, sets nothing and execs.
  ##
  ## * NO `dlopen` LEAF NAMES. Every `{.dynlib.}` binding in the tree
  ##   names a Win32 system DLL (`kernel32.dll`, `advapi32.dll`) or a
  ##   POSIX libc symbol; there is no third-party shared library opened
  ##   by leaf name anywhere in `libs/` or `apps/`. Declaring a system
  ##   DLL here would ask the layer to vendor a file it must never
  ##   vendor.
  ##
  ## * SQLITE IS A TOOL, NOT A LIBRARY. RunQuota reaches SQLite through
  ##   the `sqlite3` COMMAND (`sqlite_cli.nim`: `findExe(sqliteTool)`),
  ##   deliberately — "a missing tool is an ordinary, catchable
  ##   condition here, which is what OS-4 ('degrade, never fail') needs;
  ##   a missing shared library would be a load-time abort." So it
  ##   contributes nothing to any runtime closure and nothing to any
  ##   import table. See the dependency note below for what the package
  ##   says about it.
  ##
  ## `vendorRuntimeClosure` is left at its default `true` and
  ## `computeDependencyFloor` at `true`: both are Linux-only mechanisms
  ## over the shipped ELF images, and RunQuota's Linux binaries do link
  ## a C library whose floor a `.deb` must state.
  result = newDistribution(RunQuotaPackageName, version, targetOs,
    prefix = prefix, release = release, architecture = architecture,
    layout = (if targetOs == toWindows: plWindowsTree else: plUnix),
    stagingRoot = stagingRoot, outputDir = outputDir)
  # Set BEFORE anything reads it, the ordering discipline reprobuild's
  # own constructors record: `privateLibPrefixRelDir` is derived from
  # this field, and reading it before assignment gives the role default
  # — a bare `lib`, which under `prefix=/usr` would drop this package's
  # vendored closure on top of the distribution's.
  result.runtime.privateLibSubdir = "lib/runquota"
  result.runtime.envDefaults = @[]
  # Nothing to check: `requireEnvDefaultPayload` asserts that every
  # declared default names a path this package SHIPS, and an empty list
  # makes that assertion vacuous rather than false. Left off so the flag
  # keeps meaning "I promised payloads, check them" wherever it is seen.
  result.runtime.requireEnvDefaultPayload = false
  result.runtime.dlopenLeafNames = @[]
  result.runtime.wrapExecutables = false
  result.services = @[runQuotaDaemonService(targetOs)]
  result.metadata = DistMetadata(
    summary: "RunQuota — a host-wide resource lease authority",
    description: "RunQuota bounds the load a machine accepts. One " &
      "daemon per host admits work against that host's measured " &
      "capacity, so parallel builds and test runs share a budget " &
      "instead of each assuming the whole machine.\n" &
      "This package ships the runquota CLI and the runquotad daemon.",
    maintainer: "Metacraft Labs <dev@metacraft-labs.com>",
    vendor: "Metacraft Labs",
    license: "MIT",
    homepage: "https://github.com/metacraft-labs/runquota",
    section: "devel",
    priority: "optional",
    # THE SQLITE DEPENDENCY IS A RECOMMENDS, NOT A DEPENDS, and the
    # distinction is the whole of the decision.
    #
    # Reprobuild's python3 precedent is the case that looks similar and
    # is not. Its package SHIPS an executable python script; without an
    # interpreter that file cannot run at all, and its recipe says so:
    # "a dependency that is optional in the metadata and mandatory in
    # the payload is how a package comes to contain something that
    # cannot run." Mandatory in the payload, therefore mandatory in the
    # metadata.
    #
    # RunQuota's `sqlite3` is the opposite case, and it is opposite by
    # design rather than by accident. `sqliteToolAvailable()` is a real
    # branch with real behaviour behind it (OS-4: "degrade, never
    # fail"): with no `sqlite3` on PATH the daemon still binds its
    # endpoint, still admits and releases leases, still publishes its
    # aggregate table, and says on its own startup line that capture is
    # off. RunQuota's test runner carries
    # `RUNQUOTA_ALLOW_MISSING_SQLITE=1` for exactly this reason — the
    # absence is a SUPPORTED STATE, not a broken host.
    #
    # `Depends: sqlite3` would therefore refuse to install RunQuota on a
    # machine that deliberately has no sqlite3, converting a designed
    # degradation into an installation failure. `Recommends:` is
    # Debian's word for "found together with this package in all but
    # unusual installations", which is precisely true here: apt
    # installs it by default and `--no-install-recommends` does not,
    # and both of those are correct outcomes.
    #
    # It goes through `debControlExtraFields` because the layer's named
    # lists (`debDepends`, `rpmRequires`, `archDepends`) are all HARD
    # requirements and there is no Recommends/optdepends field. rpm and
    # Arch therefore say nothing about sqlite3 in their metadata, and
    # the packaging runbook records that gap rather than letting a
    # `Requires:` paper over it with the wrong strength. The MSI has no
    # dependency mechanism of this kind at all.
    debControlExtraFields: @[("Recommends", "sqlite3")],
    upgradeCode: RunQuotaUpgradeCode)
