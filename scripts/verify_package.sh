#!/usr/bin/env bash
# Verify one distribution channel's artifact, over the SHIPPED BYTES.
#
# `just verify-package <channel>`, run after `just build-package
# <channel>`. It reads what the artifact actually contains -- not the
# recipe that produced it, and not the intermediate files the producer
# generated, because a check over those could only establish that the
# renderer agrees with itself.
#
# EVERY ARM CAN FAIL, AND THE FAILURE IS SPECIFIC. A pattern list that
# passes on any failure it does not spell is the shape this campaign has
# caught repeatedly; so each assertion below names one property, and a
# run that asserted nothing is a failure rather than a pass.
set -euo pipefail

fail() { echo "verify-package: $*" >&2; exit 1; }

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

[ "$#" -eq 1 ] || fail "usage: $0 CHANNEL (one of: msi scoop deb rpm arch tarball nix)"
channel="$1"

version="$(sed -n 's/^version *= *"\([^"]*\)".*/\1/p' runquota.nimble)"
[ -n "${version}" ] || fail "could not read the version out of runquota.nimble"

listing="build/package-artifacts-${channel}.txt"
require_artifact() {
  [ -f "${listing}" ] || fail "no ${listing}; run 'just build-package ${channel}' first"
  local count
  count="$(grep -c . "${listing}" || true)"
  [ "${count}" -eq 1 ] || fail "${listing} names ${count} artifacts, expected 1"
  artifact="$(cat "${listing}")"
  [ -s "${artifact}" ] || fail "the artifact ${artifact} is missing or empty"
}

# The staged install tree the Windows producers built from. It is the
# prefix-rooted variant, which is what an installed package looks like.
staged_msi_tree="packaging/build/dist/runquota-${version}/msi"

case "${channel}" in
  msi)
    require_artifact
    command -v pwsh >/dev/null 2>&1 || command -v powershell >/dev/null 2>&1 || \
      fail "no PowerShell on PATH; the MSI arms read the database through WindowsInstaller"
    ps="pwsh"; command -v pwsh >/dev/null 2>&1 || ps="powershell"

    # ARM 1: THE DATABASE. Product identity, the shipped files, and the
    # service rows -- read out of the MSI itself.
    #
    # `ExpectedVersion` is `major.minor.build`: MSI ignores a fourth
    # field when comparing versions, so the packaging release is
    # deliberately not part of ProductVersion.
    msi_version="$(printf '%s' "${version}" | awk -F. '{printf "%s.%s.%s", ($1==""?0:$1), ($2==""?0:$2), ($3==""?0:$3)}')"
    upgrade_code="$(sed -n 's/.*RunQuotaUpgradeCode\* = "\({[^"]*}\)".*/\1/p' packaging/runquota_dist.nim)"
    [ -n "${upgrade_code}" ] || fail "could not read RunQuotaUpgradeCode out of packaging/runquota_dist.nim"
    "${ps}" -NoProfile -ExecutionPolicy Bypass \
      -File scripts/verify_windows_package.ps1 \
      -MsiPath "${artifact}" \
      -ExpectedVersion "${msi_version}" \
      -ExpectedUpgradeCode "${upgrade_code}"

    # ARM 2: THE SCRUBBED LAUNCH. RunQuota's Windows package declares no
    # runtime library components at all; this is what turns that claim
    # into a measurement. See the script's own header.
    [ -d "${staged_msi_tree}" ] || fail "no staged tree at ${staged_msi_tree}"
    "${ps}" -NoProfile -ExecutionPolicy Bypass \
      -File scripts/check_windows_scrubbed_launch.ps1 -TreeRoot "${staged_msi_tree}"
    ;;

  scoop)
    require_artifact
    # THE TOKENS MUST BE GONE. The Scoop producer leaves `@SCOOP_URL@`
    # and `@SCOOP_SHA256@` for the publish step to substitute; a manifest
    # that still carries one would make `scoop install` fetch nothing, or
    # fetch something and refuse its hash -- and only after a user tried.
    #
    # This arm therefore asserts the manifest is well-formed JSON with a
    # version, and REPORTS the tokens rather than failing on them: an
    # unpublished manifest legitimately has them, and it is the publish
    # workflow that must refuse one. See the runbook.
    # `python3` on a Nix dev shell, `python` on a Windows one. Named by
    # value rather than inferred: a fallback that silently found neither
    # would leave this arm asserting nothing.
    py=""
    for candidate in python3 python; do
      if command -v "${candidate}" >/dev/null 2>&1; then py="${candidate}"; break; fi
    done
    [ -n "${py}" ] || fail "no python3/python on PATH; cannot parse the Scoop manifest"
    "${py}" -c "import json,sys; d=json.load(open(sys.argv[1])); assert d.get('version'), 'manifest has no version'; assert d.get('bin'), 'manifest exposes no bin'; print('scoop manifest version', d['version'], 'bin', d['bin'])" "${artifact}"
    if grep -q '@SCOOP_URL@\|@SCOOP_SHA256@' "${artifact}"; then
      echo "verify-package: note -- the manifest still carries publish tokens (expected before a release)"
    fi
    ;;

  tarball)
    require_artifact
    # CONTENTS THROUGH A FILE, NEVER A PIPE. `tar -tzf | grep` gives
    # grep's status, and a tar that failed to open the archive at all
    # would then be read as "the entry is absent" -- the same class of
    # inversion as `ls | head`.
    tar -tzf "${artifact}" > build/package-contents-${channel}.txt
    for want in bin/runquota bin/runquotad; do
      grep -Fq "${want}" "build/package-contents-${channel}.txt" || \
        fail "the tarball does not contain ${want}"
    done
    echo "verify-package: tarball carries both binaries"
    ;;

  deb)
    require_artifact
    command -v dpkg-deb >/dev/null 2>&1 || fail "dpkg-deb is not on PATH"
    dpkg-deb -c "${artifact}" > build/package-contents-${channel}.txt
    dpkg-deb -f "${artifact}" > build/package-control-${channel}.txt
    grep -Fq "usr/bin/runquotad" build/package-contents-${channel}.txt || \
      fail "the .deb does not contain usr/bin/runquotad"
    # THE DEGRADING DEPENDENCY IS A RECOMMENDS AND MUST STAY ONE. A
    # `Depends: sqlite3` would refuse to install RunQuota on a host that
    # deliberately has no sqlite3, converting OS-4's designed degradation
    # into an installation failure.
    grep -Eq '^Recommends: .*sqlite3' build/package-control-${channel}.txt || \
      fail "the .deb does not Recommend sqlite3"
    if grep -Eq '^Depends: .*sqlite3' build/package-control-${channel}.txt; then
      fail "the .deb DEPENDS on sqlite3; it must only Recommend it"
    fi
    echo "verify-package: deb contents and control fields check out"
    ;;

  rpm)
    require_artifact
    command -v rpm >/dev/null 2>&1 || fail "rpm is not on PATH"
    rpm -qlp "${artifact}" > build/package-contents-${channel}.txt
    grep -Fq "/usr/bin/runquotad" build/package-contents-${channel}.txt || \
      fail "the .rpm does not contain /usr/bin/runquotad"
    echo "verify-package: rpm contents check out"
    ;;

  arch)
    require_artifact
    command -v bsdtar >/dev/null 2>&1 || fail "bsdtar is not on PATH"
    bsdtar -tf "${artifact}" > build/package-contents-${channel}.txt
    for want in usr/bin/runquotad .PKGINFO .MTREE; do
      grep -Fq "${want}" build/package-contents-${channel}.txt || \
        fail "the pacman package does not contain ${want}"
    done
    echo "verify-package: pacman package contents check out"
    ;;

  nix)
    [ -e result ] || fail "no 'result' symlink; run 'just build-package nix' first"
    for want in bin/runquota bin/runquotad; do
      [ -x "result/${want}" ] || fail "the nix output has no executable ${want}"
    done
    echo "verify-package: nix output carries both binaries"
    ;;

  *) fail "unknown channel '${channel}'; the channels are: msi scoop deb rpm arch tarball nix" ;;
esac

echo "verify-package: ${channel} PASS"
