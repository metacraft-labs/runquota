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

## Measurement switches

Everything RunQuota records about a build costs the build something, and the
total is budgeted: with every measurement on, a build may take at most 1% more
wall time and 1% more CPU time than with every measurement off. To check that
(`just bench-overhead-gate`, see the repository's `benchmarks/README.md`) each
measurement has a name and a switch:

| Name | Taken by | Status |
|---|---|---|
| `capture` | the daemon: execution rows, extension rows and self-reports into this store | on by default |
| `ambient-sampling` | the daemon: the host-wide load sampler | on by default |
| `tree-sampling` | the launching client: samples of the child tree's resident memory and process count while it waits, which become the finish's summed peak memory | on by default |
| `profiles` | the launching client: a CPU profile of the child tree (Linux), see "CPU totals and profiles" below | off by default |
| `metrics-export` | the daemon: the [capacity figures text file](/usage_guide/daemon#exporting-capacity-figures-for-prometheus) | off unless `runquotad --metrics-textfile PATH` names a file; `metrics-export=on` without one is refused |
| `pressure-reports`, `sizing-data` | — | registered, not implemented yet: the switches are accepted and do nothing |

A switch is `NAME=on|off`, comma-separated and applied left to right;
`all=on|off` covers every name. The daemon takes it as `runquotad
--measurement VALUE`; the launching client (`runquota acquire`, Reprobuild)
takes it from `RUNQUOTA_MEASUREMENT`. Both accept every name, so one value can
be given to both; a name taken by the other side is ignored. With
`tree-sampling=off` a finish carries no sampled peak; its peak memory is then
the largest single process from the launcher's wait (`ru_maxrss`), which
needs no sampling.

## CPU totals and profiles

Every finish from a launching client (`runquota acquire -- CMD`, Reprobuild)
carries the tree's CPU time (user and system), its largest single resident
set and its duration, read from the rusage of the launcher's `wait4` for the
tree's root. They cover every process of the tree that was waited for. A
process that leaves the tree before it is waited for, such as a daemonising
grandchild or a background job its shell never waited for, is re-parented to
init and reaped there, and its CPU is missing from the totals. A daemon older
than protocol minor 4 is sent the finish without them, and the row's CPU
columns stay NULL.

With `RUNQUOTA_MEASUREMENT=profiles=on` the launcher also records when the
CPU was used. It reads its own descendants from `/proc` once per interval
and sends CPU used per interval in milli-CPUs. The interval starts at one
second. When a run outgrows 256 samples, adjacent pairs merge and the
interval doubles, so a profile never holds more than 256 samples and the
reads get rarer as the run lengthens. The profile is stored in
`execution_cpu_profiles` (schema version 7), one row per execution, removed
with it by retention. The daemon folds the profiles of uncontended runs, and
the totals of every run, into the command's learned CPU estimate: a 20-point
curve of CPUs against the fraction of the run elapsed, and an expected
duration per granted width. These are reported under `cpu_estimates` in the
`estimates` inspection subject. A run counts as uncontended when everything
else on the host used at most `--profile-uncontended-pct` of its CPU over the
run, judged from the ambient samples.


`runquota observations --json` reports the switches in force under
`measurements`: `on` or `off` for the daemon's own measurements, `client` for
one the launching client takes, `not-implemented` for one that does not exist
yet.

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
