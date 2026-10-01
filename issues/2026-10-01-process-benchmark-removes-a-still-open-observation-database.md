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

## Candidate validation

Candidate `9f88e77`, above prepared-hook candidate `7fd57f4`, uses the
shared helper for both M5 daemon scratch roots and copies `tests/support`
into the existing isolated benchmark tree. The complete local process
contract passes with real clients, daemon and benchmark compilation. Windows
amd64 type checking and repository lint also pass. Source files were unchanged
between the local build and commit. Logs are
`/tmp/runquota-benchmark-cleanup-{build,test-build,test,windows-check,lint}.log`.
Its immutable source lock is published with verified remote blob
`07a11ba185c875496cff8d096dc2406ffb3e7310`. Full native run `36795959804`
and Reprobuild run `36795962975` are active; the issue remains open pending
Windows execution and promotion.

The real IPC quick benchmark also passes locally at `9f88e77`, covering the
second daemon scratch-root teardown. Log:
`/tmp/runquota-benchmark-cleanup-ipc.log`. No performance comparison is claimed.

## Final application qualification (2026-10-01)

The real M5 process benchmark contract passes on both Windows hosts with bounded cleanup. The original file owner remains inferred, not measured.

These results are measured at `d6ee4588f71604376a4cc41ef281d6c479395efc`
in [run 36823482913](https://github.com/metacraft-labs/runquota/actions/runs/36823482913).
All application test programs pass on the five development hosts. The ARM
workflow still fails its subsequent, separate static-helper ACL gate; that
issue remains open and is not attributed to this repaired defect.
Ordinary [CI at `2d07c5d`](https://github.com/metacraft-labs/runquota/actions/runs/36846644651)
passes all ten jobs with unchanged application sources and fixtures.
