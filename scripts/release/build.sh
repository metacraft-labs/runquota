#!/usr/bin/env bash
# Variables below are initialized by the pinned shared common.sh.
# shellcheck disable=SC2154,SC1091
set -euo pipefail
source "${RELEASE_TOOLS:?}/common.sh" "$@"
while read -r name module _; do
  case "$name" in ''|\#*) continue ;; esac
  nim c "${release_nim_flags[@]}" --nimcache:"build/nimcache/release-$release_target-$name" \
    --out:"$release_stage/bin/$name" "$module"
done < apps/entrypoints.txt
cp LICENSE "$release_stage/"
if [ "$release_os" = linux ]; then
  REPROBUILD_SRC="$RELEASE_PACKAGING_SRC" NIMCRYPTO_SRC="$RELEASE_NIMCRYPTO_SRC" \
    BEARSSL_SRC="$RELEASE_BEARSSL_SRC" nim c -d:reproVendoredHash \
      --nimcache:build/nimcache/release-metadata --out:build/release-metadata packaging/release_metadata.nim
  build/release-metadata "$release_target" "$release_stage" build/release-authoring
fi
release_finish
