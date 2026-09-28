# Foreign-owner refusal test selects a symlink instead of a regular file

| | |
|---|---|
| Status | open |
| Recorded | 2026-09-28 |
| Observed in | runquota @ `906800c` |
| Area | `tests/unit/t_scope_boundary_rules.nim` |

## Observed

The foreign-owner case selects `/bin/sh`, which is a symlink on this Linux runner. `segmentTrust` correctly refuses its type first: actual `trustWrongType`, expected `trustForeignOwner`; the diagnostic says `mode 0777 is not a regular file`. The test never exercises the owner refusal it names.

## Expected

[RunQuota Shared Memory Transport, trust and privilege boundary](https://github.com/metacraft-labs/reprobuild-specs/blob/latest/RunQuota-Shared-Memory-Transport.md) requires both type and ownership checks. Select a real foreign-owned regular file for the owner test; do not relax the production symlink refusal.

## Evidence

[Linux test job at 906800c](https://github.com/metacraft-labs/runquota/actions/runs/36377535682/job/108786338190).
The suite ran 93 tests: 87 passed, six failed, no skips or timeouts.
These are normal-suite findings; the release payload checks passed separately.

Refreshed `origin/dev` (`f4f0f93`) and `origin/agents` (`906800c`). Searched
open issues, issue history and RunQuota milestone records before recording.
