## test_rqm_protocol_compatibility: the memory cap on the wire (protocol
## minor `MemoryCapMinor`, 14), and what an older peer sees in each
## direction.
##
## THE FACTS, all about bytes:
##
## * DAEMON TO CLIENT. A grant without a cap encodes to exactly the bytes a
##   minor-13 daemon sent, and a minor-13 CLIENT'S decoder -- written out
##   here field by field, so no fact passes by the current decoder agreeing
##   with itself -- reads it; the same decoder REFUSES a grant carrying a cap
##   block, which is why the daemon sends one only to a client that
##   announced the minor in its `Hello` (`rqsp-minor=14`). The last case
##   asserts that end to end against a real `runquotad`: a raw connection
##   whose `Hello` announces nothing is granted bytes the old decoder reads,
##   and the ordinary client, which announces, is granted the cap.
## * The cap block round-trips in `LeaseGranted` and per decision in a
##   batch (beside a reclaimed flag), and a grant naming a basis only a
##   launcher can name is refused.
## * CLIENT TO DAEMON. `lfCapExceeded` is appended, so every earlier
##   ordinal keeps its meaning; it carries kill evidence like an OOM kill; a
##   cap-exceeded finish without the memory-cap block is refused as a
##   contradiction; the block round-trips at presence bit 64 and unknown
##   flag bits are refused; and toward a daemon below the minor a cap kill
##   is reported as the OOM kill it also is (`finishForDaemon`), since such a
##   daemon refuses the ordinal.
## * `ExpectGrowth` / `GrowthExpectation` round-trip and refuse trailing
##   bytes and unknown actions.
##
## Falsifying mutations: the daemon sending the cap whatever the client
## announced (`sendsMemoryCap` always true) turns the end-to-end case red at
## the old decoder; the encoder writing the flags word unconditionally turns
## the byte-identity case red; dropping the block check in
## `decodeLeaseFinished` lets the block-less cap-exceeded finish through.
##
## NO MOCKS: the real codec over real byte strings, and a real `runquotad`.

import std/[options, os, unittest]

import runquota_client
import runquota_codec
import runquota_core
import runquota_ipc
import runquota_protocol

when defined(posix):
  import private_daemon_fixture

proc oldGranted(): string =
  ## A minor-13 daemon's `LeaseGranted` for a grant that is not reclaimed.
  var w = writer()
  w.writeU64(7'u64)
  w.writeU64(10'u64)
  w.writeResourceVector(resourceVector(milliCpu(3000), bytes(1024'u64)))
  w.data

proc minor13DecodesGranted(payload: string): bool =
  ## A minor-13 client's `decodeLeaseGranted`, as it shipped: the resources,
  ## an optional flags word, and nothing after it.
  var r = reader(payload)
  var sessionRaw, leaseRaw: uint64
  var resources: ResourceVector
  var flags: uint32
  if not r.readU64(sessionRaw): return false
  if not r.readU64(leaseRaw): return false
  if not r.readResourceVector(resources): return false
  if r.remaining != 0:
    if not r.readU32(flags): return false
  r.remaining == 0

proc grantCap(cap: uint64; basis = mcbLearned): GrantMemoryCap =
  GrantMemoryCap(known: true, capBytes: cap, basis: basis,
    previousMaxBytes: cap div 2'u64, factorMilli: 2_000'u32,
    budgetBytes: 16'u64 shl 30)

proc granted(cap = GrantMemoryCap(known: false);
             reclaimed = false): LeaseGrantedMessage =
  LeaseGrantedMessage(sessionId: sessionId(7), leaseId: leaseId(10),
    resources: resourceVector(milliCpu(3000), bytes(1024'u64)),
    reclaimed: reclaimed, memoryCap: cap)

proc decision(candidate, lease: uint64; kind: LeaseDecisionKind;
              cap = GrantMemoryCap(known: false);
              reclaimed = false): LeaseDecision =
  LeaseDecision(clientCandidateId: candidate, leaseId: leaseId(lease),
    kind: kind, resources: resourceVector(milliCpu(3000), bytes(1024'u64)),
    diagnostic: okDiagnostic(), reclaimed: reclaimed, memoryCap: cap)

proc finished(finish: LeaseFinish;
              cap = FinishMemoryCap(present: false)): LeaseFinishedMessage =
  LeaseFinishedMessage(sessionId: sessionId(7), leaseId: leaseId(10),
    finish: finish, peakMemoryBytes: 5'u64, processCount: 1'u32,
    diagnostic: okDiagnostic(), totals: FinishTotals(known: false),
    cpuProfile: noCpuProfile(), sizing: noFinishSizing(), memoryCap: cap)

proc capBlock(cap, peak: uint64; basis = mcbLearned; reached = false;
           advisory = false): FinishMemoryCap =
  FinishMemoryCap(present: true, capBytes: cap, basis: basis,
    treePeakBytes: peak, peakSource: mpsCgroup, capReached: reached,
    exceededAdvisory: advisory)

suite "test_rqm_protocol_compatibility":
  test "minor 14 announces the memory cap on every platform":
    check MemoryCapMinor == 14'u16
    check RqspProtocolMinor >= MemoryCapMinor
    check clientMinorAnnouncement() == "rqsp-minor=" & $RqspProtocolMinor
    check announcedClientMinor("m1-lease rqsp-minor=14 pidns=5") == 14'u16
    check announcedClientMinor("m1-lease") == 0'u16
    check announcedClientMinor("") == 0'u16
    # A malformed announcement reads as none: the daemon then sends the
    # bytes an older client expects, which is the safe side.
    check announcedClientMinor("rqsp-minor=") == 0'u16
    check announcedClientMinor("rqsp-minor=1x") == 0'u16
    check announcedClientMinor("rqsp-minor=70000") == 0'u16

  test "a grant without a cap is minor 13's bytes; with one, minor 13 refuses it":
    check encodeLeaseGranted(granted()) == oldGranted()
    check minor13DecodesGranted(encodeLeaseGranted(granted()))
    check minor13DecodesGranted(encodeLeaseGranted(granted(reclaimed = true)))
    let capped = encodeLeaseGranted(granted(grantCap(2'u64 shl 30)))
    check not minor13DecodesGranted(capped)
    var msg: LeaseGrantedMessage
    check decodeLeaseGranted(oldGranted(), msg)
    check not msg.memoryCap.known

  test "the grant's cap block round-trips, beside a reclaimed flag":
    let cap = grantCap(3'u64 shl 30, mcbDeclared)
    var msg: LeaseGrantedMessage
    check decodeLeaseGranted(encodeLeaseGranted(granted(cap,
      reclaimed = true)), msg)
    check msg.reclaimed
    check msg.memoryCap == cap
    check decodeLeaseGranted(encodeLeaseGranted(granted(cap)), msg)
    check not msg.reclaimed
    check msg.memoryCap == cap
    check not decodeLeaseGranted(encodeLeaseGranted(granted(cap)) & "x", msg)

  test "a grant may not name a basis only a launcher decides":
    for basis in [mcbNone, mcbRunSize, mcbRunLifted]:
      checkpoint($basis)
      var msg: LeaseGrantedMessage
      check not decodeLeaseGranted(encodeLeaseGranted(granted(
        grantCap(1'u64 shl 30, basis))), msg)

  test "decision batches: caps per decision, and minor 13's bytes without":
    let plain = LeaseDecisionBatchMessage(sessionId: sessionId(7),
      decisions: @[decision(1, 10, leaseDecisionGranted),
                   decision(2, 11, leaseDecisionQueued)])
    var w = writer()
    w.writeU64(7'u64)
    w.writeU32(2'u32)
    for (candidate, lease, kind) in [(1'u64, 10'u64, leaseDecisionGranted),
        (2'u64, 11'u64, leaseDecisionQueued)]:
      w.writeU64(candidate)
      w.writeU64(lease)
      w.writeU32(uint32(ord(kind)))
      w.writeResourceVector(resourceVector(milliCpu(3000), bytes(1024'u64)))
      w.writeDiagnostic(okDiagnostic())
    check encodeLeaseDecisionBatch(plain) == w.data
    let first = grantCap(1'u64 shl 30)
    let third = grantCap(5'u64 shl 30, mcbBudget)
    let batch = LeaseDecisionBatchMessage(sessionId: sessionId(7),
      decisions: @[decision(1, 10, leaseDecisionGranted, first),
                   decision(2, 11, leaseDecisionQueued, reclaimed = false),
                   decision(3, 12, leaseDecisionGranted, third,
                     reclaimed = true)])
    var msg: LeaseDecisionBatchMessage
    check decodeLeaseDecisionBatch(encodeLeaseDecisionBatch(batch), msg)
    check msg.decisions.len == 3
    check msg.decisions[0].memoryCap == first
    check not msg.decisions[1].memoryCap.known
    check msg.decisions[2].memoryCap == third
    check msg.decisions[2].reclaimed
    check not msg.decisions[0].reclaimed
    # A flagged decision whose block is missing is refused.
    let bytes = encodeLeaseDecisionBatch(batch)
    check not decodeLeaseDecisionBatch(bytes[0 ..< bytes.len - 4], msg)

  test "lfCapExceeded is appended and carries kill evidence":
    check ord(lfTimedOut) == 6
    check ord(lfCapExceeded) == 7
    let bySignal = capExceeded(killedBySignal(9'u32))
    check bySignal.wireSignal == 9'u32 and bySignal.wireExitCode == 0'u32
    check bySignal.exitStatus == 137'u32
    let byStatus = capExceeded(killedWithExitCode(2'u32))
    check byStatus.wireExitCode == 2'u32 and byStatus.wireSignal == 0'u32
    check byStatus.exitStatus == 2'u32
    var finish: LeaseFinish
    check leaseFinishFromWire(7'u32, 0'u32, 9'u32, finish) == ""
    check finish.kind == lfCapExceeded and finish.kill.signal == 9'u32
    check leaseFinishFromWire(7'u32, 0'u32, 0'u32, finish).len > 0
    check leaseFinishFromWire(7'u32, 1'u32, 9'u32, finish).len > 0
    check leaseFinishFromWire(8'u32, 0'u32, 9'u32, finish).len > 0

  test "a cap-exceeded finish needs its memory-cap block":
    var msg: LeaseFinishedMessage
    check decodeLeaseFinished(encodeLeaseFinished(finished(
      capExceeded(killedBySignal(9'u32)))), msg) == lfdContradictoryFinish
    let cap = capBlock(2'u64 shl 30, 3'u64 shl 30)
    check decodeLeaseFinished(encodeLeaseFinished(finished(
      capExceeded(killedBySignal(9'u32)), cap)), msg) == lfdOk
    check msg.finish.kind == lfCapExceeded
    check msg.memoryCap == cap

  test "the finish's block round-trips with its flags, and refuses unknown ones":
    for cap in [capBlock(1'u64 shl 30, 2'u64 shl 30, advisory = true),
                capBlock(1'u64 shl 30, 1'u64 shl 30, mcbRunSize, reached = true),
                capBlock(0'u64, 7'u64 shl 30, mcbRunLifted),
                capBlock(4'u64 shl 30, 1'u64 shl 30, mcbBudget)]:
      checkpoint($cap)
      var msg: LeaseFinishedMessage
      check decodeLeaseFinished(encodeLeaseFinished(finished(succeeded(),
        cap)), msg) == lfdOk
      check msg.memoryCap == cap
    # No block: no presence bit, so the finish has no trailing block at all.
    let bare = encodeLeaseFinished(finished(succeeded()))
    var msg: LeaseFinishedMessage
    check decodeLeaseFinished(bare, msg) == lfdOk
    check not msg.memoryCap.present
    # The flags byte is the last byte of the block: an unknown bit refuses.
    var flagged = encodeLeaseFinished(finished(succeeded(),
      capBlock(1'u64 shl 30, 1'u64 shl 30)))
    flagged[^1] = char(4)
    check decodeLeaseFinished(flagged, msg) == lfdMalformedPayload
    # A block naming no basis is not one a launcher sends.
    var noBasis = capBlock(1'u64 shl 30, 1'u64 shl 30)
    noBasis.basis = mcbNone
    check decodeLeaseFinished(encodeLeaseFinished(finished(succeeded(),
      noBasis)), msg) == lfdMalformedPayload

  test "a daemon below the minor is told an OOM kill with the same evidence":
    let killed = capExceeded(killedBySignal(9'u32))
    let downgraded = finishForDaemon(killed, memoryCapSupported = false)
    check downgraded.kind == lfOomKilled
    check downgraded.kill.bySignal and downgraded.kill.signal == 9'u32
    check finishForDaemon(killed, memoryCapSupported = true).kind ==
      lfCapExceeded
    check finishForDaemon(succeeded(), false).kind == lfSucceeded

  test "ExpectGrowth and its answer round-trip":
    let request = ExpectGrowthMessage(commandStatsId: "cc foo.c",
      action: egSet, sizeBytes: 8'u64 shl 30)
    var decoded: ExpectGrowthMessage
    check decodeExpectGrowth(encodeExpectGrowth(request), decoded)
    check decoded == request
    check not decodeExpectGrowth(encodeExpectGrowth(request) & "x", decoded)
    var bad = encodeExpectGrowth(request)
    bad[4 + request.commandStatsId.len] = char(3) # the action byte
    check not decodeExpectGrowth(bad, decoded)
    let answer = GrowthExpectationMessage(found: true,
      maxObservedPeakBytes: 1, declaredCapBytes: 2, declaredByUid: 3,
      declaredUnixMillis: 4, lastBreachCapBytes: 5, lastBreachPeakBytes: 6,
      lastBreachUnixMillis: 7, conservativeMemoryBytes: 8, factorMilli: 9)
    var back: GrowthExpectationMessage
    check decodeGrowthExpectation(encodeGrowthExpectation(answer), back)
    check back == answer
    check not decodeGrowthExpectation(encodeGrowthExpectation(answer) & "x",
      back)

when defined(posix):
  proc rawRequest(connection: var LocalConnection; kind: RqspMessageKind;
                  requestId: uint64; payload: string): RqspFrame =
    connection.sendFrame(encodeFrame(kind, FrameFlagRequest, requestId,
      payload))
    var diagnosticSeen: Diagnostic
    prerequisite(connection.receiveFrame(result, diagnosticSeen,
      timeoutMs = 10_000), "no answer to " & $kind & ": " &
      diagnosticSeen.message)

  suite "test_rqm_protocol_compatibility against a daemon":
    test "a client that announces nothing is granted minor 13's bytes":
      let root = scratchDir("rqmwire")
      defer: removeDir(root)
      let socket = root / "d.sock"
      writeFile(root / "host.toml", "[machine]\nmemory_bytes = " &
        $(16'u64 shl 30) & "\ncpu_milli = 8000\n")
      let daemon = launch(root, socket, privateEnv(socket))
      defer: stopOwned(daemon)
      prerequisite(awaitSocket(daemon, socket), "runquotad did not bind")
      putEnv("RUNQUOTA_ENDPOINT_SCOPE", "private")
      putEnv("RUNQUOTA_SOCKET", socket)

      # An OLDER CLIENT: its Hello carries the capabilities a minor-13
      # client sent, with no minor announcement.
      var connection = connectEndpoint(endpointForPath(socket))
      defer: connection.close()
      let hello = rawRequest(connection, rqHello, 1, encodeHello(HelloMessage(
        clientName: "minor-13", clientVersion: "0",
        minProtocolMajor: RqspProtocolMajor,
        maxProtocolMajor: RqspProtocolMajor,
        processId: uint64(getCurrentProcessId()),
        userId: uint64(currentProcessOwnerId().get(0)),
        desiredCapabilities: "m1-lease")))
      check hello.header.messageKind == rqHelloOk
      let registered = rawRequest(connection, rqRegisterSession, 2,
        encodeRegisterSession(RegisterSessionMessage(name: "minor-13",
          version: "0", metadata: metadataNone())))
      var session: SessionRegisteredMessage
      prerequisite(decodeSessionRegistered(registered.payload, session),
        "no session")
      let grant = rawRequest(connection, rqRequestLease, 3,
        encodeLeaseRequest(LeaseRequestMessage(sessionId: session.sessionId,
          label: "old", commandStatsId: "old-client",
          resources: resourceVector(milliCpu(1000), bytes(1'u64 shl 30)),
          deadline: noDeadline(), priority: priorityNormal,
          purpose: leasePurposeWork, metadata: metadataNone())))
      check grant.header.messageKind == rqLeaseGranted
      check minor13DecodesGranted(grant.payload)
      var oldView: LeaseGrantedMessage
      check decodeLeaseGranted(grant.payload, oldView)
      check not oldView.memoryCap.known

      # The ordinary client announces the minor, and is granted the cap.
      var client = runquota_client.connectDefault()
      defer: client.close()
      var current = client.registerSession("current", "0")
      var lease = current.requestLease(resourceRequest("new",
        milliCpu(1000), bytes(1'u64 shl 30)))
      check lease.memoryCap.known
      check lease.memoryCap.basis == mcbBudget
      # B − H: the older client's 1 GiB lease is still held.
      check lease.memoryCap.capBytes == (16'u64 shl 30) - (1'u64 shl 30)
      lease.release()
      current.closeSession()
