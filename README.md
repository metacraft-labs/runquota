# RunQuota

> **Status:** M0 repository skeleton

RunQuota is the local resource lease coordinator used by Reprobuild and other
tools that launch concurrent process trees.

M0 establishes the public repository shape, policy checks, compileable Nim
library skeletons, and ARC/staticlib checks for helper libraries.

## Documentation

- **[The RunQuota book](docs/book-isonim/)** — user-facing documentation: what
  RunQuota is, [provisioning a host](docs/book-isonim/content/getting_started/provisioning.md),
  [the daemon](docs/book-isonim/content/usage_guide/daemon.md),
  [the CLI](docs/book-isonim/content/usage_guide/cli.md) and
  [the observation store](docs/book-isonim/content/usage_guide/observations.md).
  The Markdown is readable as-is; rendering it needs the sibling checkouts
  listed in [its README](docs/book-isonim/README.md).
- [`docs/database.md`](docs/database.md) — the observation store's design and
  schema, for implementers.
- [`AGENTS.md`](AGENTS.md) — contributor and agent instructions.

## Commands

- `just build` compiles app entry points listed in `apps/entrypoints.txt`.
- `just test` runs local tests and the static helper-library gate.
- `just lint` runs repository requirement and Nim source checks.
- `just check-static-helpers` compiles helper libraries with
  `--mm:arc --app:staticlib` and rejects Nim `ref` types.

## Repository Shape

- `libs/` contains importable Nim libraries.
- `apps/runquota/` contains the user-facing CLI.
- `apps/runquotad/` contains the daemon entry point.
- `tests/` contains unit, integration, compatibility, fixture, and E2E tests.
- `benchmarks/` contains repeatable benchmark suites.

## License

MIT
