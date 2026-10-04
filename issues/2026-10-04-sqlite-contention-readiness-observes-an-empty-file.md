# SQLite contention readiness observes the file before its acknowledgment

| Field | Value |
| --- | --- |
| Status | Open; repair authorized by the current stabilization |
| Observed in | `024038a4799c80002b78dc085ae2014594f1d73b`, macOS ARM64, complete forced Repro run |
| Expectation | Observation-store sampling and accounting in `docs/database.md`; the real SQLite transaction must be held before measuring sampling under contention |

The full debug and optimized suites pass 105 programs and 537 cases at this
source. The 213-action Repro run fails in `t_ambient_writer_contention` before
sampling starts: `readFile(ready).strip() == "locked"` sees an empty string.
Four later measurement programs are blocked. The report is retained as
`/tmp/runquota-013-repro-report.json` on the development host.

The fixture waits for the readiness file to exist, then requires its contents
to equal `locked`. SQLite's `.once` creates the output file before the following
`select 'locked'` writes its result. Existence therefore does not establish
that the acknowledgment has arrived, although the preceding `begin immediate`
has acquired the real transaction.

Refresh and search: fetched the product's `agents` and `dev`, searched open and
historical issues for writer, SQLite, readiness and contention. Existing
retention readiness and background-sampler issues concern different boundaries.
The latest hook-only change `8d7796f` is preserved in the dated branch before
this repair; it changes no test or runtime code.

## Repair and controls

Wait for the complete `locked` acknowledgment inside the existing 3500 ms
readiness bound, then retain the existing exact-content assertion. Keep the
transaction, 50 ms sampling cadence, 1200 ms measurement window, sample counts,
overflow and loss accounting, background scheduling, draining and every
existing assertion unchanged. Do not increase a deadline or retry a test.

Use real SQLite to delay the result after `.once` opens the file. The old
fixture must fail on empty contents; the repaired fixture must pass the same
real contention controls. A wrong acknowledgment must still fail within the
existing readiness bound. Repeat full debug, optimized and forced Repro suites
with exact program/case parity before opening the promotion PR.

## Local controls

At `29adbce` plus the readiness repair, a real recursive SQLite query delays
its one `locked` result after `.once` opens the file. The original fixture
fails on the empty acknowledgment in 0.465 seconds. The repaired fixture with
the identical SQL passes all eight cases, including the real background child,
in 10.30 seconds. Returning `wrong` instead of `locked` still fails readiness:
the whole program exits in 3.90 seconds, including database setup before the
unchanged 3500 ms wait. Source variants, logs and results are retained under
`/tmp/runquota-sqlite-ready-controls` on the development host.

Only fixture synchronization changes. Full debug, optimized, Repro and platform
qualification remain required; the preceding failed full report is retained.
