# Windows's memory cap exceeds the overhead gate's 1% CPU budget on `run-64`

| Field | Value |
| --- | --- |
| Status | Open -- confirmed by two independent gate runs; root cause (mechanism vs. this case's methodology) not yet isolated |
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

## Suggested direction

1. A longer-action variant of `run64RunWindows`'s `--run64-spin` worker
   (a configurable loop count, or a `--run64-min-millis` floor) to test
   whether the overhead shrinks as the action grows -- the cheapest way to
   tell the two candidate causes apart without touching
   `runquota_process.nim` at all.
2. If the overhead persists even against long actions, the mechanism
   itself needs profiling: which of the two `SetInformationJobObject`
   calls, the watcher thread's creation, or its join at teardown
   (`finalizeMemoryCap`) dominates.
3. Until resolved, Windows's `kill` mode should not be turned on by
   default; this is a decision for rq-reform-mgr / the operator, not one
   this driver can make unilaterally.
