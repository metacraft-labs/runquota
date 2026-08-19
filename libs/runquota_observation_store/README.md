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

Migrations are forward-only and a shipped step is never edited afterwards:
`tests/unit/t_observation_store_migration.nim` builds a version-1 database
from its own frozen copy of the version-1 DDL, so the ladder is exercised
against an artifact that does not move when this library changes.
