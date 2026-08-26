## M13a gate, the daemon half: ``runquotad`` answers queries over the
## SOCKET, and admission takes a client's estimate at face value.
##
## NO MOCKS, AND NOTHING SUBSTITUTED. Every arm runs the real ``runquotad``
## binary from ``build/bin``, a real Unix-domain socket, the real RQSP
## client library, and the real SQLite store the daemon wrote. The answers
## asserted on came back over the wire.
##
## THE CONSUMER IS SYNTHETIC, AND SAYS SO. The two consumers the
## specification names — ``repro stats`` (M18) and ``ct test stats`` (M21)
## — DO NOT EXIST YET. This file is the consumer: it drives the same
## interface they will, through ``runquota_client.queryStats``, and asserts
## what comes back. Nothing here pretends to exercise a downstream tool.
##
## WHY ROWS ARE ALSO WRITTEN DIRECTLY. The gate requires a store holding
## two hardware profiles and two owner uids, and neither is a state a
## well-behaved client can produce: one machine does not have two profiles
## current at once, and one test process does not run under two uids.
## Those rows are inserted through the store library — the same insert path
## the daemon uses — and everything READ in this file comes back over the
## socket. The direct writes are the fixture; they are never the answer.
##
## WHY THE DAEMON BINARY RATHER THAN ``initDaemon`` IN PROCESS. The same
## reason M10, M11 and M13 give: a mutation that only recompiles the test
## reports green while the code under test never executes.

import std/[options, os, osproc, posix, streams, strutils, unittest]

from runquota_ipc import endpointDirectoryPermissions
import runquota_client
import runquota_core
import runquota_observation_store
from runquota_observation_store/extensions as extensions import nil
import runquota_protocol

const
  RealKey = "m13a-real-socket-exec"
  HistoryKey = "m13a-wire-history"
  ZeroKey = "m13a-wire-zero"
  NeverKey = "m13a-wire-never-seen"
  EstimateKey = "m13a-estimate-key"
  FlushKey = "m13a-flush-key"
  FlushRounds = 6
    ## Six rounds because the thing under test closes a RACE WINDOW rather
    ## than a deterministic bug: the background writer drains every 25ms,
    ## and the finish-to-query round trip is sub-millisecond, so a daemon
    ## that did not flush would occasionally be rescued by a drain tick
    ## landing in the gap. Requiring every round to see its own execution
    ## makes that rescue have to happen six times running.
  OtherUid = 4042'i64
  ProbeExtensionId = "m13a_wire_probe"
  probeDdl = """
create table ext_m13a_wire_probe (
  host_id text not null,
  execution_id text not null,
  probe_label text,
  probe_count integer,
  primary key (host_id, execution_id),
  foreign key (host_id, execution_id)
    references executions(host_id, execution_id)
);
"""
  MiB = 1024'u64 * 1024'u64
  ObservedPeakBytes = 800'u64 * MiB
  LearnedConservativeBytes = 1000'u64 * MiB
    ## ``updateEstimateFromFinish`` inflates an observed peak by 25%% when
    ## the run neither hit a limit nor was OOM-killed. 800 MiB observed is
    ## therefore 1000 MiB learned, and the arms below are chosen so that
    ## number is far from every estimate they supply.
  SmallEstimateBytes = 4'u64 * MiB
  LargeEstimateBytes = 2000'u64 * MiB

# ---------------------------------------------------------------------------
# Fixture plumbing
# ---------------------------------------------------------------------------

proc scratchRoot(name: string): string =
  # Short on purpose: `Sockaddr_un_path_length` is 92 on macOS, so the whole
  # socket path budget is 91 characters and a plain macOS TMPDIR is 49.
  result = getTempDir() / ("rq-q-" & $getCurrentProcessId() & "-" & name)
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

proc daemonPath(): string =
  getCurrentDir() / "build" / "bin" / "runquotad"

proc socketIsBound(path: string): bool =
  var info: Stat
  lstat(path.cstring, info) == 0 and S_ISSOCK(info.st_mode)

type DaemonHandle = object
  process: Process

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
  # Exactly three startup lines, as `t_observation_socket_write_path`
  # asserts: reading them keeps the pipe from filling and wedging the
  # daemon on a write nobody is draining.
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

proc completeOneExecution(client: var RunQuotaClient; statsKey: string) =
  var session = client.registerSession("m13a-query", "0.1.0")
  var request = resourceRequest(statsKey, milliCpu(1000), bytes(64'u64 * MiB))
  request.commandStatsId = statsKey
  var lease = session.requestLease(request)
  doAssert lease.active
  lease.markStarting()
  lease.markRunning(childProcessId = uint64(getCurrentProcessId()))
  sleep(30)
  lease.finish(outcome = leaseFinishSucceeded, exitCode = 0'u32,
    peakMemoryBytes = 5_000_000'u64, processCount = 1'u32,
    majorPageFaults = 0'u64)
  lease.release()
  session.closeSession()

proc waitForExecutions(path: string; atLeast: int): seq[ExecutionRow] =
  for _ in 0 ..< 200:
    let store = openObservationStore(path)
    if store.captureEnabled:
      result = store.readExecutions()
      if result.len >= atLeast:
        return
    sleep(50)

type SyntheticRow = object
  statsKey: string
  profileId: string
  ownerUid: Option[int64]
  durationMillis: int64
  peakRssBytes: int64

proc insertSynthetic(store: ObservationStore; hostId, runId: string;
                     rows: openArray[SyntheticRow]) =
  for index, row in rows:
    doAssert store.insertExecution(ExecutionRow(
      executionId: "exec-m13a-wire-" & $index,
      hostId: hostId,
      hostProfileId: some(row.profileId),
      runId: runId,
      commandStatsId: row.statsKey,
      leaseId: none(int64),
      startedAtUnixMillis: 20_000 + int64(index),
      finishedAtUnixMillis: 20_000 + int64(index) + row.durationMillis,
      durationMillis: row.durationMillis,
      exitStatus: 0,
      termination: tExited,
      attempt: 1,
      retryOf: none(string),
      peakRssBytes: row.peakRssBytes,
      cpuUserMillis: none(int64),
      cpuSysMillis: none(int64),
      maxProcesses: 1,
      majorPageFaults: 0,
      ioReadBytes: none(int64),
      ioWriteBytes: none(int64),
      captureCompleteness: ccComplete,
      droppedObservations: 0,
      ownerUid: row.ownerUid)), store.lastError

proc syntheticProfile(hostId, profileId: string): HostProfileRow =
  ## A SUPERSEDED profile beside the daemon's live one. Superseded because
  ## `host_profiles_current` allows exactly one open profile per host —
  ## which is the constraint that makes "two profiles" mean "hardware that
  ## changed", the situation the no-blending rule exists for.
  let hardware = HardwareProfile(
    cpuModel: "M13a Retired Builder 64", physicalCores: 64,
    logicalCores: 64, ramBytes: 256_000_000_000'i64, swapBytes: 0,
    diskClass: dcNvme, fsType: "apfs", arch: "arm64", os: "macos",
    osVersion: "14.0", kernelVersion: "23.0", virtualization: "none",
    cpuShareGroup: "")
  HostProfileRow(
    hostId: hostId, profileId: profileId,
    profileHash: profileHash(hardware),
    validFromUnixMillis: 1, validToUnixMillis: some(2'i64),
    cpuModel: hardware.cpuModel, physicalCores: hardware.physicalCores,
    logicalCores: hardware.logicalCores, ramBytes: hardware.ramBytes,
    swapBytes: hardware.swapBytes, diskClass: hardware.diskClass,
    fsType: hardware.fsType, arch: hardware.arch, os: hardware.os,
    osVersion: hardware.osVersion, kernelVersion: hardware.kernelVersion,
    virtualization: hardware.virtualization,
    cpuShareGroup: hardware.cpuShareGroup)

proc distributionFor(response: StatsResponseMessage;
                     profileId: string): ResourceDistributionWire =
  for entry in response.distributions:
    if entry.profile.profileIdPresent and entry.profile.profileId == profileId:
      return entry
  raise newException(ValueError, "no distribution for " & profileId)

suite "observation_query_interface":

  # -------------------------------------------------------------------------
  # THE GATE: both aggregations, over the socket, against a store that
  # really holds two profiles, two uids, and a key with and without history.
  # -------------------------------------------------------------------------

  test "runquotad answers both aggregations over the socket":
    let root = scratchRoot("read")
    defer: removeDir(root)
    let socketPath = rendezvousDir(root) / "d.sock"
    let state = hostStateDir(root)
    let identityFile = state / "host-id"
    let dbPath = state / "observations.sqlite3"
    check fileExists(daemonPath())

    putEnv("RUNQUOTA_SOCKET", socketPath)
    var daemon = startDaemon(socketPath,
      ["--host-identity-file", identityFile,
       "--ambient-sample-interval-millis", "0"])
    try:
      var client = connectDefault()
      client.completeOneExecution(RealKey)
      let realRows = waitForExecutions(dbPath, 1)
      check realRows.len == 1
      let hostId = realRows[0].hostId
      let liveProfileId = realRows[0].hostProfileId
      check liveProfileId.isSome
      let runId = realRows[0].runId

      # ------------------------------------------------------------------
      # THE FIXTURE, ASSERTED BEFORE ANY ANSWER IS ASSERTED.
      # ------------------------------------------------------------------
      let retiredProfileId = "profile-m13a-retired"
      let store = openObservationStore(dbPath)
      check store.captureEnabled
      check store.insertHostProfile(
        syntheticProfile(hostId, retiredProfileId))
      let myUid = int64(getuid())
      store.insertSynthetic(hostId, runId, [
        SyntheticRow(statsKey: HistoryKey, profileId: retiredProfileId,
          ownerUid: some(myUid), durationMillis: 100, peakRssBytes: 1_000),
        SyntheticRow(statsKey: HistoryKey, profileId: retiredProfileId,
          ownerUid: some(OtherUid), durationMillis: 110,
          peakRssBytes: 1_100),
        SyntheticRow(statsKey: HistoryKey, profileId: retiredProfileId,
          ownerUid: none(int64), durationMillis: 120, peakRssBytes: 1_200),
        SyntheticRow(statsKey: HistoryKey, profileId: liveProfileId.get,
          ownerUid: some(myUid), durationMillis: 900, peakRssBytes: 9_000),
        SyntheticRow(statsKey: HistoryKey, profileId: liveProfileId.get,
          ownerUid: some(OtherUid), durationMillis: 910,
          peakRssBytes: 9_100),
        SyntheticRow(statsKey: HistoryKey, profileId: liveProfileId.get,
          ownerUid: none(int64), durationMillis: 920, peakRssBytes: 9_200),
        SyntheticRow(statsKey: ZeroKey, profileId: liveProfileId.get,
          ownerUid: some(myUid), durationMillis: 0, peakRssBytes: 0),
        SyntheticRow(statsKey: ZeroKey, profileId: liveProfileId.get,
          ownerUid: some(OtherUid), durationMillis: 0, peakRssBytes: 0),
        SyntheticRow(statsKey: ZeroKey, profileId: liveProfileId.get,
          ownerUid: none(int64), durationMillis: 0, peakRssBytes: 0)])

      let profiles = store.readHostProfiles()
      check profiles.len == 2
      check retiredProfileId != liveProfileId.get
      var openProfiles = 0
      for profile in profiles:
        if profile.validToUnixMillis.isNone:
          openProfiles += 1
      check openProfiles == 1
      var uids: seq[int64] = @[]
      var never = 0
      for row in store.readExecutions():
        if row.ownerUid.isSome and row.ownerUid.get notin uids:
          uids.add(row.ownerUid.get)
        if row.commandStatsId == NeverKey:
          never += 1
      check uids.len == 2
      check myUid in uids
      check OtherUid in uids
      check never == 0
      check myUid != OtherUid

      # ------------------------------------------------------------------
      # HOST QUALIFICATION over the wire.
      # ------------------------------------------------------------------
      let spanned = client.queryStats(statsSubjectDistribution, HistoryKey,
        span = profileSpanWireAll)
      check spanned.captureEnabled
      check spanned.knowledge == statsKnowledgeWireKnown
      check spanned.distributions.len == 2
      let retired = spanned.distributionFor(retiredProfileId)
      let live = spanned.distributionFor(liveProfileId.get)
      # THE HARDWARE IDENTITY CAME BACK WITH THE FIGURES.
      check retired.profile.hostId == hostId
      check retired.profile.cpuModel == "M13a Retired Builder 64"
      check retired.profile.logicalCores == 64'u64
      check retired.profile.profileHash.len > 0
      check live.profile.profileHash != retired.profile.profileHash
      check retired.sampleCount == 3'u64
      check retired.durationMillisMin == 100'u64
      check retired.durationMillisP50 == 110'u64
      check retired.durationMillisMax == 120'u64
      check live.sampleCount == 3'u64
      check live.durationMillisMin == 900'u64
      check live.durationMillisMax == 920'u64
      # AND NOT BLENDED: the pooled six-sample answer appears in neither.
      for entry in spanned.distributions:
        check entry.sampleCount != 6'u64
        check not (entry.durationMillisMin == 100'u64 and
          entry.durationMillisMax == 920'u64)

      # THE WIDENING IS ANNOUNCED TOO, and this is the half without which
      # the pair below is satisfied by a daemon that hardcodes
      # `profileSpanWireSingle` into every answer it sends. `spanApplied`
      # exists so a reader can tell "one host has data" from "I only asked
      # about one host", and a field that is constant tells it neither.
      check spanned.spanApplied == profileSpanWireAll

      # Narrow by default: the caller that did not ask for cross-host data
      # does not get it.
      let narrow = client.queryStats(statsSubjectDistribution, HistoryKey)
      check narrow.spanApplied == profileSpanWireSingle
      check narrow.distributions.len == 1
      check narrow.distributions[0].profile.profileId == liveProfileId.get
      check narrow.distributions[0].durationMillisMax == 920'u64

      # ------------------------------------------------------------------
      # COLD START over the wire.
      # ------------------------------------------------------------------
      let unknown = client.queryStats(statsSubjectDistribution, NeverKey)
      let zero = client.queryStats(statsSubjectDistribution, ZeroKey)
      check unknown.knowledge == statsKnowledgeWireUnknown
      check zero.knowledge == statsKnowledgeWireKnown
      check unknown.distributions.len == 1
      check zero.distributions.len == 1
      # IDENTICAL NUMBERS, DIFFERENT KNOWLEDGE. Everything a reader could
      # measure agrees; only the claim differs.
      check unknown.distributions[0].durationMillisMin ==
        zero.distributions[0].durationMillisMin
      check unknown.distributions[0].durationMillisP50 ==
        zero.distributions[0].durationMillisP50
      check unknown.distributions[0].durationMillisP90 ==
        zero.distributions[0].durationMillisP90
      check unknown.distributions[0].durationMillisMax ==
        zero.distributions[0].durationMillisMax
      check unknown.distributions[0].peakRssBytesMax ==
        zero.distributions[0].peakRssBytesMax
      check zero.distributions[0].durationMillisMax == 0'u64
      check zero.distributions[0].sampleCount == 3'u64
      check unknown.distributions[0].sampleCount == 0'u64
      check unknown.distributions[0].knowledge == statsKnowledgeWireUnknown
      check zero.distributions[0].knowledge == statsKnowledgeWireKnown
      # Still qualified: it names the hardware it knows nothing about.
      check unknown.distributions[0].profile.profileId == liveProfileId.get

      # ------------------------------------------------------------------
      # SCOPING over the wire: uid by default, host on request.
      # ------------------------------------------------------------------
      let mine = client.queryStats(statsSubjectExecutions, HistoryKey,
        span = profileSpanWireAll)
      check mine.scopeApplied == statsScopeWireOwner
      # FROM PEER CREDENTIALS: the daemon reports the uid it scoped to, and
      # it is this process's, which the query never named.
      check mine.ownerUidPresent
      check mine.ownerUid == uint64(myUid)
      check mine.executions.len == 2
      for entry in mine.executions:
        check entry.ownerUidPresent
        check entry.ownerUid == uint64(myUid)
        check entry.profile.profileIdPresent

      let hostWide = client.queryStats(statsSubjectExecutions, HistoryKey,
        scope = statsScopeWireHost, span = profileSpanWireAll)
      check hostWide.scopeApplied == statsScopeWireHost
      check hostWide.executions.len == 6
      var otherRows = 0
      for entry in hostWide.executions:
        if entry.ownerUidPresent and entry.ownerUid == uint64(OtherUid):
          otherRows += 1
      # THE OTHER USER'S ROWS REALLY ARE IN THE STORE, which is what makes
      # their absence from `mine` a statement about scoping rather than
      # about an empty table.
      check otherRows == 2

      let ranked = client.queryStats(statsSubjectRanking, "",
        scope = statsScopeWireHost, span = profileSpanWireAll)
      var rankedKeys: seq[string] = @[]
      for entry in ranked.rankings:
        if entry.statsKey notin rankedKeys:
          rankedKeys.add(entry.statsKey)
        check entry.profile.profileIdPresent
      check HistoryKey in rankedKeys
      check RealKey in rankedKeys

      # ------------------------------------------------------------------
      # AND THE ESTIMATE PATH IS NOT UID-SCOPED, which is the asymmetry.
      # ------------------------------------------------------------------
      # The uid-scoped ROW query above saw 3 of the 6 rows for this key.
      # The distribution sees all of them, and says so: it reports itself
      # host-scoped with no owner, rather than quietly narrowing.
      check spanned.scopeApplied == statsScopeWireHost
      check not spanned.ownerUidPresent
      check retired.sampleCount + live.sampleCount == 6'u64
      let narrowedAttempt = client.queryStats(statsSubjectDistribution,
        HistoryKey, scope = statsScopeWireOwner, span = profileSpanWireAll)
      # EVEN WHEN ASKED TO NARROW IT. A uid-scoped estimate would discard
      # most of the history on exactly the machines that have the most.
      check narrowedAttempt.scopeApplied == statsScopeWireHost
      check not narrowedAttempt.ownerUidPresent
      check narrowedAttempt.distributions.len == 2
      check narrowedAttempt.distributionFor(retiredProfileId).sampleCount ==
        3'u64

      # ------------------------------------------------------------------
      # EXTENSION ROWS over the wire: RunQuota carries a product's fact
      # without interpreting it, under the SAME scope rules.
      # ------------------------------------------------------------------
      let declaration = ExtensionDeclaration(
        extensionId: ProbeExtensionId, owner: "runquota-m13a",
        schemaVersion: 1, migrations: @[probeDdl])
      check store.declareExtension(declaration) == eoCreated
      var attached = 0
      for row in store.readExecutions():
        if row.commandStatsId != HistoryKey or
            row.hostProfileId != some(liveProfileId.get):
          continue
        check store.insertExtensionRow(declaration, extensions.ExtensionRow(
          hostId: row.hostId, executionId: row.executionId,
          columns: @["probe_label", "probe_count"],
          values: @[
            (if row.ownerUid == some(myUid): extText("mine")
              elif row.ownerUid == some(OtherUid): extText("theirs")
              else: extNull()),
            extInt(row.durationMillis)])) == ewWritten
        attached += 1
      # NON-VACUITY: three facts really exist, one per owner, so the
      # scoped answer below hides something rather than finding nothing.
      check attached == 3

      let myFacts = client.queryStats(statsSubjectExtensionRows, HistoryKey,
        extensionId = ProbeExtensionId,
        extensionColumns = ["probe_label", "probe_count"])
      check myFacts.scopeApplied == statsScopeWireOwner
      check myFacts.ownerUidPresent
      check myFacts.extensionRows.len == 1
      check myFacts.extensionRows[0].ownerUid == uint64(myUid)
      # OPAQUE: the columns come back as asked for, the values as text.
      check myFacts.extensionRows[0].columns == @["probe_label", "probe_count"]
      check myFacts.extensionRows[0].values == @["mine", "900"]
      # And still qualified by the hardware the fact was measured on.
      check myFacts.extensionRows[0].profile.profileId == liveProfileId.get
      check myFacts.extensionRows[0].statsKey == HistoryKey

      let allFacts = client.queryStats(statsSubjectExtensionRows, HistoryKey,
        scope = statsScopeWireHost, extensionId = ProbeExtensionId,
        extensionColumns = ["probe_label", "probe_count"])
      check allFacts.extensionRows.len == 3
      var wireLabels: seq[string] = @[]
      for entry in allFacts.extensionRows:
        wireLabels.add(entry.values[0])
      # THE OTHER USER'S FACT IS REACHABLE ONLY BY WIDENING, and it really
      # is there, which is what makes its absence above a statement about
      # scoping.
      check "theirs" in wireLabels
      check "theirs" notin @[myFacts.extensionRows[0].values[0]]

      client.close()
    finally:
      daemon.stop()

  # -------------------------------------------------------------------------
  # THE ESTIMATE RULE: a supplied estimate is used unmodified; the daemon's
  # learned one is the fallback and only that.
  # -------------------------------------------------------------------------

  test "a supplied estimate is passed through unmodified, learned is fallback":
    let root = scratchRoot("est")
    defer: removeDir(root)
    let socketPath = rendezvousDir(root) / "d.sock"
    let state = hostStateDir(root)

    putEnv("RUNQUOTA_SOCKET", socketPath)
    var daemon = startDaemon(socketPath,
      ["--host-identity-file", state / "host-id",
       "--cpu-milli", "16000",
       "--memory-bytes", $(16'u64 * 1024'u64 * MiB),
       "--ambient-sample-interval-millis", "0"])
    try:
      var client = connectDefault()
      var session = client.registerSession("m13a-estimate", "0.1.0")

      # ------------------------------------------------------------------
      # Teach the daemon an estimate, the only way it can be taught: by
      # finishing an execution that really reported a peak.
      # ------------------------------------------------------------------
      var seed = resourceRequest("seed", milliCpu(1000), bytes(1'u64 * MiB))
      seed.commandStatsId = EstimateKey
      var seedLease = session.requestLease(seed)
      check seedLease.active
      seedLease.markStarting()
      seedLease.markRunning(childProcessId = uint64(getCurrentProcessId()))
      seedLease.finish(outcome = leaseFinishSucceeded, exitCode = 0'u32,
        peakMemoryBytes = ObservedPeakBytes, processCount = 1'u32,
        majorPageFaults = 0'u64)
      seedLease.release()
      # THE FIXTURE FOR THIS CLAUSE IS "THE DAEMON HOLDS A LEARNED
      # ESTIMATE", and it is asserted before anything is asserted about
      # pass-through: against an empty table, "the supplied estimate was
      # not clamped" is unfalsifiable, because there is nothing to clamp
      # against.
      check client.inspectionJson("estimates").contains(EstimateKey)

      # ------------------------------------------------------------------
      # NO ESTIMATE SUPPLIED -> the learned one is used. This is the ONLY
      # branch it may be used on, and this arm is what makes the next two
      # mean something.
      # ------------------------------------------------------------------
      var bare = resourceRequest("bare", milliCpu(1000), bytes(1'u64 * MiB))
      bare.commandStatsId = EstimateKey
      var bareLease = session.requestLease(bare)
      check bareLease.active
      check bareLease.resources.memory.value == LearnedConservativeBytes
      check bareLease.resources.memory.value > 1'u64 * MiB
      bareLease.release()

      # ------------------------------------------------------------------
      # AN ESTIMATE SMALLER THAN THE LEARNED ONE. This is the arm that
      # kills every clamping implementation: `max(supplied, learned)` and
      # "validate against the table" both answer 1000 MiB here, and the
      # rule says 4.
      # ------------------------------------------------------------------
      var small = resourceRequest("small", milliCpu(1000), bytes(1'u64 * MiB))
      small.commandStatsId = EstimateKey
      small = small.withEstimate(SmallEstimateBytes)
      var smallLease = session.requestLease(small)
      check smallLease.active
      check smallLease.resources.memory.value == SmallEstimateBytes
      check smallLease.resources.memory.value != LearnedConservativeBytes
      smallLease.release()

      # ------------------------------------------------------------------
      # AN ESTIMATE LARGER THAN THE LEARNED ONE. Together with the arm
      # above this pins pass-through in BOTH directions, so no clamp in
      # either survives: a floor would have raised 4 MiB, a ceiling would
      # have lowered 2000 MiB.
      # ------------------------------------------------------------------
      var large = resourceRequest("large", milliCpu(1000), bytes(1'u64 * MiB))
      large.commandStatsId = EstimateKey
      large = large.withEstimate(LargeEstimateBytes)
      var largeLease = session.requestLease(large)
      check largeLease.active
      check largeLease.resources.memory.value == LargeEstimateBytes
      largeLease.release()

      # ------------------------------------------------------------------
      # AND A ZERO ESTIMATE IS AN ESTIMATE, WHICH IS WHY THIS IS A
      # REFUSAL. Zero reaches admission unchanged and the request is then
      # malformed — a lease must reserve something — so it is DENIED. That
      # denial is the evidence: a daemon that clamped against its own
      # table, or that read "supplied" as "non-zero", would have granted
      # this at the learned 1000 MiB and nothing would have gone wrong.
      #
      # It is also why presence is a separate field rather than a
      # zero sentinel: with a sentinel this request would be
      # indistinguishable from one that supplied nothing at all.
      # ------------------------------------------------------------------
      var zeroEstimate = resourceRequest("zero", milliCpu(1000),
        bytes(1'u64 * MiB))
      zeroEstimate.commandStatsId = EstimateKey
      zeroEstimate = zeroEstimate.withEstimate(0'u64)
      var denied = false
      var deniedMessage = ""
      try:
        var zeroLease = session.requestLease(zeroEstimate)
        zeroLease.release()
      except RunQuotaClientError as error:
        denied = true
        deniedMessage = error.msg
      check denied
      check deniedMessage.contains("must reserve CPU and memory")

      # ------------------------------------------------------------------
      # The batched path takes the same rule. It is a separate decode and
      # a separate call site, which is exactly how a rule ends up holding
      # on one path and not the other.
      # ------------------------------------------------------------------
      var batchBare = resourceRequest("batch-bare", milliCpu(1000),
        bytes(1'u64 * MiB))
      batchBare.commandStatsId = EstimateKey
      var batchSupplied = resourceRequest("batch-supplied", milliCpu(1000),
        bytes(1'u64 * MiB))
      batchSupplied.commandStatsId = EstimateKey
      batchSupplied = batchSupplied.withEstimate(SmallEstimateBytes)
      let offered = session.offerCandidates([
        toCandidate(1'u64, batchBare),
        toCandidate(2'u64, batchSupplied)])
      check offered.len == 2
      for entry in offered:
        if entry.clientCandidateId == 1'u64:
          check entry.lease.resources.memory.value == LearnedConservativeBytes
        else:
          check entry.lease.resources.memory.value == SmallEstimateBytes
      for entry in offered:
        var lease = entry.lease
        lease.release()

      session.closeSession()
      client.close()
    finally:
      daemon.stop()

  # -------------------------------------------------------------------------
  # THE READ PATH SEES WHAT THE DAEMON HAS ALREADY RECORDED. Not a
  # convenience: a store whose answers lag its own writes is a system of
  # record only after an unspecified delay, and the caller cannot tell "not
  # yet flushed" from "never happened".
  # -------------------------------------------------------------------------

  test "a query immediately after a lease finishes sees that execution":
    # WHY THIS TEST EXISTS SEPARATELY FROM THE GATE ABOVE. Every other arm
    # in this file reaches the store through `waitForExecutions`, which
    # polls for up to ten seconds -- and polling MASKS the daemon's flush
    # completely: with or without it the row has landed long before the
    # first assertion. A call that no test can be shown to need is either
    # dead code or a latent race, and this one is the latter.
    #
    # So this arm does the thing a real consumer does and no other arm
    # does: it finishes a lease and asks, with nothing in between.
    let root = scratchRoot("flush")
    defer: removeDir(root)
    let socketPath = rendezvousDir(root) / "d.sock"
    let state = hostStateDir(root)
    let dbPath = state / "observations.sqlite3"

    putEnv("RUNQUOTA_SOCKET", socketPath)
    var daemon = startDaemon(socketPath,
      ["--host-identity-file", state / "host-id",
       "--ambient-sample-interval-millis", "0"])
    try:
      var client = connectDefault()
      var session = client.registerSession("m13a-flush", "0.1.0")
      for round in 0 ..< FlushRounds:
        let key = FlushKey & "-" & $round
        var request = resourceRequest(key, milliCpu(1000),
          bytes(64'u64 * MiB))
        request.commandStatsId = key
        var lease = session.requestLease(request)
        check lease.active
        lease.markStarting()
        lease.markRunning(childProcessId = uint64(getCurrentProcessId()))
        lease.finish(outcome = leaseFinishSucceeded, exitCode = 0'u32,
          peakMemoryBytes = 5_000_000'u64, processCount = 1'u32,
          majorPageFaults = 0'u64)
        lease.release()

        # NO SLEEP, NO POLL, NO RETRY. The next line is the assertion.
        let answer = client.queryStats(statsSubjectExecutions, key)
        check answer.captureEnabled
        check answer.executions.len == 1
        if answer.executions.len == 1:
          check answer.executions[0].statsKey == key
          check answer.executions[0].ownerUidPresent
          check answer.executions[0].ownerUid == uint64(getuid())

      # NON-VACUITY: capture really was on and the rows really were
      # written, so "the query saw it" is a statement about the flush
      # rather than about a daemon that recorded nothing and answered
      # nothing. Read from the file directly -- this is the fixture check,
      # not the answer.
      let store = openObservationStore(dbPath)
      check store.captureEnabled
      var recorded = 0
      for row in store.readExecutions():
        if row.commandStatsId.startsWith(FlushKey):
          recorded += 1
      check recorded == FlushRounds

      session.closeSession()
      client.close()
    finally:
      daemon.stop()
