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

# ONE DISTRIBUTION CHANNEL'S ARTIFACT, for this host. The channel
# vocabulary is msi / scoop / deb / rpm / arch / tarball / nix and is
# recorded in `codetracer-specs/runbooks/packaging/runquota.md` §3.
#
# A channel this host cannot produce is a REFUSAL and never a skip: the
# MSI producer's tools are Windows-native PE executables and the Linux
# producers stage through patchelf and an ELF closure walk, so
# `build-package msi` on a Linux runner must stop rather than report
# success having produced no installer.
build-package channel:
    mkdir -p test-logs
    bash scripts/build_package.sh {{channel}} 2>&1 | tee test-logs/build-package-{{channel}}.log

# The same artifact, read back OVER THE SHIPPED BYTES -- the MSI's own
# tables through WindowsInstaller, the archive's own member list, the
# .deb's own control fields. Never the intermediate files the producer
# generated: a check over those could only establish that the renderer
# agrees with itself.
verify-package channel:
    mkdir -p test-logs
    bash scripts/verify_package.sh {{channel}} 2>&1 | tee test-logs/verify-package-{{channel}}.log

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

# M1: the socket baseline -- what RunQuota's socket costs a REAL `repro`
# build and a REAL parallel test run, broken down into admission versus
# reporting. THE ONLY BENCHMARK HERE WHOSE CLIENT IS NOT SYNTHETIC: the M5
# `ipc` and M13 write-path suites drive a real daemon from a tight loop, which
# is the right shape for what they measure and the wrong shape for this. It
# needs a built sibling `reprobuild` checkout and runs its subjects under that
# checkout's dev shell.
#
#   just bench-socket-baseline calibrate      instrument check only, seconds
#   just bench-socket-baseline tap-overhead   the relay's own cost
#   just bench-socket-baseline client-cost    syscalls per round trip
#   just bench-socket-baseline wide-build     65 parallel compile actions
#   just bench-socket-baseline wide-build-capture-off   the same, store off
#   just bench-socket-baseline test-run       reprobuild's own test suite
#   just bench-socket-baseline all            everything above
bench-socket-baseline *args:
    mkdir -p bench-results test-logs
    bash scripts/run-m1-benchmark.sh {{args}} 2> >(tee test-logs/bench-socket-baseline.log >&2)

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
