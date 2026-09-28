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
SQLite polls. The other 94 test programs and the static-helper gate pass.
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

- `/tmp/runquota-3170fba-full-macos.log`: 94/95 programs and the static helper checks pass.
- `/tmp/runquota-pressure-repeat-baseline.log`: five original repeats pass.
- `/tmp/runquota-pressure-diag-runs.log`: 25 diagnostic repeats pass.
- Refreshed `origin/dev` at `f4f0f93`, already an ancestor of the measured source,
  and searched current and deleted issues for learned-estimate persistence and
  the memory-pressure test. The observation-store flush issue concerns a separate
  writer and does not explain this failure.
