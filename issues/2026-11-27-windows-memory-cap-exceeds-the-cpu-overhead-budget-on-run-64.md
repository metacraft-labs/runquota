# Windows's memory cap exceeds the overhead gate's 1% CPU budget on `run-64`

| Field | Value |
| --- | --- |
| Status | Root-caused and ruled on, 2026-11-28. NOT the Windows mechanism (the watcher thread profiles clean, 46.4us/launch; action-only CPU differential 0.36%). The ~1% is a cross-platform defect: `enqueueEstimateWrite` reachable from a finish's critical path (`issues/2026-11-28-memory-cap-learning-writes-on-the-finish-critical-path.md`), owned by rq-memcap. Windows `kill` mode stays off by default until a rerun shows zero after that fix |
| Observed in | `runquota` @ `bb8ef2a8d1513f7b984c66621252c3b9ca445a99` (`agents`); eli-pc (Windows 11 x86_64, 32 CPUs) |
| Area | `libs/runquota_process/src/runquota_process.nim` (`applyMemoryCapHard` / `applyMemoryCapNotification` / `startMemoryCapWatcher`), or `benchmarks/lib/runquota_overhead_gate.nim`'s `run64CaseWindowsMemoryCap` / `run64RunWindows` methodology -- which one is not yet established |
| Expectation | `RunQuota-Memory-Caps.md` § "The overhead rule": the 95% CI of the wall and CPU time difference must include zero at the gate's ±0.5% resolution; a mechanism whose interval excludes zero is rejected or made opt-in |

## Observed

Two `--case=run-64 --switch=memory-cap` gate runs on Windows, same host,
same commit, different round budgets:

1. Default policy (10-200 rounds, 1500 s). Stopped at the round limit,
   200 rounds, 1329.6 s: **inconclusive**. Wall time flat (0.25% overhead,
   [-0.98%, +1.49%]). CPU time: 2.39% overhead, **[+0.99%, +3.81%]** --
   almost entirely above the 1% budget, never reaching the required
   ±0.5% precision in 200 rounds.
2. `--max-rounds=600 --max-minutes=75`, to settle (1). The gate's own
   early-fail rule (module header, `statistics.decide`: "FAIL as soon as
   the LOWER bound of either metric exceeds the budget") fired at round
   32, 231.5 s: **fail**. CPU overhead 5.94%, **[1.35%, 10.74%]**. Wall
   time stayed flat and in budget (1.6% overhead, [-3.05%, +6.48%]).

Both runs' CPU intervals sit entirely above the 1% budget. Two different
round counts, two different point estimates (2.39% vs. 5.94%) -- not one
noisy reading, the same direction twice. Full detail (per-round figures,
JSON reports, host and commit) is recorded in
`reprobuild-pm` `spec/RunQuota-Memory-Caps.md` § "Verdicts".

## Why this matters

The operator's hard rule (relayed 2026-11-27, driver brief) is **no
measurable overhead**, verified by this exact gate and switch. A confirmed
fail here means Windows's `kill` mode, as currently built, cannot be
turned on by default without either fixing the cost or making it opt-in,
per the spec's own stated consequence.

## Suspected cause (unverified, two candidates)

1. **The mechanism itself.** Every capped launch does two
   `SetInformationJobObject` calls (`applyMemoryCapHard`,
   `applyMemoryCapNotification`) and spawns a watcher thread
   (`startMemoryCapWatcher`, a raw `CreateThread` that blocks on
   `GetQueuedCompletionStatus` until the run ends or a notification
   fires), joined again at teardown (`finalizeMemoryCap`). Each of these
   is cheap in isolation, but `run-64`'s actions are short.
2. **This case's methodology.** `run64LoopTurns` (150,000) makes each
   action well under a second. A fixed per-launch cost that would be
   negligible against a real multi-second build action can read as
   several percent against an action this short. Neither `run-64` with a
   longer action, nor `reprobuild-64` on Windows (its own follow-on,
   `issues/2026-11-27-overhead-gate-does-not-compile-on-windows.md`,
   "still open" -- that case's `/bin/sh -c` driver script has no Windows
   port yet), has been tried.

These are not mutually exclusive, and neither has been isolated: the
suspected cause needs a controlled comparison (same mechanism, a longer
action) before either is more than a guess.

## Update, 2026-11-27 (rq-memcap-win): the action itself was dead code

Attempting candidate 2's controlled comparison found a real bug first:
`serveRun64Child`'s spin worker (the Windows action) was a plain counting
loop with no observed result, and `-d:release` proved the whole loop had
no effect and removed it entirely -- measured directly, 2 BILLION claimed
iterations and 150,000 both completed in ~30 ms. Every Windows `run-64`
action, in both recorded verdicts above, did ZERO of the work its Linux
shell-loop counterpart does -- not merely a short amount of work, none.

Fixed (`runquota` `agents` `02c5ac3d`) by reusing `burn` (the `synthetic`
case's own anti-optimiser xorshift loop) and echoing its result the way
`serveSyntheticChild` already does; a first attempt that `discard`ed the
result instead was folded away for the identical reason (`burn`'s own
fold-resistance needs an observer, not an unfoldable loop body). Verified
by direct timing: time now scales linearly with the turn count (100M:
0.18 s, 1B: 1.2 s, 5B: 5.8 s, ~1.16 ns/iteration).

**With the fix**, a quick comparison at `run64LoopTurns` raised to ~1e9
(~1 s of real CPU per action instead of near zero) -- 8 rounds, stopped
by the 600 s time budget before reaching its own 20-round minimum, so
not a formal verdict -- showed **CPU overhead at 0.48%**, interval
[-2.30%, +3.34%], against 2.39% and 5.94% at the original near-zero
action length. One host-disturbance outlier in round 1 inflated the
wall-time reading (24% point estimate; the other seven rounds do not
support that). Suggestive, consistent with candidate 2 (methodology),
not yet conclusive. Recorded in `reprobuild-pm`'s
`spec/RunQuota-Memory-Caps.md` § "Verdicts".

## Suggested direction

1. A proper `--min-rounds`/`--max-rounds` run at a longer action length
   (enough rounds, enough time budget, to reach the gate's own required
   precision) to turn "suggestive" into a verdict. Whether that belongs
   as a permanent knob on `run-64` (a configurable loop count, or a
   `--run64-min-millis` floor) or is better served by `reprobuild-64`
   once it runs on Windows is still open.
2. If a precise run still shows overhead above budget even against a
   long action, the mechanism itself needs profiling: which of the two
   `SetInformationJobObject` calls, the watcher thread's creation, or its
   join at teardown (`finalizeMemoryCap`) dominates.
3. Until a precise run says otherwise, the recorded fail (above) stands;
   Windows's `kill` mode should not be turned on by default. That
   decision is rq-reform-mgr's / the operator's, not this driver's to
   make unilaterally.

## Update, 2026-11-27 (rq-memcap-win): a precision run, and the full picture

Ran the comparison again, `run64LoopTurns` raised to 100M (~0.1-0.2s of
real CPU per action, ~4.3s wall per round with all 64 concurrent), 200
rounds, 2008s. CPU overhead reached the gate's required ±0.5% precision
this time: **1.02%, interval [0.60%, 1.43%]** -- straddling the 1%
budget almost exactly. Per the gate's own rule that is neither a pass
(needs the upper bound in budget) nor an early fail (needs the lower
bound over it): a precise, genuinely ambiguous reading.

Across all three runs (near-zero dead-loop action: 2.39% and 5.94%;
~0.1-0.2s: 1.02% precise; ~1s: 0.48% noisy, 8 rounds), the trend is
real and monotonic in the two precise readings: overhead falls as the
action grows. Consistent with candidate 2 (a fixed per-launch cost
diluting with a longer action) but not conclusive that it reaches zero
-- a smaller fixed cost could still survive dilution. The watcher
thread (`startMemoryCapWatcher`) is the one candidate that would NOT
dilute with action length: one extra thread held for the action's whole
duration competes for the host's cores regardless of how long the
action's own work takes, unlike the two one-time
`SetInformationJobObject` calls.

**Not pursuing a fourth gate run unilaterally.** Three runs (23, 33 and
45 minutes) in one session establish the shape of the question; what
comes next -- a longer action still, profiling the watcher thread's own
cost specifically, or accepting/rejecting a residual cost under 1% -- is
a design decision, not one more data point. Flagged to rq-reform-mgr.
Full detail in `reprobuild-pm`'s `spec/RunQuota-Memory-Caps.md` §
"Verdicts".

## Resolution, 2026-11-28: root-caused, ruled on, not this driver's fix

Directed by rq-reform-mgr to profile the watcher thread directly rather
than guess further. A 2000-iteration micro-benchmark of
`startMemoryCapWatcher`/`stopMemoryCapWatcher`/`applyMemoryCapHard`/
`applyMemoryCapNotification` measured **46.4 µs total per launch** --
`stopMemoryCapWatcher` was already a true blocking join on the
completion port (`WaitForSingleObject(..., INFINITE)`), not polling, so
there was no polling-to-blocking conversion to make. 20-40x too small
to be the measured ~1-2 ms/action.

Decomposed the third follow-up's recorded data instead (splitting `cpu`
into its two components): daemon-only CPU differential **+2.47%**,
action-only (where the Windows mechanism would show up) **+0.36%**,
clean. The weighted blend (daemon ~31% of total CPU) matches the
recorded 1.01% total exactly -- **the overhead is almost entirely on
the daemon side**. Traced to `runquota_daemon.learnMemoryCapFromFinish`
reaching `runquota_persistence.enqueueEstimateWrite` on every finish
with a measured peak; the OFF arm never measures a peak (nothing else
is switched on) so it never reaches this, the ON arm's cap mechanism
inherently does. Filed as its own defect:
`issues/2026-11-28-memory-cap-learning-writes-on-the-finish-critical-path.md`
-- common `runquota_daemon`/`runquota_persistence` code, not
Windows-specific.

**rq-reform-mgr's ruling**: not a tradeoff against learning.
Persistence is specified as asynchronous and batched; a write reachable
from the action's critical path is a defect in that queue.
rq-memcap (owns learning) moves it off the critical path. Windows
`kill` mode stays off by default until a rerun of this gate shows zero
after that fix; this driver reruns it once the fix lands. Recorded in
`reprobuild-pm`'s `spec/RunQuota-Memory-Caps.md` § "Verdicts".
