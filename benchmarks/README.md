# RunQuota Benchmarks

Run `just bench-quick` for the abbreviated M0 benchmark suite or `just bench`
for the full M0 suite. The M0 suite measures real repository operations:
source enumeration, focused Nim checks, and static helper compiles.

Outputs:

- `bench-results/benchmark_results.json`
- `bench-results/report.html`

## The measurement overhead gate

`just bench-overhead-gate [CASE] [options]` asks whether RunQuota's
measurements (the observation store, the ambient sampler, the launching
client's tree sampling, and the measurements registered for later) slow a
build by more than 1%, in wall time or in CPU time. It runs the case with
every measurement off and with every implemented measurement on
(`--measure=NAME` for one alone), switched by `runquotad --measurement` and
`RUNQUOTA_MEASUREMENT` against a private daemon per arm, and repeats until the
95% interval of the difference is within ±0.5%:

- rounds are paired and interleaved (off-on, on-off, ...); the unit is
  `ln(on / off)` per round, so a slow round is slow in both arms;
- the interval is Student's t on the mean of those log-ratios;
- **fail** as soon as a lower bound exceeds 1%; once both intervals are within
  ±0.5%, **pass** if both upper bounds are within 1%, **fail** otherwise;
- **inconclusive** if `--max-rounds` (200) or `--max-minutes` (90) runs out
  first. That is not a pass.

CPU time is the build process and everything it waited for (`wait4` rusage)
plus the arm's daemon's CPU, its own and its reaped `sqlite3` children's,
from the start of the run until the daemon has gone quiet after it, so work
the daemon finishes after the build has exited is counted too.

Cases:

| Case | Workload | Status |
|---|---|---|
| `reprobuild-64` (default) | `benchmarks/fixtures/reprobuild-64-actions`: 64 independent CPU-bound actions, Reprobuild in-process, against the arm's daemon | implemented; needs a `reprobuild` engine built against this checkout (`REPRO_ENGINE`, see `scripts/run-overhead-gate.sh`) |
| `cargo-jobserver` | a wide cargo test under `runquota jobserver` | unavailable until `runquota jobserver` exists; exits 4 |
| `synthetic` | the gate's own instrument check: fixed CPU burns, with `--inject-percent` and a periodic `--disturbance-percent` | used by `tests/integration/t_overhead_gate_detects_overhead.nim` |

Exit status: 0 pass, 1 fail, 2 usage, 3 inconclusive, 4 case unavailable,
5 a run could not be measured. The JSON report goes to
`bench-results/runquota-overhead-gate-<case>.json` with every round, the
switch text of each arm, the measurements that are not implemented (and so
not measured), the daemons' own report of what they measured, and host load
and CPU pressure at start and end. `RUNQUOTA_GATE_CPUS` pins the run to a
`taskset` CPU list.
