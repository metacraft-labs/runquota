# Daemon crashes during the monitored socket-deletion shutdown test

| | |
|---|---|
| Status | open; attribution pending |
| Recorded | 2026-10-01 |
| Observed in | RunQuota `d48e196bb6817d2d543c3ef8ff85d21acee0c892` |
| Area | daemon SIGTERM teardown under Linux x64 Reprobuild |

## Observed

[Job 110474890553](https://github.com/metacraft-labs/runquota/actions/runs/36893338411/job/110474890553)
finishes the 209-action graph with one failed execution:
`t_sigterm_exits_with_the_socket_gone`. The socket-only case reports:

```text
No stack traceback available
SIGSEGV: Illegal storage access. (Attempt to read from nil?)
socket unlinked: exit=139 after 300.1 ms
Check failed: ending.exitCode == 0
ending.exitCode was 139
```

The case that removes the complete scratch tree exits 0 and passes. The same
runtime sources passed the complete Linux ARM64 Reprobuild graph twice in
diagnostic `36892684878` at `b92dcbf`, derived from `020e695`, and the native
Linux/macOS suites at `020e695`. The `e00f5d6` fixture change only guards its
POSIX helper declaration on Windows; it does not change the POSIX helper or
case bodies. No cause or frequency has been established from this one crash.

## Expected

[Daemon shutdown](../docs/book-isonim/content/usage_guide/daemon.md) and the
fixture's header require a real served daemon to finish orderly shutdown after
its socket has been removed. Exit 139 violates that contract. Preserve the
exit-zero assertion and the existing shutdown budget.

## Investigation

Retain a core backtrace and compare repeated executions of identical binaries
with and without the outer monitor. The source-bootstrap pins are Reprobuild
`c14b1e6` and Linux io-mon `3df08c2`. A daemon teardown race and monitor
interference are hypotheses, not established causes. Do not isolate this test
merely because the observed failure happened under monitoring: unlike io-mon's
injection fixtures, it does not install a monitor of its own.

## Repeated Linux control

[Diagnostic `94b1782`](https://github.com/metacraft-labs/runquota/actions/runs/36904880141)
passes all 30 native/monitored pairs (60 fixture executions, 120 shutdown
cases), preserving the original exit and timing assertions. Every monitored
execution reports `launched=true`, `cdNotCacheable`, and `dgAutomaticMonitor`.
No crash or core was produced. The daemon SHA256 is
`fd7dbb403e99f8f6dd8d62814075722e6e911edc35818b90406890e6f0b93676` and
the fixture SHA256 is
`a5a35a737c6945943b492cd97ca91196026671d9132f744fb65770b59904fa7a`;
both remain identical across all pairs. Production runtime sources still match
`5c0de8f`; only the separate live-directory-removal fixture repair `ecbd0e3`
is added. That repair also survives all 60 executions.

The earlier diagnostic `5e6cb15` found the directory-removal race instead of
the crash. Its `ENOTEMPTY` failure is distinct from the socket-only exit 139.
The original crash remains unattributed. Repeat the complete Linux graph with
core capture to retain the concurrent suite conditions of the original job.
Evidence: `/tmp/runquota-94b-linux-daemon-controls`.

## Full-suite reproduction and thread storage

[Diagnostic `3aba051`](https://github.com/metacraft-labs/runquota/actions/runs/36925496086)
has the same `libs/`, `apps/` and `tests/` tree as candidate `102734d`.
It disables test-result caching while retaining the original graph dependencies
and monitoring policies. The first complete graph executes all 103 tests and
passes. The repeat reproduces the socket-only crash, exit 139 after 30.5 ms,
while the scratch-tree case passes. The daemon and fixture hashes match the
earlier 60-execution control above.

The retained core backtrace identifies the crashing worker's exit path:

```text
free
deallocThreadStorage
threadProcWrapper
start_thread
```

The main thread is joining workers in `serve`; the capture opener is still
opening SQLite. A second daemon core from the first graph has the same stack,
although that graph's assertions passed. The stats-table test also produces
expected SIGSEGV cores by writing through a read-only mapping; those are
separate, intentional negative controls.

At `102734d`, `serve` appends a `Thread[void]` to a sequence and starts it on
each loop iteration. Later appends can relocate already-started thread objects.
The inspected Nim 2.2.4 runtime passes `addr(t)` to `pthread_create` and uses
that pointer both when entering and when marking the thread stopped. This is
a concrete lifetime violation consistent with the captured crashes. Allocate
the complete worker sequence before starting any worker, then verify the
repair with the real shutdown fixtures and failing original-source controls.

Native sanitizer diagnostic `ead2e32` passed 30 executions with Nim's normal
allocator; its GCC 15.2 build differs from the monitored GCC 13 build. Check
the lifetime hypothesis with an instrumented allocation path as well as the
unchanged ordinary graph. Do not waive the original assertions or monitoring.

Fetched `agents` at `102734d` and `dev` at `0389129`; searched archived
thread-storage and worker-reallocation issues before extending this record.
Backtraces and summaries: `/tmp/runquota-3aba-full-graph-evidence`.

## Search

Fetched `agents` and `dev` at `d48e196` and `0389129`. Searched current and
archived issues for SIGSEGV, exit 139, and SIGTERM crashes; no matching record
exists. Local log: `/tmp/runquota-d48-linux-x64-repro-promotion.log`.
