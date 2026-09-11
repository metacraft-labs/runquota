## RunQuota's packages, produced through reprobuild's packaging layer.
##
## A SEPARATE reprobuild project from the repository root's `repro.nim`,
## and deliberately so. The root project's `defaultToolProvisioning` is
## `"path"` — its `nim`, `gcc`, `just` and `sh` come from `nix develop`,
## which is right for a build whose only tools are the ones the dev
## shell already furnishes. Packaging needs the opposite: WiX v3 arrives
## as a pinned upstream zip that no dev shell carries, so this project
## provisions its tools as hermetic tarballs. Tool provisioning governs
## a whole build rather than one edge, so the two cannot be one project.
## Reprobuild packages itself the same way, from
## `tests/fixtures/packaging/reprobuild-dist/repro.nim`.
##
## ## Where the payload comes from, stated plainly
##
## The components are read from `prebuilt/bin/`, which
## `scripts/stage_package_payload.sh` fills from an already-built
## RunQuota -- ONE script for every host rather than a pair, because what
## it does (copy the binaries `apps/entrypoints.txt` names out of
## `build/bin`) is the same act everywhere and a second copy of it would
## be a second thing to keep true. That is a real limitation and it is
## recorded rather than hidden: RunQuota is built by `nim c` through
## `scripts/build_apps.sh` and by `repro build` through the ROOT
## project, and standing this recipe on either would make a packaging
## result depend on a build result from a different project.
##
## What it does NOT weaken is what this recipe is testing. The payload
## arrives as ordinary build-tree files; from there every step — the
## staging, the service rows, the Directory/Component tables, the
## archives — is the same code path reprobuild's own packages take, and
## none of it can tell where its inputs came from. The paths are
## relative, so the graph names no host directory.

import repro_project_dsl
import repro_dsl_stdlib/packaging

import ./runquota_dist

const
  PrebuiltBin = "prebuilt/bin"
    ## Filled by the staging script from an already-built RunQuota. See
    ## the header for why, and for what it does and does not weaken.
  PrebuiltShare = "prebuilt/share"
    ## Non-executable payload staged the same way — the licence text,
    ## laid out under this root exactly as it is laid out under the
    ## install prefix, so the recipe never translates between two
    ## spellings of one path.

func hostTargetOs(): TargetOs =
  when defined(windows): toWindows
  elif defined(macosx): toDarwin
  else: toLinux

proc runQuotaComponents(targetOs: TargetOs): seq[DistComponent] =
  ## What ships: two executables and a licence.
  ##
  ## `runquotad` is `crExecutable` and NOT `crHelperExecutable`, which
  ## is the one component decision here that could have gone either way.
  ## A helper goes under `libexec/<package>`, off the user's PATH, and
  ## the role's own contract says it is for "an internal helper the
  ## package's own binaries spawn" — `runquota` never spawns
  ## `runquotad`, an operator does. The daemon is named in the service
  ## unit, it is what an administrator runs by hand with `--socket` and
  ## a capacity table to diagnose a host, and its `--help` is a
  ## documented interface. Hiding it in `libexec` would put the one
  ## binary the runbook tells you to invoke somewhere no `PATH` reaches.
  ##
  ## `runquota_m5_process_bench` — which `scripts/build_apps.sh` also
  ## produces — is deliberately NOT here. It is a benchmark driver, in
  ## the same class as the `repro-harvest-*` and `repro-peer-cache-*`
  ## tools reprobuild's §3 keeps out of its packages. A recipe that
  ## shipped whatever was in `build/bin` would be making a product
  ## decision by omission; `apps/entrypoints.txt` is the manifest of
  ## what RunQuota ships, and it has exactly these two rows.
  ##
  ## NO RUNTIME LIBRARY COMPONENTS ON WINDOWS, and that is measured
  ## rather than assumed. Reprobuild's Windows packages need an explicit
  ## `reprobuildWindowsLoaderLibraries` list because the layer's runtime
  ## closure walk is ELF-only, so a Windows package ships its
  ## executables and nothing they load. RunQuota's two images import
  ## `KERNEL32.dll` and `msvcrt.dll` and nothing else (PE import table),
  ## and every `{.dynlib.}` binding in `libs/` and `apps/` names
  ## `kernel32.dll` or `advapi32.dll` — all three are Windows system
  ## DLLs in `%SystemRoot%\system32`, which a package must never ship.
  ## The claim is not left as a claim: `just verify-package windows`
  ## launches the staged binaries with the environment rebuilt from
  ## empty and `PATH` set to the two system directories, in an empty
  ## directory, which is where a library this list forgot would show up
  ## as a loader failure rather than as a green build on the machine
  ## that produced it.
  let sfx = (if targetOs == toWindows: ".exe" else: "")
  result = @[
    executableComponent(PrebuiltBin & "/runquota" & sfx),
    executableComponent(PrebuiltBin & "/runquotad" & sfx)
  ]
  result.add(component(crDataFile, PrebuiltShare & "/LICENSE"))

package `runquota-packages`:
  config:
    sourceRepository = "https://github.com/metacraft-labs/runquota.git"
    sourceRevision = "refs/heads/dev"
    sourceChecksum = "sha256-packaging"

  # HERMETIC TARBALLS, NOT THE AMBIENT PATH. The root project's
  # `defaultToolProvisioning "path"` is right for a build whose tools
  # come from `nix develop`; it is wrong here, because WiX v3 is a
  # pinned upstream zip that no dev shell carries and no distribution
  # packages. Declared in the recipe rather than passed on every command
  # line so `just build-package` and a hand-run cannot disagree about
  # which mode produced an artifact.
  defaultToolProvisioning "tarball"

  uses:
    # Every producer's tools, as a UNION ACROSS FORMATS AND HOSTS — the
    # `uses:` block is a macro-time literal list and cannot be
    # conditioned on the target. A tool named here is provisioned only
    # when an edge that names it is actually built, so the Linux tools
    # cost a Windows run nothing.
    #
    # MSI (the Windows leg, and this milestone's named ask).
    "wix-candle"
    "wix-light"
    # TARBALL, on both legs: the relocatable fallback, and on Windows
    # also the archive a Scoop manifest describes.
    "tar"
    "gzip"
    # The POSIX staging path's trio. Windows staging uses the engine's
    # own `fs.copyFile` builtin and needs none of them.
    "install-file"
    "sh"
    "find"
    # deb and rpm.
    "dpkg-deb"
    "rpmbuild"
    "diff"
    "sed"
    # The §5 Linux contract: the RPATH and ELF-interpreter rewrite, and
    # the closure walk that fills the private libdir they point at.
    "patchelf"
    "readelf"
    # ARCH's `.MTREE`. libarchive's tar is the only one that writes an
    # mtree, and `grep` is what the mtree step's own post-conditions
    # run.
    "bsdtar"
    "grep"

  build:
    let targetOs = hostTargetOs()

    var dist = newRunQuotaDistribution(RunQuotaPackageVersion, targetOs,
      # An empty prefix on Windows: the MSI's install location is chosen
      # by the installer at install time (`ProgramFiles64Folder`), so
      # the staged tree IS the prefix and there is no build-time root
      # for it to be relative to.
      prefix = (if targetOs == toWindows: "" else: "/usr"),
      stagingRoot = "build/dist/runquota-" & RunQuotaPackageVersion,
      outputDir = "build/dist")
    dist.components = runQuotaComponents(targetOs)

    let site = packagingSite("runquota-packages")
    when defined(windows):
      discard msiPackage(dist, site)
      # SCOOP, over the TARBALL rather than over the MSI, and that is
      # Scoop's model rather than a convenience: a manifest names an
      # ARCHIVE it unpacks into its own app directory, while an MSI is
      # an installer that writes to the registry and the SCM. They are
      # the two ways of installing on Windows and Scoop wants the first,
      # so the Windows leg produces both and the manifest takes the
      # archive producer's artifact as a parameter.
      #
      # The URL is left as `ScoopUrlToken`: where a release is published
      # is the publish workflow's business, and a manifest with a
      # plausible but wrong URL installs whatever is at that address.
      #
      # A Scoop install gets NO SERVICE — Scoop has no mechanism for
      # one. That is a real difference between the two Windows channels
      # and the runbook says so rather than letting a user discover it.
      discard scoopPackage(dist, tarballPackage(dist, site), site)
    else:
      discard debPackage(dist, site)
      discard rpmPackage(dist, site)
      discard archPackage(dist, site)
      discard tarballPackage(dist, site)
