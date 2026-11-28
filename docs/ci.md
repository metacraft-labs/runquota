# What CI Runs

Every `Justfile` recipe is listed below once, with where CI runs it or why CI
does not. `scripts/check_recipe_schedule.sh` (part of `just lint`) holds this
table to the `Justfile` and to `.github/workflows/`: a recipe without a row, a
`ci` row whose workflow does not call the recipe, or a recipe CI does not run
with no reason given fails the lint. So a new test recipe has to be scheduled,
or documented here as manual with its reason, in the same change that adds it.

Classes:

- **ci**: a workflow in "Runs in" calls `just <recipe>`, or the command in
  "Signature" when the workflow calls the recipe's script directly.
- **within**: the recipe's command is part of the recipe in "Runs in", and CI
  runs that recipe.
- **alias**: another name for the recipe in "Runs in".
- **tool**: a developer command that asserts nothing, such as a build or a
  formatter.
- **bench**: a measurement that writes a report and has no pass or fail.
- **manual**: a gate that CI does not run. A recipe may stay manual only when
  it needs something CI does not have, and the reason must be recorded here.

<!-- recipe-schedule:begin -->
| Recipe | Class | Runs in | Signature | Notes |
|---|---|---|---|---|
| `default` | alias | `lint` | | |
| `build` | ci | `ci-reprobuild.yml` | | Cross-check of `repro build`, on every platform of that workflow. |
| `test` | ci | `ci.yml` | | Linux x64, Linux ARM64 and macOS ARM64; `ci-reprobuild.yml` runs it too. |
| `t` | alias | `test` | | |
| `test-release` | ci | `ci.yml` | | The suite compiled with `-d:release`, job `test-release`, on Linux x64 and Linux ARM64. A memory-ordering defect does not show at `-O0`, and ARM64 is the weakly ordered host. Runs in addition to `just test`. |
| `lint` | ci | `ci.yml` | | |
| `format` | tool | | | Rewrites sources. `just lint` checks the formatting. |
| `fmt` | alias | `format` | | |
| `bump-version` | tool | | | Edits the version for a release. |
| `build-package` | ci | `ci.yml` | | Job `packages`: `tarball`, `deb`, `rpm`, `arch` and `nix` on Linux x64, with the Reprobuild CLI that `pins/reprobuild.json` in metacraft-github-actions names. Job `packages-windows`: `msi` and `scoop` on Windows x64, which WiX needs. |
| `verify-package` | ci | `ci.yml` | | Jobs `packages` and `packages-windows`, over each artifact `build-package` produced. |
| `bench` | bench | | | Writes `bench-results/benchmark_results.json`. |
| `bench-quick` | bench | | | `just bench --quick`. |
| `bench-runquota-process-execution` | bench | | | Writes a JSON report. |
| `bench-overhead-gate` | manual | | | A pass/fail gate (exit 0 pass, 1 fail, 3 inconclusive), but it needs a quiet host: it resolves a ±0.5 % confidence interval on wall and CPU time, and a shared CI runner's noise makes that inconclusive rather than a result. Its default case also needs a Reprobuild engine built against this checkout, which no CI job builds. Its instrument is tested in the suite (`tests/integration/t_overhead_gate_detects_overhead.nim`). Run it by hand before changing what a measurement costs. |
| `bench-runquota-ipc` | bench | | | Writes a JSON report. |
| `bench-observation-write-path` | bench | | | Writes a JSON report. |
| `bench-socket-baseline` | bench | | | Writes a JSON report; needs a built sibling `reprobuild` checkout. |
| `repomix` | tool | | | Writes a source snapshot. |
| `check-repo-requirements` | within | `lint` | `bash scripts/check_repo_requirements.sh` | |
| `check-static-helpers` | within | `test` | `bash scripts/static_helper_gate.sh` | |
| `test-dev-shell` | ci | `ci.yml` | | Job `test`, on every leg. The test enters `nix develop` itself, from a scratch repository and from a copy of this one. |
| `dev-docs` | tool | | | Serves the documentation site locally. |
| `build-docs` | tool | | | Builds the documentation site; `docs-pages.yml` builds and deploys it. |
| `serve-docs` | tool | | | Serves the documentation site locally. |
| `open-docs` | tool | | | Opens the documentation site. |
| `test-ci-engine-lock` | ci | `ci-reprobuild.yml` | `python3 tests/test_ci_engine_reads_committed_lock.py` | Linux legs, against the engine the workflow installed. |
<!-- recipe-schedule:end -->
