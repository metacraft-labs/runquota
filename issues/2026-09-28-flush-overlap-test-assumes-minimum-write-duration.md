# Flush overlap test assumes a minimum database write duration

| | |
|---|---|
| Status | open |
| Recorded | 2026-09-28 |
| Observed in | runquota @ e9e487a2e1b8eac9cea2ea9bef088b77672f6a82 |
| Area | `libs/runquota_observation_store/tests/t_observation_flush_contract.nim` |

## Observed

The native macOS CI suite passes 92/93 tests. In the flush overlap case:

```text
in-flight drain took 89 ms; the flush under test waited 51 ms; written before it: 0; read back 1200 of 1200
Check failed: report.flushMillis >= MinimumWindowMillis
report.flushMillis was 89
MinimumWindowMillis was 100
```

The row visibility and write-count assertions passed. This run does not demonstrate
a broken production flush; it fails the fixture's minimum-duration control.
The local macOS full suite passed 93/93 at `906800c`, with the same test source.

## Expected

`reprobuild-specs/RunQuota-Observation-Store.md`, OS-1 and the ingestion path,
requires asynchronous observation writes without hot-path perturbation. The
flush test's documented contract requires previously queued rows to be committed
before the caller proceeds. A 100 ms minimum database write duration is not
specified. Proposed: establish overlap through an observable synchronization
condition against the real database, so a faster machine can still demonstrate
that flush waits for the in-flight drain.

## Evidence

[macOS job 108796933644](https://github.com/metacraft-labs/runquota/actions/runs/36381129777/job/108796933644),
`MinimumWindowMillis`, `inFlightDrain`, and the test
"a flush waits for a drain already in flight on another thread".
Open product issues and their git history were searched; no existing record
covers this timing control. The separate unwritable-store race recorded in
`reprobuild-specs/issues/2026-09-25-runquota-unwritable-store-test-races-the-writer-drain.md`
concerns a different fixture.

## Suggested direction

Use a real SQLite transaction and an explicit handoff to hold a drain in flight.
Keep the positive control and row-visibility assertions; merely lowering or
removing the timing threshold would not establish overlap.
