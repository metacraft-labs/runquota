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
