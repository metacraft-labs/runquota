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
      "{\"cpu_milli\":1000,\"memory_bytes\":128,\"hard_memory_limit_bytes\":0,\"io_class\":\"ioNormal\",\"process_count\":1}"

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
