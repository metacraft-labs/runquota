## The estimate writer's refresh interval, at the store's own API.
##
## The writer commits a queued row at once when its key has not been
## committed within the refresh interval or when the row's decision figures
## (conservative figure, largest measured peak, breach record, declaration)
## differ from the ones its key last committed. Otherwise it holds the row
## back -- newest per key -- and commits it itself once the interval since
## that commit has passed, or when the store stops. Held-back rows are
## bounded: one past the capacity sends the longest-waiting row to the
## store. The interval is stamped when a batch COMMITS, so a row lost to a
## failed batch does not hold back the next row of its key.
##
## WHAT IS GUARDED, each with its falsifying mutation:
##
## * a held-back row lands once the interval has passed, measured from the
##   first row's ENQUEUE (the commit is later, so the bound is safe whatever
##   the writer's 50 ms sleep and schema setup take), and not long before.
##   Mutation: drop the writer's commit of due rows (`admit`'s due loop) --
##   the row then lands only at the stop.
## * a row whose decision figures changed lands at once although its key was
##   just committed. Mutation: hold back on time alone (ignore the figures)
##   -- it waits the whole interval and the 1 s check fails.
## * the stop commits whatever is held back. Mutation: no `stopping` in
##   `admit` -- the stored sample count is the older one.
## * the held-back set is bounded. Mutation: drop the capacity loop -- no
##   row is written until the interval.
## * a row with changed figures whose batch FAILS is not followed by a 30 s
##   wait: the next row of its key, though it changes no figure itself, is
##   committed at once. Mutation: stamp the key when the batch is taken
##   rather than when it commits -- the next row is then held back.
## * a held-back row never reaches the store after a newer row of its key:
##   a row with changed figures that arrives while an older one is held back
##   replaces it. Mutation: drop `admit`'s `elif entry.waiting:` branch --
##   the older row stays held, lands when due, and overwrites the raised
##   maximum on disk.
## * a breach repeated with the same cap and peak is bookkeeping (only its
##   time differs); one with a different cap or peak is committed at once.
##   Mutation: compare the breach time too -- every repeated breach then
##   commits.
##
## NO MOCKS: real SQLite files, the production writer thread, read back
## through `loadLearnedEstimates`. The failed batch is a real SQLite abort,
## from a trigger the test installs on the store.

import std/[os, tempfiles, times, unittest]

from runquota_core/sqlite_inproc import closePooledConnections, runSqlScript
import runquota_persistence

proc stored(path: string; key = "cmd"): LearnedEstimateRow =
  for row in loadLearnedEstimates(path):
    if row.commandStatsId == key:
      return row

proc awaitSampleCount(path: string; count: uint32; budgetMillis: int;
                      key = "cmd"): bool =
  let deadline = epochTime() + float(budgetMillis) / 1000.0
  while epochTime() <= deadline:
    if stored(path, key).sampleCount == count:
      return true
    sleep(10)
  false

proc awaitRowsWritten(atLeast: uint64; budgetMillis: int): uint64 =
  let deadline = epochTime() + float(budgetMillis) / 1000.0
  while true:
    result = estimateRowsWritten()
    if result >= atLeast or epochTime() > deadline:
      return
    sleep(10)

proc sample(count: uint32; maxPeak = 100'u64; key = "cmd";
            breachCap = 0'u64; breachPeak = 0'u64): LearnedEstimateRow =
  LearnedEstimateRow(scope: "session:t", commandStatsId: key,
    conservativeMemoryBytes: 125'u64, recentPeakMemoryBytes: uint64(count),
    sampleCount: count, maxObservedPeakBytes: maxPeak,
    updatedUnixMillis: uint64(count), lastBreachCapBytes: breachCap,
    lastBreachPeakBytes: breachPeak,
    lastBreachUnixMillis: (if breachCap > 0'u64: uint64(count) else: 0'u64))

template withStore(name: string; interval: int64; capacity: int;
                   body: untyped) =
  let dir = createTempDir(name, "")
  let path {.inject.} = dir / "est.sqlite"
  var store {.inject.} = startEstimateStore(path,
    refreshIntervalMillis = interval, waitingCapacity = capacity)
  var stopped {.inject.} = false
  try:
    body
  finally:
    if not stopped: stopEstimateStore(store)
    closePooledConnections()
    removeDir(dir)

suite "the estimate writer's refresh interval":
  test "a held-back row lands after the interval, a changed one at once":
    const interval = 600'i64
    withStore("rqrefresh", interval, DefaultEstimateWaitingCapacity):
      let firstEnqueued = epochTime()
      check enqueueEstimateWrite(store, sample(1))
      check awaitSampleCount(path, 1, 2_000)

      # Bookkeeping only, inside the interval: held back ...
      check enqueueEstimateWrite(store, sample(2))
      sleep(250)
      check stored(path).sampleCount == 1'u32
      # ... and committed by the writer once the interval has passed, with
      # no further enqueue. The interval runs from the first commit, which
      # is later than the first enqueue.
      check awaitSampleCount(path, 2, 3_000)
      check epochTime() - firstEnqueued >= float(interval) / 1000.0

      # A changed decision figure right after that commit is not held back.
      check enqueueEstimateWrite(store, sample(3, maxPeak = 200'u64))
      check awaitSampleCount(path, 3, 1_000)
      check stored(path).maxObservedPeakBytes == 200'u64

  test "the stop commits the rows still held back":
    withStore("rqrefstop", 600_000'i64, DefaultEstimateWaitingCapacity):
      check enqueueEstimateWrite(store, sample(1))
      check awaitSampleCount(path, 1, 2_000)
      for count in 2'u32 .. 9'u32:
        check enqueueEstimateWrite(store, sample(count))
      sleep(200)
      check stored(path).sampleCount == 1'u32
      stopEstimateStore(store)
      stopped = true
      check stored(path).sampleCount == 9'u32

  test "the held-back rows are bounded":
    withStore("rqrefcap", 600_000'i64, 2):
      let keys = ["k0", "k1", "k2", "k3"]
      let before = estimateRowsWritten()
      for key in keys:
        check enqueueEstimateWrite(store, sample(1, key = key))
      check awaitRowsWritten(before + 4, 2_000) == before + 4
      for key in keys:
        check enqueueEstimateWrite(store, sample(2, key = key))
      # Four held back against a capacity of two: two go to the store.
      check awaitRowsWritten(before + 6, 1_000) == before + 6
      sleep(200)
      check estimateRowsWritten() == before + 6
      var advanced = 0
      for key in keys:
        if stored(path, key).sampleCount == 2'u32: inc advanced
      check advanced == 2

  test "a failed batch does not hold back the next row of its key":
    withStore("rqreffail", 600_000'i64, DefaultEstimateWaitingCapacity):
      check enqueueEstimateWrite(store, sample(1))
      check awaitSampleCount(path, 1, 2_000)
      # Every update of the row aborts while the switch is on.
      check runSqlScript(path, """
        create table fail_switch (armed integer not null);
        insert into fail_switch values (1);
        create trigger fail_updates before update on learned_estimates
          when (select armed from fail_switch) = 1
          begin select raise(abort, 'test-injected failure'); end;
      """).ok
      let failuresBefore = estimateWriteFailures()
      # A raised maximum: committed at once, and that batch fails.
      check enqueueEstimateWrite(store, sample(2, maxPeak = 300'u64))
      let deadline = epochTime() + 2.0
      while estimateWriteFailures() == failuresBefore and
          epochTime() < deadline:
        sleep(10)
      check estimateWriteFailures() > failuresBefore
      check runSqlScript(path, "update fail_switch set armed = 0;").ok
      check stored(path).maxObservedPeakBytes == 100'u64
      # The next row changes nothing against the row before it, but the
      # raised maximum never reached the store, so it is committed now.
      check enqueueEstimateWrite(store, sample(3, maxPeak = 300'u64))
      check awaitSampleCount(path, 3, 1_000)
      check stored(path).maxObservedPeakBytes == 300'u64

  test "a held-back row never lands after a newer one":
    const interval = 600'i64
    withStore("rqreforder", interval, DefaultEstimateWaitingCapacity):
      check enqueueEstimateWrite(store, sample(1))
      check awaitSampleCount(path, 1, 2_000)
      # Bookkeeping: held back. Given a writer pass of its own (50 ms
      # cadence) so the queue does not simply replace it with the next row.
      check enqueueEstimateWrite(store, sample(2))
      sleep(200)
      check stored(path).sampleCount == 1'u32
      # A raised maximum: committed at once, and it supersedes the held row.
      check enqueueEstimateWrite(store, sample(3, maxPeak = 200'u64))
      check awaitSampleCount(path, 3, 1_000)
      # Past the held row's due time: it must not have been written.
      sleep(int(interval) * 2)
      check stored(path).sampleCount == 3'u32
      check stored(path).maxObservedPeakBytes == 200'u64

  test "a repeated identical breach is bookkeeping, a different one is not":
    withStore("rqrefbreach", 600_000'i64, DefaultEstimateWaitingCapacity):
      let before = estimateRowsWritten()
      check enqueueEstimateWrite(store,
        sample(1, breachCap = 1_000'u64, breachPeak = 1_500'u64))
      check awaitRowsWritten(before + 1, 2_000) == before + 1
      # The same cap passed by the same peak, three more times: only the
      # breach time (and the sample count) differ. Each given a writer pass.
      for count in 2'u32 .. 4'u32:
        check enqueueEstimateWrite(store,
          sample(count, breachCap = 1_000'u64, breachPeak = 1_500'u64))
        sleep(120)
      check estimateRowsWritten() == before + 1
      check stored(path).sampleCount == 1'u32
      # A breach with a different peak: committed at once.
      check enqueueEstimateWrite(store,
        sample(5, breachCap = 1_000'u64, breachPeak = 1_800'u64))
      check awaitSampleCount(path, 5, 1_000)
      check stored(path).lastBreachPeakBytes == 1_800'u64
