#!/usr/bin/env bash
#
# M1 SOCKET BASELINE: what RunQuota's socket costs a real `repro` build.
#
# THIS IS THE ONLY BENCHMARK IN THIS REPOSITORY WHOSE WORKLOAD IS NOT
# SYNTHETIC. The M5 `ipc` suite and the M13 write-path suite both drive a real
# daemon over a real socket from a tight loop; M1's gate says "a real wide
# build and a real parallel test run", so the client here is `repro` itself and
# the instrument is a measuring relay on the wire. See
# benchmarks/lib/runquota_m1_tap.nim for why that is the only place a
# measurement can stand when the client is a binary this repository does not
# compile.
#
# RE-RUNNABLE BY SOMEBODY ELSE. Everything the run needs is either resolved
# here or reported as missing with the remedy:
#   * `runquotad` is built, in the mode the run is published under.
#   * `repro` is located (REPRO_BIN, or ../reprobuild/build/bin/repro) and its
#     build mode is DETECTED rather than assumed -- see reproBuildMode below.
#   * the wide-build subject lives in ../reprobuild-examples and is generated
#     by that example's own script if its sources are missing.
#
set -euo pipefail

subject="${1:-all}"
shift || true

invocations="${RUNQUOTA_M1_INVOCATIONS:-5}"
extra_args=()
for arg in "$@"; do
  case "${arg}" in
    --quick) invocations=2 ;;
    --invocations=*) invocations="${arg#--invocations=}" ;;
    *) extra_args+=("${arg}") ;;
  esac
done

mkdir -p bench-results build/bin build/nimcache test-logs

# RELEASE BY DEFAULT. A measurement is meaningless from a Nim debug build, and
# the arm this one will be weighed against -- nim-shm-lease's preemption study
# -- is -d:release throughout. See scripts/lib/build_mode.sh for why the
# default belongs to the caller and why a benchmark's default differs from the
# rest of the repository's.
# shellcheck source=scripts/lib/build_mode.sh
. "$(dirname "$0")/lib/build_mode.sh"
resolve_build_mode release
ensure_apps_built_in_mode "${RUNQUOTA_RESOLVED_BUILD_MODE}"

bench_bin="build/bin/runquota_m1_bench"
nim c \
  --threads:on \
  --hints:off \
  ${nim_mode_flags[@]+"${nim_mode_flags[@]}"} \
  --nimcache:"build/nimcache/runquota_m1_bench" \
  --out:"${bench_bin}" \
  benchmarks/lib/runquota_m1_bench.nim >/dev/null

repro_bin="${REPRO_BIN:-$(cd .. && pwd)/reprobuild/build/bin/repro}"
if [ ! -x "${repro_bin}" ]; then
  echo "M1 needs a built \`repro\`: set REPRO_BIN, or run \`just build\` in the" \
       "sibling reprobuild checkout. Looked at: ${repro_bin}" >&2
  exit 2
fi

# THE SUBJECT'S BUILD MODE IS PART OF THE RESULT, not a footnote. `repro` is
# the second binary in this measurement and its optimisation level moves the
# denominator of "cost as a fraction of build wall time" directly: a debug
# engine spends more wall time on everything that is not RunQuota, which makes
# RunQuota's share look smaller. reprobuild writes no mode stamp (runquota
# does), so the mode is read off the compile commands its nimcache manifest
# recorded -- `-d:release` makes Nim emit `-O3`, a debug build emits no -O flag
# at all. When the manifest is absent the answer is "unknown" and says so
# rather than guessing.
repro_mode="${REPRO_BUILD_MODE:-}"
if [ -z "${repro_mode}" ]; then
  manifest="$(dirname "${repro_bin}")/../nimcache/repro/repro.json"
  if [ -f "${manifest}" ]; then
    if grep -q -- '-O3' "${manifest}"; then
      repro_mode="release"
    else
      repro_mode="debug"
    fi
  else
    repro_mode="unknown"
  fi
fi

examples_root="${REPROBUILD_EXAMPLES:-$(cd .. && pwd)/reprobuild-examples}"
reprobuild_root="${REPROBUILD_SRC:-$(cd .. && pwd)/reprobuild}"
wide_dir="${examples_root}/c-cpp-make/wide-binary"

# THE SUBJECT NEEDS ITS OWN ENVIRONMENT, NOT THIS ONE. The harness is compiled
# with runquota's toolchain but it SPAWNS `repro`, and `repro` needs
# reprobuild's dev shell (its C toolchain, its provider search paths). Run
# under runquota's direnv instead and the builds fail in ~100 ms with a
# non-zero exit -- which the harness now reports loudly rather than publishing
# as a build that made no IPC.
#
# So the harness is EXECUTED under reprobuild's environment. `direnv exec DIR`
# keeps the working directory, so the relative paths below still resolve
# against the runquota checkout.
bench_exec=("${bench_bin}")
if command -v direnv >/dev/null 2>&1 && [ -f "${reprobuild_root}/.envrc" ]; then
  bench_exec=(direnv exec "${reprobuild_root}" "${bench_bin}")
else
  echo "note: direnv or ${reprobuild_root}/.envrc not found; running the" \
       "harness with the ambient environment. If the subject builds fail," \
       "this is the first thing to check." >&2
fi

run_subject() {
  local name="$1"; shift
  local dir="$1"; shift
  local out="bench-results/runquota-m1-${name}.json"
  local daemon_extra=()
  local timeout_arg=()
  if [ -n "${M1_SUBJECT_TIMEOUT:-}" ]; then
    timeout_arg=(--subject-timeout-ms="${M1_SUBJECT_TIMEOUT}")
  fi
  if [ "${M1_CAPTURE:-on}" = "off" ]; then
    daemon_extra=(--daemon-arg=--no-write-stats)
  fi
  echo "M1: ${name} (${invocations} invocations, runquota=${RUNQUOTA_RESOLVED_BUILD_MODE}," \
       "repro=${repro_mode})" >&2
  local args=()
  for a in "$@"; do args+=("--subject-arg=${a}"); done
  "${bench_exec[@]}" \
    --mode=study \
    --daemon=build/bin/runquotad \
    --repro="${repro_bin}" \
    --repro-mode="${repro_mode}" \
    --subject-name="${name}" \
    --subject-dir="${dir}" \
    "${args[@]}" \
    --invocations="${invocations}" \
    --control \
    ${daemon_extra[@]+"${daemon_extra[@]}"} \
    ${timeout_arg[@]+"${timeout_arg[@]}"} \
    --dump-events="bench-results/runquota-m1-${name}-events.csv" \
    --out="${out}" \
    ${extra_args[@]+"${extra_args[@]}"}
  echo "  -> ${out}" >&2
}

case "${subject}" in
  calibrate)
    "${bench_exec[@]}" --mode=calibrate --out=bench-results/runquota-m1-calibration.json
    cat bench-results/runquota-m1-calibration.json
    ;;
  tap-overhead)
    # THE CONTROL THAT MAKES EVERY TAPPED FIGURE READABLE. Identical lease
    # traffic, driven straight at the daemon and through the relay.
    "${bench_exec[@]}" --mode=tap-overhead \
      --daemon=build/bin/runquotad \
      --out=bench-results/runquota-m1-tap-overhead.json
    cat bench-results/runquota-m1-tap-overhead.json
    ;;
  client-cost)
    # GATE FIGURE 3's client half, measured exactly rather than differenced out
    # of a build's noise: syscalls per round trip, kernel-counted, against the
    # real daemon over the real socket, using the same client library `repro`
    # links.
    "${bench_exec[@]}" --mode=client-cost \
      --daemon=build/bin/runquotad \
      --out=bench-results/runquota-m1-client-cost.json
    cat bench-results/runquota-m1-client-cost.json
    ;;
  wide-build)
    if [ ! -f "${wide_dir}/src/main.c" ]; then
      echo "generating wide-build sources" >&2
      python3 "${wide_dir}/generate-sources.py"
    fi
    run_subject wide-build "${wide_dir}" \
      build --tool-provisioning=path --force-rebuild --log=summary
    ;;
  wide-build-capture-off)
    # THE ONE-FLAG CONTROL, on the daemon rather than the client:
    # `--no-write-stats` turns off the observation store, its writer thread,
    # the ambient sampler and the self-report intake. Same build, same client,
    # same message sequence. Whatever moves between this and `wide-build` is
    # the store, and whatever does not is the socket.
    M1_CAPTURE=off run_subject wide-build-capture-off "${wide_dir}" \
      build --tool-provisioning=path --force-rebuild --log=summary
    ;;
  test-run)
    # A BOUNDED WINDOW, AND THE RESULT SAYS SO. reprobuild's own suite declares
    # 2785 actions and runs for hours; a paired five-invocation study of it is
    # measured in days. A truncated window still yields real admission and
    # completion latencies from a real PARALLEL TEST RUN -- a workload whose
    # action shape is nothing like a compile fan-out -- and it explicitly
    # cannot yield gate figure 4, which needs a whole build's wall time. The
    # emitted record carries `truncated: true` on every such invocation.
    M1_SUBJECT_TIMEOUT="${M1_SUBJECT_TIMEOUT:-900000}" \
    run_subject test-run "${reprobuild_root}" \
      test --tool-provisioning=path --log=summary
    ;;
  all)
    "$0" calibrate
    "$0" tap-overhead
    "$0" client-cost
    "$0" wide-build "$@"
    "$0" wide-build-capture-off "$@"
    "$0" test-run "$@"
    ;;
  *)
    echo "usage: $0 calibrate|tap-overhead|client-cost|wide-build|wide-build-capture-off|test-run|all [--quick] [--invocations=N]" >&2
    exit 2
    ;;
esac
