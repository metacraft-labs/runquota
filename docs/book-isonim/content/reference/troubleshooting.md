---
title: Troubleshooting
order: 2
---
# Troubleshooting

RunQuota's failures are written to name the thing that is wrong and the command
that fixes it. This page is a map from the message you got to the page that
explains it.

## The daemon exits immediately with status 3

```text
runquota endpoint directory /run/runquota: does not exist. It is created by
the RunQuota install step, never by the daemon; provision it with: ...
```

The rendezvous directory is missing. The message carries the exact command,
with the daemon's uid already filled in. See
[Provisioning a host](/getting_started/provisioning).

Status 3 is also what you get when the directory exists but is not trustworthy.
Those refusals name which check failed:

| Refusal | What it means |
|---|---|
| `refusing a path owned by uid <n> with mode <m>; this process runs as uid <n>` | Somebody else owns the rendezvous point, and *a rendezvous point another user owns is a rendezvous point another user controls*. |
| `refusing a path in group gid <n> ...; group membership is what the kernel admits callers by` | The directory's group is not the one admission is decided by. |
| `refusing mode <m>; it is group- or world-writable, so another user can replace what lives there` | The mode is too permissive. |
| `mode <m> is not a directory` | Something else is sitting at that path. |

The checks run in order — type, owner, group, mode — and on **every daemon
start and every client attach**, not once at install time.

## `runquota stats` says nothing at all

Look at the exit code first.

- **Exit 4** — the instrument is not working. Either capture is off (usually a
  host whose [state directory was never provisioned](/getting_started/provisioning)),
  or no daemon answered, or the daemon refused. Run `runquota stats capture` to
  find out which.
- **Exit 3** — the instrument is fine and there is genuinely nothing matching:
  an unknown key, an empty store, or no rows inside the scope you asked for.
  Try `--all-users` and `--all-profiles`.

The distinction is the whole point: *a caller that treats them alike will
conclude from a broken instrument that the system is fast.*

## The daemon starts but capture is off

Its third startup line says why. The common one:

```text
runquota host identity /var/lib/runquota/host-id: cannot persist -- the
host-wide state directory /var/lib/runquota does not exist ...
```

This is not a broken daemon — leases are being granted normally. Only the
recording is off. [Provision the state directory](/getting_started/provisioning)
and restart.

Other reasons, all reported the same way and all leaving admission untouched:
the `sqlite3` tool is not on `PATH`; the store's parent directory cannot be
created; the database is corrupt (it is **left untouched**, not repaired); the
schema version is unreadable; the schema is newer than this build understands
(again, the file is not modified); a table is missing; or WAL cannot be
enabled.

And one that is not a problem at all:

```text
runquota observation store: capture disabled by --no-write-stats; no
observations are recorded and no store file is opened
```

## The socket is owner-only and colleagues cannot connect

```text
(single-user mode: no group "runquota" on this host, so the endpoint is
owner-only -- directory 0700, socket 0600; create the group and restart to
serve every member of it)
```

The host has no `runquota` group. The daemon degraded rather than failing, and
is serving exactly one user. Create the group, add the users, restart. If the
group exists but is not name-resolvable on this host, set
`RUNQUOTA_ENDPOINT_GROUP` to its numeric gid — see
[Environment variables](/reference/environment_variables).

## A command runs but nothing is coordinated or recorded

There is no daemon, and RunQuota let the work through anyway. That is
[standalone mode](/getting_started/concepts#standalone-mode) and it is
deliberate. Set `RUNQUOTA_REPORT_STANDALONE=1` to be told each time it happens.

## `runquota <something>` printed the usage text and exited 0

The CLI has no `--help`; usage is what you get for anything it does not
recognise. The most common cause is a missing `--json` — `sessions`, `leases`,
`topology` and `observations` all require it and have no text renderer.

## Lease counts look wrong after a client crashed

`runquota status` reports `supervisor_lost_leases`. A client that vanishes has
its session torn down: leases it had not started are released at once, but a
lease whose child was already running becomes `supervisor_lost` and keeps its
reservation for as long as that child runs, because the child may still be
using the memory it was admitted for. The daemon releases it at the next
admission decision after the child is gone (any `RequestLease`,
`OfferCandidates` or `GrantNext`, so a client waiting in the queue is enough to
trigger it).

To see what a lost lease is waiting for, run `runquota leases --json`: each
lease carries `child_process_id` and `child_start_stamp`, the identity the
daemon recorded when the lease started running. The lease is released when that
pid no longer exists **or now belongs to a different process** (a different
start stamp), so a recycled pid does not keep it alive.
`runquota observations --json` counts the releases as `lost_leases_reaped`. A
lost lease that stays while nothing is running under its `child_process_id`
is a bug.

## The published stats table says entries are stale

```text
published stats table: /run/runquota/stats-table slots=256 ... (publisher not running; entries are stale)
```

The daemon exited and deliberately left the file behind — a table whose
publisher has gone is stale, not invalid. Start the daemon again. Nothing
depends on the table being present: it is
[a cache and never a second source of truth](/getting_started/concepts#published-aggregate-table).
