## The wire form of the sizing declarations and figures (protocol minor 9,
## `SizingMinor`), and what an older peer sees.
##
## * `RegisterSession`'s sizing block follows the group block; a
##   registration without one is byte-identical to minor 8's, and a sizing
##   block with no group writes an empty group name that only a sizing block
##   may follow.
## * `LeaseFinished`'s totals block gains bits 3-5 (memory profile, IO
##   bytes, `after` lease ids); a finish without them is byte-identical to
##   minor 8's, and the receiver refuses a list longer than
##   `MaxAfterLeases`, a zero-interval profile and trailing bytes.
## * `QuerySizing` round trips and refuses unknown values.
##
## The older payloads are written field by field here, not through the
## current encoder, so "decodes as before" cannot pass by the encoder
## agreeing with itself. NO MOCKS: the real codec over real byte strings.

import std/unittest

import runquota_codec
import runquota_core
import runquota_protocol

proc minor8RegisterSession(): string =
  var w = writer()
  w.writeString("s")
  w.writeString("1")
  w.writeMetadata(metadataNone())
  w.data

suite "sizing codec":
  test "no declaration encodes to the minor-8 bytes":
    check encodeRegisterSession(RegisterSessionMessage(name: "s",
      version: "1", metadata: metadataNone())) == minor8RegisterSession()

  test "a project without a group round trips as no group":
    let sent = RegisterSessionMessage(name: "s", version: "1",
      metadata: metadataNone(), project: "codetracer", entryPoint: "test")
    var got: RegisterSessionMessage
    check decodeRegisterSession(encodeRegisterSession(sent), got)
    check got.group.name.len == 0
    check got.project == "codetracer"
    check got.entryPoint == "test"

  test "a project with a group keeps both":
    let sent = RegisterSessionMessage(name: "s", version: "1",
      metadata: metadataNone(), project: "p", entryPoint: "",
      group: SessionGroupDeclaration(name: "host:1",
        priority: sessionPriorityNormal))
    var got: RegisterSessionMessage
    check decodeRegisterSession(encodeRegisterSession(sent), got)
    check got.group.name == "host:1"
    check got.project == "p"
    check got.entryPoint == ""

  test "an empty group name with no sizing block after it is refused":
    var w = writer()
    w.writeString("s")
    w.writeString("1")
    w.writeMetadata(metadataNone())
    w.writeString("")
    w.writeBool(false)
    w.writeU32(0)
    w.writeBool(false)
    w.writeU64(0)
    var got: RegisterSessionMessage
    check not decodeRegisterSession(w.data, got)

  test "an over-long declaration is refused":
    let sent = RegisterSessionMessage(name: "s", version: "1",
      metadata: metadataNone(), project: newString(MaxSizingDeclarationBytes + 1))
    var got: RegisterSessionMessage
    check not decodeRegisterSession(encodeRegisterSession(sent), got)

  test "a finish without sizing figures is byte-identical to minor 8":
    let base = LeaseFinishedMessage(sessionId: sessionId(1),
      leaseId: leaseId(2), finish: succeeded(),
      totals: FinishTotals(known: true, cpuUserMicros: 5, durationMillis: 9))
    var withNone = base
    withNone.sizing = noFinishSizing()
    check encodeLeaseFinished(withNone) == encodeLeaseFinished(base)

  test "memory profile, IO and after round trip":
    var sent = LeaseFinishedMessage(sessionId: sessionId(1),
      leaseId: leaseId(2), finish: succeeded())
    sent.sizing = FinishSizing(
      memoryProfile: MemoryProfile(intervalMillis: 1000,
        samplesMiB: @[1'u16, 4096, 65535]),
      io: IoTotals(known: true, readBytes: 7, writeBytes: 1 shl 40),
      afterKnown: true, afterLeases: @[3'u64, 4, 5])
    var got: LeaseFinishedMessage
    check decodeLeaseFinished(encodeLeaseFinished(sent), got) == lfdOk
    check got.sizing.memoryProfile == sent.sizing.memoryProfile
    check got.sizing.io == sent.sizing.io
    check got.sizing.afterKnown
    check got.sizing.afterLeases == @[3'u64, 4, 5]
    check not got.totals.known

  test "a declared empty after list stays declared":
    var sent = LeaseFinishedMessage(sessionId: sessionId(1),
      leaseId: leaseId(2), finish: succeeded())
    sent.sizing = FinishSizing(afterKnown: true)
    var got: LeaseFinishedMessage
    check decodeLeaseFinished(encodeLeaseFinished(sent), got) == lfdOk
    check got.sizing.afterKnown
    check got.sizing.afterLeases.len == 0

  test "a list over the bound is not sent, and is refused when received":
    var sent = LeaseFinishedMessage(sessionId: sessionId(1),
      leaseId: leaseId(2), finish: succeeded())
    sent.sizing = FinishSizing(afterKnown: true)
    for i in 0 .. MaxAfterLeases:
      sent.sizing.afterLeases.add(uint64(i))
    var got: LeaseFinishedMessage
    check decodeLeaseFinished(encodeLeaseFinished(sent), got) == lfdOk
    check not got.sizing.afterKnown
    # Hand-written: bit 5 with a count above the bound.
    var w = writer()
    w.writeU32(32)
    w.writeU16(uint16(MaxAfterLeases + 1))
    let prefix = encodeLeaseFinished(LeaseFinishedMessage(
      sessionId: sessionId(1), leaseId: leaseId(2), finish: succeeded()))
    var payload = prefix & w.data
    for i in 0 .. MaxAfterLeases:
      var item = writer()
      item.writeU64(uint64(i))
      payload.add(item.data)
    check decodeLeaseFinished(payload, got) == lfdMalformedPayload

  test "a zero-interval memory profile is refused":
    let prefix = encodeLeaseFinished(LeaseFinishedMessage(
      sessionId: sessionId(1), leaseId: leaseId(2), finish: succeeded()))
    var w = writer()
    w.writeU32(8)
    w.writeU32(0)
    w.writeU16(1)
    w.writeU16(5)
    var got: LeaseFinishedMessage
    check decodeLeaseFinished(prefix & w.data, got) == lfdMalformedPayload

  test "QuerySizing round trips and refuses unknown values":
    let sent = QuerySizingMessage(what: swSizing, project: "p",
      entryPoint: "build", cpus: @[2'u32, 8, 16], quantilePpm: 950_000,
      sinceMillis: 86_400_000, allProfiles: true, allUsers: false,
      redaction: srStrict, offset: 7)
    var got: QuerySizingMessage
    check decodeQuerySizing(encodeQuerySizing(sent), got)
    check got == sent
    var bytes = encodeQuerySizing(sent)
    bytes[0] = char(3)
    check not decodeQuerySizing(bytes, got)
    check not decodeQuerySizing(encodeQuerySizing(sent) & "x", got)

  test "SizingMinor is announced":
    check RqspProtocolMinor >= SizingMinor
