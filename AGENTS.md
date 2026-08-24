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
- `runquotad` is the only sanctioned reader of the observation store. No client
  may open the database file directly: queries go over the socket, where the
  daemon scopes them to the calling uid from peer credentials and qualifies
  every answer with the hardware profile it describes. A client that read the
  file would skip both, silently, on a schema RunQuota owns. Arbitrary reads
  are request/response on the socket and must never be placed on the
  observation ring, which is a one-way write path of the opposite shape.
- A client-supplied estimate on a lease request is taken at face value. RunQuota
  must not clamp it, second-guess it, or validate it against its own learned
  table; the learned estimate is the fallback when none is supplied.
- `runquotad` is the only writer of the published aggregate table, and no client
  may hold a writable mapping of it. It is the one host-wide segment in the
  design — daemon-owned, group-readable, `0640` — and it is safe to share
  precisely because no client can write it. The daemon must not read it back as
  authority either: it is published output, and a daemon decision that depended
  on it would depend on a page outside its own address space.
- The published aggregate table is a cache and never a second source of truth.
  The socket must be able to answer anything it can, and no behaviour may exist
  only while an entry is resident — which is what lets the table be dropped,
  resized or skipped in a degraded mode with no correctness argument at all.
- Static helper libraries must compile with `--mm:arc --app:staticlib` and must
  not define or use Nim `ref` types.
- JSON may be emitted for inspection output, diagnostics, or benchmark reports.
  It must not define persistent or wire state.
- Workspace source revisions come from workspace locks, not repo-local sibling
  pin files.
