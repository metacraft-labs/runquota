# Completion latency fixture uses the Windows wall clock for submillisecond work

| | |
|---|---|
| Status | in-progress; fix/release-validation-failures |
| Recorded | 2026-09-29 |
| Observed in | RunQuota `292e578`, diagnostic `36558849865` |
| Area | `t_completion_report_does_not_wait_on_the_store.nim` |

## Observed

The unchanged native Windows binary passes directly but fails under `timeout`:
keyed median 0.0000 ms, keyless median 2.0113 ms, against the 2 ms ceiling.
This does not establish a wrapper defect: the runs are sequential, and the
fixture measures elapsed time with `epochTime()`. Nim 2.2.8 implements that
Windows clock with `GetSystemTimeAsFileTime` and explicitly documents it as
unsuitable for benchmarking. The paired store-drain counters pass.

## Expected

The fixture's OS-1 contract requires completion latency to remain independent
of store publication. Measure elapsed time with `getMonoTime()` and retain
the existing 2 ms control ceiling, paired comparison, drain and final-publication
assertions. A native rerun must still establish whether the actual lifecycle
cost meets the threshold; changing the clock alone does not establish that.

## Evidence

Artifact `runquota-windows-toolstore-292e578`,
`build/windows-controls/t_completion_report_does_not_wait_on_the_store-timeout.log`.
The direct and wrapped binaries have the same SHA-256
`576EBB5D607DA5B78702DCC3785754A8E871A8DF459AD6415C9DB98D10FDF421`.
Refreshed `origin/dev` at `e9f9011` and searched live/deleted issues for
`epochTime`, latency and `LatencySlackMillis`; none records this clock defect.
