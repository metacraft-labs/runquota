# Second-uid test uses a macOS-only temporary directory on Linux

| | |
|---|---|
| Status | open |
| Recorded | 2026-09-28 |
| Observed in | runquota @ `906800c` |
| Area | `tests/integration/t_shared_endpoint_second_uid.nim` |

## Observed

The preflight assigns `toolDir = "/private/tmp" / ...` on all POSIX hosts. On Linux it fails with `Read-only file system`, `Additional info: /private/`. The later cross-user checks cannot run because the probe was never built.

## Expected

[RunQuota Observation Store, scope boundaries](https://github.com/metacraft-labs/reprobuild-specs/blob/latest/RunQuota-Observation-Store.md) requires a real kernel-enforced group boundary. The fixture must use a host-appropriate directory that a second uid can traverse, then execute both permitted and refused cases. Preserve the permission checks and assertions.

## Evidence

[Linux test job at 906800c](https://github.com/metacraft-labs/runquota/actions/runs/36377535682/job/108786338190).
The suite ran 93 tests: 87 passed, six failed, no skips or timeouts.
These are normal-suite findings; the release payload checks passed separately.

Refreshed `origin/dev` (`f4f0f93`) and `origin/agents` (`906800c`). Searched
open issues, issue history and RunQuota milestone records before recording.
