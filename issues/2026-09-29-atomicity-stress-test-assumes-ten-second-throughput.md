# Atomicity stress test assumes a fixed ten-second step throughput

| | |
| --- | --- |
| Status | open |
| Recorded | 2026-09-29 |
| Observed in | RunQuota `0622770` |
| Area | `t_ambient_sample_atomicity.nim` |

## Observed

Linux ARM64 Reprobuild job `109139768209` finishes the complete 194-action
graph with one failing execution: `steps.len > 100`, actual 75. It examines
60 rows and 16 distinct self values with zero atomicity violations. The
native serial catalog at the same SHA passes. The fixture deliberately
oversubscribes CPU and contends on the real sampler lock, but stops after
exactly ten seconds even when those threads have made insufficient progress.

## Expected

[RunQuota Observation Store](../../reprobuild-specs/RunQuota-Observation-Store.md)
specifies the ambient host/self measurements. The fixture checks that each
row's self figures were live at its timestamp and requires over 100 steps,
at least 15 checked rows and five distinct values to avoid vacuous success.
Preserve every threshold and every recorded row. Proposed fixture repair:
run for at least ten seconds and until over 100 steps have completed, with
a monotonic sixty-second deadline and the same failure assertions afterward.
Publish progress atomically; inspect step records only after joining their
writer. This changes the fixture's scheduling allowance, not the sampler.

## Evidence

[Linux ARM64 job](https://github.com/metacraft-labs/runquota/actions/runs/36484461518/job/109139768209)
at `0622770`, downloaded as `/tmp/runquota-062-linux-arm-repro.log`.
Refreshed dev `f4f0f93` and searched current and deleted issue history for
`atomicity`, `steps.len` and `churnRounds`; no prior record was found.

At `2efa366`, macOS Reprobuild job `109349836460` passes 195 of 196 actions.
The atomicity fixture records 810 steps but only 11 rows and two distinct
self values, with zero violations. The earlier wait extends only until the
step floor is met; it still stops before the sampler's coverage floors.
Extend that same bounded wait until persisted rows also meet the existing
15-row and five-value floors, using the real store read. Keep the sixty-second
deadline and all final row/atomicity assertions; do not inspect the step
records before joining their writer. Native validation remains required.

At `2efa366` plus this repair, the real local program passes with 58 rows,
769 steps, 50 distinct self values and zero violations. A temporary control
changes only the sampler cadence from 100 ms to 2000 ms in each version:
the old fixture fails its unchanged 15-row floor with five rows; the repaired
fixture waits for 16 rows and passes with 16 distinct values and zero
violations. Both controls compile and run the real sampler/store without mocks.
