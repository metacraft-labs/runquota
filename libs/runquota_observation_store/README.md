# runquota_observation_store

The durable record of program executions: the execution spine (`runs`,
`executions`), host identity and versioned hardware (`hosts`,
`host_profiles`), ambient host load (`ambient_samples`), and the registry
for product-owned extension tables (`extension_registry`).

Normative schema: `reprobuild-specs/RunQuota-Observation-Store.md`.
Repository posture and state-boundary requirements: `../../docs/database.md`.

## Shape of the API

- `openObservationStore(path)` never raises. It returns a store whose
  `status` says whether capture is on, and whose `report` says why not.
  Callers check `captureEnabled` and carry on regardless — a build or a
  test run must never fail because observation is unavailable (OS-4).
- Rows in `executions` are immutable. A `before update` trigger aborts any
  attempt, including one made with `sqlite3` directly, and there is no
  update entry point (OS-3).
- A database whose `user_version` is newer than this build understands is
  REFUSED, not degraded. A daemon that writes into a schema it does not
  fully understand produces rows a newer reader cannot trust.
- `resolveHostIdentity(path)` returns this machine's `host_id`: 128 random
  bits minted once and kept in a per-user state file. Nothing about the
  machine is an input — not its name, not its address, not its hardware —
  because any *derivation* from the hostname merges the histories of two
  machines that share a name, and a hash of the hostname does so exactly
  as thoroughly as the name itself.
- `detectHardwareProfile(referencePath)` describes the machine in the
  descriptive columns of `host_profiles`; `ensureHostProfile` hashes them
  and reuses the current row when the hash is unchanged, or closes it and
  opens a successor at the same instant when it is not. Executions already
  written keep pointing at the profile that was current when they ran.
  **Detection has only ever run on macOS/arm64.** The Linux branch is
  written from `/proc` and `/sys` and has never executed; there is no
  Windows detection, only honest `unknown`s.
- `declareExtension(store, declaration)` is how a product attaches its own
  facts. It creates the table from the declaration's forward-only ladder,
  migrates it when the client is newer, accepts an older client unchanged,
  and REFUSES a client declaring a version this database has no route to —
  the extension-level form of the refusal `openObservationStore` already
  makes for the spine. `insertExtensionRow` refuses that client's rows too,
  rather than writing them into a shape it was not built for.
  `pruneExecutions` cascades retention from the spine into every
  registered extension and into the merge quarantine, in one transaction,
  driven by `extension_registry` rather than by any list in RunQuota.
- `applyRetention(store, hostId, now, policy)` enforces the two bounds —
  age and row count, each optional and configurable — over executions and
  over `ambient_samples`. It never deletes `hosts` or `host_profiles`: a
  live machine's *current* hardware profile is as old as the last time its
  hardware changed, so an age bound applied to hardware would delete the
  row every surviving execution points at. `orphanReport` checks the whole
  store by outer join, so it can see an orphan the foreign keys could not
  have created. **Nothing calls `applyRetention` yet**: the daemon has no
  retention flag and no periodic pass.
- `mergeObservationStore` unions another store in: an append-only union
  with no conflict resolution, no clock anywhere on the path, extension
  rows whose schema this receiver does not know CARRIED into
  `carried_extension_rows` and marked unqueryable by a check constraint
  rather than dropped, and a source without the host and hardware
  dimension REFUSED before anything is written. `canonicalDump` renders a
  whole database so two of them can be compared for observable content
  rather than for bytes — which two logically identical SQLite files never
  share, because rowids are assigned in insertion order and `VACUUM`
  preserves them.
- **RunQuota never interprets an extension column** (OS-5). Extension table
  names are composed from the `ext_` prefix and a registered
  `extension_id`, and the only column names RunQuota writes into a
  statement against one are the spine key it is joined by. Both are
  asserted by inspection over a discovered source set, with positive
  controls, in `tests/unit/t_observation_store_extension_boundary.nim`.
- `startObservationWriter` runs the drain thread. Recording is an
  in-memory append under an uncontended lock: no blocking, no fsync, no
  failure path into the caller (OS-1). A full queue drops and counts.

This library is deliberately **not** a static helper: it is absent from
`libs/static_helpers.txt` because it uses `ref` types (`ObservationStore`)
and the GC'd `seq`/`string`/`Option` types the row model needs. The
`--mm:arc --app:staticlib` no-`ref` constraint applies to the client-side
helpers that get linked into other programs, not to daemon-side state.

## Why the `sqlite3` command-line tool

`runquota_persistence` already reaches SQLite through the CLI for learned
estimates, so this adds no new link dependency to the daemon. It also
matches OS-4: a missing command-line tool is an ordinary catchable
condition that degrades to no capture, whereas a missing shared library
would abort at load time.

## Schema versions

| Version | Change |
|---------|--------|
| 1 | The spine as specified: `hosts`, `host_profiles`, `runs`, `executions`, `ambient_samples`, `extension_registry`, plus the `executions` immutability trigger. |
| 2 | `dropped_observations` on `runs` and `executions`. OS-2 requires every dropped observation to be counted, and the specification's table lists gave the count no home. |
| 3 | `host_profiles_current`, a unique index on `host_id` where `valid_to` is NULL. "Unchanged hardware must not accumulate profile rows" becomes a database constraint rather than a property of this library's code, and holds against a client reaching past it into `sqlite3`. Superseded rows stay unconstrained. |
| 4 | `owner_uid` on `executions`, nullable. One host-wide daemon means one store holding every user's executions, so a row has to say whose it is; the value comes from the connection's peer credentials and never from anything a client declares. |

Migrations are forward-only and a shipped step is never edited afterwards:
`tests/unit/t_observation_store_migration.nim` builds a version-1 database
from its own frozen copy of the version-1 DDL, so the ladder is exercised
against an artifact that does not move when this library changes.

**Each extension carries its own version, on its own ladder.** The table
above is the SPINE's, and the two never move together: an extension
migrates while the spine stands still, and the spine migrates while every
extension stands still. Both directions are asserted in
`tests/unit/t_observation_store_extensions.nim`, because a mechanism that
bumped the two together would pass either arm alone.
