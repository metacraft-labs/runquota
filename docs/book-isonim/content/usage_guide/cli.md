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
  runquota jobserver [--width N|MIN:PREF] [--mem SIZE] [--stats-key KEY] [--verbose] -- COMMAND [ARG...]
  runquota acquire --cpu MILLI --mem SIZE [--label TEXT] [--machine ID] [--stats-key KEY] [--benchmark] [-- COMMAND [ARG...]]
```

There is no `--help`. Any invocation the CLI does not recognise prints this
usage and exits **0** — so if you get the usage back, look at what you typed.
`--version` is accepted only as the sole argument.

The `stats` verbs have a page of their own:
[Reading the history](/usage_guide/stats).

## Inspecting the daemon

| Command | What it tells you |
|---|---|
| `runquota status [--json]` | Live counters: sessions, leases, `supervisor_lost_leases`, finished and granted totals, the memory-pressure reading, the starvation bound, and one row per [session group](/getting_started/concepts#session-group) with its counters (below). `--json` also carries the capacity figures (below). Both end with what is enforced below admission on this host ([below](#priority-below-admission)). |
| `runquota sessions --json` | The registered sessions. |
| `runquota leases --json` | Every lease the daemon is tracking. |
| `runquota topology --json` | The configured machines and CPU share groups — the budget, as the daemon sees it. |
| `runquota observations --json` | The recording subsystem: whether capture is on, which store is open, and every counter about what has been accepted, refused, queued or dropped. |
| `runquota explain SESSION_ID` | The leases belonging to one session. |
| `runquota pressure [--group G] [--json]` | [Build-wait pressure](#build-wait-pressure) per host, session group and open session. |
| `runquota pressure report [--class CLASS]` | A pool's reporting session: reads `class-queue <started-unix-millis> <length-millis>` lines on stdin and reports each as a wait of the class's queue (see [Build-wait pressure](#build-wait-pressure)). |
| `runquota profile [--project P] [--json]` | [Resource profiles](#resource-profiles-and-sizing) per project, entry point and host profile. |
| `runquota sizing --project P --cpus N[,N...] [--json]` | How much memory N dedicated CPUs need for a project: its recorded runs [replayed](#resource-profiles-and-sizing) at N CPUs. |
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

### Capacity figures

`status --json` also carries `capacity`: the figures
`runquotad --metrics-textfile` exports for Prometheus (see
[the daemon](/usage_guide/daemon#exporting-capacity-figures-for-prometheus)),
in the daemon's own integer units, whether or not a file is written. Unlike
`session_groups`, a group stays here after its last session closes, until it
has been idle for an hour.

| Field | Meaning |
|---|---|
| `cpu_budget_milli` | The host's CPU budget. |
| `host`, `groups[]` | The figures below for the whole host, and for each session group (with `owner_uid` and `name`). |
| `cpu_granted_milli`, `memory_reserved_bytes` | What granted leases hold now. |
| `pending_requests`, `oldest_pending_wait_millis` | Requests waiting, and the longest wait so far. |
| `cpu_used_micros` | CPU (user + system) finished leases' launchers reported; finishes without totals add nothing. |
| `finished_with_totals`, `finished_without_totals` | Finished leases, by whether they reported totals. |
| `grants`, `wait_millis` | Leases granted, and the time they had spent queued. |
| `cpu_busy_pct`, `cpu_foreign_pct`, `ambient_reading_unix_millis` | (`host` only) The ambient sampler's latest reading, or `null` while it has none. |
| `textfile` | `null` without `--metrics-textfile`; otherwise its `path`, `interval_millis`, `writes`, `failures` and `last_error` (`null` after a successful write). |

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
| `--cpu MILLI` | `1000` | Milli-CPU: `1000` is one logical CPU, so `--cpu 2` reserves 0.002 of a CPU, not two. |
| `--mem SIZE` | 128 MiB | Accepts `gib`/`mib`/`kib` (1024-based) and `gb`/`mb`/`kb` (1000-based), case-insensitive; a bare number is bytes. |
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
| `--width N` / `--width MIN:PREF` | `1:` host CPUs, at most 8 | `N` alone is a fixed width. With a range, the daemon grants the widest width in `MIN..PREF` that is free, at least `MIN`, and the command waits while not even `MIN` is free. Against a daemon too old to grant ranges, `run` asks for `PREF` slots and, if refused, retries at half, down to `MIN`. `MIN:` keeps the default `PREF`, `:PREF` keeps `MIN` at 1. A fixed width the budget cannot grant fails with exit 1 and the command does not run. |
| `--stats-key KEY` | `run/<program>@<project>` | Keys the recorded row and the [estimate](/getting_started/concepts#estimate) lookup. The default is the program's base name plus the name of the nearest enclosing git checkout of the working directory (or of the directory itself). |
| `--adapter NAME` | detected | `nim`, `go`, `nextest`, `nix`, `pnpm`, `yarn`, `playwright`, `npm`; `none` leaves the command line alone and only holds the lease; `list` prints the table and exits. |
| `--verbose`, `-v` | off | Print the chosen width, what the adapter did and the final command line to stderr. |
| `--cap` | off | Hold the command's whole process tree to the granted width. **Linux:** a cgroup of its own whose `cpu.max` is the grant, when [placement](#priority-below-admission) is on. **Windows:** a Job Object whose CPU-rate control is capped at the granted width, so however many threads or processes the command spawns it cannot use more CPU than the lease bought. Where neither can be done (macOS, Linux with placement off or unavailable, or inside another lease's tree) the command still runs, uncapped, and `run` says `--cap not enforced: <why>` on stderr. |
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
**2** for bad arguments; **1** when the daemon refused or lost
the lease so the command never ran; **127** when the command could not be
started. The lease is released when the command ends, whatever its status.

**With no daemon, it still runs your command**, unchanged and unbounded, as
`acquire` does.

The command's standard streams are the terminal's: its output is not captured
and replayed, unlike `acquire`.

## Priority below admission

Admission decides how much CPU a command is granted; it cannot stop a tool
that ignores its grant and starts a process per core. On Linux, RunQuota's
launchers (`run`, `acquire -- CMD`, `jobserver`) therefore start each command's
process tree inside a cgroup v2 directory of its
[session group](/getting_started/concepts#session-group), so such a tool
competes for CPU at its group's priority:

| Directory (below the root) | `cpu.weight` | What runs there |
|---|---|---|
| `group-<name>/shared` | low 25, normal 100, high 400, urgent 1600 | every tree of the group |
| `group-<name>/cap-<pid>-<n>` | the group's | one `run --cap` tree, with `cpu.max` at its grant |
| `reclaimed/shared` | 1 | trees of a reclaimed grant (also at nice +10) |

**Placement is off by default.** A host turns it on in its host file, which
every user's `runquota` reads at each launch:

```toml
[enforcement]
cgroups = "on"
```

(`runquota config set enforcement.cgroups on`). `RUNQUOTA_CGROUP_ROOT=off`
turns it off for one user or shell, and `RUNQUOTA_CGROUP_ROOT=<path>` turns
it on under another root ([environment variables](/reference/environment_variables)).
The default root is `runquota.slice` below your own `user@<uid>.service`
cgroup, the subtree systemd delegates to you with the `cpu` controller.
`<name>` is the group name with every byte outside `[A-Za-z0-9_:@-]` written
as `%XX`. The command is forked as usual and writes itself into its
directory before it runs, so nothing it starts escapes; the last tree out of
a directory removes it.
`runquota session set --priority` also changes the weight of the group's
directory when it exists. A launcher that itself runs inside a leased tree
leaves its command where the outer launcher put it.

With placement off, nothing below admission changes except that a
reclaimed tree runs at nice +10, and `--cap` runs uncapped with a note on
stderr. Where placement is on but unavailable (another OS, no delegated
`cpu` controller, a process outside its user manager), nothing fails either:
a reclaimed tree runs at nice +10, a `low` group's tree at nice +5, others
unchanged. `runquota status` says which, one
line per mechanism, and `status --json` carries the same as `enforcement`:

```text
enforcement_os: linux placement=on cgroup_root=/sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/runquota.slice
enforcement: priority enforced (cgroup v2 cpu.weight of .../group-<group> ...)
enforcement: reclaimed enforced (cgroup v2 cpu.weight 1 of .../reclaimed, and nice +10)
enforcement: width-cap enforced (cgroup v2 cpu.max of the tree's own leaf (runquota run --cap))
enforcement: memory-cap admission-only (admission (memory reservation)) gap: ...
```

The record is the client's: it describes the host and user of the `runquota`
process that prints it, because the cgroups are the launcher's, not the
daemon's.

**On Windows** there are no cgroups; the equivalent is a process priority
class, forced on a whole tree by a Job Object limit. A reclaimed grant's tree
always runs at `BELOW_NORMAL_PRIORITY_CLASS` (the base, like nice +10). The
switchable layer holds each tree to the class of its group's priority — idle
for reclaimed, below-normal/normal/above-normal/high for
low/normal/high/urgent — when the host turns it on:

```toml
[enforcement]
job-priority = "on"
```

(`runquota config set enforcement.job-priority on`). `RUNQUOTA_JOB_PRIORITY=off`
turns it off for one user or shell and `=on` turns it on. Off by default, like
cgroup placement, until an overhead gate passes it. The idle, below-normal,
normal and above-normal classes (reclaimed, low, normal, high) all take with no
privilege; only the urgent tier's `HIGH_PRIORITY_CLASS` needs
`SeIncreaseBasePriorityPrivilege` enabled, which the Job Object path requires
and an ordinary launcher does not hold, so an urgent group's tree is held at
normal. Because of that `runquota status` reports priority as `degraded` on
Windows with the switch on, naming the urgent-tier gap, with
`enforcement_os: windows`.

**On macOS** there are no cgroups and no CPU cap. A launcher that keeps
`fork` and `execve` (so that preload libraries' fork handlers still run) can
put a tree under the *background policy* (`setpriority(PRIO_DARWIN_BG)`, what
`taskpolicy -b` does), which the scheduler honours and every process of the
tree inherits. Nothing between the default and background can be set that way,
and a plain `nice` did not change the CPU share of an exec'd tree in
measurement, so macOS has two levels: a reclaimed grant's tree and a `low`
group's tree run in the background, everything else is unchanged (`high` and
`urgent` do not rise above `normal`). The switch is off by default:

```toml
[enforcement]
qos = "on"
```

(`runquota config set enforcement.qos on`). `RUNQUOTA_QOS=off` turns it off for
one user or shell and `=on` turns it on. `runquota status` reports `priority`
as `degraded` and `reclaimed` as `enforced` with the switch on, and says what
is missing; with it off `priority` is `admission-only` and `reclaimed` is
`degraded` (its nice +10, which does not schedule an exec'd tree on macOS).

## `runquota jobserver`

Run a command that speaks the GNU make jobserver protocol under one lease, and
serve it a jobserver whose tokens are the lease's slots. GNU make 4.4, cargo
and rustc, ninja 1.13 and GCC's `-flto=jobserver` ask the jobserver before
each job beyond their first, so their parallelism follows the lease without
any flag being rewritten.

```sh
runquota jobserver --width 4 -- cargo build --release   # at most 4 rustc at once
runquota jobserver -- make                               # make with no -j follows the jobserver
runquota jobserver --width 2:8 --mem 6GiB -- ninja -C build
```

**N slots serve N − 1 tokens.** A jobserver client holds one implicit token
for itself and takes a token only for each further job, so a 4-slot lease
puts 3 tokens in the jobserver and the command runs at most 4 jobs. The
jobserver is a named FIFO (`--jobserver-auth=fifo:PATH`, the GNU make 4.4
form) in a fresh private directory, removed when the command ends.

| Flag | Default | Notes |
|---|---|---|
| `--width N` / `--width MIN:PREF` | `1:` host CPUs, at most 8 | As for `run`. |
| `--mem SIZE` | 512 MiB per slot; inside a parent, the parent's reservation | The memory reserved on the lease (bytes, or with `KiB`, `MiB`, `GiB`). Tokens carry only CPU, so memory is reserved here. A learned estimate under the stats key raises the default. |
| `--stats-key KEY` | `run/<program>@<project>` | As for `run`. |
| `--verbose`, `-v` | off | Print the lease, the tokens served and returned, and any width flag removed. |

The command gets `MAKEFLAGS` and `CARGO_MAKEFLAGS` (the inherited `MAKEFLAGS`
words, minus any job count or jobserver, followed by
` -jN --jobserver-auth=fifo:PATH`), `RUNQUOTA_JOBSERVER_FIFO`,
`RUNQUOTA_RUN_WIDTH` and `RUNQUOTA_RUN_STATS_KEY`.

**An explicit width overrides a jobserver** in make and ninja: `make -j8` or
`ninja -j8` would run 8 jobs whatever the jobserver holds. For a command whose
program is `make`, `gmake` or `ninja`, `jobserver` removes `-j`, `-jN`,
`-j N`, `--jobs` and `--jobs=N` from the command line.

**Nesting.** `runquota acquire` and `runquota run` give the command they start
`RUNQUOTA_PARENT_LEASE`, naming their lease. A `runquota jobserver` started
with it takes a *sub-lease* of that parent: its slots come out of the
parent's grant and never from the host's budget, so a nested build cannot
wait on the host behind its own parent. The daemon fits the sub-lease's width
to what the parent's other sub-leases leave and queues it while not even the
minimum fits. A parent that is unknown or has ended makes `jobserver` fall back
to an ordinary lease (and say so); a width larger than the parent's is
refused. Inside a bridge, the jobserver is the nesting mechanism: the command
does not get `RUNQUOTA_PARENT_LEASE`, and a `runquota jobserver` started
inside it joins the existing jobserver and takes no lease of its own, as a
recursive make does. A sub-lease keeps its granted width for the command's
lifetime.

**The width moves while the command runs.** An ordinary (not nested) lease is
asked for as a range and declared resizable. When slots are free and nothing
waits for them, the daemon widens it, up to `PREF`, and `jobserver` puts the
extra tokens into the FIFO at once. When other work waits, the daemon narrows
it back towards the width it was first granted: `jobserver` keeps the tokens
the command hands back until it is down to the new width. No token is taken
from a running job and no process is signalled, so a narrowing completes only
as jobs finish; slots return to the host as each token comes back. A tool that
picks a returned token up again straight away competes with `jobserver` for
it, so narrowing a build that keeps every token busy can take longer than one
job. `jobserver` reports the width it holds to the daemon every 100 ms and
follows the answer. `MAKEFLAGS`' `-jN` and `RUNQUOTA_RUN_WIDTH` give the width
at start.

**The command runs in its own process group**, and gets the terminal when
`jobserver` has it. SIGINT, SIGTERM and SIGHUP are forwarded to the group. When
the command exits, anything left in its group is ended (SIGTERM, then SIGKILL
after two seconds), since it would otherwise keep running after the lease is
released. A process meant to outlive the build leaves the group, as daemons
do. Then the lease is finished, with the command's CPU totals, and released,
which returns every slot to the host (or to the parent) whatever the tokens'
fate.

**Exit codes and the no-daemon case** are as for `run`. Linux and macOS only
for now.

### Build-wait pressure

`runquota pressure` prints, for the host, every session group that has
reported and every open session that has (with `--group G`, only the groups
named `G` and their sessions), the *some* and *full* averages over 10, 60 and 300 seconds and their
totals, the wall time the reports covered, and the waits of a second or more
by kind with how many were long. `--json` prints the daemon's answer as it
sent it; `runquota status --json` carries the same as `pressure`. An average
is held-up time per second of wall time, summed over the invocations of a
group or the host: 1.0 is one invocation held up all the time, or two held
up half of it. It exits 0 when the daemon answered, 1 when no daemon could be
reached or it predates pressure reports, 2 on bad arguments. See
[the daemon](/usage_guide/daemon#build-wait-pressure) for what is reported
and how it is clamped.

It also prints each **class**: the pressure its sessions reported and its
lease queue time as the daemon measured it. A pool that runs jobs in a
class (a CI runner pool, a VM pool) reports how long each job waited for a
slot through `runquota pressure report --class CLASS`, which it starts once
and keeps: it prints `ready <session>`, then reads one line per finished
wait, `class-queue <started-unix-millis> <length-millis>`, and answers
`reported <length>`, `skipped` (under a second) or `refused` (a line it
cannot read). The daemon trusts no wait longer than the reporting session
has existed, which is why it is one long-lived session and not one per job.

## `runquota vm hold`

```text
runquota vm hold --name NAME --cpu-milli N --memory-bytes N [--machine ID]
                 (--pid PID [--vsock-cid CID] | --started-from-stdin)
                 [--restart-grace SECONDS -- PROBE [ARGS...]]
```

Holds a virtual machine's shape on the host daemon for as long as the VM
runs (Linux). A VM provider runs it *before* starting the VM: it registers
the VM (CPU = its vCPUs, memory = its RAM) in the session group
`RUNQUOTA_SESSION` names, waits like any lease until the host grants it, and
prints `granted <lease-id>`. The provider starts the VM and writes one line,
`<pid> [<vsock-cid>]` -- the VM's host process and the CID its guest daemon
will link from -- and the command prints `started`, detaches its standard
streams, waits for that process to exit (a pidfd: nothing polls), releases
the registration and exits 0. `--pid` gives the same on the command line for
a VM that already runs. Exit 1 when no daemon answers or it refuses, 2 on bad
arguments.

While the VM is registered the host holds its whole memory, and counts its
vCPUs at their full count until a RunQuota daemon in the guest links to the
host daemon over vsock (`runquotad --link-host` in the guest,
`--vm-link-vsock-port` on the host); then at what the guest's own leases
hold, so host builds use the vCPUs an idle VM leaves free and the guest gets
them back as soon as it takes a lease. Nothing is revoked: a running host
lease keeps its grant, and the host admits less until it ends.
`runquota status` prints a `virtual_machine` line per VM, with its charge and
`link=linked` or `link=unlinked`; an unlinked VM carries a `capability=` gap.

A VM restarted in place runs on in a new process (an Incus VM does on a
guest reboot). With `--restart-grace SECONDS -- PROBE...`, when the watched
process exits the command runs the provider's `PROBE` (every 500 ms, each
run bounded to 10 s) for up to `SECONDS`: on exit 0 the probe prints
`<pid> [<vsock-cid>]` while the VM runs, `0` while it exists but does not
run, and nothing once it no longer exists. A new process is reported to the
daemon, which watches it from then on, and the registration is kept; nothing
printed, or the grace running out, releases it. A probe that fails is asked
again within the grace.

A SIGTERM or SIGINT ends the command *without* releasing: the daemon then
keeps the reservation exactly as long as the VM process lives, because that
process is the lease's watched child. Neither RunQuota nor this command ever
stops the VM.

## Resource profiles and sizing

These read the observation store, so they answer only on a host whose daemon
captures (`runquotad --measurement capture=on`); otherwise they say
`capture-off` and exit 4. Exit codes are those of `runquota stats`: 0 an
answer, 3 no run of the project in scope, 4 no instrument, 2 bad arguments.
Rows are your own unless you pass `--all-users`, and they come from this
host's current hardware profile unless you pass `--host-profile all`.

A session says which project it works for and through which entry point
(`build`, `test`, a CI job name) from `RUNQUOTA_PROJECT` and
`RUNQUOTA_ENTRY_POINT`, or from `--project` and `--entry-point` on
`runquota run`, `runquota acquire` and `runquota jobserver`. With
`RUNQUOTA_MEASUREMENT=sizing-data=on` the launching client also sends the
tree's memory over time (so a job's peak is the sum of its processes, not
its largest one), the bytes it read and wrote, and, for a build engine that
knows its graph, which earlier jobs each one waited for. That measurement is
off by default. On Linux the bytes include the descendants the root
waited for; on macOS they are the root process's own, because the kernel
keeps no reaped-children share for storage IO, so a tree whose root only
forks reads low there, and memory is resident size, which leaves out
pages the compressor holds (a floor under pressure). `runquota profile`,
`sizing` and `status`, in text and in `--json` (a `measurement` object, with
the same keys on every OS), and the header of the sizing export say which
applies: a `measurement:` line per quantity with its coverage (`full`,
`partial` or `none`) and its gap. The record describes the host the daemon
runs on, not the host that recorded stored rows.

```sh
runquota profile --project myproject
runquota sizing --project myproject --cpus 4,8,16 --quantile 0.99
runquota observations export --format sizing --project myproject > sizing.ndjson
node scripts/sizing-replay.mjs --cpus 4,8,16 sizing.ndjson
```

`profile` prints, per entry point, the quantile and maximum of each job's
peak memory, duration, mean CPU, granted width and write rate. `sizing`
replays every complete run of the project with N CPU tokens: a job becomes
ready when the jobs it declared it waited for have finished (or at its
recorded offset, shifted by how late the jobs that finished before it now
finish), starts when its width fits, runs longer when it ran wider than N
allows, and holds its recorded memory over time (or its peak throughout,
which overestimates and is said). For each N it prints the quantile over
runs of the peak concurrent memory, the maximum and the makespan, plus the
baseline: other processes' memory (foreign RSS) sampled while the runs ran.
Runs still open or with incomplete capture are left out and counted, and
every gap in the data (no memory profile, no recorded width or request time)
is named in a note. The host's `[machine] write_bytes_per_sec`, when the host
file sets it, is shown beside the replayed write rate; it is not enforced.

`observations export --format sizing` writes the records the replay reads as
NDJSON (redacted by `--redact default|strict|none`, default `default`, which
replaces command shapes, paths, and project and entry point names with
tokens; ids, times and figures are never redacted), and
`scripts/sizing-replay.mjs` replays them offline to the same figures.

Each answer is bounded, because the daemon computes it while it is also
admitting work: it reads at most the newest 1000 runs and 50,000 executions
in scope (and says `read_truncated` when there were more), takes at most 16
values of `--cpus`, and replays runs newest first within a fixed work budget
(roughly the executions of a run squared, per N); runs the budget does not
reach are counted under `over_budget` and named in a note. The offline
script has no budget, so replaying an export gives the figures of every run
it carries.

