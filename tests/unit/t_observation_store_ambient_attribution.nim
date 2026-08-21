## M11 gate, the deterministic half: the attribution arithmetic, the clamp,
## and the boundary that says the daemon may not look at process trees.
##
## No mocks, and nothing here is a stand-in for a measurement: the two
## ``HostLoadReading`` values are *constructed* rather than measured on
## purpose, because the property under test is arithmetic and a property
## checked against whatever the machine happened to be doing is a property
## checked against a moving target. The measured half — that ``foreign_*``
## really tracks a real load on a real machine — is
## ``t_ambient_load_attribution``, and neither file is sufficient alone:
## this one cannot show the sampler reads anything true, and that one
## cannot pin an exact value.
##
## THE CLAMP IS THE POINT OF THE FILE. ``foreign_* = host_total - self_*``
## goes negative whenever a client's report covers a busier window than the
## instant the sample fell in, which is the normal case rather than an
## error. Both arms are asserted: clamped to exactly zero when reports
## exceed the host total, and strictly positive and exactly equal to the
## difference when they do not — because a "clamp" implemented as "always
## zero" satisfies the first arm and destroys the column.
##
## The boundary check at the end is a source-inspection test. It is pinned
## to the sentence in ``runquota/CLAUDE.md`` it enforces, so deleting the
## boundary from the policy file fails the test rather than quietly
## retiring it, and it carries a positive control: the same scanner is run
## over the client-side helper that DOES walk process trees and must find
## it there. A scanner that finds nothing anywhere agrees with every
## implementation.

import std/[options, os, strutils, unittest]

import runquota_observation_store

const
  # Fifty-eight lines apart from the store, so that a change to either
  # file's location is a compile-time problem rather than a silently
  # skipped test.
  repoRoot = currentSourcePath().parentDir.parentDir.parentDir
  ambientSource =
    repoRoot / "libs" / "runquota_observation_store" / "src" /
    "runquota_observation_store" / "ambient.nim"
  daemonSource =
    repoRoot / "libs" / "runquota_daemon" / "src" / "runquota_daemon.nim"
  macosTreeSource =
    repoRoot / "libs" / "runquota_host_macos" / "src" / "runquota_host_macos" /
    "process_telemetry.nim"
  linuxTreeSource =
    repoRoot / "libs" / "runquota_host_linux" / "src" / "runquota_host_linux.nim"
  boundaryFile = repoRoot / "CLAUDE.md"

  perProcessInterfaces = [
    # Every documented way of asking an operating system about a PROCESS
    # rather than about the MACHINE. None of these may appear anywhere in
    # the sampler or on the daemon's sampling path.
    "proc_listpids", "proc_pidinfo", "proc_listchildpids", "proc_pid_rusage",
    "libproc.h", "sys/proc_info.h", "kinfo_proc", "KERN_PROC",
    "task_for_pid", "ProcessTreeTelemetry", "processTreeRows",
    "readProcessRow", "readChildProcessIds", "/proc/self"]

  # The ONLY `/proc` files the sampler may name. Every one of them is a
  # host-wide aggregate; a per-process path (`/proc/<pid>/stat`) is not on
  # the list and cannot be added by accident.
  allowedProcPaths = [
    "/proc/stat", "/proc/meminfo", "/proc/vmstat", "/proc/loadavg",
    "/proc/diskstats"]

proc scratchDir(name: string): string =
  result = getTempDir() / ("runquota-m11u-" & name & "-" &
    $getCurrentProcessId())
  removeDir(result)
  createDir(result)

proc reading(atMillis, busyMillis, totalMillis, memTotal, memAvailable,
             swapIn: int64; loadAvg = 1.0; ioQueue = ioQueueDepthUnmeasured):
    HostLoadReading =
  HostLoadReading(
    available: true, source: "constructed", detail: "",
    atUnixMillis: atMillis, cpuBusyMillis: busyMillis,
    cpuTotalMillis: totalMillis, memTotalBytes: memTotal,
    memAvailableBytes: memAvailable, swapInPages: swapIn,
    loadAvg1m: loadAvg, ioQueueDepth: ioQueue)

const
  gib = 1024'i64 * 1024'i64 * 1024'i64
  # A machine with 64 GiB, 40 GiB of it available, so 24 GiB is in use.
  memTotal = 64'i64 * gib
  memAvailable = 40'i64 * gib
  memUsed = 24'i64 * gib

proc pair(busyDeltaMillis, totalDeltaMillis: int64;
          swapDelta = 0'i64; elapsedMillis = 1000'i64):
    tuple[previous, current: HostLoadReading] =
  let previous = reading(1_700_000_000_000'i64, 900_000, 8_000_000, memTotal,
    memAvailable, 4242)
  let current = reading(previous.atUnixMillis + elapsedMillis,
    previous.cpuBusyMillis + busyDeltaMillis,
    previous.cpuTotalMillis + totalDeltaMillis, memTotal, memAvailable,
    previous.swapInPages + swapDelta)
  (previous, current)

proc scannedFor(path: string; tokens: openArray[string]): seq[string] =
  let text = readFile(path)
  for token in tokens:
    if token in text:
      result.add(token)

proc assignmentsTo(text, field: string): int =
  ## How many times ``field`` appears on the LEFT of an assignment.
  ##
  ## Written as a scan rather than as a substring test because
  ## ``x.field ==`` contains ``x.field =`` and a naive test would call a
  ## comparison an assignment. ``=``, ``+=`` and ``-=`` all count; ``==``
  ## does not.
  var index = 0
  while true:
    let hit = text.find(field, index)
    if hit < 0:
      break
    var cursor = hit + field.len
    index = cursor
    while cursor < text.len and text[cursor] == ' ':
      cursor += 1
    if cursor >= text.len:
      break
    if text[cursor] in {'+', '-'} and cursor + 1 < text.len and
        text[cursor + 1] == '=':
      result += 1
    elif text[cursor] == '=' and
        (cursor + 1 >= text.len or text[cursor + 1] != '='):
      result += 1

suite "observation_store_ambient_attribution":

  test "a rate needs two readings that actually moved":
    # macOS updates the mach CPU tick counters on its own schedule. A
    # byte-identical snapshot divided by itself is 0.0, and 0.0 in
    # `cpu_busy_pct` does not read as "no measurement" — it reads as an
    # idle machine, which is a lie a reader will average.
    let base = reading(1000, 500_000, 4_000_000, memTotal, memAvailable, 10)
    check classifyReadings(base, base) == rpStale

    var advanced = base
    advanced.atUnixMillis += 1000
    advanced.cpuTotalMillis += 16_000
    advanced.cpuBusyMillis += 2_000
    check classifyReadings(base, advanced) == rpAdvanced

    # The clock moved but the counters did not: still no measurement.
    var onlyClock = base
    onlyClock.atUnixMillis += 1000
    check classifyReadings(base, onlyClock) == rpStale

    # Backwards in any dimension is a wrap or a reset, never a rate. Each
    # field is walked back BELOW the baseline, which is what a 32-bit
    # ``natural_t`` tick counter does about once a month per state on a
    # sixteen-core machine.
    for mutate in [
        proc (r: var HostLoadReading) = r.cpuTotalMillis = base.cpuTotalMillis - 1,
        proc (r: var HostLoadReading) = r.cpuBusyMillis = base.cpuBusyMillis - 1,
        proc (r: var HostLoadReading) = r.swapInPages = base.swapInPages - 1,
        proc (r: var HostLoadReading) = r.atUnixMillis = base.atUnixMillis - 1]:
      var broken = advanced
      mutate(broken)
      check classifyReadings(base, broken) == rpDiscontinuous
      # And the same field left alone still classifies as a measurement,
      # so the four assertions above are about the mutation rather than
      # about `advanced` having been broken some other way.
      check classifyReadings(base, advanced) == rpAdvanced

    # Busy time cannot exceed elapsed capacity; if it does, the two
    # counters came from different epochs.
    var impossible = base
    impossible.atUnixMillis += 1000
    impossible.cpuTotalMillis += 1_000
    impossible.cpuBusyMillis += 2_000
    check classifyReadings(base, impossible) == rpDiscontinuous

  test "cpu_busy_pct is busy CPU time over elapsed capacity":
    # Percent of the WHOLE MACHINE, not of one core: 1_000_000 ms of busy
    # CPU time inside 8_000_000 ms of elapsed sixteen-core capacity is
    # 12.5%, whatever the wall clock says. Wall time and CPU time are not
    # interchangeable and the denominator is the one that says which is
    # meant.
    let (previous, current) = pair(1_000_000, 8_000_000)
    let row = attributeAmbientSample("host-a", previous, current, [])
    check row.cpuBusyPct == 12.5
    check row.hostId == "host-a"
    check row.sampledAtUnixMillis == current.atUnixMillis
    check row.memAvailableBytes == memAvailable

    # And the wall clock does NOT enter it: the same counters over a
    # tenfold longer wall interval describe the same fraction.
    let (p2, c2) = pair(1_000_000, 8_000_000, elapsedMillis = 10_000)
    check attributeAmbientSample("host-a", p2, c2, []).cpuBusyPct == 12.5

  test "swap_in_rate is pages per second over the sampled interval":
    let (previous, current) = pair(1_000_000, 8_000_000, swapDelta = 512,
      elapsedMillis = 2000)
    check attributeAmbientSample("host-a", previous, current, []).swapInRate ==
      256.0
    let (p2, c2) = pair(1_000_000, 8_000_000, swapDelta = 0)
    check attributeAmbientSample("host-a", p2, c2, []).swapInRate == 0.0

  test "self is exactly what clients reported, and nothing else":
    # THE LOAD-BEARING ASSERTION AGAINST PROCESS-TREE INSPECTION. The
    # daemon is a lease authority; it does not measure client processes.
    # `self_*` is therefore the arithmetic sum of what clients said about
    # themselves, to the last bit, and any contribution derived from
    # anywhere else — a measured process tree, a lease reservation, a
    # learned estimate — changes a number pinned here. The figures are
    # deliberately awkward: no measurement produces 3.25 and 0.75.
    let reports = [
      SelfReport(executionId: "exec-a", cpuPct: 12.5, rssBytes: 3 * gib),
      SelfReport(executionId: "exec-b", cpuPct: 3.25, rssBytes: 1 * gib),
      SelfReport(executionId: "exec-c", cpuPct: 0.75, rssBytes: 512 * 1024 * 1024)]
    let (previous, current) = pair(3_200_000, 8_000_000)         # 40% busy
    let row = attributeAmbientSample("host-a", previous, current, reports)

    check row.cpuBusyPct == 40.0
    check row.selfCpuPct == 16.5
    check row.selfRssBytes == 4 * gib + 512 * 1024 * 1024
    check sumSelfCpuPct(reports) == row.selfCpuPct
    check sumSelfRssBytes(reports) == row.selfRssBytes

    # Foreign is the residual, exactly.
    check row.foreignCpuPct == 40.0 - 16.5
    check row.foreignRssBytes == memUsed - row.selfRssBytes
    check row.foreignCpuPct > 0.0
    check row.foreignRssBytes > 0

    # An unreported execution lands in FOREIGN rather than being invented
    # into self. That is the correct failure direction for a lease
    # authority: it understates its own share rather than claiming a
    # measurement it did not make.
    let withoutC = attributeAmbientSample("host-a", previous, current,
      reports[0 .. 1])
    check withoutC.selfCpuPct == 15.75
    check withoutC.foreignCpuPct == row.foreignCpuPct + 0.75
    check withoutC.foreignRssBytes ==
      row.foreignRssBytes + 512 * 1024 * 1024

  test "foreign is CLAMPED AT ZERO when client reporting lags sampling":
    let (previous, current) = pair(800_000, 8_000_000)         # 10% busy
                                                               # A client whose report covers a window busier than the instant the
                                                               # sample fell in. This is lag, not error: reports describe intervals
                                                               # and samples describe instants.
    let overshooting = [
      SelfReport(executionId: "exec-a", cpuPct: 55.0, rssBytes: 20 * gib),
      SelfReport(executionId: "exec-b", cpuPct: 20.0, rssBytes: 40 * gib)]
    let row = attributeAmbientSample("host-a", previous, current, overshooting)

    check row.cpuBusyPct == 10.0
    check row.selfCpuPct == 75.0
    check row.selfRssBytes == 60 * gib
    # Exactly zero, not merely non-negative: a residual that ran to -65.0
    # and was reported as -65.0 would also satisfy ">= -100".
    check row.foreignCpuPct == 0.0
    check row.foreignRssBytes == 0'i64
    check row.foreignCpuPct >= 0.0
    check row.foreignRssBytes >= 0'i64

    # THE POSITIVE CONTROL. "Clamped at zero" implemented as "always zero"
    # passes every assertion above and destroys the column. One percentage
    # point of headroom, and one byte of it, must survive.
    let barelyUnder = [
      SelfReport(executionId: "exec-a", cpuPct: 9.0,
        rssBytes: memUsed - 1)]
    let edge = attributeAmbientSample("host-a", previous, current, barelyUnder)
    check edge.foreignCpuPct == 1.0
    check edge.foreignCpuPct > 0.0
    check edge.foreignRssBytes == 1'i64

    # And the clamp agrees with the database rather than merely preceding
    # it: the schema refuses a negative, so an unclamped value would be
    # rejected on write and the sample lost entirely.
    let dir = scratchDir("clamp")
    defer: removeDir(dir)
    let store = openObservationStore(dir / "observations.sqlite")
    check store.captureEnabled
    let hostId = resolveHostIdentity(dir / "host-id").hostId
    check store.ensureHostRow(hostId, "boot-0")
    var stored = row
    stored.hostId = hostId
    check store.insertAmbientSample(stored)
    let readBack = store.readAmbientSamples()
    check readBack.len == 1
    check readBack[0].foreignCpuPct == 0.0
    check readBack[0].foreignRssBytes == 0'i64
    check readBack[0].selfCpuPct == 75.0
    check readBack[0].cpuBusyPct == 10.0

    var negative = stored
    negative.foreignCpuPct = -0.5
    check not store.insertAmbientSample(negative)
    negative = stored
    negative.sampledAtUnixMillis += 1
    negative.foreignRssBytes = -1
    check not store.insertAmbientSample(negative)
    check store.readAmbientSamples().len == 1

  test "the live self-report set is a set, and it empties":
    # `self_*` is the sum over CONCURRENTLY LIVE executions. A client
    # reporting twice must not double its own weight, and a finished
    # execution must leave, or `self` grows without bound and drives
    # `foreign` permanently to the clamp.
    clearSelfReportedExecutions()
    check liveSelfReports().len == 0

    reportSelfExecution("exec-a", 10.0, 1000)
    reportSelfExecution("exec-b", 4.0, 2000)
    check liveSelfReports().len == 2
    check sumSelfCpuPct(liveSelfReports()) == 14.0
    check sumSelfRssBytes(liveSelfReports()) == 3000

    reportSelfExecution("exec-a", 25.0, 7000)
    check liveSelfReports().len == 2
    check sumSelfCpuPct(liveSelfReports()) == 29.0
    check sumSelfRssBytes(liveSelfReports()) == 9000

    endSelfReportedExecution("exec-a")
    check liveSelfReports().len == 1
    check sumSelfCpuPct(liveSelfReports()) == 4.0
    endSelfReportedExecution("exec-does-not-exist")
    check liveSelfReports().len == 1
    endSelfReportedExecution("exec-b")
    check liveSelfReports().len == 0
    check sumSelfCpuPct(liveSelfReports()) == 0.0

  test "a sample whose millisecond is taken is DROPPED, never re-timed":
    # `(host_id, sampled_at_unix_millis)` is the primary key. Two samples
    # inside one millisecond collide, and the only two things an
    # implementation can do with the loser are to drop it or to move its
    # timestamp. Moving it writes an instant at which no reading was taken
    # -- a fabricated value presented as an observation, which OS-2
    # forbids -- so it is dropped and counted, exactly as this module
    # already treats a stale pair and a discontinuous one.
    check ambientSampleFollows(1_700_000_000_000'i64, 1_700_000_000_001'i64)
    check not ambientSampleFollows(1_700_000_000_000'i64,
      1_700_000_000_000'i64)
    check not ambientSampleFollows(1_700_000_000_000'i64,
      1_699_999_999_999'i64)

    # The counter is on the same surface as the other two refusals, and a
    # sampler that has taken no colliding sample reads zero rather than
    # not being readable at all.
    stopAmbientSampler()
    startAmbientSampler("", "host-x")
    check ambientSamplesCollided() == 0
    stopAmbientSampler()

    # THE ASSERTION THAT FAILS AGAINST A RE-TIMING SAMPLER, and the reason
    # it is an inspection gate: the collision path is unreachable at any
    # sane cadence, so no run of the sampler can distinguish "drops" from
    # "re-times" -- which is exactly how a fabricated timestamp got shipped
    # as a deferral. What CAN be checked is that no code path in the
    # sampler assigns a sample's instant at all: every `sampled_at` in the
    # store is the `atUnixMillis` of a reading that was actually taken.
    check fileExists(ambientSource)
    let ambientText = readFile(ambientSource)
    check assignmentsTo(ambientText, "sampledAtUnixMillis") == 0
    # And `sampled_at` is populated ONLY by construction from a reading,
    # so the zero above is not zero because the field went missing.
    check "sampledAtUnixMillis: current.atUnixMillis" in ambientText

    # THE POSITIVE CONTROL. The same scanner, over a file that really does
    # assign the field -- this one: the clamp test moves a row's instant on
    # purpose to get a second primary key -- must find it. A scanner that
    # finds nothing anywhere agrees with every implementation.
    let selfText = readFile(currentSourcePath())
    check assignmentsTo(selfText, "sampledAtUnixMillis") >= 1
    # ... and it does not mistake this file's comparisons for assignments.
    check "check row.sampledAtUnixMillis == current.atUnixMillis" in selfText

  test "an unusable store or host leaves the sampler inactive":
    # OS-4 on this path too: ambient sampling is capture, and capture that
    # cannot run must not fail anything.
    stopAmbientSampler()
    startAmbientSampler("", "host-x")
    check not ambientSamplerActive()
    startAmbientSampler(getTempDir() / "nowhere.sqlite", "")
    check not ambientSamplerActive()
    stopAmbientSampler()

  test "io_queue_depth says 'not measured' rather than 'nothing queued'":
    # 0.0 is a legitimate measurement — an idle disk — so a platform with
    # no host-wide in-flight counter must not report it.
    check ioQueueDepthUnmeasured < 0.0
    let (previous, current) = pair(1_000_000, 8_000_000)
    check attributeAmbientSample("host-a", previous, current, [
        ]).ioQueueDepth ==
      ioQueueDepthUnmeasured
    var measured = current
    measured.ioQueueDepth = 0.0
    check attributeAmbientSample("host-a", previous, measured, [
        ]).ioQueueDepth ==
      0.0

  test "the daemon's sampling path performs no process-tree inspection":
    # The boundary this enforces, quoted from the policy file it lives in.
    # Pinning the sentence means deleting the boundary fails the test
    # rather than quietly retiring it.
    let boundary = readFile(boundaryFile)
    check "must not spawn, sandbox, monitor, or kill" in boundary
    check "client process trees" in boundary
    check "runquotad" in boundary

    check fileExists(ambientSource)
    check fileExists(daemonSource)
    check scannedFor(ambientSource, perProcessInterfaces).len == 0
    check scannedFor(daemonSource, perProcessInterfaces).len == 0

    # The sampler may name `/proc`, because `/proc/stat` and `/proc/meminfo`
    # describe the machine. It may not name a process's own directory, and
    # an allow-list is what makes that structural: `/proc/self/stat` and
    # `/proc/<pid>/stat` both fail it.
    let ambientText = readFile(ambientSource)
    var index = 0
    var procPaths = 0
    while true:
      let hit = ambientText.find("/proc/", index)
      if hit < 0:
        break
      var stop = hit + "/proc/".len
      while stop < ambientText.len and
          ambientText[stop] notin {'"', '\'', '`', ' ', '\n', ')', ','}:
        stop += 1
      let path = ambientText[hit ..< stop]
      check path in allowedProcPaths
      procPaths += 1
      index = stop
    # The Linux branch really does name some, so the loop above is not
    # vacuously satisfied by finding nothing.
    check procPaths >= 5

    # THE POSITIVE CONTROL. The same scanner, run over the client-side
    # helpers that DO walk process trees, must find them. Without this, a
    # scanner looking for tokens that no longer exist anywhere would agree
    # with a daemon that walked every process on the machine.
    check fileExists(macosTreeSource)
    check fileExists(linuxTreeSource)
    let macosHits = scannedFor(macosTreeSource, perProcessInterfaces)
    check macosHits.len >= 3
    check "proc_listpids" in macosHits
    check "proc_pidinfo" in macosHits
    let linuxHits = scannedFor(linuxTreeSource, perProcessInterfaces)
    check linuxHits.len >= 2
    check "processTreeRows" in linuxHits
