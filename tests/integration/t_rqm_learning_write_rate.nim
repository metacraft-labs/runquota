## How often a command's learned row reaches the estimate store.
##
## Every finish that carries a measured tree peak is folded into the
## command's learned row, in memory, at once -- admission reads that row. A
## DURABLE write of the row is what the estimate store's background writer
## spends CPU on, and with the memory cap on every finish carries a peak, so
## committing every finish made the daemon's CPU grow with the finish rate of
## every command that repeats. The writer's rule now:
##
## * a row whose decision figures -- the conservative figure, the largest
##   measured peak (M), the last breach's cap and peak -- differ from the
##   ones its key last committed is committed with the next batch, as before;
## * a row that differs only in bookkeeping (sample count, recent peak,
##   outcome, time, the time of a breach identical to the last) is committed
##   at most once per key per refresh interval;
## * a clean stop commits every row still held back, so it loses nothing.
##
## WHAT IS GUARDED, one case per clause, each with the mutation that turns it
## red:
##
## * test_bookkeeping_finishes_are_rate_limited: twenty paced finishes below
##   M, inside the interval of the key's first commit, are not committed at
##   all, while the row in memory counts every one of them. Mutation: never
##   hold a row back (`admit`) -- the paced finishes then land in a batch
##   each.
## * test_decision_figures_are_written_at_once: raising M, raising the
##   conservative figure (an outside OOM kill) and recording a breach are
##   each committed within a second (twenty writer batches) of the finish,
##   and the store read back after a SIGKILL -- no final drain -- holds all
##   three. Mutation: hold rows back on time alone, ignoring the figures --
##   none of the three is committed in time, and the killed daemon's store
##   holds none of them.
## * test_clean_stop_flushes_waiting_rows: after rate-limited finishes, a
##   SIGTERM'd daemon's store, and the daemon restarted over it, hold the
##   latest sample count. Mutation: do not commit held-back rows on the stop
##   (`admit`'s `stopping`) -- the restarted daemon reads the count of the
##   first commit.
##
## The write count is the daemon's own `estimate_rows_written` (the rows its
## writer committed), from the inspection output. No mocks: the built
## `runquotad`, a real endpoint, the ordinary client library and a real
## SQLite store (`tests/support/rqm_daemon.nim`).

when defined(posix):
  import std/[json, os, osproc, times, unittest]

  import runquota_client
  import runquota_persistence
  import runquota_protocol
  import rqm_daemon

  const
    Key = "learning-write-rate"
    RefreshIntervalSeconds = 30.0
      ## `runquota_persistence.DefaultEstimateRefreshIntervalMillis`, which
      ## the daemon runs with; restated so a change to it is a change here.
    MaxPeak = 4'u64 * GiB

  proc rowsWritten(client: var RunQuotaClient): int =
    let node = parseJson(client.inspectionJson("observations"))
    let observations = node["observations"]
    doAssert observations.hasKey("estimate_rows_written"),
      "the status JSON does not report estimate_rows_written"
    observations["estimate_rows_written"].getInt()

  proc awaitRowsWritten(client: var RunQuotaClient; atLeast: int;
                        budgetMillis: int): int =
    ## The count once it reaches `atLeast`, or what it is when the budget
    ## runs out. The writer drains every 50 ms.
    let deadline = epochTime() + float(budgetMillis) / 1000.0
    while true:
      result = client.rowsWritten()
      if result >= atLeast or epochTime() > deadline:
        return
      sleep(10)

  proc finishMeasured(session: var RunQuotaSession; outcome: LeaseFinish;
                      peak: uint64; breach = false) =
    var lease = session.requestLease(request(Key, 1'u64 * GiB))
    lease.finishWith(outcome, peakBytes = peak,
      capBlock = measured(lease.memoryCap.capBytes, peak,
        lease.memoryCap.basis, capReached = breach))

  proc establishMax(client: var RunQuotaClient;
                    session: var RunQuotaSession): int =
    ## The first, decisive finish of `Key` (it creates the row and sets M),
    ## and the write count once it is committed.
    let before = client.rowsWritten()
    session.finishMeasured(succeeded(), MaxPeak)
    result = client.awaitRowsWritten(before + 1, 5_000)
    doAssert result == before + 1, "the first finish was not written"

  proc storedRow(root: string): LearnedEstimateRow =
    for row in loadLearnedEstimates(root / "est.sqlite"):
      if row.commandStatsId == Key:
        return row

  proc killNow(daemon: RqmDaemon) =
    ## SIGKILL: the writer gets no final drain.
    daemon.process.kill()
    discard daemon.process.waitForExit(10_000)
    daemon.process.close()
    # The killed daemon's socket file is left behind; removed so a restart
    # waits for the new daemon's socket, not this one.
    removeFile(daemon.socket)

  suite "the learned-row write rate":
    test "test_bookkeeping_finishes_are_rate_limited":
      let daemon = startRqmDaemon("rqmrate")
      defer: daemon.stop()
      var client = connectDefault()
      defer: client.close()
      var session = client.registerSession(SessionName, "0")
      let established = client.establishMax(session)
      let started = epochTime()
      const finishes = 20
      for i in 0 ..< finishes:
        # Below M and below the conservative figure (1.25 × M): nothing a
        # decision reads changes. PACED past the writer's 50 ms drain, so
        # a write per finish would show as one batch each rather than be
        # coalesced by the queue.
        session.finishMeasured(succeeded(), 1'u64 * GiB + uint64(i) * MiB)
        sleep(60)
      sleep(300) # a few more drains, for anything queued late
      let elapsed = epochTime() - started
      let written = client.rowsWritten() - established
      checkpoint("rows written " & $written & " in " & $elapsed & " s")
      # All of it inside the interval of the first commit: nothing is due.
      require elapsed < RefreshIntervalSeconds
      check written == 0
      # The row in memory took every finish: admission is not rate-limited.
      let row = client.learnedRow(Key)
      check row.figure("sample_count") == uint64(finishes + 1)
      check row.figure("max_observed_peak_bytes") == MaxPeak
      check row.figure("recent_peak_memory_bytes") ==
        1'u64 * GiB + uint64(finishes - 1) * MiB
      session.closeSession()

    test "test_decision_figures_are_written_at_once":
      let daemon = startRqmDaemon("rqmnow")
      var killed = false
      defer:
        if not killed: daemon.stop()
        else:
          try: removeDir(daemon.root)
          except CatchableError: discard
      var client = connectDefault()
      var session = client.registerSession(SessionName, "0")
      var written = client.establishMax(session)

      # Raising M, inside the refresh interval of the write above.
      let raisedMax = 6'u64 * GiB
      session.finishMeasured(succeeded(), raisedMax)
      check client.awaitRowsWritten(written + 1, 1_000) == written + 1
      inc written

      # Raising the conservative figure: an outside OOM kill doubles the
      # larger of its peak and the lease's memory (2 × 6 GiB), M unchanged.
      session.finishMeasured(oomKilled(killedBySignal(9'u32)), raisedMax)
      check client.awaitRowsWritten(written + 1, 1_000) == written + 1
      inc written

      # A breach: recorded (cap, peak, time); no learned figure moves.
      let breachPeak = 20'u64 * GiB
      session.finishMeasured(capExceeded(killedBySignal(9'u32)), breachPeak,
        breach = true)
      check client.awaitRowsWritten(written + 1, 1_000) == written + 1
      inc written

      session.closeSession()
      client.close()
      # And it is on disk, not only counted: the store is read only after
      # the daemon is killed, with no drain, and holds all three.
      daemon.killNow()
      killed = true
      let stored = storedRow(daemon.root)
      check stored.maxObservedPeakBytes == raisedMax
      check stored.conservativeMemoryBytes == 2'u64 * raisedMax
      check stored.lastBreachPeakBytes == breachPeak
      check stored.lastBreachUnixMillis > 0'u64

    test "test_clean_stop_flushes_waiting_rows":
      let daemon = startRqmDaemon("rqmstop")
      block:
        var client = connectDefault()
        defer: client.close()
        var session = client.registerSession(SessionName, "0")
        let established = client.establishMax(session)
        for i in 0 ..< 5:
          session.finishMeasured(succeeded(), 1'u64 * GiB + uint64(i) * MiB)
        sleep(300)
        # Rate-limited: the store still holds the first write's count.
        check client.rowsWritten() == established
        check storedRow(daemon.root).sampleCount == 1'u32
        session.closeSession()
      daemon.halt() # SIGTERM: the orderly shutdown
      check storedRow(daemon.root).sampleCount == 6'u32
      let restarted = startRqmDaemon("", root = daemon.root)
      defer: restarted.stop()
      var client = connectDefault()
      defer: client.close()
      check client.learnedRow(Key).figure("sample_count") == 6'u64
