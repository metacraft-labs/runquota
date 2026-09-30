# Windows ambient test expires after its CPU arm

Status: open. RunQuota `dda957b`, Windows x64 Reprobuild run `36684402030`,
job `109786852180`.

The complete build succeeds. Execution finishes 97 programs successfully and
times out `t_ambient_load_attribution` with exit 124 at the unchanged 600-second
limit. Its CPU arm passes with ratio 1.010; no memory result is printed.
The full-word random population introduced at `dda957b` is a possible cost:
the memory arm makes nine 4-GiB allocations, calling `next(random)` once per
64-bit word. The log does not yet locate the delay inside that arm.

[Observation Store M11](../../reprobuild-specs/RunQuota-Observation-Store.md)
requires measured foreign-load attribution. Keep the full allocation, all
cycles, assertions and the 600-second limit. Compare the actual fixture with
timed allocation boundaries and a bulk system-random fill, through the same
monitored recipe and compiler. A bulk fill must still touch every byte with
incompressible data; reverting to mostly-zero pages would undo the macOS
control correction.

Fetched dev `0bce530`, already included in the candidate, and searched open
and deleted issues for ambient Windows failures, memory population and timeouts.
The existing macOS memory issue concerns the measured resident-load ratio,
not expiration before a result. No timeout repair is claimed yet.
