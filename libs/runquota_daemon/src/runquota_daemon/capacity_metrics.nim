## What builds use, for capacity tools: the daemon's per-host and
## per-session-group CPU and memory figures, kept as counters and gauges and
## rendered as Prometheus text exposition (for node-exporter's textfile
## collector) and as JSON (for `runquota status --json`).
##
## WHERE THE FIGURES COME FROM. Nothing here samples anything.
##
## * CPU USED is a counter fed by lease finishes: the user + system CPU time
##   the launching client read from its `wait4` for the tree's root and sent
##   with the finish (`FinishTotals`). A finish that carries no totals (a
##   client older than the totals, or a launcher that could not reap its
##   root) is NOT counted as zero CPU: it adds nothing to the CPU counter and
##   is counted on its own, in `finishedWithoutTotals`, so a reader can see
##   how much of the work the CPU counter does not cover.
## * Sub-leases are left out of every figure here. A sub-lease is carved out
##   of its parent lease, whose launcher waited for the whole tree the
##   sub-lease's processes ran in, so the parent's totals already contain
##   its CPU and counting both would count it twice.
## * CPU GRANTED, RESERVED MEMORY and PENDING REQUESTS are gauges read from
##   the lease table when a snapshot is taken.
## * Host busy and foreign CPU are the ambient sampler's latest reading,
##   attached by the caller (`AmbientFigures`).
##
## COUNTERS ARE MONOTONIC AND SATURATE. Every addition goes through
## `saturatingAdd`: the CPU figures arrive from any local peer, and a
## counter that wrapped would read to a rate function as a reset followed by
## an enormous increase. A counter that has reached `high(uint64)` stays
## there.
##
## LABEL CARDINALITY IS BOUNDED. A group is labelled by its owner uid (from
## peer credentials, never a declared uid) and its name. A group drops out
## of both outputs once it has held nothing, queued nothing and finished
## nothing for `GroupIdleDropMillis`; host-wide series never drop out, so a
## group dropping out never lowers a host counter. Memory is bounded the
## same way: `pruneIdleGroups` forgets the same groups, and keeps at most
## `MaxRetainedIdleGroups` idle ones.
##
## The exposition format is
## <https://prometheus.io/docs/instrumenting/exposition_formats/>; the
## textfile convention (write a temporary file in the same directory, then
## rename it over the target) is node-exporter's,
## <https://github.com/prometheus/node_exporter#textfile-collector>.

import std/[algorithm, os, sets, strutils, tables, unicode]

when defined(posix):
  import std/posix

  proc cRename(oldPath, newPath: cstring): cint {.importc: "rename",
    header: "<stdio.h>".}

  var oNoFollow {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint
    ## Not exported by `std/posix`.

import runquota_core/cpu_profile

const
  GroupIdleDropMillis* = 60'i64 * 60'i64 * 1000'i64
    ## How long a group may hold nothing, queue nothing and finish nothing
    ## before it drops out of the export: one hour.
  MaxRetainedIdleGroups* = 1024
    ## The most idle groups kept in memory. A group that is working is never
    ## dropped; beyond this many idle ones, the longest idle go first.
  DefaultMetricsIntervalMillis* = 15_000
    ## How often the text file is rewritten: node-exporter's textfile
    ## collector reads it on every scrape, and 15 s is the usual scrape
    ## interval.

type
  CapacityCounters* = object
    ## Monotonic counters, for the host or for one group.
    cpuUsedMicros*: uint64
      ## CPU (user + system) reported by finishes that carried totals.
    finishedWithTotals*: uint64
    finishedWithoutTotals*: uint64
      ## Finishes that carried no totals; their CPU is not in `cpuUsedMicros`.
    grants*: uint64
      ## Leases granted.
    waitMillis*: uint64
      ## Time the granted leases spent queued, summed.

  LiveFigures* = object
    ## Gauges, read from the lease table at snapshot time.
    cpuGrantedMilli*: uint64
    memoryReservedBytes*: uint64
    pendingRequests*: uint64
    oldestPendingWaitMillis*: uint64

  GroupCapacity* = object
    counters*: CapacityCounters
    lastActiveMillis*: int64
      ## Monotonic milliseconds of the last event that involved the group:
      ## a session joining or leaving, a lease queued, granted, released or
      ## finished.

  CapacityLedger* = object
    ## What the daemon keeps. Owned by the lease authority and changed only
    ## under its lock, on the threads that serve requests.
    host*: CapacityCounters
    groups*: Table[string, GroupCapacity]
      ## By session group key, `<owner>/<name>` (`sessionGroupKey`).
    lastPruneMillis*: int64

  AmbientFigures* = object
    ## The ambient sampler's latest reading, or `available = false` when the
    ## sampler is off or has not completed a reading yet.
    available*: bool
    busyPct*: float64
      ## Percent of the whole host's CPU capacity that was busy.
    foreignPct*: float64
      ## `busyPct` less what clients reported their running leases used
      ## (`LeaseObservation`); equal to `busyPct` when no client reports.
    atUnixMillis*: int64

  GroupSnapshot* = object
    ownerKnown*: bool
    ownerUid*: int64
    name*: string
    counters*: CapacityCounters
    live*: LiveFigures

  CapacitySnapshot* = object
    cpuBudgetMilli*: uint64
    hostCounters*: CapacityCounters
    hostLive*: LiveFigures
    groups*: seq[GroupSnapshot]
      ## Sorted by owner, then name.
    ambient*: AmbientFigures

  CapacityCopy* = object
    ## What a snapshot is computed from, copied out of the daemon under its
    ## lock so that everything else -- filtering, parsing keys, sorting,
    ## rendering -- happens after the lock is released.
    host*: CapacityCounters
    groups*: seq[tuple[key: string, group: GroupCapacity]]
    leases*: seq[LeaseFigure]
    cpuBudgetMilli*: uint64
    nowMillis*: int64

  LeaseFigure* = object
    ## What a snapshot needs of one host lease (never a sub-lease).
    groupKey*: string
    queued*: bool
      ## Queued; otherwise it holds capacity.
    cpuMilli*: uint64
    memoryBytes*: uint64
    waitedMillis*: uint64
      ## For a queued lease, how long it has waited so far.

# ---------------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------------

proc saturatingAdd*(a, b: uint64): uint64 =
  ## `a + b`, or `high(uint64)` where that would wrap.
  if b > high(uint64) - a: high(uint64) else: a + b

proc finishCpuMicros*(totals: FinishTotals): uint64 =
  ## User + system CPU of a finish's totals, saturating. Meaningful only
  ## when `totals.known`.
  saturatingAdd(totals.cpuUserMicros, totals.cpuSysMicros)

proc groupKeyParts*(key: string; ownerKnown: var bool; ownerUid: var int64;
                    name: var string) =
  ## Split a session group key, `<owner>/<name>`, where the owner is a uid
  ## or `?` for a transport that reported no credentials. The owner part
  ## never contains `/`, so the first `/` separates the two.
  let slash = key.find('/')
  if slash < 0:
    ownerKnown = false
    ownerUid = 0
    name = key
    return
  let owner = key[0 ..< slash]
  name = key[slash + 1 .. ^1]
  ownerKnown = false
  ownerUid = 0
  if owner.len > 0 and owner != "?":
    try:
      ownerUid = parseBiggestInt(owner)
      ownerKnown = true
    except ValueError:
      discard

proc touchGroup*(ledger: var CapacityLedger; key: string; nowMillis: int64) =
  ## Record activity in group `key`, creating its entry if needed.
  if key.len == 0:
    return
  ledger.groups.mgetOrPut(key, GroupCapacity()).lastActiveMillis = nowMillis

proc noteGrant*(ledger: var CapacityLedger; key: string; waitedMillis: uint64;
                nowMillis: int64) =
  ## A host lease was granted after queueing for `waitedMillis`.
  ledger.host.grants = saturatingAdd(ledger.host.grants, 1)
  ledger.host.waitMillis = saturatingAdd(ledger.host.waitMillis, waitedMillis)
  if key.len == 0:
    return
  ledger.touchGroup(key, nowMillis)
  var group = addr ledger.groups[key]
  group.counters.grants = saturatingAdd(group.counters.grants, 1)
  group.counters.waitMillis = saturatingAdd(group.counters.waitMillis,
    waitedMillis)

proc addFinish(counters: var CapacityCounters; totals: FinishTotals) =
  if totals.known:
    counters.cpuUsedMicros = saturatingAdd(counters.cpuUsedMicros,
      finishCpuMicros(totals))
    counters.finishedWithTotals = saturatingAdd(counters.finishedWithTotals, 1)
  else:
    counters.finishedWithoutTotals =
      saturatingAdd(counters.finishedWithoutTotals, 1)

proc noteFinish*(ledger: var CapacityLedger; key: string; totals: FinishTotals;
                 nowMillis: int64) =
  ## A host lease finished with `totals` (which may be unknown).
  ledger.host.addFinish(totals)
  if key.len == 0:
    return
  ledger.touchGroup(key, nowMillis)
  ledger.groups[key].counters.addFinish(totals)

proc liveFigures*(leases: openArray[LeaseFigure]):
    tuple[host: LiveFigures, groups: Table[string, LiveFigures]] =
  ## The gauges for the host and for every group that has a lease.
  for lease in leases:
    var group = result.groups.getOrDefault(lease.groupKey)
    if lease.queued:
      inc result.host.pendingRequests
      inc group.pendingRequests
      result.host.oldestPendingWaitMillis =
        max(result.host.oldestPendingWaitMillis, lease.waitedMillis)
      group.oldestPendingWaitMillis =
        max(group.oldestPendingWaitMillis, lease.waitedMillis)
    else:
      result.host.cpuGrantedMilli =
        saturatingAdd(result.host.cpuGrantedMilli, lease.cpuMilli)
      result.host.memoryReservedBytes =
        saturatingAdd(result.host.memoryReservedBytes, lease.memoryBytes)
      group.cpuGrantedMilli = saturatingAdd(group.cpuGrantedMilli,
        lease.cpuMilli)
      group.memoryReservedBytes = saturatingAdd(group.memoryReservedBytes,
        lease.memoryBytes)
    if lease.groupKey.len > 0:
      result.groups[lease.groupKey] = group

proc groupIsIdle(group: GroupCapacity; working: bool; nowMillis: int64): bool =
  not working and nowMillis - group.lastActiveMillis >= GroupIdleDropMillis

proc pruneIdleGroups*(ledger: var CapacityLedger; working: HashSet[string];
                      nowMillis: int64) =
  ## Forget every group idle for `GroupIdleDropMillis`, and the longest idle
  ## beyond `MaxRetainedIdleGroups` idle ones. `working` holds the keys of
  ## groups with a lease queued or holding capacity: those are never
  ## forgotten, however long ago their last event was.
  ledger.lastPruneMillis = nowMillis
  var expired: seq[string]
  var idle: seq[tuple[at: int64, key: string]]
  for key, group in ledger.groups.pairs:
    if key in working:
      continue
    if group.groupIsIdle(false, nowMillis):
      expired.add(key)
    else:
      idle.add((group.lastActiveMillis, key))
  for key in expired:
    ledger.groups.del(key)
  if idle.len > MaxRetainedIdleGroups:
    idle.sort()
    for i in 0 ..< idle.len - MaxRetainedIdleGroups:
      ledger.groups.del(idle[i].key)

proc copyFor*(ledger: CapacityLedger; leases: sink seq[LeaseFigure];
              cpuBudgetMilli: uint64; nowMillis: int64): CapacityCopy =
  ## The part of a snapshot taken under the daemon lock: plain copies, no
  ## parsing or sorting. READ-ONLY on the ledger, so a thread that does not
  ## own the ledger's memory may call it: idle groups are left out by
  ## `snapshot` and forgotten by `pruneIdleGroups`.
  result.host = ledger.host
  result.groups = newSeqOfCap[tuple[key: string, group: GroupCapacity]](
    ledger.groups.len)
  for key, group in ledger.groups.pairs:
    result.groups.add((key, group))
  result.leases = leases
  result.cpuBudgetMilli = cpuBudgetMilli
  result.nowMillis = nowMillis

proc snapshot*(copy: CapacityCopy): CapacitySnapshot =
  ## The figures as of `copy.nowMillis`, with idle groups left out.
  let live = liveFigures(copy.leases)
  result.cpuBudgetMilli = copy.cpuBudgetMilli
  result.hostCounters = copy.host
  result.hostLive = live.host
  var seen = initHashSet[string]()
  for (key, entry) in copy.groups:
    seen.incl(key)
    if entry.groupIsIdle(live.groups.hasKey(key), copy.nowMillis):
      continue
    var group = GroupSnapshot(counters: entry.counters,
      live: live.groups.getOrDefault(key))
    groupKeyParts(key, group.ownerKnown, group.ownerUid, group.name)
    result.groups.add(group)
  # A lease whose group has no entry (impossible today: every queue and
  # grant touches it) still shows, with zero counters.
  for key, figures in live.groups.pairs:
    if key.len > 0 and key notin seen:
      var group = GroupSnapshot(live: figures)
      groupKeyParts(key, group.ownerKnown, group.ownerUid, group.name)
      result.groups.add(group)
  result.groups.sort(proc (a, b: GroupSnapshot): int =
    result = cmp(a.ownerKnown, b.ownerKnown)
    if result == 0: result = cmp(a.ownerUid, b.ownerUid)
    if result == 0: result = cmp(a.name, b.name))

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

proc fixedPoint(value: uint64; scale: uint64; digits: int): string =
  ## `value / scale` in decimal, exactly, with `digits` fractional digits.
  $(value div scale) & "." & align($(value mod scale), digits, '0')

proc cpus(milli: uint64): string = fixedPoint(milli, 1000, 3)
proc secondsOfMicros(micros: uint64): string = fixedPoint(micros, 1_000_000, 6)
proc secondsOfMillis(millis: uint64): string = fixedPoint(millis, 1000, 3)

proc ratio(pct: float64): string =
  formatFloat(max(0.0, pct) / 100.0, ffDecimal, 6)

proc escapeLabelValue*(value: string): string =
  ## A label value as the text format spells it: backslash, double quote
  ## and line feed escaped. The value must already be valid UTF-8.
  for ch in value:
    case ch
    of '\\': result.add("\\\\")
    of '"': result.add("\\\"")
    of '\n': result.add("\\n")
    else: result.add(ch)

proc validUtf8Label(name: string): tuple[label: string, hex: string] =
  ## The `group` label for a name, and the `group_hex` label when it needs
  ## one. Label values must be valid UTF-8, and a session group name is any
  ## bytes but control characters. A name that is not valid UTF-8 is shown
  ## with U+FFFD for each bad byte AND carries its bytes in hex, so two such
  ## names never collapse into one series (or collide with a valid name
  ## that happens to contain U+FFFD).
  if validateUtf8(name) < 0:
    return (name, "")
  var label = ""
  var i = 0
  while i < name.len:
    let rest = name[i .. ^1]
    let bad = validateUtf8(rest)
    if bad < 0:
      label.add(rest)
      break
    label.add(rest[0 ..< bad])
    label.add("\xEF\xBF\xBD")
    i += bad + 1
  (label, toHex(name).toLowerAscii())

proc groupLabels(group: GroupSnapshot): string =
  let (label, hex) = validUtf8Label(group.name)
  result = "owner_uid=\"" &
    (if group.ownerKnown: $group.ownerUid else: "unknown") &
    "\",group=\"" & escapeLabelValue(label) & "\""
  if hex.len > 0:
    result.add(",group_hex=\"" & hex & "\"")

proc family(output: var string; name, kind, help: string) =
  output.add("# HELP " & name & " " & help & "\n")
  output.add("# TYPE " & name & " " & kind & "\n")

proc sample(output: var string; name, labels, value: string) =
  output.add(name)
  if labels.len > 0:
    output.add("{" & labels & "}")
  output.add(" " & value & "\n")

proc expositionText*(snap: CapacitySnapshot): string =
  ## The snapshot in Prometheus text exposition format 0.0.4. No sample
  ## carries a timestamp: node-exporter's textfile collector refuses them.
  result.family("runquota_host_cpu_budget_cpus", "gauge",
    "CPU budget RunQuota admits against on this host, in CPUs.")
  result.sample("runquota_host_cpu_budget_cpus", "", cpus(snap.cpuBudgetMilli))
  result.family("runquota_host_cpu_granted_cpus", "gauge",
    "CPU currently granted to leases, in CPUs.")
  result.sample("runquota_host_cpu_granted_cpus", "",
    cpus(snap.hostLive.cpuGrantedMilli))
  result.family("runquota_host_memory_reserved_bytes", "gauge",
    "Memory currently reserved by granted leases.")
  result.sample("runquota_host_memory_reserved_bytes", "",
    $snap.hostLive.memoryReservedBytes)
  result.family("runquota_host_pending_requests", "gauge",
    "Lease requests waiting in the queue.")
  result.sample("runquota_host_pending_requests", "",
    $snap.hostLive.pendingRequests)
  result.family("runquota_host_oldest_pending_wait_seconds", "gauge",
    "How long the longest-waiting queued request has waited.")
  result.sample("runquota_host_oldest_pending_wait_seconds", "",
    secondsOfMillis(snap.hostLive.oldestPendingWaitMillis))
  result.family("runquota_host_cpu_used_seconds_total", "counter",
    "CPU time (user + system) of finished lease trees, as their " &
    "launchers reported it at exit. Finishes without totals add nothing.")
  result.sample("runquota_host_cpu_used_seconds_total", "",
    secondsOfMicros(snap.hostCounters.cpuUsedMicros))
  result.family("runquota_host_finished_leases_total", "counter",
    "Leases finished, by whether the finish reported the tree's CPU totals.")
  result.sample("runquota_host_finished_leases_total", "totals=\"reported\"",
    $snap.hostCounters.finishedWithTotals)
  result.sample("runquota_host_finished_leases_total", "totals=\"missing\"",
    $snap.hostCounters.finishedWithoutTotals)
  result.family("runquota_host_grants_total", "counter", "Leases granted.")
  result.sample("runquota_host_grants_total", "", $snap.hostCounters.grants)
  result.family("runquota_host_wait_seconds_total", "counter",
    "Time granted leases spent queued before their grant, summed.")
  result.sample("runquota_host_wait_seconds_total", "",
    secondsOfMillis(snap.hostCounters.waitMillis))
  if snap.ambient.available:
    result.family("runquota_host_cpu_busy_ratio", "gauge",
      "Share of the host's whole CPU capacity that was busy, from the " &
      "ambient sampler's latest reading.")
    result.sample("runquota_host_cpu_busy_ratio", "", ratio(snap.ambient.busyPct))
    result.family("runquota_host_cpu_foreign_ratio", "gauge",
      "Busy share less what clients reported their running leases used, " &
      "from the same reading.")
    result.sample("runquota_host_cpu_foreign_ratio", "",
      ratio(snap.ambient.foreignPct))
    result.family("runquota_host_ambient_reading_timestamp_seconds", "gauge",
      "Unix time of the ambient reading the busy and foreign shares are from.")
    result.sample("runquota_host_ambient_reading_timestamp_seconds", "",
      fixedPoint(uint64(max(0'i64, snap.ambient.atUnixMillis)), 1000, 3))
  if snap.groups.len == 0:
    return
  # One family at a time: the format wants every sample of a family
  # together, after its HELP and TYPE.
  template groupFamily(name, kind, help: string;
                       value: proc (g: GroupSnapshot): string) =
    result.family(name, kind, help)
    for group in snap.groups:
      result.sample(name, groupLabels(group), value(group))
  groupFamily("runquota_group_cpu_granted_cpus", "gauge",
    "CPU currently granted to the session group's leases, in CPUs.",
    proc (g: GroupSnapshot): string = cpus(g.live.cpuGrantedMilli))
  groupFamily("runquota_group_memory_reserved_bytes", "gauge",
    "Memory currently reserved by the session group's granted leases.",
    proc (g: GroupSnapshot): string = $g.live.memoryReservedBytes)
  groupFamily("runquota_group_pending_requests", "gauge",
    "The session group's lease requests waiting in the queue.",
    proc (g: GroupSnapshot): string = $g.live.pendingRequests)
  groupFamily("runquota_group_oldest_pending_wait_seconds", "gauge",
    "How long the session group's longest-waiting queued request has waited.",
    proc (g: GroupSnapshot): string =
      secondsOfMillis(g.live.oldestPendingWaitMillis))
  groupFamily("runquota_group_cpu_used_seconds_total", "counter",
    "CPU time (user + system) of the session group's finished lease trees, " &
    "as their launchers reported it at exit.",
    proc (g: GroupSnapshot): string = secondsOfMicros(g.counters.cpuUsedMicros))
  result.family("runquota_group_finished_leases_total", "counter",
    "The session group's finished leases, by whether the finish reported " &
    "the tree's CPU totals.")
  for group in snap.groups:
    let labels = groupLabels(group)
    result.sample("runquota_group_finished_leases_total",
      labels & ",totals=\"reported\"", $group.counters.finishedWithTotals)
    result.sample("runquota_group_finished_leases_total",
      labels & ",totals=\"missing\"", $group.counters.finishedWithoutTotals)
  groupFamily("runquota_group_grants_total", "counter",
    "Leases granted to the session group.",
    proc (g: GroupSnapshot): string = $g.counters.grants)
  groupFamily("runquota_group_wait_seconds_total", "counter",
    "Time the session group's granted leases spent queued, summed.",
    proc (g: GroupSnapshot): string = secondsOfMillis(g.counters.waitMillis))

proc jsonString(value: string): string =
  ## A JSON string literal. Bytes that are not valid UTF-8 are replaced, as
  ## a JSON text must be UTF-8 (RFC 8259 section 8.1).
  let (label, _) = validUtf8Label(value)
  result = "\""
  for ch in label:
    case ch
    of '"': result.add("\\\"")
    of '\\': result.add("\\\\")
    of '\0' .. '\x1f', '\x7f':
      result.add("\\u" & toHex(ord(ch), 4))
    else: result.add(ch)
  result.add("\"")

proc countersJson(counters: CapacityCounters): string =
  "\"cpu_used_micros\":" & $counters.cpuUsedMicros &
    ",\"finished_with_totals\":" & $counters.finishedWithTotals &
    ",\"finished_without_totals\":" & $counters.finishedWithoutTotals &
    ",\"grants\":" & $counters.grants &
    ",\"wait_millis\":" & $counters.waitMillis

proc liveJson(live: LiveFigures): string =
  "\"cpu_granted_milli\":" & $live.cpuGrantedMilli &
    ",\"memory_reserved_bytes\":" & $live.memoryReservedBytes &
    ",\"pending_requests\":" & $live.pendingRequests &
    ",\"oldest_pending_wait_millis\":" & $live.oldestPendingWaitMillis

proc capacityJson*(snap: CapacitySnapshot; textfile: string): string =
  ## The snapshot as the `capacity` member of `runquota status --json`:
  ## the same figures as the text file, in the daemon's integer units.
  ## `textfile` is a JSON value describing the writer (or `null`).
  result = "{\"cpu_budget_milli\":" & $snap.cpuBudgetMilli &
    ",\"host\":{" & liveJson(snap.hostLive) & "," &
      countersJson(snap.hostCounters)
  if snap.ambient.available:
    result.add(",\"cpu_busy_pct\":" & formatFloat(snap.ambient.busyPct,
      ffDecimal, 3) & ",\"cpu_foreign_pct\":" &
      formatFloat(snap.ambient.foreignPct, ffDecimal, 3) &
      ",\"ambient_reading_unix_millis\":" & $snap.ambient.atUnixMillis)
  else:
    result.add(",\"cpu_busy_pct\":null,\"cpu_foreign_pct\":null" &
      ",\"ambient_reading_unix_millis\":null")
  result.add("},\"groups\":[")
  for i, group in snap.groups:
    if i > 0:
      result.add(",")
    result.add("{\"owner_uid\":" &
      (if group.ownerKnown: $group.ownerUid else: "null") &
      ",\"name\":" & jsonString(group.name) & "," & liveJson(group.live) &
      "," & countersJson(group.counters) & "}")
  result.add("],\"textfile\":" & textfile & "}")

# ---------------------------------------------------------------------------
# The text file
# ---------------------------------------------------------------------------

proc writeTextfileAtomically*(path, content: string): string =
  ## Replace `path` with `content` so a reader sees the old file or the new
  ## one, never a part: write a temporary file in the same directory (a
  ## rename is atomic only within one file system), then rename it over
  ## `path`. Returns "" or why it failed; a failure leaves the old file.
  ##
  ## The temporary name is `.<name>.<pid>.tmp`, which the textfile
  ## collector ignores (it reads `*.prom` only), and it is created with
  ## `O_EXCL | O_NOFOLLOW` so a planted file or link is never written
  ## through. The file is readable by everyone (0644): the collector usually
  ## runs as another user. It is not synced to disk; after a crash the
  ## figures are rewritten within one interval, and a stale file is what
  ## node-exporter's `node_textfile_mtime_seconds` exposes.
  let (dir, name, ext) = splitFile(path)
  let tmp = (if dir.len > 0: dir else: ".") / ("." & name & ext & "." &
    $getCurrentProcessId() & ".tmp")
  when defined(posix):
    # A leftover from a daemon of the same pid that died mid-write.
    discard posix.unlink(tmp.cstring)
    let fd = posix.open(tmp.cstring, O_WRONLY or O_CREAT or O_EXCL or
      O_CLOEXEC or oNoFollow, Mode(0o644))
    if fd < 0:
      return "cannot create " & tmp & ": " & $strerror(errno)
    discard posix.fchmod(fd, Mode(0o644))
    var written = 0
    var failure = ""
    while written < content.len:
      let n = posix.write(fd, unsafeAddr content[written],
        content.len - written)
      if n < 0:
        if errno == EINTR:
          continue
        failure = "cannot write " & tmp & ": " & $strerror(errno)
        break
      written += n
    if posix.close(fd) != 0 and failure.len == 0:
      failure = "cannot close " & tmp & ": " & $strerror(errno)
    if failure.len == 0 and cRename(tmp.cstring, path.cstring) != 0:
      failure = "cannot rename " & tmp & " to " & path & ": " &
        $strerror(errno)
    if failure.len > 0:
      discard posix.unlink(tmp.cstring)
    failure
  else:
    try:
      writeFile(tmp, content)
      moveFile(tmp, path)
      ""
    except CatchableError as err:
      try: removeFile(tmp) except CatchableError: discard
      "cannot write " & path & ": " & err.msg
