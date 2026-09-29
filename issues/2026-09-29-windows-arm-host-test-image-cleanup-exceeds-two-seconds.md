# Windows ARM-host test cleanup cannot remove finished executable images

Status: open. Observed at RunQuota `177e2af`.

## Observed

Ordinary ARM-host job
[109548617782](https://github.com/metacraft-labs/runquota/actions/runs/36609966396/job/109548617782)
passes the functional checks in three nested-build fixture programs, then
fails `removeScratchRoot` with access denied on `runquotad.exe`, `hello.bin`
or `passing.exe`. The helper already retries Windows removal for two seconds.
The failing programs are `t_m5_process_exec_bench_contract`,
`t_observation_store_degraded_capture_build` and
`t_standalone_daemonless_degradation`.

This resembles the separately recorded MSI extraction cleanup problem on the
same host architecture. That earlier control established delayed release of
an x64 image after its processes exited, but this observation has no process
or file-owner census and does not yet prove the same cause.

## Expected and investigation

The [release validation spec](../../metacraft-specs/infrastructure/gosti-io-mon-runquota-releases.md)
requires both complete test paths without discarding cleanup failures. Compare
the same fixtures natively and under the selected monitor, record remaining
process/file owners, and keep a bounded fatal cleanup gate. Do not kill unrelated
processes or silently retain fixture trees. Shared diagnostic `d04a676` runs
these comparisons in `36618038706` with unchanged deadlines and assertions.

Refreshed dev `e9f9011`, searched open and deleted issues for cleanup, scratch
roots and retention. The MSI cleanup issue covers installer extraction; the
compiler-directory issue concerns read-only directory modes. Neither establishes
why these test executable images remain undeletable.
