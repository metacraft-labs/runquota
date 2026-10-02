---
title: The runquota CLI
order: 2
---
# The `runquota` CLI

```text
usage:
  runquota --version
  runquota status [--json]
  runquota sessions --json
  runquota leases --json
  runquota topology --json
  runquota observations --json
  runquota explain SESSION_ID
  runquota daemon start|status
  runquota config path
  runquota config show [--file PATH]
  runquota config set KEY VALUE [--file PATH] [--no-reload]
  runquota config unset KEY [--file PATH] [--no-reload]
  runquota config reload
  runquota stats-table [KEY]
  runquota stats capture [--json]
  runquota stats top [KEY] [--limit N] [--all-users] [--all-profiles] [--json]
  runquota stats export [KEY] [--limit N] [--all-users] [--all-profiles] [--json]
  runquota acquire --cpu N --mem BYTES [--label TEXT] [--machine ID] [--stats-key KEY] [--benchmark] [-- COMMAND [ARG...]]
```

There is no `--help`. Any invocation the CLI does not recognise prints this
usage and exits **0** — so if you get the usage back, look at what you typed.
`--version` is accepted only as the sole argument.

The `stats` verbs have a page of their own:
[Reading the history](/usage_guide/stats).

## Inspecting the daemon

| Command | What it tells you |
|---|---|
| `runquota status [--json]` | Live counters: sessions, leases, `supervisor_lost_leases`, finished and granted totals, and the memory-pressure reading. |
| `runquota sessions --json` | The registered sessions. |
| `runquota leases --json` | Every lease the daemon is tracking. |
| `runquota topology --json` | The configured machines and CPU share groups — the budget, as the daemon sees it. |
| `runquota observations --json` | The recording subsystem: whether capture is on, which store is open, and every counter about what has been accepted, refused, queued or dropped. |
| `runquota explain SESSION_ID` | The leases belonging to one session. |
| `runquota daemon status` | Same as `status`. |

> **`--json` is mandatory** on `sessions`, `leases`, `topology` and
> `observations`. Without it you fall through to the usage text and a zero exit
> — which is easy to mistake for "there is nothing to report". These four have
> no text renderer; the JSON *is* the answer.

## `runquota config`

Reads and changes the host budget file, `runquotad.toml`, and asks the running
daemon to reload it. `KEY` is `machine.memory_bytes` (the value may carry a
unit: `96GiB`, `512MiB`, `64GB`), `machine.cpu_milli` or `pools.NAME`.

| Command | What it does | Exit |
|---|---|---|
| `config path` | Prints the file's path. | 0 |
| `config show` | The file's keys, the built-in default for each unset one on this host, and the budget the running daemon enforces, where it came from and which keys its flags pin. | 0; 1 if the file does not parse |
| `config set KEY VALUE` | Checks the edit with the daemon's reader, writes the file atomically, reloads the daemon. | 0; 1 if refused or the reload failed |
| `config unset KEY` | The same, removing the key. | as `set` |
| `config reload` | Asks the daemon to re-read its file. | 0; 1 if the file does not parse |

With no daemon answering, `set` and `unset` still write the file and say the
next daemon to start will read it. Unrecognised arguments exit **2**. See
[Running the daemon](/usage_guide/daemon#reloading-under-a-running-daemon) for
what a reload does to leases.

## `runquota stats-table [KEY]`

Reads the [published aggregate table](/getting_started/concepts#published-aggregate-table)
straight out of shared memory — no round trip, no syscall. It always reports
the table's own state first:

```text
published stats table: /run/runquota/stats-table slots=256 hits=12 misses=3 retries=0 torn=0
```

or `published stats table: not attached (socket fallback)`. With a `KEY`, one
of four answers:

```text
<key>: <bytes> bytes over <n> samples (<knowledge>)
<key>: not resident (ask over the socket)
<key>: torn under a concurrent publisher (ask over the socket)
<key>: no table attached (ask over the socket)
```

The last three are not failures. The table is a cache; every one of them means
"the socket knows, this page does not".

## `runquota acquire`

Take a lease, optionally run a command under it, and release it.

```sh
runquota acquire --cpu 4000 --mem 2gib -- cargo build --release
```

| Flag | Default | Notes |
|---|---|---|
| `--cpu N` | `1000` | Milli-CPU. |
| `--mem BYTES` | 128 MiB | Accepts `gib`/`mib`/`kib` (1024-based) and `gb`/`mb`/`kb` (1000-based), case-insensitive; a bare number is bytes. |
| `--label TEXT` | `debug` | Shows up in `runquota leases`. |
| `--machine ID` | `local` | Which configured machine to draw from. |
| `--stats-key KEY` | none | Keys the [estimate](/getting_started/concepts#estimate) lookup and the recorded row. |
| `--benchmark` | off | Marks the lease as a benchmark and waits for a grant rather than giving up if queued. |
| `-- COMMAND [ARG...]` | none | Everything after `--` is the command. |

**Exit codes.** With a command, you get the child's exit code, or `128 +
signal` if it was killed — `acquire` is transparent, so it can sit inside an
existing pipeline without changing its meaning. Without a command it takes the
lease, prints `lease <id> granted` / `lease <id> released`, and returns 0. A
bad flag returns **2**.

**With no daemon, it still runs your command.** No lease, no recording, no
estimate — see [standalone mode](/getting_started/concepts#standalone-mode).
Set `RUNQUOTA_REPORT_STANDALONE` to any non-empty value to have that printed to
stderr, and `RUNQUOTA_REPORT_ESTIMATE_SOURCE` to see which of the three
estimate paths answered.
