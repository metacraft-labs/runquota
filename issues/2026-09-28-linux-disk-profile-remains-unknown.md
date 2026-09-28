# Linux host profile detection returns an unknown disk class

| | |
|---|---|
| Status | open |
| Recorded | 2026-09-28 |
| Observed in | runquota @ `906800c` |
| Area | `detectHardwareProfile; host-profile tests` |

## Observed

Two tests fail because `diskClass` is `unknown`: `t_observation_store_host_profile` and `t_observation_store_degraded_capture_build`. The Linux runner is `high-mem-server-mcl-002`; the detector did not identify its backing storage class. The precise mount/device discovery failure has not been isolated.

## Expected

[RunQuota Observation Store, host profiles](https://github.com/metacraft-labs/reprobuild-specs/blob/latest/RunQuota-Observation-Store.md) lists the disk class as a host-profile dimension. The existing tests require real detection. Investigate the actual backing mount/device chain before choosing a fallback or changing that expectation.

## Evidence

[Linux test job at 906800c](https://github.com/metacraft-labs/runquota/actions/runs/36377535682/job/108786338190).
The suite ran 93 tests: 87 passed, six failed, no skips or timeouts.
These are normal-suite findings; the release payload checks passed separately.

Refreshed `origin/dev` (`f4f0f93`) and `origin/agents` (`906800c`). Searched
open issues, issue history and RunQuota milestone records before recording.
