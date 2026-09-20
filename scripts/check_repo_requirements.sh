#!/usr/bin/env bash
set -euo pipefail

failures=0

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

require_file() {
  [ -f "$1" ] || fail "missing file $1"
}

require_dir() {
  [ -d "$1" ] || fail "missing directory $1"
}

require_symlink() {
  local path="$1"
  local target="$2"
  if [ ! -L "${path}" ]; then
    fail "missing symlink ${path}"
    return
  fi
  [ "$(readlink "${path}")" = "${target}" ] || fail "${path} must point to ${target}"
}

require_contains() {
  local path="$1"
  local text="$2"
  grep -Fq "${text}" "${path}" || fail "${path} must contain ${text}"
}

for path in README.md LICENSE flake.nix flake.lock .envrc .gitignore Justfile runquota.nimble config.nims AGENTS.md; do
  require_file "${path}"
done

for path in .github .github/workflows nix docs libs apps tests benchmarks scripts examples vendor; do
  require_dir "${path}"
done

require_symlink CLAUDE.md AGENTS.md
require_symlink .github/copilot-instructions.md ../AGENTS.md
require_file .github/workflows/ci.yml

require_contains .envrc "use flake"
require_contains flake.nix 'nixos-modules.url = "github:metacraft-labs/devops-modules"'
require_contains flake.nix 'nixpkgs.follows = "nixos-modules/nixpkgs-unstable"'
require_contains flake.nix 'flake-parts.follows = "nixos-modules/flake-parts"'
require_contains flake.nix 'git-hooks.follows = "nixos-modules/git-hooks-nix"'
for system in x86_64-linux aarch64-linux x86_64-darwin aarch64-darwin; do
  require_contains flake.nix "\"${system}\""
done
require_contains flake.nix "devShells.default"
require_contains flake.nix "packages.default"
require_contains flake.nix "checks ="
require_contains flake.nix "static-helpers"
require_contains flake.nix "git-hooks.lib"
require_contains flake.nix "shellHook = pre-commit-check.shellHook"

for recipe in build test lint format fmt t bump-version build-package verify-package bench bench-quick bench-runquota-process-execution bench-runquota-ipc repomix check-repo-requirements check-static-helpers; do
  just --summary | tr ' ' '\n' | grep -Fxq "${recipe}" || fail "missing Justfile recipe ${recipe}"
done

require_contains .github/workflows/ci.yml "run: nix develop --command just lint"
require_contains .github/workflows/ci.yml "run: nix develop --command just test"
require_contains .github/workflows/ci.yml "run: nix build .#default"
require_contains .github/workflows/ci.yml "if: always()"
require_contains .github/workflows/ci.yml "actions/upload-artifact@v4"

# THE WINDOWS GATE, PINNED HERE SO IT CANNOT BE QUIETLY DROPPED. Two
# Windows-only compile errors reached `dev` while every job in this workflow
# ran on Linux and macOS only, and both were found downstream rather than
# here. The requirements below are the load-bearing parts of the fix: the job
# exists, it runs on the Windows pool, it really invokes a shell rather than
# standing as a placeholder, its test manifest and its Linux-side counterpart
# are present, and the runner-label config that keeps actionlint able to
# check the Windows pool at all has not been removed with it.
#
# THE POOL IS NAMED BY CAPABILITY LABELS, NOT BY AN `eph-*` CLASS NAME. The
# single-name ephemeral classes (`eph-win-x64` and friends) were retired in
# favour of the `[self-hosted, <os>, <arch>]` arrays by 126ab5b, which
# rewrote every `runs-on:` in `.github/workflows/` and left this assertion
# pinning the old spelling -- so `just lint` has failed on its FIRST script,
# for everyone, ever since. Assert the spelling the workflows actually use.
require_contains .github/workflows/ci.yml "windows-compile-gate:"
require_contains .github/workflows/ci.yml "runs-on: [self-hosted, windows, x64]"
require_contains .github/workflows/ci.yml "shell: pwsh"
require_file tests/windows/portable_tests.txt
require_file tests/unit/t_windows_compile_gate.nim
require_file .github/actionlint.yaml

# NOTHING IN THIS REPOSITORY BOUNDED A HANGING TEST, and the shape is easy
# to lose again: the bound lives in two ordinary-looking lines of shell and
# one key per CI job. Both are pinned here so that dropping either fails the
# lint rather than surfacing as a six-hour job months later.
require_file scripts/run_tests.sh
require_contains scripts/run_tests.sh "RUNQUOTA_TEST_TIMEOUT"
require_contains scripts/run_tests.sh "kill-after="

# THE OTHER HALF OF THE SAME RULE: the runner refuses both of the two ways a
# run can report something that is not about this tree -- unbounded (a wedge
# nobody catches) and without `sqlite3` (three tests reddening on
# `store.captureEnabled` for a reason that is in the environment). Both
# refusals are overridable BY VALUE and never by inference, and both are
# pinned so that removing one fails the lint.
require_contains scripts/run_tests.sh "RUNQUOTA_ALLOW_MISSING_SQLITE"

# THE PACKAGING SURFACE, PINNED. The `Distribution` is the one source of
# truth every package format is produced from, and the two scripts below
# are what turn `just build-package` / `just verify-package` into
# something other than names in a Justfile. The contract test is what
# stops the packaging recipe -- which is compiled by `repro build` with
# none of `libs/` on its path, and so cannot import anything it asserts
# about -- from drifting away from the product it packages.
require_file packaging/repro.nim
require_file packaging/runquota_dist.nim
require_file scripts/stage_package_payload.sh
require_file scripts/build_package.sh
require_file scripts/verify_package.sh
require_file scripts/verify_windows_package.ps1
require_file scripts/check_windows_scrubbed_launch.ps1
require_file tests/unit/t_packaging_contract.nim
require_file .github/workflows/publish-windows.yml
require_file .github/workflows/publish-linux.yml

# EVERY JOB CARRIES ITS OWN CEILING. `runs-on:` appears exactly once per job,
# which is what makes this a per-job count rather than a grep for the key
# somewhere in the file: adding a job without `timeout-minutes` fails here.
# `grep -c` exits non-zero on no match, and this script runs under `set -e`.
ci_jobs="$(grep -cE '^    runs-on:' .github/workflows/ci.yml || true)"
ci_ceilings="$(grep -cE '^    timeout-minutes: [0-9]+$' .github/workflows/ci.yml || true)"
if [ "${ci_jobs}" -lt 4 ]; then
  fail "ci.yml yielded ${ci_jobs} jobs; refusing to pass on an empty sweep"
fi
if [ "${ci_ceilings}" -lt "${ci_jobs}" ]; then
  fail "ci.yml has ${ci_jobs} jobs but only ${ci_ceilings} timeout-minutes"
fi

# THE SAME CEILING RULE, APPLIED TO THE PUBLISH WORKFLOWS. The rule above
# predates them and named `ci.yml` literally, so the two workflows added
# for packaging were carrying their ceilings by the author's care rather
# than by anything that would notice their absence. A publish job that
# hung would hold one of this organisation's two Windows slots until the
# repository-wide 6h default expired -- which is the failure the ceiling
# exists to bound, and it is worse here than in `ci.yml` because a
# publish runs on a tag nobody is watching.
for wf in .github/workflows/publish-windows.yml .github/workflows/publish-linux.yml; do
  wf_jobs="$(grep -cE '^    runs-on:' "${wf}" || true)"
  wf_ceilings="$(grep -cE '^    timeout-minutes: [0-9]+$' "${wf}" || true)"
  if [ "${wf_jobs}" -lt 1 ]; then
    fail "${wf} yielded ${wf_jobs} jobs; refusing to pass on an empty sweep"
  fi
  if [ "${wf_ceilings}" -lt "${wf_jobs}" ]; then
    fail "${wf} has ${wf_jobs} jobs but only ${wf_ceilings} timeout-minutes"
  fi
done

for pattern in "repomix/" "bench-results/" "nimcache/" "result"; do
  require_contains .gitignore "${pattern}"
done

for forbidden in .github/sibling-pins .github/sibling-pins.json .github/rr-backend-pin.txt .repo-workspaces.env; do
  [ ! -e "${forbidden}" ] || fail "forbidden workspace pin file present: ${forbidden}"
done

while read -r lib _; do
  case "${lib}" in
    ""|\#*) continue ;;
  esac
  require_dir "libs/${lib}"
  require_file "libs/${lib}/${lib}.nimble"
  require_file "libs/${lib}/README.md"
  require_file "libs/${lib}/src/${lib}.nim"
done < libs/libraries.txt

while read -r lib _; do
  case "${lib}" in
    ""|\#*) continue ;;
  esac
  grep -Fxq "${lib}" libs/libraries.txt || fail "static helper ${lib} missing from libraries.txt"
done < libs/static_helpers.txt

while read -r name path _; do
  case "${name}" in
    ""|\#*) continue ;;
  esac
  require_dir "apps/${name}"
  require_file "${path}"
done < apps/entrypoints.txt

for path in tests/unit tests/integration tests/compatibility tests/fixtures tests/e2e benchmarks/suites benchmarks/lib benchmarks/fixtures benchmarks/reports; do
  require_dir "${path}"
done

for suite in basic-acquire multi-session-fairness crash-recovery platform-backends; do
  require_dir "tests/e2e/${suite}"
done

for suite in admission-throughput ipc-latency process-execution-throughput pressure-response; do
  require_dir "benchmarks/suites/${suite}"
done

if [ "${failures}" -ne 0 ]; then
  exit 1
fi

echo "runquota repository requirements passed"
