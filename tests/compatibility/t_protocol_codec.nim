import std/unittest

import runquota_client
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
      "{\"machine_id\":\"local\",\"cpu_milli\":1000,\"memory_bytes\":128,\"hard_memory_limit_bytes\":0,\"io_class\":\"ioNormal\",\"process_count\":1,\"named_pools\":[]}"

  test "a supplied estimate of zero survives the wire as SUPPLIED":
    # PRESENCE IS A FIELD, NOT A SENTINEL, and this is the case that says
    # so: an encoding that used "memoryBytes == 0" to mean "none supplied"
    # would decode this as absent, and the daemon would then fall back to
    # its learned table for a request that explicitly declared zero. That
    # is the second-guessing the pass-through rule forbids, arriving below
    # the level the rule is written at.
    var request = LeaseRequestMessage(
      sessionId: sessionId(1),
      label: "zero-estimate",
      commandStatsId: "codec-key",
      resources: resourceVector(milliCpu(1000), bytes(1024)),
      deadline: noDeadline(),
      priority: priorityNormal,
      purpose: leasePurposeWork,
      metadata: metadataNone(),
      estimate: ClientEstimate(supplied: true, memoryBytes: 0'u64)
    )
    var decodedRequest: LeaseRequestMessage
    check decodeLeaseRequest(encodeLeaseRequest(request), decodedRequest)
    check decodedRequest.estimate.supplied
    check decodedRequest.estimate.memoryBytes == 0'u64

    # And an absent estimate stays absent, so the two are distinguishable
    # in both directions rather than merely in one.
    request.estimate = ClientEstimate(supplied: false, memoryBytes: 0'u64)
    check decodeLeaseRequest(encodeLeaseRequest(request), decodedRequest)
    check not decodedRequest.estimate.supplied

    # The batched path carries it too. It is a separate encoder and a
    # separate decoder, which is how a field ends up on one path only.
    let candidate = toCandidate(7'u64, ResourceRequest(
      label: "batched",
      commandStatsId: "codec-key",
      resources: resourceVector(milliCpu(1000), bytes(1024)),
      deadline: noDeadline(),
      priority: priorityNormal,
      purpose: leasePurposeWork,
      metadata: metadataNone(),
      estimate: ClientEstimate(supplied: true, memoryBytes: 0'u64)))
    var offer: CandidateOfferMessage
    check decodeCandidateOffer(encodeCandidateOffer(CandidateOfferMessage(
      sessionId: sessionId(1), candidates: @[candidate])), offer)
    check offer.candidates.len == 1
    check offer.candidates[0].estimate.supplied
    check offer.candidates[0].estimate.memoryBytes == 0'u64

  test "a stats query and its answer round trip with the profile attached":
    let query = StatsQueryMessage(
      sessionId: sessionId(0),
      subject: statsSubjectDistribution,
      statsKey: "codec-stats-key",
      scope: statsScopeWireHost,
      span: profileSpanWireAll,
      limit: 5'u32
    )
    var decodedQuery: StatsQueryMessage
    check decodeStatsQuery(encodeStatsQuery(query), decodedQuery)
    check decodedQuery.subject == statsSubjectDistribution
    check decodedQuery.statsKey == "codec-stats-key"
    check decodedQuery.scope == statsScopeWireHost
    check decodedQuery.span == profileSpanWireAll

    let response = StatsResponseMessage(
      subject: statsSubjectDistribution,
      statsKey: "codec-stats-key",
      knowledge: statsKnowledgeWireUnknown,
      scopeApplied: statsScopeWireHost,
      spanApplied: profileSpanWireSingle,
      ownerUidPresent: false,
      ownerUid: 0'u64,
      captureEnabled: true,
      distributions: @[ResourceDistributionWire(
        profile: ProfileIdentityWire(hostId: "host-x",
          profileIdPresent: true, profileId: "profile-x",
          profileHash: "abcd", cpuModel: "Codec CPU", logicalCores: 12'u64),
        knowledge: statsKnowledgeWireUnknown,
        sampleCount: 0'u64, durationMillisMin: 0'u64,
        durationMillisP50: 0'u64, durationMillisP90: 0'u64,
        durationMillisMax: 0'u64, peakRssBytesMax: 0'u64)],
      executions: @[],
      rankings: @[],
      diagnostic: okDiagnostic()
    )
    var decodedResponse: StatsResponseMessage
    check decodeStatsResponse(encodeStatsResponse(response), decodedResponse)
    # AN UNKNOWN ANSWER STILL CARRIES ITS HARDWARE IDENTITY ACROSS THE
    # WIRE, and is still unknown rather than a distribution of zeros.
    check decodedResponse.knowledge == statsKnowledgeWireUnknown
    check decodedResponse.distributions.len == 1
    check decodedResponse.distributions[0].profile.profileId == "profile-x"
    check decodedResponse.distributions[0].profile.cpuModel == "Codec CPU"
    check decodedResponse.distributions[0].profile.logicalCores == 12'u64
    check decodedResponse.distributions[0].knowledge ==
      statsKnowledgeWireUnknown
    check decodedResponse.distributions[0].sampleCount == 0'u64

  test "an extension row whose columns and values disagree is REFUSED":
    # A REFUSAL NO ROUND TRIP CAN REACH, which is why it needed a payload
    # built by hand. `encodeStatsResponse` always writes the two counts
    # from the two sequences it was given, so encode-then-decode can never
    # produce a mispaired row -- and a check nothing constructs the fixture
    # for is a check that has never run. The refusal matters because
    # RunQuota does not know what these columns MEAN (OS-5): it cannot
    # repair a mispairing, and zipping as far as it goes would turn a
    # product's fact into a different fact.
    proc mispaired(columns, values: seq[string]): string =
      var w = writer()
      w.writeU32(uint32(ord(statsSubjectExtensionRows)))
      w.writeBytes("pairing-key")
      w.writeU32(uint32(ord(statsKnowledgeWireKnown)))
      w.writeU32(uint32(ord(statsScopeWireOwner)))
      w.writeU32(uint32(ord(profileSpanWireSingle)))
      w.writeBool(true)
      w.writeU64(4001'u64)
      w.writeBool(true)
      w.writeU32(0'u32) # distributions
      w.writeU32(0'u32) # executions
      w.writeU32(0'u32) # rankings
      w.writeU32(1'u32) # one extension row
      w.writeString("host-pairing")
      w.writeString("exec-pairing")
      w.writeBytes("pairing-key")
      # The profile identity, inline: its writer is private to the
      # protocol module, and the point of this test is to emit bytes the
      # encoder would never emit.
      w.writeString("host-pairing")
      w.writeBool(true)
      w.writeString("profile-pairing")
      w.writeString("hash-pairing")
      w.writeString("Pairing CPU")
      w.writeU64(8'u64)
      w.writeBool(true)
      w.writeU64(4001'u64)
      w.writeU32(uint32(columns.len))
      for name in columns:
        w.writeString(name)
      w.writeU32(uint32(values.len))
      for value in values:
        w.writeString(value)
      w.writeDiagnostic(okDiagnostic())
      w.data

    var decoded: StatsResponseMessage
    # MORE COLUMNS THAN VALUES, and the other way round: a check written as
    # `values.len < columns.len` would pass one and not the other, so both
    # directions are pinned.
    check not decodeStatsResponse(
      mispaired(@["probe_label", "probe_count"], @["only-one"]), decoded)
    check not decodeStatsResponse(
      mispaired(@["probe_label"], @["first", "second"]), decoded)
    # NON-VACUITY: the same builder with the counts AGREEING decodes, so
    # the two refusals above are about the pairing rule and not about a
    # payload this test cannot build correctly at all.
    check decodeStatsResponse(
      mispaired(@["probe_label", "probe_count"], @["a", "7"]), decoded)
    check decoded.extensionRows.len == 1
    check decoded.extensionRows[0].columns == @["probe_label", "probe_count"]
    check decoded.extensionRows[0].values == @["a", "7"]

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

  test "candidate offer truncates an over-long commandStatsId instead of rejecting":
    # Regression: a caller that defaults ``commandStatsId`` to a long, unique
    # action id (> MaxCommandStatsIdBytes) must NOT hard-fail the decode. For a
    # batched ``OfferCandidates`` message that rejected the WHOLE batch — every
    # staged launch failed and the caller's build scheduler stalled with "no
    # progress" — and it was asymmetric with ``label`` (no length cap). The
    # over-long stats hint is now truncated; the candidate still decodes.
    let longId = "reprobuild.test_execute." &
      "t_workspace_pre_push_passes_when_clean_and_published_and_locked"
    check longId.len > MaxCommandStatsIdBytes
    var request = resourceRequest(longId, milliCpu(1000), bytes(128))
    request.commandStatsId = longId
    let offer = CandidateOfferMessage(
      sessionId: sessionId(1),
      candidates: @[toCandidate(7'u64, request)])
    var decoded: CandidateOfferMessage
    check decodeCandidateOffer(encodeCandidateOffer(offer), decoded)
    check decoded.candidates.len == 1
    # ``label`` is preserved in full (it carries no cap); only the stats hint
    # is truncated to the protocol maximum.
    check decoded.candidates[0].label == longId
    check decoded.candidates[0].commandStatsId.len == MaxCommandStatsIdBytes
    check decoded.candidates[0].commandStatsId == longId[0 ..< MaxCommandStatsIdBytes]
