## M13 gate: the write path over the socket — the FALLBACK path.
##
## NO MOCKS, AND NOTHING SUBSTITUTED. Every arm below runs the real
## ``runquotad`` binary from ``build/bin``, a real Unix-domain socket, the
## real RQSP client library, and a real SQLite store on the real
## filesystem. The rows asserted on are read back out of the database file
## the daemon wrote. The one place a "fixture" appears is where the gate
## requires a state a well-behaved client cannot produce — a truncated
## frame, a lease reported by the session that does not own it, a client
## SIGKILLed mid-execution, a store made unwritable underneath a running
## daemon — and each of those is a real hostile or broken client, not a
## stand-in for one.
##
## WHY THE DAEMON BINARY RATHER THAN ``initDaemon`` IN PROCESS. M10's
## record and M11's mutation (15) both say the same thing: the daemon-side
## behaviour has to be exercised through ``scripts/build_apps.sh`` and the
## binary on disk, because a mutation that only recompiles the test reports
## green while the code under test never executes.
##
## THE REFUSAL ARMS ARE THE POINT. The campaign's working conventions warn
## that these suites are written from OUTSIDE the API, driving it the way a
## well-behaved client would, and that such a style reaches every
## ACCEPTANCE path and almost no REFUSAL path. Four of the six tests here
## are refusals or degradations, and each is reached by doing something a
## client library cannot be asked to do.

import std/[json, options, os, osproc, posix, streams, strutils, unittest]

from runquota_ipc import endpointDirectoryPermissions, sendFrame, receiveFrame
import runquota_client
import runquota_core
import runquota_observation_store
import runquota_protocol

const CrashClientEnv = "RUNQUOTA_M13_CRASH_CLIENT"
const CrashReadyEnv = "RUNQUOTA_M13_CRASH_READY"
const CrashCpuMilliPct = 9_500'u32
const CrashRssBytes = 2_250_000_000'u64

# ---------------------------------------------------------------------------
# The child role: a client that reports and then dies without saying so
# ---------------------------------------------------------------------------
#
# THIS HAS TO BE A SEPARATE PROCESS. "A client dies mid-report" is not
# reproducible in-process: the failure under test is that the daemon never
# hears a LeaseFinished and never hears a CloseSession, and anything the
# test process could do to itself either unwinds cleanly or takes the test
# down with it. So the test re-executes its own binary in a client role and
# SIGKILLs it — no handlers, no unwinding, no goodbye.
proc runCrashClientRole(socketPath, readyPath: string) =
  putEnv("RUNQUOTA_SOCKET", socketPath)
  var client = connectDefault()
  var session = client.registerSession("m13-crash-client", "0.1.0")
  var lease = session.requestLease(resourceRequest(
    "m13-crash-exec", milliCpu(1000),
    bytes(256'u64 * 1024'u64 * 1024'u64)))
  doAssert lease.active
  lease.markStarting()
  lease.markRunning(childProcessId = uint64(getCurrentProcessId()))
  lease.reportObservation(CrashCpuMilliPct, CrashRssBytes,
    uint64(unixMillisNow()))
  # Announced only after the report has been written to the socket, so the
  # parent never kills this process before the thing it is testing has
  # happened.
  writeFile(readyPath, $getCurrentProcessId() & "\n")
  while true:
    sleep(1000)

when isMainModule:
  let crashSocket = getEnv(CrashClientEnv)
  if crashSocket.len > 0:
    runCrashClientRole(crashSocket, getEnv(CrashReadyEnv))
    quit 0

# ---------------------------------------------------------------------------
# Fixture plumbing
# ---------------------------------------------------------------------------

proc scratchRoot(name: string): string =
  # Short on purpose: Nim's `Sockaddr_un_path_length` is 92 on macOS and
  # `toSockAddr` refuses a path at or past it, so 91 characters is the
  # entire budget. A plain macOS `TMPDIR` is 49 of them on its own.
  result = getTempDir() / ("rq-m13-" & $getCurrentProcessId() & "-" & name)
  removeDir(result)
  createDir(result)

proc rendezvousDir(root: string): string =
  result = root / "ep"
  createDir(result)
  # THE MODE THE SHIPPED POLICY REQUIRES, derived rather than written as a
  # literal: the rendezvous mode is 0750 where a `runquota` group exists
  # and 0700 where it does not, so a hardcoded fixture is green on one kind
  # of host and red on the other.
  setFilePermissions(result, endpointDirectoryPermissions())

proc hostStateDir(root: string): string =
  result = root / "state"
  createDir(result)
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc daemonPath(): string =
  getCurrentDir() / "build" / "bin" / "runquotad"

proc socketIsBound(path: string): bool =
  var info: Stat
  lstat(path.cstring, info) == 0 and S_ISSOCK(info.st_mode)

type DaemonHandle = object
  process: Process
  startupLines: seq[string]

proc startDaemon(socketPath: string; extraArgs: openArray[string]):
    DaemonHandle =
  var args = @["--socket", socketPath]
  for arg in extraArgs:
    args.add(arg)
  let process = startProcess(daemonPath(), args = args,
    options = {poStdErrToStdOut})
  for _ in 0 ..< 400:
    if socketIsBound(socketPath): break
    sleep(25)
  # EXACTLY THREE STARTUP LINES, ALWAYS. Before M13 it was three when a
  # store path was given and one when it was not; capture is on without any
  # flag now, so there is always a store to report on — including the one
  # `--no-write-stats` turned off. Reading precisely three is itself an
  # assertion: a daemon that printed a different number would leave this
  # read blocked or misaligned.
  var lines: seq[string] = @[]
  for _ in 0 ..< 3:
    lines.add(process.outputStream.readLine())
  DaemonHandle(process: process, startupLines: lines)

proc stop(handle: var DaemonHandle) =
  if handle.process.running:
    handle.process.terminate()
    discard handle.process.waitForExit(5000)
  if handle.process.running:
    handle.process.kill()
    discard handle.process.waitForExit(5000)
  handle.process.close()

proc observations(client: var RunQuotaClient): JsonNode =
  parseJson(client.inspectionJson("observations"))["observations"]

proc waitForExecutions(path: string; atLeast: int): seq[ExecutionRow] =
  for _ in 0 ..< 120:
    let store = openObservationStore(path)
    if store.captureEnabled:
      result = store.readExecutions()
      if result.len >= atLeast:
        return
    sleep(50)

proc completeOneExecution(client: var RunQuotaClient; label: string;
                          reportFigures = false): uint64 =
  ## One whole execution over the socket, the way a supervising client
  ## drives it: register, request, starting, running, (report), finished.
  var session = client.registerSession("m13-" & label, "0.2.0")
  var lease = session.requestLease(resourceRequest(
    label, milliCpu(1000), bytes(256'u64 * 1024'u64 * 1024'u64)))
  doAssert lease.active
  result = lease.id.value
  lease.markStarting()
  lease.markRunning(childProcessId = uint64(getCurrentProcessId()))
  if reportFigures:
    lease.reportObservation(CrashCpuMilliPct, CrashRssBytes,
      uint64(unixMillisNow()))
  sleep(60)
  lease.finish(outcome = leaseFinishSucceeded, exitCode = 0'u32,
    peakMemoryBytes = 1_234_567'u64, processCount = 3'u32,
    majorPageFaults = 11'u64)
  lease.release()
  session.closeSession()

suite "observation_socket_write_path":

  # -------------------------------------------------------------------------
  # THE GATE: capture is on without any flag, and the rows are complete
  # -------------------------------------------------------------------------

  test "with NO capture flag a real run produces complete, correct spine rows":
    let root = scratchRoot("on")
    defer: removeDir(root)
    let socketPath = rendezvousDir(root) / "d.sock"
    let state = hostStateDir(root)
    let identityFile = state / "host-id"
    # THE DEFAULT STORE PATH IS DERIVED, NOT PASSED. Nothing below names a
    # database: `--host-identity-file` moves the whole host state, and the
    # store follows it. If the daemon needed a flag to capture, this path
    # would not exist at the end of the test.
    let expectedDb = state / "observations.sqlite3"
    check fileExists(daemonPath())
    check not fileExists(expectedDb)

    putEnv("RUNQUOTA_SOCKET", socketPath)
    var daemon = startDaemon(socketPath, ["--host-identity-file", identityFile])
    var rows: seq[ExecutionRow] = @[]
    var runs: seq[RunRow] = @[]
    var leaseIdValue = 0'u64
    var reported: JsonNode = nil
    try:
      check daemon.startupLines[1].contains(expectedDb)
      check daemon.startupLines[1].contains("capture enabled")
      check daemon.startupLines[2].contains("hardware profile")

      var client = connectDefault()
      leaseIdValue = client.completeOneExecution("socket-write", true)
      reported = client.observations()
      rows = waitForExecutions(expectedDb, 1)
      runs = openObservationStore(expectedDb).readRuns()
      client.close()
    finally:
      daemon.stop()

    # The store exists because capture was on, not because anything asked.
    check fileExists(expectedDb)
    check reported != nil
    check reported["capture_enabled"].getBool()
    check reported["write_stats_disabled"].getBool() == false
    check reported["store_path"].getStr() == expectedDb
    # The in-flight report made the round trip and was folded in.
    check reported["accepted"].getInt() == 1
    check reported["rejected"].getInt() == 0

    # COMPLETE AND CORRECT, column by column, against what the client
    # actually did. "A row appeared" is not the gate; these are.
    check runs.len == 1
    check runs[0].tool == "m13-socket-write"
    check runs[0].toolVersion == "0.2.0"
    check runs[0].captureCompleteness == ccComplete

    check rows.len == 1
    let row = rows[0]
    check row.runId == runs[0].runId
    check row.hostId == runs[0].hostId
    check row.hostId == readFile(identityFile).strip()
    check isOpaqueId(row.hostId, "host-")
    check row.hostProfileId.isSome
    check row.leaseId == some(int64(leaseIdValue))
    check row.exitStatus == 0
    check row.termination == tExited
    check row.peakRssBytes == 1_234_567
    check row.maxProcesses == 3
    check row.majorPageFaults == 11
    check row.attempt == 1
    check row.captureCompleteness == ccComplete
    check row.droppedObservations == 0
    # DURATION IS A MEASUREMENT OF THE WINDOW THE CLIENT HELD, so it is
    # asserted against the sleep that window contained rather than merely
    # against zero.
    check row.durationMillis >= 50
    check row.finishedAtUnixMillis - row.startedAtUnixMillis ==
      row.durationMillis
    # FROM PEER CREDENTIALS, never from anything the client declared.
    check row.ownerUid == some(int64(getuid()))
    # Columns the protocol still does not carry are NULL, not zero: a zero
    # here would be indistinguishable from a measured zero.
    check row.cpuUserMillis.isNone
    check row.ioReadBytes.isNone

  # -------------------------------------------------------------------------
  # THE GATE: --no-write-stats disables it
  # -------------------------------------------------------------------------

  test "--no-write-stats writes nothing at all, and the daemon serves anyway":
    let root = scratchRoot("off")
    defer: removeDir(root)
    let socketPath = rendezvousDir(root) / "d.sock"
    let state = hostStateDir(root)
    let identityFile = state / "host-id"
    let defaultDb = state / "observations.sqlite3"

    putEnv("RUNQUOTA_SOCKET", socketPath)
    var daemon = startDaemon(socketPath,
      ["--host-identity-file", identityFile, "--no-write-stats"])
    var reported: JsonNode = nil
    var status = DaemonStatusMessage()
    try:
      check daemon.startupLines[1].contains("--no-write-stats")
      check daemon.startupLines[1].contains("capture disabled")

      var client = connectDefault()
      # THE SAME WORK AS THE ARM ABOVE, so "no rows" is a statement about
      # the switch and not about a run that did nothing.
      discard client.completeOneExecution("socket-write", true)
      reported = client.observations()
      status = client.daemonStatus()
      client.close()
      # A whole extra second for a writer thread that does not exist to
      # flush something it never queued.
      sleep(1000)
    finally:
      daemon.stop()

    # NOT ONE BYTE ON DISK. Not an empty store, not a store with no rows:
    # the file was never created, and neither was the host identity, which
    # is only needed in order to record.
    check not fileExists(defaultDb)
    check not fileExists(defaultDb & "-wal")
    check not fileExists(identityFile)
    check not fileExists(state / "observations.sqlite")

    check reported != nil
    check reported["capture_enabled"].getBool() == false
    check reported["write_stats_disabled"].getBool()
    check reported["queued"].getInt() == 0
    # THE REPORT WAS DROPPED TOO, not merely unrecorded. `self_*` must not
    # accumulate in a daemon that is not capturing.
    check reported["live_self_reports"].getInt() == 0
    check reported["accepted"].getInt() + reported["rejected"].getInt() >= 1

    # AND ADMISSION KEPT WORKING, which is the half that makes this a
    # switch rather than a kill: the lease was granted, run and finished
    # while capture was off.
    check status.totalGranted >= 1'u64
    check status.totalFinished >= 1'u64

  test "--no-write-stats wins over a named store, and does not blame it":
    # THE PRECEDENCE CLAUSE, AGAINST A DAEMON RATHER THAN A CONFIG. The
    # unit file asserts `effectiveObservationDbPath` returns "" for
    # `--observation-db X --no-write-stats`, and that is a statement about
    # a pure function. It cannot see the thing that makes the clause worth
    # having: a store that would ALSO have refused, for a reason of its
    # own. "Capture is off" is then true whichever way the precedence
    # goes, so the only evidence of which rule fired is WHAT THE DAEMON
    # SAYS and WHETHER IT TOUCHED THE FILE.
    let root = scratchRoot("precedence")
    defer: removeDir(root)
    let socketPath = rendezvousDir(root) / "d.sock"
    let state = hostStateDir(root)
    let identityFile = state / "host-id"
    # A REAL STORE FROM A NEWER BUILD. It opens far enough to read its
    # `user_version` and is then refused -- M9's refusal, which reports
    # the schema and leaves the file alone.
    let namedDb = state / "from-the-future.sqlite3"
    check openObservationStore(namedDb).captureEnabled
    check runSqlite(namedDb,
      "pragma user_version = " & $(spineSchemaVersion + 7) & ";").ok
    # CHECKPOINTED AND THE JOURNAL REMOVED, so that a `-wal` beside the
    # file afterwards can only have been made by the daemon. Building the
    # fixture with the real store puts the database in WAL mode, and
    # leaving its journal there would make "no journal was created" true
    # of nothing.
    check runSqlite(namedDb, "pragma wal_checkpoint(truncate);").ok
    for suffix in ["-wal", "-shm"]:
      removeFile(namedDb & suffix)
    let untouched = readFile(namedDb)

    putEnv("RUNQUOTA_SOCKET", socketPath)
    var daemon = startDaemon(socketPath,
      ["--observation-db", namedDb, "--host-identity-file", identityFile,
       "--no-write-stats"])
    var reported: JsonNode = nil
    var status = DaemonStatusMessage()
    try:
      # NAMED AS THE OPERATOR'S DECISION rather than as a broken database.
      #
      # THESE FOUR LINES ARE NOT THE DISCRIMINATING ONES, and saying so is
      # the point: the startup report is written by the `--no-write-stats`
      # branch whether or not the store was opened first, so a daemon with
      # the precedence reversed prints exactly this. What separates the two
      # is below -- the reported store path, and whether a journal appeared
      # beside a file that should never have been touched.
      check daemon.startupLines[1].contains("--no-write-stats")
      check daemon.startupLines[1].contains("capture disabled")
      check not daemon.startupLines[1].contains("refusing to open schema")
      check not daemon.startupLines[1].contains(namedDb)
      check daemon.startupLines[2].contains("--no-write-stats")

      var client = connectDefault()
      discard client.completeOneExecution("precedence", true)
      reported = client.observations()
      status = client.daemonStatus()
      client.close()
    finally:
      daemon.stop()

    # THE NAMED STORE WAS NEVER OPENED. Not opened and refused -- not
    # opened: no path was configured at all, so there is no store path to
    # report and no journal beside the file.
    check reported != nil
    check reported["write_stats_disabled"].getBool()
    check reported["capture_enabled"].getBool() == false
    check reported["store_path"].getStr() == ""
    check reported["queued"].getInt() == 0
    check reported["live_self_reports"].getInt() == 0
    check readFile(namedDb) == untouched
    check not fileExists(namedDb & "-wal")
    check not fileExists(namedDb & "-shm")
    check not fileExists(identityFile)
    # And admission never noticed any of it.
    check status.totalGranted >= 1'u64
    check status.totalFinished >= 1'u64

  # -------------------------------------------------------------------------
  # DEGRADATION: the shipped default on a host nobody has provisioned yet
  # -------------------------------------------------------------------------

  test "an unprovisioned host state directory degrades capture to off":
    # THIS IS THE SHIPPED DEFAULT, NOT AN EDGE CASE, and that is new with
    # M13. The host-wide state directory is created by the install step and
    # by nothing else, so on every host where that step has not run --
    # including the one this suite is running on -- a daemon started with
    # no store flag resolves its default store to a path whose parent it
    # cannot create. Before M13 that path was reachable only by an operator
    # who passed `--observation-db` at a bad location, which is a choice;
    # now it is what happens by doing nothing.
    #
    # THE FIXTURE IS THE REAL SHAPE, not the real path. `/var/db/runquota`
    # sits under a root-owned directory this test may not write in and must
    # not create, so the fixture reproduces the mechanism -- a default store
    # path derived from a host identity file whose parent cannot be made --
    # rather than the literal location. `defaultObservationDbFile` and its
    # derivation from the identity file are asserted in
    # `tests/unit/t_observation_write_path_rules`.
    let root = scratchRoot("unprovisioned")
    let locked = root / "locked"
    createDir(locked)
    setFilePermissions(locked, {fpUserRead, fpUserExec})
    defer:
      setFilePermissions(locked, {fpUserRead, fpUserWrite, fpUserExec})
      removeDir(root)
    let socketPath = rendezvousDir(root) / "d.sock"
    let identityFile = locked / "nostate" / "host-id"
    let expectedDb = locked / "nostate" / "observations.sqlite3"

    putEnv("RUNQUOTA_SOCKET", socketPath)
    var daemon = startDaemon(socketPath, ["--host-identity-file", identityFile])
    var reported: JsonNode = nil
    var status = DaemonStatusMessage()
    try:
      # THE STORE REPORT IS ONE LINE. The startup output is consumed BY
      # COUNT, and this branch is the one that produces a multi-line
      # message: `OSError.msg` on macOS is the failure plus an "Additional
      # info:" line. Unfolded, it makes four startup lines out of three and
      # every reader of the third gets the second half of the second --
      # which is why the assertion is on line THREE being the identity
      # report rather than merely on line two mentioning the failure.
      check daemon.startupLines[1].contains(expectedDb)
      check daemon.startupLines[1].contains("capture disabled")
      check daemon.startupLines[2].startsWith("runquota observation store")
      check daemon.startupLines[2].contains(
        "host identity and hardware profile not recorded")

      var client = connectDefault()
      # AND THE DAEMON IS A LEASE AUTHORITY FIRST. An advisory subsystem
      # may not take out a machine's build capacity, so a whole execution
      # runs -- including the in-flight report -- and nothing raises.
      discard client.completeOneExecution("unprovisioned", true)
      reported = client.observations()
      status = client.daemonStatus()
      client.close()
    finally:
      daemon.stop()

    # NOTHING WAS CREATED. A path any caller can create is a path any
    # caller can create differently, so the daemon reports and stops.
    check not dirExists(locked / "nostate")
    check not fileExists(expectedDb)

    check reported != nil
    check reported["capture_enabled"].getBool() == false
    # AND IT IS NOT THE OFF SWITCH. Capture off because the host is
    # unprovisioned and capture off because the operator said so are the
    # same state to a consumer and different facts to an operator.
    check reported["write_stats_disabled"].getBool() == false
    check reported["store_path"].getStr() == expectedDb
    check reported["queued"].getInt() == 0
    check reported["live_self_reports"].getInt() == 0
    check status.totalGranted >= 1'u64
    check status.totalFinished >= 1'u64

  test "an untrusted host state directory refuses the identity, not the daemon":
    # THE OTHER HALF, and the one that only exists because the store path
    # is now DERIVED from the identity file. The store and the host
    # identity live in the same directory, so a directory that opens fine
    # for SQLite can still be one whose `host-id` any local user could
    # replace. M13c-fix refuses the identity in that case; M13 is what
    # makes the pair reachable without any flag naming a database.
    let root = scratchRoot("untrusted")
    defer: removeDir(root)
    let socketPath = rendezvousDir(root) / "d.sock"
    let state = root / "state"
    createDir(state)
    # WORLD-WRITABLE: the `sudo mkdir` an operator ran without the chmod.
    setFilePermissions(state, {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupWrite, fpGroupExec,
      fpOthersRead, fpOthersWrite, fpOthersExec})
    let identityFile = state / "host-id"
    let expectedDb = state / "observations.sqlite3"

    putEnv("RUNQUOTA_SOCKET", socketPath)
    var daemon = startDaemon(socketPath, ["--host-identity-file", identityFile])
    var reported: JsonNode = nil
    var status = DaemonStatusMessage()
    try:
      # THE STORE OPENED -- this is not the arm above wearing a different
      # costume -- and capture is off anyway, because the identity was
      # refused.
      check daemon.startupLines[1].contains("capture enabled")
      check daemon.startupLines[2].contains("no host identity")
      check daemon.startupLines[2].contains("group- or world-writable")

      var client = connectDefault()
      discard client.completeOneExecution("untrusted", true)
      reported = client.observations()
      status = client.daemonStatus()
      client.close()
    finally:
      daemon.stop()

    check reported != nil
    check reported["capture_enabled"].getBool() == false
    check reported["write_stats_disabled"].getBool() == false
    check reported["live_self_reports"].getInt() == 0
    check status.totalFinished >= 1'u64
    # NO IDENTITY WAS MINTED into a directory somebody else can write, and
    # NO ROW was written against one. The store file itself exists because
    # it opened before the identity was judged; what must be empty is the
    # spine.
    check not fileExists(identityFile)
    check fileExists(expectedDb)
    let store = openObservationStore(expectedDb)
    check store.captureEnabled
    check store.readExecutions().len == 0
    check store.readRuns().len == 0

  # -------------------------------------------------------------------------
  # REFUSAL: a hostile client reporting against somebody else's lease
  # -------------------------------------------------------------------------

  test "a session reporting figures for a lease it does not own is refused":
    # A FIXTURE NO CLIENT LIBRARY CAN PRODUCE. `reportObservation` takes a
    # lease and reads the session out of it, so a well-behaved client can
    # never name a lease belonging to somebody else. The frame is therefore
    # built by hand and written straight onto the second connection.
    #
    # WHY IT MATTERS: one host-wide daemon holds every user's leases, so a
    # report accepted across the session boundary lets any local
    # participant subtract fictitious load from another user's
    # `foreign_*` — invisibly, because the arithmetic stays self-consistent
    # and the clamp absorbs the overshoot.
    let root = scratchRoot("own")
    defer: removeDir(root)
    let socketPath = rendezvousDir(root) / "d.sock"
    let state = hostStateDir(root)

    putEnv("RUNQUOTA_SOCKET", socketPath)
    var daemon = startDaemon(socketPath,
      ["--host-identity-file", state / "host-id"])
    try:
      var victim = connectDefault()
      var victimSession = victim.registerSession("m13-victim", "0.1.0")
      var victimLease = victimSession.requestLease(resourceRequest(
        "m13-victim-exec", milliCpu(1000),
        bytes(256'u64 * 1024'u64 * 1024'u64)))
      check victimLease.active
      victimLease.markStarting()
      victimLease.markRunning()
      victimLease.reportObservation(CrashCpuMilliPct, CrashRssBytes,
        uint64(unixMillisNow()))

      # The honest report landed. Recorded before the attack so the
      # comparison below is against a known state rather than against zero.
      var settled = victim.observations()
      for _ in 0 ..< 100:
        if settled["accepted"].getInt() >= 1: break
        sleep(20)
        settled = victim.observations()
      check settled["accepted"].getInt() == 1
      check settled["live_self_reports"].getInt() == 1
      let honestCpu = settled["self_cpu_pct"].getFloat()
      let honestRss = settled["self_rss_bytes"].getInt()
      check honestCpu == observedCpuPct(CrashCpuMilliPct)
      check honestRss == int(CrashRssBytes)

      # THE ATTACK. A second connection, its own session, naming the
      # victim's lease id and a figure large enough to swamp the column.
      var attacker = connectDefault()
      var attackerSession = attacker.registerSession("m13-attacker", "0.1.0")
      let forged = LeaseObservationMessage(
        sessionId: attackerSession.id,
        leaseId: victimLease.id,
        cpuMilliPct: 1_600_000'u32,
        rssBytes: 99_000_000_000'u64,
        sampledAtUnixMillis: uint64(unixMillisNow()))
      attacker.connection.sendFrame(encodeFrame(rqLeaseObservation,
        FrameFlagRequest, 9_000_001'u64, encodeLeaseObservation(forged)))

      # AND ONE NAMING ITS OWN SESSION BUT A LEASE THAT DOES NOT EXIST,
      # because "refuse a lease you do not own" implemented as "refuse a
      # lease the session table does not link" would still accept this.
      let phantom = LeaseObservationMessage(
        sessionId: attackerSession.id,
        leaseId: leaseId(victimLease.id.value + 4242'u64),
        cpuMilliPct: 500_000'u32,
        rssBytes: 77_000_000_000'u64,
        sampledAtUnixMillis: uint64(unixMillisNow()))
      attacker.connection.sendFrame(encodeFrame(rqLeaseObservation,
        FrameFlagRequest, 9_000_002'u64, encodeLeaseObservation(phantom)))

      var after = victim.observations()
      for _ in 0 ..< 200:
        if after["rejected"].getInt() >= 2: break
        sleep(20)
        after = victim.observations()

      # BOTH REFUSED, AND NOTHING OF EITHER APPLIED. The count of live
      # reports is not enough on its own — a forged report that REPLACED
      # the victim's would leave the count at one — so the figures
      # themselves are compared.
      check after["rejected"].getInt() == 2
      check after["accepted"].getInt() == 1
      check after["live_self_reports"].getInt() == 1
      check after["self_cpu_pct"].getFloat() == honestCpu
      check after["self_rss_bytes"].getInt() == honestRss

      # ONE SESSION'S RECLAMATION TAKES ITS OWN REPORTS AND NOBODY ELSE'S.
      # The attacker now behaves, takes a lease of its own and reports
      # honestly about it, so there are two live reports under two
      # different owners; then its connection drops with the lease still
      # running, which is the reclamation path. It must carry off exactly
      # its own report and leave the victim's where it was.
      #
      # AN OWNER KEY THAT DID NOT DISTINGUISH SESSIONS — a constant, the
      # store path, the daemon's own id — satisfies every other clause in
      # this file and empties the column for every other client on the
      # host whenever anybody disconnects. That is worse than the leak it
      # replaced, and it is invisible in the data.
      var attackerLease = attackerSession.requestLease(resourceRequest(
        "m13-attacker-exec", milliCpu(1000),
        bytes(256'u64 * 1024'u64 * 1024'u64)))
      check attackerLease.active
      attackerLease.markStarting()
      attackerLease.markRunning()
      attackerLease.reportObservation(1_000'u32, 1_000_000'u64,
        uint64(unixMillisNow()))

      var both = victim.observations()
      for _ in 0 ..< 200:
        if both["live_self_reports"].getInt() >= 2: break
        sleep(20)
        both = victim.observations()
      check both["live_self_reports"].getInt() == 2
      check both["accepted"].getInt() == 2

      # NO CloseSession AND NO LeaseFinished: the connection just goes.
      attacker.close()

      var survivor = victim.observations()
      for _ in 0 ..< 200:
        if survivor["live_self_reports"].getInt() <= 1: break
        sleep(20)
        survivor = victim.observations()
      check survivor["live_self_reports"].getInt() == 1
      check survivor["self_cpu_pct"].getFloat() == honestCpu
      check survivor["self_rss_bytes"].getInt() == honestRss

      # THE ORDINARY EXIT, asserted with the session STILL OPEN. Finishing
      # and releasing a lease must drop that lease's figures on its own; if
      # only the session teardown reaped them, `self_*` would grow across
      # every execution of a long-lived client and drive `foreign_*` to the
      # clamp — the same leak as the crash case, just slower.
      victimLease.finish(outcome = leaseFinishSucceeded)
      victimLease.release()
      var settledAfterRelease = victim.observations()
      for _ in 0 ..< 200:
        if settledAfterRelease["live_self_reports"].getInt() == 0: break
        sleep(20)
        settledAfterRelease = victim.observations()
      check settledAfterRelease["live_self_reports"].getInt() == 0
      check settledAfterRelease["self_cpu_pct"].getFloat() == 0.0
      # AND IT WAS THE ORDINARY EXIT, not the crash one. The reaper's
      # counter must still read exactly the ONE report the attacker's
      # session close took with it: a session that is alive has not been
      # reclaimed, and a release that quietly went through the reclamation
      # path would pass the assertion above for the wrong reason.
      check settledAfterRelease["self_reports_reaped"].getInt() == 1

      victimSession.closeSession()
      victim.close()
    finally:
      daemon.stop()

  # -------------------------------------------------------------------------
  # REFUSAL: a malformed report is rejected whole, never applied in part
  # -------------------------------------------------------------------------

  test "a damaged or oversized report is refused entirely, leaving no half-state":
    let root = scratchRoot("bad")
    defer: removeDir(root)
    let socketPath = rendezvousDir(root) / "d.sock"
    let state = hostStateDir(root)

    putEnv("RUNQUOTA_SOCKET", socketPath)
    var daemon = startDaemon(socketPath,
      ["--host-identity-file", state / "host-id"])
    try:
      var client = connectDefault()
      var session = client.registerSession("m13-malformed", "0.1.0")
      var lease = session.requestLease(resourceRequest(
        "m13-malformed-exec", milliCpu(1000),
        bytes(256'u64 * 1024'u64 * 1024'u64)))
      check lease.active
      lease.markStarting()
      lease.markRunning()
      lease.reportObservation(CrashCpuMilliPct, CrashRssBytes,
        uint64(unixMillisNow()))

      var settled = client.observations()
      for _ in 0 ..< 100:
        if settled["accepted"].getInt() >= 1: break
        sleep(20)
        settled = client.observations()
      check settled["accepted"].getInt() == 1
      let honestCpu = settled["self_cpu_pct"].getFloat()
      let honestRss = settled["self_rss_bytes"].getInt()

      let wellFormed = encodeLeaseObservation(LeaseObservationMessage(
        sessionId: session.id,
        leaseId: lease.id,
        cpuMilliPct: 1_234_000'u32,
        rssBytes: 88_000_000_000'u64,
        sampledAtUnixMillis: uint64(unixMillisNow())))

      # FOUR DAMAGED FRAMES, chosen so that a decoder applying fields as it
      # reads them would get progressively further into the message. The
      # third truncation has already yielded a session id, a lease id and a
      # CPU figure by the time it fails, which is the state "partially
      # stored" actually means.
      var damaged: seq[string] = @[
        wellFormed[0 ..< 8],        # session id only
        wellFormed[0 ..< 16],       # + lease id
        wellFormed[0 ..< wellFormed.len - 1], # + cpu, + rss, short time
        wellFormed & "\x7f\x7f\x7f" # trailing bytes
      ]
      # AND ONE THAT IS WELL-FORMED BUT LIES ABOUT WHEN IT WAS TAKEN. A
      # frame the decoder accepts and the rule does not: this is the arm a
      # decode-only refusal would miss entirely.
      damaged.add(encodeLeaseObservation(LeaseObservationMessage(
        sessionId: session.id,
        leaseId: lease.id,
        cpuMilliPct: 1_234_000'u32,
        rssBytes: 88_000_000_000'u64,
        sampledAtUnixMillis: uint64(unixMillisNow() + 600_000))))

      # EVERYTHING FROM HERE IS WATCHED FROM A SECOND CONNECTION, and that
      # is load-bearing rather than tidy. The daemon must write NOTHING
      # back on the connection the reports arrived on, and an inspection
      # request issued on that same connection would destroy the evidence:
      # `readResponse` files a frame whose request id it did not ask for
      # into `responseBuffer` and reads on, so a stray error frame is
      # invisible to every client-library call and to every later request.
      # Watching over the reporting connection made the one-way claim
      # unfalsifiable -- a daemon that answered every refusal with an error
      # frame passed this arm unchanged.
      var watcher = connectDefault()

      for i, payload in damaged:
        client.connection.sendFrame(encodeFrame(rqLeaseObservation,
          FrameFlagRequest, 8_000_000'u64 + uint64(i), payload))

      var after = watcher.observations()
      for _ in 0 ..< 200:
        if after["rejected"].getInt() >= damaged.len: break
        sleep(20)
        after = watcher.observations()

      check after["rejected"].getInt() == damaged.len
      check after["accepted"].getInt() == 1
      check after["live_self_reports"].getInt() == 1
      # NOT ONE FIELD OF ANY OF THEM LANDED.
      check after["self_cpu_pct"].getFloat() == honestCpu
      check after["self_rss_bytes"].getInt() == honestRss

      # AND THE DAEMON SAID NOTHING BACK, asserted on the RAW connection.
      # `rqLeaseObservation` is one-way: §"Write Path" forbids an
      # observation from introducing an additional round trip and OS-1
      # forbids it from blocking the work being observed, so a refusal is
      # COUNTED (above) and never reported. Every one of the frames sent
      # here has been counted by now -- four that would not decode and one
      # the sample-time rule refused, so both refusal branches have run --
      # and there must be no frame of any kind left on the wire. A reply
      # would be the round trip, and a frame a later request has to step
      # over.
      #
      # The extra wait is because the count and the write are not ordered
      # with respect to each other: a daemon that incremented the counter
      # first and wrote afterwards would otherwise be read too early.
      sleep(300)
      var stray: RqspFrame
      check not client.connection.receiveFrame(stray, 500)

      # AND THE CONNECTION IS STILL GOOD. A malformed observation must cost
      # the observation and nothing else: it must not close the session,
      # and the next real request must get its own answer.
      lease.finish(outcome = leaseFinishSucceeded)
      lease.release()
      session.closeSession()
      check client.daemonStatus().totalFinished >= 1'u64
      watcher.close()
      client.close()
    finally:
      daemon.stop()

  # -------------------------------------------------------------------------
  # THE CRASH EXIT: a client that dies mid-report leaks nothing
  # -------------------------------------------------------------------------

  test "a client SIGKILLed mid-execution leaves no self figures and no half-row":
    # THE FIXTURE IS A REAL KILLED PROCESS. This is M11's deferral (1) in
    # its dangerous form: `SelfReport` had no timestamp, no TTL and no
    # liveness handle, and its only exits were an explicit end or a
    # wholesale clear — so a client that reported and never came back
    # leaked its figures into `self_*` for the daemon's whole lifetime,
    # understating every later `foreign_*` until the clamp pinned it to
    # zero. Nothing about that is visible in the data.
    let root = scratchRoot("kill")
    defer: removeDir(root)
    let socketPath = rendezvousDir(root) / "d.sock"
    let state = hostStateDir(root)
    let expectedDb = state / "observations.sqlite3"
    let readyPath = root / "child-ready"

    putEnv("RUNQUOTA_SOCKET", socketPath)
    var daemon = startDaemon(socketPath,
      ["--host-identity-file", state / "host-id"])
    var child: Process = nil
    try:
      var watcher = connectDefault()

      putEnv(CrashClientEnv, socketPath)
      putEnv(CrashReadyEnv, readyPath)
      child = startProcess(getAppFilename(), options = {poStdErrToStdOut})
      delEnv(CrashClientEnv)
      delEnv(CrashReadyEnv)

      var ready = false
      for _ in 0 ..< 600:
        if fileExists(readyPath):
          ready = true
          break
        sleep(25)
      check ready

      # THE STATE THE LEAK LIVES IN, ASSERTED BEFORE THE KILL. Without
      # this, "no live reports afterwards" is satisfied by a report that
      # never arrived, and the whole test proves nothing.
      var live = watcher.observations()
      for _ in 0 ..< 200:
        if live["live_self_reports"].getInt() >= 1: break
        sleep(20)
        live = watcher.observations()
      check live["accepted"].getInt() == 1
      check live["live_self_reports"].getInt() == 1
      check live["self_cpu_pct"].getFloat() == observedCpuPct(CrashCpuMilliPct)
      check live["self_reports_reaped"].getInt() == 0

      # NO GOODBYE. SIGKILL: no LeaseFinished, no CloseSession, no
      # unwinding, nothing the client could have done on its way out.
      child.kill()
      discard child.waitForExit(5000)
      check not child.running

      var reaped = watcher.observations()
      for _ in 0 ..< 400:
        if reaped["self_reports_reaped"].getInt() >= 1: break
        sleep(25)
        reaped = watcher.observations()

      # THE CRASH EXIT FIRED, and the column it defends is back to zero.
      check reaped["self_reports_reaped"].getInt() == 1
      check reaped["live_self_reports"].getInt() == 0
      check reaped["self_cpu_pct"].getFloat() == 0.0
      check reaped["self_rss_bytes"].getInt() == 0

      # AND NO HALF-ROW. The execution never finished, so no `executions`
      # row may exist for it: a row invented from a lease the daemon
      # reclaimed would be a duration nobody measured. The `runs` row the
      # session opened stays, because a session really was registered.
      sleep(300)
      let store = openObservationStore(expectedDb)
      check store.captureEnabled
      check store.readExecutions().len == 0
      check store.readRuns().len == 1

      # And the daemon is still serving.
      check watcher.daemonStatus().activeSessions >= 0'u32
      watcher.close()
    finally:
      if child != nil:
        if child.running:
          child.kill()
          discard child.waitForExit(5000)
        child.close()
      daemon.stop()

  # -------------------------------------------------------------------------
  # DEGRADATION: the store becomes unwritable underneath a running daemon
  # -------------------------------------------------------------------------

  test "a store that turns unwritable mid-flight degrades and never fails a client":
    # A FIXTURE THE HAPPY PATH CANNOT CONSTRUCT. M9 covers a store that is
    # already corrupt when the daemon opens it; this is the other half —
    # a store that was healthy at startup, was written to successfully, and
    # then stopped accepting writes while the daemon was serving. OS-4 says
    # that must degrade to no capture, and OS-1 says it must not perturb
    # the work being observed, so the client's execution has to complete
    # normally with nobody telling it anything went wrong.
    let root = scratchRoot("ro")
    defer: removeDir(root)
    let socketPath = rendezvousDir(root) / "d.sock"
    let state = hostStateDir(root)
    let dbPath = state / "observations.sqlite3"

    putEnv("RUNQUOTA_SOCKET", socketPath)
    var daemon = startDaemon(socketPath,
      ["--host-identity-file", state / "host-id"])
    try:
      var client = connectDefault()
      # HEALTHY FIRST, so the failure below is a change of state rather
      # than a store that never worked.
      discard client.completeOneExecution("healthy")
      let before = waitForExecutions(dbPath, 1)
      check before.len == 1
      check client.observations()["write_failures"].getInt() == 0

      # THE STORE STOPS ACCEPTING WRITES. Read-only on the database and on
      # its write-ahead log, so `sqlite3` fails the transaction rather than
      # the daemon failing to find the file — a missing file is the M9 case
      # and this one is not.
      for suffix in ["", "-wal", "-shm"]:
        if fileExists(dbPath & suffix):
          setFilePermissions(dbPath & suffix, {fpUserRead})
      setFilePermissions(state, {fpUserRead, fpUserExec})

      # THE CLIENT MUST NOT NOTICE. Every call below would raise on any
      # error the daemon reported, so completing at all is the assertion.
      discard client.completeOneExecution("degraded-one")
      discard client.completeOneExecution("degraded-two")
      check client.daemonStatus().totalFinished >= 3'u64

      var degraded = client.observations()
      for _ in 0 ..< 200:
        # BOTH COUNTERS ARE WAITED ON, not just the first. The writer
        # drains in batches, so `write_failures` can reach one while the
        # second row is still queued -- and a loop that exited on the
        # first counter and then asserted the second is a race that fails
        # about once in a dozen runs on a loaded host. It was observed
        # doing exactly that.
        if degraded["write_failures"].getInt() >= 1 and
            degraded["dropped"].getInt() >= 2: break
        sleep(25)
        degraded = client.observations()
      # THE LOSS IS COUNTED, which is OS-2: a window that lost rows must be
      # distinguishable from one that had none.
      check degraded["write_failures"].getInt() >= 1
      check degraded["dropped"].getInt() >= 2

      # And admission is untouched.
      discard client.completeOneExecution("degraded-three")
      client.close()

      setFilePermissions(state, {fpUserRead, fpUserWrite, fpUserExec})
      for suffix in ["", "-wal", "-shm"]:
        if fileExists(dbPath & suffix):
          setFilePermissions(dbPath & suffix, {fpUserRead, fpUserWrite})
      # THE ROWS THAT WERE ALREADY THERE ARE STILL THERE AND STILL RIGHT.
      # Degradation loses what it could not write; it must not damage what
      # it had (OS-3).
      let after = openObservationStore(dbPath).readExecutions()
      check after.len == 1
      check after[0].executionId == before[0].executionId
      check after[0].durationMillis == before[0].durationMillis
    finally:
      setFilePermissions(state, {fpUserRead, fpUserWrite, fpUserExec})
      for suffix in ["", "-wal", "-shm"]:
        if fileExists(dbPath & suffix):
          setFilePermissions(dbPath & suffix, {fpUserRead, fpUserWrite})
      daemon.stop()
