# Ambient attribution test workload does not exceed its declared CPU share

| | |
|---|---|
| Status | open |
| Recorded | 2026-09-28 |
| Observed in | runquota @ `906800c` |
| Area | `tests/integration/t_ambient_load_attribution.nim` |

## Observed

The case `self is what admitted executions reported, foreign is the rest` fails `ownCpuPct([reporting]) > declaredCpu`: measured `8.274709565380903`, declared `10.0`. Its other CPU and memory measurement cases pass in this run. This observation alone does not distinguish a load-sensitive fixture from an accounting defect.

## Expected

[RunQuota Observation Store, ambient load attribution](https://github.com/metacraft-labs/reprobuild-specs/blob/latest/RunQuota-Observation-Store.md) distinguishes actual self usage from requested capacity. Isolate the reporting and load generation, retain a positive control proving actual usage exceeds its declaration, and keep the attribution assertions.

## Evidence

[Linux test job at 906800c](https://github.com/metacraft-labs/runquota/actions/runs/36377535682/job/108786338190).
The suite ran 93 tests: 87 passed, six failed, no skips or timeouts.
These are normal-suite findings; the release payload checks passed separately.

Refreshed `origin/dev` (`f4f0f93`) and `origin/agents` (`906800c`). Searched
open issues, issue history and RunQuota milestone records before recording.
