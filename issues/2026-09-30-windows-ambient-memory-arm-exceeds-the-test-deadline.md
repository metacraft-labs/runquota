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

## Confirmed cause and candidate

The same timeout recurs at `c371915`, job `109796870562` in `36687563185`.
Control `36692312223` at shared actions `0a6fbed` compares the complete real
fixture at that source on the same Windows x64 host and compiler. The original
fills take 138,036, 143,352 and 156,377 ms; execution hits exit 124 during the
fourth fill. The bulk system-random variant executes successfully with all
five tests, nine allocations, assertions and the 600-second limit retained.
The bulk fills take 1,899–1,967 ms and the measured memory ratio is 0.999.
Both report a real launched action. The completed ARM-host comparison in
that run also reproduces the original 600-second timeout during its third
fill, after fills of 254,871 and 255,045 ms. Bulk filling passes all five real
tests with all nine allocations, 1,625–1,729 ms fills and a 0.999 memory ratio.
Candidate `8322c3f` incorporates that repair; its ordinary Windows x64 job
is blocked before this fixture by the separate completion-latency control.

The candidate uses 4-MiB `std/sysrand.urandom` chunks, filling every byte
without overflowing the Windows API's 32-bit length. A failed fill frees its
mapping before propagating the error. The same bulk control passes all five
real tests on macOS, with a 0.906 memory ratio and 1.5–1.6-second fills.
Complete ordinary CI at the final candidate remains required.
