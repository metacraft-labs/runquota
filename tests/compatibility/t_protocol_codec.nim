import std/unittest

import runquota_codec
import runquota_core
import runquota_protocol

suite "RQSP protocol and codec":
  test "frame header round trips request metadata":
    let payload = encodeHello(HelloMessage(
      clientName: "test",
      clientVersion: "0.1.0",
      minProtocolMajor: RqspProtocolMajor,
      maxProtocolMajor: RqspProtocolMajor,
      processId: 10'u64,
      userId: 20'u64,
      desiredCapabilities: "m1"
    ))
    let encoded = encodeFrame(rqHello, FrameFlagRequest, 7'u64, payload)
    var frame: RqspFrame
    check decodeFrame(encoded, frame)
    check frame.header.messageKind == rqHello
    check frame.header.requestId == 7'u64
    var hello: HelloMessage
    check decodeHello(frame.payload, hello)
    check hello.clientName == "test"

  test "binary envelope keeps metadata separate from JSON views":
    let envelope = BinaryEnvelope(
      tag: envelopeProtocolPayload,
      version: 1'u16,
      metadata: cborMetadataPlaceholder("opaque"),
      payload: "payload"
    )
    var decoded: BinaryEnvelope
    check decodeEnvelope(encodeEnvelope(envelope), decoded) == codecOk
    check decoded.metadata.kind == metadataCborPlaceholder
    check decoded.payload == "payload"
    check inspectionResourceJson(resourceVector(milliCpu(1000), bytes(128))) ==
      "{\"cpu_milli\":1000,\"memory_bytes\":128,\"hard_memory_limit_bytes\":0,\"io_class\":\"ioNormal\",\"process_count\":1,\"named_pools\":[]}"

  test "compatibility rejects unsupported major versions":
    let result = compatible(HelloMessage(
      clientName: "old",
      clientVersion: "0.0.1",
      minProtocolMajor: 2'u16,
      maxProtocolMajor: 2'u16,
      processId: 1'u64,
      userId: 1'u64,
      desiredCapabilities: ""
    ))
    check not result.compatible
    check result.diagnostic.code == diagUnsupportedVersion

  test "lease lifecycle messages keep child completion explicit":
    let running = LeaseRunningMessage(
      sessionId: sessionId(1),
      leaseId: leaseId(2),
      childProcessId: 123'u64,
      processGroupId: 456'u64,
      cleanupRegistered: false
    )
    var decodedRunning: LeaseRunningMessage
    check decodeLeaseRunning(encodeLeaseRunning(running), decodedRunning)
    check decodedRunning.leaseId.value == 2'u64
    check decodedRunning.childProcessId == 123'u64

    let finished = LeaseFinishedMessage(
      sessionId: sessionId(1),
      leaseId: leaseId(2),
      outcome: leaseFinishCrashed,
      exitCode: 0'u32,
      signal: 11'u32,
      peakMemoryBytes: 4096'u64,
      processCount: 2'u32,
      majorPageFaults: 3'u64,
      pressureEvents: 1'u32,
      hardLimitOrOom: true,
      diagnostic: diagnostic(diagCancelled, "child crashed")
    )
    var decodedFinished: LeaseFinishedMessage
    check decodeLeaseFinished(encodeLeaseFinished(finished), decodedFinished)
    check decodedFinished.outcome == leaseFinishCrashed
    check decodedFinished.signal == 11'u32
    check decodedFinished.peakMemoryBytes == 4096'u64
    check decodedFinished.hardLimitOrOom

  test "status reports supervisor-lost and finished leases separately":
    let status = DaemonStatusMessage(
      activeSessions: 0'u32,
      activeLeases: 1'u32,
      queuedLeases: 0'u32,
      supervisorLostLeases: 1'u32,
      finishedLeases: 0'u32,
      totalGranted: 3'u64,
      totalFinished: 0'u64
    )
    var decoded: DaemonStatusMessage
    check decodeStatus(encodeStatus(status), decoded)
    check decoded.supervisorLostLeases == 1'u32
    check decoded.finishedLeases == 0'u32
    check inspectionStatusJson(decoded) ==
      "{\"active_sessions\":0,\"active_leases\":1,\"queued_leases\":0,\"supervisor_lost_leases\":1,\"finished_leases\":0,\"total_granted\":3,\"total_finished\":0}"
