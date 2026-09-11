#!/usr/bin/env bash
# Rewrite EVERY version source in this repository, in one act.
#
# WHY "EVERY" IS THE WHOLE POINT. RunQuota's version exists three times
# and cannot exist once:
#
#   * `runquota.nimble`            -- what nimble reads;
#   * `runquota_core`'s `RunQuotaVersion` -- what `--version` prints and
#     what the protocol handshake carries;
#   * `packaging/runquota_dist.nim`'s `RunQuotaPackageVersion` -- what
#     every package format carries, compiled by `repro build` under a Nim
#     invocation that has none of `libs/` on its path and therefore
#     cannot import the second one.
#
# This script used to rewrite only the first, so `just bump-version
# 0.2.0` produced a tree whose nimble said 0.2.0 and whose binaries said
# 0.1.0 -- and the release runbook's "confirm every version source
# rewritten" had nothing to confirm. `tests/unit/t_packaging_contract`
# refuses a tree in which the three disagree, so a missed rewrite is now
# a failing test rather than a wrong release.
set -euo pipefail

fail() { echo "bump-version: $*" >&2; exit 1; }

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

if [ "$#" -ne 1 ]; then
  echo "usage: $0 VERSION" >&2
  exit 2
fi

version="$1"
case "${version}" in
  *[!0-9.]*|"") echo "version must contain digits and dots only" >&2; exit 2 ;;
esac

# EACH REWRITE IS CHECKED, NOT ASSUMED. `perl -0pi -e s///` exits 0 when
# it matched nothing, so a renamed constant would leave its file at the
# old version and this script would still report success -- the shape of
# false green this repository has already met elsewhere. So every
# substitution is followed by a read-back of the value it was supposed to
# write.
rewrite() { # rewrite <file> <perl-substitution> <grep-pattern-for-readback>
  local file="$1" subst="$2" readback="$3"
  [ -f "${file}" ] || fail "missing version source: ${file}"
  perl -0pi -e "${subst}" "${file}"
  grep -Eq "${readback}" "${file}" || \
    fail "${file} does not carry version ${version} after the rewrite (pattern: ${readback})"
  echo "  ${file}"
}

echo "bump-version: ${version}"
rewrite runquota.nimble \
  "s/version = \"[^\"]+\"/version = \"${version}\"/" \
  "^version = \"${version}\"\$"
rewrite libs/runquota_core/src/runquota_core.nim \
  "s/const RunQuotaVersion\* = \"[^\"]+\"/const RunQuotaVersion* = \"${version}\"/" \
  "^const RunQuotaVersion\\* = \"${version}\"\$"
rewrite packaging/runquota_dist.nim \
  "s/RunQuotaPackageVersion\* = \"[^\"]+\"/RunQuotaPackageVersion* = \"${version}\"/" \
  "RunQuotaPackageVersion\\* = \"${version}\""

# `t_version.nim` asserts the compiled-in version against a literal, so
# it is a fourth place the string appears -- deliberately, because a test
# that read the constant it is checking would assert nothing. It is
# rewritten here too so a bump does not leave the suite red.
rewrite tests/unit/t_version.nim \
  "s/versionString\(\) == \"[^\"]+\"/versionString() == \"${version}\"/" \
  "versionString\\(\\) == \"${version}\""

echo "bump-version: 4 sources rewritten to ${version}"
