#!/usr/bin/env bash
# Fill `packaging/prebuilt/` from an already-built RunQuota.
#
# WHY THE PAYLOAD IS STAGED RATHER THAN BUILT BY THE PACKAGING PROJECT.
# `packaging/repro.nim` is a SEPARATE reprobuild project from the
# repository root's, because the two need opposite tool-provisioning
# modes (see that file's header). A separate project cannot reach into
# another project's build outputs as typed edges, so the binaries arrive
# here as ordinary files. That is a real limitation and it is recorded
# in the recipe rather than hidden.
#
# WHAT THIS SCRIPT REFUSES. A staging step that silently copied nothing
# would leave `repro build` staging a previous run's payload, and the
# package would be a function of the order somebody ran two commands in.
# Every file this script expects is named, and a missing one stops it.
set -euo pipefail

fail() { echo "stage_package_payload: $*" >&2; exit 1; }

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

# The executable suffix this host's binaries carry. `uname -s` answers
# MINGW64_NT-* / MSYS_NT-* under Git Bash and MSYS2, which is where a
# Windows package is staged from.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) sfx=".exe" ;;
  *)                    sfx="" ;;
esac

bin_out="packaging/prebuilt/bin"
share_out="packaging/prebuilt/share"

# REMOVED AND RECREATED, not overwritten. A binary that stopped being
# shipped -- or one renamed -- would otherwise stay in the staging tree
# and keep appearing in every package built afterwards. Reprobuild's own
# M1 shipped a deleted binary for exactly this reason.
rm -rf packaging/prebuilt
mkdir -p "${bin_out}" "${share_out}"

# THE MANIFEST IS `apps/entrypoints.txt`, not a list written here. It is
# what the Windows compile gate sweeps and what `scripts/build_apps.sh`
# builds, so a third list would be a third answer to "what does RunQuota
# ship".
staged=0
while read -r name _path _rest; do
  case "${name}" in
    ""|\#*) continue ;;
  esac
  src="build/bin/${name}${sfx}"
  [ -f "${src}" ] || fail "missing ${src}; run 'just build' first"
  cp -- "${src}" "${bin_out}/${name}${sfx}"
  staged=$((staged + 1))
done < apps/entrypoints.txt

# A manifest this script failed to parse would otherwise sweep nothing
# and report success. The floor is the count in the tree today; it
# cannot be lowered without editing this file on purpose.
if [ "${staged}" -lt 2 ]; then
  fail "apps/entrypoints.txt yielded ${staged} binaries; refusing to stage an empty payload"
fi

cp -- LICENSE "${share_out}/LICENSE"

echo "staged ${staged} binaries and 1 data file into packaging/prebuilt"
