# Stats-table position-independence test assumes ASLR chooses distinct bases

| | |
|---|---|
| Status | open |
| Recorded | 2026-09-28 |
| Observed in | runquota @ `906800c` |
| Area | `tests/integration/t_stats_table_concurrency.nim` |

## Observed

The SM-7 case prints writer and local bases both `00007FFFF7C1F000`, with reader `00007FFFF7B1F000`, and fails `uint(writerBase) != localBase`. The test already documents the same failure on WSL2 at `10147ac`; it controls the reader mapping but assumes the writer and local mappings will differ.

## Expected

[RunQuota Shared Memory Transport, SM-7](https://github.com/metacraft-labs/reprobuild-specs/blob/latest/RunQuota-Shared-Memory-Transport.md) requires position independence. The test must arrange its required distinct mappings and prove coherent access; dropping the assertion would discard the intended evidence.

## Evidence

[Linux test job at 906800c](https://github.com/metacraft-labs/runquota/actions/runs/36377535682/job/108786338190).
The suite ran 93 tests: 87 passed, six failed, no skips or timeouts.
These are normal-suite findings; the release payload checks passed separately.

Refreshed `origin/dev` (`f4f0f93`) and `origin/agents` (`906800c`). Searched
open issues, issue history and RunQuota milestone records before recording.
