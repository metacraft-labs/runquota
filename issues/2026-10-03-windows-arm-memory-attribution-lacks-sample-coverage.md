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

## Windows x64 timing evidence and repair design

At `1915b28670f1df1722def660817ba2d8a2bcc4a8`, native Windows x64 Reprobuild
job [111186935291](https://github.com/metacraft-labs/runquota/actions/runs/37117429003/job/111186935291)
fails the unchanged released-state requirement: two rows instead of at least
three in the 2.5-second observation window. The memory control in that same
process passes, but measures 140 host reads taking 0.391 seconds total (maximum
14.2 ms), and 35 flushes taking 9.879 seconds total (maximum 1.202 seconds).
`samplerMain` calls `flushAmbientQueue` synchronously after every flush interval,
so those database calls suspend sampling. This establishes a scheduling defect;
it does not yet prove that it explains the earlier ARM64 result.

Repair design, within the authorized LOCAL-4 follow-up:

- Keep the actual host-counter reads and attribution on the sampler thread.
  Give database publication its own worker, signaled at the existing flush
  cadence. Database contention must not stop host observations.
- Use a bounded queue of process-owned statement bytes so a drained batch never
  refers to the sampler thread's ORC allocator after that thread exits. Preserve
  timestamps, ordering, the existing capacity, and all dropped/failed counters.
- Stop and join the sampler first, then signal the writer to drain the final
  batch and join it before resetting any shared state. Failed database writes
  remain counted losses; no invented samples or retry timestamps.
- Qualify with a real SQLite write transaction held by another process: sampling
  must continue while publication is blocked, then all accepted rows must settle
  before stop returns. Exercise bounded overflow and failed publication too.
  Retain all existing load windows and minimum coverage assertions.

## Local qualification of the writer repair

At `6aef188f0dc30b73c34b2ddffcdd869b06c79a2d` plus the separate-writer
patch, `just lint`, `just test` and `just test-release` succeed on macOS ARM64.
Each test mode compiles and runs all 104 programs, with 522 passing cases and
zero failed, timed-out or skipped programs. The existing platform-specific case
skip remains. Both static-helper checks pass in the same combined command.

The three new real-SQLite controls pass with queue capacities 128 and one,
including overflow accounting, shutdown draining and foreign-key rejection.
Putting the database flush back on the sampling thread makes both contention
controls fail with zero ticks during the blocked write; the small-capacity
control also rejects the missing overflow. The mutation was restored. Windows
C generation succeeds; native Windows runtime qualification remains required.

The new timing test joins the existing serialized measurement group in the
Reprobuild graph so concurrent load generators cannot invalidate its control.
No existing sampling window, cadence, sample-count or ratio requirement changes.

## macOS contention control needs timing attribution

At `0d4c8cd810c9aeb0d217c63d7c515c31eabb5ece`, native macOS job
[111201933293](https://github.com/metacraft-labs/runquota/actions/runs/37122709511/job/111201933293)
runs all 104 programs and fails the new capacity-one contention case: nine
sampler ticks in its 1.2-second window, below the unchanged minimum of ten.
Capacity 128 records thirteen ticks and passes. Publication remains blocked.
The existing memory-attribution cases pass. Linux x64 and ARM64 native suites
pass at the same source.

The contention control now prints the actual monotonic window length, host-read
time during that window and maximum host-read time. At `0d4c8cd8` plus this
instrumentation, five local macOS runs pass all three cases, recording 20–21
ticks per contention window. Host reads occupy about 1–2 milliseconds in each
window. This does not establish why the CI runner sampled more slowly.

The sampler currently sleeps a full cadence after each iteration, so host-read,
formatting and scheduler delays accumulate. The fixed-cadence requirement in
Observation Store §ambient_samples supports budgeting waits against monotonic
deadlines. Investigate this separately from SQLite publication; do not identify
it as the CI cause without evidence, change the test window, lower the minimum
count, invent readings or manufacture timestamps to fill missed intervals.
