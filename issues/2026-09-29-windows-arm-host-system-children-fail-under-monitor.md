# Windows ARM-host tests cannot launch their real system-tool fixtures

Status: open. Observed at RunQuota `8add804` in the x64-emulation lane.

## Observed

[Windows ARM-host job 109446771063](https://github.com/metacraft-labs/runquota/actions/runs/36580081181/job/109446771063)
finishes 198 actions with 179 successes, 15 failures and four blocked actions.
The ACL fixture fails at `currentUserSid`: `whoami /user failed:` with no
output. All fourteen directory ACL cases then fail before their intended
assertions. Owner identity also fails its independent system-tool comparison.
Other failures include child lease lifecycle, retention, read-only mapping,
and test process timeouts. Their shared cause is not established.

This job uses an x64 Reprobuild/monitor/compiler on Windows ARM64. io-mon
`af1af0f` has a separate real control showing that x64 injection fixtures fail
when they launch the ARM64 System32 shell and pass with an x64 child. This
suggests a cross-architecture monitoring limitation here, but does not yet
attribute RunQuota's failures or prove its native ARM64 behavior.

## Expected and investigation

[Release validation](../../metacraft-specs/infrastructure/gosti-io-mon-runquota-releases.md)
requires real native payload checks on every shipped target. Windows ARM64
RunQuota remains in scope; io-mon's native Windows ARM64 backend is explicitly
deferred. Keep the ACL fixtures independent of RunQuota: compare the same
real system tools and test binaries with and without the enclosing monitor.
Retain their exit codes, output, architecture and exact source identities.
Do not replace the independent owner check with the implementation it tests,
or reinterpret a failed monitored run as success.

Fetched dev `e9f9011` before filing. Searched current and deleted issue history
for `whoami /user failed` and `emulation`; no existing record covers this
ARM-host failure. The downloaded failure report is retained under
`/tmp/runquota-8add-windows-arm-repro-artifacts/`.

## Complete candidate at `7036462`

[Job 109865062657](https://github.com/metacraft-labs/runquota/actions/runs/36708690438/job/109865062657)
passes the full compilation graph, then reports 185 successful actions, eight
failed programs, eight blocked programs and 102 cache hits. The failures are:

- Exact isolated environment includes `PROCESSOR_ARCHITECTURE`; the new
  dedicated environment issue records this unmonitored fixture separately.
- Concurrent short-lived clients settle at 31 finished operations, missing
  the expected final completion.
- The process execution benchmark contract, observation export and observation
  merge programs expire at the unchanged 600-second action limit. Their
  earlier cases pass.
- The store-degradation fixture counts one dropped row instead of at least two.
- The stats-table control fails its resident precondition, then its emptied
  and off branches report correct socket estimates.
- The in-process retention schedule repeatedly observes no completed sweep
  within its existing bounds; disabled/unidentified-host controls pass.

These observations do not identify a shared cause or establish that native
ARM64 payloads behave the same way. They must be investigated using retained
state and matched native/monitored controls. No deadlines or assertions are
relaxed. Evidence is in `/tmp/runquota-703-windows-arm-evidence` and the full
job log `/tmp/runquota-703-windows-arm.log`. Refreshed dev `0bce530` and agents
`04a74d2` before extending this issue.

## Test scheduling comparison

The environment failure has a separate verified fixture repair at `48bb701`.
The seven remaining failed programs are compared, unchanged, in
[36726271653](https://github.com/metacraft-labs/metacraft-github-actions/actions/runs/36726271653)
at tooling `ce0d17e`. One monitored build supplies the same binaries for
parallel, serial and parallel execution on one ARM host. The admission caps
are eight, one and eight; the report's launch/completion trace can establish
the actual overlap. Every execution is uncached and must really launch. The
fixture deadlines, assertions, monitoring and internal concurrency (including
all 32 concurrent clients) remain intact. Hashes must remain equal across all
three runs. This is a diagnostic of competing fixture work, not a selected
CI scheduling repair. Complete ordinary validation remains required.

## First comparison outcome and fixed-image correction

At tooling `ce0d17e`, run `36726271653` executes every selected program in
parallel-first mode. Concurrent clients, process benchmark and stats-table
control pass. Store degradation again counts one dropped row; retention
schedule misses its sweep bounds; export and merge stop at 600 seconds after
their first three cases pass. Before execution, the graph evaluation legitimately
rebuilds stats-table control and export on cache misses. The hash guard then
stops the experiment before serial mode. There is no serial-versus-parallel
result, and these failures do not establish a common contention cause.

Tooling `b60cba4` builds the same RunQuota `48bb701` programs once, enters the
activated environment once, and launches fixed executable images under the
production monitor. It never invokes a compiler during comparison. Replacement
`36735013860` records each program's start, finish, exit code and binary hashes
for admission caps eight, one and eight. Original internal concurrency,
assertions, closed stdin and the 600-second timeout/ten-second kill grace remain.
Every program executes in every mode, regardless of earlier failures. The
complete ordinary Reprobuild workflow remains the release gate.

Evidence: `/tmp/runquota-arm-contention-ce-evidence`. Refreshed dev `2c50aaf`
and agents `e67ce70` before extending the existing record.

## Ordinary environment-repair candidate

At RunQuota `48bb701`, [job 109933446531](https://github.com/metacraft-labs/runquota/actions/runs/36729033751/job/109933446531)
fails compilation of `t_hardware_run_tool_streams`: GCC reports that it cannot
start its `cc1.exe` child (`CreateProcess: No such file or directory`). Tests
and native cross-checks are consequently skipped. This is the compiler-launch
symptom reproduced in the separately instrumented hook-transaction investigation;
this ordinary run carries no trace proving the same underlying cause. Its
Windows x64 counterpart passes the complete monitored suite, native cross-check
and all 12 static helper checks. Current candidate `33add18` remains in CI.

Raw ARM log: `/tmp/runquota-48bb-windows-arm-complete.log`; failure artifact:
`/tmp/runquota-48bb-arm-evidence`. Refreshed dev `2c50aaf` and agents `4ae8008`
before recording these results. Neither failure nor the passing x64 result
replaces native ARM64 release-payload validation.

The current RunQuota `33add18` repeats compiler-child launch failures in
[job 109944771773](https://github.com/metacraft-labs/runquota/actions/runs/36732257074/job/109944771773):
101 actions succeed, while the daemon and `t_observation_store_retention`
compilations cannot start `cc1.exe`. Its Windows x64 job passes monitored
build/test, all 100 native test programs and all 12 static helper checks.
The ARM report again contains no hook checkpoints. Evidence is retained at
`/tmp/runquota-33add-arm-evidence`; the shared hook investigation remains active.
