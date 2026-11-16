## The wire form of RECLAIMED grants (protocol minor 8), and what an older
## peer sees.
##
## A client says it may be given a reclaimed grant with bit 1 of the width
## block's flags; the daemon marks such a grant in an OPTIONAL TRAILING
## block of `LeaseDecisionBatch` (one flags word per decision) and an
## optional trailing flags word of `LeaseGranted`, written only when a
## decision in them is reclaimed. The compatibility facts, all about bytes:
##
## * a batch or grant with no reclaimed decision encodes to exactly the
##   bytes of a minor-7 peer, so a client that never opted in reads every
##   answer it ever gets as before;
## * an older daemon's batch and grant decode, as not reclaimed;
## * the opt-in bit round-trips, and a reader that knows only bit 0
##   (`resizable`) is unaffected by it (bit 1 is in the reserved bits an
##   older daemon ignores);
## * a flags block whose count is not the number of decisions is refused.
##
## The old payloads are written field by field here, not through the current
## encoder, so no fact can pass by the encoder agreeing with itself.
## Falsifying mutations: writing the block unconditionally breaks the first
## case; reading it without checking its count lets the last one through.
##
## NO MOCKS: the real codec over real byte strings.

import std/unittest

import runquota_codec
import runquota_core
import runquota_protocol

proc oldDecision(w: var BinaryWriter; candidate, lease: uint64;
                 kind: LeaseDecisionKind) =
  w.writeU64(candidate)
  w.writeU64(lease)
  w.writeU32(uint32(ord(kind)))
  w.writeResourceVector(resourceVector(milliCpu(3000), bytes(1024'u64)))
  w.writeDiagnostic(okDiagnostic())

proc oldBatch(): string =
  var w = writer()
  w.writeU64(7'u64)
  w.writeU32(2'u32)
  w.oldDecision(1, 10, leaseDecisionGranted)
  w.oldDecision(2, 11, leaseDecisionQueued)
  w.data

proc oldGranted(): string =
  var w = writer()
  w.writeU64(7'u64)
  w.writeU64(10'u64)
  w.writeResourceVector(resourceVector(milliCpu(3000), bytes(1024'u64)))
  w.data

proc decision(candidate, lease: uint64; kind: LeaseDecisionKind;
              reclaimed = false): LeaseDecision =
  LeaseDecision(clientCandidateId: candidate, leaseId: leaseId(lease),
    kind: kind, resources: resourceVector(milliCpu(3000), bytes(1024'u64)),
    diagnostic: okDiagnostic(), reclaimed: reclaimed)

suite "reclaimed grants on the wire":
  test "minor 8 announces them":
    check ReclaimedGrantsMinor == 8'u16
    check RqspProtocolMinor >= ReclaimedGrantsMinor

  test "a batch with no reclaimed decision is byte-identical to minor 7":
    let batch = LeaseDecisionBatchMessage(sessionId: sessionId(7),
      decisions: @[decision(1, 10, leaseDecisionGranted),
                   decision(2, 11, leaseDecisionQueued)])
    check encodeLeaseDecisionBatch(batch) == oldBatch()

  test "an older daemon's batch decodes, as not reclaimed":
    var msg: LeaseDecisionBatchMessage
    check decodeLeaseDecisionBatch(oldBatch(), msg)
    check msg.decisions.len == 2
    check not msg.decisions[0].reclaimed and not msg.decisions[1].reclaimed

  test "a reclaimed decision round-trips in the trailing block":
    let batch = LeaseDecisionBatchMessage(sessionId: sessionId(7),
      decisions: @[decision(1, 10, leaseDecisionQueued),
                   decision(2, 11, leaseDecisionGranted, reclaimed = true)])
    let bytes = encodeLeaseDecisionBatch(batch)
    # The block is the count and one word per decision, after the old bytes.
    check bytes.len > 0
    var msg: LeaseDecisionBatchMessage
    check decodeLeaseDecisionBatch(bytes, msg)
    check msg.decisions.len == 2
    check not msg.decisions[0].reclaimed
    check msg.decisions[1].reclaimed

  test "a flags block whose count differs from the decisions is refused":
    var w = writer()
    w.writeU64(7'u64)
    w.writeU32(1'u32)
    w.oldDecision(1, 10, leaseDecisionGranted)
    # A count of 2 over one decision, with one flags word: the block's
    # length fits one decision, its count does not.
    w.writeU32(2'u32)
    w.writeU32(1'u32)
    var msg: LeaseDecisionBatchMessage
    check not decodeLeaseDecisionBatch(w.data, msg)
    # And a truncated block.
    var t = writer()
    t.writeU64(7'u64)
    t.writeU32(1'u32)
    t.oldDecision(1, 10, leaseDecisionGranted)
    t.writeU32(1'u32)
    check not decodeLeaseDecisionBatch(t.data, msg)

  test "LeaseGranted: identical without the flag, flagged with it":
    check encodeLeaseGranted(LeaseGrantedMessage(sessionId: sessionId(7),
      leaseId: leaseId(10),
      resources: resourceVector(milliCpu(3000), bytes(1024'u64)))) ==
      oldGranted()
    var msg: LeaseGrantedMessage
    check decodeLeaseGranted(oldGranted(), msg)
    check not msg.reclaimed
    let flagged = encodeLeaseGranted(LeaseGrantedMessage(
      sessionId: sessionId(7), leaseId: leaseId(10),
      resources: resourceVector(milliCpu(3000), bytes(1024'u64)),
      reclaimed: true))
    check flagged.len == oldGranted().len + 4
    check decodeLeaseGranted(flagged, msg)
    check msg.reclaimed
    check not decodeLeaseGranted(flagged & "x", msg)

  test "the opt-in is bit 1 of the width flags, beside resizable":
    let request = LeaseRequestMessage(sessionId: sessionId(7), label: "x",
      resources: resourceVector(milliCpu(3000), bytes(1024'u64)),
      deadline: noDeadline(), priority: priorityNormal,
      purpose: leasePurposeWork, metadata: metadataNone(),
      width: WidthRange(present: true, minMilli: 3000, preferredMilli: 3000,
        acceptsReclaimed: true))
    let bytes = encodeLeaseRequest(request)
    # The flags word is the last four bytes, little-endian: 2 = bit 1 only.
    check bytes[^4] == char(2) and bytes[^3] == char(0) and
      bytes[^2] == char(0) and bytes[^1] == char(0)
    var decoded: LeaseRequestMessage
    check decodeLeaseRequest(bytes, decoded)
    check decoded.width.acceptsReclaimed
    check not decoded.width.resizable
    var plain = request
    plain.width.acceptsReclaimed = false
    plain.width.resizable = true
    let plainBytes = encodeLeaseRequest(plain)
    check plainBytes[^4] == char(1)
    check decodeLeaseRequest(plainBytes, decoded)
    check not decoded.width.acceptsReclaimed
