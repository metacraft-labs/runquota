---
title: Reading the history
order: 3
---
# Reading the history — `runquota stats`

Three verbs over everything RunQuota has recorded:

```text
runquota stats capture [--json]
runquota stats top    [KEY] [--limit N] [--all-users] [--all-profiles] [--json]
runquota stats export [KEY] [--limit N] [--all-users] [--all-profiles] [--json]
```

Every one of them goes **over the socket**. `runquotad` is the only sanctioned
reader of the store, so these commands ask it rather than opening the database
— which is what gets you uid scoping and hardware qualification for free
instead of silently skipping both.

## Why three and not thirteen

The obvious design is a verb per question: rank, rows, spread, compare. The
trouble is that the next question is always the one that is not there, and the
usual answers — a filter grammar, a query language — are things a caller has to
be *taught*.

`export` sidesteps the category. It emits one JSON object per recorded
execution, carrying every column the schema holds, and stops. Ranking,
percentiles, before-and-after, bimodality and every question nobody has thought
of yet are `jq` expressions over that, written by somebody who already knows
`jq`. **RunQuota ships facts; you do the analysis.**

`capture` stays because whether this host is recording at all is the one thing
that is not general knowledge. `top` stays because it answers the most common
question in one step.

## An empty result must never look like a healthy one

The query layer returns nothing when capture is off — and on a host whose state
directory was never provisioned, "which of my tests are slowest" answers
*nothing*, which reads exactly like "no slow tests".

So every verb reports a **status** naming which kind of nothing it is, and the
exit code separates the kinds:

| Exit | Statuses | Meaning |
|---|---|---|
| **0** | `ok` | Rows came back. |
| **3** | `no-data`, `unknown-key`, `no-rows-in-scope` | **The question has no answer.** Capture is on; there is simply nothing matching. |
| **4** | `capture-off`, `daemon-unreachable`, `denied` | **The instrument is not working.** |

Three and four are different on purpose. *A caller that treats them alike will
conclude from a broken instrument that the system is fast.*

## `stats capture`

Whether this host is recording, and why not if it is not.

```console
$ runquota stats capture
runquota stats capture
capture: ON   status: ok
daemon detail: {...}
```

Caveats, when they apply, are printed as `! ` lines. The one you will see on an
unprovisioned host:

```text
! capture is OFF on this daemon: nothing has been recorded and nothing will be.
  This is NOT an empty result — it is an absent instrument.
```

## `stats top`

The heaviest keys, in one step.

```sh
runquota stats top                     # every key
runquota stats top build.compile       # one key
runquota stats top --limit 50          # default is 20
```

Columns are `total`, `n`, `max` and `key`, with durations in milliseconds.

**Rankings are never pooled across hardware profiles.** The same command on a
laptop and on a 64-core builder is not the same measurement, and a CLI that
flattened them would undo that at the last possible moment. So the output is
grouped by hardware profile, each group a separate answer, and when there is
more than one you are told so.

A ranking is `total`, `count` and `max` only, and it **sums across capture
grades**. For anything else — percentiles, before-and-after, the grade of each
row — use `export` and `jq`. The command says so itself rather than letting you
read a ranking as more than it is.

## `stats export`

Every recorded column, one JSON object per execution.

```sh
runquota stats export | jq -s 'group_by(.stats_key) | map({key: .[0].stats_key, p95: (map(.duration_millis) | sort | .[(length*0.95)|floor])})'
```

**NDJSON on stdout, status on stderr.** A status line mixed into the stream
would break the `jq` pipe that is the entire point of the verb; an exit code
and a stderr line break nothing and are visible to both a human and a script.
Pass `--json` if you would rather have one self-describing document, rows and
metadata together, on stdout.

`--limit` defaults to **250** and is capped at **600** — a full row is about
1.4 KB on the current schema, so 600 rows is roughly 855 KB against a 1 MiB
frame limit. A larger value is refused (exit 2) rather than silently truncated.

> The rows you get are the **newest** `--limit` rows and **there is no older
> page**: the protocol carries a row limit but no time cursor, so a deeper
> history needs a larger `--limit`, not a second call. The command tells you
> this when the limit binds.

## Scope

| Flag | Default | With the flag |
|---|---|---|
| `--all-users` | your own uid only | every uid on the host |
| `--all-profiles` | this host's hardware profile only | every hardware profile |

The uid comes from **peer credentials on the socket**, not from anything the
client claims. The scope actually applied is printed in the header of every
answer, so a narrowed result never looks like a whole one.
