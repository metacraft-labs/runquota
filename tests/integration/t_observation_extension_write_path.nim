## M17's enabling half: a CLIENT declares its own extension and attaches
## rows to its own executions, over the socket.
##
## WHY THIS EXISTS AT ALL, AND IT IS A FINDING ABOUT M12. M12 built the
## extension mechanism as a STORE API and gated it against a synthetic
## extension declared in the daemon's own process. M13a then gave extension
## rows a way OUT over the socket and none in. A real product cannot use an
## in-process API: `runquotad` is the only sanctioned reader and the only
## writer, and no client may open the database file -- so before this file's
## subject existed, the only route for a product to populate its own
## extension was the one thing the boundary forbids. The MECHANISM was not
## widened to fit a client; a transport was added for the mechanism that
## already existed, and the four storage classes cross it unchanged.
##
## NO MOCKS. Every arm runs the real ``runquotad`` binary over a real
## Unix-domain socket, through the real RQSP client library, against the
## real SQLite store the daemon wrote.
##
## MOST OF WHAT IS ASSERTED HERE IS A REFUSAL, deliberately. The write path
## is one-way: a refused row is never reported to its sender, so the only
## way a refusal can be observed at all is through the counter the daemon
## publishes -- and a refusal nobody can observe is a refusal nobody can
## test. Each arm below produces a fixture a WELL-BEHAVED CLIENT CANNOT
## PRODUCE: a row naming another session's lease, a row whose value count
## disagrees with its column count, a storage class the daemon has no name
## for, a row for an extension that was never declared.

import std/[json, options, os, osproc, posix, streams, strutils, times,
    unittest]

from runquota_ipc import endpointDirectoryPermissions
import runquota_client
import runquota_codec
import runquota_core
import runquota_observation_store
import runquota_protocol
import daemon_binary

const
  ProbeExtension = "m17_probe"
  ProbeKey = "m17-write-path"
  probeDdl = """
create table ext_m17_probe (
  host_id text not null,
  execution_id text not null,
  probe_label text,
  probe_count integer,
  probe_ratio real,
  primary key (host_id, execution_id),
  foreign key (host_id, execution_id)
    references executions(host_id, execution_id)
);
"""
  MiB = 1024'u64 * 1024'u64

proc scratchRoot(name: string): string =
  result = getTempDir() / ("rq-x-" & $getCurrentProcessId() & "-" & name)
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

proc socketIsBound(path: string): bool =
  var info: Stat
  lstat(path.cstring, info) == 0 and S_ISSOCK(info.st_mode)

type DaemonHandle = object
  process: Process

proc startDaemon(socketPath, identityFile: string): DaemonHandle =
  let process = startProcess(daemonPath(),
    args = @["--socket", socketPath,
             "--host-identity-file", identityFile,
             "--ambient-sample-interval-millis", "0"],
    options = {poStdErrToStdOut})
  for _ in 0 ..< 400:
    if socketIsBound(socketPath): break
    sleep(25)
  for _ in 0 ..< 3:
    discard process.outputStream.readLine()
  DaemonHandle(process: process)

proc stop(handle: var DaemonHandle) =
  if handle.process.running:
    handle.process.terminate()
    discard handle.process.waitForExit(5000)
  if handle.process.running:
    handle.process.kill()
    discard handle.process.waitForExit(5000)
  handle.process.close()

proc completeOneExecution(session: var RunQuotaSession;
                          statsKey: string): uint64 =
  ## Run one lease to completion and return its id. RELEASED at the end,
  ## exactly as a well-behaved client does -- which is what makes the
  ## lease table useless as an ownership check afterwards, and is the
  ## reason the daemon remembers the session beside the execution id.
  var request = resourceRequest(statsKey, milliCpu(1000), bytes(64'u64 * MiB))
  request.commandStatsId = statsKey
  var lease = session.requestLease(request)
  doAssert lease.active
  result = lease.id.value
  lease.markStarting()
  lease.markRunning(childProcessId = uint64(getCurrentProcessId()))
  lease.finish(outcome = succeeded(),
    peakMemoryBytes = 1_000_000'u64, processCount = 1'u32)
  lease.release()

proc observationCounters(client: var RunQuotaClient): JsonNode =
  parseJson(client.inspectionJson("observations")){"observations"}

# ---------------------------------------------------------------------------
# A WEDGE MUST REPORT ITSELF, because the subject below is a wedge.
# ---------------------------------------------------------------------------
#
# The guard the "no recorded execution" arm exists to prove is what stands
# between an unrecognised lease id and an index into a table that does not
# hold that key. WITHOUT IT THE ARM DOES NOT GO RED -- it HANGS: the raising
# request takes the connection's worker down while its socket stays open, so
# every later RQSP call blocks forever on a peer that will never answer.
# Measured on macOS: with the guard removed the binary was still sitting in
# that arm at 300 s and needed SIGKILL.
#
# ``scripts/run_tests.sh`` runs each binary with NO per-test timeout, so a
# binary in that state stops the entire suite rather than failing one test --
# the exact shape this campaign has already lost a run to. A deadline thread
# turns it back into an ordinary, attributable red. It is armed only around
# the calls that can wedge and is generous enough (90 s against an arm that
# takes about eleven) that it can never fire on a slow but healthy host.
var wedgeDeadline = 0.0
var wedgeArmed = false

proc wedgeGuard(ignored: int) {.thread.} =
  while wedgeArmed:
    if epochTime() >= wedgeDeadline:
      echo "  [WEDGED] the daemon stopped answering RQSP after a refused " &
        "extension row; a refusal must never cost the coordinator"
      quit(1)
    sleep(200)

template withWedgeDeadline(seconds: float; body: untyped) =
  wedgeDeadline = epochTime() + seconds
  wedgeArmed = true
  var wedgeThread: Thread[int]
  createThread(wedgeThread, wedgeGuard, 0)
  try:
    body
  finally:
    wedgeArmed = false
    joinThread(wedgeThread)

proc probeDeclaration(): tuple[id, owner: string; version: int64;
    ladder: seq[string]] =
  (id: ProbeExtension, owner: "m17-test", version: 1'i64,
   ladder: @[probeDdl])

proc declareProbe(session: var RunQuotaSession): string =
  let d = probeDeclaration()
  session.declareExtension(d.id, d.owner, d.version, d.ladder)

proc waitForProbeRows(path: string; atLeast: int64): int64 =
  for _ in 0 ..< 200:
    let store = openObservationStore(path)
    if store.captureEnabled:
      result = store.extensionRowCount(ProbeExtension)
      if result >= atLeast:
        return
    sleep(50)

suite "observation_extension_write_path":

  test "a client declares its extension and attaches a row to its execution":
    let root = scratchRoot("ok")
    defer: removeDir(root)
    let socketPath = rendezvousDir(root) / "d.sock"
    let state = hostStateDir(root)
    let dbPath = state / "observations.sqlite3"
    check fileExists(daemonPath())
    putEnv("RUNQUOTA_SOCKET", socketPath)
    var daemon = startDaemon(socketPath, state / "host-id")
    try:
      var client = connectDefault()
      var session = client.registerSession("m17-writer", "0.1.0")
      check session.declareProbe() == ""

      let leaseId = session.completeOneExecution(ProbeKey)
      # ALL FOUR STORAGE CLASSES CROSS THE WIRE, which is what makes the
      # transport as expressive as the mechanism rather than as expressive
      # as its first client happened to need.
      session.recordExtensionRow(leaseId, ProbeExtension, 1,
        ["probe_label", "probe_count", "probe_ratio"],
        [wireText("attached"), wireInt(42), wireReal(0.5)])

      check waitForProbeRows(dbPath, 1) == 1
      let counters = client.observationCounters()
      check counters{"extension_rows"}.getBiggestInt() == 1
      check counters{"extension_rows_refused"}.getBiggestInt() == 0

      # JOINED TO THE SPINE, and read back through the store's own reader.
      let store = openObservationStore(dbPath)
      let values = store.readExtensionColumns(ProbeExtension,
        ["probe_label", "probe_count", "probe_ratio"])
      check values.len == 1
      check values[0][0] == "attached"
      check values[0][1] == "42"
      check values[0][2] == "0.5"

      client.close()
    finally:
      daemon.stop()

  test "a row naming another session's lease is refused":
    # THE FIXTURE A WELL-BEHAVED CLIENT CANNOT PRODUCE. One host-wide
    # daemon holds every user's executions; a row accepted here would
    # attach one client's facts to another's execution, and the store
    # would then answer a query with a fact nobody measured about that
    # work. Two sessions on ONE connection is the mildest form of the
    # violation -- the connection genuinely owns both -- so an
    # implementation that checked only "does this connection own the
    # session it named" passes every other arm and fails this one.
    let root = scratchRoot("own")
    defer: removeDir(root)
    let socketPath = rendezvousDir(root) / "d.sock"
    let state = hostStateDir(root)
    let dbPath = state / "observations.sqlite3"
    putEnv("RUNQUOTA_SOCKET", socketPath)
    var daemon = startDaemon(socketPath, state / "host-id")
    try:
      var client = connectDefault()
      var owner = client.registerSession("m17-owner", "0.1.0")
      var intruder = client.registerSession("m17-intruder", "0.1.0")
      check owner.declareProbe() == ""

      let leaseId = owner.completeOneExecution(ProbeKey)
      # The intruder names the OWNER's lease under its OWN session id.
      intruder.recordExtensionRow(leaseId, ProbeExtension, 1,
        ["probe_label"], [wireText("stolen")])

      # Give the writer several drain ticks: "the row never appeared" must
      # be a statement about the refusal and not about timing.
      sleep(400)
      check waitForProbeRows(dbPath, 1) == 0
      let counters = client.observationCounters()
      check counters{"extension_rows"}.getBiggestInt() == 0
      check counters{"extension_rows_refused"}.getBiggestInt() == 1

      # NON-VACUITY: the very same row, sent by the session that owns the
      # lease, IS accepted -- so the refusal above is about ownership and
      # not about the row being malformed or the extension unusable.
      owner.recordExtensionRow(leaseId, ProbeExtension, 1,
        ["probe_label"], [wireText("mine")])
      check waitForProbeRows(dbPath, 1) == 1
      check client.observationCounters(){"extension_rows"}.getBiggestInt() == 1

      client.close()
    finally:
      daemon.stop()

  test "a row from a connection that never registered the session is refused":
    # THE STRONGER FORM OF THE OWNERSHIP VIOLATION, and the one the
    # intruder arm below cannot reach. There both sessions live on ONE
    # connection, so "does this connection own the session it named" is
    # satisfied and only the per-execution check can refuse. Here a
    # SECOND CONNECTION names a session id it never registered -- the
    # session exists, the lease exists, and the only thing wrong is who is
    # speaking. An implementation checking solely the recorded session id
    # would accept it, because the id the intruder supplies is the right
    # one.
    let root = scratchRoot("conn")
    defer: removeDir(root)
    let socketPath = rendezvousDir(root) / "d.sock"
    let state = hostStateDir(root)
    let dbPath = state / "observations.sqlite3"
    putEnv("RUNQUOTA_SOCKET", socketPath)
    var daemon = startDaemon(socketPath, state / "host-id")
    try:
      var owner = connectDefault()
      var ownerSession = owner.registerSession("m17-conn-owner", "0.1.0")
      check ownerSession.declareProbe() == ""
      let leaseId = ownerSession.completeOneExecution(ProbeKey)

      # A second connection, forging the owner's session id.
      var other = connectDefault()
      var otherSession = other.registerSession("m17-conn-other", "0.1.0")
      otherSession.id = ownerSession.id
      otherSession.recordExtensionRow(leaseId, ProbeExtension, 1,
        ["probe_label"], [wireText("forged")])

      sleep(400)
      check waitForProbeRows(dbPath, 1) == 0
      check owner.observationCounters(){
        "extension_rows_refused"}.getBiggestInt() == 1

      # NON-VACUITY: the identical row, from the connection that really
      # registered that session, is accepted -- so the refusal is about
      # the speaker and not about the row.
      ownerSession.recordExtensionRow(leaseId, ProbeExtension, 1,
        ["probe_label"], [wireText("genuine")])
      check waitForProbeRows(dbPath, 1) == 1

      other.close()
      owner.close()
    finally:
      daemon.stop()

  test "a row for a lease with no recorded execution is refused, not fatal":
    # THE LATE ROW, AND THE ONE ARM THAT FOUND A LIVE DEFECT. A client
    # sends its rows when the facts are complete, which for a build system
    # is long after the lease finished -- so the daemon remembers a BOUNDED
    # number of finished leases and a row arriving after its entry aged out
    # has no spine row to join to. Nothing a well-behaved client does
    # produces that state, which is why the check guarding it went
    # untested until a mutation removed it and the whole suite stayed
    # green: no arm ever named a lease the daemon had never recorded.
    #
    # TWO THINGS ARE ASSERTED, and the second is why this is not merely a
    # counter check. Refusing is correct; SURVIVING is essential. Without
    # the guard the daemon indexes a table by a key that is not in it, and
    # a client can take the host's lease coordinator down with one
    # one-way message it is never told was rejected.
    let root = scratchRoot("late")
    defer: removeDir(root)
    let socketPath = rendezvousDir(root) / "d.sock"
    let state = hostStateDir(root)
    let dbPath = state / "observations.sqlite3"
    putEnv("RUNQUOTA_SOCKET", socketPath)
    var daemon = startDaemon(socketPath, state / "host-id")
    try:
      var client = connectDefault()
      var session = client.registerSession("m17-late", "0.1.0")
      check session.declareProbe() == ""

      # A lease id the daemon never granted: there is no execution behind
      # it and there never was.
      session.recordExtensionRow(999_999'u64, ProbeExtension, 1,
        ["probe_label"], [wireText("orphan")])
      sleep(400)
      # EVERY CALL AFTER THE ORPHAN ROW IS ON A DEADLINE. This is the one
      # arm whose subject can leave the peer unable ever to answer, and an
      # unbounded RQSP read against such a peer is not a failing test but a
      # stopped suite. See ``wedgeGuard``.
      withWedgeDeadline(90.0):
        check waitForProbeRows(dbPath, 1) == 0
        let counters = client.observationCounters()
        check counters{"extension_rows"}.getBiggestInt() == 0
        check counters{"extension_rows_refused"}.getBiggestInt() == 1

        # STILL SERVING. The counter above can be read only from a daemon
        # that is still answering, so this is already implied -- but a real
        # lease afterwards proves the refusal left the coordinator's own
        # state intact rather than merely leaving it able to talk.
        let leaseId = session.completeOneExecution(ProbeKey)
        session.recordExtensionRow(leaseId, ProbeExtension, 1,
          ["probe_label"], [wireText("live")])
        check waitForProbeRows(dbPath, 1) == 1

      client.close()
    finally:
      daemon.stop()

  test "a row for an extension nobody declared is refused":
    let root = scratchRoot("undecl")
    defer: removeDir(root)
    let socketPath = rendezvousDir(root) / "d.sock"
    let state = hostStateDir(root)
    let dbPath = state / "observations.sqlite3"
    putEnv("RUNQUOTA_SOCKET", socketPath)
    var daemon = startDaemon(socketPath, state / "host-id")
    try:
      var client = connectDefault()
      var session = client.registerSession("m17-undeclared", "0.1.0")
      let leaseId = session.completeOneExecution(ProbeKey)
      # No declaration at all: there is no table to write into, and
      # creating one from a row's column list would mean RunQuota chose a
      # schema on the product's behalf.
      session.recordExtensionRow(leaseId, ProbeExtension, 1,
        ["probe_label"], [wireText("nowhere")])
      sleep(400)
      # ON A DEADLINE, for the same reason the late-row arm is: the check
      # this arm covers (``ewNotRegistered``) is the other one whose
      # removal makes the row RAISE rather than refuse, taking the
      # connection worker with it and leaving every later RQSP read
      # waiting on a peer that will never answer. Measured with the check
      # removed: still wedged at 600 s. See ``wedgeGuard``.
      withWedgeDeadline(90.0):
        check client.observationCounters(){
          "extension_rows_refused"}.getBiggestInt() == 1

        # NON-VACUITY: declare it, resend, and the same row lands.
        check session.declareProbe() == ""
        session.recordExtensionRow(leaseId, ProbeExtension, 1,
          ["probe_label"], [wireText("nowhere")])
        check waitForProbeRows(dbPath, 1) == 1

      client.close()
    finally:
      daemon.stop()

  test "a declaration from a connection that never registered the session is refused":
    # THE DECLARE-SIDE OWNERSHIP VIOLATION, AND IT WAS THE ONE VACUOUS
    # CLAUSE IN THIS FILE. Removing ``declareClientExtension``'s
    # ``ownsSession`` check left every other arm here green, for exactly
    # the reason this campaign keeps rediscovering: every arm declared
    # from the connection that had registered the session, so no arm could
    # reach the refusal.
    #
    # It matters more on this message than on a row. A declaration is DDL
    # against a HOST-WIDE store: it creates a table every user's rows will
    # sit beside, and the statements are the client's own, run verbatim.
    # A connection naming a session it never opened has no business
    # running one.
    let root = scratchRoot("declconn")
    defer: removeDir(root)
    let socketPath = rendezvousDir(root) / "d.sock"
    let state = hostStateDir(root)
    putEnv("RUNQUOTA_SOCKET", socketPath)
    var daemon = startDaemon(socketPath, state / "host-id")
    try:
      var owner = connectDefault()
      var ownerSession = owner.registerSession("m17-decl-owner", "0.1.0")

      # A SECOND CONNECTION FORGING THE OWNER'S SESSION ID -- the session
      # exists and the id is the right one; the only thing wrong is who is
      # speaking. The extension it names has never been registered, so a
      # daemon that let this through would CREATE the table on behalf of a
      # speaker that owns nothing.
      var other = connectDefault()
      var otherSession = other.registerSession("m17-decl-other", "0.1.0")
      otherSession.id = ownerSession.id
      check otherSession.declareExtension(ProbeExtension, "m17-test", 1,
        [probeDdl]) == "unknown-session"

      # NON-VACUITY, and it is the whole point: the IDENTICAL declaration
      # from the connection that really registered that session is
      # accepted. Without it the refusal above would be satisfied by a
      # daemon that refused every declaration.
      check ownerSession.declareProbe() == ""

      other.close()
      owner.close()
    finally:
      daemon.stop()

  test "a declaration naming a version its ladder cannot reach is refused":
    let root = scratchRoot("ver")
    defer: removeDir(root)
    let socketPath = rendezvousDir(root) / "d.sock"
    let state = hostStateDir(root)
    putEnv("RUNQUOTA_SOCKET", socketPath)
    var daemon = startDaemon(socketPath, state / "host-id")
    try:
      var client = connectDefault()
      var session = client.registerSession("m17-version", "0.1.0")
      # Version 3 with one step: there is no route to that version, so
      # accepting it would mean writing rows into a shape that is not the
      # one the client described while the registry claims otherwise.
      let refusal = session.declareExtension(ProbeExtension, "m17-test", 3,
        [probeDdl])
      check refusal == "refused-unstorable-version"
      # AND THE CONVERSE, without which the check above would pass on an
      # implementation that refused everything.
      check session.declareProbe() == ""
      client.close()
    finally:
      daemon.stop()

suite "observation_extension_write_path_codec":

  test "a row whose value count disagrees with its column count is refused":
    # THE ONE THE TRANSPORT MUST CATCH. The store indexes `values` by the
    # position of `columns`, so a short row is an out-of-bounds read and a
    # long one silently drops the extras into a table the client believes
    # it filled. Neither is a shape a well-behaved client can send, which
    # is exactly why nothing else would ever reach the check.
    var short = ExtensionRowMessage(extensionId: ProbeExtension,
      schemaVersion: 1, columns: @["a", "b"], values: @[wireText("x")])
    check extensionRowRefusal(short).len > 0
    var long = ExtensionRowMessage(extensionId: ProbeExtension,
      schemaVersion: 1, columns: @["a"],
      values: @[wireText("x"), wireText("y")])
    check extensionRowRefusal(long).len > 0
    var matched = ExtensionRowMessage(extensionId: ProbeExtension,
      schemaVersion: 1, columns: @["a"], values: @[wireText("x")])
    check extensionRowRefusal(matched) == ""

  test "a storage class the daemon has no name for is refused, not defaulted":
    # Defaulting an unknown class to text would write the wrong literal
    # into a column whose type the CLIENT chose. The frame is built by
    # hand because no encoder can emit this one.
    var w = writer()
    w.writeU64(1'u64)
    w.writeU64(7'u64)
    w.writeString(ProbeExtension)
    w.writeU32(1'u32)
    w.writeU32(1'u32)
    w.writeString("probe_label")
    w.writeU32(1'u32)
    w.writeU8(200'u8)          # not an ExtensionCellKind
    w.writeString("x")
    w.writeU64(0'u64)
    w.writeU64(0'u64)
    var decoded: ExtensionRowMessage
    check not decodeExtensionRow(w.data, decoded)

    # THE CONVERSE, so the check above is about the class and not about
    # the frame being malformed in some other way.
    var ok = writer()
    ok.writeU64(1'u64)
    ok.writeU64(7'u64)
    ok.writeString(ProbeExtension)
    ok.writeU32(1'u32)
    ok.writeU32(1'u32)
    ok.writeString("probe_label")
    ok.writeU32(1'u32)
    ok.writeU8(uint8(ord(extCellText)))
    ok.writeString("x")
    ok.writeU64(0'u64)
    ok.writeU64(0'u64)
    check decodeExtensionRow(ok.data, decoded)
    check decoded.values[0].kind == extCellText
    check decoded.values[0].text == "x"

  test "a batch emits an execution before the extension row that references it":
    # WHERE THE CODE ACTUALLY DOES THE DANGEROUS THING. `foreign_keys` is
    # on, so an extension insert placed before its parent's aborts the
    # whole transaction and takes the parent execution down with it.
    #
    # THIS WAS ASSERTED THROUGH THE DAEMON FIRST, AND THAT CHECK COULD NOT
    # FAIL. Reversing the two loops in `batchStatement` left every
    # end-to-end arm green: the lease finish is a round trip and the row
    # is a later one-way message, so a 25 ms drain tick reliably lands
    # between them and the parent is already committed by the time the
    # child is queued. The end-to-end path never produces the same-batch
    # case, so no threshold and no amount of polling would have caught it
    # -- only asserting on the statement the batch actually emits does.
    let execution = ExecutionRow(
      executionId: "exec-order-probe", hostId: "host-order-probe",
      hostProfileId: none(string), runId: "run-order-probe",
      commandStatsId: ProbeKey, leaseId: none(int64),
      startedAtUnixMillis: 1, finishedAtUnixMillis: 2, durationMillis: 1,
      exitStatus: 0, termination: tExited, attempt: 1, retryOf: none(string),
      peakRssBytes: 0, cpuUserMillis: none(int64), cpuSysMillis: none(int64),
      maxProcesses: 1, majorPageFaults: 0, ioReadBytes: none(int64),
      ioWriteBytes: none(int64), captureCompleteness: ccComplete,
      droppedObservations: 0, ownerUid: none(int64))
    let childInsert =
      "insert into ext_m17_probe (host_id, execution_id, probe_label) " &
      "values ('host-order-probe', 'exec-order-probe', 'ordered');"
    let sql = batchStatement([], [execution], [childInsert])
    let parentAt = sql.find("insert into executions")
    let childAt = sql.find(childInsert)
    # NON-VACUITY: both really are in this batch, so the comparison below
    # is an ordering statement and not a statement about one being absent.
    check parentAt >= 0
    check childAt >= 0
    check parentAt < childAt
    # And both are inside the one transaction, so "the parent is there"
    # cannot be satisfied by a batch that committed it separately.
    check sql.find("begin immediate;") < parentAt
    check childAt < sql.rfind("commit;")

  test "every storage class survives the round trip unchanged":
    let msg = ExtensionRowMessage(
      sessionId: sessionId(3), leaseId: leaseId(9),
      extensionId: ProbeExtension, schemaVersion: 2,
      columns: @["a", "b", "c", "d"],
      values: @[wireNull(), wireText("t"), wireInt(-17), wireReal(2.25)])
    var decoded: ExtensionRowMessage
    check decodeExtensionRow(encodeExtensionRow(msg), decoded)
    check decoded.columns == msg.columns
    check decoded.values[0].kind == extCellNull
    check decoded.values[1].text == "t"
    check decoded.values[2].number == -17
    check wireRealValue(decoded.values[3]) == 2.25
    check decoded.leaseId.value == 9'u64
    check decoded.schemaVersion == 2'u32
