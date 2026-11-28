# The estimate-store writer durably rewrites a pending row every ~50ms flush interval, even when it has not changed

| Field | Value |
| --- | --- |
| Status | Open -- root cause corrected 2026-11-28 by rq-memcap (via rq-reform-mgr); fix approved and in progress, owned by rq-memcap |
| Observed in | `runquota` @ `1b5ca6a0` (`agents`); found via the Windows overhead gate, but the defect is OS-agnostic |
| Area | `libs/runquota_persistence/src/runquota_persistence.nim` (`writerMain`, the estimate store's 50ms background flush loop) |
| Expectation | A learned figure should be written durably when it changes in a decision-relevant way, or at most once per key per interval -- not every interval a key happens to be pending, regardless of whether anything changed |

## Corrected, 2026-11-28

The original filing of this issue (titled "...writes on the finish
critical path") was wrong about the mechanism, caught by rq-memcap
reading the code at `1b5ca6a0`: **the finish does NOT wait on the
write.** `enqueueEstimateWrite` only appends (or replaces an existing
entry for the same key) in a small bounded in-memory queue
(`writerPending`), under a lock held only for that append -- genuinely
cheap, and never on the finish's own critical path. The actual durable
write happens on the daemon's background writer thread
(`writerMain`), exactly as the persistence layer is specified:
asynchronous and batched.

## Observed (corrected)

`writerMain` wakes every 50 ms, takes whatever is currently pending (at
most one entry per key, since `enqueueEstimateWrite` replaces rather
than duplicates), and -- if anything is pending at all -- commits a real
SQLite write for it. It does this **every interval a key has anything
pending, with no check for whether the row's figures actually changed
since the last flush**. Under the Windows overhead gate's
`--switch=memory-cap` comparison, the ON arm's cap mechanism measures a
peak on every action's finish (to enforce the cap and to learn from it),
so `run-64`'s continuous stream of capped actions keeps the command's
estimate key pending across many consecutive 50 ms windows for the
whole run -- and because the synthetic action's own peak does not
change between actions, the SAME figure is committed to SQLite over and
over, dozens of times a second of wall time, with no new information in
any of the repeats. The OFF arm never enqueues anything (no peak is ever
measured there), so it pays none of this.

This showed up as a measured daemon-only CPU differential of +2.47%
against an action-only (launcher-side) differential of +0.36% in the
Windows overhead gate's third follow-up run (`reprobuild-pm`'s
`spec/RunQuota-Memory-Caps.md` § "Verdicts" has the full run-by-run
detail); the weighted blend of the two matches the recorded 1.01% total
overhead exactly. Nothing about the writer loop is Windows-specific --
a Linux `run-64 --switch=memory-cap` run precise enough to isolate
daemon CPU from action CPU the way this one did should show the same
cost, for the same reason.

## Fix (approved, in progress, owned by rq-memcap)

Write durably only when a decision-relevant figure actually changes,
otherwise at most once per key per interval, with a flush on a clean
stop (so a real, final change is never lost to the daemon exiting
between flushes).

## Status

Windows `kill` mode stays off by default (already true: `[enforcement]
memoryCap` has no default) until a rerun of the overhead gate shows
zero after this fix lands. `rq-memcap-win` reruns the Windows gate once
it does.
