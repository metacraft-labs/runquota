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

## Candidate validation

Linux x64 job `109851362121` at `ed40495` reproduces the identical names and
assertion. On macOS, the unchanged fixture binary built from `ed40495` has
SHA256 `ba790445792287b2296c6d86ed8c0648d652e0cf3f308df08e4a6ccf76248cb6`.
It fails under released io-mon `53994c0` with `DYLD_INSERT_LIBRARIES` and
`CT_SANDBOX_TOOLS_DIR` added, then passes both assertions in two native runs
with identical bytes.

The prepared recipe at `15ea4b5` plus the fixture-disposition patch passes
Nim checking against Reprobuild `c14b1e6`. Two real invocations of
`repro build .#runquota.test_execute.t_isolated_environment` both pass and
report `launched: true`, `cacheDecision: cdNotCacheable`, and
`dependencyPolicyKind: dgRecognizedFormat`. All compilation stays monitored;
the exact child-environment assertion and 600-second execution bound are
unchanged. The complete candidate matrix remains required.

## Final application qualification (2026-10-01)

The exact environment fixture passes with the selected uncached monitor-free execution. Compilation and other tests retain their existing monitoring.

These results are measured at `d6ee4588f71604376a4cc41ef281d6c479395efc`
in [run 36823482913](https://github.com/metacraft-labs/runquota/actions/runs/36823482913).
All application test programs pass on the five development hosts. The ARM
workflow still fails its subsequent, separate static-helper ACL gate; that
issue remains open and is not attributed to this repaired defect.
Ordinary [CI at `2d07c5d`](https://github.com/metacraft-labs/runquota/actions/runs/36846644651)
passes all ten jobs with unchanged application sources and fixtures.
