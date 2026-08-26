#!/usr/bin/env bash
#
# M13 overhead benchmark: the per-execution latency the socket observation
# write path adds, versus a capture-disabled control.
#
set -euo pipefail

quick=false
for arg in "$@"; do
  case "${arg}" in
    --quick) quick=true ;;
    *) echo "unknown benchmark argument: ${arg}" >&2; exit 2 ;;
  esac
done

output="bench-results/runquota-observation-write-path.json"
bench_bin="build/bin/runquota_m13_bench"
nimcache="build/nimcache/runquota_m13_bench"

mkdir -p bench-results build/bin build/nimcache test-logs

# RELEASE BY DEFAULT. A measurement is meaningless from a Nim debug build
# (`opt: none`), and the arm this one is compared against -- `nim-shm-lease`'s
# preemption study -- is `-d:release` throughout. See scripts/lib/build_mode.sh.
# shellcheck source=scripts/lib/build_mode.sh
. "$(dirname "$0")/lib/build_mode.sh"
resolve_build_mode release
ensure_apps_built_in_mode "${RUNQUOTA_RESOLVED_BUILD_MODE}"

nim c \
  --threads:on \
  ${nim_mode_flags[@]+"${nim_mode_flags[@]}"} \
  --nimcache:"${nimcache}" \
  --out:"${bench_bin}" \
  benchmarks/lib/runquota_m13_bench.nim >/dev/null

args=()
if [ "${quick}" = true ]; then
  args+=("--quick")
fi

echo "running RunQuota M13 observation write-path benchmark (quick=${quick})" >&2
"${bench_bin}" ${args[@]+"${args[@]}"} | tee "${output}"
