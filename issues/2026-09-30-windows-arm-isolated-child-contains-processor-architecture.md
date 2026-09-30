# Windows ARM-host isolated child contains PROCESSOR_ARCHITECTURE

Status: open. RunQuota `70364629d5214bf4be9ac760d63e572fc257b111`.

## Observed

The complete Windows ARM-host [job 109865062657](https://github.com/metacraft-labs/runquota/actions/runs/36708690438/job/109865062657)
passes compilation, then its isolated-environment fixture sees exactly
`PROCESSOR_ARCHITECTURE` and `RQ_TEST_DECLARED`. The inheriting-child control
passes. This fixture already executes without an outer monitor and cannot
reuse an execution cache entry; it is a different observation from monitor
loader/session-variable injection. The report does not retain the extra
variable's value. Native CI passes all ten jobs, and the complete Linux and
macOS monitored jobs pass at the same candidate.

## Expected and investigation

[`CommandSpec.isolateEnvironment`](../libs/runquota_process/src/runquota_process/types.nim)
requires the launcher to supply only the declared environment, inheriting
nothing from its own environment. The real child assertion in
[`t_isolated_environment`](../libs/runquota_process/tests/t_isolated_environment.nim)
expects exactly the declared variable. Compare a literal Unicode environment
block passed directly to Windows `CreateProcessW`, independently of RunQuota,
on native x64 and the ARM host. Include a declared architecture value and a
real inheriting-child control. Never print the inherited environment or
credentials into the public artifact.

Microsoft documents architecture-related environment changes in
[WOW64](https://learn.microsoft.com/en-us/windows/win32/winprog64/wow64-implementation-details),
but that page describes 32/64-bit transitions and does not by itself establish
this x64-on-ARM behavior. Do not add a broad variable allowlist or weaken the
launcher-leak assertion without the real OS control. The complete release gate
remains required.

Fetched dev `0bce530` and agents `04a74d2`; both are included locally. Searched
open issues and their full history for environment, isolation and ARM. The
monitor-injection and case-variant records describe distinct mechanisms.
