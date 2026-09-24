---
title: Running the daemon
order: 1
---
# Running the daemon

`runquotad` is the lease authority: **one per host, serving every user on it**.
Bounding load on a machine requires a single authority over that machine's
resources — per-user daemons would each admit work against their own view of a
budget they in fact share.

Before it will start, the host must be
[provisioned](/getting_started/provisioning).

## Starting it

```sh
runquotad                 # with the defaults
runquotad --cpu-milli 32000 --memory-bytes 68719476736
```

Under Nix, prefer the service: `services.runquotad.enable = true` on NixOS,
or the `runquotad` nix-darwin module on macOS. On Windows it runs as an SCM
service named `runquotad`.

`runquota daemon start` is the convenience path: it checks whether a daemon is
already answering, and only if not spawns a detached `runquotad` **with no
arguments**, then polls for readiness. Idempotent; the budget it gets is the
host file's (below), or the defaults when there is none. For flags,
start the daemon yourself or use the service.

## Configuring the budget

### The host file

One daemon serves the whole host, so its budget belongs to the host, not to
whichever shell started it. `runquotad` reads it at start from:

| OS | Path |
|---|---|
| Windows | `C:\ProgramData\runquota\runquotad.toml` |
| Linux, macOS | `/etc/runquota/runquotad.toml` |

```toml
schema = "runquota.host-config.v1"

[machine]
memory_bytes = 103_079_215_104   # 96 GiB
cpu_milli    = 16000

[pools]
compile = 8
fetch   = 2
```

Every key is optional; an absent one keeps the default in the table below. A
flag given on the command line overrides the file for that launch. The file is
read once, at start: restart the daemon to apply a change.

The reader accepts exactly this shape: a `schema` string, positive integers in
`[machine]` and `[pools]`, `_` between digits, and `#` comments. Anything else
is refused with the file and line, and the daemon exits **2** without starting,
because a budget file that was half-read would look configured when it is not.
A missing file is not an error, and the daemon never creates the file or its
directory.

A daemon that reprobuild starts for you reads the same file, and reprobuild
passes budget flags only for the keys the file leaves unset.

### Flags

`runquotad --help` prints the full list. The ones that shape admission:

| Flag | Default | Meaning |
|---|---|---|
| `--cpu-milli N` | detected cores × 1000 | Host CPU budget; `1000` is one core. |
| `--memory-bytes N` | 16 GiB | Host memory budget. |
| `--io-slots N` | `1` | Concurrent heavy-I/O slots. |
| `--machine ID=CPU_MILLI,MEMORY_BYTES[,IO_SLOTS[,CPU_SHARE_GROUP]]` | one implicit machine, `local` | A named capacity. Omitted I/O slots inherit `--io-slots`; an omitted share group defaults to the machine's own id. |
| `--cpu-share-group ID=CPU_MILLI` | derived | A CPU cap shared across machines. |
| `--pool NAME=UNITS` | none | An arbitrary named counter. |
| `--socket PATH` | the rendezvous socket | Where to listen. A path you name here is created on demand; the host-wide one never is. |

Memory pressure:

| Flag | Default | Meaning |
|---|---|---|
| `--memory-pressure-source host\|deterministic-file\|unavailable` | `host` | Where the pressure reading comes from. |
| `--memory-pressure-file PATH` | — | The file `deterministic-file` reads. |
| `--memory-pressure-required` | off | Treat an unavailable reading as a refusal rather than a shrug. |
| `--memory-pressure-heavy-bytes N` | 512 MiB | The threshold a request counts as heavy at. |

Recording (see [the observation store](/usage_guide/observations)):

| Flag | Default | Meaning |
|---|---|---|
| `--observation-db PATH` | beside the host identity file | Where to record. |
| `--no-write-stats` | off | **The off switch, and the only one.** Wins over `--observation-db` regardless of order. |
| `--estimate-db PATH` | — | The learned-estimate database. |
| `--ambient-sample-interval-millis N` | `1000` | Host-wide sampling cadence; `0` turns sampling off. |
| `--host-identity-file PATH` | `/var/lib/runquota/host-id` (`/var/db/...` on macOS) | Relocates the host state, and the store with it. |

Retention — four bounds, each with the **same unusual rule**:

| Flag | Default |
|---|---|
| `--retention-sweep-interval-millis N` | 1 h (`0` or negative turns retention off; capture stays on) |
| `--retention-max-deferred-sweeps N` | `24` |
| `--retention-max-execution-age-millis N` | 90 days |
| `--retention-max-executions N` | `2000000` |
| `--retention-max-ambient-sample-age-millis N` | 14 days |
| `--retention-max-ambient-samples N` | `2000000` |

> **A negative value turns the bound off, and zero does not.** Zero means *keep
> nothing*. This is the opposite of the convention most tools use and it is
> deliberate: "unbounded" and "keep none" are both things somebody wants, and
> collapsing them onto one value would make one of them unsayable.

An unrecognised flag is a refusal, not a warning: `unknown runquotad argument:
<arg>`, exit **2**.

## What it prints at startup: exactly three lines, always

```text
runquotad listening /run/runquota/runquotad.sock; <stats publisher report>
runquota observation store /var/lib/runquota/observations.sqlite3: schema 4; capture enabled
runquota observation store ...: host <id>; hardware profile <id>; <ambient>; <retention>; <identity>
```

1. where it is listening, plus any rendezvous degradation and the state of the
   published aggregate table;
2. the observation store — open, or the reason it is not;
3. the host identity and hardware profile.

**Three lines, unconditionally.** It used to be three when a store path was
given and one when it was not; that distinction stopped existing when capture
became on-by-default, and a fixed count is what lets a supervisor read the
daemon's startup without guessing how much to read. Anything a message would
have embedded a newline into is folded onto one line to keep the count true.

Then it exits **3** without printing any of that if the rendezvous directory is
missing or untrustworthy — that check runs before anything else starts.

## Shutting it down

`runquotad` handles `SIGTERM`. Getting a blocking `accept` to notice a signal
is the whole difficulty: a flag the accept loop cannot see is a flag it will
never act on, and the kernel delivers the signal to an arbitrary thread. So the
daemon **dials its own socket** — a waker thread parked on a pipe wakes when
the handler writes to it and opens one connection, `accept` returns it, the
loop sees the flag and breaks into the shutdown path.

Shutdown then stops the connection queue, joins the workers, stops the
aggregate publisher, and stops the retention sweeper **before** the observation
writer, so a sweep in flight cannot outlive the writer it depends on.

The stats-table file is deliberately **left behind**. A table whose publisher
has exited is stale, not invalid, and a reader that finds it says so:
`(publisher not running; entries are stale)`.

## When things go wrong at runtime

A failed `accept` is counted (`connections_failed` in `runquota status`) and
printed **once**:

```text
runquota accept failed: <msg> (this is counted as connections_failed and not printed again)
```

After 64 consecutive failures the daemon gives up on the endpoint and says so
rather than spinning silently.
