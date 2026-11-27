# The overhead gate does not compile on Windows at all, so no `--switch` verdict can be measured there yet

| Field | Value |
| --- | --- |
| Status | In progress -- the gate builds and runs `synthetic` end to end on Windows (`runquota` agents, see 2026-11-27 progress below); `--switch=memory-cap` on `run-64` is Linux-only by design and still needs a Windows arm |
| Observed in | `runquota` @ `7c98da54` (`agents` tip); Nim 2.2.8 + WinLibs gcc 16.1.0, eli-pc (Windows 11 x86_64) |
| Area | `benchmarks/lib/runquota_overhead_gate.nim`; `benchmarks/lib/runquota_overhead_gate/process_cost.nim` |
| Expectation | RunQuota-Memory-Caps.md's § "The overhead rule" directs each new enforcement mechanism to be judged with this gate, naming a Windows arm (`--switch memory-cap`) explicitly, "each on its own platform, by its driver." |

## Observed

`nim check` on `runquota_overhead_gate.nim` passes on Windows (the module's
unconditional `import std/posix` type-checks fine there -- `std/posix`
degrades to an effectively empty module off POSIX rather than refusing to
compile). A real `nim c` build does not:

```
.nimcache\...\@mrunquota_overhead_gate.nim.c:12:10: fatal error: sys/wait.h: No such file or directory
.nimcache\...\@mrunquota_overhead_gate@sprocess_cost.nim.c:12:10: fatal error: sys/resource.h: No such file or directory
```

`process_cost.nim` is the direct cause: it imports `wait4(2)` from
`<sys/wait.h>` and `Rusage` from `<sys/resource.h>` unconditionally, with no
`when defined(windows)` branch at all (confirmed: the whole file has no
Windows-specific code; its only `when defined(linux)` guards are narrower,
inside the POSIX-only body). Nothing stands between a Windows build of the
gate and that header, so the C codegen simply fails every time, before any
case or switch runs.

The module doc comment is accurate but easy to read past: "Linux is the
platform this has run on. The macOS code paths compile but have not been
run." Windows is not mentioned because there is no Windows code path to
mention -- it is not a matter of the gate being unverified on Windows, it
does not exist there yet.

## Why this matters now

RunQuota-Memory-Caps.md's overhead rule names this gate, with a Windows arm
of `--switch memory-cap`, as the way to judge whether the Windows memory-cap
mechanism (`PROC_THREAD_ATTRIBUTE_JOB_LIST` job creation, the hard and
notification limits, the watcher thread) costs anything measurable. That
judgment cannot be produced until `runquota_overhead_gate` -- and at least
`process_cost.nim`'s child-cost reading -- gets a Windows implementation
(a `GetProcessTimes` / Job Object accounting equivalent of `wait4`'s
`Rusage`, mirroring the pattern `runquota_process.nim`'s own Windows arm
already uses for its accounting).

## Suggested direction

Port `process_cost.nim`'s child-cost reading to Windows first (its own
focused task, narrower than the whole gate); then confirm the rest of
`runquota_overhead_gate.nim` and its `--case` arms (`synthetic` at least,
which needs no cgroup root or CLI binary) build and run on Windows before
adding a `memory-cap` switch arm there. Until this lands, a Windows
verdict for any enforcement mechanism can only come from an ad hoc,
non-statistical timing comparison outside the gate -- not the same
guarantee the gate's confidence-interval methodology gives the Linux and
(once run) macOS verdicts.

## Progress, 2026-11-27 (rq-memcap-win)

`process_cost.nim` itself now builds and runs on Windows (`runquota`
agents `2f00d634`): `spawnChild`/`runMeasured` place the measured child in
a fresh, limitless Job Object at creation
(`PROC_THREAD_ATTRIBUTE_JOB_LIST`, the same mechanism the production
launcher uses) and read `TotalUserTime`/`TotalKernelTime` from it --
Windows has no `wait4`-style aggregation of a reaped child's own
descendants, so without the job a grandchild's CPU would be invisible to
`cpuSeconds` exactly the way the module header already warns a daemon's
reaped `sqlite3` child would be if `/proc` weren't read. `processCpuSeconds`
(for the daemon's own pid) and `loadAverage` get Windows arms too (the
latter returns `""`: Windows has no load-average concept). Verified
against a real grandchild-forking workload (a direct child that only
waits on a burning grandchild): `cpuSeconds` reads the full burn, not
~0, with a control (no job at all) that would show the gap if the job
accounting weren't wired correctly.

**Found and fixed along the way**, in both this file and
`runquota_process.nim`'s own `buildWindowsEnvBlock`: an environment block
built from zero entries is a single-NUL block, which `CreateProcessW`
refuses with `ERROR_INVALID_PARAMETER` -- it needs a double-NUL to mean
"zero variables," and with no entry there is nothing to borrow the second
null from. This is reachable in production (`CommandSpec(inheritEnv:
false)` with no declared `env`), had no test coverage (every existing
isolated-environment test happened to declare at least one variable), and
is now fixed and covered by a regression test with its own falsifying
mutation.

## Progress, 2026-11-27 (rq-memcap-win), part 2 -- the main gate file now builds and runs

`runquota_overhead_gate.nim`'s own unconditional `import std/posix` was
the next blocker: on Windows it falls back to `posix_other`, which still
declares `Pid` and a long list of POSIX procs with `importc`/`header`
pragmas naming headers Windows does not have, and that `Pid` is now
ambiguous against `process_cost.Pid`. Importing `std/posix` only under
`when defined(posix)` fixes the ambiguity (Windows gets `process_cost.Pid`
alone). `stopDaemon`/`startDaemon`'s direct `kill`/`waitpid` calls are
replaced with a small cross-platform surface
(`daemonTerminate`/`daemonKillNow`/`daemonTryReap`/`daemonReapBlocking`,
`process_cost.nim`) instead -- Windows's versions reopen the process by
pid for `TerminateProcess`/`GetExitCodeProcess`/`WaitForSingleObject`
rather than keeping a creation-time handle alive, since the daemon is
meant to outlive the call that started it. `gateCgroupRoot` and
`migrationProbe` are cgroup v2 / Linux-only by nature (their only callers
already refuse off Linux), gated behind `when defined(linux)` with a
defensive raise on the unreached arm instead of failing the whole file's
C codegen.

**Verified end to end**: built the real `runquota`/`runquotad` binaries
from source on Windows (`nim c --threads:on`, no changes needed to either
app), then ran `runquota_overhead_gate.exe --case=synthetic` to
completion -- real measurement, real statistics, real JSON report,
correctly `INCONCLUSIVE` at a deliberately short burn/round count (too
little signal for the required precision, which is the gate's own
correct answer, not a failure).

**Still open**: `--switch=memory-cap` on `run-64` refuses outright off
Linux (`when not defined(linux): raise CaseUnavailable`), by design --
the module's own doc comment says the switch judges the mechanism "one
stage of its Linux mechanism at a time" with cgroup-rooted arms
(`gateCgroupRoot`/`armRoots`), and its probe script is `/bin/sh -c`.
Windows's mechanism has no stages (the spec's own words: "job creation
for every tree, and the limit," one comparison, not several) and no
cgroup root to place arms under, so a Windows arm is a parallel branch in
`run64Case`, not a small patch to the existing one -- its own follow-on,
not attempted here. `reprobuild-64`'s driver script
(`run64Script`/`memoryCapProbeScript`) is also `/bin/sh -c`-based and
would need a Windows-shell equivalent for that case specifically,
independent of the memory-cap switch.
