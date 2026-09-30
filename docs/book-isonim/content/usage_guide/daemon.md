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

`runquota daemon start [RUNQUOTAD_ARG...]` is the convenience path: it checks
whether a daemon is already answering, and only if not spawns a detached
`runquotad` with the flags you give it, then polls for readiness. Idempotent; the
budget it gets is the host file's (below) unless a flag overrides it, or the
defaults when there is none.

The daemon it starts **does not keep the caller's terminal or pipes**. Its
output goes to `--log-file`, by default the per-user
`%LOCALAPPDATA%\runquota\runquotad.log` on Windows and
`$XDG_STATE_HOME/runquota/runquotad.log` (else `~/.local/state/...`)
elsewhere, and the verb prints that path. So `runquota daemon start | tail`, a
`$(...)` or a CI step returns as soon as the daemon answers, instead of waiting
for it to exit. `runquotad --log-file PATH` does the same for a daemon you
start yourself.

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

Every key is optional; an absent one keeps the built-in default: **75% of
physical memory** and one core (`1000` milli-CPU) per logical processor. A
flag given on the command line overrides the file for that launch.

The reader accepts exactly this shape: a `schema` string, positive integers in
`[machine]` and `[pools]`, `_` between digits, and `#` comments. Anything else
is refused with the file and line, and the daemon exits **2** without starting,
because a budget file that was half-read would look configured when it is not.
A missing file is not an error, and the daemon never creates the file or its
directory. The installers create the directory and seed a file whose keys are
all commented out (see [provisioning](/getting_started/provisioning)).

A daemon that reprobuild starts for you reads the same file. Reprobuild passes
no memory flag unless `REPROBUILD_RUNQUOTA_MEMORY_BYTES` is set, and passes
CPU and pool flags only for the keys the file leaves unset.

### Changing it: `runquota config`

```sh
runquota config show                              # the file, the defaults, and what the daemon enforces
runquota config set machine.memory_bytes 96GiB    # also 512MiB, 64GB, or a byte count
runquota config set machine.cpu_milli 16000
runquota config set pools.compile 8
runquota config unset pools.compile               # back to the default
runquota config reload                            # after editing the file by hand
runquota config path
```

`set` and `unset` check the edited file with the daemon's own reader before
writing anything, write it atomically (beside it, then renamed over it), keep
every comment and every other line, and then ask the running daemon to
**reload** it. They need the rights the install step gave the directory: an
elevated prompt on Windows, root elsewhere. They never create the directory;
on an unprovisioned host they say so and write nothing. `--file PATH` edits
another file, and `--no-reload` skips the reload.

### Reloading under a running daemon

One daemon serves every workspace on the host, so restarting it to change a
budget would drop every build's session at once. Instead the daemon re-reads
its file when a client sends it `ReloadHostConfig` — which `runquota config
reload` does, and `set`/`unset` do after writing. It is a message over the
daemon's own endpoint, not a signal, so it works the same on Windows. The
request carries no values: the daemon reads the file it was started with,
which only administrators can write, so any client that may connect may ask.

What a new budget does to leases already in flight:

| Change | Granted leases | Queued leases |
|---|---|---|
| Grow | untouched | promoted now, if they fit; clients see the grant on their next poll |
| Shrink | **never revoked** — they keep running, and the granted total may exceed the new budget | admitted against the new budget, so nothing new starts until the total falls below it |
| Shrink below a queued lease's size | untouched | **denied** on its session's next poll, with the reason a fresh request of that size gets (`lease request exceeds machine memory budget: local`) — waiting could never end |
| A pool removed from the file | untouched | denied, as above |

A file that does not parse changes **nothing**: the reload is refused with the
file and line, the budget in force stays the last one that parsed, and
`runquota config reload` exits 1. A key a `runquotad` flag pinned for this
launch keeps the flag's value; the reload answer lists such keys, so an edit
that had no effect says so. `runquota topology --json` carries the budget in
force, the `pools`, and a `host_config` object naming the file it came from,
the number of reloads, and the keys the flags pin. The daemon logs one line
per reload (`runquotad: host configuration reloaded: ...`).

`runquotad --host-config PATH` names another file to read at start and on
every reload — for a test's private daemon, never for the host's.

### Flags

`runquotad --help` prints the full list. The ones that shape admission:

| Flag | Default | Meaning |
|---|---|---|
| `--cpu-milli N` | logical processors × 1000 | Host CPU budget; `1000` is one core. Pins the value against a reload. |
| `--memory-bytes N` | 75% of physical memory | Host memory budget. Pins the value against a reload. |
| `--io-slots N` | `1` | Concurrent heavy-I/O slots. |
| `--machine ID=CPU_MILLI,MEMORY_BYTES[,IO_SLOTS[,CPU_SHARE_GROUP]]` | one implicit machine, `local` | A named capacity. Omitted I/O slots inherit `--io-slots`; an omitted share group defaults to the machine's own id. |
| `--cpu-share-group ID=CPU_MILLI` | derived | A CPU cap shared across machines. |
| `--pool NAME=UNITS` | none | An arbitrary named counter. |
| `--socket PATH` | the rendezvous socket | Where to listen. A path you name here is created on demand; the host-wide one never is. |
| `--host-config PATH` | the host file above | The budget file read at start and on every reload. |

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
