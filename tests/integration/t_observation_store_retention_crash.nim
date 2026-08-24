## M15 gate, the clause M12 could not make: **pruning is crash-safe —
## killed mid-prune leaves a consistent store.**
##
## M12 asserted "a prune that cannot finish removes nothing" with an
## INDUCED CONSTRAINT FAILURE, and its own record says plainly that this is
## atomicity rather than crash recovery. It also records the sharper
## lesson: the first version of that check placed the obstruction where
## ``sqlite3 -bail`` made it moot, so "nothing moved" was a statement about
## a command-line flag. A failure the code returns from is not a crash, and
## a kill that lands outside the window measures nothing.
##
## SO THIS FILE KILLS A REAL PROCESS GROUP WITH A REAL SIGNAL, AND PROVES
## THE SIGNAL LANDED INSIDE THE WINDOW BEFORE IT SENDS IT.
##
## * The prune runs in a SEPARATE PROCESS — this binary, re-executed in a
##   prune role. It makes itself a process-group leader with ``setpgid``,
##   so the ``sqlite3`` child that actually executes the batch is in the
##   same group and ``kill(-pgid, SIGKILL)`` takes both. Killing only the
##   Nim process would leave the child to commit, which is not a crash; and
##   a surviving child would be a process this suite leaked.
## * The kill is triggered by TWO OBSERVATIONS OF THE OPEN TRANSACTION,
##   not by a sleep. The write-ahead log is truncated to zero before the
##   prune starts, so any growth is pages the prune's own transaction has
##   written — that is the partial work. And a second connection is refused
##   ``begin immediate``, which is only true while the transaction is open.
##   Both are recorded in the output, so a reader can see where the signal
##   landed rather than take it on trust.
## * The uninterrupted pass is MEASURED FIRST, on a twin store, so the
##   point the kill aims at is three quarters of a known quantity rather
##   than a hope. The measurement is a reading and not a sample: see
##   ``startWalPin``, and the eleven-in-sixty-two false failures that
##   sampling produced.
##
## WHAT "CONSISTENT" IS ASSERTED TO MEAN, precisely: the store reopens
## (SQLite's own recovery ran and did not report corruption), every
## extension row and carried row still has the execution it belongs to, and
## the pass is ALL OR NOTHING — the doomed executions and their extension
## rows are either all present or all gone, never half. The middle state is
## what a prune without one transaction produces, and it is the state this
## test exists to forbid.
##
## TWO LEGS, AND THEY ARE NOT REDUNDANT. The kill leg says a killed pass
## leaves a whole state; the isolation leg says no other connection ever
## SEES a half-done one while the pass runs. The second is deterministic
## and the first depends on where the signal lands, so the second is what
## makes the first's aim checkable — but a calibration that quietly left
## only the isolation leg discriminating would have traded one defect for
## another, so both are measured against the mutation that removes the
## transaction: 20 of 20 runs, both legs, every run.
##
## NO MOCKS. A real store, a real ``sqlite3``, a real ``SIGKILL``.

import std/[os, osproc, posix, streams, strutils, times, unittest]

import runquota_observation_store

const
  RoleEnv = "RUNQUOTA_M15_PRUNE_ROLE"
  ReadyEnv = "RUNQUOTA_M15_PRUNE_READY"
  crashHost = "host-m15c"
  # Enough rows that the delete has a middle. The figures are asserted
  # against the measured duration below rather than assumed to be enough.
  seededExecutions = 15_000
  keptExecutions = 100
  extensionCount = 3

proc extensionId(index: int): string = "m15c_probe" & $index

proc extensionDdl(index: int): string =
  "create table " & extensionTableName(extensionId(index)) & " (\n" &
  "  host_id text not null,\n" &
  "  execution_id text not null,\n" &
  "  probe_payload text not null,\n" &
  "  primary key (host_id, execution_id),\n" &
  "  foreign key (host_id, execution_id)\n" &
  "    references executions(host_id, execution_id)\n);"

proc declaration(index: int): ExtensionDeclaration =
  ExtensionDeclaration(extensionId: extensionId(index),
    owner: "runquota-m15", schemaVersion: 1,
    migrations: @[extensionDdl(index)])

# ---------------------------------------------------------------------------
# The prune role
# ---------------------------------------------------------------------------

proc runPruneRole(dbPath, readyPath: string) =
  # A GROUP OF ITS OWN, so the `sqlite3` child that executes the batch dies
  # with this process rather than outliving it and committing. Without
  # this, "killed mid-prune" would be "the caller died and the prune
  # finished anyway".
  discard setpgid(0, 0)
  let store = openObservationStore(dbPath)
  doAssert store.captureEnabled, store.report
  writeFile(readyPath, $getCurrentProcessId() & "\n")
  discard store.pruneExecutions(crashHost, beyondNewest(keptExecutions))
  # Only reached if the kill never arrived. The parent asserts against this
  # file, so a window that was missed is visible rather than silent.
  writeFile(readyPath & ".finished", "finished\n")

when isMainModule:
  let rolePath = getEnv(RoleEnv)
  if rolePath.len > 0:
    runPruneRole(rolePath, getEnv(ReadyEnv))
    quit 0

# ---------------------------------------------------------------------------
# Fixture
# ---------------------------------------------------------------------------

proc scratchDir(name: string): string =
  result = getTempDir() / ("rq-m15c-" & name & "-" &
    $getCurrentProcessId() & "-" & $epochTime())
  removeDir(result)
  createDir(result)

proc seedStore(path: string) =
  ## One host, one profile, one run, ``seededExecutions`` executions, and a
  ## row in each of ``extensionCount`` extension tables for every one of
  ## them. Written through the library so the schema is the shipped one,
  ## then filled with one SQL batch because 16,000 individual inserts
  ## through the CLI would dominate the test.
  let store = openObservationStore(path)
  doAssert store.captureEnabled, store.report
  doAssert store.insertHost(HostRow(hostId: crashHost,
    createdAtUnixMillis: 1_000, lastBootId: "boot"))
  doAssert store.insertHostProfile(HostProfileRow(hostId: crashHost,
    profileId: "p", profileHash: "sha256:p", validFromUnixMillis: 1_000,
    cpuModel: "synthetic", physicalCores: 4, logicalCores: 8,
    ramBytes: 1 shl 34, swapBytes: 0, diskClass: dcSsd, fsType: "apfs",
    arch: "arm64", os: "macos", osVersion: "15", kernelVersion: "24",
    virtualization: "none", cpuShareGroup: "default"))
  doAssert store.insertRun(RunRow(runId: "run-1", hostId: crashHost,
    tool: "t", toolVersion: "v", invocationKind: "build",
    startedAtUnixMillis: 1_000, captureCompleteness: ccComplete))
  for index in 0 ..< extensionCount:
    doAssert store.declareExtension(declaration(index)) == eoCreated

  var sql = "begin immediate;\n"
  for i in 1 .. seededExecutions:
    let id = "exec-" & align($i, 6, '0')
    sql.add("insert into executions (execution_id, host_id, host_profile_id," &
      " run_id, command_stats_id, started_at_unix_millis, " &
      "finished_at_unix_millis, duration_millis, exit_status, termination, " &
      "attempt, peak_rss_bytes, max_processes, major_page_faults, " &
      "capture_completeness) values (" & encodeText(id) & ", " &
      encodeText(crashHost) & ", 'p', 'run-1', 'c', " & $i & ", " & $(i + 1) &
      ", 1, 0, 'exited', 1, 0, 1, 0, 'complete');\n")
    for index in 0 ..< extensionCount:
      sql.add("insert into " & extensionTableName(extensionId(index)) &
        " values (" & encodeText(crashHost) & ", " & encodeText(id) & ", " &
        encodeText("payload-" & $index & "-" & $i) & ");\n")
  sql.add("commit;\n")
  doAssert store.runStatement(sql), store.lastError

proc counts(path: string): seq[int64] =
  let store = openObservationStore(path)
  doAssert store.captureEnabled, store.report
  result.add(int64(store.readExecutions().len))
  for index in 0 ..< extensionCount:
    result.add(store.extensionRowCount(extensionId(index)))

proc snapshotCounts(path: string): seq[int64] =
  ## The same four figures as ``counts``, read by ONE other connection in
  ## ONE statement, so the answer describes a single instant. A reader in
  ## WAL mode is never blocked by a writer, so this can be asked while the
  ## prune holds the write lock — which is the whole point of asking it.
  var parts = @["(select count(*) from executions)"]
  for index in 0 ..< extensionCount:
    parts.add("(select count(*) from " &
      extensionTableName(extensionId(index)) & ")")
  let outcome = runSqlite(path,
    "select " & parts.join(" || '|' || ") & ";")
  if not outcome.ok:
    return @[]
  for field in outcome.output.strip().split('|'):
    try:
      result.add(parseBiggestInt(field.strip()))
    except ValueError:
      return @[]

proc walBytes(path: string): int64 =
  let wal = path & "-wal"
  if not fileExists(wal): 0'i64 else: getFileSize(wal)

proc writeLocked(path: string): bool =
  ## Whether somebody else holds a write transaction on ``path`` RIGHT NOW.
  ## ``.timeout 0`` so the probe reports the state instead of waiting for it
  ## to pass.
  let outcome = execCmdEx("sqlite3 -batch -bail -cmd '.timeout 0' " &
    quoteShell(path) & " 'begin immediate; rollback;' 2>&1")
  outcome.exitCode != 0 and "locked" in outcome.output.toLowerAscii

proc startWalPin(path: string): Process =
  ## A reader holding an open snapshot, and the reason the measurement
  ## below is a reading rather than a race.
  ##
  ## THE FIRST VERSION OF THIS TEST SAMPLED THE LOG'S SIZE IN A POLL LOOP
  ## AND THAT DOES NOT WORK. SQLite keeps a transaction's dirty pages in
  ## its page cache and can spill the lot into the log in ONE BURST at
  ## commit, and the log is then checkpointed and truncated the moment the
  ## writing process exits. A sampler is looking at a file that is empty,
  ## then briefly several megabytes, then empty again — and whether it sees
  ## the middle state is luck. Measured: eleven of sixty-two idle runs read
  ## a "peak" of 0 or 32 bytes, which collapsed the kill threshold to
  ## nothing and put the kill exactly where the calibration existed to
  ## prevent it.
  ##
  ## A reader holding a snapshot removes the race instead of narrowing it.
  ## A checkpoint may only copy frames older than the oldest reader's mark,
  ## so with this process alive the log CANNOT be truncated: the writer's
  ## whole transaction stays in it, and its size can be read at leisure
  ## after the pass has finished. Readers never block writers in WAL mode,
  ## so pinning costs the pass nothing.
  ##
  ## It also makes the two runs comparable, which matters for the mutation
  ## this test exists to catch. Without a pin, a pass built out of separate
  ## statements auto-checkpoints as each one commits and its log keeps
  ## resetting; with one, both the calibration run and the killed run
  ## accumulate monotonically and the threshold means the same thing in
  ## both.
  result = startProcess(sqliteTool, args = ["-batch", path],
    options = {poUsePath, poStdErrToStdOut})
  result.inputStream.write("begin;\nselect count(*) from executions;\n")
  result.inputStream.flush()
  # The snapshot is taken by the first read, not by `begin`. Wait for it,
  # or the pin is not yet a pin.
  sleep(300)

proc stopWalPin(pin: Process) =
  if pin.running:
    pin.terminate()
    discard pin.waitForExit(5000)
  if pin.running:
    pin.kill()
    discard pin.waitForExit(5000)
  pin.close()

type Calibration = object
  ## What one uninterrupted pass on a twin store says about the pass the
  ## next phase is going to interrupt.
  walTotal: int64
  windowMillis: int
  observations: int
  partialSeen: seq[int64]
  finished: bool
  twinPath: string
  endState: seq[int64]

proc calibrate(dir: string; attempt: int;
               seededState, prunedState: seq[int64]): Calibration =
  ## Runs the prune to completion in the same role process, with the log
  ## pinned so its total size can be READ afterwards rather than caught in
  ## flight, and samples the store from a second connection throughout.
  result = Calibration(walTotal: -1, windowMillis: 0, observations: 0,
                       partialSeen: @[], finished: false, twinPath: "",
                       endState: @[])
  let twin = dir / ("twin-" & $attempt & ".sqlite")
  result.twinPath = twin
  seedStore(twin)
  doAssert counts(twin) == seededState
  doAssert runSqlite(twin, "pragma wal_checkpoint(truncate);").ok
  doAssert walBytes(twin) == 0

  # Pinned only AFTER the log has been truncated, so what it holds open is
  # an empty one and every byte measured below belongs to the prune.
  let pin = startWalPin(twin)
  let ready = dir / ("twin-ready-" & $attempt)
  putEnv(RoleEnv, twin)
  putEnv(ReadyEnv, ready)
  let role = startProcess(getAppFilename(), options = {poStdErrToStdOut})
  delEnv(RoleEnv)
  delEnv(ReadyEnv)

  let startedAt = epochTime()
  while role.running:
    # ISOLATION, WHICH IS THE ONE-TRANSACTION PROPERTY OBSERVED FROM
    # OUTSIDE. A pass built out of separate statements publishes each
    # delete as it commits, so another connection sees an extension table
    # already emptied while its executions are still there. One transaction
    # publishes nothing until the end, so every sample is one of exactly
    # two whole states. This sampler spawns a process per sample and is
    # therefore slow — which is why the log is no longer measured here.
    let snapshot = snapshotCounts(twin)
    if snapshot.len == 1 + extensionCount:
      result.observations += 1
      if snapshot != seededState and snapshot != prunedState:
        result.partialSeen = snapshot
  discard role.waitForExit(30_000)
  role.close()
  result.windowMillis = int((epochTime() - startedAt) * 1000.0)
  result.finished = fileExists(ready & ".finished")
  # THE MEASUREMENT, taken after the pass and with the log still pinned. No
  # sampling, no race: this is the size of what the pass wrote.
  result.walTotal = walBytes(twin)
  stopWalPin(pin)
  result.endState = counts(twin)

suite "observation_store_retention_crash":

  test "a prune killed mid-pass leaves a consistent store":
    let dir = scratchDir("kill")
    defer: removeDir(dir)

    # ------------------------------------------------------------------
    # CALIBRATION: an uninterrupted pass on a twin store, measured
    # ------------------------------------------------------------------
    #
    # THE POINT OF THIS PHASE IS THE NUMBER IT PRODUCES, and that number is
    # what keeps this test from repeating M12's mistake. Killing as soon as
    # the transaction has written *anything* lands inside the FIRST
    # statement of the batch — and a prune built out of separate statements
    # rolls that one statement back too, so "nothing moved" would hold for
    # a reason that has nothing to do with the pass being one transaction.
    # The kill therefore has to land LATE: past the point where a
    # statement-at-a-time implementation would already have committed
    # several deletes. "Late" is only meaningful against a measured total,
    # so the total is measured here, on a twin store, by running the same
    # role process to completion with its log pinned open.

    # The two whole states this pass may ever be observed in. Anything else
    # is a half-done cascade.
    var seededState: seq[int64] = @[]
    var prunedState: seq[int64] = @[]
    for _ in 0 .. extensionCount:
      seededState.add(int64(seededExecutions))
      prunedState.add(int64(keptExecutions))

    # 14,900 executions and 44,700 extension rows cannot be deleted through
    # less than this much log. A reading below it is not a fast pass, it is
    # a MEASUREMENT THAT MISSED — and an implausible measurement is one to
    # retake rather than one to fail on, so the calibration is repeated
    # before anything is asserted about it.
    const plausibleWal = 2 * 1024 * 1024
    var calibration: Calibration
    for attempt in 1 .. 3:
      calibration = calibrate(dir, attempt, seededState, prunedState)
      echo "  calibration " & $attempt & ": " & $calibration.windowMillis &
        " ms, log total " & $calibration.walTotal & " bytes, " &
        $calibration.observations & " isolation samples, partial states: " &
        (if calibration.partialSeen.len == 0: "none"
         else: $calibration.partialSeen)
      if calibration.walTotal >= plausibleWal:
        break

    check calibration.finished
    check calibration.endState == prunedState
    # A window nobody can aim at is not a window; a log nobody can measure
    # is not a measurement. Both are assertions so a future host on which
    # either stops holding reports that rather than quietly testing nothing.
    check calibration.windowMillis >= 50
    check calibration.walTotal >= plausibleWal
    # Enough samples that "none" is a finding rather than an absence of
    # looking.
    check calibration.observations >= 5
    check calibration.partialSeen.len == 0

    # AND THE OBSERVER CAN SEE ONE, which is what makes the line above
    # evidence. A single delete against one extension table puts the store
    # in exactly the shape a half-done cascade would leave it in, and the
    # same sampler reports it.
    let store = openObservationStore(calibration.twinPath)
    check store.captureEnabled
    check store.runStatement("delete from " &
      extensionTableName(extensionId(0)) & ";")
    let partialProbe = snapshotCounts(calibration.twinPath)
    check partialProbe.len == 1 + extensionCount
    check partialProbe != seededState
    check partialProbe != prunedState

    # Three quarters of the way through the work. With the pass as one
    # transaction nothing has committed at that point; with one statement
    # at a time, most of the cascade has.
    let killThreshold = (calibration.walTotal * 3) div 4

    # ------------------------------------------------------------------
    # The killed pass
    # ------------------------------------------------------------------
    let path = dir / "observations.sqlite"
    seedStore(path)
    let before = counts(path)
    check before[0] == seededExecutions
    # THE WAL IS TRUNCATED FIRST, so every byte of growth below belongs to
    # the prune's own transaction and to nothing that came before it.
    check runSqlite(path, "pragma wal_checkpoint(truncate);").ok
    check walBytes(path) == 0
    # PINNED HERE TOO, so the threshold measured above means the same thing
    # in this run as it did in that one. Without a pin a statement-at-a-time
    # prune auto-checkpoints as each delete commits and its log keeps
    # resetting, so it could never reach a threshold derived from a
    # monotonically growing one — the mutation would be caught by the wrong
    # assertion, and the kill leg would be measuring the checkpointer.
    let pin = startWalPin(path)

    let ready = dir / "ready"
    putEnv(RoleEnv, path)
    putEnv(ReadyEnv, ready)
    let role = startProcess(getAppFilename(), options = {poStdErrToStdOut})
    delEnv(RoleEnv)
    delEnv(ReadyEnv)

    var rolePid = 0
    for _ in 0 ..< 4_000:
      if fileExists(ready):
        rolePid = parseInt(readFile(ready).strip())
        break
      sleep(1)
    check rolePid > 0

    # THE TRIGGER, AND IT IS THE OPEN TRANSACTION ITSELF. A second
    # connection asking for `begin immediate` with no timeout is refused
    # exactly while the prune holds the write lock — before it, and after
    # it commits, the probe succeeds. The write-ahead log's size is read
    # immediately before each probe and reports how much work that
    # transaction had already done, which is what makes this the MIDDLE of
    # the pass rather than its edge.
    var observedWal = 0'i64
    var locked = false
    var probes = 0
    for _ in 0 ..< 4_000:
      probes += 1
      if writeLocked(path):
        locked = true
        break
      if not role.running:
        break
    check locked
    # THE SECOND HALF OF THE TRIGGER, AND THE ONE THAT DECIDES THIS TEST.
    # A transaction that has only just opened has written nothing, and
    # killing there tests the same "nothing had happened yet" edge M12's
    # obstruction sat on — a pass built out of separate statements would
    # have its one in-flight statement rolled back too, and would pass.
    # So the kill waits until the log holds three quarters of what the
    # whole pass produces, measured above. Past that point a
    # statement-at-a-time implementation has committed most of the cascade
    # and the store is visibly half-pruned; one transaction has committed
    # nothing.
    for _ in 0 ..< 5_000_000:
      observedWal = walBytes(path)
      if observedWal >= killThreshold:
        break
    echo "  kill trigger: writeLocked after " & $probes & " probe(s), wal=" &
      $observedWal & " of " & $killThreshold & " target bytes"
    check observedWal >= killThreshold

    # THE WHOLE GROUP, so the `sqlite3` child executing the batch dies with
    # its caller instead of committing after it.
    check kill(Pid(-rolePid), SIGKILL) == 0
    discard role.waitForExit(10_000)
    check not role.running
    role.close()
    # The role never reached the end of the prune, which is what "the kill
    # landed inside" means from the other side.
    check not fileExists(ready & ".finished")
    # And nothing of it is left running.
    check execCmdEx("pgrep -g " & $rolePid & " 2>/dev/null || true").
      output.strip().len == 0
    # The pin has done its job; released before the store is reopened so
    # what follows is a reader like any other.
    stopWalPin(pin)

    # ------------------------------------------------------------------
    # What the store looks like afterwards
    # ------------------------------------------------------------------
    let reopened = openObservationStore(path)
    check reopened.status == ssOpen
    check reopened.captureEnabled
    let integrity = runSqlite(path, "pragma integrity_check;")
    check integrity.ok
    check integrity.output.strip() == "ok"

    let after = counts(path)
    echo "  after the kill: executions=" & $after[0] & " extension rows=" &
      $after[1] & "/" & $after[2] & "/" & $after[3]

    # ALL OR NOTHING. The middle state — some extension rows gone while
    # their executions remain, or executions gone while their rows remain —
    # is what a pass built out of separate statements produces, and it is
    # the state this assertion forbids.
    let intact = after == before
    var pruned: seq[int64] = @[int64(keptExecutions)]
    for _ in 0 ..< extensionCount:
      pruned.add(int64(keptExecutions))
    check intact or after == pruned
    echo "  outcome: " & (if intact: "rolled back whole"
                          else: "committed whole")

    # NOTHING IS ORPHANED either way, asserted as a join rather than as a
    # count that happens to agree.
    let orphanage = reopened.orphanReport()
    check orphanage.checked
    check orphanage.orphans == 0

    # AND THE STORE STILL WORKS: the same prune, run again, completes and
    # leaves exactly the rows retention was asked to keep. Without this the
    # arms above are satisfied by a database nobody can use.
    let again = reopened.pruneExecutions(crashHost,
      beyondNewest(keptExecutions))
    check again.pruned
    check counts(path) == pruned
    check reopened.orphanReport().orphans == 0
    check reopened.captureEnabled
