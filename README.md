# RunQuota

> **Status:** M0 repository skeleton

RunQuota is the local resource lease coordinator used by Reprobuild and other
tools that launch concurrent process trees.

M0 establishes the public repository shape, policy checks, compileable Nim
library skeletons, and ARC/staticlib checks for helper libraries.

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
