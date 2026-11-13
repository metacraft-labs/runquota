#!/usr/bin/env bash
#
# THE MEASUREMENT OVERHEAD GATE: does turning RunQuota's measurements on make
# a build more than 1% slower, in wall time or CPU time?
#
#   scripts/run-overhead-gate.sh [reprobuild-64|cargo-jobserver|synthetic] [gate options]
#
# See benchmarks/lib/runquota_overhead_gate.nim for what the gate does and
# benchmarks/README.md for how to read its report. Exit status is the gate's:
# 0 pass, 1 fail, 3 inconclusive, 4 case unavailable, 5 a run could not be
# measured. Only 0 is a pass.
#
# RELEASE BY DEFAULT, like every benchmark here (scripts/lib/build_mode.sh):
# a debug runquotad spends more CPU on everything, which inflates whatever
# its measurements cost.
#
# THE REPROBUILD CASE needs a `reprobuild` engine built against THIS RunQuota
# checkout, or its client-side measurement switch does not exist in it and
# the gate refuses (exit 4). Build one with, in a reprobuild checkout:
#
#   nix develop --command bash -c \
#     'RUNQUOTA_SRC=/path/to/this/runquota REPROBUILD_BUILD_MODE=release just build'
#
# (inside the shell: reprobuild's dev shell sets RUNQUOTA_SRC itself) and
# point REPRO_ENGINE at its build/bin/reprobuild. The engine runs inside
# reprobuild's own dev shell, which supplies the compiler its recipe provider
# is built with; REPROBUILD_SRC names that checkout.
#
# NOISE. The host is assumed shared. The gate interleaves the arms and stops
# on a confidence interval, so noise costs rounds rather than correctness, and
# a host too noisy to reach the precision in --max-rounds/--max-minutes is
# reported as inconclusive. To cut noise further, pin the run to a set of
# CPUs with RUNQUOTA_GATE_CPUS (a taskset(1) list, Linux).
set -euo pipefail

case_name="${1:-reprobuild-64}"
shift || true

mkdir -p bench-results build/bin build/nimcache test-logs

# shellcheck source=scripts/lib/build_mode.sh
. "$(dirname "$0")/lib/build_mode.sh"
resolve_build_mode release
ensure_apps_built_in_mode "${RUNQUOTA_RESOLVED_BUILD_MODE}"

gate_bin="build/bin/runquota_overhead_gate"
nim c \
  --threads:on \
  --hints:off \
  ${nim_mode_flags[@]+"${nim_mode_flags[@]}"} \
  --nimcache:"build/nimcache/runquota_overhead_gate" \
  --out:"${gate_bin}" \
  benchmarks/lib/runquota_overhead_gate.nim >/dev/null

out="bench-results/runquota-overhead-gate-${case_name}.json"
args=("--case=${case_name}" "--out=${out}")

pin=()
if [ -n "${RUNQUOTA_GATE_CPUS:-}" ]; then
  pin=(taskset -c "${RUNQUOTA_GATE_CPUS}")
fi

run_gate() {
  local status=0
  "$@" || status=$?
  echo "overhead gate (${case_name}): exit ${status}; report ${out}" >&2
  return "${status}"
}

case "${case_name}" in
  reprobuild-64)
    reprobuild_root="${REPROBUILD_SRC:-$(cd .. && pwd)/reprobuild}"
    engine="${REPRO_ENGINE:-${reprobuild_root}/build/bin/reprobuild}"
    args+=("--daemon=$(pwd)/build/bin/runquotad"
      "--engine=${engine}"
      "--fixture=$(pwd)/benchmarks/fixtures/reprobuild-64-actions")
    gate_abs="$(pwd)/${gate_bin}"
    # Positional arguments expand in the child shell, after activation.
    # shellcheck disable=SC2016
    run_gate nix develop "${reprobuild_root}" --command \
      bash -c 'cd "$1" && shift && exec "$@"' overhead-gate "$(pwd)" \
      ${pin[@]+"${pin[@]}"} "${gate_abs}" "${args[@]}" "$@"
    ;;
  cargo-jobserver|synthetic)
    run_gate ${pin[@]+"${pin[@]}"} "${gate_bin}" "${args[@]}" "$@"
    ;;
  *)
    echo "usage: $0 [reprobuild-64|cargo-jobserver|synthetic] [gate options]" >&2
    exit 2
    ;;
esac
