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
    find tests -type f -name 't*.nim' -print0
    find libs -path '*/tests/t*.nim' -type f -print0
  } | LC_ALL=C sort -z
)

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
seen_names=" "
failures=()
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
    skipped=$((skipped + 1))
    skips+=("${test_file} (duplicate test binary name '${test_name}')")
    continue
  fi
  seen_names="${seen_names}${test_name} "

  echo "=== compiling ${test_file}"
  # `|| status=$?` keeps `set -e` from aborting the run on a failing test while
  # still capturing the real exit status of the command itself.
  status=0
  nim c \
    --threads:on \
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
  "./build/test-bin/${test_name}" || status=$?
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
echo "  discovered: ${discovered}"
echo "  compiled:   ${compiled}"
echo "  ran:        ${ran}"
echo "  passed:     ${passed}"
echo "  failed:     ${failed}"
echo "  skipped:    ${skipped}"

if [ "${skipped}" -gt 0 ]; then
  echo
  echo "  skipped tests:"
  for skip in "${skips[@]}"; do
    echo "    - ${skip}"
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

if [ "${failed}" -gt 0 ]; then
  echo "${failed} of ${discovered} test(s) failed" >&2
  exit 1
fi

echo "all ${passed} test(s) passed"
