# runquota_stats_table

The **published aggregate table**: `runquotad` writes the current aggregate
for hot stats keys into a host-wide shared-memory segment as it folds in each
run's results, and a client reads its admission estimate from there with
**zero syscalls** — no socket round trip.

Normative format and algorithm:
`reprobuild-specs/RunQuota-Shared-Memory-Structures.md` §"Structures Not Yet
Built", the published-aggregate-table entry. Rationale:
`RunQuota-Shared-Memory-Transport.md` §1b and §"Trust and the privilege
boundary". Transport choice: `RunQuota-Observation-Store.md` §"Query
Interface" → Transport.

## The one thing to keep true

**It is a cache, not a second source of truth.** The socket interface of M13a
can answer anything this table can, and no behaviour anywhere may exist only
while an entry is resident. That is what lets the table be dropped, resized,
zeroed or skipped entirely without any correctness argument at all.
`tests/integration/t_stats_table_cache_control.nim` forcibly empties the
table and requires every store gate and every client gate to keep passing.

## Two modules, and the split is the enforcement

- `runquota_stats_table` — the **reader**. Maps the segment `PROT_READ` from
  an `O_RDONLY` descriptor, so a client cannot write it even by mistake;
  `lookupEstimate` never blocks and never fails. Absent key, stale entry, a
  torn read whose retry budget ran out, no segment at all — every one of them
  means "ask over the socket, or use your own default".
- `runquota_stats_table/publisher` — the **writer**, `runquotad`'s only. It
  never loads a byte back from the segment: placement, eviction victims and
  the per-slot sequence numbers all come from a shadow in the daemon's own
  private heap. That is how "the daemon MUST NOT read the table back as
  authority" is made structural rather than careful.

`tests/unit/t_stats_table_rules.nim` scans the tree and fails if anything
outside `runquota_daemon` / `apps/runquotad` imports the publisher.

## The seqlock, and why it is written out longhand

Per entry, not global, so a writer updating one key never stalls a reader of
another. Even-odd counter; the writer bumps to odd, writes **key and
payload**, bumps to even; the reader loads the counter, reads, re-loads and
retries on an odd or changed value.

Three things MV3's models established before this was written, all now
normative in the structures spec:

1. **The counter is a full word.** `s2 == s1` proves the payload was stable
   only because the counter cannot return to a value it has left. On a narrow
   counter the shipped protocol violates `NoTornRead` at depth 19. A bounded,
   fixed-size-entry table is exactly where someone packs the counter in
   beside a key hash to save room.
2. **The key lives inside the seqlocked region and the reader re-checks it.**
   Open addressing forces this on its own: a probe for K may legitimately
   land on a slot holding K′. Eviction written as a round then makes rebind
   safe for free.
3. **The C11 rendering needs relaxed atomics and two explicit fences** — a
   release fence before the closing bump, an acquire fence before the
   re-load. "Retry on an odd or changed count" has nowhere to put them, and
   the relaxed variant of either ordering pair is *Allowed on C11 and ARMv8
   and Forbidden on x86-TSO*: a defect here is invisible to any amount of
   x86 testing and live on ARM.

## Depends on `nim-shm-lease`

This is the first thing in `runquota` to do so, and the dependency is wired
here rather than assumed: `flake.nix` carries the input, `config.nims` puts
its `src` on the path from `SHM_LEASE_SRC` with a workspace-sibling fallback.
Boot id, process start time and the pid-reuse-proof liveness verdict come
from `shm_lease/anchor`; the page size from `shm_lease/waitword`; the
kernel-maintained syscall counter the zero-syscall gate is measured with from
`shm_lease/syscount`. None of them is reimplemented here.
