# Ambient load fixture exceeds its ceiling on a three-core runner

| | |
|---|---|
| Status | in-progress; fix/release-validation-failures |
| Recorded | 2026-09-29 |
| Observed in | RunQuota `292e578`, job `109375131970` |
| Area | `t_ambient_load_attribution.nim`, `spinnersForHeadroom` |

## Observed

The native macOS run starts two CPU spinners on three logical cores. Its
independent process CPU measurement is 65.72% of host capacity, exceeding the
fixture's 60% ceiling. Attribution itself measures 66.03%, a ratio of 1.005.
`spinnersForHeadroom` imposes a minimum of two even when half the machine is
only one core. All other assertions in that run pass.

## Expected

The real-load gate described in the header of
`tests/integration/t_ambient_load_attribution.nim` requires measured load in
the 8–60% range and bounded waiting for available headroom. The fixture must
size its load for the host. Use a minimum of one spinner while retaining
every load-range, headroom and attribution assertion. Run the complete native
suite on a three-core macOS runner to validate the measurement.

## Evidence

Shared-actions run `36559025544`, job `109375131970`, records the core count,
spinner count, CPU times and assertion. Refreshed `origin/dev` at `e9f9011`
and searched open/deleted issues for headroom and `spinnersForHeadroom`.
The earlier busy-host fixture repair does not cover the minimum core count.
