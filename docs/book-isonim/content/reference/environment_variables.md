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

## The published aggregate table

| Variable | Meaning |
|---|---|
| `RUNQUOTA_STATS_TABLE` | Exactly the value `off` disables the table — on the publisher and on every reader. Any other value is ignored. Everything still works; estimate lookups go over the socket instead. |
| `RUNQUOTA_STATS_TABLE_PATH` | Overrides the segment path. |

## Client behaviour

| Variable | Default | Meaning |
|---|---|---|
| `RUNQUOTA_HANDSHAKE_TIMEOUT_MS` | `30000` | Milliseconds a client waits on a **control handshake** before giving up so it can fall back to standalone. `0` restores unbounded blocking. It never bounds the long-running grant stream — that one is supposed to wait. |
| `RUNQUOTA_REPORT_STANDALONE` | unset | Any non-empty value makes a daemonless `runquota acquire` print its degradation to **stderr**. Off by default on purpose: a missing daemon is not an error, and a wrapper that complained about one on every host without it would be a wrapper nobody could adopt incrementally. |
| `RUNQUOTA_REPORT_ESTIMATE_SOURCE` | unset | Any non-empty value makes `acquire --stats-key` print which of the three [estimate](/getting_started/concepts#estimate) paths answered, and with what. |

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
