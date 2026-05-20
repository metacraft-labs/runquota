import std/[os, osproc, strutils, unittest]

import runquota_client
import runquota_codec
import runquota_core
import runquota_ipc except connectDefault
import runquota_protocol

proc daemonPath(): string =
  getCurrentDir() / "build" / "bin" / "runquotad"

proc cliPath(): string =
  getCurrentDir() / "build" / "bin" / "runquota"

proc waitForDaemon(socketPath: string) =
  putEnv("RUNQUOTA_SOCKET", socketPath)
  var lastError = ""
  for _ in 0 ..< 100:
    try:
      var client = connectDefault()
      client.close()
      return
    except CatchableError as error:
      lastError = error.msg
      sleep(50)
  raise newException(OSError, "runquotad did not become ready: " & lastError)

proc req(label: string; cpu: int; memoryMiB: int;
         poolName: string = ""; poolUnits: int = 0;
         ioClass: IoClass = ioNormal): ResourceRequest =
  result = resourceRequest(
    label,
    milliCpu(cpu),
    bytes(uint64(memoryMiB) * 1024'u64 * 1024'u64)
  )
  result.resources.ioClass = ioClass
  if poolName.len > 0:
    result.resources = result.resources.withNamedPool(poolName, poolUnits)

proc benchmarkReq(label: string; cpu: int; memoryMiB: int): ResourceRequest =
  result = req(label, cpu, memoryMiB)
  result.purpose = leasePurposeBenchmark

proc machineReq(label, machine: string; cpu: int;
    memoryMiB: int): ResourceRequest =
  result = req(label, cpu, memoryMiB)
  result.resources = result.resources.forMachine(machine)

proc candidate(id: uint64; request: ResourceRequest): LeaseCandidate =
  toCandidate(id, request)

proc findDecision(decisions: seq[OfferedLease];
    candidateId: uint64): OfferedLease =
  for decision in decisions:
    if decision.clientCandidateId == candidateId:
      return decision
  raise newException(ValueError, "missing decision for candidate " & $candidateId)

proc offerAndReceive(session: var RunQuotaSession;
                     candidates: openArray[LeaseCandidate]): seq[OfferedLease] =
  let requestId = session.sendCandidateOffer(candidates)
  session.receiveCandidateDecisions(requestId)

proc sendRawCandidateOffer(session: var RunQuotaSession; requestId: uint64;
                           candidates: openArray[LeaseCandidate]) =
  var copied: seq[LeaseCandidate] = @[]
  for candidate in candidates:
    copied.add(candidate)
  let msg = CandidateOfferMessage(sessionId: session.id, candidates: copied)
  session.client[].connection.sendFrame(
    encodeFrame(rqOfferCandidates, FrameFlagRequest, requestId,
        encodeCandidateOffer(msg))
  )

proc oversizedStatusRequestFrame(requestId: uint64): string =
  var w = writer()
  w.data.add(RqspMagic)
  w.writeU16(RqspProtocolMajor)
  w.writeU16(RqspHeaderLen)
  w.writeU16(uint16(ord(rqStatusRequest)))
  w.writeU16(FrameFlagRequest)
  w.writeU64(requestId)
  w.writeU32(DefaultMaxFrameBytes + 1'u32)
  w.data

proc receiveProtocolError(client: var RunQuotaClient; requestId: uint64;
                          messagePart: string): Diagnostic =
  var frame: RqspFrame
  check client.connection.receiveFrame(frame)
  check frame.header.requestId == requestId
  check frame.header.messageKind == rqError
  check (frame.header.flags and FrameFlagError) != 0
  var error: ProtocolErrorMessage
  check decodeProtocolError(frame.payload, error)
  check error.diagnostic.code == diagProtocol
  check error.diagnostic.message.contains(messagePart)
  error.diagnostic

proc waitForGrant(session: var RunQuotaSession;
    candidateId: uint64): RunQuotaLease =
  for _ in 0 ..< 100:
    let grants = session.pollNextGrant()
    for grant in grants:
      if grant.clientCandidateId == candidateId and not grant.queued:
        return grant.lease
    sleep(50)
  raise newException(OSError, "grant did not arrive for candidate " & $candidateId)

proc readStatus(): DaemonStatusMessage =
  var client = connectDefault()
  defer: client.close()
  client.daemonStatus()

proc waitForNoActiveSessions() =
  for _ in 0 ..< 100:
    if readStatus().activeSessions == 0'u32:
      return
    sleep(50)
  raise newException(OSError, "daemon did not clean up active sessions")

proc runCli(args: openArray[string]): string =
  execProcess(cliPath(), args = @args, options = {poUsePath})

template finishLease(lease: var RunQuotaLease; progress: var int) =
  lease.finish()
  inc progress

suite "e2e_runquota_multi_client_fairness":
  test "real daemon admits batched multi-session work fairly without oversubscription":
    let socketDir = getTempDir() / ("runquota-m3-" & $getCurrentProcessId())
    let socketPath = socketDir / "runquotad.sock"
    if dirExists(socketDir):
      removeDir(socketDir)
    createDir(socketDir)
    check fileExists(daemonPath())
    check fileExists(cliPath())

    let process = startProcess(
      daemonPath(),
      args = [
        "--socket", socketPath,
        "--cpu-milli", "3000",
        "--memory-bytes", $(3072'u64 * 1024'u64 * 1024'u64),
        "--io-slots", "1",
        "--pool", "host/linker=1",
        "--pool", "host/pty=1"
      ],
      options = {poStdErrToStdOut}
    )
    try:
      waitForDaemon(socketPath)

      var clientA = connectDefault()
      var clientB = connectDefault()
      var clientWatch = connectDefault()
      var sessionA = clientA.registerSession("repro-a", "0.1.0")
      var sessionB = clientB.registerSession("repro-b", "0.1.0")
      var sessionWatch = clientWatch.registerSession("repro-watch", "0.1.0")
      var progressA = 0
      var progressB = 0
      var progressWatch = 0

      let bDecisions = sessionB.offerAndReceive([
        candidate(201, req("b-compile-1", 1000, 1024)),
        candidate(202, req("b-compile-2", 1000, 1024))
      ])
      var b1 = bDecisions.findDecision(201).lease
      var b2 = bDecisions.findDecision(202).lease
      check bDecisions.findDecision(201).queued == false
      check bDecisions.findDecision(202).queued == false
      b1.markRunning()
      b2.markRunning()

      let watchFirst = sessionWatch.offerAndReceive([
        candidate(301, req("watch-pty-1", 500, 512, "host/pty", 1))
      ])
      var w1 = watchFirst.findDecision(301).lease
      check not watchFirst.findDecision(301).queued
      w1.markRunning()

      let aLinkerRequest = sessionA.sendCandidateOffer([
        candidate(101, req("a-large-linker", 3000, 3072, "host/linker", 1))
      ])
      let aCompileRequest = sessionA.sendCandidateOffer([
        candidate(102, req("a-small-compile", 500, 512))
      ])
      check aLinkerRequest != aCompileRequest
      let aCompileDecisions = sessionA.receiveCandidateDecisions(aCompileRequest)
      check aCompileDecisions.len == 1
      let aCompileDecision = aCompileDecisions.findDecision(102)
      check not aCompileDecision.queued
      var aCompile = aCompileDecision.lease
      aCompile.markRunning()
      check sessionA.client[].inflightRequestIds.contains(aLinkerRequest)
      let aLinkerDecisions = sessionA.receiveCandidateDecisions(aLinkerRequest)
      check aLinkerDecisions.len == 1
      let aLinkerDecision = aLinkerDecisions.findDecision(101)
      check aLinkerDecision.queued

      let watchSecond = sessionWatch.offerAndReceive([
        candidate(302, req("watch-pty-2", 500, 512, "host/pty", 1))
      ])
      check watchSecond.findDecision(302).queued

      let mixedStatus = readStatus()
      check mixedStatus.activeSessions == 3'u32
      check mixedStatus.activeLeases == 4'u32
      check mixedStatus.queuedLeases == 2'u32
      check mixedStatus.finishedLeases == 0'u32

      let leasesSnapshot = runCli(["leases", "--json"])
      check leasesSnapshot.contains("\"state\":\"running\"")
      check leasesSnapshot.contains("\"state\":\"queued\"")
      check leasesSnapshot.contains("a-large-linker")
      check leasesSnapshot.contains("host/pty")
      check runCli(["sessions", "--json"]).contains("repro-watch")
      check runCli(["explain", $sessionA.id.value]).contains("a-large-linker")

      finishLease(aCompile, progressA)
      check readStatus().queuedLeases == 2'u32

      finishLease(w1, progressWatch)
      var w2 = sessionWatch.waitForGrant(302)
      w2.markRunning()
      finishLease(w2, progressWatch)

      finishLease(b1, progressB)
      check readStatus().queuedLeases == 1'u32
      finishLease(b2, progressB)

      var aLinker = sessionA.waitForGrant(101)
      aLinker.markRunning()
      finishLease(aLinker, progressA)

      check progressA == 2
      check progressB == 2
      check progressWatch == 2

      sessionA.closeSession()
      sessionB.closeSession()
      sessionWatch.closeSession()
      clientA.close()
      clientB.close()
      clientWatch.close()

      let finalStatus = readStatus()
      check finalStatus.activeSessions == 0'u32
      check finalStatus.activeLeases == 0'u32
      check finalStatus.queuedLeases == 0'u32
      check finalStatus.finishedLeases == 6'u32
      check finalStatus.totalFinished == 6'u64
      check runCli(["leases", "--json"]).contains("\"state\":\"finished\"")
    finally:
      if process.running:
        process.terminate()
        discard process.waitForExit(3000)
      process.close()
      if dirExists(socketDir):
        removeDir(socketDir)

  test "real daemon queues IO admission without blocking fitting non-IO work":
    let socketDir = getTempDir() / ("runquota-m3-io-" & $getCurrentProcessId())
    let socketPath = socketDir / "runquotad.sock"
    if dirExists(socketDir):
      removeDir(socketDir)
    createDir(socketDir)
    check fileExists(daemonPath())
    check fileExists(cliPath())

    let process = startProcess(
      daemonPath(),
      args = [
        "--socket", socketPath,
        "--cpu-milli", "2000",
        "--memory-bytes", $(2048'u64 * 1024'u64 * 1024'u64),
        "--io-slots", "1"
      ],
      options = {poStdErrToStdOut}
    )
    try:
      waitForDaemon(socketPath)

      var clientIo = connectDefault()
      var clientOther = connectDefault()
      var sessionIo = clientIo.registerSession("repro-io", "0.1.0")
      var sessionOther = clientOther.registerSession("repro-non-io", "0.1.0")
      var progressIo = 0
      var progressOther = 0

      let firstIoDecisions = sessionIo.offerAndReceive([
        candidate(501, req("io-heavy-active", 500, 512, ioClass = ioHeavy))
      ])
      let firstIoDecision = firstIoDecisions.findDecision(501)
      check not firstIoDecision.queued
      check firstIoDecision.lease.resources.ioClass == ioHeavy
      var io1 = firstIoDecision.lease
      io1.markRunning()

      let queuedIoDecisions = sessionIo.offerAndReceive([
        candidate(502, req("io-heavy-queued", 500, 512, ioClass = ioHeavy))
      ])
      let queuedIoDecision = queuedIoDecisions.findDecision(502)
      check queuedIoDecision.queued
      check queuedIoDecision.lease.resources.ioClass == ioHeavy
      check sessionIo.pollNextGrant().len == 0

      let ioBoundStatus = readStatus()
      check ioBoundStatus.activeSessions == 2'u32
      check ioBoundStatus.activeLeases == 1'u32
      check ioBoundStatus.queuedLeases == 1'u32
      let ioBoundSnapshot = runCli(["leases", "--json"])
      check ioBoundSnapshot.contains("io-heavy-active")
      check ioBoundSnapshot.contains("io-heavy-queued")
      check ioBoundSnapshot.contains("\"io_class\":\"ioHeavy\"")
      check ioBoundSnapshot.contains("\"state\":\"queued\"")

      let nonIoDecisions = sessionOther.offerAndReceive([
        candidate(601, req("non-io-while-io-queued", 500, 512))
      ])
      let nonIoDecision = nonIoDecisions.findDecision(601)
      check not nonIoDecision.queued
      check nonIoDecision.lease.resources.ioClass == ioNormal
      var nonIo = nonIoDecision.lease
      nonIo.markRunning()

      let mixedStatus = readStatus()
      check mixedStatus.activeLeases == 2'u32
      check mixedStatus.queuedLeases == 1'u32
      let mixedSnapshot = runCli(["leases", "--json"])
      check mixedSnapshot.contains("non-io-while-io-queued")
      check mixedSnapshot.contains("\"io_class\":\"ioNormal\"")

      finishLease(nonIo, progressOther)
      let afterNonIoProgress = readStatus()
      check afterNonIoProgress.activeLeases == 1'u32
      check afterNonIoProgress.queuedLeases == 1'u32

      finishLease(io1, progressIo)
      var io2 = sessionIo.waitForGrant(502)
      check io2.resources.ioClass == ioHeavy
      io2.markRunning()
      finishLease(io2, progressIo)

      check progressIo == 2
      check progressOther == 1

      sessionIo.closeSession()
      sessionOther.closeSession()
      clientIo.close()
      clientOther.close()

      let finalStatus = readStatus()
      check finalStatus.activeSessions == 0'u32
      check finalStatus.activeLeases == 0'u32
      check finalStatus.queuedLeases == 0'u32
      check finalStatus.finishedLeases == 3'u32
      check finalStatus.totalFinished == 3'u64
    finally:
      if process.running:
        process.terminate()
        discard process.waitForExit(3000)
      process.close()
      if dirExists(socketDir):
        removeDir(socketDir)

  test "real daemon grants benchmark leases only after outstanding work drains":
    let socketDir = getTempDir() / ("runquota-m3-benchmark-" &
        $getCurrentProcessId())
    let socketPath = socketDir / "runquotad.sock"
    if dirExists(socketDir):
      removeDir(socketDir)
    createDir(socketDir)
    check fileExists(daemonPath())
    check fileExists(cliPath())
    var cliBenchmark: Process

    let process = startProcess(
      daemonPath(),
      args = [
        "--socket", socketPath,
        "--cpu-milli", "3000",
        "--memory-bytes", $(3072'u64 * 1024'u64 * 1024'u64)
      ],
      options = {poStdErrToStdOut}
    )
    try:
      waitForDaemon(socketPath)

      var clientWork = connectDefault()
      var clientBench = connectDefault()
      var clientLate = connectDefault()
      var sessionWork = clientWork.registerSession("repro-work", "0.1.0")
      var sessionBench = clientBench.registerSession("repro-bench", "0.1.0")
      var sessionLate = clientLate.registerSession("repro-late-work", "0.1.0")
      var progress = 0

      let activeWorkDecisions = sessionWork.offerAndReceive([
        candidate(701, req("active-work", 1000, 512))
      ])
      let activeWorkDecision = activeWorkDecisions.findDecision(701)
      check not activeWorkDecision.queued
      var activeWork = activeWorkDecision.lease
      activeWork.markRunning()

      let benchmarkDecisions = sessionBench.offerAndReceive([
        candidate(801, benchmarkReq("isolated-benchmark", 1000, 512))
      ])
      let benchmarkDecision = benchmarkDecisions.findDecision(801)
      check benchmarkDecision.queued
      check benchmarkDecision.diagnostic.message.contains("benchmark isolation")

      let lateWorkDecisions = sessionLate.offerAndReceive([
        candidate(901, req("late-fitting-work", 500, 256))
      ])
      let lateWorkDecision = lateWorkDecisions.findDecision(901)
      check lateWorkDecision.queued
      check lateWorkDecision.diagnostic.message.contains("benchmark isolation")

      let queuedSnapshot = runCli(["leases", "--json"])
      check queuedSnapshot.contains("\"purpose\":\"benchmark\"")
      check queuedSnapshot.contains("isolated-benchmark")
      check queuedSnapshot.contains("late-fitting-work")

      finishLease(activeWork, progress)
      var benchmark = sessionBench.waitForGrant(801)
      check benchmark.resources.cpu.value == 1000'u32
      benchmark.markRunning()
      check sessionLate.pollNextGrant().len == 0

      finishLease(benchmark, progress)
      var lateWork = sessionLate.waitForGrant(901)
      lateWork.markRunning()
      finishLease(lateWork, progress)

      let cliBlockerDecisions = sessionWork.offerAndReceive([
        candidate(702, req("cli-benchmark-blocker", 1000, 512))
      ])
      var cliBlocker = cliBlockerDecisions.findDecision(702).lease
      check not cliBlockerDecisions.findDecision(702).queued
      cliBlocker.markRunning()

      let markerPath = socketDir / "cli-benchmark-marker.txt"
      cliBenchmark = startProcess(
        cliPath(),
        args = [
          "acquire",
          "--benchmark",
          "--cpu", "500",
          "--mem", "64MiB",
          "--label", "cli-benchmark",
          "--",
          "/bin/sh", "-c", "echo ok > \"$1\"", "sh", markerPath
        ],
        options = {poStdErrToStdOut}
      )
      sleep(200)
      check cliBenchmark.running
      check not fileExists(markerPath)

      finishLease(cliBlocker, progress)
      check cliBenchmark.waitForExit(5000) == 0
      check readFile(markerPath).strip() == "ok"
      cliBenchmark.close()
      cliBenchmark = nil

      check progress == 4
      sessionWork.closeSession()
      sessionBench.closeSession()
      sessionLate.closeSession()
      clientWork.close()
      clientBench.close()
      clientLate.close()

      let finalStatus = readStatus()
      check finalStatus.activeSessions == 0'u32
      check finalStatus.activeLeases == 0'u32
      check finalStatus.queuedLeases == 0'u32
      check finalStatus.finishedLeases == 4'u32
    finally:
      if cliBenchmark != nil:
        if cliBenchmark.running:
          cliBenchmark.terminate()
          discard cliBenchmark.waitForExit(3000)
        cliBenchmark.close()
      if process.running:
        process.terminate()
        discard process.waitForExit(3000)
      process.close()
      if dirExists(socketDir):
        removeDir(socketDir)

  test "real daemon models host and VM shared CPU topology":
    let socketDir = getTempDir() / ("runquota-m3-topology-" &
        $getCurrentProcessId())
    let socketPath = socketDir / "runquotad.sock"
    if dirExists(socketDir):
      removeDir(socketDir)
    createDir(socketDir)
    check fileExists(daemonPath())
    check fileExists(cliPath())

    let process = startProcess(
      daemonPath(),
      args = [
        "--socket", socketPath,
        "--machine", "host=4000," & $(4096'u64 * 1024'u64 * 1024'u64) &
            ",1,physical",
        "--machine", "vm=4000," & $(4096'u64 * 1024'u64 * 1024'u64) &
            ",1,physical",
        "--cpu-share-group", "physical=4000"
      ],
      options = {poStdErrToStdOut}
    )
    try:
      waitForDaemon(socketPath)

      var clientHost = connectDefault()
      var clientVm = connectDefault()
      var clientDenied = connectDefault()
      var sessionHost = clientHost.registerSession("ci-host", "0.1.0")
      var sessionVm = clientVm.registerSession("ci-vm", "0.1.0")
      var sessionDenied = clientDenied.registerSession("ci-denied", "0.1.0")
      var progress = 0

      let hostDecisions = sessionHost.offerAndReceive([
        candidate(1001, machineReq("host-memory-heavy", "host", 1000, 3072))
      ])
      var hostLease = hostDecisions.findDecision(1001).lease
      check not hostDecisions.findDecision(1001).queued
      hostLease.markRunning()

      let vmDecisions = sessionVm.offerAndReceive([
        candidate(1101, machineReq("vm-memory-heavy", "vm", 1000, 3072))
      ])
      var vmLease = vmDecisions.findDecision(1101).lease
      check not vmDecisions.findDecision(1101).queued
      vmLease.markRunning()

      let blockedDecisions = sessionHost.offerAndReceive([
        candidate(1002, machineReq("host-shared-cpu-blocked", "host", 2500, 256))
      ])
      let blockedDecision = blockedDecisions.findDecision(1002)
      check blockedDecision.queued

      let topology = runCli(["topology", "--json"])
      check topology.contains("\"id\":\"host\"")
      check topology.contains("\"id\":\"vm\"")
      check topology.contains("\"id\":\"physical\"")
      check topology.contains("\"cpu_share_group\":\"physical\"")
      let leases = runCli(["leases", "--json"])
      check leases.contains("\"machine_id\":\"host\"")
      check leases.contains("\"machine_id\":\"vm\"")

      try:
        discard sessionDenied.requestLease(machineReq("unknown-machine",
            "missing-vm", 100, 64))
        check false
      except RunQuotaClientError as error:
        check error.msg.contains("unknown machine")

      finishLease(vmLease, progress)
      var unblocked = sessionHost.waitForGrant(1002)
      unblocked.markRunning()
      finishLease(unblocked, progress)
      finishLease(hostLease, progress)

      check progress == 3
      sessionHost.closeSession()
      sessionVm.closeSession()
      sessionDenied.closeSession()
      clientHost.close()
      clientVm.close()
      clientDenied.close()

      let finalStatus = readStatus()
      check finalStatus.activeSessions == 0'u32
      check finalStatus.activeLeases == 0'u32
      check finalStatus.queuedLeases == 0'u32
      check finalStatus.finishedLeases == 3'u32
    finally:
      if process.running:
        process.terminate()
        discard process.waitForExit(3000)
      process.close()
      if dirExists(socketDir):
        removeDir(socketDir)

  test "real daemon reports candidate batch and frame flow-control diagnostics":
    let socketDir = getTempDir() / ("runquota-m3-flow-" & $getCurrentProcessId())
    let socketPath = socketDir / "runquotad.sock"
    if dirExists(socketDir):
      removeDir(socketDir)
    createDir(socketDir)
    check fileExists(daemonPath())

    let process = startProcess(
      daemonPath(),
      args = [
        "--socket", socketPath,
        "--cpu-milli", "3000",
        "--memory-bytes", $(3072'u64 * 1024'u64 * 1024'u64)
      ],
      options = {poStdErrToStdOut}
    )
    try:
      waitForDaemon(socketPath)

      var client = connectDefault()
      var session = client.registerSession("repro-flow-control", "0.1.0")
      var tooManyCandidates: seq[LeaseCandidate] = @[]
      for i in 0 .. int(DefaultMaxCandidatesPerBatch):
        tooManyCandidates.add(candidate(400'u64 + uint64(i), req("over-batch-" &
            $i, 100, 64)))

      session.sendRawCandidateOffer(90'u64, tooManyCandidates)
      let batchDiagnostic = client.receiveProtocolError(90'u64, "candidate batch exceeds")
      check batchDiagnostic.detail.contains("max_candidates_per_batch=" &
          $DefaultMaxCandidatesPerBatch)
      check readStatus().activeSessions == 1'u32

      client.connection.sendFrame(oversizedStatusRequestFrame(91'u64))
      let frameDiagnostic = client.receiveProtocolError(91'u64, "frame exceeds")
      check frameDiagnostic.detail.contains("max_frame_bytes=" &
          $DefaultMaxFrameBytes)
      client.close()
      waitForNoActiveSessions()
    finally:
      if process.running:
        process.terminate()
        discard process.waitForExit(3000)
      process.close()
      if dirExists(socketDir):
        removeDir(socketDir)
