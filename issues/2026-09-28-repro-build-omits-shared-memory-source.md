# Reprobuild does not provision RunQuota's shared-memory source dependency

Status: open. Recorded 2026-09-28.

At RunQuota `437e6dac65ecf3a7b1e7753d09890f7b6cb14fe3`, [macOS job 109021658851](https://github.com/metacraft-labs/runquota/actions/runs/36449898510/job/109021658851) passes bootstrap but both app builds fail with `cannot open file: shm_lease/anchor`.

The Nix shell exports `SHM_LEASE_SRC`; the typed build actions have no declared producer, and `.github/sibling-repos` does not request `nim-shm-lease`. The comment claiming the ambient variable or sibling fallback is sufficient is contradicted by this clean CI build.

[Cross-Repo-Source-Consumption](../../reprobuild-specs/Cross-Repo-Source-Consumption.md), section 4.2a, requires source library dependencies to expose their import root through the producer interface and `nimPathDirs`. Declare and provision that dependency so the engine can identify its source. Preserve both shipping app builds and the complete test suite.

Fetched `origin/dev` at `f4f0f93`, confirmed it is already an ancestor of this branch, and searched current and deleted issues before recording.

The producer interface at `nim-shm-lease@665e128` is merged, and RunQuota
`d7e7833` builds both shipping applications through the actual Reprobuild graph
on macOS. Clean CI at `3170fba` then exposes a provisioning prerequisite:
RunQuota has neither a committed `repro.lock` nor a carried workspace lock for
`dev@f4f0f93`. The new bare `nim-shm-queue` sibling consequently cannot resolve
a revision. Pin it to the clean, published and locally validated
`02f442ac12ce2587d9c053c527041097af38609f` for this release, matching the explicit
immutable producer pin, and retain full consumer validation.

## Final application qualification (2026-10-01)

Both application builds complete with the declared shared-memory source dependency.

These results are measured at `d6ee4588f71604376a4cc41ef281d6c479395efc`
in [run 36823482913](https://github.com/metacraft-labs/runquota/actions/runs/36823482913).
All application test programs pass on the five development hosts. The ARM
workflow still fails its subsequent, separate static-helper ACL gate; that
issue remains open and is not attributed to this repaired defect.
Ordinary [CI at `2d07c5d`](https://github.com/metacraft-labs/runquota/actions/runs/36846644651)
passes all ten jobs with unchanged application sources and fixtures.
