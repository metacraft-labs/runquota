#!/usr/bin/env bash
set -euo pipefail

mkdir -p build/bin build/nimcache

# shellcheck source=scripts/lib/build_mode.sh
. "$(dirname "$0")/lib/build_mode.sh"
resolve_build_mode debug

while read -r name path _; do
  name="${name%$'\r'}"
  path="${path%$'\r'}"
  case "${name}" in
    ""|\#*) continue ;;
  esac
  nim c \
    --threads:on \
    ${nim_mode_flags[@]+"${nim_mode_flags[@]}"} \
    --nimcache:"build/nimcache/${name}" \
    --out:"build/bin/${name}" \
    "${path}"
done < apps/entrypoints.txt

# RECORD WHAT WAS BUILT, so a later consumer can ask rather than assume.
# `build/bin/runquotad` is an INPUT to the integration tests and to every
# benchmark; its mere existence says nothing about how it was compiled, and a
# benchmark that reused a debug daemon published a number for a pair of
# binaries built two different ways.
printf '%s\n' "${RUNQUOTA_RESOLVED_BUILD_MODE}" > "$(build_apps_mode_stamp)"
