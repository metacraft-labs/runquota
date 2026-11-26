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

The admission order has a table of its own (see
[Admission control](/getting_started/concepts#admission-control)):

```toml
[admission]
order               = ["starvation", "fair-share", "arrival"]   # default: starvation, priority, cache-deadline, arrival
max-wait            = "90s"    # also "1500ms", "2m"; "0s" turns the bound off; default "120s"
share-between-users = "drf"    # or "none"; default "drf"
```

`order` takes the keys `starvation`, `priority`, `cache-deadline`,
`fair-share` and `arrival`. A key outside them, a key listed twice and an
empty list are refused like any other malformed line. `--admission-max-wait-millis`
overrides `max-wait` for that launch.

Four more keys turn on and tune **predictive admission**:

```toml
[admission]
predictive    = "off"   # "on": admit into the predicted tails of running leases
horizon       = "10s"   # how far ahead that CPU must be predicted free
pressure-high = "10"    # CPU pressure (percent) above which it, and widening, stop
pressure-low  = "5"     # ... and below which they resume
```

With `predictive = "on"`, a queued request whose minimum width does not fit
the granted widths can still be granted, at its minimum, when the running
leases' learned CPU curves say that much CPU will be free for the whole
horizon: a test run that saturated the host for a minute and now runs on one
core is predicted at one core, not at its grant. Such a grant is marked
**reclaimed**. Only launchers that run a reclaimed tree at a lower
scheduling weight ask for one (`runquota acquire -- COMMAND` and `runquota
run`, which start it at nice +10), memory, I/O slots and pools must still fit
exactly, and the curves exist only where the daemon captures observations
(`--measurement capture=on`) and the launching clients record CPU profiles
(`RUNQUOTA_MEASUREMENT=profiles=on`); without a curve a lease is predicted at
its granted width, so admission is unchanged. Measured CPU pressure corrects
the prediction: on Linux the *some* `avg10` of `/proc/pressure/cpu` (another
file of that format with `--cpu-pressure-file PATH`). Above `pressure-high`
no reclaimed grant is made and no resizable lease is widened, until it falls
below `pressure-low`; when the signal cannot be read, nothing is reclaimed
and widening is unaffected. `runquota status --json` reports all of it under
`admission_prediction`, and `runquota leases --json` marks each reclaimed
lease. The thresholds are percentages from 0 to 100, and `pressure-low` may
not be above `pressure-high`.

A `runquotad` older than this table refuses a file that has it: it does not
start, and a reload is refused with the budget in force unchanged. Upgrade
the daemon before adding the table.

**Classes, reservations and the oversubscription target.** A launcher
puts its sessions in a *class* by exporting `RUNQUOTA_CLASS` (for example
`ci`), and the host file can reserve capacity for a class and let CPU
grants overlap the budget:

```toml
[admission]
oversubscription = "0.1"     # CPU grants may sum to the budget x 1.1; default "0"

[reservation.ci]
cpu-milli    = 8000          # reserved CPU; absent: none
memory-bytes = 34359738368   # reserved memory; absent: none
lend         = true          # idle reserved CPU may be lent (default true)
```

Work outside a class is never granted a class's reserved memory, and
reserved memory is never lent. A class's idle reserved CPU is lent to other
work when `lend = true`; as soon as the class asks, its idle reservation is
held for it, and every CPU a finishing lease frees, up to the reservation,
goes to the class first. Running leases are never revoked. Each admission
pass serves the requests that fit their class's reservation before the
admission order runs, so a class gets its reserved capacity whatever else is
queued; beyond its reservation a class borrows like any other work, only
from capacity no other class's reservation protects. Lent CPU comes back
only as the borrowers' leases finish, so a class that must have its cores
the moment it asks should set `lend = false`. The admission order's
starvation bound still holds for other work, over the capacity the
reservations leave it. The reservations
together must fit the budget itself (the target does not make room for
them): a file that breaks this does not start the daemon, and a reload of
it is refused. `oversubscription` is a fraction from `"0"` to `"1"`; memory
is never oversubscribed. `runquota status` shows each class's reservation,
what it holds and borrows, and what is held for it; `runquota pressure`
shows each class's queue time (see [Build-wait pressure](#build-wait-pressure)).

**Who may claim a class: its socket.** Every `[reservation.<class>]` table
gets its own daemon socket, `class-<class>.sock` beside the daemon's endpoint
(`/run/runquota/class-ci.sock` on a provisioned Linux host,
`/var/run/runquota/class-ci.sock` on macOS, the pipe
`\\.\pipe\runquota\class-ci` on Windows, and beside `--socket` or
`RUNQUOTA_SOCKET` when one is given). A client whose `RUNQUOTA_CLASS` names
the class connects there, and the operating system's access check on that
socket is what decides whether it may claim the class: `connect(2)` on a Unix
socket needs write permission on it. The table says who that is:

```toml
[reservation.ci]
cpu-milli    = 8000
socket-owner = "runquota"   # user name or decimal uid; default: the daemon's user
socket-group = "ci"         # group name or decimal gid; default: the daemon's primary group
socket-mode  = "0660"       # "0600" | "0660" | "0666"; default "0600"
```

- The default, `"0600"`, lets only the daemon's own account (and root) claim
  the class, so a host that declares a reservation and nothing else has
  capacity no other user can claim. `"0660"` lets the members of
  `socket-group` claim it, and `"0666"` every local user who can reach the
  rendezvous. No other mode is accepted: read and execute bits decide
  nothing for a socket.
- The socket is in the rendezvous directory, so a claimant must also be able
  to reach the daemon at all (on a provisioned Linux host, be in the
  `runquota` group). A class socket narrows who may claim; it never widens who
  reaches the daemon.
- The daemon's account must be able to apply what is declared: a daemon
  that is not root can give the socket only a group it is a member of, and
  cannot give it away to another owner. A start whose class socket cannot be
  created as declared fails (exit 2, naming the class, the socket and what is
  missing, for example that the daemon's account is not in group `ci`), and
  such a reload is refused with everything in force unchanged.
- The socket is created with exactly the declared owner, group and mode; it
  never appears at its path with a wider mode or another group, even for an
  instant.
- A table added on reload gets its socket, a table dropped loses it, and
  changed keys are applied to the existing socket. A connection accepted
  before the reload keeps its class: a reload revokes nothing.
- A class with no table has no socket and cannot be claimed. A table with
  only socket keys is a class with no reservation, claimable through its
  socket.
- On Windows the keys are `allowed-users` and `allowed-groups` (names or
  SIDs), the principals the class pipe's access list allows besides `SYSTEM`,
  Administrators and the daemon's account. A file read on Windows refuses the
  Linux and macOS keys and the reverse, naming the platform.
- `runquota config set reservation.ci.socket-group ci`,
  `reservation.ci.socket-mode 0660` and `reservation.ci.socket-owner runquota`
  write them (on Windows `reservation.ci.allowed-groups "CI Runners"`, with
  commas between several), and `unset` removes one. A mode outside the three,
  an unknown user or group, or the other platform's key is refused before
  anything is written.

On the class's socket a session gets the class whether or not it names it.
A session there that names *another* class is refused, and so is one that
would join an existing group of another class, or of no class. On the shared
socket a session that names a class is refused, with an error naming the
class's socket (or saying the host declares no such class), and so is one
that would join a group that has a class; everything else on the shared
socket is unchanged. The client never falls back from a class socket that
refuses it to the shared one: it stops with an error naming the socket and
the class, and a launcher (`runquota run`, `acquire`, `jobserver`) does not
run the command unleased instead. That holds for every way of failing to
reach the class -- an invalid class name, a socket nobody listens on, a
daemon that does not answer, and no daemon at all -- since the work asked for
a reservation. When the class's socket does not exist the
client asks the shared socket, and the daemon answers that the host declares
no such class: declare `[reservation.<class>]`, or unset `RUNQUOTA_CLASS`.
A daemon older than class sockets (protocol minor 12) keeps its earlier
behaviour, where any client may name any class. `runquota pressure report
--class C` reports into `C` from `C`'s socket. The per-user daemon (below)
gives every declared class a socket that only its user can reach and ignores
the socket keys: its directory is the user's alone.

The reader accepts exactly this shape: a `schema` string, positive integers in
`[machine]` and `[pools]`, `_` between digits, the `[admission]` keys above
(plain double-quoted strings without escapes, and `order` as a one-line
array of them), and `#` comments. Anything else
is refused with the file and line, and the daemon exits **2** without starting,
because a budget file that was half-read would look configured when it is not.
A missing file is not an error, and the daemon never creates the file or its
directory. The installers create the directory and seed a file whose keys are
all commented out (see [provisioning](/getting_started/provisioning)).

A daemon that reprobuild starts for you reads the same file and **behaves
exactly as the service would**: reprobuild passes it no CPU, memory or pool
flag, so nothing it starts is pinned, and `runquota config set` reaches it.
The one exception is `REPROBUILD_RUNQUOTA_MEMORY_BYTES`, an explicit
per-invocation override that reprobuild passes as `--memory-bytes` and warns
about every time: it pins the memory budget for that daemon's life. (Until
2026-10-01 reprobuild also passed `--cpu-milli` = its own build parallelism
× 1000 and `--pool` flags; see *Pools a build declares* below for where the
pools went.)

On Windows the daemon reprobuild starts binds the same host-wide pipe as the
service and outlives the build, so `runquota config reload` from any shell
reaches it. On an unprovisioned Linux or macOS host reprobuild starts a daemon
private to one build, on a socket of its own (exported to the build as
`RUNQUOTA_SOCKET`), and stops it when the build ends; a change to the file is
in force from the next build.

### Changing it: `runquota config`

```sh
runquota config show                              # the file, the defaults, and what the daemon enforces
runquota config set machine.memory_bytes 96GiB    # also 512MiB, 64GB, or a byte count
runquota config set machine.cpu_milli 16000
runquota config set pools.compile 8
runquota config set admission.order starvation,fair-share,arrival
runquota config set admission.max-wait 90s
runquota config set admission.share-between-users none
runquota config set admission.predictive on
runquota config set admission.oversubscription 0.1
runquota config set reservation.ci.cpu-milli 8000
runquota config set reservation.ci.memory-bytes 32GiB
runquota config set reservation.ci.lend false
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
| Shrink below a queued lease's size | untouched | **denied** on its session's next poll, with the reason a fresh request of that size gets (`lease request exceeds machine memory budget: local (requested 12 GiB, budget 8 GiB)`) — waiting could never end |
| A pool removed from the file | untouched | denied, as above |

A reload also puts the file's `[admission]` keys in force: the reload's own
admission pass already orders the queue by them, queued requests keep the time
they have waited, and nothing granted is revoked.

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

### Pools a build declares

A client can tell the daemon which named pools its work uses and the capacity
it expects each to have, on its own session (`DeclarePools`). Reprobuild does
this for every build: the convention `compile` / `fetch` pools and every
recipe `buildPool(name, capacity)`. That is how a daemon reprobuild did not
start — the installed service, or one another build left running — learns
those pools.

A declaration is the **lowest** layer of a pool's cap:

1. a `--pool NAME=UNITS` flag (pins it);
2. the host file's `[pools]` entry;
3. what the open sessions of **the same user** declared — the smallest
   capacity, when several of that user's sessions declare one pool.

A pool that only sessions declare belongs to the user who declared it. The
daemon reads the user from the connection's peer credentials (the uid on
Linux and macOS, the account SID on Windows), never from anything the client
sends. Two users whose builds both use a pool called `compile` or `serial` get
two pools: one user's `compile = 1` does not throttle the other's compiles,
and one user's declaration cannot shrink a pool in which another user's lease
is waiting. One user's sessions share a pool, so a recipe's `serial = 1`
still means "never two at once" for all of that user's work, including work
that reprobuild runs on separate sessions.

A pool that the host file or a flag sizes is a single pool for every user on
the host. Name a resource that really is host-wide, such as a GPU, in the
host file (`runquota config set pools.gpu 1`): what users declare for that
name is then ignored. If the entry is removed (`unset`), each user's
declaration applies again, separately.

So `runquota config set pools.compile 4` overrides what builds declare, and
`runquota config unset pools.compile` hands the pool back to them. A
declaration leaves with its session; a pool nobody declares and nothing else
sizes is gone, and a queued lease in it is denied as on a reload. `runquota
config show` and `runquota topology --json` name each pool's source (`flag`,
`host-file`, `declared`). They list a declared pool once for each user that
declares it, with that user's figure, and `topology` gives the user's owner
id as `owner` (`null` for a connection that reported no credentials; all such
connections count as one user).

The host file's keys are bare TOML keys, so a pool whose name contains `.` or
`/` (`nim_pty.pty-serial`, `host/linker`) cannot be written there; such a pool
takes its declared capacity, which applies to each user separately, or a
flag, which makes it host-wide.

A daemon older than the message (RQSP minor 0) is never sent it, because it
would close the connection and every session on it; the client warns instead,
and that daemon admits only the pools its file and flags size.

### Flags

`runquotad --help` prints the full list. The ones that shape admission:

| Flag | Default | Meaning |
|---|---|---|
| `--cpu-milli N` | logical processors × 1000 | Host CPU budget; `1000` is one core. Pins the value against a reload. |
| `--memory-bytes N` | 75% of physical memory | Host memory budget. Pins the value against a reload. |
| `--io-slots N` | `1` | Concurrent heavy-I/O slots. |
| `--machine ID=CPU_MILLI,MEMORY_BYTES[,IO_SLOTS[,CPU_SHARE_GROUP]]` | one implicit machine, `local` | A named capacity. Omitted I/O slots inherit `--io-slots`; an omitted share group defaults to the machine's own id. |
| `--cpu-share-group ID=CPU_MILLI` | derived | A CPU cap shared across machines. |
| `--pool NAME=UNITS` | none | An arbitrary named counter. Pins the value against a reload, and over what sessions declare. |
| `--socket PATH` | the rendezvous socket | Where to listen. A path you name here is created on demand; the host-wide one never is. |
| `--host-config PATH` | the host file above | The budget file read at start and on every reload. |
| `--admission-max-wait-millis N` | the host file's `admission.max-wait`, else `120000` | The starvation bound: a request queued this long is served before its user's other requests, and capacity is held for it. `0` turns the bound off. Pins the value against a reload. See [Admission control](/getting_started/concepts#admission-control). |
| `--idle-exit-after SECONDS` | never | Exit (0, through the orderly shutdown) once no client connection has been open for `SECONDS`, counted from start-up or from the moment the last connection closed. A positive whole number; anything else is a usage error (exit 2). See [Exiting when idle](#exiting-when-idle). |

Memory pressure:

| Flag | Default | Meaning |
|---|---|---|
| `--memory-pressure-source host\|deterministic-file\|unavailable` | `host` | Where the pressure reading comes from. |
| `--memory-pressure-file PATH` | — | The file `deterministic-file` reads. |
| `--memory-pressure-required` | off | Treat an unavailable reading as a refusal rather than a shrug. |
| `--memory-pressure-heavy-bytes N` | 512 MiB | The threshold a request counts as heavy at. |

CPU pressure:

| Flag | Default | Meaning |
|---|---|---|
| `--cpu-pressure-file PATH` | `/proc/pressure/cpu` | Where the CPU pressure signal that corrects predictive admission and stops widening is read (a file in the kernel's PSI format). |
| `--host-cpu-busy-file PATH` | the ambient sampler | Read the host's busy CPU share, which predictive admission takes background demand from, as one percentage (0-100) from this file. For tests: what other tenants of a shared host keep busy is neither controllable nor repeatable. An unreadable file means no reclaimed grants. |

Recording (see [the observation store](/usage_guide/observations)):

| Flag | Default | Meaning |
|---|---|---|
| `--observation-db PATH` | beside the host identity file | Where to record once capture is on. Naming a file does not turn capture on. |
| `--no-write-stats` | off | The older spelling of `--measurement capture=off`. Capture is off by default, so this matters only beside something that turns it on; it wins over `--observation-db` regardless of order. |
| `--estimate-db PATH` | — | The learned-estimate database. |
| `--ambient-sample-interval-millis N` | `1000` | Host-wide sampling cadence; `0` turns sampling off. |
| `--profile-uncontended-pct N` | `25` | The most of the host's CPU that everything other than a finished execution may have used over its run for the run to be folded into its command's learned duration and CPU curve. |
| `--measurement NAME=on\|off[,...]` | the defaults | Turns daemon-side measurements on or off by name, repeatable, applied after every other flag. Capture is off by default (it costs more than the measurement budget allows); `capture=on` turns it on, and with it the ambient sampler, which writes into the store. `capture=off` is `--no-write-stats`; `ambient-sampling=off` is an interval of `0`; `metrics-export=off` drops `--metrics-textfile`. An explicit `=on` against one of those older flags (or `metrics-export=on` with no `--metrics-textfile`), an unknown name, or a value other than `on`/`off` is a refusal (exit 2). See [Measurement switches](/usage_guide/observations#measurement-switches). |
| `--metrics-textfile PATH` | none | Write the [capacity figures](#exporting-capacity-figures-for-prometheus) to `PATH` in Prometheus text format. Naming a file is what turns the `metrics-export` measurement on. |
| `--metrics-interval-millis N` | `15000` | How often that file is rewritten. A positive number; anything else is a usage error (exit 2). |
| `--pressure-long-wait-millis N` | `300000` | A reported [build-wait](#build-wait-pressure) at least this long is counted as long. A positive number; anything else is a usage error (exit 2). |
| `--host-identity-file PATH` | `/var/lib/runquota/host-id` (`/var/db/...` on macOS) | Relocates the host state, and the store with it. |

Retention — four bounds, each with the **same unusual rule**:

| Flag | Default |
|---|---|
| `--retention-sweep-interval-millis N` | 1 h (`0` or negative turns retention off; capture is unaffected) |
| `--retention-max-deferred-sweeps N` | `24` |
| `--retention-max-execution-age-millis N` | 90 days |
| `--retention-max-executions N` | `2000000` |
| `--retention-max-ambient-sample-age-millis N` | 14 days |
| `--retention-max-ambient-samples N` | `2000000` |

> **A negative value turns the bound off, and zero does not.** Zero means *keep
> nothing*. This is the opposite of the convention most tools use and it is
> deliberate: "unbounded" and "keep none" are both things somebody wants, and
> collapsing them onto one value would make one of them unsayable.

Virtual machines (Linux; see [Virtual machines](/usage_guide/cli#runquota-vm-hold)):

| Flag | Default | Meaning |
|---|---|---|
| `--vm-link-vsock-port PORT` | none | On a host: accept links from the RunQuota daemons of registered virtual machines on this vsock port (21073 is the port a guest uses when it names none). Without it every registered VM is charged its full shape. A port that cannot be bound is reported in `runquota status --json` (`vm_link.error`); the daemon serves leases either way. |
| `--link-host vsock[:CID]:PORT` | none | In a virtual machine: report what this daemon's leases hold to the host daemon at that vsock address (CID 2, the host, by default), each time it changes. The host is told nothing else and never holds this daemon back. |
| `--link-sample-millis N` | `0` | With `--link-host`: also send the guest's busy CPU (from `/proc/stat`) and CPU pressure every `N` ms; the host then charges the larger of busy and granted. Off by default: no periodic measurement is on until it is shown to fit the measurement budget. |
| `--link-name NAME` | none | A name this guest gives itself on the link, shown by the host. Informational: the host identifies the VM by its vsock CID. |

An unrecognised flag is a refusal, not a warning: `unknown runquotad argument:
<arg>`, exit **2**.

## Exporting capacity figures for Prometheus

A capacity tool (a launch gate, a dashboard, a fleet balancer) can see how
much of a host's CPU builds hold and use, per host and per
[session group](/getting_started/concepts#session-group), and tell it from
other load. Nothing is sampled for this and nothing is asked of the build
tools: the figures come from the lease table, from the CPU totals each
launching client reads from its own `wait4` for the tree's root and sends
when the lease finishes, and from the ambient sampler.

`runquotad --metrics-textfile PATH` writes them in the Prometheus text
exposition format every 15 seconds (`--metrics-interval-millis`), for
[node-exporter's textfile collector](https://github.com/prometheus/node_exporter#textfile-collector):
point `PATH` into the collector's directory and give it a `.prom` name. The
file is written beside the target under a temporary name (`.<name>.<pid>.tmp`,
which the collector ignores) and renamed over it, so a scrape never reads half
a file. It is readable by everyone (mode 0644), because the collector usually
runs as another user. A write that fails leaves the previous file in place, and
is counted in `runquota status --json` (`capacity.textfile`) with its reason.
The file is left in place when the daemon stops; node-exporter's
`node_textfile_mtime_seconds` says how old it is. The writer runs on a thread
of its own and holds the daemon's lock only to copy the figures, so writing the
file never delays a lease.

| Metric | Type | Meaning |
|---|---|---|
| `runquota_host_cpu_budget_cpus` | gauge | The CPU budget the daemon admits against. |
| `runquota_host_cpu_granted_cpus` | gauge | CPU granted to leases now. |
| `runquota_host_memory_reserved_bytes` | gauge | Memory reserved by granted leases now. |
| `runquota_host_pending_requests` | gauge | Requests waiting in the queue. |
| `runquota_host_oldest_pending_wait_seconds` | gauge | How long the longest-waiting request has waited. |
| `runquota_host_cpu_used_seconds_total` | counter | CPU time (user + system) of finished lease trees, as their launchers reported it at exit. |
| `runquota_host_finished_leases_total{totals}` | counter | Finished leases, `totals="reported"` or `"missing"`. |
| `runquota_host_grants_total` | counter | Leases granted. |
| `runquota_host_wait_seconds_total` | counter | Time granted leases spent queued, summed. |
| `runquota_host_cpu_busy_ratio` | gauge | Share of the host's whole CPU capacity that was busy, from the ambient sampler's latest reading. |
| `runquota_host_cpu_foreign_ratio` | gauge | The busy share less what clients reported their running leases used. No client reports that today, so it equals the busy share. |
| `runquota_host_ambient_reading_timestamp_seconds` | gauge | When that reading was taken. |
| `runquota_group_*` | as above | The same live figures and counters per session group, labelled `owner_uid` and `group`. |
| `runquota_host_pressure_{some,full}_avg{10,60,300}` | gauge | [Build-wait pressure](#build-wait-pressure): held-up time per second of wall time, decaying over 10, 60 or 300 s, summed over the invocations that report. |
| `runquota_host_pressure_{wall,some,full}_seconds_total` | counter | The wall time pressure reports covered, and the held-up time in it. |
| `runquota_host_pressure_wait_seconds{kind}` | histogram | Lengths of reported waits of at least a second, by `kind` (`queue`, `slowdown`, `class-queue`). |
| `runquota_host_pressure_long_waits_total{kind}` | counter | Reported waits at or over `--pressure-long-wait-millis`. |
| `runquota_group_pressure_*` | as above | The same per session group, for groups that have reported. |

A few rules make the figures safe to compute with:

- **Used CPU counts what was reported, never what was granted.** A finish
  without totals (a client older than them, or a launcher that could not reap
  its root) adds no CPU; it is counted under `totals="missing"`, so the share
  of work the counter does not cover is visible. A lease released without
  any finish (released early, or its session closed while it ran) is a grant
  and neither kind of finish.
- **Sub-leases are left out.** A sub-lease runs inside its parent lease's tree,
  whose launcher's totals already include it.
- **Counters only grow, and saturate** at 2^64 - 1 microseconds rather than
  wrap, whatever a client sends.
- **Idle groups drop out.** A group that has held nothing, queued nothing and
  finished nothing for an hour leaves the file and the status output; if it
  comes back, its counters start again from zero, which Prometheus's `rate()`
  reads as a counter reset. Host series never drop out. At most 1024 idle
  groups are kept.
- **Labels are escaped** as the format requires. `owner_uid` comes from the
  peer's credentials (`unknown` where the transport reports none). A group
  name that is not valid UTF-8 is shown with U+FFFD in `group` and its bytes in
  hex in an extra `group_hex` label, so two such names never merge.
- **The busy and foreign shares are present only while the ambient sampler
  runs** (it needs the observation store and a positive
  `--ambient-sample-interval-millis`). Build load is the rate of
  `runquota_host_cpu_used_seconds_total`, which lags by one lease, beside
  `runquota_host_cpu_granted_cpus`, which is live.

### Build-wait pressure

A build that waits for RunQuota, or whose commands run slower than they do
on an idle host, is *held up*. A launching client measures that over its own
wall time, in the manner of Linux PSI: *some* is the time in which at least
one of its ready or running commands was held up, *full* the time in which
all of them were. It sends what those grew by to the daemon, with the wall
time covered and each wait of a second or more, in a one-way
`PressureReport`; the daemon computes nothing itself. Reprobuild's engine,
`runquota run` and `runquota jobserver` report when the `pressure-reports`
measurement is on (`RUNQUOTA_MEASUREMENT=pressure-reports=on`; off by
default). A client that knows no expected duration for its commands
(`runquota run` never does) reports its queue waits only, and says so.

The daemon keeps, per host, per session group and per open session,
cumulative totals, averages decaying over 10, 60 and 300 s, and per wait
kind a histogram of lengths and a count of waits at or over
`--pressure-long-wait-millis` (default 300000, five minutes). Every figure
is clamped to what the reporting session could have measured (no more wall
time over all its reports than the session has existed, plus a second; no
wait longer than the session's life) and every counter saturates. A report is accepted only on
the connection that registered its session; a refused report is counted.
`runquota pressure` prints the figures and `runquota pressure --json`
serves them (see [the CLI](/usage_guide/cli#build-wait-pressure)).

The export is the `metrics-export` measurement and is off unless a file is
named. `runquota status --json` carries the same figures as `capacity`,
whether or not a file is written (see
[the CLI](/usage_guide/cli#capacity-figures)).

## What it prints at startup: exactly three lines, always

```text
runquotad listening /run/runquota/runquotad.sock; <stats publisher report>
runquota observation store /var/lib/runquota/observations.sqlite3: schema 4; capture enabled
runquota observation store ...: host <id>; hardware profile <id>; <ambient>; <retention>; <identity>
```

That is a daemon with `--measurement capture=on`. With capture off (the
default) the second line says so and names the switch, and the third says
that no host identity or hardware profile was recorded.

1. where it is listening, plus any rendezvous degradation and the state of the
   published aggregate table;
2. the observation store — open, or the reason it is not;
3. the host identity and hardware profile.

**Three lines, unconditionally.** It used to be three when a store path was
given and one when it was not; a fixed count is what lets a supervisor read the
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

### Stopping with the process that started it

A daemon started for **one** caller can be tied to it: start it with
`RUNQUOTA_EXIT_WITH_PARENT=1` in its environment (POSIX only; Windows ignores
the variable). The daemon records its parent at start, removes the variable
from its own environment so nothing it starts inherits it, and checks its
parent every 200 ms once `SIGTERM` is armed. When the parent has changed —
the parent died and the daemon was re-parented to init or a subreaper — it
sends itself `SIGTERM` and takes exactly the shutdown above, exiting 0. A
parent that is already init at start counts as gone when no explicit owner
was supplied.

Callers that need ownership guaranteed across startup also set
`RUNQUOTA_EXIT_WITH_PARENT_PID` to their own pid before spawning. The daemon
compares against that recorded owner, so a caller dying before daemon entry
cannot cause the daemon to adopt init or a subreaper as its owner. Both
variables are removed from the daemon's environment at entry.
An explicitly supplied PID 1 is valid, allowing the caller to be a container
entrypoint; the daemon stays alive while its observed parent is still 1.

It is the only way such a daemon stops when its caller is `SIGKILL`ed or
OOM-killed, since no handler in the caller runs then. Neither the installed
host-wide service nor the per-user daemon `repro` starts (next section) is
started with it: both are meant to outlive whoever started them.

### Exiting when idle

`runquotad --idle-exit-after SECONDS` makes a daemon end itself once no client
connection has been open for `SECONDS`, counted from start-up or from the
moment the last connection closed. Leases live in sessions and sessions on
connections, so "no connection" includes "no lease"; a client that merely
holds a connection open, saying nothing, keeps the daemon alive. When the
period passes the daemon prints

```text
runquotad: idle exit: no client connection for SECONDS s
```

stops admitting connections, frees its endpoint first and exits 0 through the
shutdown above. The decision and the admission of connections are one step,
so no connection is admitted after it and none admitted before it is cut off;
a client whose connection lands in that instant is closed unserved, exactly as
during a `SIGTERM` shutdown, and should start or find the next daemon.

Without the flag a daemon never idles out.

### One daemon per user on an unprovisioned host

On a host with no RunQuota service installed, `repro` starts one daemon per
user, which every later invocation of that user adopts and which exits by
itself after a period with no client (`--idle-exit-after`). Its endpoint is
computed the same way by every process of the user, from the filesystem and
the effective uid:

1. `RUNQUOTA_USER_ENDPOINT_DIR`, when set;
2. on Linux, `/run/user/<uid>/runquota` when `/run/user/<uid>` is a real
   directory owned by the user with no group or other write permission;
3. otherwise `/tmp/runquota-<uid>`.

The socket is `runquotad.sock` in that directory, which is created `0700`
and must be owned by the user. One owned by anyone else is refused, never
replaced: remove it, or set `RUNQUOTA_USER_ENDPOINT_DIR`. The daemon and its
clients use the owner-only private policy (`RUNQUOTA_ENDPOINT_SCOPE=private`).

Two lock files sit beside the socket:

- `runquotad.sock.lock`, the **lifetime lock**. A daemon that binds a
  private endpoint takes an exclusive `flock` on it before it binds and holds
  it until it exits. A second daemon on the same endpoint is refused (exit 3,
  naming the lock). The lock, not the socket file, says whether a daemon is
  alive there: a daemon killed with `SIGKILL` leaves its socket behind, and
  the kernel releases its lock, so a launcher that finds the socket but a
  free lock knows the socket is stale.
- `runquotad.sock.start`, the **start lock**, held by a launcher while it
  adopts or starts a daemon, so that concurrent invocations never start two.
  The daemon never takes it.

One daemon per *user* is still not one per *host*: two users of an
unprovisioned host each get their own. Installing the service is what gives a
host a single authority.

### Socket activation (systemd)

A `runquotad` started by a systemd `.socket` unit serves the listening socket
systemd hands it on descriptor 3 instead of binding one: with `LISTEN_PID`
equal to its pid and `LISTEN_FDS=1`
([`sd_listen_fds(3)`](https://www.freedesktop.org/software/systemd/man/latest/sd_listen_fds.html)).
It removes the three `LISTEN_*` variables from its environment first, and
refuses (exit 3) a descriptor that is not a listening Unix stream socket, and
one bound at a path other than its configured endpoint (`--socket`, else the
default) -- its clients would be looking somewhere else. With class sockets
there is one descriptor more per declared class, each named `class-<class>`
in `LISTEN_FDNAMES` (the socket unit's `FileDescriptorName=`), and the
shared socket carries any other name. A declared class without a descriptor,
a descriptor for a class the host file does not declare, or a class socket
whose owner, group or mode differs from the file's declaration refuses the
start; and since the sockets are systemd's, a reload that would add, drop or
change one is refused, naming the module as the place to change it. It never removes the socket (systemd owns it), takes no
lifetime lock, and never dials its own socket to wake its accept loop, so it
leaves no queued connection behind that would make systemd start it again at
once. With `--idle-exit-after` it exits when idle and systemd starts it again
on the next connection, which systemd holds queued meanwhile.

The NixOS module turns this on with `services.runquotad.socketActivation =
true`, and `services.runquotad.idleExitAfter = SECONDS` adds the idle period
(it requires socket activation). It declares one socket unit, and so one
`ListenStream`, per `services.runquotad.hostConfig.reservations` entry, with
the class's `socketOwner`, `socketGroup` and `socketMode` as its
`SocketUser`, `SocketGroup` and `SocketMode`; a host file written with
`runquota config set` instead cannot declare them, so a socket-activated
daemon refuses one that declares a class. The nix-darwin service keeps running
unconditionally.

## When things go wrong at runtime

A failed `accept` is counted (`connections_failed` in `runquota status`) and
printed **once**:

```text
runquota accept failed: <msg> (this is counted as connections_failed and not printed again)
```

After 64 consecutive failures the daemon gives up on the endpoint and says so
rather than spinning silently.
