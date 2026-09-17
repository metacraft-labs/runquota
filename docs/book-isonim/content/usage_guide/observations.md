---
title: The observation store
order: 4
---
# The observation store

A durable, append-only record of what every admitted execution actually cost:
one row per executed process, plus the host-wide ambient load around it. It is
what turns "how much memory will this need?" from a guess into a measurement,
and it is what [`runquota stats`](/usage_guide/stats) reads.

## Capture is on without any flag

The store is **enabled by default**. Nothing can retroactively enable capture
for the week that would have answered "did this test ever pass on this host" —
an opt-in store is empty exactly when it is first needed.

Three ways to say where, in precedence order:

| Setting | Effect |
|---|---|
| `--no-write-stats` | Capture off. Nothing is opened, no store file and no host identity file is created, and admission carries on untouched. **Wins over `--observation-db`.** |
| `--observation-db PATH` | Capture into `PATH`. |
| neither | Capture into the host default. |

The host default is `<host state directory>/observations.sqlite3` — beside the
host identity file, in the directory the
[install step provisions](/getting_started/provisioning). The two are derived
from one another rather than being two constants, so relocating the host state
with `--host-identity-file` relocates the store with it and the two can never
disagree.

On a host where the state directory was never provisioned, capture degrades to
**off**, with a report naming the directory and the command that creates it.
The daemon keeps admitting leases: an advisory subsystem may not take out a
machine's build capacity.

## Only the daemon reads it

`runquotad` is the **only sanctioned reader**. No client opens the database
file. Queries go over the socket, where the daemon does two things a direct
reader would silently skip:

- **scopes the answer to the calling uid**, taken from peer credentials rather
  than from anything the client says;
- **qualifies every answer with the hardware profile it describes**, so two
  machines' measurements are never pooled into one number.

Two more rules hold on every answer: *unknown is not zero* — the absence of a
measurement is reported as absent, never as a value — and *a client's own
estimate is never second-guessed*.

## What is in it

A spine of `runs` and `executions`, plus `hosts`, `host_profiles`,
`ambient_samples` and an `extension_registry`. Rows are immutable once written,
enforced in the database itself.

Because the daemon does not monitor client process trees — it is a lease
authority, not a supervisor — the **per-execution figures are client-reported**.
The daemon samples only host-wide totals, and derives foreign load by
difference.

`executions.owner_uid` comes from peer credentials, and is `NULL` rather than
`0` where credentials were unavailable — because `0` is root, and a row that
said root when it meant "unknown" would be worse than no row.

## Retention

A sweeper thread prunes on a cadence, against four optional bounds — age and
count, for executions and for ambient samples. Remember that
[**a negative value turns a bound off and zero does not**](/usage_guide/daemon).

Ordering is deliberate: the age bound runs first, the count bound second, each
pass is one transaction, and `hosts`/`host_profiles` are never deleted — losing
the dimension tables would orphan every row that survived. A sweep prefers an
idle machine and is deferred while any lease is live, up to
`--retention-max-deferred-sweeps` ticks, after which it runs anyway and is
counted as forced. A failed sweep increments a counter, keeps its reason, and
changes nothing else.

## Extension tables

A product built on RunQuota can declare its own table: an id, an owner, a
schema version and a forward-only migration ladder. RunQuota creates
`ext_<extension_id>`, migrates it forward, accepts an older client unchanged,
and refuses one declaring a version it cannot reach.

**RunQuota never interprets an extension column.** It creates, migrates, prunes
and merges those tables; what is in them is the declaring product's business.
That is structural rather than a matter of care: no concrete extension table
name may appear anywhere in RunQuota's own source, and the only column names it
may write into a statement against one are the spine key it joins by — every
other column name having arrived from the caller.

## Copying, merging and exporting

- **Backup** is a `VACUUM INTO` copy, safe to take while the daemon is running.
- **Merge** is an append-only union with no clock and no conflict resolution.
  Rows are deduplicated by `(host_id, execution_id)` and friends. A row from an
  extension this store does not know, or knows at an older version, is
  **carried** rather than dropped — kept verbatim and marked non-queryable
  until something can interpret it. A source without the host and hardware
  dimensions is refused outright.
- **Export** applies a redaction policy — `none`, `default` or `strict` — at
  export time and never at capture, so the local store always holds the truth.
  A redacted value becomes `[redacted:<category>:<16 hex of sha256>]`, which is
  stable and therefore still groupable. It is explicitly **not** a defence
  against somebody who can guess the value and hash it. The policy is recorded
  in the destination so a reader knows what they are looking at.

Merge, backup and export are library operations today; there is no CLI verb for
them yet.
