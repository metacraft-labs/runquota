## THE ENDPOINT DOES NOT WAIT FOR THE OBSERVATION STORE.
##
## THE DEFECT THIS EXISTS FOR. `runquotad` used to open its observation
## store -- `openObservationStore`, whose first act on an existing file is a
## whole-file `pragma quick_check` -- BEFORE it bound its endpoint. On a host
## whose store had grown to a few hundred megabytes that check took 3-17 s
## warm and over two minutes cold, and for all of it the daemon was simply
## ABSENT: no socket, no listening line. Every client that starts a daemon
## and waits a bounded time for it (reprobuild's auto-start waits 15 s, its
## tests 5 s) reported "runquotad did not become reachable" for a daemon
## that was, in fact, busy reading statistics nobody had asked for yet.
##
## WHAT THE SPECIFICATION SAYS, and why the fix is shaped the way it is.
## `docs/database.md`, "Corruption handling": corruption is detected at open
## with `pragma quick_check`, and "the store degrades to no capture and the
## daemon keeps serving leases". Lease service therefore never depended on
## the store's verdict -- only capture does. So the endpoint binds and
## serves at once, and the store is verified on a thread of its own; capture
## starts only when the verdict is in. The guarantee the check exists for --
## NOTHING IS WRITTEN INTO A STORE THAT HAS NOT BEEN VERIFIED -- is kept, and
## this file asserts it rather than assuming it.
##
## THREE CLAUSES, EACH FAILING FOR ITS OWN REASON:
##
##   1. **Reachable while the check runs.** A full Hello handshake (not a
##      socket-file test) succeeds while the store's check is provably still
##      blocked on the lock. Fails on the old ordering, where nothing is bound
##      until the check returns: on `dev` 3b1de0f the daemon was unreachable
##      for the whole window. The time to reach it is PRINTED, not bounded
##      more tightly than the window: it is ~50-150 ms on a quiet host, but
##      a sub-second bound measured 1494 ms once at a load average of 300,
##      and a clause that fails for host load says nothing about the defect.
##   2. **Leases are served, and nothing is captured, during verification.**
##      A lease taken in the window is granted; the daemon reports
##      `store_status: verifying` and `capture_enabled: false`; and after
##      verification the store holds NO row for that session. Fails if the
##      fix skipped or bypassed the check to get the endpoint up.
##   3. **Capture starts once the store is verified.** The three fixed
##      startup lines still arrive, the store line still says "capture
##      enabled", and a session opened afterwards IS recorded. Fails if the
##      deferral lost capture altogether -- a daemon that never opened its
##      store would pass clauses 1 and 2 on its own.
##
## HOW THE CHECK IS MADE SLOW, and why this is not a mock. A multi-hundred-
## megabyte store would make the check slow only on a cold page cache, and
## by an amount that depends on the host. Instead a REAL `sqlite3` process
## holds a REAL `BEGIN EXCLUSIVE` on a REAL store file (in rollback-journal
## mode, where an exclusive lock blocks readers). The daemon's
## `quick_check` then waits on SQLite's own busy handler (`.timeout 5000`,
## `sqlite_cli.nim`) until the lock is released -- the same wait a store
## contended by another daemon's writer or retention sweep produces in
## production. The duration is under this test's control, so every clause is
## decisive without being timing-sensitive; the lock is always released
## well inside the 5 s busy timeout, so the check then passes.
##
## NO MOCKS. The real `runquotad` from `build/bin`, a real Unix-domain
## socket, the shipped client library, and the store read back through the
## store library.

import std/[json, os, osproc, streams, strutils, times, unittest]

from runquota_ipc import endpointDirectoryPermissions
import runquota_client
import runquota_core
import runquota_observation_store
import runquota_protocol
import daemon_binary
import daemon_endpoint
import scratch_root

const
  LockHeldCeilingMillis = 3500
    ## The lock is released no later than this after it was taken, whatever
    ## the clauses above it are doing. The daemon's check gives up after 5 s
    ## of busy-waiting and would then (correctly) call the store corrupt,
    ## which would make clause 3 fail for a reason that is not the defect.
  MiB = 1024'u64 * 1024'u64

proc scratchRoot(name: string): string =
  # Short on purpose: `Sockaddr_un_path_length` is 92 on macOS.
  result = getTempDir() / ("rq-bf-" & $getCurrentProcessId() & "-" & name)
  removeDir(result)
  createDir(result)

proc rendezvousDir(root: string): string =
  result = root / "ep"
  createDir(result)
  setFilePermissions(result, endpointDirectoryPermissions())

proc hostStateDir(root: string): string =
  result = root / "state"
  createDir(result)
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

type StoreLock = object
  process: Process
  takenAt: float

proc holdExclusiveLock(dbPath: string): StoreLock =
  ## A real `sqlite3` connection holding `BEGIN EXCLUSIVE`. Returns only once
  ## the lock is HELD -- the `select` after the `begin` cannot print until
  ## the `begin` succeeded -- so the daemon is never spawned into a race
  ## with the fixture.
  let process = startProcess(findExe("sqlite3"),
    args = ["-batch", "-noheader", "-bail", dbPath], options = {})
  let input = process.inputStream
  # Rollback-journal mode, because under WAL an exclusive writer does not
  # block readers and the check would not wait at all.
  input.write("pragma journal_mode = delete;\n")
  input.write("begin exclusive;\n")
  input.write("select 'lock-held';\n")
  input.flush()
  var line = ""
  while process.outputStream.readLine(line):
    if line.strip() == "lock-held":
      return StoreLock(process: process, takenAt: epochTime())
  raise newException(IOError, "sqlite3 exited before taking the lock: " &
    process.errorStream.readAll())

proc millisHeld(lock: StoreLock): int =
  int((epochTime() - lock.takenAt) * 1000.0)

proc release(lock: var StoreLock) =
  if lock.process.isNil:
    return
  if lock.process.running:
    try:
      lock.process.inputStream.write("commit;\n.quit\n")
      lock.process.inputStream.flush()
      lock.process.inputStream.close()
    except CatchableError:
      discard
    discard lock.process.waitForExit(5000)
  if lock.process.running:
    lock.process.kill()
    discard lock.process.waitForExit(5000)
  lock.process.close()
  lock.process = nil

proc stopDaemon(process: Process) =
  if process.running:
    process.terminate()
    discard process.waitForExit(10_000)
  if process.running:
    process.kill()
    discard process.waitForExit(5000)
  process.close()

proc tryConnect(): (bool, RunQuotaClient) =
  try:
    (true, connectDefault())
  except CatchableError:
    (false, default(RunQuotaClient))

proc takeOneLease(client: var RunQuotaClient; sessionName: string): bool =
  var session = client.registerSession(sessionName, "0.1.0")
  var lease = session.requestLease(resourceRequest(sessionName,
    milliCpu(100), bytes(1'u64 * MiB)))
  result = lease.active
  lease.markStarting()
  lease.markRunning(childProcessId = uint64(getCurrentProcessId()))
  lease.finish(outcome = succeeded(), peakMemoryBytes = 4'u64 * MiB,
    processCount = 1'u32)
  lease.release()
  session.closeSession()

proc runTools(dbPath: string): seq[string] =
  let store = openObservationStore(dbPath)
  if store.captureEnabled:
    for run in store.readRuns():
      result.add(run.tool)

suite "endpoint_serves_before_store_verification":

  test "the endpoint answers while the store's integrity check is still running":
    let root = scratchRoot("v")
    defer: removeScratchRoot(root)
    let socketPath = rendezvousDir(root) / "d.sock"
    let state = hostStateDir(root)
    let dbPath = state / "observations.sqlite3"
    require fileExists(daemonPath())
    require findExe("sqlite3").len > 0

    # A real, current-schema store, so the daemon's open takes the
    # "existing file" path that runs the check.
    let fixture = openObservationStore(dbPath)
    require fixture.captureEnabled

    putEnv("RUNQUOTA_SOCKET", socketPath)
    var lock = holdExclusiveLock(dbPath)
    var daemon: Process = nil
    try:
      let spawnedAt = epochTime()
      daemon = startProcess(daemonPath(),
        args = ["--socket", socketPath,
                "--observation-db", dbPath,
                "--host-identity-file", state / "host-id",
                "--ambient-sample-interval-millis", "0",
                "--retention-sweep-interval-millis", "0"],
        options = {poStdErrToStdOut})

      # -------------------------------------------------------------------
      # CLAUSE 1: reachable while the check is blocked.
      # -------------------------------------------------------------------
      var reachable = false
      var client: RunQuotaClient
      while not reachable and lock.millisHeld() < LockHeldCeilingMillis - 500:
        (reachable, client) = tryConnect()
        if not reachable:
          sleep(10)
      let reachedMillis = int((epochTime() - spawnedAt) * 1000.0)
      echo "  spawn -> Hello answered: " &
        (if reachable: $reachedMillis & " ms" else: "not within the window") &
        " (store lock held " & $lock.millisHeld() & " ms so far)"
      check reachable
      # THE CHECK IS STILL RUNNING, not merely "was slow once": the lock it
      # is waiting on has not been released.
      check lock.process.running

      if reachable:
        # -----------------------------------------------------------------
        # CLAUSE 2: leases are served; nothing is captured yet.
        # -----------------------------------------------------------------
        let during = parseJson(client.inspectionJson("observations"))
        check during["observations"]{"store_status"}.getStr() == "verifying"
        check during["observations"]["capture_enabled"].getBool() == false
        check takeOneLease(client, "during-verification")
        # Still inside the window, or the clause above proved nothing.
        check lock.process.running
        check lock.millisHeld() < LockHeldCeilingMillis
        client.close()

      lock.release()

      # ---------------------------------------------------------------------
      # CLAUSE 3: the verdict arrives, capture starts, and only after it.
      # ---------------------------------------------------------------------
      # EXACTLY THREE STARTUP LINES, consumed by count; the second and third
      # are the store's verdict, so they arrive once the check is done.
      var lines: seq[string] = @[]
      for _ in 0 ..< 3:
        lines.add(daemon.outputStream.readLine())
      echo "  startup lines: " & lines.join(" | ")
      check lines[0].startsWith("runquotad listening")
      check lines[1].contains("capture enabled")
      check lines[2].contains("hardware profile")

      var after = connectDefault()
      let settled = parseJson(after.inspectionJson("observations"))
      check settled["observations"]{"store_status"}.getStr() == "open"
      check settled["observations"]["capture_enabled"].getBool() == true
      check takeOneLease(after, "after-verification")
      # `queryStats` flushes the writer, so the rows are committed when it
      # returns.
      discard after.queryStats(statsSubjectDistribution,
        statsKey = "after-verification")
      after.close()

      let tools = runTools(dbPath)
      echo "  sessions recorded: " & $tools
      check "after-verification" in tools
      check "during-verification" notin tools
    finally:
      lock.release()
      if not daemon.isNil:
        stopDaemon(daemon)
      delEnv("RUNQUOTA_SOCKET")
