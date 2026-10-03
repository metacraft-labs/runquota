## Real SQLite contention must not stop host observations.
##
## A separate sqlite3 process holds BEGIN IMMEDIATE while the production
## sampler runs. Its readiness marker is written by SQLite after acquiring
## the transaction. We require an in-flight publication, continued actual
## host reads, bounded overflow, complete shutdown draining, and counted
## foreign-key rejection. No mocks or synthetic host readings are used.

import std/[monotimes, os, osproc, streams, strutils, tempfiles, times, unittest]
import runquota_observation_store

proc waitFor(predicate: proc(): bool {.closure.}; millis = 3500): bool =
  let start = getMonoTime()
  while (getMonoTime() - start).inMilliseconds < millis:
    if predicate(): return true
    sleep(10)
  predicate()

proc startLocker(path, ready: string): Process =
  result = startProcess(findExe("sqlite3"),
    args = ["-batch", "-bail", path], options = {poStdErrToStdOut})
  result.inputStream.write(".timeout 5000\nbegin immediate;\n.once '" &
    ready.replace('\\', '/') & "'\nselect 'locked';\n")
  result.inputStream.flush()

proc unlock(locker: Process) =
  locker.inputStream.write("rollback;\n.quit\n")
  locker.inputStream.flush()
  let code = locker.waitForExit(5000)
  if code == -1:
    locker.kill()
    discard locker.waitForExit()
  doAssert code == 0, "SQLite lock holder did not exit cleanly"

suite "ambient writer contention":
  for capacity in [128, 1]:
    test "sampling continues during SQLite contention, capacity " & $capacity:
      let dir = createTempDir("rq-ambient-writer-", "")
      defer: removeDir(dir)
      let path = dir / "observations.sqlite"
      let store = openObservationStore(path)
      require store.captureEnabled
      let hostId = resolveHostIdentity(dir / "host-id").hostId
      require store.ensureHostRow(hostId, "boot-contention")
      let ready = dir / "locked"
      let locker = startLocker(path, ready)
      var released = false
      defer:
        if not released:
          locker.kill()
          discard locker.waitForExit()
        locker.close()
        stopAmbientSampler()
      require waitFor(proc(): bool = fileExists(ready))
      require readFile(ready).strip() == "locked"
      startAmbientSampler(path, hostId, cadenceMillis = 50,
        flushSamples = 1, capacity = capacity)
      setAmbientLiveLeaseCount(1)
      require waitFor(proc(): bool = ambientSamplerTiming().flushesStarted > 0)
      require ambientSamplerTiming().flushes == 0
      let before = ambientSamplerTicks()
      sleep(1200)
      # At 50 ms this allows ordinary scheduler jitter, while the original
      # synchronous flush records zero ticks during the locked transaction.
      let ticksWhileBlocked = ambientSamplerTicks() - before
      echo "  capacity=", capacity, " ticksDuringBlockedFlush=", ticksWhileBlocked
      check ticksWhileBlocked >= 10
      check ambientSamplerTiming().flushes == 0
      if capacity == 1:
        require waitFor(proc(): bool = ambientSamplesDropped() > 0, 2300)
      else:
        check ambientSamplesDropped() == 0
      unlock(locker)
      released = true
      stopAmbientSampler()
      let rows = store.readAmbientSamples()
      check rows.len.int64 == ambientSamplesWritten()
      check ambientSamplesTaken() ==
        ambientSamplesWritten() + ambientSamplesDropped()
      check ambientSampleFailures() == 0
      check rows.len > 0
      for i in 1 ..< rows.len:
        check rows[i].sampledAtUnixMillis > rows[i - 1].sampledAtUnixMillis
      check ambientSamplerTiming().flushesStarted == ambientSamplerTiming().flushes

  test "rejected publication is counted and shutdown settles every sample":
    let dir = createTempDir("rq-ambient-rejected-", "")
    defer: removeDir(dir)
    let path = dir / "observations.sqlite"
    let store = openObservationStore(path)
    require store.captureEnabled
    # No host row: the real foreign-key constraint must reject publication.
    startAmbientSampler(path, "unregistered-host", cadenceMillis = 50,
      flushSamples = 1)
    defer: stopAmbientSampler()
    setAmbientLiveLeaseCount(1)
    require waitFor(proc(): bool = ambientSampleFailures() > 0)
    stopAmbientSampler()
    check ambientSamplesWritten() == 0
    check ambientSamplesTaken() > 0
    check ambientSamplesTaken() == ambientSamplesDropped()
    check store.readAmbientSamples().len == 0
    check ambientSamplerTiming().flushesStarted == ambientSamplerTiming().flushes
