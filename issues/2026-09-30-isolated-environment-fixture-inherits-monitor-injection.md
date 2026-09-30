# Exact child-environment fixture is changed by outer monitor injection

Status: open. RunQuota `ed40495`, Reprobuild run `36704362941`, Linux ARM64
job `109851362185`.

## Observed

The complete monitored compilation passes. The newly added
`t_isolated_environment` passes the inheriting-child control but fails its
exact isolated-child assertion. The child sees `RQ_TEST_DECLARED`, `LD_PRELOAD`
and `REPRO_MONITOR_EXEC_GEN`; the fixture requires only `RQ_TEST_DECLARED`.
The extra variables are the outer monitor's child propagation mechanism.
The failed fixture blocks the later measurement sequence.

This is observed on the deferred Linux ARM64 development lane, but its cause
is shared with monitored execution on other targets. It does not establish a
failure of the new production `CommandSpec.isolateEnvironment` implementation.

## Expected and repair plan

The exact environment contract is documented by
`libs/runquota_process/tests/t_isolated_environment.nim` and the public
`CommandSpec.isolateEnvironment` API in `libs/runquota_process/src/runquota_process.nim`.
Keep its assertion and the real inheriting/isolated child comparison intact.
Execute only this environment-owning fixture without an outer injected shim,
using the existing depfile disposition with `suppressMonitorShimSeed` and
`cacheable = false`. Compilation and every other fixture remain monitored.
[Monitor failure semantics](../../reprobuild-specs/Monitor-Hook-Shim.md#failure-semantics)
requires that incomplete monitor evidence cannot back a cache publication.
The declared depfile supplies ordering only, so the execution must always rerun.

Validate the same real binary under the original outer monitor (failure with
injected names) and without it (both assertions pass), then repeat the corrected
Reprobuild execution to prove it launches again. Keep the 600-second action
bound and existing native cross-checks.

Fetched dev `0bce530` and agents `ed40495`; both are included locally. Searched
open issues and complete issue history for `isolateEnvironment` and environment
isolation; the existing Windows environment-case issue describes a different
failure. The new test arrived with PR 33 at `ed40495`.
