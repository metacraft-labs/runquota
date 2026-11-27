# The overhead gate does not compile on Windows at all, so no `--switch` verdict can be measured there yet

| Field | Value |
| --- | --- |
| Status | The Windows `--switch=memory-cap` arm on `run-64` now runs end to end against real `runquota`/`runquotad` binaries (see "part 3" below); a full-precision verdict run is in progress, to be recorded in RunQuota-Memory-Caps.md § "Verdicts" |
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

**Still open (narrowed)**: `reprobuild-64`'s driver script
(`run64Script`/`memoryCapProbeScript`'s POSIX-only use there) would need a
Windows-shell equivalent for that case specifically, independent of the
memory-cap switch, and remains unattempted. `--switch=memory-cap` on
`run-64` is no longer Linux-only -- see below.

## Progress, 2026-11-27 (rq-memcap-win), part 3 -- the Windows
`--switch=memory-cap` arm on `run-64`, running end to end

`run64CaseWindowsMemoryCap` (`runquota_overhead_gate.nim`) is the Windows
sibling of the Linux cgroup-stage arm, written separately rather than
forced into the same function: the mechanism has no stages (the spec's
own words, § "The overhead rule": "job creation for every tree, and the
limit," one comparison, not several), so only the plain `memory-cap`
switch is accepted there (`:STAGE` is refused with a clear reason, since
a stage names a cgroup placement step that does not exist on Windows).

- **The config check** (`probeMemoryCapLevelWindows` /
  `winMemoryCapProbeLevel`), the Windows analogue of
  `probeMemoryCapLevel` reading `/proc/self/cgroup` and `memory.max`:
  each arm's own job's `JOB_OBJECT_LIMIT_JOB_MEMORY` state, read back by a
  new `--win-memcap-probe` worker mode (this binary, cargo-style, like
  the existing `--synthetic-child=N`) that calls a new exported
  `runquota_process.readOwnJobMemoryCapLimit()`. That proc passes a NULL
  job handle to `QueryInformationJobObject`, which Microsoft Learn
  documents as "the calling process's job is used" -- verified against
  the live docs page before relying on it, per this driver's mandate to
  check the Windows survey against Microsoft's own documentation.
  Falsifying mutation: forcing both arms' env to carry no cap turns the
  existing `memoryCapConfigProblem` refusal red with "its launches apply
  no cap, so the comparison would be vacuous" (reused unchanged from the
  Linux path -- it takes an observed level, not a cgroup-specific
  input), confirmed, then reverted.
- **The 64 actions** run as this binary's own new `--run64-spin` worker
  (cargo-style again), launched by `runquota run` and joined without a
  POSIX shell: `run64Script`'s shell `&`/`wait` fan-out has no portable
  Windows equivalent, and depending on one being on PATH is not
  guaranteed on a Windows dev or CI box. The new exported
  `process_cost.runMeasuredFanOut` starts every action's `runquota run`
  concurrently (`spawnChildInJob`, no wait between them) and joins all of
  them with one `WaitForMultipleObjects` call --
  `MAXIMUM_WAIT_OBJECTS` (64) happens to equal `run64ActionCount` exactly,
  so no batching is needed. Falsifying mutation: making the spin worker
  write `turns - 1` instead of `turns` turns the existing "ran out of
  N actions" check red (the Linux path's own check, reused unchanged),
  confirmed, then reverted.

**Two defects found and fixed along the way, both pre-existing in this
driver's own earlier landing (`cd14b30e`), neither specific to the new
arm**:

1. `process_cost.spawnChildInJob` called `SetInformationJobObject` with
   info class 9 (`JobObjectExtendedLimitInformation`) but a buffer sized
   for class 2's shorter `JOBOBJECT_BASIC_LIMIT_INFORMATION` shape
   (`JobBasicLimitW`) -- undersized for what class 9 actually expects
   (verified against Microsoft Learn's struct layout), so the call almost
   certainly failed silently (its return value was discarded) and
   `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` was never really applied to any of
   this module's measured children. Fixed by adding the correctly-shaped
   `JobExtendedLimitW` (mirroring `runquota_process.nim`'s own, already
   correct, struct) and using it for that call.
2. Fixing (1) uncovered a second, previously-masked bug: `spawnChild`
   (used only for the gate's own long-lived daemon) closes the job handle
   immediately after spawning, on purpose, because the daemon must
   outlive that call -- but now that `KILL_ON_JOB_CLOSE` actually takes
   effect, closing the only handle to a job carrying that limit kills
   everything in it, i.e. the daemon, the instant `spawnChild` returns.
   Observed directly: `runquotad` exited during start-up with an empty
   log, every time. Fixed by giving `spawnChildInJob` a `killOnClose`
   parameter (default true, for `runMeasured`'s short-lived children,
   which do want the safety net) and having `spawnChild` pass `false`.
3. (Not a regression, but blocked every daemon start before (1) and (2)
   were even reachable.) `startDaemon`/`daemonEnv`/`runEnv`/
   `reprobuildEnv` unconditionally set `RUNQUOTA_ENDPOINT_SCOPE=private`
   and a filesystem socket path -- `runquota_ipc` refuses private scope on
   Windows ("private RunQuota endpoints require POSIX"; the transport
   there is a named pipe under the default `host` scope,
   `tests/support/windows_daemon_fixture.nim` already establishes the
   pattern). Fixed by making all four Windows-conditional: a named pipe
   name unique per arm (`startDaemon`) and no explicit scope (the default
   `host` scope, isolated by the pipe name alone, same effect `private`
   gives on POSIX).
4. A smaller fourth: `main`'s scratch cleanup (`removeDir(scratch)` after
   `gateCase.stop()`) could race a just-terminated `runquotad.exe` still
   releasing its log file handle on Windows, turning a correctly-reported
   error (or a correct pass) into an unhandled `OSError` instead of a
   clean exit. Fixed with the same bounded wait-and-retry
   `removeGateCgroups` already uses for cgroup v2's own "not empty yet"
   lag, and confirmed to stop crashing under the same mutation that
   surfaced it.

**Verified end to end** against real `runquota.exe`/`runquotad.exe` built
from source: `--case=run-64 --switch=memory-cap` runs both arms, the
config check reports `off: has_limit=0` / `on: has_limit=1,
limit_bytes=1073741824` (`GateMemoryCapBytes`, 1 GiB), and the gate
produces real wall/CPU intervals narrowing round over round (a short
4-round smoke run: wall 5.9% ±16.6, cpu 3.6% ±25.5 -- correctly
`INCONCLUSIVE`, too few rounds for the required precision, not a failure).
A full-precision run (default rounds, 25-minute budget) is in progress;
its verdict will be recorded in RunQuota-Memory-Caps.md § "Verdicts".
