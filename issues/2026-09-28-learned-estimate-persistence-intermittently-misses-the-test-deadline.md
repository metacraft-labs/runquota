# Learned estimate persistence intermittently misses the test deadline

| | |
|---|---|
| Status | in-progress: diagnosis |
| Recorded | 2026-09-28 |
| Observed in | RunQuota `3170fba`, local macOS ARM64 |
| Area | memory-pressure integration test and asynchronous estimate persistence |

## Observed

A full `nix develop --profile /tmp/runquota-3170fba-validation-shell --command just test`
passes admission, in-memory estimate inspection and learned-budget assertions,
then the pressure test raises `learned estimate was not persisted` after 100
SQLite polls. The other 95 test programs and the static-helper gate pass.
Five immediate unmodified repeats and 25 diagnostic repeats pass.

The original probe discards SQLite exit status and stderr, and removes the
scratch database on failure. It cannot distinguish an absent row from a failed
query. No cause is yet established. A diagnostic copy now preserves the database,
prints daemon status/output and records actual SQLite errors without mocking
SQLite or changing the daemon.

## Expected

[RunQuota Protocol and Client Libraries, Learned Estimate Store](../../reprobuild-specs/RunQuota-Protocol-And-Client-Libraries.md)
requires asynchronous persistence while keeping admission independent of durable
storage. Retain the real daemon, memory-pressure checks and the persisted value
assertion. Establish whether a write is dropped, delayed or merely not observed
before changing a timeout or the writer.

## Evidence

- `/tmp/runquota-3170fba-full-macos.log`: 95/96 programs and the static helper checks pass.
- `/tmp/runquota-pressure-repeat-baseline.log`: five original repeats pass.
- `/tmp/runquota-pressure-diag-runs.log`: 25 diagnostic repeats pass.
- Refreshed `origin/dev` at `f4f0f93`, already an ancestor of the measured source,
  and searched current and deleted issues for learned-estimate persistence and
  the memory-pressure test. The observation-store flush issue concerns a separate
  writer and does not explain this failure.

## Additional evidence and probe repair

Native macOS CI at `3170fba` passes all 96 programs and static helpers in
job `109081684248`; CPU attribution records 38.3% initial host use and a
measured/known-load ratio of 1.032. One hundred further diagnostic repeats
pass. Two query invocations report `database is locked`; other early queries
report a missing table. No writer failure was reproduced, so these do not
establish the original timeout's cause.

The query probe did have an independently testable defect: opening a missing
SQLite file in default mode creates it before the asynchronous writer does.
Open it read-only, assert that polling leaves an absent database absent, and
retain SQLite exit/stderr diagnostics on timeout. Keep the same 100 polls and
every pressure, admission and persisted-value assertion. The new regression
fails when `-readonly` is removed: SQLite creates the absent database and
reports a missing table. Both cases pass at `a889665` plus this probe repair;
the real-daemon case also passes in the negative control. The original
intermittent timeout remains open until it is attributed.

Linux x64 job `109368774241` at `292e578` reproduces the timeout in the native
cross-check with the repaired read-only probe: `query returned no learned
estimate`. The fixture still discards the daemon's output during cleanup.
Preserve daemon inspection counters, shutdown output and the SQLite files on
failure so the next occurrence can distinguish a dropped writer batch from a
delayed one. Keep the same persistence deadline and value assertion. A local
real-reader transaction held for 350 ms at `2dd0407` does not reproduce a drop;
do not change the SQLite writer based on that unconfirmed explanation.
