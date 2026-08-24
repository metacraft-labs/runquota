set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

REPOMIX_OUT_DIR := env('REPOMIX_OUT_DIR', 'repomix')

default:
    just lint

build:
    mkdir -p test-logs
    bash scripts/build_apps.sh 2>&1 | tee test-logs/build.log

# Both steps always run; the recipe exits non-zero if either failed. Without
# the `|| rc=$?` the failing test suite would abort before the static helper
# gate was ever invoked, hiding that check behind an unrelated failure.
test:
    mkdir -p test-logs
    rc=0; \
    bash scripts/run_tests.sh 2>&1 | tee test-logs/test.log || rc=$?; \
    runquota-static-helper-gate 2>&1 | tee -a test-logs/test.log || rc=$?; \
    exit $rc

t: test

# THE SAME SUITE, COMPILED OPTIMISED. Not a nicety: a memory-ordering defect
# is invisible at -O0, so a clause about release/acquire fences that only ever
# ran under `just test` has asserted nothing. `RUNQUOTA_BUILD_MODE` is the
# variable `scripts/build_apps.sh` already reads; `scripts/run_tests.sh` now
# reads it too, and the tests that compile a fixture binary of their own pass
# `-d:release` down to that inner compile when they were themselves built with
# it. Slower than `just test` and meant to be run in addition to it, not
# instead of it.
test-release:
    mkdir -p test-logs
    rc=0; \
    RUNQUOTA_BUILD_MODE=release bash scripts/run_tests.sh 2>&1 | tee test-logs/test-release.log || rc=$?; \
    runquota-static-helper-gate 2>&1 | tee -a test-logs/test-release.log || rc=$?; \
    exit $rc

lint:
    mkdir -p test-logs
    bash scripts/check_repo_requirements.sh 2>&1 | tee test-logs/lint.log
    bash scripts/check_nim_sources.sh 2>&1 | tee -a test-logs/lint.log

format:
    bash scripts/format_sources.sh

fmt: format

bump-version version:
    bash scripts/bump_version.sh {{version}}

bench *args:
    mkdir -p bench-results test-logs
    bash scripts/collect-benchmark-metrics.sh {{args}} > bench-results/benchmark_results.json 2> >(tee test-logs/bench.log >&2)

bench-quick:
    just bench --quick

bench-runquota-process-execution *args:
    mkdir -p bench-results test-logs
    bash scripts/run-m5-benchmark.sh process {{args}} 2> >(tee test-logs/bench-runquota-process-execution.log >&2)

bench-runquota-ipc *args:
    mkdir -p bench-results test-logs
    bash scripts/run-m5-benchmark.sh ipc {{args}} 2> >(tee test-logs/bench-runquota-ipc.log >&2)

# M13: per-execution latency the SOCKET observation write path adds, against
# a `--no-write-stats` control. The fallback path's cost; the ring (M22)
# carries the default-on decision.
bench-observation-write-path *args:
    mkdir -p bench-results test-logs
    bash scripts/run-m13-benchmark.sh {{args}} 2> >(tee test-logs/bench-observation-write-path.log >&2)

repomix *args:
    mkdir -p {{REPOMIX_OUT_DIR}}
    repomix \
        . \
        --output {{REPOMIX_OUT_DIR}}/RunQuota.md \
        --style markdown \
        --header-text "RunQuota public repository" \
        --ignore "repomix/**,bench-results/**,build/**" \
        {{args}}

check-repo-requirements:
    bash scripts/check_repo_requirements.sh

check-static-helpers:
    runquota-static-helper-gate
