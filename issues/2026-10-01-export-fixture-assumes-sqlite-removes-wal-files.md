# Export fixture assumes SQLite removes WAL files when connections close

| | |
| --- | --- |
| Status | open |
| Recorded | 2026-10-01 |
| Observed in | runquota `a173bafd35ce3eef607f6062bde5175f1aadeede` |
| Area | `tests/unit/t_observation_store_export.nim`, `buildLocalStore` |

## Observed

On macOS ARM64 with Nim 2.2.4 and `/usr/bin/sqlite3` version 3.51.0
(`f0ca7bba...dcaapl`), the unmodified observation-store suite passes 27 of
28 binaries. Export fails with `the template store still has a -wal file`.
The fixture assumes closing every SQLite process removes the template's WAL
and shared-memory files before copying its main database file.

The measurement used a shell wrapper that records each invocation and then
executes `/usr/bin/sqlite3` with unchanged arguments, input, output and status.
It does not replace SQLite or hold an extra database connection. Evidence:
`/tmp/runquota-merge-batch-baseline-tests.log`, retained test root
`/tmp/rqtest.PwpFRmbX`. This occurred before the merge batching change.

## Expected

The [observation-store spec](https://github.com/metacraft-labs/reprobuild-specs/blob/3d6ccdbda46c88f637a10484bf949d4d404ba133/RunQuota-Observation-Store.md#redaction)
requires redaction at export and preservation of unredacted local data.
Not specified: whether the fixture must support Apple's SQLite build.
Proposed: construct its reusable template with SQLite's snapshot operation,
so every case gets a complete independent database without relying on WAL
sidecar removal. Retain the checks that detect missing rows and redaction
errors. Do not simply delete the sidecars or weaken the assertion.

## Search

Fetched `agents` and `dev` on 2026-09-30 UTC. Searched current issues and
issue history for the assertion and Apple SQLite; no earlier record found.
The existing macOS retention crash issue concerns a different WAL boundary.
