## The scheduled retention pass, deterministic half: what the sweeper does
## with a tick, a live lease, and a store that has stopped accepting
## writes.
##
## NO MOCKS. Every arm below drives the real sweeper thread against a real
## SQLite store on the real filesystem, through the real ``sqlite3`` the
## rest of the store uses. The lease count the idle gate reads is the real
## module-level one ``runquotad`` publishes; nothing here stands in for a
## daemon, and the half that needs one — a real ``runquotad``, a real
## socket, and a prune long enough to issue a request inside — is
## ``tests/integration/t_observation_retention_scheduled``.
##
## WHY THIS FILE EXISTS SEPARATELY. Four of the clauses below are REFUSALS
## or DEGRADATIONS: a sweep the operator turned off, a sweep with no host
## to attribute rows to, a sweep deferred because work is live, a sweep
## that could not run at all. The campaign's working conventions say a
## refusal asserted where it is convenient to reach is the defect that has
## shipped twelve-plus unfalsifiable checks — and the convenient place to
## reach these is from a running daemon, where none of them can be produced
## on demand. Here the lease count is set directly, the interval is
## milliseconds rather than an hour, and the store can be made unwritable
## between one tick and the next.
##
## EVERY ABSENCE ASSERTION HAS ITS PRESENCE ASSERTED FIRST. "No row past
## the bound remains" is satisfied trivially by a table that never had one,
## so every arm reads the seeded rows back before the sweeper is started.

import std/[options, os, strutils, times, unittest]

import runquota_daemon
import runquota_observation_store

const
  probeExtension = "m15s_unit_probe"

type
  SweepCounter = enum
    ## Which of the sweeper's published counters ``waitFor`` watches.
    scStarted
    scFinished
    scDeferred
    scForced
    scFailures
    scExecutionsRemoved

proc read(counter: SweepCounter): int64 =
  case counter
  of scStarted: retentionSweepsStarted()
  of scFinished: retentionSweepsFinished()
  of scDeferred: retentionSweepsDeferred()
  of scForced: retentionSweepsForced()
  of scFailures: retentionSweepFailures()
  of scExecutionsRemoved: retentionExecutionsRemoved()

proc waitFor(counter: SweepCounter; atLeast: int64; millis = 10_000): int64 =
  ## Polls until ``counter`` reaches ``atLeast``, and returns WHAT IT READ
  ## rather than whether it got there. A bounded loop that falls out
  ## quietly is how "the sweeper never ran" reads as green; the caller
  ## asserts on the number.
  let deadline = epochTime() + float(millis) / 1000.0
  result = counter.read()
  while result < atLeast and epochTime() < deadline:
    sleep(10)
    result = counter.read()

proc scratchDir(name: string): string =
  result = getTempDir() / ("rq-m15s-" & name & "-" &
    $getCurrentProcessId() & "-" & $int(epochTime() * 1000))
  removeDir(result)
  createDir(result)

proc extensionDdl(): string =
  "create table " & extensionTableName(probeExtension) & " (\n" &
  "  host_id text not null,\n" &
  "  execution_id text not null,\n" &
  "  probe_payload text not null,\n" &
  "  primary key (host_id, execution_id),\n" &
  "  foreign key (host_id, execution_id)\n" &
  "    references executions(host_id, execution_id)\n);"

proc executionInsert(id, hostId: string; startedAt: int64): string =
  "insert into executions (execution_id, host_id, host_profile_id, run_id, " &
  "command_stats_id, started_at_unix_millis, finished_at_unix_millis, " &
  "duration_millis, exit_status, termination, attempt, peak_rss_bytes, " &
  "max_processes, major_page_faults, capture_completeness) values (" &
  encodeText(id) & ", " & encodeText(hostId) & ", 'p', 'run-1', 'c', " &
  $startedAt & ", " & $(startedAt + 1) &
  ", 1, 0, 'exited', 1, 0, 1, 0, 'complete');\n"

proc seedStore(path, hostId: string; executions: int; firstStartedAt: int64;
               ambientFirstSampledAt = 0'i64; ambientSamples = 0) =
  ## One host, one profile, one run, ``executions`` executions one
  ## millisecond apart from ``firstStartedAt``, an extension row for every
  ## one of them, and optionally a run of ambient samples. Written through
  ## the library so the schema is the shipped one.
  let store = openObservationStore(path)
  doAssert store.captureEnabled, store.report
  doAssert store.insertHost(HostRow(hostId: hostId,
    createdAtUnixMillis: 1_000, lastBootId: "boot"))
  doAssert store.insertHostProfile(HostProfileRow(hostId: hostId,
    profileId: "p", profileHash: "sha256:p", validFromUnixMillis: 1_000,
    cpuModel: "synthetic", physicalCores: 4, logicalCores: 8,
    ramBytes: 1 shl 34, swapBytes: 0, diskClass: dcSsd, fsType: "apfs",
    arch: "arm64", os: "macos", osVersion: "15", kernelVersion: "24",
    virtualization: "none", cpuShareGroup: "default"))
  doAssert store.insertRun(RunRow(runId: "run-1", hostId: hostId,
    tool: "t", toolVersion: "v", invocationKind: "build",
    startedAtUnixMillis: 1_000, captureCompleteness: ccComplete))
  doAssert store.declareExtension(ExtensionDeclaration(
    extensionId: probeExtension, owner: "runquota-m15s", schemaVersion: 1,
    migrations: @[extensionDdl()])) == eoCreated

  var sql = "begin immediate;\n"
  for i in 0 ..< executions:
    let id = "exec-" & align($i, 6, '0')
    sql.add(executionInsert(id, hostId, firstStartedAt + int64(i)))
    sql.add("insert into " & extensionTableName(probeExtension) &
      " values (" & encodeText(hostId) & ", " & encodeText(id) & ", " &
      encodeText("payload-" & $i) & ");\n")
  for i in 0 ..< ambientSamples:
    sql.add("insert into ambient_samples (host_id, sampled_at_unix_millis, " &
      "cpu_busy_pct, mem_available_bytes, swap_in_rate, io_queue_depth, " &
      "load_avg_1m, self_cpu_pct, self_rss_bytes, foreign_cpu_pct, " &
      "foreign_rss_bytes) values (" & encodeText(hostId) & ", " &
      $(ambientFirstSampledAt + int64(i)) &
      ", 1.0, 1000, 0.0, -1.0, 0.5, 0.0, 0, 1.0, 0);\n")
  sql.add("commit;\n")
  doAssert store.runStatement(sql), store.lastError

proc executionCount(path: string): int =
  openObservationStore(path).readExecutions().len

proc ambientCount(path: string): int =
  openObservationStore(path).readAmbientSamples().len

proc quiesce() =
  ## Between arms: one sweeper per process, one lease count per process.
  stopRetentionSweeper()
  setAmbientLiveLeaseCount(0)

suite "observation_retention_schedule":

  # -------------------------------------------------------------------------
  # The shipped policy
  # -------------------------------------------------------------------------

  test "the shipped default bounds both tables on both axes":
    # BOTH AXES, BOTH TABLES. The specification says retention "MUST be
    # bounded by both age and row count"; a default that left either open
    # would be an unbounded store wearing a policy.
    let policy = defaultRetentionPolicy()
    check policy.maxExecutionAgeMillis.isSome
    check policy.maxExecutions.isSome
    check policy.maxAmbientSampleAgeMillis.isSome
    check policy.maxAmbientSamples.isSome
    check policy.maxExecutionAgeMillis.get > 0
    check policy.maxExecutions.get > 0
    check policy.maxAmbientSampleAgeMillis.get > 0
    check policy.maxAmbientSamples.get > 0
    # Ambient rows arrive a second at a time while work is live and the
    # spine arrives an execution at a time, so the ambient window is the
    # shorter of the two on purpose.
    check policy.maxAmbientSampleAgeMillis.get <
      policy.maxExecutionAgeMillis.get

  test "a daemon is configured to sweep without any flag":
    # THE WHOLE GAP THIS CLOSES, at the configuration boundary. M15 built
    # the bounds and nothing scheduled them; a default of zero here would
    # leave that true with more code in the tree.
    let config = defaultDaemonConfig()
    check config.retentionSweepIntervalMillis > 0
    check config.retentionMaxDeferredSweeps > 0
    check config.retentionPolicy == defaultRetentionPolicy()

  test "a bound turned off is spelled out rather than omitted":
    var policy = defaultRetentionPolicy()
    policy.maxExecutions = none(int64)
    let text = describe(policy)
    let ageClause = "max_execution_age_millis=" &
      $policy.maxExecutionAgeMillis.get
    check "max_executions=off" in text
    check ageClause in text
    # And "off" is not what a set bound prints, so an operator reading one
    # startup line can tell a disabled bound from a configured one.
    check not ("max_execution_age_millis=off" in text)

  # -------------------------------------------------------------------------
  # The pass runs on its own, and it removes what the bounds doom
  # -------------------------------------------------------------------------

  test "an idle host is swept, and the cascade goes with it":
    let dir = scratchDir("idle")
    defer:
      quiesce()
      removeDir(dir)
    let path = dir / "observations.sqlite"
    let host = "host-m15s-idle"
    let now = unixMillisNow()
    seedStore(path, host, 40, now - 40,
      ambientFirstSampledAt = now - 40, ambientSamples = 20)

    # THEY EXISTED FIRST. Without this every assertion below is satisfied
    # by a store that was never seeded.
    let before = openObservationStore(path)
    check before.readExecutions().len == 40
    check before.extensionRowCount(probeExtension) == 40
    check ambientCount(path) == 20
    check before.readHosts().len == 1
    check before.readHostProfiles().len == 1

    setAmbientLiveLeaseCount(0)
    startRetentionSweeper(path, host,
      RetentionPolicy(maxExecutionAgeMillis: none(int64),
        maxExecutions: some(10'i64),
        maxAmbientSampleAgeMillis: none(int64),
        maxAmbientSamples: some(5'i64)),
      intervalMillis = 40, maxDeferredSweeps = 4)
    check retentionSweeperActive()
    check waitFor(scFinished, 1) >= 1

    # NOBODY ASKED FOR THIS PASS. No client called and no request arrived;
    # a tick fired and the bounds were enforced.
    check retentionSweepsStarted() >= 1
    check retentionSweepFailures() == 0
    check retentionExecutionsRemoved() == 30
    check retentionExtensionRowsRemoved() == 30
    check retentionAmbientSamplesRemoved() == 15

    let after = openObservationStore(path)
    let kept = after.readExecutions()
    check kept.len == 10
    # The NEWEST ten, named rather than counted: a bound that kept the
    # wrong end of the table satisfies a count and destroys the store's
    # whole purpose.
    check kept[0].executionId == "exec-000030"
    check kept[^1].executionId == "exec-000039"
    check after.extensionRowCount(probeExtension) == 10
    check ambientCount(path) == 5
    # AND THE HARDWARE DIMENSION SURVIVED IT. A pruned history that
    # orphaned its hardware context would be durations pooled across
    # unknown machines.
    check after.readHosts().len == 1
    check after.readHostProfiles().len == 1
    let orphanage = after.orphanReport()
    check orphanage.checked
    check orphanage.orphans == 0

  test "the age bound is enforced by the same scheduled pass":
    let dir = scratchDir("age")
    defer:
      quiesce()
      removeDir(dir)
    let path = dir / "observations.sqlite"
    let host = "host-m15s-age"
    let now = unixMillisNow()
    # Twenty rows an hour old, then twenty from this millisecond.
    seedStore(path, host, 20, now - 3_600_000)
    block:
      let store = openObservationStore(path)
      var sql = "begin immediate;\n"
      for i in 20 ..< 40:
        sql.add(executionInsert("exec-" & align($i, 6, '0'), host,
          now + int64(i)))
      sql.add("commit;\n")
      doAssert store.runStatement(sql), store.lastError
    check executionCount(path) == 40

    setAmbientLiveLeaseCount(0)
    startRetentionSweeper(path, host,
      RetentionPolicy(maxExecutionAgeMillis: some(60_000'i64),
        maxExecutions: none(int64),
        maxAmbientSampleAgeMillis: none(int64),
        maxAmbientSamples: none(int64)),
      intervalMillis = 40, maxDeferredSweeps = 4)
    check waitFor(scFinished, 1) >= 1
    check retentionExecutionsRemoved() == 20
    let kept = openObservationStore(path).readExecutions()
    check kept.len == 20
    check kept[0].executionId == "exec-000020"

  # -------------------------------------------------------------------------
  # REFUSAL: nothing to sweep for, or nobody asking
  # -------------------------------------------------------------------------

  test "a non-positive interval leaves the sweeper inactive and the rows alone":
    let dir = scratchDir("off")
    defer:
      quiesce()
      removeDir(dir)
    let path = dir / "observations.sqlite"
    let host = "host-m15s-off"
    seedStore(path, host, 30, unixMillisNow() - 30)
    check executionCount(path) == 30

    setAmbientLiveLeaseCount(0)
    startRetentionSweeper(path, host,
      RetentionPolicy(maxExecutionAgeMillis: none(int64),
        maxExecutions: some(1'i64),
        maxAmbientSampleAgeMillis: none(int64),
        maxAmbientSamples: none(int64)),
      intervalMillis = 0, maxDeferredSweeps = 4)
    # NOT MERELY "no rows were removed": no thread and no ticks. A sweeper
    # that started and then declined to sweep would satisfy a row count
    # and still be a thread nobody asked for.
    check not retentionSweeperActive()
    sleep(300)
    check retentionSweepsStarted() == 0
    check executionCount(path) == 30

  test "an unidentified host is not swept, because no host owns the rows":
    let dir = scratchDir("nohost")
    defer:
      quiesce()
      removeDir(dir)
    let path = dir / "observations.sqlite"
    seedStore(path, "host-m15s-nohost", 12, unixMillisNow() - 12)
    check executionCount(path) == 12

    setAmbientLiveLeaseCount(0)
    # An empty host id is what `runquotad` holds when the identity could
    # not be persisted, and `applyRetention` refuses one. A thread started
    # to be refused every hour is a thread that does nothing.
    startRetentionSweeper(path, "", defaultRetentionPolicy(),
      intervalMillis = 40, maxDeferredSweeps = 4)
    check not retentionSweeperActive()
    sleep(200)
    check retentionSweepsStarted() == 0
    check executionCount(path) == 12

  # -------------------------------------------------------------------------
  # The idle preference, and the ceiling that keeps it from being a wish
  # -------------------------------------------------------------------------

  test "a live lease defers the sweep, and releasing it ends the deferral":
    let dir = scratchDir("busy")
    defer:
      quiesce()
      removeDir(dir)
    let path = dir / "observations.sqlite"
    let host = "host-m15s-busy"
    seedStore(path, host, 30, unixMillisNow() - 30)
    check executionCount(path) == 30

    # WORK IS LIVE. This is the number the lease authority publishes on
    # every grant and every release.
    setAmbientLiveLeaseCount(2)
    startRetentionSweeper(path, host,
      RetentionPolicy(maxExecutionAgeMillis: none(int64),
        maxExecutions: some(1'i64),
        maxAmbientSampleAgeMillis: none(int64),
        maxAmbientSamples: none(int64)),
      intervalMillis = 30, maxDeferredSweeps = 1_000_000)
    check retentionSweeperActive()
    check waitFor(scDeferred, 5) >= 5

    # DEFERRED, NOT MERELY SLOW: no pass started, and the rows are all
    # still there.
    check retentionSweepsStarted() == 0
    check retentionSweepsForced() == 0
    check executionCount(path) == 30

    # AND THE DEFERRAL ENDS WHEN THE WORK DOES. Without this the arm above
    # is satisfied by a sweeper that never sweeps at all.
    setAmbientLiveLeaseCount(0)
    check waitFor(scFinished, 1) >= 1
    check executionCount(path) == 1

  test "deferring has a ceiling, and a permanently busy host is still bounded":
    let dir = scratchDir("forced")
    defer:
      quiesce()
      removeDir(dir)
    let path = dir / "observations.sqlite"
    let host = "host-m15s-forced"
    seedStore(path, host, 30, unixMillisNow() - 30)
    check executionCount(path) == 30

    # THE MACHINE NEVER GOES IDLE. This is the case "prune only when idle"
    # cannot handle, and it is not exotic: a build farm is the machine
    # with the most history to bound and the least idle time to bound it
    # in.
    setAmbientLiveLeaseCount(1)
    startRetentionSweeper(path, host,
      RetentionPolicy(maxExecutionAgeMillis: none(int64),
        maxExecutions: some(4'i64),
        maxAmbientSampleAgeMillis: none(int64),
        maxAmbientSamples: none(int64)),
      intervalMillis = 30, maxDeferredSweeps = 3)
    check waitFor(scFinished, 1) >= 1

    # THE DEFERRAL HAPPENED, AND THEN IT STOPPED. Both halves: a sweeper
    # that ignored the lease count entirely would satisfy the row
    # assertion below and fail this one.
    check retentionSweepsDeferred() >= 3
    check retentionSweepsForced() >= 1
    check executionCount(path) == 4
    # The lease never went away, so the sweep that ran was a forced one.
    check ambientLiveLeaseCount() == 1

  # -------------------------------------------------------------------------
  # DEGRADATION: a store that stops accepting writes
  # -------------------------------------------------------------------------

  test "a pass that cannot run is counted, and the sweeper keeps its cadence":
    let dir = scratchDir("ro")
    let path = dir / "observations.sqlite"
    defer:
      quiesce()
      setFilePermissions(dir, {fpUserRead, fpUserWrite, fpUserExec})
      for suffix in ["", "-wal", "-shm"]:
        if fileExists(path & suffix):
          setFilePermissions(path & suffix, {fpUserRead, fpUserWrite})
      removeDir(dir)
    let host = "host-m15s-ro"
    seedStore(path, host, 40, unixMillisNow() - 40)
    check executionCount(path) == 40

    # THE STORE STOPS ACCEPTING WRITES BEFORE THE FIRST TICK. Read-only on
    # the database, its log and the directory holding them: a full disk's
    # symptom without needing a full disk.
    for suffix in ["", "-wal", "-shm"]:
      if fileExists(path & suffix):
        setFilePermissions(path & suffix, {fpUserRead})
    setFilePermissions(dir, {fpUserRead, fpUserExec})

    setAmbientLiveLeaseCount(0)
    startRetentionSweeper(path, host,
      RetentionPolicy(maxExecutionAgeMillis: none(int64),
        maxExecutions: some(5'i64),
        maxAmbientSampleAgeMillis: none(int64),
        maxAmbientSamples: none(int64)),
      intervalMillis = 30, maxDeferredSweeps = 4)
    check waitFor(scFailures, 1) >= 1

    # COUNTED, WITH A REASON, AND NOTHING RAISED. OS-4: a store that
    # cannot be pruned degrades to no pruning; it may not fail anything.
    check retentionLastDetail().len > 0
    check retentionExecutionsRemoved() == 0
    # AND THE SWEEPER IS STILL THERE. A thread that died on the first
    # failure would leave a daemon that silently stopped bounding its
    # store — the exact state this whole change exists to end.
    let failuresSoFar = retentionSweepFailures()
    check waitFor(scFailures, failuresSoFar + 1) > failuresSoFar

    # AND IT RECOVERS. A transient full disk must not silence retention
    # for the daemon's whole life, so the handle is reopened rather than
    # left in the state a failed write put it in.
    setFilePermissions(dir, {fpUserRead, fpUserWrite, fpUserExec})
    for suffix in ["", "-wal", "-shm"]:
      if fileExists(path & suffix):
        setFilePermissions(path & suffix, {fpUserRead, fpUserWrite})
    check waitFor(scExecutionsRemoved, 1) >= 1
    check executionCount(path) == 5
