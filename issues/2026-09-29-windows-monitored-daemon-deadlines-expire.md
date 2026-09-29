# Windows monitored daemon readiness and retention miss fixture deadlines

Status: open. Observed at RunQuota `177e2af` with io-mon `5421a9b`.

## Observed

Ordinary Windows x64 job
[109548617510](https://github.com/metacraft-labs/runquota/actions/runs/36609966396/job/109548617510)
fails two programs. The forced-supervisor-kill case cannot connect to its newly
started daemon within the existing four-second readiness bound; the other
seven lease lifecycle cases pass. Scheduled retention reports no completed
sweep within its twenty-second wait, and the healthy-store precondition of
the unwritable-store case removes no rows within ten seconds. Another retention
case records a 28.229-second prune window and passes concurrent admission and
observation assertions. After daemon shutdown the first case finds the correct
retained rows, so absence of pruning is not established by its timeout alone.

## Expected and investigation

[RunQuota Observation Store](../../reprobuild-specs/RunQuota-Observation-Store.md)
requires background retention without blocking admission. The
[release validation spec](../../metacraft-specs/infrastructure/gosti-io-mon-runquota-releases.md)
requires real daemon tests in both ordinary paths. Preserve those assertions
and deadlines while comparing the same binaries without monitoring. Capture
retention state and child startup evidence before choosing a runtime or fixture
repair. Current evidence does not separate monitor overhead, competing fixture
work, or a daemon defect. Shared diagnostic `d04a676` compares the selected
programs in `36618038706` and reports the retention state at each failure.

Refreshed dev `e9f9011` and searched open and deleted readiness/retention issues.
The earlier Windows tool-store issue records a startup timeout but no isolated
cause. macOS sentinel readiness concerns a different child and measurement.

## Full-graph reproduction with helper timing

At RunQuota `19ee745`, io-mon `5e71adf`, diagnostic
[36636493544](https://github.com/metacraft-labs/metacraft-github-actions/actions/runs/36636493544)
(`7c2fe6d`) runs all 98 programs. The parallel graph fails four programs:

- The starting-lease helper returns zero after 3022 ms against its unchanged
  3000 ms deadline. Its flushed helper-entry marker is absent; other helper
  modes finish in 159, 256 and 465 ms with their expected statuses. Nim's
  Windows `waitForExit(timeout)` terminates timed-out children with status zero,
  so this is a timeout, not a successful application exit. No lease was granted.
- Store verification's Hello response arrives after 5872 ms, beyond the
  fixture's 3500 ms lock-window ceiling.
- Scheduled retention's zero-bound case removes none of the expected 41 rows
  within its wait. Another case measures a 26038 ms prune while admission and
  reporting remain responsive.
- The unwritable-store socket test counts one dropped row instead of two
  before its five-second polling bound; its later flush-barrier checks pass.

The companion graph moves only lifecycle and scheduled retention into the
existing measurement lane after compilation and competing tests. Its outcome
is still pending. These observations establish missed test windows, not a
particular runtime cause. Keep every bound and assertion while checking that
comparison. The ordinary Windows x64 Reprobuild job at `19ee745` passes the
graph and native cross-check, so the failure is intermittent.

Evidence: `/tmp/runquota-windows-deadline-7c-parallel-evidence`. Refreshed dev
`e9f9011` and searched open/deleted deadline and readiness records before
extending this issue.
