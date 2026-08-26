#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: $0 process|ipc [--quick]" >&2
  exit 2
fi

suite="$1"
shift
quick=false
for arg in "$@"; do
  case "${arg}" in
    --quick) quick=true ;;
    *) echo "unknown benchmark argument: ${arg}" >&2; exit 2 ;;
  esac
done

case "${suite}" in
  process)
    output="bench-results/runquota-process-execution.json"
    bench_bin="build/bin/runquota_m5_process_bench"
    nimcache="build/nimcache/runquota_m5_process_bench"
    ;;
  ipc)
    output="bench-results/runquota-ipc.json"
    bench_bin="build/bin/runquota_m5_ipc_bench"
    nimcache="build/nimcache/runquota_m5_ipc_bench"
    ;;
  *) echo "unknown benchmark suite: ${suite}" >&2; exit 2 ;;
esac

mkdir -p bench-results build/bin build/nimcache test-logs

# RELEASE BY DEFAULT -- see scripts/lib/build_mode.sh for why a benchmark's
# default differs from the rest of the repository's.
# shellcheck source=scripts/lib/build_mode.sh
. "$(dirname "$0")/lib/build_mode.sh"
resolve_build_mode release
ensure_apps_built_in_mode "${RUNQUOTA_RESOLVED_BUILD_MODE}"

nim c \
  --threads:on \
  ${nim_mode_flags[@]+"${nim_mode_flags[@]}"} \
  --nimcache:"${nimcache}" \
  --out:"${bench_bin}" \
  benchmarks/lib/runquota_m5_bench.nim >/dev/null

args=("--suite=${suite}")
if [ "${quick}" = true ]; then
  args+=("--quick")
fi

echo "running RunQuota M5 ${suite} benchmark (quick=${quick})" >&2
"${bench_bin}" "${args[@]}" | tee "${output}"
