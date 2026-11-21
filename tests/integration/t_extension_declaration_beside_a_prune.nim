## A ``DeclareExtension`` that has to write the store waits alone.
##
## REGRESSION TEST FOR reprobuild-pm
## ``issues/2026-11-18-runquota-declare-extension-writes-the-store-under-the-daemon-lock.md``.
##
## THE PROPERTY. RunQuota-Observation-Store.md §"Retention": the retention
## pass "MUST NOT run under the daemon-wide request lock, and neither may
## anything that can wait on a pass". A declaration that CREATES an
## extension's table, or MIGRATES it to a newer version, runs a
## ``begin immediate`` script, and ``begin immediate`` waits on SQLite's busy
## timeout for whoever holds the write lock -- above all the sweeper's
## delete, which holds it for the length of the delete. When that script ran
## inside the connection worker's ``acquire(sharedDaemon.lock)``, one
## client's first declaration during a pass stopped every lease grant,
## release and record on the host until the delete committed. The write now
## happens on the connection worker before the request takes the lock.
##
## HOW THE ORDER IS PINNED. Client A declares a NEW extension (the create
## branch) on a thread of its own once the pass's delete is observed holding
## the store's write lock. Client B then registers a session and asks for a
## lease on the test's main thread. B must be answered while A's declaration
## is still unanswered. With the write under the daemon-wide lock, B's
## requests queue behind A's handler and are answered only after the delete
## commits and A has been answered, so the discriminating check fails.
##
## THE ONE WAIT THAT IS A SLEEP, AND WHY IT IS ONE-SIDED. Nothing the daemon
## reports says "a declaration is waiting on SQLite", so the test cannot
## observe that A's frame has reached the daemon; it sleeps 100 ms after A's
## thread says it is about to send. A local socket delivers in microseconds.
## If the frame were somehow slower than that on the UNFIXED daemon, B would
## be served first and the arm would pass there -- a missed red, never a
## false red on the fixed one. The red was recorded against the unfixed
## daemon (see the fixing commit).
##
## NO MOCKS, AND NOTHING SUBSTITUTED. The real ``runquotad`` from
## ``build/bin``, a real Unix-domain socket, the real RQSP client library and
## a real SQLite store, seeded so that a scheduled retention pass has a
## delete long enough to act inside. ``scripts/run_tests.sh`` builds the apps
## first; an ad-hoc ``nim c -r`` of this file does not.

import private_broker_owner
import std/[atomics, json, options, os, osproc, strutils, unittest]

from runquota_ipc import endpointDirectoryPermissions
import runquota_client
import runquota_core
import runquota_observation_store
import daemon_binary
import scratch_root
import daemon_endpoint

when defined(windows):
  import std/winlean
  const
    LockfileFailImmediately = 0x00000001'i32
    LockfileExclusiveLock = 0x00000002'i32
  proc shmLockFileEx(file: Handle; flags, reserved, lengthLow, lengthHigh: int32;
                     overlapped: ptr OVERLAPPED): WINBOOL
    {.stdcall, dynlib: "kernel32.dll", importc: "LockFileEx".}
  proc shmUnlockFileEx(file: Handle; reserved, lengthLow, lengthHigh: int32;
                       overlapped: ptr OVERLAPPED): WINBOOL
    {.stdcall, dynlib: "kernel32.dll", importc: "UnlockFileEx".}
else:
  import std/posix

const
  seededExtension = "m15decl_seeded"
    ## Seeded with one row per execution so the pass's delete cascades into
    ## a second table and is longer for it.
  declaredExtension = "m15decl_new"
    ## The extension client A declares during the pass: unknown to the
    ## store, so its declaration takes the create branch and must write.
  declaredOwner = "runquota-m15decl"
  seededExecutions = 60_000
    ## The same seed as `t_observation_retention_scheduled`, for the same
    ## reason: enough rows that the pass has a middle to act inside, and
    ## few enough that it stays under the 5-second busy timeout.
  walWriteLockByte = 120
    ## The WAL-index byte SQLite holds exclusively for the whole of a write
    ## transaction; see `t_observation_store_retention_crash.nim`.

# ---------------------------------------------------------------------------
# Fixture plumbing
# ---------------------------------------------------------------------------

proc scratchRoot(name: string): string =
  # Short on purpose: `Sockaddr_un_path_length` is 92 on macOS.
  result = getTempDir() / ("rq-m15d-" & $getCurrentProcessId() & "-" & name)
  removeDir(result)
  createDir(result)

proc rendezvousDir(root: string;
                   fixturePolicy: var PrivateBrokerCallerPolicyBinding): string =
  result = root / "ep"
  createDir(result)
  fixturePolicy = bindPrivateBrokerPolicyToCaller(privateEndpointGroup(result))
  setFilePermissions(result, endpointDirectoryPermissions())

proc hostStateDir(root: string): string =
  result = root / "state"
  createDir(result)
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

type DaemonHandle = object
  process: Process

proc startDaemon(socketPath: string; extraArgs: openArray[string]):
    DaemonHandle =
  var args = @["--socket", socketPath, "--measurement", "capture=on"]
  for arg in extraArgs:
    args.add(arg)
  let process = startProcess(daemonPath(), args = args,
    options = {poStdErrToStdOut})
  for _ in 0 ..< 400:
    if endpointIsBound(socketPath): break
    sleep(25)
  discard readRequiredStartupLines(process, 3,
    "t_extension_declaration_beside_a_prune")
  DaemonHandle(process: process)

proc stop(handle: var DaemonHandle) =
  if handle.process.running:
    handle.process.terminate()
    discard handle.process.waitForExit(5000)
  if handle.process.running:
    handle.process.kill()
    discard handle.process.waitForExit(5000)
  handle.process.close()

proc retention(client: var RunQuotaClient): JsonNode =
  parseJson(client.inspectionJson("observations"))["observations"]["retention"]

proc mintIdentity(identityFile: string): string =
  result = opaqueId("host-")
  writeFile(identityFile, result & "\n")

proc extensionDdl(extensionId, column: string): string =
  "create table " & extensionTableName(extensionId) & " (\n" &
  "  host_id text not null,\n" &
  "  execution_id text not null,\n" &
  "  " & column & " text not null,\n" &
  "  primary key (host_id, execution_id),\n" &
  "  foreign key (host_id, execution_id)\n" &
  "    references executions(host_id, execution_id)\n);"

proc seedStore(path, hostId: string; executions: int; firstStartedAt: int64) =
  let store = openObservationStore(path)
  doAssert store.captureEnabled, store.report
  doAssert store.insertHost(HostRow(hostId: hostId,
    createdAtUnixMillis: 1_000, lastBootId: "boot"))
  doAssert store.insertHostProfile(HostProfileRow(hostId: hostId,
    profileId: "seeded", profileHash: "sha256:seeded",
    validFromUnixMillis: 1_000,
    cpuModel: "synthetic", physicalCores: 4, logicalCores: 8,
    ramBytes: 1 shl 34, swapBytes: 0, diskClass: dcSsd, fsType: "apfs",
    arch: "arm64", os: "macos", osVersion: "15", kernelVersion: "24",
    virtualization: "none", cpuShareGroup: "default"))
  doAssert store.insertRun(RunRow(runId: "seed-run", hostId: hostId,
    tool: "t", toolVersion: "v", invocationKind: "build",
    startedAtUnixMillis: 1_000, captureCompleteness: ccComplete))
  doAssert store.declareExtension(ExtensionDeclaration(
    extensionId: seededExtension, owner: declaredOwner, schemaVersion: 1,
    migrations: @[extensionDdl(seededExtension, "payload")])) == eoCreated
  var sql = "begin immediate;\n"
  for i in 0 ..< executions:
    let id = "seed-" & align($i, 7, '0')
    sql.add("insert into executions (execution_id, host_id, host_profile_id," &
      " run_id, command_stats_id, started_at_unix_millis, " &
      "finished_at_unix_millis, duration_millis, exit_status, termination, " &
      "attempt, peak_rss_bytes, max_processes, major_page_faults, " &
      "capture_completeness) values (" & encodeText(id) & ", " &
      encodeText(hostId) & ", 'seeded', 'seed-run', 'c', " &
      $(firstStartedAt + int64(i)) & ", " & $(firstStartedAt + int64(i) + 1) &
      ", 1, 0, 'exited', 1, 0, 1, 0, 'complete');\n")
    sql.add("insert into " & extensionTableName(seededExtension) &
      " values (" & encodeText(hostId) & ", " & encodeText(id) & ", " &
      encodeText("payload-" & $i) & ");\n")
  sql.add("commit;\n")
  doAssert store.runStatement(sql), store.lastError

proc writeLocked(path: string): bool =
  ## Whether somebody holds a write transaction on ``path`` right now, read
  ## in process from the WAL index's write-lock byte, with no request to
  ## the daemon -- so the poll cannot itself be what is slow.
  let shm = path & "-shm"
  when defined(windows):
    let file = createFileW(newWideCString(shm),
      GENERIC_READ or GENERIC_WRITE,
      FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,
      nil, OPEN_EXISTING, 0, 0)
    if file == INVALID_HANDLE_VALUE:
      return false
    defer: discard closeHandle(file)
    var at: OVERLAPPED
    at.offset = int32(walWriteLockByte)
    if shmLockFileEx(file, LockfileFailImmediately or LockfileExclusiveLock,
        0, 1, 0, addr at) == 0:
      return true
    discard shmUnlockFileEx(file, 0, 1, 0, addr at)
    false
  else:
    let fd = posix.open(shm.cstring, O_RDWR)
    if fd < 0:
      return false
    defer: discard posix.close(fd)
    var lock: Tflock
    lock.l_type = cshort(F_WRLCK)
    lock.l_whence = cshort(SEEK_SET)
    lock.l_start = Off(walWriteLockByte)
    lock.l_len = Off(1)
    fcntl(fd, F_GETLK, addr lock) == 0 and lock.l_type != cshort(F_UNLCK)

proc registryVersion(path, extensionId: string): int64 =
  ## What the STORE says, read from the file: -1 when not registered.
  let store = openObservationStore(path)
  if not store.captureEnabled:
    return -1
  let entry = store.extensionRegistryEntry(extensionId)
  if entry.isSome: entry.get.schemaVersion else: -1

# ---------------------------------------------------------------------------
# Client A, on a thread of its own
# ---------------------------------------------------------------------------

var
  declarationAboutToSend: Atomic[bool]
  declarationAnswered: Atomic[bool]
  declarationAnsweredAtMillis = 0'i64
  declarationOutcome = "<not answered>"
  declarationError = ""

proc declareOnItsOwnClient() {.thread.} =
  ## Client A's first declaration of ``declaredExtension``. The plain
  ## globals are read only after `joinThread`, which orders them; the two
  ## atomics are what the main thread reads while A is still waiting.
  {.cast(gcsafe).}:
    try:
      var client = connectDefault()
      var session = client.registerSession("m15d-declarer", "0.2.0")
      declarationAboutToSend.store(true)
      declarationOutcome = session.declareExtension(declaredExtension,
        declaredOwner, 1, [extensionDdl(declaredExtension, "note")])
      declarationAnsweredAtMillis = unixMillisNow()
      declarationAnswered.store(true)
      session.closeSession()
      client.close()
    except CatchableError as error:
      declarationError = error.msg
      declarationAnswered.store(true)

var
  racerReady: array[2, Atomic[bool]]
  racerGo: Atomic[bool]
  racerOutcome: array[2, string]
  racerError: array[2, string]

proc declareAsRacer(index: int) {.thread.} =
  ## One of two clients declaring the SAME new extension at once. Both
  ## connect and register first, then wait for one signal, so their two
  ## frames leave together. Globals are read only after `joinThread`.
  {.cast(gcsafe).}:
    try:
      var client = connectDefault()
      var session = client.registerSession("m15d-racer-" & $index, "0.2.0")
      racerReady[index].store(true)
      while not racerGo.load():
        sleep(0)
      racerOutcome[index] = session.declareExtension(declaredExtension,
        declaredOwner, 1, [extensionDdl(declaredExtension, "note")])
      session.closeSession()
      client.close()
    except CatchableError as error:
      racerError[index] = error.msg

suite "extension_declaration_beside_a_prune":

  test "a declaration waiting on a prune does not hold up another client's lease":
    let privateOwner = bindPrivateBrokerOwnerToCaller()
    defer: restorePrivateBrokerOwner(privateOwner)
    let root = scratchRoot("decl")
    defer: removeScratchRoot(root)
    var endpointPolicy: PrivateBrokerCallerPolicyBinding
    defer: restorePrivateBrokerPolicy(endpointPolicy)
    let socketPath = rendezvousDir(root, endpointPolicy) / "d.sock"
    let state = hostStateDir(root)
    let identityFile = state / "host-id"
    let dbPath = state / "observations.sqlite3"
    let hostId = mintIdentity(identityFile)
    seedStore(dbPath, hostId, seededExecutions, unixMillisNow() - 400_000)
    check registryVersion(dbPath, declaredExtension) == -1

    putEnv("RUNQUOTA_SOCKET", socketPath)
    var daemon = startDaemon(socketPath,
      ["--host-identity-file", identityFile,
       "--retention-max-executions", "100",
       "--retention-max-execution-age-millis", "-1",
       "--retention-sweep-interval-millis", "1000"])
    declarationAboutToSend.store(false)
    declarationAnswered.store(false)
    var declarer: Thread[void]
    var declarerStarted = false
    var sawDeleteHoldingTheStore = false
    var lockedWhenADeclared = false
    var lockedWhenBAnswered = false
    var answeredBeforeB = true
    var leaseActive = false
    var leaseAnsweredAt = 0'i64
    var passStartedAt = 0'i64
    var passFinishedAt = 0'i64
    try:
      var clientB = connectDefault()
      # FIRST THE PASS: the daemon writes at start-up too, and a write lock
      # seen then is not the prune's.
      var passBegan = false
      for _ in 0 ..< 4_000:
        let snapshot = clientB.retention()
        if snapshot["sweeps_started"].getInt() >= 1:
          passBegan = snapshot["sweeps_finished"].getInt() == 0
          break
        sleep(5)
      check passBegan
      # THEN THE WRITE LOCK DURING THE PASS -- its delete, by far the
      # longest writer.
      for _ in 0 ..< 400_000:
        if writeLocked(dbPath):
          sawDeleteHoldingTheStore = true
          break
        sleep(0)
      check sawDeleteHoldingTheStore

      createThread(declarer, declareOnItsOwnClient)
      declarerStarted = true
      for _ in 0 ..< 4_000:
        if declarationAboutToSend.load(): break
        sleep(1)
      check declarationAboutToSend.load()
      sleep(100)
      # STILL INSIDE THE DELETE once A's frame has been sent; otherwise A's
      # `begin immediate` has nothing to wait for and nothing is asserted.
      lockedWhenADeclared = writeLocked(dbPath)
      check lockedWhenADeclared

      var session = clientB.registerSession("m15d-beside-declaration",
        "0.2.0")
      var lease = session.requestLease(resourceRequest(
        "beside-declaration", milliCpu(1000),
        bytes(256'u64 * 1024'u64 * 1024'u64)))
      leaseAnsweredAt = unixMillisNow()
      # SAMPLED AT BOTH ENDS. The write-lock byte is read once before A's
      # frame is sent (above) and once here, right after B is answered. The
      # discriminator below only means something if the delete held the
      # store across the whole interval between the two, and a single
      # early sample cannot say so: a delete that committed in between
      # would make A answer quickly and read as a product regression. The
      # delete is one transaction, so locked at both ends is locked
      # throughout; if the second sample is clear, the arm reports that
      # the prune ended first instead of blaming the daemon.
      lockedWhenBAnswered = writeLocked(dbPath)
      # THE DISCRIMINATOR. With the declaration's write under the
      # daemon-wide lock, B's two requests are answered only after A's.
      answeredBeforeB = declarationAnswered.load()
      leaseActive = lease.active
      if lease.active:
        lease.release()
      session.closeSession()

      joinThread(declarer)
      declarerStarted = false

      var settled: JsonNode = nil
      for _ in 0 ..< 1_200:
        settled = clientB.retention()
        if settled["sweeps_finished"].getInt() >= 1: break
        sleep(50)
      check settled["sweeps_finished"].getInt() >= 1
      passStartedAt = settled["last_pass_started_at_unix_millis"].getBiggestInt()
      passFinishedAt =
        settled["last_pass_finished_at_unix_millis"].getBiggestInt()
      clientB.close()
    finally:
      if declarerStarted:
        joinThread(declarer)
      daemon.stop()

    echo "  prune window: " & $(passFinishedAt - passStartedAt) &
      " ms; B's lease answered at " & $(leaseAnsweredAt - passStartedAt) &
      " ms, A's declaration answered at " &
      $(declarationAnsweredAtMillis - passStartedAt) & " ms"

    check declarationError.len == 0
    check leaseActive
    # PRECONDITION OF THE DISCRIMINATOR, NOT A PROPERTY OF THE DAEMON: the
    # prune was still deleting when B was answered. When this fails the
    # arm measured nothing; the checks below are not evidence either way.
    check lockedWhenBAnswered
    # THE PROPERTY: B was served while A's declaration was still waiting on
    # the delete.
    check not answeredBeforeB
    check leaseAnsweredAt <= declarationAnsweredAtMillis
    # NOT VACUOUS: A's declaration was accepted as a CREATE and the store
    # carries it -- the write moved, it was not skipped.
    check declarationOutcome == ""
    check registryVersion(dbPath, declaredExtension) == 1
    check passFinishedAt - passStartedAt >= 300

  test "two first declarations of one extension during a prune are both accepted":
    ## THE SAFEGUARD THE MOVE NEEDED, PINNED. With the declaration's write
    ## off the daemon-wide lock, that lock no longer serializes declarations.
    ## Two clients declaring the same new id would both read "not
    ## registered" and both run the create; the loser's "table already
    ## exists" is not a rejection, so it would be answered
    ## `refused-migration-failed` AND degrade the store, turning capture off
    ## host-wide. `declarationLock` serializes them, so the second reads the
    ## first's registration and is answered up to date.
    ##
    ## WHY DURING A PRUNE: both frames then wait on the pass's delete, so
    ## without the lock both reads land before either create commits --
    ## the race is forced, not hoped for. Red with `declarationLock`
    ## removed is recorded in the fixing commit.
    let privateOwner = bindPrivateBrokerOwnerToCaller()
    defer: restorePrivateBrokerOwner(privateOwner)
    let root = scratchRoot("race")
    defer: removeScratchRoot(root)
    var endpointPolicy: PrivateBrokerCallerPolicyBinding
    defer: restorePrivateBrokerPolicy(endpointPolicy)
    let socketPath = rendezvousDir(root, endpointPolicy) / "d.sock"
    let state = hostStateDir(root)
    let identityFile = state / "host-id"
    let dbPath = state / "observations.sqlite3"
    let hostId = mintIdentity(identityFile)
    seedStore(dbPath, hostId, seededExecutions, unixMillisNow() - 400_000)

    putEnv("RUNQUOTA_SOCKET", socketPath)
    var daemon = startDaemon(socketPath,
      ["--host-identity-file", identityFile,
       "--retention-max-executions", "100",
       "--retention-max-execution-age-millis", "-1",
       "--retention-sweep-interval-millis", "1000"])
    for i in 0 .. 1:
      racerReady[i].store(false)
      racerOutcome[i] = "<not answered>"
      racerError[i] = ""
    racerGo.store(false)
    var racers: array[2, Thread[int]]
    var started = 0
    var sawDelete = false
    var captureAfter = ""
    try:
      var probe = connectDefault()
      for i in 0 .. 1:
        createThread(racers[i], declareAsRacer, i)
        inc started
      for _ in 0 ..< 4_000:
        if racerReady[0].load() and racerReady[1].load(): break
        sleep(1)
      check racerReady[0].load() and racerReady[1].load()
      for _ in 0 ..< 4_000:
        let snapshot = probe.retention()
        if snapshot["sweeps_started"].getInt() >= 1: break
        sleep(5)
      for _ in 0 ..< 400_000:
        if writeLocked(dbPath):
          sawDelete = true
          break
        sleep(0)
      check sawDelete
      racerGo.store(true)
      for i in 0 ..< started:
        joinThread(racers[i])
      started = 0
      # CAPTURE IS STILL ON: a third declaration is answered, not refused
      # as `unavailable`.
      var session = probe.registerSession("m15d-after-race", "0.2.0")
      captureAfter = session.declareExtension(declaredExtension,
        declaredOwner, 1, [extensionDdl(declaredExtension, "note")])
      session.closeSession()
      probe.close()
    finally:
      for i in 0 ..< started:
        joinThread(racers[i])
      daemon.stop()

    echo "  racers answered: '" & racerOutcome[0] & "', '" & racerOutcome[1] &
      "'; after: '" & captureAfter & "'"
    check racerError[0].len == 0 and racerError[1].len == 0
    check racerOutcome[0] == ""
    check racerOutcome[1] == ""
    check captureAfter == ""
    check registryVersion(dbPath, declaredExtension) == 1
