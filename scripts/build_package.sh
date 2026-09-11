#!/usr/bin/env bash
# Build one distribution channel's artifact for this host.
#
# `just build-package <channel>`. The channel vocabulary and what each
# one means is recorded in
# `codetracer-specs/runbooks/packaging/runquota.md` §3; this script is
# the executable half of that table and refuses anything not in it.
#
# WHY A CHANNEL A HOST CANNOT PRODUCE IS A REFUSAL AND NOT A SKIP. The
# MSI producer's tools are WiX v3, which is Windows-native PE
# executables with no Linux channel; the deb/rpm/arch producers stage
# through `patchelf` and an ELF closure walk. A script that quietly did
# nothing for the wrong host would let `just build-package msi` on a
# Linux runner report success having produced no installer, which is the
# exact false green this campaign keeps meeting.
set -euo pipefail

fail() { echo "build-package: $*" >&2; exit 1; }

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

[ "$#" -eq 1 ] || fail "usage: $0 CHANNEL (one of: msi scoop deb rpm arch tarball nix)"
channel="$1"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) host_os="windows" ;;
  Darwin)               host_os="darwin" ;;
  *)                    host_os="linux" ;;
esac

# The extension each channel's artifact carries, and the host class that
# can produce it. `nix` is handled separately below: it is the flake, not
# a packaging-layer producer.
case "${channel}" in
  msi)     want_os="windows"; glob="packaging/build/dist/runquota-*.msi" ;;
  # The Scoop manifest is `<name>.json` with NO version in it: `scoop
  # install runquota` looks for `runquota.json` in a bucket, so the
  # producer names it that and the version lives inside.
  scoop)   want_os="windows"; glob="packaging/build/dist/runquota.json" ;;
  # THE HOST'S OWN OS IS IN THE GLOB, and it has to be. The tarball
  # producer names its artifact `<name>-<ver>-<rel>-<os>-<arch>.tar.gz`,
  # but the ARCH producer emits `<name>-<ver>-<rel>-<arch>.pkg.tar.gz` --
  # which also ends in `.tar.gz`. A bare `runquota-*.tar.gz` therefore
  # matches BOTH on a Linux host, and the exactly-one-artifact assertion
  # below refuses with "found 2". Invisible on Windows, where no arch
  # producer runs, and so not seen until the Linux leg was first
  # executed: the whole reason a real run beats a plausible one.
  tarball) want_os="any";     glob="packaging/build/dist/runquota-*-${host_os}-*.tar.gz" ;;
  deb)     want_os="linux";   glob="packaging/build/dist/runquota_*.deb" ;;
  rpm)     want_os="linux";   glob="packaging/build/dist/runquota-*.rpm" ;;
  arch)    want_os="linux";   glob="packaging/build/dist/runquota-*.pkg.tar.*" ;;
  nix)     want_os="any";     glob="" ;;
  *) fail "unknown channel '${channel}'; the channels are: msi scoop deb rpm arch tarball nix" ;;
esac

if [ "${channel}" = "nix" ]; then
  # THE FLAKE, WHICH IS NOT A PACKAGING-LAYER PRODUCER. `flake.nix`
  # already declares `packages.default` and `ci.yml` already builds it;
  # this recipe exists so the channel vocabulary has no hole in it, not
  # because there is a second mechanism.
  command -v nix >/dev/null 2>&1 || fail "nix is not on PATH"
  nix build .#default
  [ -e result ] || fail "nix build produced no 'result' symlink"
  echo "build-package: nix -> $(readlink result)"
  exit 0
fi

if [ "${want_os}" != "any" ] && [ "${host_os}" != "${want_os}" ]; then
  fail "channel '${channel}' is produced on ${want_os} hosts only; this host is ${host_os}"
fi
if [ "${channel}" = "tarball" ] && [ "${host_os}" = "darwin" ]; then
  fail "the tarball producer stages through the POSIX path; macOS staging is not exercised yet"
fi

# `repro` is reprobuild's CLI. In CI it comes from `setup-dev-env` with
# `env-flavor: reprobuild`; on a developer host it is whatever `repro` is
# on PATH, or an explicit override. NOT guessed from a sibling checkout:
# a packaging result that depended on which directory happened to be
# beside this one would not be reproducible.
repro="${REPRO:-repro}"
command -v "${repro}" >/dev/null 2>&1 || \
  fail "no '${repro}' on PATH; set REPRO=/path/to/repro, or run under 'dev-exec' with env-flavor: reprobuild"

# TOOL PROVISIONING IS PER-HOST, AND THE RECIPE CANNOT SAY SO.
#
# `packaging/repro.nim` declares `defaultToolProvisioning "tarball"`
# because WiX v3 is a pinned upstream zip that no dev shell carries, and
# tool provisioning governs a WHOLE BUILD rather than one edge. The DSL
# takes a single string LITERAL there -- `defaultToolProvisioning expects
# exactly one string literal` -- so it cannot be conditioned on the host,
# and one project cannot say "tarball on Windows, nix on Linux".
#
# On Linux that literal is not merely suboptimal, it REFUSES: no
# packaging tool in reprobuild's stdlib has a Linux tarball channel.
# `tar`, `gzip`, `install-file` and `sh` carry a tarball entry marked
# `os = "windows"`, and `dpkg-deb`, `rpmbuild`, `patchelf`, `readelf` and
# `bsdtar` carry none at all, so the build stops with
#   tool-resolution failed: no tarball provisioning entry for package
#   "tar" matches host cpu=x86_64 os=linux
# before a single producer runs.
#
# `REPRO_TOOL_PROVISIONING` is reprobuild's documented override for
# exactly this ("select provisioning without editing every project"), and
# it takes precedence over the package's own default. Setting it HERE
# rather than in the workflow keeps `just build-package deb` and the CI
# step producing the same artifact from the same inputs -- the property
# the whole packaging recipe is built on. An operator who has already
# chosen a mode keeps it.
if [ "${host_os}" != "windows" ] && [ -z "${REPRO_TOOL_PROVISIONING:-}" ]; then
  export REPRO_TOOL_PROVISIONING=nix
  echo "build-package: REPRO_TOOL_PROVISIONING=nix (the recipe's 'tarball' default is Windows-only)"
fi

bash scripts/stage_package_payload.sh

# EVERY FORMAT THIS HOST CAN PRODUCE IS BUILT, and then ONE is asserted
# to exist. `packaging/repro.nim`'s build block declares the host's whole
# format set in one graph; asking the engine for a subset would mean
# naming per-format targets whose only purpose is to be named here.
# Building them together costs one staging pass rather than N.
(cd packaging && "${repro}" build)

# THE ARTIFACT IS FOUND THROUGH A FILE, NEVER A PIPE. `ls | head` gives
# `head`'s exit status, which is 0 whether or not anything matched --
# the shape that has already inverted one refusal in this campaign.
listing="build/package-artifacts-${channel}.txt"
mkdir -p build
# shellcheck disable=SC2086
find ${glob} -maxdepth 0 -type f > "${listing}" 2>/dev/null || true
count="$(grep -c . "${listing}" || true)"
if [ "${count}" -ne 1 ]; then
  echo "build-package: expected exactly one artifact matching ${glob}, found ${count}:" >&2
  cat "${listing}" >&2
  exit 1
fi
artifact="$(cat "${listing}")"
[ -s "${artifact}" ] || fail "the artifact ${artifact} is empty"

echo "build-package: ${channel} -> ${artifact} ($(wc -c < "${artifact}") bytes)"
