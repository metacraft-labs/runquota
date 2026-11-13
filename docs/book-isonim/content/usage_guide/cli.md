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
  runquota session set GROUP [--priority LEVEL] [--cache-deadline TIME|none | --cache-ttl SECONDS]
  runquota config path
  runquota config show [--file PATH]
  runquota config set KEY VALUE [--file PATH] [--no-reload]
  runquota config unset KEY [--file PATH] [--no-reload]
  runquota config reload
  runquota stats-table [KEY]
  runquota stats capture [--json]
  runquota stats top [KEY] [--limit N] [--all-users] [--all-profiles] [--json]
  runquota stats export [KEY] [--limit N] [--all-users] [--all-profiles] [--json]
  runquota run [--width N|MIN:PREF] [--stats-key KEY] [--adapter NAME|none|list] [--verbose] -- COMMAND [ARG...]
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
| `runquota status [--json]` | Live counters: sessions, leases, `supervisor_lost_leases`, finished and granted totals, the memory-pressure reading, the starvation bound, and one row per [session group](/getting_started/concepts#session-group) with its counters (below). |
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

### Session group counters

`runquota status` prints one `session_group:` line per open group, and
`status --json` carries the same as `session_groups`. These are inspection
output: read them, do not parse them into anything that persists.

| Field | Meaning |
|---|---|
| `name`, `owner_uid` | The group, and the user it belongs to. |
| `priority`, `cache_deadline_unix_millis` | Its attributes now (`null`: no deadline). |
| `sessions` | Open sessions in it. |
| `queued_leases`, `active_leases` | Its requests waiting, and its leases holding capacity. |
| `held_cpu_milli`, `held_memory_bytes` | What its granted leases reserve now. |
| `grants_total` | Leases granted to it since it was created. |
| `granted_cpu_milli_seconds` | The CPU its released leases reserved, times how long they held it. |
| `wait_total_millis`, `wait_max_millis` | How long its granted requests had waited: in total, and the longest. |
| `oldest_queued_wait_millis` | How long its oldest waiting request has waited so far. |

The figures are reservations, not measurements: the daemon does not watch
process trees.

## `runquota session set`

Changes a session group's attributes while it runs — how a launcher keeps
them current.

```sh
runquota session set myhost:3 --priority urgent --cache-ttl 240
runquota session set myhost:3 --cache-deadline none
```

| Flag | Meaning |
|---|---|
| `--priority LEVEL` | `urgent`, `high`, `normal` or `low`. |
| `--cache-deadline TIME` | A UTC time, `YYYY-MM-DDTHH:MM:SSZ`; `none` clears the deadline. |
| `--cache-ttl SECONDS` | The deadline as seconds from now. Give this or `--cache-deadline`, not both. |

Only the group's owner may change it, and only while one of its sessions is
open. Exit **0** when changed (it prints the attributes now in force), **1**
when the daemon refuses — another user's group, or no open session names it —
or cannot be reached, **2** on bad arguments.

## `runquota config`

Reads and changes the host budget file, `runquotad.toml`, and asks the running
daemon to reload it. `KEY` is `machine.memory_bytes` (the value may carry a
unit: `96GiB`, `512MiB`, `64GB`), `machine.cpu_milli` or `pools.NAME`.

| Command | What it does | Exit |
|---|---|---|
| `config path` | Prints the file's path. | 0 |
| `config show` | The file's keys, the built-in default for each unset one on this host, and the budget the running daemon enforces, where it came from, which keys its flags pin, and for each pool whether a flag, the file or the open sessions' declarations size it. | 0; 1 if the file does not parse |
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

## `runquota run`

Run a command under a CPU lease, and tell the command how wide it may be.
Build and test tools that have no RunQuota client of their own (`nim`, `go`,
`cargo nextest`, `nix`, Playwright, the JavaScript package managers) keep doing
their own parallelism; `run` takes a lease of N slots and passes N to the tool
in the form it understands, so the tool's fan-out stays inside what the host
granted.

```sh
runquota run --width 3 -- nim c --parallelBuild:8 app.nim   # runs with --parallelBuild:3
runquota run --width 2:8 -- go test ./...                   # go test -p N, N from 2 to 8
runquota run -- nix build .#package                         # --max-jobs 1 --cores N
runquota run --adapter list
```

| Flag | Default | Notes |
|---|---|---|
| `--width N` / `--width MIN:PREF` | `1:` host CPUs, at most 8 | `N` alone is a fixed width. With a range, `run` asks for `PREF` slots and, if the daemon refuses that many, retries at half, down to `MIN`; the grant is whole or not at all. `MIN:` keeps the default `PREF`, `:PREF` keeps `MIN` at 1. A fixed width the budget cannot grant fails with exit 1 and the command does not run. |
| `--stats-key KEY` | `run/<program>@<project>` | Keys the recorded row and the [estimate](/getting_started/concepts#estimate) lookup. The default is the program's base name plus the name of the nearest enclosing git checkout of the working directory (or of the directory itself). |
| `--adapter NAME` | detected | `nim`, `go`, `nextest`, `nix`, `pnpm`, `yarn`, `playwright`, `npm`; `none` leaves the command line alone and only holds the lease; `list` prints the table and exits. |
| `--verbose`, `-v` | off | Print the chosen width, what the adapter did and the final command line to stderr. |
| `--cap` | | Not available yet: exits 2 without running the command. |
| `-- COMMAND [ARG...]` | required | Everything after `--` is the command. Its own flags are never read by `run`. |

The command also gets two environment variables whatever the adapter:
`RUNQUOTA_RUN_WIDTH` (the grant in slots, for scripts and tools no adapter
covers) and `RUNQUOTA_RUN_STATS_KEY`. A `RUNQUOTA_SESSION` group exported by a
launcher is joined, as for every other client.

### Adapters

Each adapter recognises a command from the program's base name and its first
positional word, and inserts its flag right after that word, so the flag lands
before any `--` that passes the rest of the line on.

| Adapter | Recognises | Passes the grant as |
|---|---|---|
| `nim` | `nim c`, `cc`, `cpp`, `objc`, `js`, `r`, `compile*` | `--parallelBuild:N` |
| `go` | `go build`, `install`, `test`, `vet` | `-p N` |
| `nextest` | `cargo [+toolchain] nextest run` | `-j N` |
| `playwright` | `playwright test`, also behind `npx`, `pnpm`, `yarn`, `npm`, `bunx`, `bun` | `--workers=N` |
| `nix` | `nix [flags] build`, `nix-build` | `--max-jobs 1 --cores N` |
| `pnpm` | `pnpm` with `-r`, `--recursive`, `--filter`, or a script-running or install command | `--workspace-concurrency=N` |
| `yarn` | `yarn workspaces foreach` (Yarn 2 and later) | `--jobs N` |
| `npm` | any `npm` command | nothing: npm has no workspace concurrency setting, so the command is passed through |

**A width flag you already wrote is kept, and capped.** A value from 1 up to the
grant stays exactly as written. A larger value, `0`, a negative number, or
anything that is not a plain integer (`50%`, `auto`, `num-cpus`) becomes the
grant, because none of those can be shown to fit. For `nix`, `--max-jobs` and
`--cores` share the grant so that jobs times cores never exceeds it: with
`--max-jobs M` the cores per build are the grant divided by M. A command that
no adapter recognises is run unchanged; the lease is still held for its
duration.

**Exit codes.** The command's exit code, or `128 + signal` if it was killed.
**2** for bad arguments and for `--cap`; **1** when the daemon refused or lost
the lease so the command never ran; **127** when the command could not be
started. The lease is released when the command ends, whatever its status.

**With no daemon, it still runs your command**, unchanged and unbounded, as
`acquire` does.

The command's standard streams are the terminal's: its output is not captured
and replayed, unlike `acquire`.
