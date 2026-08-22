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
- `apps/runquotad/` is the host-wide lease authority daemon: ONE PER HOST,
  serving every user. Bounding load on a machine requires a single authority
  over that machine's resources, and per-user daemons would each admit against
  their own view of a budget they in fact share. Everything scope-related
  follows from this — the rendezvous directory is verified rather than assumed,
  `host_id` is host-wide state, and `owner_uid` comes from peer credentials.
- `tests/` contains repository-level tests.
- `benchmarks/` contains repeatable benchmark suites.

## Boundaries

- `runquotad` is a lease authority. It must not spawn, sandbox, monitor, or kill
  client process trees.
- Client-side process helpers live in `runquota_process` and `runquota_exec`.
- Extension tables are owned by the product that declares them. RunQuota
  creates, migrates, prunes and merges them and must not interpret extension
  columns. Two rules make that structural rather than a matter of care: every
  extension table name is composed from the `ext_` prefix and the registered
  `extension_id`, so no concrete extension table name may appear in `libs/` or
  `apps/` source; and the only column names RunQuota may write into a statement
  against one are the spine key it is joined by, every other column name having
  arrived from the caller.
- Static helper libraries must compile with `--mm:arc --app:staticlib` and must
  not define or use Nim `ref` types.
- JSON may be emitted for inspection output, diagnostics, or benchmark reports.
  It must not define persistent or wire state.
- Workspace source revisions come from workspace locks, not repo-local sibling
  pin files.
