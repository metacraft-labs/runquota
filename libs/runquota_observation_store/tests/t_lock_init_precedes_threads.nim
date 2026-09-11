## The observation store's process-wide locks must be armed before any
## thread exists, not on first use.
##
## THE HAZARD THIS PINS. `writer.nim` and `ambient.nim` each used to arm
## their `Lock` (and, in the writer's case, a `Cond` beside it) from an
## `ensure...Lock()` proc guarded by a plain `bool`. Two threads reaching
## that guard before anybody had armed the module would BOTH run `initLock`,
## and the loser's lock would be the one every later caller failed to take.
## The doc comment that stood there argued the daemon was safe for a
## lifecycle reason -- `startObservationWriter` runs on the main thread
## before a connection worker exists.
##
## IT DID NOT COVER THE CAPTURE-DISABLED PATHS. `initDaemon` calls
## `startObservationWriter` and `startAmbientSampler` only in the arm it
## takes when the store has a host identity AND `ensureHostRow` succeeds;
## the sampler additionally needs a positive sample interval. In every other
## configuration neither is ever called, and the first touch of these modules
## comes from a CONNECTION WORKER, of which the daemon starts several.
##
## WHICH DOOR, EXACTLY. Not the enqueues: `openObservationRun` and its
## siblings all return early on `observationCaptureEnabled`. It is the
## ungated read side -- `statsAnswer`'s unconditional
## `flushObservationWriter`, and the status JSON's unconditional
## `observationWriterFlushes` / `observationsWritten` / `observationsDropped`
## / `observationWriteFailures` -- plus, for the sampler,
## `setAmbientLiveLeaseCount` on every lease add and release and
## `reportSelfExecution` on every client self-report, none of which consults
## capture at all.
##
## WHAT THIS FILE DRIVES IS THAT CONFIGURATION, and nothing else: it never
## calls `startObservationWriter` or `startAmbientSampler`, so every touch
## below is a first touch from a thread. It is a HAZARD-REMOVAL pin rather
## than a red-then-green: the defect was a `initLock`-on-a-live-mutex window,
## which is undefined behaviour and not a deterministic failure. What the
## writer's and the sampler's clauses can and do detect is the hazard's
## observable shadow -- a counter incremented under two DIFFERENT locks loses
## updates -- so those are exact counts rather than "greater than zero".
## Retention has no such shadow, for the reason given below, and does not
## pretend to one.
##
## `retention.nim` IS THE THIRD MODULE HERE, and the one whose guard was very
## nearly kept. The argument written over it said the module had three
## lifecycle entry points on the main thread and published no counter a status
## query reads. Both halves were false: the `sweeperReader` template defines
## THIRTEEN exported readers, `retentionJson` calls every one of them from
## `observationsJson`, and `inspect observations` reaches that with no capture
## gate at all -- on a connection worker, of which the daemon starts several.
## The sweeper is in fact gated MORE tightly than the writer was
## (`startRetentionSweeper` needs the `ensureHostRow` arm AND a positive sweep
## interval), so the set of configurations whose first touch is concurrent is
## wider there, not narrower.
##
## RETENTION'S CONCURRENT SURFACE IS READ-ONLY, and that is said plainly
## rather than dressed up: nothing a connection worker can reach increments a
## sweeper counter, so there is no lost-update shadow to count here as there
## is for the writer and the sampler. The first retention clause below
## therefore pins the CONFIGURATION -- thirty-two threads, every one of them
## this module's first touch, through exactly the reader set `retentionJson`
## uses -- and the second exists so that its readings are readings: it drives
## the sweeper against a path it cannot open and watches the same counters
## move. Without that second clause "every counter is zero" would be satisfied
## by a reader that returned a constant.
##
## THE DAEMON'S FOURTH GUARD, `ensurePublicationLock`, is driven the same way
## by `libs/runquota_daemon/tests/t_publication_queue_ownership.nim`, whose
## first statement creates 64 threads that all call `notePendingKey`; it is
## not repeated here because module state is per process and that test
## already owns the shape.
##
## PROVEN ABLE TO FAIL, because a lock test that cannot go red is worth
## nothing. The retention clauses were run against four mutations of
## `retention.nim`, each reverted afterwards; all four turned this binary red
## and none was silently absorbed:
##
##   * `sweeperStarted` initialised to 1 rather than 0 -> the toucher's
##     `doAssert` aborts the process (exit 1), which is also the check that
##     `doAssert` and not `check` was the right tool in a helper proc;
##   * `sweeperStarted += 1` deleted from `sweepOnce` -> `[FAILED] ... those
##     zeroes are a reading`;
##   * `sweeperFailures += 1` deleted -> the same clause fails, after the
##     30 s poll falls out;
##   * `sweeperLastDetail = report.detail` replaced by `= ""` -> the detail
##     clause fails.
##
## ONE MUTATION IS KNOWN GREEN AND IS NOT A GAP. Replacing `not writerActive
## or` with `false or` in `enqueueExtensionInsert` leaves this file green,
## because `writerCapacity == 0` on a writer nobody started refuses the row
## anyway: those `doAssert`s are double-defended, which is a property of the
## writer rather than a hole in the clause.
##
## NO MOCKS. Every call below is the real module surface.

import std/[os, times, unittest]

import runquota_observation_store

const
  Touchers = 32
    ## Enough concurrent first touches that a lost update under a duplicated
    ## lock would be likely rather than theoretical.
  PerToucher = 8

type Toucher = object
  id: int

proc offerRows(state: ptr Toucher) {.thread.} =
  ## `doAssert`, never `check`: stock `unittest.fail` takes the
  ## `setProgramResult 1` branch outside a test body, so a `check` here would
  ## print and leave the test reporting `[OK]`.
  {.cast(gcsafe).}:
    for i in 0 ..< PerToucher:
      let tag = $state.id & "-" & $i
      # EVERY OFFER MUST BE REFUSED. No writer was ever started, so an
      # accepted row would mean this test was not driving the configuration
      # it claims to drive.
      doAssert not enqueueRunRow(RunRow(
        runId: "run-" & tag,
        hostId: "host-0",
        tool: "tool",
        toolVersion: "0.0.1",
        invocationKind: "build",
        startedAtUnixMillis: 1,
        captureCompleteness: ccComplete))
      doAssert not enqueueExecutionRow(ExecutionRow(
        executionId: "exec-" & tag,
        hostId: "host-0",
        runId: "run-" & tag,
        commandStatsId: "stats-" & tag,
        startedAtUnixMillis: 1,
        finishedAtUnixMillis: 2,
        durationMillis: 1,
        exitStatus: 0,
        termination: tExited,
        attempt: 1,
        peakRssBytes: 1024,
        maxProcesses: 1,
        majorPageFaults: 0,
        captureCompleteness: ccComplete))
      doAssert not enqueueExtensionInsert(
        "insert into ext_probe (execution_id) values ('" & tag & "');")
      # THE CONDITION VARIABLE, TOO. `initCond` beside the `initLock` is what
      # raised this guard's consequence from an unsynchronised counter to a
      # waiter parked on a duplicated condition variable. An inactive writer's
      # flush returns without waiting, which is the point: it must return,
      # and it must have been counted.
      flushObservationWriter()

proc touchSampler(state: ptr Toucher) {.thread.} =
  {.cast(gcsafe).}:
    for i in 0 ..< PerToucher:
      setAmbientLiveLeaseCount(state.id + i + 1)
      reportSelfExecution("self-" & $state.id & "-" & $i,
        cpuPct = 1.0, rssBytes = 1024, ownerKey = "owner-" & $state.id)

proc touchRetention(state: ptr Toucher) {.thread.} =
  ## THE THIRTEEN READERS `runquota_daemon`'s `retentionJson` CALLS, in the
  ## order it calls them, and nothing else: this proc is what one
  ## `inspect observations` request does to this module, run thirty-two wide.
  ##
  ## Every one of them takes `sweeperLock`, so before the repair each was a
  ## candidate first toucher -- `initLock` on a mutex another thread may
  ## already hold.
  discard state
  {.cast(gcsafe).}:
    for _ in 0 ..< PerToucher:
      doAssert not retentionSweeperActive()
      doAssert retentionSweepsStarted() == 0'i64
      doAssert retentionSweepsFinished() == 0'i64
      doAssert retentionSweepsDeferred() == 0'i64
      doAssert retentionSweepsForced() == 0'i64
      doAssert retentionSweepFailures() == 0'i64
      doAssert retentionExecutionsRemoved() == 0'i64
      doAssert retentionExtensionRowsRemoved() == 0'i64
      doAssert retentionCarriedRowsRemoved() == 0'i64
      doAssert retentionAmbientSamplesRemoved() == 0'i64
      doAssert retentionLastPassStartedAtUnixMillis() == 0'i64
      doAssert retentionLastPassFinishedAtUnixMillis() == 0'i64
      # A STRING, AND THEREFORE THE SHARPEST OF THE THIRTEEN. A string copied
      # out from under a duplicated lock is not a lost update but a read of a
      # buffer another thread may be reassigning.
      doAssert retentionLastDetail().len == 0

proc unopenablePath(): string =
  ## A store path whose PARENT CANNOT BE CREATED, because a regular file
  ## stands where the directory would go. `openObservationStore` degrades on
  ## it without spawning anything, so the clause that uses it needs neither
  ## `sqlite3` nor a writable database -- it is about the counters moving,
  ## not about retention.
  let blocker = getTempDir() / ("rq-lockinit-" & $getCurrentProcessId() & "-" &
    $int(epochTime() * 1000))
  removeDir(blocker)
  removeFile(blocker)
  writeFile(blocker, "not a directory\n")
  blocker / "observations.db"

var
  touchers: array[Touchers, Toucher]
  toucherThreads: array[Touchers, Thread[ptr Toucher]]

suite "process-wide locks are armed before any thread":
  test "the observation writer's first touch may be many threads at once":
    # NOTHING ON THE MAIN THREAD FIRST. The next line is this process's first
    # contact with `writer.nim`, and it is thirty-two threads wide.
    for i in 0 ..< Touchers:
      touchers[i] = Toucher(id: i)
      createThread(toucherThreads[i], offerRows, addr touchers[i])
    for i in 0 ..< Touchers:
      joinThread(toucherThreads[i])

    check not observationWriterActive()
    # EXACT, NOT "AT LEAST". Three offers per iteration, every one refused
    # and every one counted under `writerLock`; a second lock would let some
    # of those increments overwrite each other.
    check observationsDropped() == int64(Touchers * PerToucher * 3)
    check observationsWritten() == 0'i64
    check observationWriteFailures() == 0'i64
    check observationWriterFlushes() == int64(Touchers * PerToucher)

  test "the ambient sampler's first touch may be many threads at once":
    for i in 0 ..< Touchers:
      touchers[i] = Toucher(id: i)
      createThread(toucherThreads[i], touchSampler, addr touchers[i])
    for i in 0 ..< Touchers:
      joinThread(toucherThreads[i])

    check not ambientSamplerActive()
    # Every execution id is unique, so the live set holds one slot per
    # report. A slot appended under a duplicated lock is a slot lost.
    check liveSelfReports().len == Touchers * PerToucher
    check ambientLiveLeaseCount() > 0
    # The owner sweep is the same count taken a second way, through the
    # other index into the set.
    check endSelfReportsForOwner("owner-0") == PerToucher
    check liveSelfReports().len == Touchers * PerToucher - PerToucher
    clearSelfReportedExecutions()
    check liveSelfReports().len == 0

  test "the retention sweeper's counters may be read first by many threads":
    # NOTHING ON THE MAIN THREAD FIRST, again: the next line is this process's
    # first contact with `retention.nim`, and it is thirty-two threads wide.
    # This is the reachable configuration -- a capture-disabled daemon, or
    # merely one with `retention_sweep_interval_millis` at zero, answering two
    # `inspect observations` requests at once.
    for i in 0 ..< Touchers:
      touchers[i] = Toucher(id: i)
      createThread(toucherThreads[i], touchRetention, addr touchers[i])
    for i in 0 ..< Touchers:
      joinThread(toucherThreads[i])

    check not retentionSweeperActive()
    check retentionSweepsStarted() == 0'i64
    check retentionSweepsFinished() == 0'i64
    check retentionSweepFailures() == 0'i64
    check retentionLastDetail().len == 0

  test "and those zeroes are a reading rather than a constant":
    # WHY THIS CLAUSE EXISTS. Every assertion in the clause above is that a
    # counter is ZERO, and a reader broken into returning a constant would
    # satisfy all of them. This drives the same readers to values that are not
    # zero, through the real sweeper thread, so the clause above is known to
    # be capable of failing.
    #
    # THE SWEEP IS MADE TO FAIL ON PURPOSE. `applyRetention` against a store
    # that would not open returns `applied == false` with a reason -- OS-4's
    # degrade-never-fail path -- and that moves `started`, `finished`,
    # `failures`, both timestamps and `last_detail` in a single tick without
    # needing a database or a `sqlite3` on PATH.
    let path = unopenablePath()
    # The blocker is a real file in the system temp directory; it goes away
    # whether this clause passes or fails.
    defer: removeFile(path.parentDir)
    # THE IDLE GATE, SETTLED RATHER THAN WAITED ON. The sampler clause above
    # leaves live leases published, and a busy tick is a DEFERRED sweep. Zero
    # leases and a deferral ceiling of zero point the same way, so the first
    # tick sweeps under either reading.
    setAmbientLiveLeaseCount(0)
    startRetentionSweeper(path, "host-0", noRetention(),
      intervalMillis = 20, maxDeferredSweeps = 0, pollMillis = 5)
    check retentionSweeperActive()

    # POLLED, WITH THE READING ASSERTED RATHER THAN THE LOOP. A bounded wait
    # that falls out quietly is how "the sweeper never ran" reads green.
    let deadline = epochTime() + 30.0
    var failures = retentionSweepFailures()
    while failures == 0 and epochTime() < deadline:
      sleep(5)
      failures = retentionSweepFailures()
    stopRetentionSweeper()

    check failures > 0'i64
    check retentionSweepsStarted() > 0'i64
    check retentionSweepsFinished() > 0'i64
    check retentionLastPassStartedAtUnixMillis() > 0'i64
    check retentionLastPassFinishedAtUnixMillis() > 0'i64
    # The store could not be opened, and the pass says exactly that.
    check retentionLastDetail() == "store is not open"
    check not retentionSweeperActive()
