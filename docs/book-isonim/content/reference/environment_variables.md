---
title: Environment variables
order: 1
---
# Environment variables

Every variable RunQuota's binaries read. Anything not on this list is not read.

## Endpoint and rendezvous

| Variable | Read by | Meaning |
|---|---|---|
| `RUNQUOTA_SOCKET` | daemon and clients | Overrides the endpoint path for **both** sides. On Windows a `\\.\pipe\...` value is used as-is; any other path is mapped deterministically onto a pipe name. |
| `RUNQUOTA_ENDPOINT_GROUP` | daemon and clients | Overrides the rendezvous group name (default `runquota`). **A numeric gid is accepted**, for hosts whose group is real but not name-resolvable. If it does not resolve, the endpoint degrades visibly to single-user `0700`/`0600` rather than silently widening. |
| `RUNQUOTA_ENDPOINT_OWNER_UID` | daemon and clients | Overrides the uid the rendezvous is expected to be owned by. Falls back to a lookup of the user `runquota`, then to the current uid. |
| `RUNQUOTA_USER_ENDPOINT_DIR` | launchers of the per-user daemon (`runquota_ipc.userEndpoint`) | Names the directory of the per-user daemon outright, instead of `/run/user/<uid>/runquota` (Linux, when that runtime directory exists and is yours) or `/tmp/runquota-<uid>`. Must be absolute; a relative value is an error. An isolation knob for tests, and for running a second, separate per-user daemon. POSIX only. See [Running the daemon](/usage_guide/daemon#one-daemon-per-user-on-an-unprovisioned-host). |

## Daemon lifetime

| Variable | Read by | Meaning |
|---|---|---|
| `RUNQUOTA_EXIT_WITH_PARENT_PID` | `runquotad` | Optional expected owner pid, recorded by the caller before spawning. With `RUNQUOTA_EXIT_WITH_PARENT=1`, a different current parent triggers shutdown even if the owner died before daemon entry. Removed from the environment at start; an invalid or nonpositive supplied pid requests immediate shutdown; an explicit PID 1 is valid for a container entrypoint. POSIX only. |
| `RUNQUOTA_EXIT_WITH_PARENT` | `runquotad` | Exactly `1` makes the daemon stop — through its ordinary `SIGTERM` shutdown, exiting 0 — when the process that started it exits (detected as a change of `getppid()`, polled every 200 ms; a parent of 1 at start counts as gone only without an explicitly supplied owner). The daemon removes the variable from its own environment at start whatever its value, so nothing it spawns inherits it. POSIX only; ignored on Windows. For a caller that owns its daemon; `repro` does not set it for the per-user daemon it starts, which outlives every invocation. See [Running the daemon](/usage_guide/daemon#stopping-with-the-process-that-started-it). |
| `LISTEN_PID`, `LISTEN_FDS`, `LISTEN_FDNAMES` | `runquotad` | systemd socket activation ([`sd_listen_fds(3)`](https://www.freedesktop.org/software/systemd/man/latest/sd_listen_fds.html)). With `LISTEN_PID` equal to the daemon's pid and `LISTEN_FDS=1`, it serves the listening socket on descriptor 3 instead of binding one; any other `LISTEN_FDS` is refused (exit 3). Removed from the environment at start. POSIX only. See [Running the daemon](/usage_guide/daemon#socket-activation-systemd). |

## The published aggregate table

| Variable | Meaning |
|---|---|
| `RUNQUOTA_STATS_TABLE` | Exactly the value `off` disables the table — on the publisher and on every reader. Any other value is ignored. Everything still works; estimate lookups go over the socket instead. |
| `RUNQUOTA_STATS_TABLE_PATH` | Overrides the segment path. |

## Session groups

Read by every RunQuota client when it registers a session. A launcher (an
agent session's starter) exports them; see
[Session group](/getting_started/concepts#session-group).

| Variable | Meaning |
|---|---|
| `RUNQUOTA_SESSION` | The session group to join, at most 128 bytes with no control characters (an invalid name is an error). Unset or empty: the user's `interactive` group. |
| `RUNQUOTA_SESSION_PRIORITY` | `urgent`, `high`, `normal` or `low`: the group's priority if this session creates it. Any other value is ignored. |
| `RUNQUOTA_SESSION_CACHE_TTL` | Whole seconds until the group's prompt cache expires: its cache deadline, if this session creates it. Any other value is ignored. |

The two attributes are starting values only: a session that joins an existing
group does not reset them.

## Client behaviour

| Variable | Default | Meaning |
|---|---|---|
| `RUNQUOTA_HANDSHAKE_TIMEOUT_MS` | `30000` | Milliseconds a client waits on a **control handshake** before giving up so it can fall back to standalone. `0` restores unbounded blocking. It never bounds the long-running grant stream — that one is supposed to wait. |
| `RUNQUOTA_REPORT_STANDALONE` | unset | Any non-empty value makes a daemonless `runquota acquire` print its degradation to **stderr**. Off by default on purpose: a missing daemon is not an error, and a wrapper that complained about one on every host without it would be a wrapper nobody could adopt incrementally. |
| `RUNQUOTA_REPORT_ESTIMATE_SOURCE` | unset | Any non-empty value makes `acquire --stats-key` print which of the three [estimate](/getting_started/concepts#estimate) paths answered, and with what. |
| `RUNQUOTA_RUN_WIDTH`, `RUNQUOTA_RUN_STATS_KEY` | _set by `runquota run`_ | Exported to the command `runquota run` starts: the grant in whole slots and the stats key the lease carries. Not read by RunQuota itself. |
| `RUNQUOTA_MEASUREMENT` | the defaults | Measurement switches for the measurements the **launching client** takes, read from the launcher's own environment at every launch (never the child's): `NAME=on\|off[,NAME=on\|off...]`, applied left to right, `all=on\|off` for every name. The same syntax and names as `runquotad --measurement`; see [Measurement switches](/usage_guide/observations#measurement-switches). A value that does not parse is reported once on stderr and the defaults are used: a measurement switch never stops a build. |

## Platform

| Variable | Meaning |
|---|---|
| `RUNQUOTA_PROC_ROOT` | The Linux host backend's `/proc` root. A test affordance; default `/proc`. |
| `USERNAME` | Windows only. Sanitised into the named-pipe path `\\.\pipe\runquota-<token>`, falling back to `default`. |

## What is deliberately *not* read

`HOME`, `XDG_STATE_HOME`, `XDG_RUNTIME_DIR`, `TMPDIR` and `LOCALAPPDATA` are
**not** consulted when locating host state. The host identity is host-wide by
construction, and a per-user environment override would reintroduce, per user,
exactly the divergence that constant exists to remove.

## Build-time only

These are read by RunQuota's own build and test scripts, not by the shipped
binaries: `RUNQUOTA_BUILD_MODE` (`release` for an optimised build),
`RUNQUOTA_TEST_TIMEOUT`, `RUNQUOTA_TEST_KILL_GRACE`,
`RUNQUOTA_ALLOW_MISSING_SQLITE`, `SHM_LEASE_SRC`, `REPROBUILD_SRC`.
