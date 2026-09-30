# Windows ARM-host isolated child contains PROCESSOR_ARCHITECTURE

Status: focused repair verified at `33add18`; complete CI and promotion pending.
Observed at RunQuota `70364629d5214bf4be9ac760d63e572fc257b111`.

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

[`CommandSpec.inheritEnv = false`](../libs/runquota_process/src/runquota_process/types.nim)
requires the launcher to supply only the declared environment, inheriting
nothing from its own environment (`isolateEnvironment` at the observed source).
The real child assertion in
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

## OS control and fixture repair

Direct API [36724192457](https://github.com/metacraft-labs/metacraft-github-actions/actions/runs/36724192457)
at tooling `80e9c493c2692e830ebf2712275d6f0a2c418ae1` passes on both hosts.
On native x64, a literal block containing only `RQ_TEST_DECLARED=yes` yields
that one variable. On the ARM host, the same x64 program yields that variable
and `PROCESSOR_ARCHITECTURE=AMD64`. An explicitly supplied architecture sentinel
is preserved on native x64 but replaced with `AMD64` on ARM. The real
inheriting-child control observes the launcher sentinel on both hosts. No
RunQuota or monitoring code participates in this control.

Repair the fixture by explicitly declaring its compile-target architecture
on Windows (`AMD64` for x64 and `ARM64` for native ARM64), while retaining the
exact comparison of all child keys and values against the declared entries.
Keep the launcher-only leak control and the ten-second child completion bound.
This avoids accepting undeclared variables or a broad platform allowlist.
Clarify the API comment: RunQuota supplies the declared environment only; an
OS loader can normalize reserved platform variables. No launcher runtime
change is needed for the behavior reproduced here. Validate the unchanged
fixture and repaired fixture on both real hosts, then reintroduce environment
inheritance as a negative control and require that control to fail.

Refreshed dev `0bce530` and agents `5bba14b` before selecting this repair.

## Real repair and negative-control validation

[36725477372](https://github.com/metacraft-labs/metacraft-github-actions/actions/runs/36725477372)
at tooling `ac3f4f3` compares RunQuota `48bb701` with the unchanged fixture from
`7036462`. Native x64 passes both original and repaired fixtures. The ARM host
reproduces the original `PROCESSOR_ARCHITECTURE` failure and passes both
repaired assertions. Reintroducing the real launcher inheritance path makes
the repaired fixture fail on both hosts, rejecting the launcher sentinel and
the extra parent entry. All six processes finish normally within their bounds.
Each comparison uses a deliberately small synthetic parent environment, so
the negative control cannot print CI credentials. Exact binary hashes and all
logs are retained in the run artifacts.

Both native macOS assertions also pass at `48bb701`; its Windows x64 and ARM64
Nim source checks pass. The recipe's existing monitor isolation and uncached
execution remain unchanged. No production launcher logic changes.

## Reconciliation with the current mainline API

Dev `2c50aaf` introduces the same isolation capability as `inheritEnv = false`.
Candidate `33add18739814c3886da1f69f8a4e18ab1e36faa` merges that commit into
`48bb701`, using the mainline API in the exact-environment fixture. It retains
the explicit Windows architecture, every exact key/value assertion, and the
case-insensitive Windows override repair. Both fixtures pass all five cases
on native macOS; a real inherited-environment mutation still fails the exact
assertion. Windows x64/ARM64 source checks and repository lint pass at `33add18`.

Windows [36732223032](https://github.com/metacraft-labs/metacraft-github-actions/actions/runs/36732223032)
at tooling `5838377` repeats the original/repaired/leaking comparison against
`33add18`. Only the baseline's constructor argument is translated to the
mainline API; its old declarations and assertions remain intact. Complete
native `36732251894` and Reprobuild `36732257074` validate that exact candidate.
Its source-lock blob `f4eb79d702ea51496c6932f02e8af453457af0a0` is published
and verified through manifests `b6ba16b`.

The repeated control `36732223032` at tooling `5838377` passes on both hosts
against `33add18`. Native x64 passes original and repaired fixtures; ARM again
fails the original assertion and passes the repair. Restoring real inheritance
makes the repaired fixture fail on both hosts. All six processes finish.
Evidence is retained in `/tmp/runquota-environment-583-arm-evidence` and
`/tmp/runquota-environment-583-x64-evidence`. Complete CI remains active.
