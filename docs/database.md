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
unless `runquotad --observation-db PATH` names a store; making it on by default
is M13, together with the client-declared run boundaries the `runs` row is still
missing.

### What exists today

The execution spine (`runs`, `executions`), `hosts`, `host_profiles`,
`ambient_samples` and `extension_registry` are created, migrated, written and
read. The daemon opens the store at startup, writes one `runs` row per
registered session and one immutable `executions` row per finished lease, and
reports on stdout whether capture is on.

Host identity and the hardware dimension are live. The machine's `host_id` is
128 random bits kept in a per-user state file (`--host-identity-file PATH`,
defaulting under `XDG_STATE_HOME`); it is not derived from the hostname, the
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

## State-boundary requirements

Any persistent RunQuota state must document schema ownership, migrations, backup,
restore, corruption handling, and benchmarks before it becomes a stable boundary.
For the observation store these are specified in
`reprobuild-specs/RunQuota-Observation-Store.md` §"State-Boundary Requirements".
As implemented:

- **Schema ownership.** RunQuota owns every spine table. Extension tables are
  owned by the declaring product, must be named `ext_<extension_id>` (the
  schema enforces it), and RunQuota never reads their columns.
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
  the database write happens on a drain thread in batches. The per-execution
  overhead figure that the default-on decision is conditional on belongs to
  M13 and does not exist yet.

Two rules apply to every persistent store here:

- A corrupt or unavailable store degrades to no capture. It MUST NOT fail a build
  or a test run.
- The daemon MUST refuse to open a database newer than it understands rather than
  degrade silently.

## JSON

JSON may be emitted for inspection output, diagnostics, or benchmark reports. It
MUST NOT define persistent or wire state.
