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
  between the request and its acknowledgement. **Read this narrowly**: it is a
  per-connection observation, so it rules out the client waiting behind other
  traffic *on its own connection*. It does **not** rule out the daemon
  serializing this request against other clients' — every request is handled
  under one daemon-wide lock, and at 64 concurrent actions that is a live
  possibility rather than a remote one. The time is spent inside the daemon;
  whether it is spent working or waiting for the lock is exactly what this
  control cannot tell you.
- **The daemon's own syscall count moves with it**: 29 682 per build with the
  store on against 750 with it off — **≈ 432 extra kernel syscalls per
  completion report**.

**This did not reproduce from a synthetic driver.** The existing M13
write-path benchmark, same repository, same release build, same one-flag
control, measured the store's added per-execution latency at **0.0012 ms**
(3.5% relative). Against a real build it is **≈ 21.8 ms** — four orders of
magnitude larger. That was read here as a real difference between a tight
loop and a build.

At the time this baseline was published, which of a build's conditions was
responsible was **not** determined, and two candidates were offered: daemon-wide
lock contention, and a per-row durable commit. **Both were wrong**, and so was
the premise: the benchmark was not exercising the same code. Corrected, it
reproduces the wide build's figure from a tight loop at concurrency 1 — 53.6 ms
against this study's 21.9 ms, the same order. The answer is recorded below
rather than quietly swapped in.

### The cause, determined after this baseline was published

**Neither candidate. The M13 benchmark did not drive the expensive code at
all**, and the one condition that mattered was already named in this study's
own list of unisolated variables: *"the real `commandStatsId` … a synthetic
execution does not carry"*.

`handleLeaseFinished` called `publishAggregate`, which refreshed the published
aggregate for the finished lease's stats key **on the completion request path,
under the daemon-wide lock**. Publishing meant a synchronous
`flushObservationWriter()` — whose own docstring says *"for the read path,
never for the write path"* — followed by `estimateFor`. The observation store
is driven through the **`sqlite3` command-line tool**, so that is **three
subprocess spawns per finished action**: one for the flush, and two for the
query (the host-profile read and the aggregate itself).

`publishAggregate` returned immediately when the stats key was empty. The M13
benchmark built its requests with `resourceRequest(label, …)` — whose first
parameter is the **label**, not the stats key — and never assigned
`commandStatsId`, so for the whole of M13's life that early return was the only
branch it ever took. `reprobuild` sets `commandStatsId` on every request, so a
real build took the other one every time.

Measured inside the daemon, per keyed completion, release build, M13's loop:

| Step in `handleLeaseFinished` | p50 | p95 |
|---|---|---|
| `updateEstimateFromFinish` (in-memory) | 0.001 ms | 0.002 ms |
| `captureObservation` (enqueue only) | 0.002 ms | 0.008 ms |
| **`publishAggregate`** | **72.9 ms** | **193.4 ms** |
| — of which `flushObservationWriter()` | 24.9 ms | 57.4 ms |
| — of which `estimateFor` | 39.9 ms | 62.8 ms |

The same daemon, same loop, with the stats key left empty: `publishAggregate`
p50 **0.000 ms**. That is the ON/OFF split this report measured from outside,
seen from inside.

**Why both published candidates were wrong.** It is not a per-row durable
commit: the row write is asynchronous and always was, and the cost is three
process spawns rather than an fsync. It is not lock contention either — the
work is genuinely done, at concurrency 1, and 72.9 ms of it. Contention is a
*consequence*: the daemon-wide lock was held across all three spawns, so every
other connection worker waited behind them. The proposed discriminating
experiment (latency at concurrency 1, 8, 32, 64) would have answered a question
neither of whose answers was the truth.

**Fixed.** Aggregate publication now happens on a background thread: the
completion path marks the key dirty and returns, and the thread does the flush,
the query and the publication, coalescing repeated completions of one key into
a single query. The flush moved rather than disappeared, so the published
figure still includes the run that dirtied the key and is still byte-identical
to what the socket answers.

### After the fix

**The M13 benchmark, corrected and re-run.** It now sets `commandStatsId` and
carries both arms, because the difference between them turned out to be the
dominant term. 400 rounds, interleaved, `-d:release`, same host:

| Per-execution added latency (paired median) | before | after |
|---|---|---|
| **stats key set** — what every shipped client does | **53.60 ms** | **0.0012 ms** |
| no stats key — what this suite used to measure | 0.014 ms | 0.0012 ms |
| stats key set, paired p95 | 63.72 ms | 0.0088 ms |

A factor of ~45 000. The two arms now agree, which is the point: a completion
report costs the same whether or not it carries a stats key, because it no
longer does the store's work.

**There is an accident worth naming.** The corrected keyed figure is *also*
0.0012 ms — the same number this report quoted as evidence that the synthetic
driver saw nothing. That figure is now honest: it describes the path a real
client takes, rather than an early return.

The regression is held by
`tests/integration/t_completion_report_does_not_wait_on_the_store.nim`, which
asserts on a drain counter rather than on time, and by the benchmark's second
arm.

**And M1's own subject, re-run.** Same wide build, same harness, same host,
`runquotad` `-d:release`. **Read the two columns as a comparison of the
daemon, not of the machine or the engine** — see the caveats below.

| Wide build, per invocation | before (2026-08-26) | after |
|---|---|---|
| **`LeaseFinished` p50** | **21 893 µs** | **41.6 µs** |
| `LeaseStarting` p50 | 18.5 µs | 16.5 µs |
| `LeaseRunning` p50 | 23.8 µs | 20.1 µs |
| `ReleaseLease` p50 | 21.4 µs | 19.0 µs |
| Completion reporting, per build | 2369 ms | **4.29 ms** |
| Admission, per build | 5.7 ms | 5.75 ms |
| Lifecycle start, per build | 3.7 ms | 3.4 ms |
| Session, per build | 78.3 ms | 68.9 ms |
| RunQuota IPC on the critical path | 2487 ms | **132 ms** |
| **as a fraction of build wall time** | **2.5%** | **0.17%** |
| daemon syscalls per build, over the control | ≈ 28 900 | ≈ 15 000 |

`LeaseFinished` has rejoined the other three lifecycle round trips — 41.6 µs
against 16–20 µs — which is the shape the original study said would exist if
the store were not on that path. Everything that did **not** change is at
least as informative: admission is 5.7 ms in both columns.

**Where the remaining 132 ms is, which is a different place.** `CloseSession`
is **51 256 µs** at the median and `DeclareExtension` **25 704 µs**, two of
each per build; together they are about 90% of what this table prices, against
4.3 ms for all 268 per-execution round trips combined.

> **This paragraph originally read "four of each per build", called the two
> messages session-scoped, and concluded that the remaining cost is "no longer
> per-execution at all". The count was wrong — four across the two measured
> invocations, two per build — and so was the conclusion. `CloseSession` was
> not doing anything; it was waiting behind a per-execution cost this table
> does not contain. See the section below, which was written after the cause
> was found.**

**Caveats on the "after" column, stated because they matter:**

- **Two invocations per arm, not five.** Single-figure precision at best.
- **`repro` was a DEBUG build** in the re-measurement and `-d:release` in the
  original, so the *wall-time denominator is not comparable between the two
  columns* and the fraction row should be read as an order of magnitude, not a
  ratio of ratios. The per-message latencies do not depend on it. Both arms
  within the re-measurement match, which is what the paired comparison needs.
- **Wall time differed** (78.9 s after against 92.0 s before) for reasons that
  include the engine's build mode and the host's other work; it is not a
  RunQuota result in either direction.
- Measured load in the re-measurement: wall/CPU **p50 1.00, p90 1.04, max
  2.7** over 1970 units. Not oversubscribed, same as before.
- The tap resolved **1480 frames → 673 paired round trips + 134 one-way
  `ExtensionRow` sends**, on 5 connections, with no unpaired remainder beyond
  those sends.

### What `CloseSession` was waiting for

**A one-way message, priced at zero by construction.** The 134 `ExtensionRow`
sends in the line above are excluded from every percentile in this report,
because the tap resolves latency by pairing a request with its reply and an
`ExtensionRow` has none. They were not free. Each one cost the daemon a
`sqlite3` subprocess.

The evidence is in this study's own event stream —
`bench-results/runquota-m1-wide-build-events.csv`, the file the table above was
derived from, read a second time. **Every slow `CloseSession` is immediately
preceded on its own connection by a burst of `ExtensionRow` frames, and its
latency is a function of how many:**

| connection | one-way rows sent just before it | `CloseSession` |
|---|---|---|
| 1 | 1 | 8 903 µs |
| 2 | 66 | 68 812 µs |
| 3 | 1 | 8 666 µs |
| 4 | 66 | 51 257 µs |

**And the client was paced while sending them.** The 66-row bursts span 348 ms
and 272 ms, in a shape nothing about the client explains: a median inter-frame
gap of **3 µs**, a p90 of **23 ms**, and stalls of 16–41 ms after every fourth
or fifth row. That is a sender blocked on a socket being drained one process
spawn at a time. Priced end to end — last `ReleaseLease` acknowledged to
`SessionClosed` acknowledged — the close of a session costs **450 ms and
349 ms** in the two invocations, against the **132 ms** this report attributes
to RunQuota for the entire build.

**So the remaining cost was per-execution after all, and it did scale with
build width.** One row per action, one spawn per row.

### The cause, and the fix

`admitExtensionRow` read `extension_registry` out of the database for every
row, to establish two things: that the extension is registered, and what schema
version the registry carries. Neither can change while a client is sending rows
for an extension it has already declared — and a declaration is mandatory
before any row, is request/response, and reads the registry authoritatively.
The per-row read was asking a question that had already been answered, at the
price of a process, on the daemon thread, under the daemon-wide lock every
other connection is waiting on.

Measured directly against the release daemon over a real socket with the
shipped client, same host, one session, rows sent the way a build sends them:

| | before | after |
|---|---|---|
| next round trip after **0** one-way rows | 0.036 ms | 0.030 ms |
| next round trip after **64** one-way rows | **1759.6 ms** | **0.11 ms** |
| `CloseSession` after **64** one-way rows | **1431.5 ms** | **0.06 ms** |
| the regression test's 40-row burst | **837.1 ms** | **0.07 ms** |
| `DeclareExtension`, registry up to date | 37.8 ms | 34.3 ms |
| `StatusRequest` — the transport's own floor | 0.007 ms | 0.015 ms |

**21 ms per row**, which is what a `sqlite3` spawn costs on this host; the M5
process benchmark independently puts a null spawn at 20.8 ms here.

The declaration's read stays, and that is the point rather than an omission:
it is what makes answering the row path from memory sound. `DeclareExtension`
is therefore still two spawns — the registry read and the "does the table the
registry claims actually exist" check — and still about 35 ms, twice per build.
It does not scale with anything, and both spawns are doing work the row path
was doing redundantly.

**Three rows of the before column are deliberately not quoted**: bursts of 1, 4
and 16 rows measured 143 ms, 429 ms and 484 ms, which is more than 21 ms a row.
The aggregate publisher's own spawns were in flight during those bursts and
every spawn in the daemon passes through one guard, so those three figures
price the contention as well as the row. The 64-row and 40-row bursts are long
enough for that to wash out.

Held by `tests/integration/t_extension_rows_do_not_query_the_registry.nim`,
which asserts on a read counter rather than on a stopwatch.

### What this says about the transport, which is what M1 exists to inform

A `StatusRequest` round trip on this socket costs **7–15 µs**. The four
per-execution round trips cost 16–42 µs each. Every large number this study
has produced — 21.9 ms per completion, 21 ms per extension row, 35 ms per
declaration — has turned out to be a `sqlite3` process behind the socket, and
none of them was the socket. After both fixes, RunQuota's whole cost to this
66-action build is roughly **4.3 ms of per-execution round trips plus ~70 ms of
process spawns in two declarations**, on a build of 79–92 seconds.

**M22 and M23 are both premised on the socket being expensive. On this
evidence it is not.** That is not an argument against either milestone — a ring
and a shared-memory admission path may earn their keep at a width this subject
does not reach, and neither claim is tested here — but the case for them cannot
rest on this baseline, and the number to beat is tens of microseconds rather
than tens of milliseconds.

**The 4.3 ms + 70 ms figure above is a projection, not a measurement.** The
wide build was NOT re-run after this fix: the per-message figures come from
driving the release daemon directly, and the end-to-end total adds them up.
What was measured end to end is the mechanism the build was waiting on, and
that is daemon-side — the same daemon, socket and client library a build uses,
differing only in which process sends the frames. A third pass over the wide
build would settle the addition and is the obvious next measurement.

---

## What is missing

- **The parallel test run is thin.** See *The second subject* below: 8 lease
  lifecycles, not 335, and no fraction-of-wall-time figure. It corroborates the
  shape; it does not carry a gate figure of its own.
- **Oversubscription.** Measured load was ~1.0×. These figures do NOT describe
  the ≥2× oversubscribed condition M8's gate names.
- **A third pass over the wide build**, after the extension-row fix. The
  "after" column above still contains the row path's cost, spread between a
  `CloseSession` percentile and 134 frames priced at zero.
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

## A defect in this harness, found while re-measuring

**The warmup invocation ran the control arm, and that silently disarmed the
tap for the whole study.** `runOnce` derives the subject's environment with
`reproEnv(arm == "runquota", …)`, and the warmup's arm string is `"warmup"` —
so the warmup ran with `REPROBUILD_NO_RUNQUOTA=1`. `repro-daemon` is a
*persistent* process that the first invocation starts and every later one
reuses, and it keeps the environment it was started with, so the build daemon
spent the rest of the study refusing to talk to RunQuota at all. The tap then
reported one `Hello` and nothing else: **the silent zero `reproEnv`'s own
comment exists to prevent, arriving through a door that comment did not
cover.**

This is why the original study had to kill and restart `repro-daemon` by hand
to see any lease traffic. The condition is `arm != "control"` now, so the
warmup is a RunQuota arm — still run straight at the daemon rather than
through the tap, so nothing it does can reach a percentile.

**Check `tap.paired_round_trips` and `by_message_kind` in the emitted JSON
before believing any run of this benchmark.** A study whose tap saw only
`Hello` has measured nothing and looks exactly like a build that makes no IPC.

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
