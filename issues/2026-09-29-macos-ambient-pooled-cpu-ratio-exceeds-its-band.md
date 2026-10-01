# macOS ambient CPU control exceeds its pooled ratio band

Status: open. Observed at RunQuota `1d381e5`.

## Observed

Complete graph control
[36607798283](https://github.com/metacraft-labs/metacraft-github-actions/actions/runs/36607798283)
at shared `7336b46` builds fresh apps, then runs all 198 actions on the standard
macOS 26 ARM64 runner. The ambient-load test is the only failed action; the
later native-process telemetry action is blocked. The same telemetry binary
passes all three checks when run directly afterward.

The CPU control reports initial host use of 1.0%, one spinner, OFF median
7.93%, ON median 72.20%, independently measured process load 32.45 percentage
points, and pooled ratio 1.98056 against the unchanged upper bound 1.8.
Both groups contain 36 samples. Its separately reported paired ratio is
0.990 across 14 pairs. Every other assertion in this program passes.

## Expected and investigation

[RunQuota Observation Store / ambient_samples](../../reprobuild-specs/RunQuota-Observation-Store.md#ambient_samples)
requires real host-wide totals and separation of self and foreign work.
The fixture's documented liveness gate requires a real kernel counter to
respond to its synthetic load. This observation does not establish a product
accounting defect or identify the source of the pooled/paired disagreement.

Preserve the current thresholds and host-headroom checks. Compare unchanged
real binaries natively and under monitoring, and retain the per-window sample
groups and independent process CPU measurements. Determine whether unrelated
host work, monitor overhead, sample selection or accounting explains the
disagreement before changing the gate. A later passing run alone is not a
diagnosis of this failure.

Refreshed dev `e9f9011` and searched open and deleted issues for pooled ratios,
pairing and ambient CPU measurement. The earlier three-core oversubscription
issue concerns two spinners exceeding the load ceiling; this run uses one
spinner and satisfies that ceiling. The shared-host saturation issue concerns
missing initial headroom; this run satisfies the headroom precondition.
