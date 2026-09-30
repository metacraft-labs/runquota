# macOS retention crash fixture delivers its kill after pruning has finished

Status: open. Observed at RunQuota `177e2af`.

## Observed

Ordinary macOS job
[109548617627](https://github.com/metacraft-labs/runquota/actions/runs/36609966396/job/109548617627)
fails only `t_observation_store_retention_crash`. Its calibration completes in
2242 ms, records 5,693,872 WAL bytes and 73 isolation samples, with no partial
state. The killed pass first observes its write lock after 71 probes, then
sees the entire 5,693,872-byte WAL against a 4,270,404-byte target. The process
group is already gone when the kill is sent; the completion marker exists and
the store contains the correctly pruned whole state. This did not exercise a
crash and is correctly rejected by the fixture.

## Expected and repair

[RunQuota Observation Store / Retention](../../reprobuild-specs/RunQuota-Observation-Store.md)
requires crash-safe pruning. Keep the real process-group kill, measured WAL
threshold, completion-marker rejection, no-survivors assertion and whole-state
checks. Do not count an uninterrupted successful prune as a crash control.

The fixture currently logs and checks the observed WAL size, then opens its
process-group handle before sending the kill. Open the group after readiness
and deliver the kill immediately when the threshold is observed; report and
check afterward. Also schedule this timing-sensitive measurement with the
existing measurement programs after compilation and competing tests. The
complete graph must verify those changes; neither the current evidence nor a
later quiet pass alone proves which delay caused the missed window.

Refreshed dev `e9f9011` and searched current and deleted issues for pruning,
crash safety and the killed-prune test. The Windows retention deadline issue
concerns scheduled background pruning, not this process-group kill control.
