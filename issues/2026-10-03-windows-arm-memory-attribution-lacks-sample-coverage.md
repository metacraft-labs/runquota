# Windows ARM64 memory attribution test lacks sample coverage

Status: open; blocks the v0.1.1 promotion at `874702e`.

## Observed

RunQuota `874702ea3151d40d985a972562edd0a5f69f2e3a` fails the Windows
ARM64 x64-emulation Reprobuild test job
[110917251406](https://github.com/metacraft-labs/runquota/actions/runs/37030911036/job/110917251406).
`foreign_rss_bytes tracks a known synthetic memory load` in
`tests/integration/t_ambient_load_attribution.nim` fails two preconditions:

- `fullRows.len >= 9`: only seven full-window samples were recorded.
- `paired.len * 2 > memoryCycles`: only three pairs survived nine cycles.

The reported memory ratio is 0.998 and pooled ratio 1.001, with 14 empty-window
and seven full-window samples. These values do not qualify the result because
the required sample coverage was not established. The other three cases in
this test program pass. No root cause is established from this log alone.

## Expected and investigation

[Observation Store / ambient_samples](../../reprobuild-specs/spec/RunQuota-Observation-Store.md#ambient_samples)
requires sampled host usage and its attribution. This real-load fixture must
first collect enough observations of both allocation states for its estimator.
The existing count and majority requirements remain enforced.

Reproduce with the Windows ARM64 host, x64 compiler and monitored execution
used by the failed job. Preserve sample timestamps, allocation-window bounds,
sampler read durations and publication timing to distinguish delayed sampling
from incorrect window selection or persistence. A bounded wait for observed
state may be appropriate if the timing evidence supports it; investigate
product scheduling if the sampler itself stalls. Retain the allocation size,
sample-count requirements, majority requirement and memory liveness checks.

The sample-count and majority assertions predate this release work. In
particular, the majority assertion comes from `cad25b0` on 2026-08-21.
The existing macOS window/compression issue concerns different failures.

## Archive search

Fetched `dev@052e7fe` and `agents@c965d25`; the latter includes the current
mainline. Searched open records and deleted issue history for `fullRows.len`,
`paired.len * 2`, memory-cycle coverage and the observed sample counts.
No existing issue records this Windows ARM64 failure. The local retained
CI log is `/tmp/runquota-011-windows-arm-failure.log`.

## Portable diagnostics prepared on macOS

The sampler now exposes monotonic counts, total time and maximum time for its
actual host-counter reads and database flushes. The existing memory control
prints that snapshot, sampler outcome counts, all nine allocation-window bounds
and every persisted sample timestamp. New checks connect the timing counters to
real sampling and publication. Allocation size, all observation/settling waits,
sample selection, minimum counts, majority and ratio assertions are unchanged.

At `11cc0aa702ebf6435a15fbe5949b20e4b1b724d3` plus this diagnostics patch, the
focused macOS ARM64 memory test passes with 195 sampler reads, 160 persisted
samples, 22 empty-window and 26 full-window rows, and nine valid pairs. Maximum
host read is 65,709 ns; maximum flush is 33,792,958 ns. This qualifies the
diagnostics on macOS, not the Windows sampler or the cause of its missing rows.

The next Windows ARM64 run must use these diagnostics with the original gates.
This issue remains open until that run establishes the required coverage.
