# Windows ARM compiler startup fails in the full monitored build

Status: open. Observed at RunQuota `19ee745` with source-built io-mon
`5e71adf` on `windows-11-arm`, compiling and running the x64-emulation suite.

## Observed

Ordinary Reprobuild job
[109635178225](https://github.com/metacraft-labs/runquota/actions/runs/36635537078/job/109635178225)
finishes compilation with 97 successful and three failed actions, all cold.
The test stage never starts. Two Nim invocations cannot start `gcc.exe` and
report Windows error 1460 (startup timeout); another GCC invocation cannot
start `cc1.exe`, reporting `CreateProcess: No such file or directory`.
The same declared compiler builds the other 97 actions. This does not establish
that the cc1 file was absent when its launch failed.

The log shows eight simultaneous outer Nim actions. Their commands omit
`--parallelBuild`, so each may start several C compilers. The related Reprobuild
[oversubscription issue](../../reprobuild-specs/issues/2026-09-24-test-build-nim-compiles-oversubscribe-the-c-compiler.md)
already records this nesting; its measurements do not prove the cause here.
The injection library also deliberately reports 1460 after terminating a child
whose borrowed-thread injection failed to finish safely. Preserve that failure
behavior rather than resume a potentially corrupted child.

## Expected and investigation

The approved [release validation](../../metacraft-specs/infrastructure/gosti-io-mon-runquota-releases.md)
requires full compilation and execution on the shipped Windows host targets.
Retain all test programs, monitoring and child-injection deadlines. Compare the
same complete graph at `8cf662c` with two admitted outer actions, alongside its
ordinary eight-action CI. Supplemental control `36644657089`, shared actions
`a7c9c3f`, records native CPU details and samples actual Nim/GCC/cc1 counts.
A scheduling improvement is a hypothesis until the full graph confirms it.

The original build failure report is retained under
`/tmp/runquota-19ee-windows-arm-evidence/.repro/build/repro/build-failure-report.json`.
Fetched current dev `0bce530` and searched open/deleted compiler, timeout and
nested-parallelism issues before filing. This is separate from the verified
finished-image cleanup repair and the measured test-execution scheduling fix.

## Two-action control did not eliminate the failure

At RunQuota `8cf662c`, shared control `36644657089` (`a7c9c3f`) executes
all 100 build actions with two outer actions admitted. Ninety-nine succeed;
`t_forking_lease_completion` fails starting a C compiler with error 1460.
The test stage does not run. Ordinary eight-action CI `36643299557` at the
same source fails launching `as.exe` from GCC. Lower concurrency alone is not
a repair. The control retains process counts and the full build report in
artifact `runquota-windows-arm-build-budget`.

## Capture-repaired candidate still has a compiler launch failure

Ordinary Reprobuild run `36765565687` at release candidate `a173baf`
finishes on 2026-09-30 at 21:05 UTC with 102 successful build actions and
one failed action, `runquota.test_build.t_host_load_reading_invariants`.
GCC 16.1 cannot start its `cc1.exe` child and reports
`CreateProcess: No such file or directory`. No test action runs on this host.
The declared toolchain successfully compiles the other programs; the report
does not measure whether the compiler file existed at the failed launch.

This candidate selects hooks `def2464`, including the independently validated
root-exit capture repair, while retaining original hook protection and
context polling. The ordinary report has no hook phase trace, so the matching
launch symptom does not prove the same phase-130 cause. Linux x64/ARM64,
macOS ARM64 and Windows x64 Reprobuild jobs pass; all ten native CI jobs pass.
The current-source all-range diagnostic `36763970172` and the focused runtime
observer `36774529116` remain active. No release tag has been created.

Evidence: `/tmp/runquota-a173-arm-evidence/.repro/build/repro/build-failure-report.json`
and `/tmp/runquota-a173-arm-complete.log`. Refreshed dev `2c50aaf` and agents
`b83ad77` before recording this recurrence in the existing issue.

## The unchanged retry fails a different compiler launch

Attempt 2 of `36765565687`, still at `a173baf`, finishes on 2026-09-30
at 22:46 UTC with 102 successful compilations and one failed action:
`runquota.test_build.t_observation_write_path_rules`. Nim cannot complete
the GCC invocation for `@pmath.nim.c` and reports Windows error 1460,
`This operation returned because the timeout period expired`. No test stage
executes. This recurrence is a different compilation from attempt 1.

Evidence: `/tmp/runquota-a173-arm-retry.log` and
`/tmp/runquota-a173-arm-retry-evidence/.repro/build/repro/build-failure-report.json`.
The report again lacks hook phase traces, so it does not establish the blocked
API or a missing compiler file. No further unchanged retry is selected.
Merge/retention batching candidates address test execution overhead separately;
they do not repair this compiler-startup boundary.

## Isolated full-graph page-preparation candidate

`7fd57f4` is based on the native-CI-green `f93855c` application tree and
changes only the Windows hook bootstrap input to `d36cab8`. That helper
candidate prepares code-page protection transitions before suspending peers;
its complete original/prepared 26-test Windows corpus passes on both hosts
(104 case runs total, tooling `6875d29`, run `36792017491`). Both source
variants pass, so the short corpus does not reproduce or prove repair of the
compiler stall. It is the prerequisite behavior check for the full graph.

The exact RunQuota source lock is published, remote blob
`383b2708b2ece78200177a3fc8610fe7b6ae4f66` verified. Complete candidate
CI is `36792986046` / `36792989240`. PR 35 remains at `a173baf`; this
experimental input is not selected for a release until the full results pass.
The ordinary `f93855c` run is retained as the unchanged-protection baseline.

That baseline completes on 2026-10-01 at 00:43 UTC with 101 of 103 builds
passing. `t_e2e_runquota_client_exit_releases_lease` cannot launch `cc1.exe`;
`t_observation_retention_scheduled` cannot launch `as.exe`. Both report
`CreateProcess: No such file or directory`; there is no hook phase trace.
No test stage runs on the ARM host. Its Windows x64 monitored suite passes,
but the native benchmark cleanup race is recorded separately.
Evidence: `/tmp/runquota-f938-arm-repro.log` and
`/tmp/runquota-f938-arm-evidence/repro/build-failure-report.json`.

Prepared candidate `7fd57f4` passes all ten native jobs and the complete
Linux ARM64 Reprobuild gate; other Reprobuild jobs remain active. Follow-up
`9f88e77` changes only benchmark cleanup and its isolated-source fixture.
It retains the same prepared hook input and runs complete native
`36795959804` / Reprobuild `36795962975` CI. No compiler timeout or
runtime assertion is relaxed.
