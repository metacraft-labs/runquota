## The wire form of build-wait pressure, and what an older peer sees.
##
## Three compatibility facts, all about bytes:
##
## * a `LeaseFinishedAck` to a finish that did not ask for the expected
##   duration is exactly the 16 bytes of a minor-6 ack, so an older client
##   (which refuses trailing bytes) never meets the new field; an ack that
##   carries it decodes;
## * a `LeaseFinished` that does not ask carries no new presence bit, and
##   one that asks sets bit 2 and decodes with the question;
## * the new message kinds 45-47 are known, and a report is refused with
##   more than `MaxPressureWaitsPerReport` waits, an unknown wait kind or
##   trailing bytes, so a peer cannot make one report cost unbounded work.
##
## The old ack is written field by field, not through the current encoder,
## so the first fact cannot pass by the encoder agreeing with itself.
##
## NO MOCKS: the real codec over real byte strings.

import std/unittest

import runquota_codec
import runquota_core
import runquota_protocol

proc oldAck(session, lease: uint64): string =
  var w = writer()
  w.writeU64(session)
  w.writeU64(lease)
  w.data

suite "the finish exchange":
  test "an ack nobody asked for is byte-identical to minor 6":
    let ack = LeaseFinishedAckMessage(sessionId: sessionId(3),
      leaseId: leaseId(9))
    check encodeLeaseFinishedAck(ack) == oldAck(3, 9)
    var decoded: LeaseFinishedAckMessage
    check decodeLeaseFinishedAck(oldAck(3, 9), decoded)
    check not decoded.expectedKnown

  test "an ack that answers carries the expected duration":
    let ack = LeaseFinishedAckMessage(sessionId: sessionId(3),
      leaseId: leaseId(9), expectedKnown: true,
      expectedUncontendedMillis: 20_000)
    var decoded: LeaseFinishedAckMessage
    check decodeLeaseFinishedAck(encodeLeaseFinishedAck(ack), decoded)
    check decoded.expectedKnown
    check decoded.expectedUncontendedMillis == 20_000
    var short: LeaseFinishedAckMessage
    check not decodeLeaseFinishedAck(oldAck(3, 9) & "\x01\x02", short)

  test "the question is bit 2 of the totals block and decodes":
    var finish = LeaseFinishedMessage(sessionId: sessionId(1),
      leaseId: leaseId(2), finish: succeeded())
    let plain = encodeLeaseFinished(finish)
    finish.wantExpectedDuration = true
    let asking = encodeLeaseFinished(finish)
    # The asking finish is the plain one plus a block of presence bits 4.
    check asking.len == plain.len + 4
    check asking[0 ..< plain.len] == plain
    check asking[plain.len] == '\x04'
    var decoded: LeaseFinishedMessage
    check decodeLeaseFinished(asking, decoded) == lfdOk
    check decoded.wantExpectedDuration
    check not decoded.totals.known
    check decodeLeaseFinished(plain, decoded) == lfdOk
    check not decoded.wantExpectedDuration

suite "PressureReport":
  test "a report round-trips":
    let report = PressureReportMessage(sessionId: sessionId(5),
      queueOnly: true, wallMicros: 3_000_000, someMicros: 2_000_000,
      fullMicros: 1_000_000, waits: @[
        PressureWait(startedAtUnixMillis: 77, lengthMillis: 310_000,
          kind: pwkQueue),
        PressureWait(startedAtUnixMillis: 78, lengthMillis: 1_500,
          kind: pwkSlowdown)])
    var decoded: PressureReportMessage
    check decodePressureReport(encodePressureReport(report), decoded)
    check decoded.sessionId.value == 5
    check decoded.queueOnly
    check decoded.wallMicros == 3_000_000
    check decoded.someMicros == 2_000_000
    check decoded.fullMicros == 1_000_000
    check decoded.waits == report.waits

  test "at most MaxPressureWaitsPerReport waits are written, and more are refused":
    var report = PressureReportMessage(sessionId: sessionId(5))
    for i in 0 ..< MaxPressureWaitsPerReport + 5:
      report.waits.add(PressureWait(lengthMillis: uint64(i), kind: pwkQueue))
    var decoded: PressureReportMessage
    check decodePressureReport(encodePressureReport(report), decoded)
    check decoded.waits.len == MaxPressureWaitsPerReport
    # A hand-written report that claims one more is refused.
    var w = writer()
    w.writeU64(5)
    w.writeU32(0)
    w.writeU64(0)
    w.writeU64(0)
    w.writeU64(0)
    w.writeU32(uint32(MaxPressureWaitsPerReport + 1))
    for i in 0 .. MaxPressureWaitsPerReport:
      w.writeU64(0)
      w.writeU64(0)
      w.writeU8(0)
    check not decodePressureReport(w.data, decoded)

  test "an unknown wait kind or trailing bytes refuse the report":
    let one = encodePressureReport(PressureReportMessage(sessionId: sessionId(5),
      waits: @[PressureWait(lengthMillis: 1, kind: pwkClassQueue)]))
    var decoded: PressureReportMessage
    check decodePressureReport(one, decoded)
    var bad = one
    bad[^1] = '\x03'
    check not decodePressureReport(bad, decoded)
    check not decodePressureReport(one & "\x00", decoded)

  test "unknown flag bits are ignored":
    var w = writer()
    w.writeU64(5)
    w.writeU32(0xFFFF_FFFE'u32)
    w.writeU64(1)
    w.writeU64(1)
    w.writeU64(1)
    w.writeU32(0)
    var decoded: PressureReportMessage
    check decodePressureReport(w.data, decoded)
    check not decoded.queueOnly

suite "kinds and the minor":
  test "45, 46 and 47 are the pressure messages, announced by minor 7":
    var kind: RqspMessageKind
    check messageKindFromWire(45'u16, kind) and kind == rqPressureReport
    check messageKindFromWire(46'u16, kind) and kind == rqQueryPressure
    check messageKindFromWire(47'u16, kind) and kind == rqPressureAnswer
    check PressureMinor == 7'u16
    check RqspProtocolMinor >= PressureMinor

  test "a query round-trips and refuses an unknown scope":
    var decoded: QueryPressureMessage
    check decodeQueryPressure(encodeQueryPressure(QueryPressureMessage(
      scope: psGroups, groupName: "g")), decoded)
    check decoded.scope == psGroups and decoded.groupName == "g"
    var w = writer()
    w.writeU8(4)
    w.writeString("")
    check not decodeQueryPressure(w.data, decoded)
