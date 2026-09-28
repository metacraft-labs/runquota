# Reprobuild does not provision RunQuota's shared-memory source dependency

Status: open. Recorded 2026-09-28.

At RunQuota `437e6dac65ecf3a7b1e7753d09890f7b6cb14fe3`, [macOS job 109021658851](https://github.com/metacraft-labs/runquota/actions/runs/36449898510/job/109021658851) passes bootstrap but both app builds fail with `cannot open file: shm_lease/anchor`.

The Nix shell exports `SHM_LEASE_SRC`; the typed build actions have no declared producer, and `.github/sibling-repos` does not request `nim-shm-lease`. The comment claiming the ambient variable or sibling fallback is sufficient is contradicted by this clean CI build.

[Cross-Repo-Source-Consumption](../../reprobuild-specs/Cross-Repo-Source-Consumption.md), section 4.2a, requires source library dependencies to expose their import root through the producer interface and `nimPathDirs`. Declare and provision that dependency so the engine can identify its source. Preserve both shipping app builds and the complete test suite.

Fetched `origin/dev` at `f4f0f93`, confirmed it is already an ancestor of this branch, and searched current and deleted issues before recording.
