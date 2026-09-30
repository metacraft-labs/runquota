# macOS ambient attribution controls fail at window and memory boundaries

Status: open. Observed at RunQuota `8cf662c`.

## Observed

Native run `36643299540`, job `109660392857`, and Reprobuild run
`36643299557`, job `109660392938`, fail the same clamp assertion: a selected
row carries the ordinary self report (10% CPU and 4.5 GB), although the test
expects the additional runaway report (410% and 516.5 GB). The real sampler
already reads host counters and self reports under one lock. The test selects
both endpoints of a window after truncating its wall clock to milliseconds,
then removes the runaway report immediately after taking the ending time.
Retain row timestamps and transition times to distinguish an incorrectly
selected boundary row from a product attribution failure.

The monitored memory arm measures 0.953 GB against its declared 4 GiB load,
a ratio of 0.222 below the unchanged 0.25 floor. Its allocation writes one
random byte per 4096 bytes, leaving almost all bytes zero despite the comment
claiming an incompressible load. On ARM macOS a native page is also larger
than 4096 bytes. Verify actual resident footprint and host-counter movement
with the original and fully populated allocations before changing the fixture.
Do not relax the liveness band or the exact attribution assertions.

## Expected

[Observation Store / ambient_samples](../../reprobuild-specs/RunQuota-Observation-Store.md#ambient_samples)
requires self figures from live reports and foreign figures from the
nonnegative residual. The real-load test must measure an allocation that
actually remains resident and select samples from the state interval it
claims to observe. The deterministic unit suite retains exact arithmetic and
clamp controls.

Fetched dev `0bce530` and searched open and resolved clamp, timestamp,
compression and window-boundary issues. Earlier CPU sizing and pooled-ratio
issues describe different assertions and are retained separately.

## Real comparison and candidate repair

Control `36681906030` at shared `49df90b` compiles the original `8cf662c`
fixture with post-measurement timestamp output, and a variant that fills every
64-bit word with random data and selects strict interior millisecond bins.
All four full fixture runs pass (two per variant). Thus this control does not
reproduce the original failure. The original memory ratios are 0.302 and
0.749; the populated variants measure 0.694 and 0.692. Every existing sample
count, liveness band and exact arithmetic assertion is unchanged.

The candidate applies those fixture corrections and retains sample/window
identity in failed clamp assertions. A millisecond that straddles the window's
end can also contain the immediately following report removal; it cannot
unambiguously represent the earlier state. The complete native and monitored
macOS suites remain required. Keep this issue open until those results arrive;
do not claim this passing comparison alone proves the earlier root cause.
