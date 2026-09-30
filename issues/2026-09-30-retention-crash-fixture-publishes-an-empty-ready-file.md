# Retention crash fixture exposes its ready file before writing the PID

Status: open. Observed at `dda957b` on Linux ARM64, native CI run
`36684401708`, job `109786845604`.

## Observed

The full suite passes 97 programs and fails only
`t_observation_store_retention_crash`. Calibration finishes in 249 ms with
5,693,872 WAL bytes and no partial state. The killed pass then raises
`ValueError: invalid integer` at line 552 while parsing an empty ready file.
`runPruneRole` uses `writeFile` on the final pathname; the parent's existence
check can succeed after creation but before the PID has been written.
This occurs before the actual crash assertion, independently of the earlier
late-kill failure. The ambient CPU, memory and clamp checks all pass.

## Expected and repair

[Observation Store / Retention](../../reprobuild-specs/RunQuota-Observation-Store.md)
requires a real process-group kill and whole-transaction recovery check.
Publish the PID through a closed temporary file and a same-directory rename,
so the ready pathname denotes a complete record. Keep the current readiness
bound, real group kill, measured WAL threshold, completion-marker rejection
and all integrity/row assertions.

Fetched dev `0bce530`, already an ancestor of the candidate, and searched
current and deleted issues for readiness, PID markers and invalid integers.
The existing macOS retention issue concerns a kill arriving after commit,
not this file-publication race. Linux ARM64 is deferred from the first release;
the fixture repair applies to every platform.
