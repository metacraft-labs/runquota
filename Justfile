set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

REPOMIX_OUT_DIR := env('REPOMIX_OUT_DIR', 'repomix')

default:
    just lint

build:
    mkdir -p test-logs
    bash scripts/build_apps.sh 2>&1 | tee test-logs/build.log

test:
    mkdir -p test-logs
    bash scripts/run_tests.sh 2>&1 | tee test-logs/test.log
    bash scripts/check_static_helpers.sh 2>&1 | tee -a test-logs/test.log

t: test

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
    bash scripts/check_static_helpers.sh
