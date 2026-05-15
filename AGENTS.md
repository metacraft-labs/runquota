# RunQuota Agent Instructions

## Commands

- Build: `just build`
- Test: `just test`
- Lint: `just lint`
- Format: `just format`
- Static helper gate: `just check-static-helpers`
- Repository contract check: `just check-repo-requirements`

## Structure

- `libs/` contains importable Nim libraries. Static helper libraries are listed
  in `libs/static_helpers.txt`.
- `apps/runquota/` is the CLI.
- `apps/runquotad/` is the per-user lease authority daemon.
- `tests/` contains repository-level tests.
- `benchmarks/` contains repeatable benchmark suites.

## Boundaries

- `runquotad` is a lease authority. It must not spawn, sandbox, monitor, or kill
  client process trees.
- Client-side process helpers live in `runquota_process` and `runquota_exec`.
- Static helper libraries must compile with `--mm:arc --app:staticlib` and must
  not define or use Nim `ref` types.
- JSON may be emitted for inspection output, diagnostics, or benchmark reports.
  It must not define persistent or wire state.
- Workspace source revisions come from workspace locks, not repo-local sibling
  pin files.
