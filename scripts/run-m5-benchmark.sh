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
if [ ! -x build/bin/runquotad ] || [ ! -x build/bin/runquota ]; then
  ./scripts/build_apps.sh
fi

nim c \
  --threads:on \
  --nimcache:"${nimcache}" \
  --out:"${bench_bin}" \
  benchmarks/lib/runquota_m5_bench.nim >/dev/null

args=("--suite=${suite}")
if [ "${quick}" = true ]; then
  args+=("--quick")
fi

echo "running RunQuota M5 ${suite} benchmark (quick=${quick})" >&2
"${bench_bin}" "${args[@]}" | tee "${output}"
