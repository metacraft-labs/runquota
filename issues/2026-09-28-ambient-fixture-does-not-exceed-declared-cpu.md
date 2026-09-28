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

## Repair and Linux follow-up at 1cc64a3

The adaptive thread count can select two spinners on a 32-core host, whose
maximum CPU share is only 6.25%, below the declared 10%. Wait for the same
headroom required by the measurement arm, then give the attribution arm enough
threads for twice its declaration. Keep the measured `getrusage` positive
control; thread count alone does not prove CPU was consumed.

[The native Linux diagnostic at 1cc64a3](https://github.com/metacraft-labs/runquota/actions/runs/36430831818/job/108956273767)
passes CPU attribution and both synthetic-load controls. It exposes another
fixture assumption: the reporting arm declares 4.5 GB and requires a positive
foreign residual even on a host using less memory. The specification requires
zero in that situation. Assert the exact clamped difference using the host's
total and each recorded available-memory sample. Retain the preceding real
memory-load positive control and the later runaway/release controls.
