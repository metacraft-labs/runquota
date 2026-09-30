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

## Helper phases pass; diagnostic console output times out

Run `36736205178` at tooling `30d78bd` preserves a passing focused graph and
all 16 successful native/monitored repetitions at RunQuota `7036462`. Each
repetition's retained log has all eight passing lifecycle cases: 128 cases
in total, with identical fixture and daemon hashes throughout. The 64 observed
helper exit waits range from 15 to 1106 ms, below their unchanged 3000 ms
bound. All helpers reach their expected exit codes. This run does not reproduce
the earlier intermittent helper failure.

The Actions step nevertheless expires at 60 minutes while emitting the
captured console text. The complete files and final `results.json` are
already present, while the job log is still printing the first monitored
repetition. Treat the workflow as failed, retaining the narrower completed
test evidence. Tooling `7729607` bounds console tails to 12 lines per capture
and removes duplicate tail printing; complete files remain artifacts and
command exit status is preserved. Real file/output controls cover successful
and failing commands, spaces in paths and invalid tail limits. PowerShell
syntax passes. Replacement `36745684530` keeps all pairs and all existing
fixture, action and workflow time limits.

Daemon readiness polling is 80 attempts with 50 ms sleeps, not a strict
four-second wall-clock deadline: an IPC connection call may itself block.
This run records 53–7603 ms from spawn return to readiness, with no exhausted
poll loop. No timeout or product behavior is changed based on those durations.
Evidence: `/tmp/runquota-readiness-30d-evidence` and
`/tmp/runquota-readiness-30d-job.log`. Refreshed dev `2c50aaf` and agents
`ef060dd` before extending this record.

## Native helper expires before its first startup marker

Bounded-output run `36745684530` at tooling `7729607` completes the focused
monitored graph and all eight paired repetitions at RunQuota `7036462`.
Every monitored repetition passes. Native repetitions 1–4 and 6–8 pass;
native repetition 5 fails its normal supervisor-exit case. Across the retained
logs, 127 of 128 lifecycle cases pass. Fixture and daemon hashes remain
identical throughout each comparison.

The failed helper has PID 1656, returns zero after 3105 ms against its unchanged
3000 ms wait, and emits no helper-entry marker or later phase. The daemon
reports zero granted leases. Nim's Windows timeout termination uses exit zero,
which the expected normal exit alone cannot distinguish; the existing lease
count assertion catches this failure. Its daemon was already ready after
7642 ms of readiness polling. Every daemon in the comparison becomes ready;
this is not the original missing-pipe failure.

This occurrence is native, without the outer monitor. It establishes that
this helper made no recorded progress before timeout termination; it does
not yet distinguish Windows image/CRT startup from imported Nim module
initialization or other scheduling delay. Capture process/thread startup
state before the timeout kills a future failing helper. Preserve the actual
lifecycle assertions and wait bound; do not attribute it to the ARM-host hook
transaction based on a shared timeout symptom.

Evidence: `/tmp/runquota-readiness-772-evidence/build/windows-readiness`,
especially `native-5.log` and `results.json`. Daemon SHA-256 is
`2650BB5E7659D33463678AB30B8CF0BA0EB24AEFBBC26F7EF4FD814D7FD5B515`;
fixture SHA-256 is
`CCCD5E8D61E0E33A61D97B6A185A8E85B11F9B4542BAACA19CF223F4E7D018E4`.
Refreshed dev `2c50aaf` and agents `339ab1e` before extending this record.

Tooling `8fd4eff` adds the next failure observer in `36753042655`. It waits
on the real Windows process with the same 3000 ms bound; only after expiry
it records process CPU time and up to eight thread contexts, with balanced
suspend/resume calls and bounded unwind addresses. It then terminates with
Nim's original exit zero and explicitly marks the expired wait as a failure.
No raw stack contents, environment values or arguments are retained. A real
fast child must preserve exit 17; a real sleeping child must time out and
yield an actual thread context before the paired fixture comparison runs.

PowerShell transformation and full Windows x64 C compilation/link pass for
the instrumented fixture at RunQuota `33add18`; the actual comparison retains
`7036462`. The observer's standalone C control also compiles/links for Windows
x64. Runtime controls and repeated comparisons remain pending in the new run.
This changes only disposable diagnostics, not the release source.

## Helper context and missing daemon readiness both recur

At exact RunQuota `7036462`, tooling `8fd4eff` in
[36753042655](https://github.com/metacraft-labs/metacraft-github-actions/actions/runs/36753042655)
passes the real observer controls and focused graph, then completes all eight
native/monitored pairs at unchanged hashes. Of 128 lifecycle cases, 125 pass.
The three failures are distinct observations:

- Native repetition 3's running-lease helper exceeds the original 3000 ms
  wait before its first flushed helper marker. At expiry its process has
  15.625 ms of kernel CPU time and zero reported user CPU time. The main thread
  is at `ntdll+0x163294`; eight unwind addresses are in ntdll and KernelBase.
  No function-symbol identity or application-level cause is established.
  The observer records the timeout before termination, and the existing
  lease/status assertions fail as well.
- Native repetition 5's daemon never prints its application-entry marker or
  publishes its pipe before the unchanged readiness loop expires.
- Monitored repetition 1 reproduces the same missing daemon output/pipe in
  its final forced-supervisor-kill case. `startProcess` itself takes 3999 ms;
  cleanup begins at 9074 ms measured from before that spawn.

The other 126 daemon startups report readiness. This reproduces the original
missing-pipe symptom without an outer monitor as well as with it. A stalled
helper also appears in a native run; neither observation supports attributing
all startup failures to monitor injection. The system instruction addresses
alone do not establish a Winsock, loader or security-software cause.

The real fast-child control returns 17. The real sleeping-child control
expires at 3000 ms, records two thread contexts and is reaped with the expected
zero timeout termination status. The diagnostic retains every original test
assertion and deadline. Daemon hash:
`7A7AAFE74FAB9176CA4984B83AF46061C90DEC7C229A1CD7E8220D3FA897AF38`;
fixture hash: `BF0C865F8479550EBC456FEF79207E647EA33E31F726E221AA62345B270F1BFE`.

Evidence: `/tmp/runquota-readiness-8fd-evidence`. Refreshed dev `2c50aaf` and
agents `641d103`. Current release candidate `33add18` separately passes all
ten native jobs and complete Windows x64 and macOS Reprobuild jobs; this
focused recurrence remains an open intermittent issue, not a failed gate at
that candidate.

## Full execution after all 100 monitored compilations succeed

Run `36753037680` at tooling `8fd4eff` completes on 2026-09-30 at
20:18 UTC against RunQuota `8cf662c`, hooks `8f4d806` and disposable all-range
hook-page preparation. All 100 monitored compile actions pass. Its test graph
has 93 successful actions, 85 up-to-date actions, 12 failed executions and
eight blocked executions:

- Exit 124: host-state trust, process/exec contract, extension write path,
  query interface, standalone backup, observation export and observation merge.
- Exit 137: observation socket write path, after a daemon stream-read error;
  the shell reports the timeout wrapper was killed.
- Exit 1: observation flush contract, multi-session fairness, standalone
  daemonless degradation and retention schedule.

Fairness fails to open a daemon pipe. Standalone degradation includes access
denied while removing a child executable. Flush-count and retention-cadence
assertions also fail. Partial successful test output precedes the timeouts;
it does not establish that the programs completed. No phase-130 hook trace
accompanies these failures. They cannot be assigned the compiler stall's cause
from a shared timeout symptom.

These 12 programs are unchanged between `8cf662c` and candidate `a173baf`.
The latter does select the separately validated root-exit capture repair in
its CI bootstrap. Its ordinary checks and the current-source prepared graph
`36763970172` at `f5a3d99` remain pending; this older result does not establish
their outcome. No test assertion or production deadline is waived.

Evidence: `/tmp/windows-arm-prepared-all-8fd-evidence` and bounded action
summary `/tmp/windows-arm-prepared-all-8fd-summary.json`. The diagnostic shim
hash is `BBB2E1EE4B77C96F6D527DBBEB3763BCA33996A3CA44DE515B31F4309507D21E`.
Refreshed dev `2c50aaf` and agents `057a60f` before extending this record.

## Next diagnostic: observe a live test tree without changing its wait

Use the current release sources and validated capture repair for a focused
export/merge/retention comparison. Keep the real monitor, test binaries,
assertions and GNU timeout's 600-second bound. Periodically read CPU times and
the diagnostic shim's exported initialization phase in that invocation's own
process tree. The observer must neither suspend threads nor terminate targets.
A real child exporting a known phase must prove the reader works and that the
child remains alive afterward. These observations can distinguish incomplete
shim initialization from later execution; they do not identify a Windows
wait's cause or replace the full ordinary CI gate.

Implemented as disposable tooling `8817d55` in run `36774529116`, using
RunQuota `33add18`, hooks `def2464` and original hook protection. Windows x64
C compilation/link with warnings as errors, Python/PowerShell syntax and
workflow validation pass at that tooling commit. The real Windows controls
and native/monitored repetitions remain pending. The known-phase child must
remain alive after observation; a separate child exporting a different phase
must fail the same phase assertion. The existing full current-source graph and
ordinary release CI remain running independently.
