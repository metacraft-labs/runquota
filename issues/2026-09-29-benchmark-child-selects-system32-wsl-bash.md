# Benchmark child selects the System32 WSL stub instead of Git Bash

| | |
|---|---|
| Status | in-progress; fix/release-validation-failures |
| Recorded | 2026-09-29 |
| Observed in | RunQuota `718598e`, diagnostic `36568279172` |
| Area | `t_m5_process_exec_bench_contract.nim` |

## Observed

The real benchmark fixture passes bare `bash` to the Windows process launcher.
Captured stdout says `Windows Subsystem for Linux has no installed distributions`.
It exits 1 both with hosted Git Bash and with checksum-pinned PortableGit first
on PATH. The diagnostic's PowerShell invocation of Bash builds the native apps
successfully. The failure is Windows executable search choosing the System32
stub before the PATH entry; it does not indicate a missing Linux distribution
needed by this native Windows benchmark.

## Expected

The benchmark contract uses the same native Bash tool as its Just recipe.
Resolve `bash` from PATH and pass its explicit executable path to
`runCapturedProcess`, preserving the real copied-source build and all benchmark
assertions. The two shell installations provide independent native controls.
The earlier full-graph access violation must be checked again after this
repair; the WSL diagnostic alone does not establish its cause.

## Evidence

Artifact `runquota-windows-focused-718598e` records both child outputs, the
PortableGit path, native compiler selection, and real app build. The unchanged
connection-cleanup and monotonic latency tests pass (0.3195/0.3102 ms medians).
Refreshed `origin/dev` at `e9f9011`; current/deleted issue searches for WSL and
benchmark Bash found only the broader tool-store diagnosis, now refined here.
