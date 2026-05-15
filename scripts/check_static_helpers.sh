#!/usr/bin/env bash
set -euo pipefail

mkdir -p build/static-libs build/nimcache

while read -r lib _; do
  case "${lib}" in
    ""|\#*) continue ;;
  esac
  if grep -R -n -E '(^|[^A-Za-z0-9_])ref([^A-Za-z0-9_]|$)' "libs/${lib}/src" --include='*.nim'; then
    echo "Nim ref type token found in static helper ${lib}" >&2
    exit 1
  fi
  nim c \
    --mm:arc \
    --app:staticlib \
    --nimcache:"build/nimcache/static-${lib}" \
    --out:"build/static-libs/lib${lib}.a" \
    "libs/${lib}/src/${lib}.nim"
done < libs/static_helpers.txt

echo "runquota static helper checks passed"
