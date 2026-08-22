## M13c: the scope boundaries enforced by the REAL daemon, over a real
## Unix socket, against real directories on the real filesystem.
##
## `t_scope_boundary_rules` asserts the rules. This file asserts that the
## daemon and the protocol actually apply them, which is a different claim:
## a correct predicate nobody calls enforces nothing.
##
## NEGATIVE CONTROLS ARE THE GATE. A test that starts a daemon and observes
## that it still starts proves nothing — that passes with the fix and
## without it. So every clause here is a refusal asserted AS a refusal:
## a real `runquotad` that exits non-zero and says which path and which
## mode it refused, a real client attach that raises rather than connects,
## and a real Hello that is answered with an error rather than a HelloOk.
## Each refusal is paired with the corresponding acceptance, so a build
## that refused everything would fail too.
##
## No mocks. The daemon is the built binary, the lease is taken by the
## built CLI, and `owner_uid` is read back out of the SQLite file the
## daemon wrote.
##
## WHAT IS NOT COVERED HERE, stated rather than implied: the spoofed-owner
## refusal below is driven from THIS uid declaring a uid it does not own,
## which is the attack in full. What a single-uid host cannot do is have a
## SECOND real user connect and be attributed correctly; see the milestone
## report for that clause's status.

import std/[options, os, osproc, posix, streams, strutils, unittest]

import runquota_core
import runquota_ipc
import runquota_observation_store
import runquota_protocol

proc scratchDir(name: string): string =
  # Short on purpose: a Unix-domain socket path is capped at ~104 bytes.
  result = getTempDir() / ("rq-m13ce-" & name & "-" & $getCurrentProcessId())
  removeDir(result)
  createDir(result)
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})

proc daemonPath(): string =
  getCurrentDir() / "build" / "bin" / "runquotad"

proc cliPath(): string =
  getCurrentDir() / "build" / "bin" / "runquota"

proc modeOf(path: string): int =
  var info: Stat
  if lstat(path.cstring, info) != 0:
    return -1
  int(info.st_mode) and 0o7777

proc ownerOf(path: string): int64 =
  var info: Stat
  if lstat(path.cstring, info) != 0:
    return -1
  int64(info.st_uid)

proc pathPresent(path: string): bool =
  ## Anything at all at `path`. `os.fileExists` answers only for REGULAR
  ## files, so it is false for a bound Unix-domain socket and would make
  ## "nothing was left behind" vacuously true.
  var info: Stat
  lstat(path.cstring, info) == 0

proc socketExists(path: string): bool =
  var info: Stat
  lstat(path.cstring, info) == 0 and S_ISSOCK(info.st_mode)

proc foreignOwnedDirectory(): string =
  ## Owned by another uid and NOT group- or world-writable, so the
  ## ownership check is the only one that can refuse it.
  for candidate in ["/usr", "/", "/etc", "/bin"]:
    var info: Stat
    if lstat(candidate.cstring, info) != 0:
      continue
    if not S_ISDIR(info.st_mode):
      continue
    if int64(info.st_uid) == int64(getuid()):
      continue
    if (int(info.st_mode) and 0o022) != 0:
      continue
    return candidate
  ""

type RefusedStart = object
  exitedOnItsOwn: bool
  exitCode: int
  output: string

proc startAndExpectExit(socketPath: string): RefusedStart =
  ## Runs the real daemon and waits, WITH A BOUND, for it to be gone.
  ##
  ## The bound is the whole point. A daemon that does NOT refuse serves
  ## forever, so an unbounded `readAll` or `waitForExit` here would make
  ## this negative control HANG rather than go red — and a control that
  ## hangs is not a control, it is a test that never reports. (Verified:
  ## the first version of this helper did exactly that under the mutation
  ## that removes enforcement.) A daemon still running after the bound is
  ## killed, its whole process group with it, and reported as a failure to
  ## refuse.
  let process = startProcess(
    daemonPath(),
    args = ["--socket", socketPath],
    options = {poStdErrToStdOut}
  )
  var exited = false
  for _ in 0 ..< 200:
    if not process.running:
      exited = true
      break
    sleep(25)
  var code = -1
  if exited:
    code = process.waitForExit()
  else:
    # Kill the GROUP: a direct kill of the daemon can strand anything it
    # spawned on pid 1, and this suite must leave nothing behind.
    discard posix.kill(Pid(-process.processID), SIGKILL)
    process.terminate()
    discard process.waitForExit(5000)
    if process.running:
      process.kill()
      discard process.waitForExit(5000)
  # Read only after the child is gone, so a full pipe cannot block it and
  # an unread pipe cannot block us.
  let output = process.outputStream.readAll()
  check not process.running
  process.close()
  RefusedStart(exitedOnItsOwn: exited, exitCode: code, output: output)

type DaemonHandle = object
  process: Process
  startupLines: seq[string]

proc waitForSocket(socketPath: string) =
  for _ in 0 ..< 400:
    if socketExists(socketPath):
      return
    sleep(25)

proc startDaemon(socketPath, observationDb, identityFile: string):
    DaemonHandle =
  let process = startProcess(
    daemonPath(),
    args = ["--socket", socketPath, "--observation-db", observationDb,
            "--host-identity-file", identityFile],
    options = {poStdErrToStdOut}
  )
  waitForSocket(socketPath)
  var lines: seq[string] = @[]
  # Exactly three startup lines whenever a store path was given, then the
  # daemon goes quiet. Reading precisely three cannot deadlock against it.
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
  check not handle.process.running
  handle.process.close()

proc helloFrame(userId: uint64): string =
  encodeFrame(rqHello, FrameFlagRequest, 1'u64, encodeHello(HelloMessage(
    clientName: "m13c-scope-probe",
    clientVersion: "0.0.0",
    minProtocolMajor: RqspProtocolMajor,
    maxProtocolMajor: RqspProtocolMajor,
    processId: uint64(getCurrentProcessId()),
    userId: userId,
    desiredCapabilities: "m1-lease"
  )))

proc exchangeHello(socketPath: string; userId: uint64):
    tuple[kind: RqspMessageKind; diagnostic: Diagnostic] =
  ## Speaks the wire protocol directly, because the shipped client always
  ## sends `getuid()` and therefore cannot express the attack: a client
  ## DECLARING an owner it does not own is the thing being refused.
  var connection = connectEndpoint(unixEndpoint(socketPath))
  try:
    connection.sendFrame(helloFrame(userId))
    var frame: RqspFrame
    var frameDiagnostic = okDiagnostic()
    check connection.receiveFrame(frame, frameDiagnostic, 5000)
    var error: ProtocolErrorMessage
    if frame.header.messageKind == rqError:
      check decodeProtocolError(frame.payload, error)
      return (frame.header.messageKind, error.diagnostic)
    (frame.header.messageKind, okDiagnostic())
  finally:
    connection.close()

proc waitForExecutionRows(path: string; atLeast: int): int =
  for _ in 0 ..< 100:
    let store = openObservationStore(path)
    if store.captureEnabled:
      result = store.readExecutions().len
      if result >= atLeast:
        return
    sleep(100)

suite "scope_boundary_enforcement_daemon_start":
  test "a real daemon REFUSES a pre-created world-writable endpoint directory":
    let root = scratchDir("wide")
    defer: removeDir(root)
    let dir = root / "endpoint"
    createDir(dir)
    setFilePermissions(dir, {
      fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupWrite, fpGroupExec,
      fpOthersRead, fpOthersWrite, fpOthersExec})
    check modeOf(dir) == 0o777
    let socketPath = dir / "runquotad.sock"

    let refused = startAndExpectExit(socketPath)
    # It refused ON ITS OWN. Without this the test would pass on a daemon
    # that had to be killed, which is the opposite of the claim.
    check refused.exitedOnItsOwn
    check refused.exitCode != 0
    check refused.exitCode == 3
    # Named, not opaque.
    check dir in refused.output
    check "0777" in refused.output
    check "0700" in refused.output
    # A refusal, not a fallback: nothing was bound and nothing was left
    # behind in a directory the daemon does not trust.
    check not pathPresent(socketPath)

  test "a real daemon REFUSES an endpoint directory owned by another uid":
    let foreign = foreignOwnedDirectory()
    check foreign.len > 0
    if foreign.len > 0:
      # The mode cannot be what refuses this one.
      check (modeOf(foreign) and 0o022) == 0
      let socketPath = foreign / ("rq-m13c-" & $getCurrentProcessId() & ".sock")
      let refused = startAndExpectExit(socketPath)
      check refused.exitedOnItsOwn
      check refused.exitCode == 3
      check foreign in refused.output
      check ("owned by uid " & $ownerOf(foreign)) in refused.output
      check ("uid " & $getuid()) in refused.output
      # It refused before touching a path it has no business writing to.
      check not pathPresent(socketPath)

  test "a real daemon accepts a directory it created itself, at 0700":
    # The acceptance half. Without it, a build that refused every start
    # would satisfy both refusals above.
    let root = scratchDir("good")
    defer: removeDir(root)
    let dir = root / "endpoint"
    let socketPath = dir / "runquotad.sock"
    let dbPath = root / "observations.sqlite"
    let identityFile = root / "host-id"
    check fileExists(daemonPath())
    var daemon = startDaemon(socketPath, dbPath, identityFile)
    try:
      check daemon.startupLines[0].contains(socketPath)
      check dirExists(dir)
      check modeOf(dir) == 0o700
      check ownerOf(dir) == int64(getuid())
      check socketExists(socketPath)
    finally:
      daemon.stop()

suite "scope_boundary_enforcement_owner_uid":
  test "a client declaring somebody else's uid is REFUSED, and one declaring its own is not":
    let root = scratchDir("owner")
    defer: removeDir(root)
    let dir = root / "endpoint"
    let socketPath = dir / "runquotad.sock"
    let dbPath = root / "observations.sqlite"
    let identityFile = root / "host-id"
    var daemon = startDaemon(socketPath, dbPath, identityFile)
    try:
      let mine = uint64(getuid())
      # A uid this process demonstrably does not own. `mine + 1` on a
      # single-uid host is still a uid the kernel will not report for this
      # connection, which is the entire point: the daemon must believe the
      # kernel and not the client.
      let spoofed = mine + 1

      let refused = exchangeHello(socketPath, spoofed)
      check refused.kind == rqError
      check refused.diagnostic.code == diagDenied
      check ($spoofed) in refused.diagnostic.message
      check ($mine) in refused.diagnostic.message
      check "peer credentials" in refused.diagnostic.message
      check "MUST NOT be" in refused.diagnostic.detail

      # And the honest Hello is accepted, so the refusal above is about the
      # declared owner rather than about the probe's handshake.
      let accepted = exchangeHello(socketPath, mine)
      check accepted.kind == rqHelloOk
    finally:
      daemon.stop()

  test "owner_uid on an execution comes from peer credentials":
    let root = scratchDir("exec")
    defer: removeDir(root)
    let dir = root / "endpoint"
    let socketPath = dir / "runquotad.sock"
    let dbPath = root / "observations.sqlite"
    let identityFile = root / "host-id"
    check fileExists(cliPath())
    putEnv("RUNQUOTA_SOCKET", socketPath)
    var daemon = startDaemon(socketPath, dbPath, identityFile)
    try:
      check daemon.startupLines[1].contains("capture enabled")
      let leased = execProcess(
        cliPath(),
        args = ["acquire", "--cpu", "1000", "--mem", "64MB",
                "--label", "m13c-owner", "--",
                "/bin/echo", "m13c-owner-ok"],
        env = nil,
        options = {poStdErrToStdOut}
      )
      check leased.contains("m13c-owner-ok")

      check waitForExecutionRows(dbPath, 1) >= 1
      let store = openObservationStore(dbPath)
      check store.captureEnabled
      check store.schemaVersion == spineSchemaVersion
      let executions = store.readExecutions()
      check executions.len >= 1
      # The column exists and is populated with this uid.
      #
      # HONEST LIMIT, recorded here rather than left to be inferred: on a
      # SINGLE-UID host this value alone cannot distinguish "read from peer
      # credentials" from "read from the client's declaration", because the
      # shipped client declares its own uid and the refusal above makes any
      # other declaration impossible. The control for the SOURCE is the
      # spoofed-Hello refusal in the test above, not this equality.
      # Distinguishing them by the recorded value needs a second real uid.
      check executions[0].ownerUid.isSome
      check executions[0].ownerUid == some(int64(getuid()))
    finally:
      daemon.stop()
      delEnv("RUNQUOTA_SOCKET")

  test "owner_uid is NULL rather than 0 when it was never established":
    # 0 is root. A row that could not learn its owner must say so, because
    # a wrong owner is worse than an absent one: it attributes one user's
    # history to another, and root's at that.
    let root = scratchDir("null")
    defer: removeDir(root)
    let dbPath = root / "observations.sqlite"
    let store = openObservationStore(dbPath)
    check store.captureEnabled
    check store.insertHost(HostRow(hostId: "h1", createdAtUnixMillis: 1,
      lastBootId: "b1"))
    check store.insertRun(RunRow(runId: "r1", hostId: "h1", tool: "t",
      toolVersion: "1", invocationKind: "k", startedAtUnixMillis: 1,
      captureCompleteness: ccComplete, droppedObservations: 0))
    check store.insertExecution(ExecutionRow(executionId: "e1", hostId: "h1",
      runId: "r1", commandStatsId: "c1", startedAtUnixMillis: 1,
      finishedAtUnixMillis: 2, durationMillis: 1, exitStatus: 0,
      termination: tExited, attempt: 1, peakRssBytes: 1, maxProcesses: 1,
      majorPageFaults: 0, captureCompleteness: ccComplete,
      droppedObservations: 0, ownerUid: none(int64)))
    let rows = store.readExecutions()
    check rows.len == 1
    check rows[0].ownerUid.isNone
    let raw = runSqlite(dbPath,
      "select count(*) from executions where owner_uid is null;")
    check raw.ok
    check raw.output.strip() == "1"
