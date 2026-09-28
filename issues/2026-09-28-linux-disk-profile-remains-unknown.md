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

## Diagnostic and repair at 28d1fbb plus working changes

The same failure also occurs on clean Ubuntu 24.04. `findmnt` identifies
`/tmp` and the checkout as ext4 on `/dev/nvme0n1p1`, major:minor `259:1`.
The diagnostic did not yet record raw mountinfo inside the Nix environment,
so the precise old source spelling remains unconfirmed.

The detector currently guesses a `/sys/block` name from the mount source.
This fails for `/dev/root`, UUID aliases and numeric device names such as
`mmcblk0p1`. Resolve the mount's kernel major:minor through `/sys/dev/block`,
follow partition parents, and read the actual queue's rotational flag.
Tests cover aliases, escaped mount points, NVMe, MMC and HDD sysfs layouts.

Mounts without a visible block device (including ZFS, tmpfs and overlay)
must retain the specified `unknown` answer. The native detection test still
requires classification when a sysfs block device exists. The persistence
test requires the daemon to store the detector's actual answer. CPU, RAM,
filesystem identity and the positive storage fixture checks remain required.

The Linux diagnostic at `28d1fbb` passes the repaired ownership, distinct
mapping and real flush synchronization checks. Its CPU accounting invariant
also passes: total capacity per core is 0.9982–1.0007 of elapsed time, and a
saturated host never reports more than full capacity. The new storage repair
and shared-UID namespace setup still need a native rerun.
