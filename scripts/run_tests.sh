#!/usr/bin/env bash
#
# Aggregating test runner.
#
# Every discovered test file is compiled and run, regardless of whether an
# earlier test failed to compile or failed at runtime. Results are collected and
# printed as a summary; the script exits non-zero if anything failed.
#
# The previous version ran `nim c -r` in a `set -e` loop, so the first failing
# binary aborted the whole run before the remaining binaries were even compiled.
# That silently hid most of the suite behind one known failure, and *which*
# tests were hidden depended on `find`'s traversal order.
#
# Two invariants keep that from coming back:
#   * discovery is sorted explicitly (LC_ALL=C, NUL-delimited), so the same set
#     runs in the same order on every host and under every shell, whatever
#     `find` implementation is on PATH;
#   * `set -e` stays enabled; only the compile and the run command carry
#     `|| status=$?`, so only *those two* are allowed to fail without aborting.
#     Every other command in this script still aborts on error as before.
#
set -euo pipefail

mkdir -p build/test-bin build/nimcache

# ---------------------------------------------------------------------------
# Build mode
# ---------------------------------------------------------------------------
#
# THE SUITE MUST BE ABLE TO COMPILE OPTIMISED, and until M13b it could not.
# A memory-ordering defect is INVISIBLE IN A DEBUG BUILD: removing the
# publisher's release fences or the reader's acquire fence leaves the suite
# green at -O0 and turns it red under `-d:release`, because the optimiser is
# what exposes the reordering the fences forbid. A runner with no build-mode
# plumbing therefore makes every ordering clause in the tree vacuous, however
# carefully those clauses are written.
#
# Same variable and same shape as `scripts/build_apps.sh`, deliberately: one
# convention for the whole repository rather than a second one here. The
# apps build below reads it too, so `RUNQUOTA_BUILD_MODE=release` gives an
# optimised tree end to end.
# shellcheck source=scripts/lib/build_mode.sh
. "$(dirname "$0")/lib/build_mode.sh"
resolve_build_mode debug
nim_flags=(--threads:on ${nim_mode_flags[@]+"${nim_mode_flags[@]}"})

# ---------------------------------------------------------------------------
# The per-binary bound
# ---------------------------------------------------------------------------
#
# A HANGING TEST USED TO HAVE NO BOUND AT ALL. The run line below was
# `"./build/test-bin/${test_name}" || status=$?` with nothing around it, and
# `.github/workflows/ci.yml` set no `timeout-minutes` on any job, so the only
# limit on a wedged binary was GitHub's six-hour job default -- and on a
# developer's machine, none at all.
#
# THAT IS NOT A THEORETICAL SHAPE IN THIS TREE. Three tests here HANG rather
# than fail under specific defects, and say so in their own headers: two cases
# in `t_observation_flush_contract` park on `writerSettled` if a drain stops
# announcing what it settled, and `t_shutdown_handler_lifecycle`'s "the
# handler's write cannot block" case sits down on a full pipe if the write end
# is blocking. One wedged `t_shutdown_handler_lifecycle` sat on a development
# host for an hour and a half with its binary already deleted, because after
# the run that started it had gone nothing was left that would ever reap it.
#
# THE BOUND, AND THE EVIDENCE FOR IT. Measured one test at a time on an
# otherwise quiet 24-core Linux host, debug build, wall clock around the
# binary alone -- not around its compile, and not inside a full-suite run,
# where these tests contend with each other and every figure is larger:
#
#     t_ambient_load_attribution                  124.5 s
#     t_standalone_daemonless_degradation          62.0 s
#     t_observation_extension_write_path           48.5 s
#     t_host_load_reading_invariants               31.4 s
#     t_observation_store_degraded_capture_build   24.8 s
#     t_m5_process_exec_bench_contract             16.8 s
#
# The slowest is wall-clock BY CONSTRUCTION -- it measures the ambient
# sampler over fixed windows -- and so are most of the others, which is why
# the tail is long rather than flat: SIX tests are over 15 s, and a bound
# derived from "everything else is quick" would be derived from something
# that is not true of this suite.
#
# The default below is 600 s: 4.8x the slowest and 9.7x the next, which
# leaves room for a slower CI runner, for the wall-clock tests' own margins,
# for a suite run in which they overlap, and for
# `RUNQUOTA_BUILD_MODE=release`, while catching a wedge in ten minutes
# rather than in six hours.
#
# RE-MEASURE BEFORE RE-TUNING. The numbers above are one host on one day and
# they are the whole of the derivation; anybody tightening this bound needs
# their own timings of the same six, taken the same way.
#
# `RUNQUOTA_TEST_TIMEOUT` overrides it, and `0` disables it. Disabling is
# spelled as a VALUE and never inferred from a missing tool: "the runner
# quietly ran unbounded because `timeout` was not installed" is precisely the
# state this section exists to end, so an absent `timeout(1)` is a refusal to
# run rather than a silent downgrade.
#
# THE PROCESS GROUP, NOT THE PROCESS. These tests spawn `sqlite3` children and
# real `runquotad` daemons, and killing only the parent would leave them
# behind. `timeout` without `--foreground` puts ITSELF and the test into a new
# process group whose id is its own pid, and signals that whole group -- which
# is why the run below is BACKGROUNDED rather than run in the foreground: `$!`
# is then the group id, so the sweep after a timeout can reach anything that
# outlived the signal.
#
# WHAT THE GROUP DOES NOT REACH, recorded rather than papered over: a
# descendant that called `setpgid(0, 0)` for ITSELF leaves the group and
# survives. `runquota_process` does exactly that for supervised client trees,
# where `createProcessGroup` defaults to true, so a timeout in a test that
# launches one can still leave that tree behind. Everything spawned through
# `osproc` -- `sqlite3`, `runquotad`, inner `nim` compiles -- stays in the
# group and is killed with it.

test_timeout="${RUNQUOTA_TEST_TIMEOUT:-600}"
test_kill_grace="${RUNQUOTA_TEST_KILL_GRACE:-10}"

case "${test_timeout}" in
  ""|*[!0-9]*)
    echo "RUNQUOTA_TEST_TIMEOUT must be whole seconds; 0 disables the bound" >&2
    exit 1
    ;;
esac
case "${test_kill_grace}" in
  ""|*[!0-9]*)
    echo "RUNQUOTA_TEST_KILL_GRACE must be whole seconds" >&2
    exit 1
    ;;
esac

timeout_bin=""
if command -v timeout >/dev/null 2>&1; then
  timeout_bin="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  # GNU coreutils under its Homebrew prefix, for a macOS shell that is not
  # the Nix one.
  timeout_bin="gtimeout"
fi

if [ "${test_timeout}" -eq 0 ]; then
  echo "=== per-test timeout DISABLED by RUNQUOTA_TEST_TIMEOUT=0" >&2
  timeout_bin=""
elif [ -z "${timeout_bin}" ]; then
  echo "no timeout(1) or gtimeout(1) on PATH" >&2
  echo "refusing to run the suite unbounded; install coreutils, or set" >&2
  echo "RUNQUOTA_TEST_TIMEOUT=0 to run without a bound on purpose" >&2
  exit 1
fi

if [ -z "${timeout_bin}" ]; then
  bound_label="unbounded"
else
  bound_label="${test_timeout}s"
fi

# ---------------------------------------------------------------------------
# The `sqlite3` prerequisite
# ---------------------------------------------------------------------------
#
# THE SAME FALSE-SIGNAL CLASS AS AN UNBOUNDED RUN, POINTING THE OTHER WAY.
# `openObservationStore` degrades to no capture when `sqlite3` is not on
# PATH, which is correct PRODUCT behaviour (OS-4) and is itself driven by
# `tests/unit/t_observation_store_degradation`'s "no sqlite3 on PATH" case,
# which empties PATH from INSIDE the test. It is not correct TEST-HOST
# behaviour: a suite run outside the nix devshell reddens
# `t_observation_flush_contract`, `t_ambient_sample_atomicity` and
# `t_hardware_run_tool_streams` on `store.captureEnabled`, with nothing in
# the output naming the cause. Three tests failing for a reason that is not
# in the tree is as misleading as a wedge nobody bounded, and it has already
# cost one review its first run.
#
# SO THE RUNNER REFUSES, the same way it refuses to run unbounded, and the
# override is again a VALUE rather than an inference:
# `RUNQUOTA_ALLOW_MISSING_SQLITE=1` runs anyway and says loudly which three
# results are not to be believed. Refusing costs nothing legitimate --
# no test in this suite needs `sqlite3` to be ABSENT from the runner's PATH,
# because the one that needs that arranges it for itself.
if ! command -v sqlite3 >/dev/null 2>&1; then
  if [ "${RUNQUOTA_ALLOW_MISSING_SQLITE:-0}" = "1" ]; then
    echo "==============================================================" >&2
    echo "WARNING: no sqlite3 on PATH; running anyway on your say-so." >&2
    echo "  These results are NOT a signal about this tree:" >&2
    echo "    - t_observation_flush_contract" >&2
    echo "    - t_ambient_sample_atomicity" >&2
    echo "    - t_hardware_run_tool_streams" >&2
    echo "  They assert store.captureEnabled, which is false without it." >&2
    echo "==============================================================" >&2
  else
    echo "no sqlite3 on PATH" >&2
    echo "the observation store degrades to no capture without it, so three" >&2
    echo "tests would fail for a reason that is not in this tree:" >&2
    echo "  t_observation_flush_contract, t_ambient_sample_atomicity," >&2
    echo "  t_hardware_run_tool_streams" >&2
    echo "run inside 'nix develop', or set RUNQUOTA_ALLOW_MISSING_SQLITE=1" >&2
    echo "to accept those three failures on purpose" >&2
    exit 1
  fi
fi

# Application binaries are a prerequisite for the tests (t_entrypoints and the
# e2e suites exec them), so a failure here is fatal rather than aggregated.
./scripts/build_apps.sh

# ---------------------------------------------------------------------------
# Discovery (deterministic)
# ---------------------------------------------------------------------------

test_files=()
while IFS= read -r -d '' test_file; do
  test_files+=("${test_file}")
done < <(
  {
    # `set -e` and `pipefail` cannot observe a process-substitution's exit
    # status, so a `find` that failed here would silently yield a SMALLER set
    # and the run would look clean. Fail loudly inside the substitution
    # instead: the marker is read back as a normal entry and rejected below.
    find tests -type f -name 't*.nim' -print0 || printf 'DISCOVERY_FAILED\0'
    find libs -path '*/tests/t*.nim' -type f -print0 || printf 'DISCOVERY_FAILED\0'
  } | LC_ALL=C sort -z
)

for entry in ${test_files[@]+"${test_files[@]}"}; do
  if [ "${entry}" = "DISCOVERY_FAILED" ]; then
    echo "test discovery failed: a find invocation returned non-zero" >&2
    echo "refusing to run a partial suite" >&2
    exit 1
  fi
done

discovered=${#test_files[@]}

if [ "${discovered}" -eq 0 ]; then
  echo "no Nim tests found" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Compile + run every discovered test
# ---------------------------------------------------------------------------

# Optional substring filter, e.g. RUNQUOTA_TEST_FILTER=partition just test.
# Non-matching tests are reported as skipped rather than silently dropped.
filter="${RUNQUOTA_TEST_FILTER:-}"

compiled=0
ran=0
passed=0
skipped=0
timed_out=0
seen_names=" "
failures=()
timeouts=()
skips=()

for test_file in "${test_files[@]}"; do
  test_name="$(basename "${test_file}" .nim)"

  if [ -n "${filter}" ] && [[ "${test_file}" != *"${filter}"* ]]; then
    skipped=$((skipped + 1))
    skips+=("${test_file} (filtered out by RUNQUOTA_TEST_FILTER=${filter})")
    continue
  fi

  # Two test files sharing a basename would overwrite each other's binary, so
  # the second one would never really run. Surface it instead of hiding it.
  if [[ "${seen_names}" == *" ${test_name} "* ]]; then
    # FATAL, not a skip. A skipped duplicate leaves the run GREEN with a test
    # that never executed -- the same shape as the abort this runner replaced,
    # just quieter. Counting it as a failure is what makes "exit 0" mean
    # "every discovered test ran and passed".
    failures+=("${test_name} (duplicate test binary name; would overwrite --out) [${test_file}]")
    continue
  fi
  seen_names="${seen_names}${test_name} "

  echo "=== compiling ${test_file}"
  # `|| status=$?` keeps `set -e` from aborting the run on a failing test while
  # still capturing the real exit status of the command itself.
  status=0
  nim c \
    "${nim_flags[@]}" \
    --nimcache:"build/nimcache/${test_name}" \
    --out:"build/test-bin/${test_name}" \
    "${test_file}" || status=$?
  if [ "${status}" -ne 0 ]; then
    echo "=== COMPILE FAILED (exit ${status}): ${test_file}" >&2
    failures+=("${test_name} (compile failed, exit ${status}) [${test_file}]")
    continue
  fi
  compiled=$((compiled + 1))

  echo "=== running ${test_name}"
  ran=$((ran + 1))
  status=0
  run_started=${SECONDS}
  # STDIN IS `/dev/null`, and that is part of the bound rather than tidiness.
  # `timeout` runs the test in a BACKGROUND process group, so a test that
  # read the terminal would take SIGTTIN and stop forever -- a second way to
  # wedge, introduced by the fix for the first. Nothing in this suite reads
  # stdin; closing it here makes that a property of the runner.
  if [ -z "${timeout_bin}" ]; then
    bounded_pgid=""
    "./build/test-bin/${test_name}" </dev/null || status=$?
  else
    "${timeout_bin}" --kill-after="${test_kill_grace}" "${test_timeout}" \
      "./build/test-bin/${test_name}" </dev/null &
    bounded_pgid=$!
    wait "${bounded_pgid}" || status=$?
  fi
  run_elapsed=$((SECONDS - run_started))

  # A TIMEOUT IS ITS OWN OUTCOME AND NOT AN ORDINARY FAILURE. `timeout` exits
  # 124 when its own SIGTERM ended the command and 137 when the
  # `--kill-after` SIGKILL had to. The elapsed time is required as well,
  # which is what keeps a fast test that happens to exit 124 -- or one the
  # OOM killer SIGKILLs early -- reported as the failure it is.
  #
  # THE CONJUNCTION NARROWS THE WINDOW AND DOES NOT CLOSE IT, and saying
  # otherwise would be the same false confidence this section exists to
  # remove. A test that runs LONGER than the bound and then exits 124 on its
  # own account is indistinguishable here from one `timeout` killed, and is
  # misreported as a wedge. Nothing in this suite exits 124 deliberately
  # today; if something ever does, this discrimination needs a signal that
  # does not travel in the exit status -- `timeout --verbose`'s message on
  # stderr, or a sentinel the test writes before it exits.
  if [ -n "${bounded_pgid}" ] &&
     [ "${run_elapsed}" -ge "${test_timeout}" ] &&
     { [ "${status}" -eq 124 ] || [ "${status}" -eq 137 ]; }; then
    # THE GROUP, AFTER THE FACT. `timeout` has already signalled it; this
    # reaps whatever joined late or outlived the grace, so the rest of the
    # suite does not run against it and the host is not left with an orphan.
    kill -KILL -- "-${bounded_pgid}" 2>/dev/null || true
    echo "=== TEST TIMED OUT after ${test_timeout}s, process group killed: ${test_file}" >&2
    timed_out=$((timed_out + 1))
    timeouts+=("${test_name} (TIMED OUT after ${test_timeout}s; process group killed) [${test_file}]")
    continue
  fi

  if [ "${status}" -ne 0 ]; then
    echo "=== TEST FAILED (exit ${status}): ${test_file}" >&2
    failures+=("${test_name} (exit ${status}) [${test_file}]")
    continue
  fi
  passed=$((passed + 1))
done

failed=${#failures[@]}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo
echo "==================== test summary ===================="
# THE MODE IS PART OF THE RESULT. "This suite passed" says nothing about an
# ordering property unless the build it passed in is on the record beside it.
echo "  build mode: ${RUNQUOTA_BUILD_MODE:-${REPROBUILD_BUILD_MODE:-debug}} (nim ${nim_flags[*]})"
echo "  discovered: ${discovered}"
echo "  compiled:   ${compiled}"
echo "  ran:        ${ran}"
echo "  passed:     ${passed}"
echo "  failed:     ${failed}"
# ON ITS OWN LINE, ALWAYS PRINTED. A wedged test merged into `failed` is a
# wedge nobody reads as one, and the number that matters to whoever is
# looking at a slow run is how many binaries had to be killed.
echo "  timed out:  ${timed_out} (per-test bound ${bound_label})"
echo "  skipped:    ${skipped}"

if [ "${skipped}" -gt 0 ]; then
  echo
  echo "  skipped tests:"
  for skip in "${skips[@]}"; do
    echo "    - ${skip}"
  done
fi

if [ "${timed_out}" -gt 0 ]; then
  echo
  echo "  TIMED OUT (killed, process group and all):"
  for timeout_entry in "${timeouts[@]}"; do
    echo "    - ${timeout_entry}"
  done
fi

if [ "${failed}" -gt 0 ]; then
  echo
  echo "  failed tests:"
  for failure in "${failures[@]}"; do
    echo "    - ${failure}"
  done
fi
echo "======================================================"

if [ "${timed_out}" -gt 0 ]; then
  echo "${timed_out} test(s) TIMED OUT after ${test_timeout}s and were killed" >&2
fi
if [ "${failed}" -gt 0 ]; then
  echo "${failed} of ${discovered} test(s) failed" >&2
fi
if [ $((failed + timed_out)) -gt 0 ]; then
  exit 1
fi

echo "all ${passed} test(s) passed"
