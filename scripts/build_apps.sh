#!/usr/bin/env bash
set -euo pipefail

mkdir -p build/bin build/nimcache

nim_flags=(--threads:on)
case "${RUNQUOTA_BUILD_MODE:-${REPROBUILD_BUILD_MODE:-debug}}" in
  debug|"")
    ;;
  release)
    nim_flags+=(-d:release)
    ;;
  *)
    echo "unknown RUNQUOTA_BUILD_MODE: ${RUNQUOTA_BUILD_MODE:-${REPROBUILD_BUILD_MODE:-debug}}" >&2
    exit 2
    ;;
esac

while read -r name path _; do
  case "${name}" in
    ""|\#*) continue ;;
  esac
  nim c \
    "${nim_flags[@]}" \
    --nimcache:"build/nimcache/${name}" \
    --out:"build/bin/${name}" \
    "${path}"
done < apps/entrypoints.txt
