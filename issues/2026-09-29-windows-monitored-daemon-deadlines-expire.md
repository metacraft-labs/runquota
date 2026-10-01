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

## Completed current-source observations

Full graph `36763970172` at tooling `f5a3d99`, RunQuota `33add18` and
hooks `def2464` completes with all 103 build actions successful. Its test
graph reports 93 successful, 88 up-to-date, 14 failed and eight blocked
actions. Nine failures return 124, two return 137 and three return 1.
The failures include SQLite concurrent spawn, daemon startup/communication,
publication, retention and export/merge. All-range page preparation therefore
does not establish a complete repair. No phase-130 trace accompanies these
runtime failures. Evidence: `/tmp/windows-arm-prepared-f5-evidence`.

Focused comparison `36774529116` at tooling `8817d55` preserves binary hashes
and the original protection behavior. All three native programs pass:
retention in 22.2 seconds, export in 52.2 and merge in 61.2. Monitored retention
passes in 220.5 seconds and export in 553.6; merge returns 124 after 636.8
seconds including monitor completion. The retained streams contain 360, 878
and 1026 process-spawn records respectively. Merge prints six successful
assertions before timeout, so this run does not support a post-suite exit
deadlock. The process-tree samples include initialized shims but omit the
actual test PID recorded in the merged stream: a snapshot of live parent
links is insufficient across the MSYS process transitions. Do not attribute
the test's wait to those idle ancestors. Both real phase-reader controls pass,
including rejection of phase 322 with status 13. Evidence:
`/tmp/runquota-runtime-881-evidence`.

### Next controlled comparison

The source bootstrap at candidate `a173baf` and these diagnostic rebuilds use
debug monitor shims. Compare the same fixed application/test binaries with
debug and release-mode shims built from identical source pins and diagnostic
stores. Keep native execution, all assertions, capture and the original
600-second timeout. Record both shim hashes and complete results even if the
debug arm fails. This tests the existing `IO_MON_BUILD_MODE` build option;
it does not select a production change or waive a gate.

Extend the read-only observer to select the exact test executable path, created
after the invocation root, as an additional observation root. Label it as an
image match rather than asserting an unobserved parent relationship. Preserve
creation-time checks, known/wrong-phase controls and the ban on suspending
observed threads. Ordinary candidate `a173baf` remains in its failed-job retry;
four Reprobuild hosts and all ten native jobs already pass at that SHA.

## Startup cost and bounded merge-query batching

Small real-assembler comparison `36784367520` at tooling `90d1c40` passes
all 80 launches on each Windows host, including child-specific COFF output,
process-start, file-read and file-write assertions. On the ARM host, median
direct launch times are 492 ms with the debug shim and 487 ms with the release
shim; propagated launches take 928 and 906 ms. Native launches take 71 ms.
This does not support treating release-mode compilation as the startup fix.
Evidence: `/tmp/windows-shim-mode-90d-arm` and
`/tmp/windows-shim-mode-90d-x64`. The full fixed-RunQuota comparison remains
active separately at tooling `2bed024`.

At RunQuota `a173baf`, each merge launches SQLite separately for each of five
spine-table existence checks, each source/destination column listing, and
each of seven before/after row counts. Batch those read-only operations into
one table-list query, one requested-column query per database and one count
query per snapshot. Keep metadata scoped to the requested tables; an unrelated
virtual table must not become a new prerequisite. Preserve column order,
extension discovery and opacity, every host/owner refusal, the existing single
write transaction, report counts and canonical merge identity (OS-5/6/7 of
the observation-store spec). Do not cache metadata across merges or modify
source databases, test fixtures, assertions or deadlines.

Validate against the existing real SQLite merge, owner, migration and export
tests, comparing original and batched binaries with the same input and tool.
Count real SQLite invocations through a delegating executable wrapper; the
wrapper must execute the real SQLite binary and preserve its stdin, stdout,
stderr and status. This is measurement, not a replacement SQL implementation.
The complete ordinary release matrix is still required before selecting the
new candidate. This batching addresses excessive launch count; it is not
claimed as a repair for the independent hook-protection compiler stall.

## Repeated full runtime observation

Diagnostic `36778919434` at tooling `d35cfcc`, using RunQuota `33add18`,
hooks `def2464` and io-mon `5e71adf`, completes native retention/export/merge
in 20.1/48.2/55.2 seconds. Monitored export and merge pass in 495.9 and
623.9 seconds including monitor cleanup. Monitored retention fails in
194.6 seconds: `waitFor(scFinished, 1)` remains zero in the bounded busy-host
deferral case. Every other retention assertion passes. The unchanged merge
can therefore complete under monitoring, but it is close to its execution
bound and is not reliably green across runs.

Evidence: `/tmp/runquota-runtime-d35-evidence`, including result JSON,
per-test logs, exact binary hashes and source pins. This observer still has
the known live-parent-tree gap; do not attribute its ancestor phase readings
to an absent test process. The later `2bed024` comparison addresses that
observation gap and remains a separate run.

## Bounded retention-query batching

RunQuota `c6ddde6` changes only merge reads. Its seven unchanged merge cases
pass locally with 762 real SQLite launches versus 1,114 at `a173baf`, using
the same Apple SQLite 3.51.0 executable through a delegating wrapper. Its
complete 28-binary observation-store subset passes with Nix SQLite 3.51.2
and Nim 2.2.4. Full ordinary CI and the paired Windows comparison at tooling
`8159a30` remain pending; no release candidate is selected from this alone.

The separate scheduled-retention failure at `33add18` is a ten-second wait
for `scFinished`. At `c6ddde6`, the first sweep opens the store, queries the
registry, checks each extension table separately, counts executions,
extension rows and carried rows separately, commits the existing deletion
transaction, then counts hosts and profiles separately. Each query launches
a new SQLite process. The passing small startup comparison above measures
about 0.5 seconds per monitored launch on the ARM host; this motivates
reducing launches, but does not establish the duration of any failed sweep.

On a separate branch, batch the registry's existing-table lookup into one
read, all doomed-row counts into one snapshot, and the final host/profile
counts into one read. Preserve registered extension order, invalid-identifier
rejection, the absent-extension-table behavior, opaque extension columns,
host-qualified deletion predicates and the existing single write transaction.
An unreadable count must fail explicitly before deletion. Preserve all
sweeper cadence, deferral, locking, degradation and reporting behavior, and
every test assertion and deadline. This implements the observation-store
spec's Retention and OS-5/6 requirements with fewer child processes.

Measure the unmodified retention-schedule suite first, then run the existing
real SQLite extension, retention, retention-schedule and crash/atomicity gates
against the change. Run Windows controls before selecting it for the release.
Do not infer a fix for compiler hook-protection stalls from these results.

### Completed local and Windows x64 checks

The retention change is `f93855c`, directly above merge change `c6ddde6`.
At `f93855c`, all 34 observation-related binaries pass locally with Nim 2.2.4
and Nix SQLite 3.51.2, including real extension rollback, retention, scheduled
retention, crash/isolation and merge tests. Repository lint passes. Tests and
deadlines are unchanged. Full CI and paired Windows retention controls are
still required before selection.

The merge comparison at tooling `8159a30` completes on Windows x64 with all
12 original/batched, native/monitored cases passing. In that one paired run,
the monitored merge suite takes 110.7 seconds at `a173baf` and 81.3 seconds
at `c6ddde6`; export takes 91.6/80.0 seconds and users 62.8/48.9 seconds.
The native merge times are 28.7/27.7 seconds. Both variants use the same
compiler, SQLite and original debug monitor on the same worker. This is one
run, not a latency distribution. Evidence: `/tmp/runquota-merge-batch-815-x64`.
The ARM-host comparison in that run is still active.

## Both Windows merge comparisons pass

Tooling `8159a30`, run `36786810296`, now passes all 12 cases on both
Windows hosts. On the ARM host, monitored merge takes 565.1 seconds at
`a173baf` and 416.4 at `c6ddde6`; export takes 444.8/408.4 and users
294.6/231.0 seconds. Native merge takes 55.7/43.1 seconds. This is one
ordered paired run, not a latency distribution; the independent local count
still establishes the reduced SQLite-launch count. Evidence:
`/tmp/runquota-merge-batch-815-arm` and `/tmp/runquota-merge-batch-815-x64`.

Native CI `36788909146` at retention candidate `f93855c` passes all ten
jobs. The x64 retention comparison `36788891396` at `cfff6c3` passes all
12 cases; store-retention takes 67.7/68.2 seconds under monitoring, so that
run does not establish a speedup. Its ARM comparison also passes all 12
cases: monitored store-retention takes 280.5 seconds at `c6ddde6` and
243.7 at `f93855c`; schedule takes 195.1/170.4 and extension tests
180.8/164.3. All use the same compiler, SQLite and original debug monitor
on the same worker. This is one ordered comparison, not a latency
distribution. Evidence: `/tmp/runquota-retention-cfff-arm`.

Full Reprobuild CI `36788912758` at `f93855c` passes both Linux jobs;
macOS and Windows remain active. Separate candidate `7fd57f4` changes only
the Windows hook pin to `d36cab8`, after that helper passes all 104 paired
original/prepared Windows corpus cases. Its complete CI is `36792986046`
and `36792989240`. No test deadline or assertion changes.

## Complete ARM-host result before retention and hook changes

Full Reprobuild run `36786740859` at RunQuota `c6ddde6` finishes with
Linux x64, Linux ARM64, macOS and Windows x64 passing. Its Windows ARM
x64-emulation job `110129883904` compiles all 103 programs, then reports
187 successful actions, eight failures and eight blocked actions:

- Inherited-descriptor isolation never starts: MSYS cannot launch
  `/usr/bin/timeout` and reports `Device or resource busy` (status 126).
- The process benchmark contract cannot remove `runquota_m5_process_bench.exe`
  after its existing cleanup retries; the outer action times out. This is
  distinct from the observation-database cleanup failure at `f93855c`.
- The socket-write fixture misses its dropped-row count. It already polls
  both write failures and dropped rows; adding that predicate again would
  not fix this observation.
- Aggregate publication and scheduled retention miss their existing waits.
- Store export and merge return 124; store query is killed with status 137
  after two passing cases.

This candidate includes merge-query batching only. It predates retention
batching at `f93855c`, prepared hook pages at `7fd57f4`, and bounded inner
benchmark cleanup at `9f88e77`. Those later complete runs must decide which
failures persist. The benchmark image-lock failure is not established as
fixed by retrying removal of its separate daemon directory. Keep every
assertion, deadline and runtime gate. No hook phase trace accompanies this
report, so it does not identify the compiler-startup stall as its cause.

Evidence: `/tmp/runquota-c6-arm-repro.log` and the downloaded
`repro/build-failure-report.json` under `.repro/build/` in
`/tmp/runquota-c6-arm-evidence`. Refreshed dev `2c50aaf` and agents
`da47483` before extending this existing record.

## Current x64 recurrence and explicit helper-start boundary

At candidate `9f88e77`, Windows x64 Reprobuild job `110159381835` in
run `36795962975` compiles every program and reaches 195 successful actions,
one failure and seven blocked measurement programs. The starting-abnormal
helper's `waitForExit(3000)` returns zero; total grants and lost leases both
remain zero. The other seven lifecycle cases pass. This matches the earlier
traced helper-start failures, but this ordinary run has no entry-phase trace.
Evidence: `/tmp/runquota-9f-x64-repro.log` and the failure report under
`/tmp/runquota-9f-x64-evidence/.repro/build/repro/`.

The fixture currently begins its three-second lease-operation/exit wait as
soon as `startProcess` returns, before establishing that the helper has
entered its own code. Earlier controls above directly observe expiration
before helper entry even without monitoring. The protocol spec's
[Supervisor-Lost Orphan Policy](../../reprobuild-specs/RunQuota-Protocol-And-Client-Libraries.md#supervisor-lost-orphan-policy)
requires recovery from an actual granted/starting/running lease; it does not
define a three-second OS-loader deadline.

Repair the fixture boundary explicitly. A real child reports application
entry through a scratch-file handshake, then waits for the parent to release
it. Reuse the fixture's existing five-second readiness bound. The parent
starts the unchanged three-second lease-operation/exit wait after releasing
that gate. Keep every real daemon, lease transition, expected exit and
reclamation assertion. Apply the same startup handshake to all helper modes;
forced-kill cases retain their additional lease-state readiness condition.
Clean up a child if setup fails. This deliberately separates setup time from
lease-operation time; it does not claim the old total spawn-to-exit window
is unchanged. No product timeout or runtime behavior changes.

Validate with real processes and no replaced APIs: a delay before the
helper-entry signal must reproduce the old failure and pass with the new
boundary; the same delay after the parent's release must still fail the
three-second exit assertion. Run the unchanged normal suite and both Windows
native/monitored controls, then the complete candidate matrix.
Refreshed dev `2c50aaf` and agents `53a6ca1`; the existing record and its
archived history own this recurrence.

### Handshake candidate and local controls

Candidate `15e4deb` implements the entry/release handshake. Against its exact
fixture source, the real local macOS controls produce all four expected
results: original plus a 3.5-second pre-entry delay fails only the
starting-abnormal case; the repaired fixture with that delay passes all eight
cases; a 3.5-second delay after release still fails only the same three-second
exit assertion; and the unmodified repaired fixture passes all eight cases.
Windows source checking and repository lint pass. The controls were measured
on the working tree above `9f88e77`, whose only source change became
`15e4deb`. Evidence: `build/startup-handshake-local/results.json` under
`/tmp/runquota-helper-startup-fix`; every variant has a retained binary hash.

The exact candidate's source lock is published with verified remote blob
`23634667c31393db5d456c3c49832d5da8704f09`. Complete native
`36800244338` and Reprobuild `36800247249` runs are active. Shared tooling
`7d1ef0c`, run `36800325319`, repeats all four real controls natively and
under the production monitor on both Windows hosts. A Windows result and the
complete ordinary matrix are still required before release selection.

### Windows control launcher correction

Native run `36800244338` passes all ten jobs at `15e4deb`. Its full
Reprobuild matrix remains active. Windows x64 control job `110172972885`
at tooling `7d1ef0c` fails before compiling or executing a fixture:
Python's bare `bash` selects the Windows System32 WSL launcher, which
reports that no WSL distribution is installed. Bootstrap had provisioned
Git Bash. This is a diagnostic launcher failure, not a candidate assertion
failure. Evidence: `/tmp/runquota-startup-7d1-x64/apps.build.log` and
`/tmp/runquota-startup-7d1-x64-job.log`.

Tooling `b5e3811` resolves Bash to its absolute path before launching it,
requires GNU Bash in its version output, and retains the selected identity.
Run `36801996275` repeats the same four native/monitored process controls
on both Windows hosts. No fixture expectation or product source changed.

### x64 process controls and interrupted complete validation

At tooling `b5e3811`, Windows x64 job `110178151125` passes all eight
native/monitored outcomes for RunQuota `15e4deb`: delayed original entry
fails only the intended exit assertion, delayed repaired entry passes all
eight cases, delayed work after release still fails that assertion, and the
unmodified repaired fixture passes all eight cases. No outer timeout occurs;
the input hashes remain unchanged. The selected GNU Bash resolves under the
activated Reprobuild tool store. Evidence: `/tmp/runquota-startup-b5e-x64`.
ARM controls remain active. The earlier `7d1ef0c` ARM job also selects the
WSL launcher and fails before fixture execution; its error requests a WSL
update. That launcher error is distinct from the x64 missing-distribution
message and is covered by the same absolute-path correction.

Full candidate run `36800247249` receives cancellation at 01:58 UTC on
October 1, before validation completes. Both Linux jobs have passed monitored
build/test but lose the native test cross-check; Windows x64 has passed its
monitored build, and macOS has completed setup and entered its monitored
build. These partial results are not a complete gate. The available API
does not identify the cancellation requester; there is no newer replacement
run and manual-dispatch concurrency is unique per run. No assertion failure
is inferred from cancellation. The reason has been requested from the user.

Predecessor `9f88e77` independently passes complete macOS monitored and native
cross-checks in job `110159381875`, run `36795962975`. Its existing x64
helper failure remains the measured reason for selecting the handshake
candidate, whose full validation is still required.

### ARM control result and next observation

At tooling `b5e3811`, ARM job `110178150891` reaches all eight comparison
outcomes for `15e4deb`. All four native outcomes match expectations. Under
monitoring, repaired delayed entry and the unchanged repaired fixture each
pass all eight lifecycle cases; delayed work after release still fails only
the required three-second exit assertion. The original delayed-entry variant
instead fails its fifth daemon's readiness check before launching the helper:
`CreateFileW` reports Windows error 2 for the named pipe. Its other seven
cases pass. Thus seven of eight comparison outcomes match, and every
repaired outcome passes; the original monitored negative control fails for
the wrong reason. Evidence: `/tmp/runquota-startup-b5e-arm`.

Do not label that comparison wholly passing or attribute its daemon failure
to the helper handshake. Supplement it with the same four variants selecting
only the starting-lease case through Nim unittest's test filter. Retain the
same real daemon and exact readiness/exit bounds. If daemon readiness fails,
record its PID, running state and available exit status before ordinary
cleanup. Preserve the existing full-suite controls and full ordinary gates.
This narrows the intended measurement without discarding the unrelated
startup failure above.

The complete matrix at unchanged `15e4deb` restarts as run `36805849869`
after the earlier interruption. Native CI remains fully passing. No source
change or assertion relaxation is selected from the baseline daemon result.

Focused tooling `e4c3b73`, run `36806359507`, implements that single-case
comparison and records its test filter explicitly. The instrumented sources
pass all four expected real local controls with one lifecycle case each;
the delayed-work variant still fails the exact three-second assertion.
Windows source checking, Python syntax and workflow checks pass. Local
evidence is under `build/startup-handshake-focused-local` in
`/tmp/runquota-helper-startup-fix`; the Windows source-check log is
`/tmp/runquota-startup-case-windows-check.log`. Complete ordinary CI still
runs every test at unchanged product `15e4deb`.

## Complete prepared-hook ARM runtime result

Full run `36792989240` at `7fd57f4` completes with 186 successful actions,
nine failed executions and eight blocked measurements on ARM. Compilation
passes completely. The failed executions are:

- SQLite concurrent spawn: two threads do not complete 100 calls within
  60 seconds. The message attributes this to inherited pipes, but the report
  contains no progress counts or pipe ownership proving that diagnosis.
- Concurrent short-lived clients: final state is quiet, with 30 completed
  leases where the fixture expects 32. Its five-second `waitForExit` checks
  do not identify which children may have timed out.
- Multi-session fairness: the fifth daemon misses pipe readiness; the first
  four cases pass.
- Forking lease completion: the leased-call elapsed time is 5.418 seconds
  against a five-second assertion. Its earlier direct completion case passes.
- Process benchmark contract and standalone daemonless degradation: exit 124
  after partial successful assertions.
- Retention schedule: five cases miss their completion/counter waits.
- Observation export and merge: exit 124 after three and four passing cases,
  respectively.

This source already includes merge/retention query batching and prepared
hook pages. It predates the benchmark cleanup and helper-handshake changes.
Those two changes do not establish repairs for the other eight test files.
Evidence: `/tmp/runquota-7fd-arm-repro.log` and the failure report under
`/tmp/runquota-7fd-arm-evidence/.repro/build/repro/`.

The earlier current-source merge comparison at `c6ddde6` passed all twelve
native/monitored cases on ARM with three independent programs admitted at
once. Its monitored batched merge took 416.4 seconds, versus 43.1 seconds
natively. The full graph admits more independent tests; this is a possible
resource-interference explanation, not proof that serialization fixes the
current failures. The older serial comparison at `33add18` still failed.

Next, instrument the current SQLite stress fixture with real per-thread
completion records, retaining both threads, all 100 calls, its 60-second
deadline and survivor checks. Compare the unchanged and observed fixture
alone, natively and monitored, then admit eight copies of the observed
fixture before repeating its single-copy measurement. Keep real SQLite,
separate databases and fixed binary/shim hashes. Counts and timestamps must
distinguish slow progress from an actual stall before selecting a resource
or fixture change. Full ordinary validation at `15e4deb` continues separately.

## SQLite progress control and later complete ARM result

Tooling `4a2a9e7`, run `36808704707`, implements the progress comparison
above against RunQuota `15e4deb`. Both original and observed real SQLite
fixtures pass locally. The observed fixture records 50 completed calls per
worker. A corrected real-tool wrapper delays each SQLite invocation by 1.4
seconds without changing its SQL: the original 60-second watchdog fails,
with both workers still progressing and each recording 41 completions.
This proves that the observer distinguishes continued progress from no
progress when the watchdog expires. An earlier wrapper used a missing Bash
interpreter and did not apply its delay; that attempt is not a control.
Local evidence is `build/sqlite-progress-local/results.json` and its marker
files in `/tmp/runquota-helper-startup-fix`. Windows source checking and
Python/workflow syntax checks pass. Windows runtime results remain pending.

Full ARM run `36795962975` at `9f88e77` now completes. Every compilation
passes, but eight runtime programs fail and the eight measurement programs
remain blocked. Multi-session fairness again misses its fifth daemon's pipe
readiness. Forking lease completion takes 6.422 seconds against its original
five-second assertion. The socket write-path case observes zero failure and
dropped counters after making its store unwritable. Four retention schedule
cases miss completion waits. Process benchmark, standalone degradation,
export and merge reach exit 124 after partial passing output. The SQLite
concurrent-spawn and short-lived-client failures from `7fd57f4` do not
recur in this run; that alone establishes no repair.

Evidence is `/tmp/runquota-9f-arm-repro.log` and the failure report under
`/tmp/runquota-9f-arm-evidence/.repro/build/repro/`. The benchmark cleanup
change does not address these runtime waits. Current `15e4deb` ordinary CI
and the focused startup comparison remain active separately.

## Select the independently validated injection-lock initialization

Helper `43b1835` passes all seven native and all five monitored/native
platform jobs. Corrected paired tooling `5336c54`, run `36802560317`,
now completes on both Windows hosts. Its original ARM implementation hangs
in native repetition one and monitored repetition four. The initialized
implementation passes all twelve native and twelve monitored repetitions,
with complete assertion output and four real output/status controls. Both
variants pass all x64 repetitions. Helper PR 12 contains exactly this fix
and its validated prerequisites.

Select `43b1835` as RunQuota's Windows CI bootstrap helper pin, above the
current `d36cab8`, to remove the independently demonstrated first-call lock
race. Preserve RunQuota `15e4deb` source, every ordinary test and deadline,
and the separate POSIX bootstrap pin. This selection does not attribute the
RunQuota SQLite or daemon waits to that race: RunQuota's captured SQLite
calls already serialize process creation. Run complete ordinary CI at the
new pin before selecting it for the release. Keep the current `15e4deb`
run and SQLite progress control as independent observations.

Candidate `b4a9c53` contains only that Windows CI helper-pin change above
`15e4deb`. Workflow checks and repository lint pass. Its isolated source
lock is published with matching local/remote blob
`a7ece987315c3cb18c02ce0395f6743cbb44fe12`. Complete native run
`36809230285` and Reprobuild run `36809232981` are active. Helper PR 12
is merged as `59a2bac`, whose tree equals the validated `43b1835` source.
