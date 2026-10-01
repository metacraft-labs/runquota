# Process benchmark removes a still-open observation database

Status: open. Observed at RunQuota `f93855c` in Windows x64 Reprobuild
run `36788912758`, job `110136908931`.

## Observed

All monitored actions pass. The final native cross-check runs all 100 test
programs; 99 pass and `t_m5_process_exec_bench_contract` fails in its quick
process benchmark. The benchmark compiles successfully, then reports:

```text
The process cannot access the file because it is being used by another process.
Additional info: ...\runquota-m5-process-16200\observations.sqlite3
```

`benchmarks/lib/runquota_m5_bench.nim` stops the daemon and directly calls
`removeDir(socketDir)`. On Windows that stop uses `TerminateProcess` and
waits for the daemon, without waiting for its SQLite children. Existing test
support documents this exact teardown race. The log does not identify the
file owner, so SQLite ownership of this particular lock is inferred from
that lifetime and the database path, not measured. No test timed out.

## Expected and repair

[Repository requirements](../docs/repository-requirements.md) keeps benchmarks
as executable repository checks. The established cleanup contract in
`tests/support/scratch_root.nim` requires daemon-owning fixtures to use
`removeScratchRoot`, which waits for file activity and retries Windows
removal within a fixed 30-second bound, still raising on persistent locks.

Use that shared helper for both M5 benchmark daemon scratch directories.
Include its source in the isolated benchmark copy made by the existing
integration test. Preserve real daemons, observation capture, metric checks,
the test's 600-second bound and fatal cleanup errors. Validate the existing
quick-path contract and full ordinary CI; do not swallow the removal error
or change product shutdown behavior on this evidence alone.

## Evidence

Log: `/tmp/runquota-f938-x64-repro.log`. Fetched dev `2c50aaf` and agents
`235a2b7`; searched current and archived issues for benchmark, cleanup,
SQLite, scratch and shutdown. Earlier image-retention cleanup was resolved
for integration fixtures but this standalone benchmark still uses direct
removal. The unrelated Windows WSL-Bash benchmark issue is already recorded.
