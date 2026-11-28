# The memory-cap learning write is reachable from a finish's critical path, not off it as persistence specifies

| Field | Value |
| --- | --- |
| Status | Open -- ruled on by rq-reform-mgr 2026-11-28; owned by rq-memcap (learning) |
| Observed in | `runquota` @ `12a01fab` (`agents`); found via the Windows overhead gate, but the defect is OS-agnostic |
| Area | `libs/runquota_daemon/src/runquota_daemon.nim` (`learnMemoryCapFromFinish`); `libs/runquota_persistence/src/runquota_persistence.nim` (`enqueueEstimateWrite`, the estimate store's writer queue) |
| Expectation | RunQuota's persistence is specified as an asynchronous, batched write queue -- a write reachable from the action's own critical path is an implementation defect in that queue, not an accepted cost of learning (rq-reform-mgr, 2026-11-28) |

## Observed

The Windows `--switch=memory-cap` overhead gate (`run-64`) measured a CPU
differential that would not go away as the action's own work grew (see
`reprobuild-pm`'s `spec/RunQuota-Memory-Caps.md` § "Verdicts" for the full
run-by-run detail). Profiling `runquota_process.nim`'s watcher thread
directly (a 2000-iteration micro-benchmark of
`startMemoryCapWatcher`/`stopMemoryCapWatcher`/`applyMemoryCapHard`/
`applyMemoryCapNotification`) measured 46.4 µs total per launch -- 20-40x
too small to be the cost. Decomposing the gate's own recorded data
instead localized it: daemon-only CPU differential +2.47%, action-only
(where the Windows mechanism itself would show up) +0.36%, clean. The
weighted blend (daemon ~31% of total CPU) matches the recorded 1.01%
total overhead exactly.

Traced to `learnMemoryCapFromFinish`: on a finish whose memory-cap block
reports a measured peak (`measuredSuccess`: the finish succeeded, the
block is present, nothing breached), it reaches
`enqueueEstimateWrite`, which does real work -- encoding the row,
taking `writerLock`, scanning the pending queue, inserting or replacing
an entry -- on the CALLER's own thread, i.e. the thread handling the
finish. The actual SQLite commit happens on a separate writer thread
started by `startEstimateStore`, but it is the SAME daemon process, so
its CPU still counts toward the daemon's measured total; more directly,
the caller-side encode-and-enqueue work itself is on the finish's own
path, which is what the gate's blocking client/daemon round-trip
actually measures.

This is reachable on every OS: the OFF arm in the gate's comparison
never measures a peak at all (no other switch is on), so it always
takes `learnFromFinish`'s early return and reaches none of this; the ON
arm's cap mechanism inherently measures the peak (to enforce the cap and
to learn from it), so every capped action's finish reaches it. Nothing
about the write itself is Windows-specific -- a Linux `run-64
--switch=memory-cap` run precise enough to isolate daemon CPU from
action CPU the way this one did should show the same cost.

## Ruling (rq-reform-mgr, 2026-11-28)

Not a tradeoff against the learning feature: RunQuota's persistence is
specified as an asynchronous, batched write queue, so a write reachable
from an action's own critical path is a defect in that queue's
implementation, not an accepted cost of learning. rq-memcap (owns
learning) is moving it off the critical path. Windows `kill` mode stays
off by default (already true: `[enforcement] memoryCap` has no default)
until the overhead gate shows zero after the fix; `rq-memcap-win` reruns
the Windows gate once it lands.

## Suggested direction

Not this driver's fix (owned by rq-memcap). The general shape: whatever
on the finish's own handling path currently does real work synchronously
for `enqueueEstimateWrite`'s caller-side half (the encode, the lock, the
queue scan/insert) should be queued without doing that work inline, or
the work itself should be cheap enough not to matter -- consistent with
the persistence layer's own stated design (asynchronous, batched), which
this call site does not currently honor for the caller.
