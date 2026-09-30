# POSIX CI overrides the recipe's Nix tool provisioning

| | |
| --- | --- |
| Status | open |
| Recorded | 2026-09-29 |
| Observed in | RunQuota `0622770` |
| Area | `.github/workflows/ci-reprobuild.yml` |

## Observed

macOS ARM64 job `109139768298` builds the applications but cannot resolve the
test tool graph: `tool-resolution failed: no zip extractor available (looked
for unzip + powershell)`. The shared `dev-exec` wrapper adds
`--tool-provisioning=path` when no explicit option is supplied. Reprobuild's
path resolver falls back to a declared archive when a tool is absent from the
host PATH. That fallback requires an extractor absent from this worker.
The log does not identify which tool selected the archive.

## Expected

The package's `defaultToolProvisioning` contract in `repro.nim` selects Nix
on Linux/macOS. The [release plan](../../metacraft-specs/infrastructure/gosti-io-mon-runquota-releases.md)
requires normal CI and declared compiler/runtime tools before publication.
Pass an explicit Nix provisioning option to POSIX Reprobuild build/test CI
commands so the wrapper preserves it. Keep the existing Windows PATH mode.
Do not rely on an unrelated host's preinstalled archive extractor.

## Evidence

[macOS job](https://github.com/metacraft-labs/runquota/actions/runs/36484461518/job/109139768298)
at `0622770`; `/tmp/runquota-062-mac-repro.log` includes the wrapper body and
failure. The complete graph passed locally at `40e7ed4` with explicit Nix
provisioning and the repaired monitor shim.
Refreshed dev `f4f0f93`; searched open and deleted issues for ZIP extractors
and PATH provisioning. No existing issue covers this CI override.
