# Linux monitored process fixture aborts with heap corruption

Status: open. Observed at RunQuota `8631534`.

## Observed

Linux x64 Reprobuild job
[109617241861](https://github.com/metacraft-labs/runquota/actions/runs/36630199662/job/109617241861)
fails only `runquota.test_execute.t_m5_process_exec_bench_contract`, returning
127 after `double free or corruption (fasttop)` and `SIGABRT`. Ten assertions
pass, ending with the real daemon-protocol case; the final benchmark case does
not report a result. The same source passed full Linux Reprobuild validation
at `a9d9f40`; `8631534` changes only the Windows bootstrap monitor pin.

The Linux source bootstrap still uses io-mon `4b2bb3910283bac4d109012411e42ce67f9c969c`
from reprobuild `c14b1e6`. The Windows-only monitor override does not change it.
This observation does not yet attribute the corruption to RunQuota or io-mon.

## Expected and investigation

The [release validation spec](../../metacraft-specs/infrastructure/gosti-io-mon-runquota-releases.md)
requires the complete Linux x64 suite, including real subprocess and daemon
boundaries. Compare the unchanged actual test binary natively and under the
old/current monitor sources, with identical dependencies and all assertions
retained. Preserve the failing command output and process termination status;
do not replace the fixture with a successful exit-only probe.

Refreshed dev `e9f9011` and searched open and deleted issues for double free,
fasttop, heap corruption and allocator failures before recording this issue.
The existing Windows image-cleanup issue concerns a different failure in the
same test program. Full log: `/tmp/runquota-863-linux-repro-failure.log`.
