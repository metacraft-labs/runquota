# POSIX shutdown test helper is compiled on Windows

| | |
|---|---|
| Status | open |
| Recorded | 2026-10-01 |
| Observed in | RunQuota `020e6953791355133425a0547e3c0291205eb38c` |
| Area | `tests/integration/t_sigterm_exits_with_the_socket_gone.nim` |

## Observed

[Windows x64 Reprobuild job 110454460565](https://github.com/metacraft-labs/runquota/actions/runs/36887279486/job/110454460565)
completes 105 of 106 build actions, then the new shutdown test fails to compile:

```text
t_sigterm_exits_with_the_socket_gone.nim(171, 17) Error: undeclared identifier: 'Pid'
```

Both test cases and the `std/posix` import already require `defined(posix)`.
Their `termAndWait` helper is unconditional, so Windows still type-checks its
POSIX `kill`, `Pid`, `SIGTERM`, and `SIGKILL` references. The compiler in this
job is the declared Windows Nim 2.2.8 tool. The ordinary Windows gate compiles
the applications and packaging checks; the Reprobuild graph compiles the full
test catalog and exposes this omission.

## Expected

[Daemon shutdown](../docs/book-isonim/content/usage_guide/daemon.md)
documents the real POSIX shutdown path and the portable endpoint-based stop.
The fixture itself specifies POSIX-only signal/socket-unlink cases because
Windows uses named pipes and has no POSIX signals. Apply that existing scope
to the helper declaration as well. Preserve both test bodies, their deadlines,
and all assertions; do not alter the native Windows daemon tests.

## Evidence and search

Fetched `agents` and `dev` at `fb14e60` and `0389129`; the fixture was introduced
by `478b459` and is unchanged in those consumer revisions. Searched open and
deleted issues for SIGTERM, signal fixtures, and undeclared Pid. No matching
record exists. Local CI log: `/tmp/runquota-020-windows-x64-repro-promotion.log`.
