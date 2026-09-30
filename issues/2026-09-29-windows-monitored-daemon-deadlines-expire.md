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
passes all 198 actions: all 98 test programs actually launch, with caching
disabled for their execution. The starting-lease helper returns its expected
32 in 71 ms; the other helper waits take 32, 47 and 197 ms. Retention's measured
prune window is 4863 ms and every original assertion passes. These are separate
runners of the same class; the comparison supports controlling competing work,
and does not establish a daemon defect. The ordinary Windows x64 Reprobuild job
at `19ee745` also passes the graph and native cross-check, confirming the
failure is intermittent.

Apply the two-program ordering change to `repro.nim` on every host, using its
existing measurement lane. No deadline, assertion, capture or monitor policy
changes. The full ordinary workflow at the resulting production commit remains
required before closure.

Evidence: `/tmp/runquota-windows-deadline-7c-parallel-evidence` and
`/tmp/runquota-windows-deadline-7c-isolated-evidence`. Refreshed dev
`e9f9011` and searched open/deleted deadline and readiness records before
extending this issue.

## Recurrence after ordering the measurement lane

The complete Windows x64 Reprobuild [job 109865062746](https://github.com/metacraft-labs/runquota/actions/runs/36708690438/job/109865062746)
at `70364629d5214bf4be9ac760d63e572fc257b111` passes the first seven
crash-recovery cases but its final forced-supervisor-kill case fails before
starting its helper. The daemon's named pipe does not appear within the same
four-second startup wait (Windows error 2). The report records 193 successful
actions, one failure and seven blocked measurement programs. The measurement
lane already waits for all compiler and ordinary test actions at this commit;
that ordering alone has not removed the intermittent startup failure.

The fixture currently closes its daemon output pipe without reporting the
child's output or whether it exited before readiness. Capture that evidence
and compare repeated monitored/native runs of the same binaries before
changing a deadline or runtime behavior. Keep every assertion and the full
ordinary release gate. Refreshed dev `0bce530` and searched current/deleted
readiness records; this is a recurrence of the existing issue.

## Focused controls and complete-graph observation

Diagnostic `36716116358` at tooling `cea927f` records a passing focused graph,
one complete passing native/monitored pair and a second passing native run.
The second monitored log contains all eight successful fixture assertions,
but its wrapper exit was not recorded before cancellation, so it is not
counted as a completed comparison. Every recorded daemon reaches its pipe
within the original readiness bound; one monitored `startProcess` itself
takes 5682 ms before the readiness wait starts. This does not reproduce the
full-graph failure.

The repeated `repro exec` environment setup consumes many minutes per sample.
Tooling `9ef9750` enters that environment once for all eight pairs, and its
startup-output collector reads only already-buffered bytes instead of waiting
for EOF that a descendant could retain. These are diagnostic corrections, not
established causes of the original readiness failure. Windows Nim checks pass
for both instrumented sources, and both PowerShell scripts and the workflow
pass syntax/lint checks.

At exact RunQuota `7036462`, full-graph observation
[36723729088](https://github.com/metacraft-labs/metacraft-github-actions/actions/runs/36723729088)
keeps every test and adds the startup checkpoints. Paired focused comparison
[36723733885](https://github.com/metacraft-labs/metacraft-github-actions/actions/runs/36723733885)
uses the same instrumentation and one environment. Both use tooling `9ef9750`.
The superseded `cea927f` and `3020d7e` diagnostics were cancelled explicitly;
ordinary release gates and the independent ARM compiler trace continue.

## Full-graph diagnostic correction

Full graph `36723729088` at tooling `9ef9750` finishes with 179 successful
actions, 14 failed programs and eight blocked programs. Its startup tracing
writes five extra lines to every daemon's stdout. Other real fixtures use the
three public startup lines as a readiness barrier, so they consume diagnostic
lines instead and proceed before store verification. For example,
`t_endpoint_serves_before_store_verification` prints the three diagnostic lines
where it expects listening, capture and hardware-profile messages. The target
crash-recovery program is blocked and never executes. This run does not
reproduce or explain its original startup failure.

Tooling `92c3b6d` enables those lines only in children of the instrumented
crash-recovery fixture, using a process-local environment flag. The fixture
already collects its own daemon output without parsing it as a barrier.
Unrelated fixtures retain the ordinary startup protocol. Windows source checks
pass for both instrumented sources. Against RunQuota `48bb701` plus this
instrumentation, a real macOS store-verification test passes with all three
ordinary startup lines, and all eight instrumented lifecycle cases pass.
Evidence: `/tmp/runquota-readiness-scoped-control.log`.

Replacement full graph
[36731094289](https://github.com/metacraft-labs/metacraft-github-actions/actions/runs/36731094289)
uses tooling `92c3b6d` and the same exact RunQuota `7036462`, deadlines and
assertions. The focused `9ef9750` comparison remains useful because it launches
only the fixture that collects raw output, and is allowed to finish. The
failed full-graph artifact is retained in `/tmp/runquota-readiness-9ef-full-evidence`.
Refreshed dev `0bce530` and agents `fed6830` before recording this correction.

## Completed focused comparison and helper observation

Focused run `36723733885` at tooling `9ef9750` finishes all eight paired
repetitions against RunQuota `7036462`. The monitored graph and every
monitored repetition pass. Native repetitions 1, 3, 5, 7 and 8 pass; repetitions
2, 4 and 6 fail helper exit/status assertions before any lease is granted.
Granted-abnormal helpers return zero instead of 31 twice, starting-abnormal
returns zero instead of 32 once, and running-abnormal returns zero instead of
33 once. All daemons reach readiness, so this does not reproduce the original
missing daemon pipe. These results show a helper failure also without an outer
monitor. At Reprobuild `c14b1e6`, `runActivatedCommand` starts the activated
command directly; only the paired monitored mode invokes `internal io monitor`.
The unchanged binary hashes are retained in `results.json`.

The helper output was not retained in that comparison. Tooling `71d7fe7` adds
flushed helper-entry, connection, registration, lease and child-spawn phases,
and records elapsed waits and bounded available output. The original 3000 ms
wait and all assertions remain. Windows source checks pass, and real macOS
startup-protocol and all eight lifecycle cases pass against `33add18` plus
this diagnostic. Focused replacement `36734357209` runs the same `7036462`
candidate; corrected full graph `36731094289` continues independently.
Refreshed dev `2c50aaf` and agents `44bc56c` before recording this evidence.

## CRLF diagnostic repair

Run `36734357209` at tooling `71d7fe7` stops before compiling or executing the
fixture: its anchored helper-phase regex does not match CRLF checkout lines.
This is a diagnostic defect, not a new RunQuota failure. Tooling `30d78bd`
normalizes disposable source and here-string anchors together and preserves
original bytes for cleanup. A real CRLF conversion of all four edited files
at RunQuota `33add18` passes Windows source checks, the native macOS public
startup-protocol control, and all eight instrumented lifecycle cases. Cleanup
is checked against the original CRLF bytes. Replacement focused run
`36736205178` uses the same RunQuota `7036462` and unchanged fixture bounds.
The independently corrected full graph `36731094289` continues.

## Corrected full graph passes

Complete run `36731094289` at tooling `92c3b6d` passes at RunQuota `7036462`:
all 201 actions succeed and every one of the 99 test programs launches with
`cdNotCacheable`. The instrumented crash-recovery fixture passes all eight
cases; its daemon readiness measurements range from 132 to 173 ms. The
ordinary startup protocol is preserved for every other fixture. This is a
passing complete graph, not a closure of the separately reproduced intermittent
helper failures. Focused helper-phase run `36736205178` remains active.
Evidence: `/tmp/runquota-readiness-92-full-evidence`.
