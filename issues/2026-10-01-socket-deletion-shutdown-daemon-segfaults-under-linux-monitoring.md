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

## Search

Fetched `agents` and `dev` at `d48e196` and `0389129`. Searched current and
archived issues for SIGSEGV, exit 139, and SIGTERM crashes; no matching record
exists. Local log: `/tmp/runquota-d48-linux-x64-repro-promotion.log`.
