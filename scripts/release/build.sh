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
release_finish
