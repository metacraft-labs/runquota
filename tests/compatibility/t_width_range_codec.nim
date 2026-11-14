## The wire form of negotiated widths, and what an older peer sees.
##
## A CPU range travels as an OPTIONAL TRAILING BLOCK: after the client
## estimate of `RequestLease`, and after the last candidate of
## `OfferCandidates` (one entry per candidate). Two compatibility facts
## follow, and both are about bytes:
##
## * a request or offer WITHOUT a range encodes to exactly the bytes of a
##   minor-5 peer, so the current client can still talk to an older daemon;
## * an older client's request and offer decode, as fixed CPU requests.
##
## The old payloads are written field by field here, not through the current
## encoder, so neither fact can pass by the encoder agreeing with itself.
##
## NO MOCKS: the real codec over real byte strings.

import std/unittest

import runquota_codec
import runquota_core
import runquota_protocol

proc oldEstimate(w: var BinaryWriter) =
  w.writeBool(false)
  w.writeU64(0'u64)

proc oldLeaseRequest(cpuMilli: uint32): string =
  var w = writer()
  w.writeU64(7'u64)
  w.writeString("old")
  w.writeBytes("")
  w.writeResourceVector(resourceVector(milliCpu(cpuMilli), bytes(1024'u64)))
  w.writeDeadline(noDeadline())
  w.writeU32(uint32(ord(priorityNormal)))
  w.writeU32(uint32(ord(leasePurposeWork)))
  w.writeMetadata(metadataNone())
  w.oldEstimate()
  w.data

proc oldCandidateOffer(cpuMilli: uint32): string =
  var w = writer()
  w.writeU64(7'u64)
  w.writeU32(1'u32)
  w.writeU64(1'u64)
  w.writeString("old")
  w.writeBytes("")
  w.writeResourceVector(resourceVector(milliCpu(cpuMilli), bytes(1024'u64)))
  w.writeDeadline(noDeadline())
  w.writeU32(uint32(ord(priorityNormal)))
  w.writeU32(uint32(ord(leasePurposeWork)))
  w.writeMetadata(metadataNone())
  w.oldEstimate()
  w.data

proc request(width: WidthRange): LeaseRequestMessage =
  LeaseRequestMessage(sessionId: sessionId(7), label: "old",
    resources: resourceVector(milliCpu(3000), bytes(1024'u64)),
    deadline: noDeadline(), priority: priorityNormal,
    purpose: leasePurposeWork, metadata: metadataNone(), width: width)

proc candidate(id: uint64; cpuMilli: uint32;
               width: WidthRange): LeaseCandidate =
  LeaseCandidate(clientCandidateId: id, label: "old",
    resources: resourceVector(milliCpu(cpuMilli), bytes(1024'u64)),
    deadline: noDeadline(), priority: priorityNormal,
    purpose: leasePurposeWork, metadata: metadataNone(), width: width)

suite "width range codec":
  test "a request without a range is the old bytes, and old bytes decode fixed":
    check encodeLeaseRequest(request(WidthRange())) == oldLeaseRequest(3000)
    var got: LeaseRequestMessage
    check decodeLeaseRequest(oldLeaseRequest(3000), got)
    check not got.width.present
    check got.resources.cpu.value == 3000'u32

  test "a ranged, resizable request round trips; trailing bytes are refused":
    let sent = request(WidthRange(present: true, minMilli: 2000,
      preferredMilli: 16000, resizable: true))
    var got: LeaseRequestMessage
    check decodeLeaseRequest(encodeLeaseRequest(sent), got)
    check got.width == sent.width
    check not decodeLeaseRequest(encodeLeaseRequest(sent) & "x", got)
    check not decodeLeaseRequest(encodeLeaseRequest(sent)[0 .. ^2], got)

  test "reserved flag bits are ignored, not refused":
    var bytes = encodeLeaseRequest(request(WidthRange(present: true,
      minMilli: 1000, preferredMilli: 2000, resizable: false)))
    # The flags are the last u32 (little-endian); set bit 7.
    bytes[bytes.len - 4] = char(0x80)
    var got: LeaseRequestMessage
    check decodeLeaseRequest(bytes, got)
    check got.width.present and not got.width.resizable

  test "an offer without ranges is the old bytes, and old bytes decode fixed":
    let offer = CandidateOfferMessage(sessionId: sessionId(7),
      candidates: @[candidate(1, 3000, WidthRange())])
    check encodeCandidateOffer(offer) == oldCandidateOffer(3000)
    var got: CandidateOfferMessage
    check decodeCandidateOffer(oldCandidateOffer(3000), got)
    check got.candidates.len == 1
    check not got.candidates[0].width.present

  test "ranges travel after the last candidate, one entry per candidate":
    let offer = CandidateOfferMessage(sessionId: sessionId(7), candidates: @[
      candidate(1, 3000, WidthRange()),
      candidate(2, 8000, WidthRange(present: true, minMilli: 2000,
        preferredMilli: 8000, resizable: true))])
    var got: CandidateOfferMessage
    check decodeCandidateOffer(encodeCandidateOffer(offer), got)
    check got.candidates.len == 2
    # A fixed candidate in a ranged offer: its own CPU at both ends.
    check got.candidates[0].width == WidthRange(present: true,
      minMilli: 3000, preferredMilli: 3000, resizable: false)
    check got.candidates[1].width == offer.candidates[1].width
    # A block whose count does not match the candidates is malformed.
    var bytes = encodeCandidateOffer(offer)
    let countAt = bytes.len - 2 * 12 - 4
    bytes[countAt] = char(1)
    check not decodeCandidateOffer(bytes, got)

  test "the resize messages round trip and refuse trailing bytes":
    let grow = LeaseGrowRequestMessage(sessionId: sessionId(1),
      leaseId: leaseId(2), cpuWantedMilli: high(uint32))
    var gotGrow: LeaseGrowRequestMessage
    check decodeLeaseGrowRequest(encodeLeaseGrowRequest(grow), gotGrow)
    check gotGrow.sessionId.value == 1'u64
    check gotGrow.leaseId.value == 2'u64
    check gotGrow.cpuWantedMilli == high(uint32)
    check not decodeLeaseGrowRequest(encodeLeaseGrowRequest(grow) & "x",
      gotGrow)
    let resized = LeaseResizedMessage(sessionId: sessionId(1),
      leaseId: leaseId(2), cpuCurrentMilli: 5000)
    var gotResized: LeaseResizedMessage
    check decodeLeaseResized(encodeLeaseResized(resized), gotResized)
    check gotResized.leaseId.value == 2'u64
    check gotResized.cpuCurrentMilli == 5000'u32
    check not decodeLeaseResized(encodeLeaseResized(resized)[0 .. ^2],
      gotResized)
    let resize = LeaseResizeMessage(sessionId: sessionId(1),
      leaseId: leaseId(2), cpuTargetMilli: 2000, cpuChargedMilli: 8000)
    var gotResize: LeaseResizeMessage
    check decodeLeaseResize(encodeLeaseResize(resize), gotResize)
    check gotResize.leaseId.value == 2'u64
    check gotResize.cpuTargetMilli == 2000'u32
    check gotResize.cpuChargedMilli == 8000'u32

  test "the minor that announces them, and their kinds":
    check NegotiatedWidthsMinor > SubLeaseMinor
    check RqspProtocolMinor >= NegotiatedWidthsMinor
    var kind: RqspMessageKind
    check messageKindFromWire(42'u16, kind) and kind == rqLeaseGrowRequest
    check messageKindFromWire(43'u16, kind) and kind == rqLeaseResize
    check messageKindFromWire(44'u16, kind) and kind == rqLeaseResized
