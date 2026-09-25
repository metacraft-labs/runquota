---
title: Concepts
order: 1
---
# Concepts

The vocabulary RunQuota's flags, JSON output and error messages are written in.

## Lease

The unit of admission. A client asks for a lease before starting a piece of
work and releases it when the work is done. A request is answered with one of
three decisions:

| Decision | Meaning |
|---|---|
| **granted** | Start now. |
| **queued** | The budget cannot cover this yet; wait for a grant. |
| **denied** | This request cannot be admitted, with a reason. |

A lease then moves through **starting** → **running** → **finished**. The
running notification carries the child's process id and process-group id, so
the daemon knows what the lease is actually covering without ever touching
those processes itself.

A lease finishes with an **outcome**, and the outcomes are modelled so that
contradictory states cannot be expressed: *succeeded* carries no exit code,
*failed* carries a non-zero one, *crashed* carries a signal, *OOM-killed* and
*timed out* each carry the evidence for that claim, and there are also
*cancelled* and *launch-failed*. You cannot report "succeeded with a kill
signal".

## Session

A client registers a session — a name and a version — before it takes any
leases, and every lease is scoped to it. If a client vanishes, its session goes
with it and the daemon reclaims the leases it was holding. A lease whose child
was already running is held as `supervisor_lost` until that child is gone
(`runquota status` counts these as `supervisor_lost_leases`), because an
orphaned child may still be using its reservation. Sessions are what make a
crashed build tool a recoverable event rather than a permanently leaked budget.

## Resource vector

What a lease asks for:

| Field | Meaning |
|---|---|
| `machineId` | Which configured machine's budget to draw from (default `local`). |
| `cpu` | Milli-CPU: `1000` is one core's worth. |
| `memory` | Bytes the work is expected to need. |
| `hardMemoryLimit` | Bytes it must not exceed. |
| `ioClass` | `normal`, `heavy` or `exclusive`. |
| `processCount` | How many processes the work will run. |
| `namedPools` | Demands on arbitrary operator-defined counters. |

## Quota and budget

The budget is **configured on the daemon, not requested by clients**. It is set
with `--cpu-milli`, `--memory-bytes` and `--io-slots`, and can be subdivided:

- `--machine ID=CPU_MILLI,MEMORY_BYTES[,IO_SLOTS[,CPU_SHARE_GROUP]]` declares a
  named capacity; a host can have several.
- `--cpu-share-group ID=CPU_MILLI` caps CPU across a set of machines that share
  it.
- `--pool NAME=UNITS` declares an arbitrary named counter — a licence seat, a
  GPU, a test fixture that only exists once.

`runquota topology --json` prints the configured shape.

## Admission control

Deciding grant/queue/deny against those budgets — plus **host memory
pressure**, which the daemon reads from the OS (`--memory-pressure-source
host`), from a fixed file for reproducible tests (`deterministic-file`), or not
at all (`unavailable`). Pressure is reported as *low*, *warning*, *critical* or
*unavailable*. `--memory-pressure-required` makes an unavailable reading a
refusal rather than something to shrug at.

## Estimate

How much memory a piece of work is expected to peak at, keyed by an opaque
**stats key** the caller chooses (`--stats-key`). Three places the answer can
come from, same answer, very different cost:

1. the published aggregate table in shared memory — no syscall at all;
2. a query over the socket;
3. nothing supplied, in which case the daemon falls back to its own **learned**
   table, built from what it has recorded.

A client-supplied estimate is used **exactly as given**. RunQuota does not
clamp it, second-guess it, or check it against the learned table — the client
knows things about this particular run that no aggregate does. (Zero is a
legitimate estimate, which is why "supplied" is tracked separately from the
value.)

## Published aggregate table

A host-wide shared-memory segment the daemon publishes at
`<rendezvous dir>/stats-table`, group-readable and daemon-written. It exists so
a client can look up an estimate without a round trip.

On Windows the endpoint is a named pipe and has no directory, so the table goes
beside the path the pipe was derived from: a daemon started with
`--socket D:\rq\ep\d.sock` (or reached through `RUNQUOTA_SOCKET` set to that
path) publishes `D:\rq\ep\stats-table`. The host-wide default pipe, and any
pipe named outright as `\\.\pipe\...`, has no published table: estimates go
over the pipe instead, unless `RUNQUOTA_STATS_TABLE_PATH` names one for the
daemon and its clients alike. "Group-readable" there means the file's DACL
grants its group read, and write to nobody but its owner and the machine's
administrators.

It is **a cache and never a second source of truth**. The socket can answer
anything the table can, no behaviour exists only while an entry is resident,
and the daemon never reads it back as authority. That is what makes it safe to
drop, resize or skip — set `RUNQUOTA_STATS_TABLE=off` and everything still
works, a little slower.

## Standalone mode

If no daemon is reachable, **a missing daemon is not an error**. The work runs,
uncoordinated; the observation is buffered and dropped when the short-lived
client exits. RunQuota reports this only if you ask
(`RUNQUOTA_REPORT_STANDALONE`), because a tool that wrapped every command in
RunQuota and failed loudly on a host without a daemon would be a tool nobody
could adopt incrementally.

`runquota stats` is the exception: it distinguishes "the question has no
answer" (exit 3) from "the instrument is not working" (exit 4) precisely so a
daemonless host is never mistaken for a fast one. See
[Reading the history](/usage_guide/stats).
