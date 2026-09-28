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
