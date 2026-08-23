# Database Posture

RunQuota maintains two kinds of durable state, with different maturity.

## Learned resource estimates

Estimates keyed by the opaque command stats id, used for admission and OOM
prevention. Held in memory on the hot path (O(1) lookup) and flushed
asynchronously to SQLite. This is scheduler metadata only and MUST NOT affect
cache identity.

## Observation store

RunQuota is the system of record for program-execution observations: one durable,
immutable row per executed process, with host and versioned hardware identity,
resource peaks, ambient host load, and product-specific facts in extension tables.

The normative specification — schema, extension mechanism, retention, cross-host
merge, redaction, and the write path — is
`reprobuild-specs/RunQuota-Observation-Store.md`. The shared-memory transport that
carries observations off the hot path is
`reprobuild-specs/RunQuota-Shared-Memory-Transport.md`.

Both Reprobuild and the CodeTracer test runner are clients of this store. See
`codetracer-specs/Planned-Features/Nim-Parallel-Test-Framework.md` §17 for the
test-side reporter.

Note the daemon boundary in `CLAUDE.md`: `runquotad` is a lease authority and does
not monitor client process trees. Per-execution resource figures are therefore
**client-reported**, as they already are for learned estimates; the daemon samples
only host-wide totals and derives foreign load by difference.

The implementation lives in `libs/runquota_observation_store`. Capture is off
unless `runquotad --observation-db PATH` names a store. Turning it on by default
is M22, whose committed per-execution overhead figure over the ring is what
justifies it; M13 measures the socket path's overhead as the fallback's cost and
supplies the client-declared run boundaries the `runs` row is still missing.

### What exists today

The execution spine (`runs`, `executions`), `hosts`, `host_profiles`,
`ambient_samples` and `extension_registry` are created, migrated, written and
read. The daemon opens the store at startup and reports on stdout whether
capture is on.

**Domain extensions are live as a mechanism, with no extension yet using
it.** A product declares an extension — an id, an owner, a schema version
and a forward-only ladder — and RunQuota creates the `ext_<extension_id>`
table, migrates it when a newer client arrives, accepts an older client
unchanged, and refuses one declaring a version it has no route to rather
than writing that client's rows into a shape it was not built for.
Retention cascades from the spine into every registered extension in one
transaction, driven by `extension_registry` rather than by any list in
RunQuota. **An extension's version and the spine's move independently**:
neither migration touches the other's schema. The two extensions that will
really exist, `ext_test_execution` and `ext_repro_action`, are M19 and M17;
the mechanism was deliberately built and gated against a synthetic
extension so that no one product's shape decided what it can express.

**Two writers run against that one store, not one.** Both are background
threads, and both exist so that nothing on the lease path waits for IO:

- The **observation writer** takes the execution spine. Recording is an
  in-memory append under an uncontended lock — one `runs` row per registered
  session, one immutable `executions` row per finished lease — and a drain
  thread batches them to SQLite. A full queue drops the row and counts it;
  losing an observation always beats perturbing the work being observed.
- The **ambient sampler** takes `ambient_samples`, on a fixed cadence rather
  than on an event. `--ambient-sample-interval-millis N` sets the cadence and
  `0` turns it off. **It writes only while at least one lease is live.** Fixed
  cadence means independent of execution *boundaries*, not independent of
  whether any work exists: a sample taken while nothing is leased can never be
  joined to an execution, so it is a row no query can reach, and without the
  gate a one-second cadence would write about 86k such rows per host per day
  through an idle night. Gating costs no information and bounds ambient growth
  by build activity, the same bound the spine already obeys. Bounded retention
  (M15) is still wanted; it is no longer a precondition for turning capture on.

Because there are two of them, `sqlite3` is given a busy timeout — through the
`.timeout` dot-command rather than `pragma busy_timeout`, since the pragma
returns a row and would prepend its value to the output of every statement
after it, starting with `pragma user_version`.

The sampler reads **host-wide totals only**: `runquotad` is a lease authority
and does not inspect client process trees, so `self_*` is the arithmetic sum of
what clients report about their own live executions and `foreign_*` is the
residual, clamped at zero. Nothing feeds `self_*` in production yet — RQSP
carries no in-flight figures from a running client — so a live daemon currently
records everything it admitted as foreign, and M13 is where that is wired up.

A tick that cannot support a measurement writes **no row** and is counted
instead: an unavailable reading, a pair of kernel counters that did not move, a
counter that went backwards, a sample whose millisecond was already taken, and
an interval over which no lease was live. Every tick lands in exactly one of
those buckets or produces a row, which the suite asserts as an identity.
A row of zeros would not read as "not measured", it would read as an idle
machine. Only macOS/arm64 has ever sampled; the Linux branch is written from
`/proc` and has never executed, and every other platform reports unavailable.

Host identity and the hardware dimension are live. The machine's `host_id` is
128 random bits kept in a **host-wide, daemon-owned** state file
(`--host-identity-file PATH`, defaulting to `/var/db/runquota/host-id` on macOS
and `/var/lib/runquota/host-id` elsewhere).
**That directory must already exist**, with the right owner and a mode nobody
else can write: see "Provisioning the host-wide state directory and the rendezvous" below. The daemon
never creates it, verifies its ownership and mode on every start, and where it
is missing or untrustworthy capture is off — path and reason named.
`runquotad` is one daemon per host,
so the file that names the machine has to be as host-wide as the daemon that
owns it: a per-user file — which is what this was before, under
`XDG_STATE_HOME` — makes one machine present as several, and that is the
failure mode hardest to notice, because the aggregates still carry *a* hardware
dimension and simply never pool. `host_id` is not derived from the hostname, the
address, or anything else two machines can share, because a derived identity
silently merges the histories of unrelated machines. At startup the daemon
detects its hardware, hashes the descriptive columns, and reuses the current
`host_profiles` row when the hash is unchanged. A change closes the old row at
that instant and opens the new one at the same instant, so the intervals are
contiguous and non-overlapping; already-written `executions` keep pointing at
the profile that was current when they ran. Schema version 3 enforces at most
one open profile per host.

Two detection notes. `swap_bytes` is recorded at whole-GiB granularity because
macOS has no configured swap size — the dynamic pager grows swap files on
demand, and a byte-exact figure would mint a fresh hardware profile every time
it did. Only macOS/arm64 has ever run the detector; the Linux branch is written
from `/proc` and `/sys` and has never executed, and there is no Windows branch
beyond what the Nim runtime already knows.

Columns the RQSP protocol does not yet carry — CPU user and system time, IO
byte counts, and a run's finish status — are stored as SQL `NULL`, which reads
as "not declared". They are deliberately not stored as zero: a zero is a
measurement, and nobody made it. M13 supplies the client-reported figures.

`executions.owner_uid` (schema version 4) says whose lease a row records. One
host-wide daemon means one store holding every user's executions, so a query
has to be able to say whose rows it is about. The value is taken by the daemon
from the connection's **peer credentials** and never from anything the client
declares — a client-declared owner would let any participant write rows
attributed to another user — and a Hello whose declared uid disagrees with the
peer credentials is refused rather than corrected. It is `NULL`, not `0`, where
the transport cannot report credentials: `0` is root, and a wrong owner is
worse than an absent one.

## Provisioning the host-wide state directory and the rendezvous

`runquotad` needs two directories that **the install step creates and the
daemon never does**. It keeps this machine's `host_id` in the first and binds
its socket in the second:

| Platform | State directory | Owner | Mode |
|----------|-----------------|-------|------|
| macOS | `/var/db/runquota` | the account `runquotad` runs as | `0755` |
| Linux | `/var/lib/runquota` | the account `runquotad` runs as | `0755` |
| Windows | `C:\ProgramData\runquota` | the account `runquotad` runs as | — |

| Platform | Rendezvous directory | Owner | Group | Mode |
|----------|----------------------|-------|-------|------|
| macOS | `/var/run/runquota` | the account `runquotad` runs as | `runquota` | `0750` |
| Linux | `/run/runquota` | the account `runquotad` runs as | `runquota` | `0750` |
| Windows | — (named pipes) | — | — | — |

The socket inside it is `runquotad.sock`, mode `0660`, group `runquota`.

**The rendezvous path contains nothing derived from the caller.** It is not
under `XDG_RUNTIME_DIR`, not `<tmp>/runquota-$UID`, and not anywhere else a
second user would compute differently — because a second user who computes a
different path does not fail to reach the daemon, they start a daemon of their
own, and two daemons then admit against their own view of one machine's budget.

**Membership in the `runquota` group is the admission control.** A user who is
in it can traverse the directory and connect to the socket; a user who is not
is refused by the kernel, before any RunQuota code runs — the directory's
missing search bit and the socket's own mode both bite, and on macOS the socket
mode alone is enough. Adding a user to the group is how an operator says "you
may participate in the managed-resource system on this host":

```sh
# Linux
sudo usermod -aG runquota alice
# macOS
sudo dseditgroup -o edit -a alice -t user runquota
```

### When the group does not exist: single-user mode

**A `runquota` group that cannot be resolved does not switch the group check
off.** The group *is* the admission boundary, so a daemon that merely skipped
the comparison would keep a `0750` directory reachable by whatever group it
happened to inherit — a boundary nobody chose and nothing verified.

Instead the endpoint degrades, visibly and to something smaller:

| | Group resolves | Group does not resolve |
|---|---|---|
| Rendezvous directory | `0750`, group `runquota` | `0700`, owner-only |
| Socket | `0660`, group `runquota` | `0600`, owner-only |
| Who may connect | the owner and every group member | the owner only |
| `runquotad` says | nothing extra | `single-user mode: …` on its listening line |

So a host-wide daemon on an unprovisioned host degrades **visibly to a per-user
one** rather than invisibly to no boundary at all. It still starts and still
serves leases: admission is the mission, and a missing group entry must not take
out a machine's build-capacity governor. Create the group and restart to serve
every member of it.

`RUNQUOTA_ENDPOINT_GROUP` overrides the group name, and accepts a numeric gid
for hosts whose group is real but not resolvable by name.

Both directories' **ownership and mode are verified on every daemon start and
every client attach**, and a squatted or wrong-moded one is refused rather than
used — path and mode named. Existence is not trust: a state directory owned by
the wrong uid lets any local user replace `host-id` and thereby fork this
machine's history or merge it with another machine's, and a rendezvous
directory owned by the wrong uid is a rendezvous point somebody else controls.

The paths are also written down once, machine-readably, in `nix/host-state.nix`,
and `tests/integration/t_host_identity_refusal.nim` asserts that file agrees
with `hostWideStateDir` and `hostWideEndpointDir` in the daemon's source.

**On a host where the directory is missing, capture is off.** The daemon still
starts and still serves leases — admission is the mission, and an advisory
subsystem must not take out a machine's build capacity — but it prints the path
and the reason on stdout and records nothing. It does **not** mint an identity
for the current process: an id nothing wrote down would be a different machine
on every invocation, no two rows would ever pool, and the aggregates would still
carry a hardware dimension, so nothing would look wrong. That failure has no
symptom at the point of use, which is why it is a refusal.

### Under Nix

The flake ships the install step:

- `nixosModules.runquotad` — a systemd unit plus `StateDirectory=runquota`,
  `RuntimeDirectory=runquota` and two `systemd.tmpfiles` rules, so
  `/var/lib/runquota` and `/run/runquota` both exist with the right owner,
  group and mode from activation onwards.
- `darwinModules.runquotad` — a launchd daemon plus an activation script that
  `install -d`s `/var/db/runquota` and `/var/run/runquota`.

Both modules are **evaluated** by `checks.module-eval` in `flake.nix`, which
puts each through its real module system — nix-darwin is reached transitively
via `inputs.nixos-modules.inputs.nix-darwin` — and asserts on the resulting
activation script, launchd `serviceConfig`, tmpfiles rules and unit
`serviceConfig`. Run it with `nix build .#checks.<system>.module-eval`. Neither
module has been *activated* on a real host by this repository's tests;
evaluation is what is claimed, and it is claimed equally for both.

```nix
{
  imports = [ runquota.nixosModules.runquotad ];   # or darwinModules
  services.runquotad.enable = true;
}
```

### By hand

On a host not managed by Nix, run once, as the account `runquotad` will run as
(`$(id -u)` below is that account's uid — run this while logged in as it):

```sh
# macOS
sudo mkdir -p /var/db/runquota && sudo chown "$(id -u)" /var/db/runquota && sudo chmod 0755 /var/db/runquota
sudo mkdir -p /var/run/runquota && sudo chown "$(id -u)":runquota /var/run/runquota && sudo chmod 0750 /var/run/runquota

# Linux
sudo mkdir -p /var/lib/runquota && sudo chown "$(id -u)" /var/lib/runquota && sudo chmod 0755 /var/lib/runquota
sudo mkdir -p /run/runquota && sudo chown "$(id -u)":runquota /run/runquota && sudo chmod 0750 /run/runquota
```

`/run` (and `/var/run` on macOS) is cleared on boot, so the rendezvous
directory has to be re-created at every boot — which is what
`RuntimeDirectory=` and the activation script do on a Nix-managed host, and
what an init script or a `tmpfiles.d` drop-in has to do elsewhere.

The daemon's own refusal message prints this command with the uid already
filled in, so an operator who hits it does not have to come back here.

`--host-identity-file PATH` overrides the location for a test or an unusual
host. It does not change the rule: the directory containing `PATH` must exist
before the daemon starts.

## Capture is on without any flag

The observation store is **enabled by default**. Its primary readers need the
history to already exist at the moment a question is asked, and nobody can
retroactively enable capture for the week that would have answered "did this
test ever pass on this host" — an opt-in store is empty exactly when it is
first needed. The reasoning is normative in
`reprobuild-specs/RunQuota-Observation-Store.md` §"Capture Is Enabled By
Default".

So `runquotad` with no store flag at all records into
`<host state directory>/observations.sqlite3` — beside the host identity
file, in the same directory the install step above provisions. The two are
derived from one another rather than being two constants, so an operator who
relocates the host state with `--host-identity-file` relocates the store with
it and the two can never disagree.

Three ways to say where, in precedence order:

| Setting | Effect |
|---|---|
| `--no-write-stats` | Capture off. Nothing is opened, no store file and no host identity file is created, and admission carries on untouched. Wins over `--observation-db`. |
| `--observation-db PATH` | Capture into `PATH`. |
| neither | Capture into the host default beside the host identity file. |

On a host where the state directory has not been provisioned, capture
degrades to off with a report naming the directory and the command that
creates it — the same OS-4 degradation a corrupt store gets, and for the same
reason: an advisory subsystem may not take out a machine's build capacity.

`runquota observations --json` (RQSP inspection subject `observations`)
reports whether
capture is on, which store is open, how many in-flight client reports were
accepted and refused, and how many rows were dropped or failed to write.

## Reading it back

`runquotad` is the **only sanctioned reader**. No client may open the database
file directly; queries go over the socket as `StatsQuery`/`StatsResponse`
(`runquota_client.queryStats`), and never on the observation ring, which is a
one-way MPSC write path of the opposite shape.

Two consumers share one interface, differing in aggregation rather than in
mechanism: a **resource distribution** over a stats key, for admission, and
**rows and rankings**, for the human and agent surfaces.

Four rules shape every answer:

- **Host qualification.** Every response carries the host profile identity of
  the rows it summarises, and rows from two hardware profiles are never pooled
  into one set of figures. A caller wanting cross-host data asks for it
  explicitly and receives one distribution *per profile*.
- **Unknown is not zero.** A key with no history answers `unknown`; a key whose
  history happens to be all zeros answers `known`, with zeros. Callers treat
  unknown as "use the declared or default estimate".
- **Uid scoping.** Row and ranking queries are scoped to the calling uid, taken
  from peer credentials rather than from anything the caller declares. Widening
  to the whole host is explicit and available. The **estimate path is
  deliberately not uid-scoped**: the cost of a piece of work is a property of
  the work and the hardware, not of who ran it.
- **Client estimates are not second-guessed.** An estimate supplied with a lease
  request is used unmodified — never clamped against the daemon's learned table.
  The learned estimate is the fallback when none is supplied.

The reader boundary is enforced by inspection rather than by review:
`tests/unit/t_observation_store_reader_boundary.nim` walks `libs/` and `apps/` —
a discovered set, not a list that can drift — and fails on any unsanctioned
module that opens the store or reaches SQLite, with positive controls in both
directions so that neither a scanner matching nothing nor one matching
everything can pass.

## State-boundary requirements

Any persistent RunQuota state must document schema ownership, migrations, backup,
restore, corruption handling, and benchmarks before it becomes a stable boundary.
For the observation store these are specified in
`reprobuild-specs/RunQuota-Observation-Store.md` §"State-Boundary Requirements".
As implemented:

- **Schema ownership.** RunQuota owns every spine table. Extension tables are
  owned by the declaring product, must be named `ext_<extension_id>` (the
  schema enforces it), and RunQuota never reads their columns. That last
  clause is enforced by inspection rather than by review:
  `tests/unit/t_observation_store_extension_boundary.nim` walks `libs/` and
  `apps/` — a discovered set, not a list that can drift — and fails on any
  concrete extension table name or extension-owned column name in RunQuota
  source, with positive controls so that a scanner matching nothing cannot
  pass.
- **Migrations.** Versioned through SQLite's `user_version` and forward-only.
  Each step is a text constant that is never edited once shipped; a database
  built from the frozen version-1 DDL must migrate to exactly the schema a
  fresh database gets, which is asserted rather than assumed.
- **Backup and restore.** `backupTo` uses `VACUUM INTO`, which takes a read
  transaction: the store is copyable while the daemon runs and the copy opens
  standalone. Combining a restored copy with a live one is merge, which is M15.
- **Corruption handling.** Corruption is detected at open with
  `pragma quick_check`, reported verbatim, and never repaired. The store
  degrades to no capture and the daemon keeps serving leases.
- **Benchmarks.** Recording on the lease-finish path is an in-memory append:
  157–381 ns per row across seven repetitions on an aarch64 macOS host whose
  load average was 66–90 at the time. Nothing on that path opens a file, and
  the database write happens on a drain thread in batches.

  **The socket write path's per-execution added latency is 0.7–1.9 µs**
  (median). Measured by `just bench-observation-write-path` against a
  `runquotad --no-write-stats` control: two daemons of the same binary run
  at once, each round times one complete execution against each in
  alternating order, and the headline is the paired median difference over
  400 rounds after 20 discarded warm-up rounds. Three consecutive full runs
  gave 1.0 µs, 1.9 µs and 0.7 µs against a control execution latency of
  58–62 µs, so **1.2–3.1 % of the cost of an execution**; a release build
  gave 1.9 µs and 1.2 µs against a 47–48 µs control (2.5–4.1 %). Paired p95
  was 11–20 µs. Host: aarch64 macOS, Apple M3 Max, 16 logical cores.

  Pairing rather than a before/after pair is not fussiness: M11 measured
  this machine's host-wide busy figure wandering between 56 % and 88 % over
  twenty consecutive one-second readings, which is larger than the effect
  being measured. The harness also refuses to report at all unless the
  capture arm recorded one row per execution and the control arm wrote no
  store, so a silently degraded store cannot produce a flattering figure.

  **This number does not decide the default.** M13 is the fallback path;
  M22 measures the ring and carries the default-on decision.

Two rules apply to every persistent store here:

- A corrupt or unavailable store degrades to no capture. It MUST NOT fail a build
  or a test run.
- The daemon MUST refuse to open a database newer than it understands rather than
  degrade silently.

## JSON

JSON may be emitted for inspection output, diagnostics, or benchmark reports. It
MUST NOT define persistent or wire state.
