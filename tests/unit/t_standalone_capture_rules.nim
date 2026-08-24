## M14, the deterministic half: the rules daemonless capture is made of.
##
## NO MOCKS. Everything here is a pure function, the real buffer object
## from ``runquota_client/standalone``, or the real wire codec from
## ``runquota_protocol``. There is no daemon, no socket, and no substitute
## for either; the half that needs a real ``runquotad``, a real build, a
## real test run and a fixture a well-behaved client cannot produce is
## ``tests/integration/t_standalone_daemonless_degradation``.
##
## WHY THIS FILE EXISTS SEPARATELY, AND WHY EVERY CLAUSE IN IT IS SUSPECT
## BY DEFAULT. M14 is a milestone about what does NOT happen: a run that
## does not fail, a window that is not marked complete, a flush that
## happens once and not twice, a database write that never occurs. The
## campaign's working conventions say a refusal or a degradation asserted
## where it is convenient to reach is the defect behind twelve-plus checks
## that could not fail — and the convenient place to reach all of these is
## from outside a client, driving it the way a well-behaved one would,
## where none of them can be produced at all. So they are asserted here on
## the buffer's own state transitions and on the pure wire predicate, at
## the exact values that straddle each boundary, WITH THE ACCEPTING CASE
## BESIDE EVERY REFUSING ONE. A rule that fires on everything is not a
## rule.

import std/[strutils, unittest]

import runquota_client
import runquota_core
import runquota_protocol

proc sampleRecord(label: string; exitStatus = 0'u32): DeferredExecutionRecord =
  deferredRecord(
    label = label,
    commandStatsId = "stats-" & label,
    startedAtUnixMillis = 1_700_000_000_000'u64,
    finishedAtUnixMillis = 1_700_000_000_500'u64,
    outcome = if exitStatus == 0: leaseFinishSucceeded else: leaseFinishFailed,
    exitStatus = exitStatus,
    signal = 0'u32,
    peakRssBytes = 4_000_000'u64,
    processCount = 1'u32)

suite "standalone_capture_rules":

  # -------------------------------------------------------------------------
  # The window is never complete
  # -------------------------------------------------------------------------

  test "a standalone window is incomplete whether or not anything was dropped":
    # BOTH ARMS, because the failure mode this guards against is a
    # completeness verdict computed FROM THE DROP COUNT. Such an
    # implementation reports `degraded` on a buffer that overflowed and
    # `complete` on one that happened to fit, which puts a window nothing
    # ever drained into the store as an authoritative one on precisely the
    # runs small enough to fit — the common case, not the rare one.
    var roomy = initStandaloneCapture("t", "1", "standalone", clLongLived,
      capacity = 8)
    check roomy.completeness == ccDegraded
    for i in 0 ..< 3:
      roomy.record(sampleRecord("e" & $i))
    check roomy.bufferedCount == 3
    check roomy.droppedObservations == 0'u32
    check roomy.completeness == ccDegraded

    var tight = initStandaloneCapture("t", "1", "standalone", clLongLived,
      capacity = 2)
    for i in 0 ..< 5:
      tight.record(sampleRecord("e" & $i))
    check tight.droppedObservations == 3'u32
    check tight.completeness == ccDegraded

    # And `ccComplete` is a value that exists, so "never complete" is a
    # statement about this buffer rather than about an enum with one
    # reachable member.
    check ccDegraded != ccComplete
    check $ccComplete == "complete"

  test "the buffer is bounded, drops the oldest, and counts what it lost":
    var capture = initStandaloneCapture("t", "1", "standalone", clLongLived,
      capacity = 3)
    for i in 0 ..< 7:
      capture.record(sampleRecord("e" & $i))
    check capture.recorded == 7'u64
    check capture.bufferedCount == 3
    check capture.droppedObservations == 4'u32
    # Everything offered is accounted for: nothing vanished uncounted,
    # which is OS-2's requirement that dropped observations be COUNTED.
    check uint64(capture.bufferedCount) + uint64(capture.droppedObservations) ==
      capture.recorded
    # The survivors are the LATEST, not the first three. A buffer that
    # kept the head would describe the start of a build and then go
    # silent, which says less than a window that keeps moving.
    let kept = capture.buffered()
    check kept.len == 3
    check kept[0].label == "e4"
    check kept[2].label == "e6"

  # -------------------------------------------------------------------------
  # The flush at exit: once, or not at all
  # -------------------------------------------------------------------------

  test "a short-lived client drops its buffer and makes no attempt at all":
    var capture = initStandaloneCapture("runquota acquire", "1", "standalone",
      clShortLived)
    capture.record(sampleRecord("only"))
    let plan = capture.planExitFlush()
    check plan.attempt == false
    check plan.reason == sfShortLivedDrop
    # Not merely "did not deliver": no attempt was even planned, which is
    # the difference between the policy and a failed connection.
    check capture.flushAttempts == 0
    check capture.bufferedCount == 0
    check capture.droppedObservations == 1'u32

  test "a long-lived client attempts exactly once, and a second call does not":
    var capture = initStandaloneCapture("test-runner", "1", "standalone",
      clLongLived)
    for i in 0 ..< 4:
      capture.record(sampleRecord("e" & $i))
    let first = capture.planExitFlush()
    check first.attempt
    check first.reason == sfAttempted
    check capture.flushAttempts == 1
    check first.message.records.len == 4
    check first.message.tool == "test-runner"
    check first.message.completeness == ccDegraded

    # THE SECOND CALL IS THE CLAUSE. "A single best-effort flush" is a
    # BOUND, and an exit hook that also runs on an explicit close is the
    # ordinary way a bound like this quietly becomes two.
    let second = capture.planExitFlush()
    check second.attempt == false
    check second.reason == sfAlreadyPlanned
    check capture.flushAttempts == 1

  test "a long-lived client with nothing to say does not connect at all":
    var capture = initStandaloneCapture("test-runner", "1", "standalone",
      clLongLived)
    let plan = capture.planExitFlush()
    check plan.attempt == false
    check plan.reason == sfNothingBuffered
    check capture.flushAttempts == 0

  test "an undelivered flush is a drop, and a delivered one is not":
    # THE TWO OUTCOMES MUST BE DISTINGUISHABLE FROM THE COUNTERS ALONE. A
    # client that emptied its buffer either way and counted neither would
    # report identical numbers whether the daemon was there or not, which
    # is the state OS-2 exists to make impossible.
    var lost = initStandaloneCapture("t", "1", "standalone", clLongLived)
    lost.record(sampleRecord("a"))
    lost.record(sampleRecord("b"))
    check lost.planExitFlush().attempt
    lost.finishExitFlush(delivered = false)
    check lost.droppedObservations == 2'u32
    check lost.deliveredRecords == 0
    check lost.bufferedCount == 0

    var landed = initStandaloneCapture("t", "1", "standalone", clLongLived)
    landed.record(sampleRecord("a"))
    landed.record(sampleRecord("b"))
    check landed.planExitFlush().attempt
    landed.finishExitFlush(delivered = true)
    check landed.droppedObservations == 0'u32
    check landed.deliveredRecords == 2
    check landed.bufferedCount == 0

  # -------------------------------------------------------------------------
  # What the daemon refuses to record
  # -------------------------------------------------------------------------

  test "a batch may say degraded or sampled, and may never say complete":
    let base = DeferredObservationsMessage(
      tool: "test-runner",
      toolVersion: "1",
      invocationKind: "standalone",
      completeness: ccDegraded,
      droppedObservations: 0'u32,
      records: @[sampleRecord("a")])

    # THE ACCEPTING CASES FIRST. A predicate that refuses everything
    # satisfies every refusal below and deletes the feature — the failure
    # mode M11's record names ("clamped at zero" implemented as "always
    # zero").
    check deferredObservationsRefusal(base) == ""
    var sampled = base
    sampled.completeness = ccSampled
    check deferredObservationsRefusal(sampled) == ""

    # THE REFUSAL THIS MILESTONE TURNS ON.
    var complete = base
    complete.completeness = ccComplete
    check deferredObservationsRefusal(complete).len > 0
    check "complete" in deferredObservationsRefusal(complete)

    # And an anonymous batch: rows whose `tool` is empty cannot be
    # attributed to anything, and OS-6-style qualification is the whole
    # reason the spine carries the column.
    var anonymous = base
    anonymous.tool = ""
    check deferredObservationsRefusal(anonymous).len > 0

    # An empty batch that also lost nothing is a `runs` row describing no
    # run at all.
    var vacant = base
    vacant.records = @[]
    check deferredObservationsRefusal(vacant).len > 0
    # ... but an empty batch that DID lose something is a real statement,
    # and refusing it would erase the only record that anything was lost.
    var lossOnly = vacant
    lossOnly.droppedObservations = 12'u32
    check deferredObservationsRefusal(lossOnly) == ""

  test "the buffer can never produce a batch the daemon would refuse":
    # THE TWO HALVES HAVE TO MEET. A client that formed a message the
    # predicate rejects would lose every observation to a refusal it could
    # not see (the flush is one-way), so the buffer's own output is
    # checked against the rule that judges it — including on the run that
    # dropped everything it had.
    var capture = initStandaloneCapture("test-runner", "1", "standalone",
      clLongLived, capacity = 2)
    for i in 0 ..< 6:
      capture.record(sampleRecord("e" & $i))
    let plan = capture.planExitFlush()
    check plan.attempt
    check deferredObservationsRefusal(plan.message) == ""
    check plan.message.droppedObservations == 4'u32

  # -------------------------------------------------------------------------
  # The wire
  # -------------------------------------------------------------------------

  test "a batch survives the wire unchanged, and a damaged one applies nothing":
    let sent = DeferredObservationsMessage(
      tool: "ct test",
      toolVersion: "9.9.9",
      invocationKind: "standalone",
      completeness: ccDegraded,
      droppedObservations: 17'u32,
      records: @[sampleRecord("first"), sampleRecord("second", 3'u32)])
    let payload = encodeDeferredObservations(sent)

    var received: DeferredObservationsMessage
    check decodeDeferredObservations(payload, received)
    check received.tool == sent.tool
    check received.toolVersion == sent.toolVersion
    check received.invocationKind == sent.invocationKind
    check received.completeness == sent.completeness
    check received.droppedObservations == sent.droppedObservations
    check received.records.len == 2
    check received.records[0].label == "first"
    check received.records[0].commandStatsId == "stats-first"
    check received.records[0].startedAtUnixMillis ==
      sent.records[0].startedAtUnixMillis
    check received.records[0].peakRssBytes == sent.records[0].peakRssBytes
    check received.records[1].exitStatus == 3'u32
    check received.records[1].outcome == leaseFinishFailed

    # ALL OR NOTHING, ASSERTED RATHER THAN DESCRIBED. The target is
    # PRE-LOADED with a sentinel and must come back carrying it after
    # every rejected payload. A decoder that filled fields as it read them
    # passes `check not decode(...)` and fails this, and "half a batch was
    # applied" is a run whose record says it had fewer executions than it
    # ran.
    let sentinel = DeferredObservationsMessage(
      tool: "SENTINEL", toolVersion: "SENTINEL", invocationKind: "SENTINEL",
      completeness: ccSampled, droppedObservations: 999'u32, records: @[])

    proc isSentinel(msg: DeferredObservationsMessage): bool =
      msg.tool == "SENTINEL" and msg.toolVersion == "SENTINEL" and
        msg.invocationKind == "SENTINEL" and msg.completeness == ccSampled and
        msg.droppedObservations == 999'u32 and msg.records.len == 0

    var truncated = sentinel
    check not decodeDeferredObservations(payload[0 ..< payload.len - 3],
      truncated)
    check isSentinel(truncated)

    var empty = sentinel
    check not decodeDeferredObservations("", empty)
    check isSentinel(empty)

    # ONE BYTE SHORT OF THE LAST FIELD OF THE LAST RECORD: the reader has
    # consumed a whole batch bar one field, which is the case a
    # field-by-field decoder gets furthest with.
    var almost = sentinel
    check not decodeDeferredObservations(payload[0 ..< payload.len - 1], almost)
    check isSentinel(almost)

    # TRAILING BYTES. A frame carrying more than this message is not this
    # message.
    var trailing = sentinel
    check not decodeDeferredObservations(payload & "\x00", trailing)
    check isSentinel(trailing)

  test "a batch that claims more records than it carries is refused outright":
    # THE ALLOCATION A PEER CAN ASK FOR BEFORE SENDING ANYTHING. The count
    # is a length prefix, so a hostile peer that sets it high and then
    # stops is asking the daemon to reserve on its say-so. The bound is
    # checked BEFORE any record is read.
    proc batch(records: seq[DeferredExecutionRecord]): string =
      encodeDeferredObservations(DeferredObservationsMessage(
        tool: "t", toolVersion: "1", invocationKind: "standalone",
        completeness: ccDegraded, droppedObservations: 0'u32,
        records: records))

    # The fixed part ends with the record count, so the count's four
    # little-endian bytes are the last four of a zero-record encoding, and
    # `completeness` is the four before `droppedObservations` before that.
    let header = batch(@[])
    let countAt = header.len - 4
    let completenessAt = header.len - 12
    let honest = batch(@[sampleRecord("a")])
    var decoded: DeferredObservationsMessage
    check decodeDeferredObservations(honest, decoded)
    check decoded.records.len == 1

    var hostile = honest
    for i in 0 ..< 4:
      hostile[countAt + i] = char(0xFF)
    var refused: DeferredObservationsMessage
    check not decodeDeferredObservations(hostile, refused)
    check MaxDeferredRecords < 0xFFFFFFFF'u32

    # An out-of-range completeness value is refused rather than cast into
    # the enum, which is undefined and could land anywhere — including on
    # `ccComplete`, the one value this message may never carry.
    var badCompleteness = honest
    badCompleteness[completenessAt] = char(200)
    var alsoRefused: DeferredObservationsMessage
    check not decodeDeferredObservations(badCompleteness, alsoRefused)

  # -------------------------------------------------------------------------
  # What a standalone client is allowed to say about statistics
  # -------------------------------------------------------------------------

  test "aggregation and learned estimates are unavailable, not faked":
    let report = standaloneStatsReport()
    check report.aggregation == saUnavailable
    check report.learnedEstimate == saUnavailable
    check report.aggregation != saFaked
    check report.learnedEstimate != saFaked
    check "unavailable" in report.detail
    # And the detail says WHY, because "unavailable" with no cause is
    # indistinguishable from a bug to the person reading it.
    check "runquotad" in report.detail

  test "the operator line reads as a degradation and not as a failure":
    var capture = initStandaloneCapture("runquota acquire", "1", "standalone",
      clShortLived)
    capture.record(sampleRecord("a"))
    let plan = capture.planExitFlush()
    let line = standaloneReport(capture, plan.reason)
    # It says what happened, in the words the store will use.
    check "degraded" in line
    check "no daemon" in line
    check "unavailable" in line
    # AND IT DOES NOT SAY THIS. §"Standalone mode": a missing daemon MUST
    # NOT be reported as an error. A line beginning "error" is what a CI
    # annotation rule and a person skimming a log both act on.
    let lower = line.toLowerAscii()
    check "error" notin lower
    check "fail" notin lower
    check "warning" notin lower
