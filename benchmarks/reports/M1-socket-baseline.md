# M1 — the socket baseline

**What RunQuota's unix-socket transport costs a real `repro` build.**

M1 is a MEASUREMENT milestone. It proves nothing on its own; it establishes the
number later milestones are weighed against. Nothing here is a verdict on
whether to build the shared-memory transport (M23) or the observation ring
(M22) — see [the findings
document](https://github.com/metacraft-labs/reprobuild-specs/blob/latest/RunQuota-Socket-Baseline-M1.md)
for what these numbers do and do not license anybody to conclude.

Measured 2026-08-26.

---

## Provenance

| | |
|---|---|
| **Host** | Apple M3 Max, 16 logical CPUs (12 performance + 4 efficiency), 16384-byte pages, macOS 26.5.1 (Darwin 25.5.0), arm64 |
| **`runquota` build mode** | `-d:release` — `runquotad`, and the harness, both. Stamped in `build/bin/.build-mode` and re-asserted by `scripts/lib/build_mode.sh` |
| **`repro` build mode** | `-d:release`. **Not the default.** `just build` in reprobuild produces a DEBUG `repro`; this study rebuilt it with `REPROBUILD_BUILD_MODE=release ./scripts/build_apps.sh` precisely because `repro`'s optimisation level is the denominator of gate figure 4 |
| **`runquota` revision** | `dev` at `f4f9442` plus this benchmark |
| **`reprobuild` revision** | `dev`, working tree as of 2026-08-26 |
| **Subjects** | `reprobuild-examples/c-cpp-make/wide-binary` — 66 actions, 65 of them independent `cc -c` compiles, measured in full. `repro test` over reprobuild's own suite — 2785 declared actions — measured over a bounded 15-minute window only; see *The second subject* |
| **Invocations** | Wide build: 5 per arm per configuration, arms interleaved within each round; every one exited 0 with 66 actions / 67 leases. Test run: 1 bounded window per arm |
| **Cache state** | COLD. `--force-rebuild` on every invocation; the warm repeat of the same build executes 0 actions and takes 1.5 s, which would have measured nothing |
| **Measured load** | wall/CPU ratio of a fixed ~2.6 ms work unit, 4059 and 4096 samples: **p50 1.00, p90 1.06, max 6.4**. The machine was NOT oversubscribed. Load average read 7.7–8.8 throughout and is reported for colour only |

---

## Instrument calibration

Re-established in-run, before anything is measured. The harness **refuses to
report** if any of these fails.

| Check | Expected | Observed |
|---|---|---|
| 1000 × `getppid()` moves the kernel syscall counter by | exactly 1000 | **1000** |
| 10⁶ pure userspace iterations move it by | exactly 0 | **0** |
| `CLOCK_MONOTONIC_RAW` over 10⁶ calls | 0 syscalls | **0** |
| `CLOCK_MONOTONIC_RAW` cost / resolution | — | **21.6–34.1 ns/call, 41 ns** |
| `CLOCK_THREAD_CPUTIME_ID` over 2×10⁵ calls | 1 syscall each | **exactly 200000** |
| `CLOCK_THREAD_CPUTIME_ID` cost | — | **104.7–132.6 ns/call** |

### A correction to what M8 recorded

The M8 preemption study states that `CLOCK_MONOTONIC` costs 14.0–14.6 ns and
**zero syscalls**, at **41 ns resolution**. On this host that description does
not belong to `CLOCK_MONOTONIC`:

| Clock | ns/call | syscalls per 10⁶ calls | resolution |
|---|---|---|---|
| `clock_gettime(CLOCK_MONOTONIC)` | 26.5–28.6 | **0–3, not reliably zero** | **1000 ns** |
| `clock_gettime(CLOCK_MONOTONIC_RAW)` | 21.6–34.1 | **0** | **41 ns** |
| `clock_gettime(CLOCK_UPTIME_RAW)` | 22.2–22.4 | 0 | 41 ns |

M8's figure describes the **raw** timebase. The distinction is load-bearing
here twice over: a 1000 ns floor would quantise a 40 µs admission round trip
into 2.5% steps, and a clock that enters the kernel cannot be used inside a
window whose syscalls are being counted. This study uses
`CLOCK_MONOTONIC_RAW`.

### The instrument's own cost, measured

The measurement is taken on the wire by a relay (`benchmarks/lib/runquota_m1_tap.nim`)
because the client is `repro`, a binary this repository does not compile.
Identical lease traffic was driven straight at the daemon and through the
relay, 100 paired rounds:

| | p50 | p90 | p99 |
|---|---|---|---|
| `RequestLease`, client-observed, direct | 12.1 µs | 16.2 µs | 30.1 µs |
| `RequestLease`, client-observed, through the tap | 17.4 µs | 30.8 µs | 51.5 µs |
| `RequestLease`, **as the tap reports it** | 9.8 µs | 16.9 µs | 33.0 µs |

**Read every tapped latency below as roughly 2 µs low** — the tap stamps a
frame when it has fully arrived, so it excludes the client↔tap hop pair. The
measured median offset is −2.3 µs against the direct client-observed figure.
On the admission p50 of ~42 µs that is a 5% under-statement; on the 21.9 ms
completion figure it is nothing.

---

## The four gate figures

Wide build, 66 actions, 67 leases, 5 invocations. Two configurations of the
same daemon, differing in **one flag**.

### 1. Per-execution admission round-trip latency

reprobuild batches admission: one `OfferCandidates` per scheduler wave, 60 per
build for 67 leases.

| Configuration | n | p50 | p90 | p99 | max |
|---|---|---|---|---|---|
| Observation store ON (shipped default) | 300 | **41.8 µs** | **63.0 µs** | **2573 µs** | 4904 µs |
| `--no-write-stats` (transport only) | 300 | 56.0 µs | 93.0 µs | 3492 µs | 4873 µs |

The p99 is two orders of magnitude above the p50 in both configurations, and it
is **not** the store: it is present with capture off. It is the queue — the
`compile` pool is capped at 8 slots against 65 ready compile actions, so an
offer that cannot be granted immediately waits.

### 2. Per-execution completion-report cost

Four blocking round trips per execution, plus one fire-and-forget send.

| Message | per build | p50, store ON | p50, `--no-write-stats` |
|---|---|---|---|
| `LeaseStarting` | 67 | 18.5 µs | 22.0 µs |
| `LeaseRunning` | 67 | 23.8 µs | 31.0 µs |
| **`LeaseFinished`** | 67 | **21 893 µs** | **47.8 µs** |
| `ReleaseLease` | 67 | 21.4 µs | 26.2 µs |
| `ExtensionRow` (one-way, no reply) | 67 | — | — |

**Completion report cost per execution** (`LeaseFinished` + `ReleaseLease`):
**≈ 21.9 ms** with the store on, **≈ 74 µs** with it off.

### 3. Total syscalls attributable to RunQuota IPC

| Side | How obtained | Store ON | `--no-write-stats` |
|---|---|---|---|
| Client | **exactly 2.000** UNIX syscalls per round trip (kernel-counted over 2000 rounds of each of 5 operations), × 336 round trips per build | 672 | 672 |
| Client, one-way sends | 67 `ExtensionRow` writes, syscall cost **not measured** (≤1 write each) | ≤67 | ≤67 |
| Daemon | measured directly on the real build, minus the same daemon idling through the paired control invocation | **≈ 26 100** | **750** |
| **Total per build** | | **≈ 26 800** | **≈ 1 500** |
| **Per execution** | | **≈ 400** | **≈ 22** |

### 4. Cost as a fraction of build wall time

Sum of measured round-trip time on the scheduler's critical path, over wall
time. Admission and the lease lifecycle **are** on the critical path:
reprobuild's scheduler is single-threaded and blocks on every one of these
round trips (`createThread` has zero occurrences in its build engine).

| Configuration | build wall time (median of 5) | RunQuota IPC on the critical path | **fraction** |
|---|---|---|---|
| Observation store ON | 92.0 s (67.8–140.3) | 2487 ms (1959–2963) | **2.5%** (2.1–2.9%) |
| `--no-write-stats` | 94.0 s (93.6–136.7) | 21.2 ms (15.2–24.9) | **0.02%** |

> The fraction column is the **median of the per-invocation ratios**, not the
> ratio of the medians — the two differ (2487 ms / 92.0 s is 2.7%) because
> wall time varied more across invocations than IPC time did.

---

## The breakdown, which is what M1 exists to produce

Per build, median of 5 invocations. The gate names two buckets; the engine's
message set has three, and `LeaseStarting`/`LeaseRunning` are put in their own
rather than folded into either, because folding them would bias the read.

| Class | store ON | share | `--no-write-stats` | share |
|---|---|---|---|---|
| **Admission** (`OfferCandidates`/`LeaseDecisionBatch`) | 5.7 ms | **0.2%** | 10.4 ms | 49% |
| **Lifecycle start** (`LeaseStarting`, `LeaseRunning`) | 3.7 ms | 0.1% | 5.2 ms | 25% |
| **Completion reporting** (`LeaseFinished`, `ReleaseLease`) | 2369 ms | **95.2%** | 5.8 ms | 27% |
| Session (`Hello`, `RegisterSession`, `CloseSession`) | 78.3 ms | 3.1% | 0.2 ms | 1% |
| **Total** | **2487 ms** | | **21.2 ms** | |

**Completion reporting is 95% of what the socket costs a real build, and
admission is 0.2% of it** — 5.7 ms out of a 92-second build, or 0.006% of wall
clock.

## Where the completion cost actually is

`LeaseFinished` is 21.9 ms at the median with the observation store on and
47.8 µs with it off — a factor of ~460 — while the three other lifecycle round
trips on the same connection stay at 18–31 µs in **both** configurations. That
internal contrast is what rules out the instrument, the client and the machine
as explanations.

Two further controls:

- **Nothing is on the wire during those 21.9 ms.** In **335 of 335**
  `LeaseFinished` round trips, zero frames in either direction were observed
  between the request and its acknowledgement. It is not queueing behind other
  traffic; it is the daemon, working.
- **The daemon's own syscall count moves with it**: 29 682 per build with the
  store on against 750 with it off — **≈ 432 extra kernel syscalls per
  completion report**.

**This does not reproduce from a synthetic driver.** The existing M13
write-path benchmark, same repository, same release build, same one-flag
control, measures the store's added per-execution latency at **0.0012 ms**
(3.5% relative). Against a real build it is **≈ 21.8 ms** — four orders of
magnitude larger. Whatever makes the store expensive is a property of the
conditions a build creates, and a tight loop does not create them. Which of
those conditions is responsible was **not** determined here.

---

## What is missing

- **The parallel test run is thin.** See *The second subject* below: 8 lease
  lifecycles, not 335, and no fraction-of-wall-time figure. It corroborates the
  shape; it does not carry a gate figure of its own.
- **Oversubscription.** Measured load was ~1.0×. These figures do NOT describe
  the ≥2× oversubscribed condition M8's gate names.
- **Linux.** Nothing here is claimed for it.
- **The build worker's total syscall count**, which would be the denominator
  for "what share of the build's syscalls are RunQuota's". The RQSP frames come
  from the build worker inside `repro-daemon`, not from the `repro` process a
  caller spawns; only the absolute counts above were measured.

---

## The second subject: a real parallel test run

`repro test` over reprobuild's own suite, one bounded **15-minute window** per
arm, `repro` and `runquotad` both `-d:release`.

The suite declares **2785 actions**. In fifteen minutes it executed **8** of
them — 8 concurrent throughout, `checked=8/2785` for the whole window. Test
actions here are long-running, so a complete paired study of this subject is
measured in **days**, not the tens of minutes the wide build costs. That is why
the window is bounded and why this subject carries no gate figure 4.

| Message | n | p50 | p90 | max |
|---|---|---|---|---|
| `OfferCandidates` | **1** | 104.0 µs | — | — |
| `LeaseStarting` | 8 | 20.6 µs | 21.8 µs | 22.3 µs |
| `LeaseRunning` | 8 | 32.0 µs | 37.2 µs | 37.5 µs |
| **`LeaseFinished`** | 8 | **17 968 µs** | 19 097 µs | 28 939 µs |
| `ReleaseLease` | 8 | 14.4 µs | 16.5 µs | 20.8 µs |

**Read these as corroboration of a shape, not as an interval.** Eight samples
is eight samples, and one admission round trip is not a distribution. What they
do establish is that a completely different workload — long test executions
rather than a compile fan-out, on a host at 1.0× measured load — reproduces the
same structure the wide build showed: `LeaseFinished` in the tens of
milliseconds, every other round trip in the tens of microseconds.

**Two things this subject cannot support.** First, no fraction of wall time:
the run did not complete. Second, the harness's assignment of frames to
invocation windows is **unreliable here** and is not used — terminating the
`repro` CLI does not immediately stop the daemon-hosted build worker, so eight
lease completions belonging to the RunQuota arm landed inside the control
arm's window. The per-message table above is window-independent and unaffected.

---

## Two environment constraints, recorded rather than worked around

- **`libclingo`.** On macOS, `repro`'s interface-extraction edge fails with
  `could not load: @rpath/libclingo.dylib` unless the `repro-daemon` process
  hosting the build was started from an environment that resolves it.
  `--daemon=off` fails unconditionally. This is a reprobuild/macOS packaging
  issue, is not this benchmark's to fix, and is why the daemon-hosted executor
  is the only usable path here.
- **File descriptors.** With `--no-runquota` the engine launches every ready
  action at once. At 130 actions that exceeded the build daemon's 256-fd soft
  limit and 16 actions failed with "process launch failed: Too many open
  files"; the RunQuota arm, whose concurrency the lease authority bounds, did
  not. The subject is 66 actions so that both arms complete — which a paired
  A/B requires.

## A defect found on the way

`runquotad` **dies with an unhandled `OSError: Invalid argument`** when a client
connects to its socket and closes without sending a `Hello` frame. Three lines
of Python against a freshly started daemon reproduce it; the daemon is gone
within a second. `runquotad` is host-wide and serves every user, so any process
that touches its rendezvous socket takes the machine's lease authority down.

Not fixed here — it is a daemon behaviour change and wants its own test. The
harness stopped provoking it (readiness now uses a real handshake). Recorded in
the M1 milestone's `:deferred:`.

---

## Reproducing it

```bash
cd runquota
just bench-socket-baseline calibrate              # instrument check, seconds
just bench-socket-baseline tap-overhead           # the relay's own cost
just bench-socket-baseline client-cost            # syscalls per round trip
just bench-socket-baseline wide-build             # ~15 min
just bench-socket-baseline wide-build-capture-off # ~15 min
```

Needs a built sibling `reprobuild` checkout. Set `REPRO_BIN` to measure a
specific engine binary; the harness detects and records its build mode either
way. Raw per-frame event streams land in
`bench-results/runquota-m1-*-events.csv` so every percentile above can be
re-derived rather than trusted.
