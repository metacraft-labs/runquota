## M13, the deterministic half: the rules the socket write path is made of.
##
## NO MOCKS. Everything here is a pure function or the real module-level
## self-report live set from ``runquota_observation_store/ambient``; there
## is no daemon, no socket and no substitute for either. The half that
## needs both — a real ``runquotad``, a real client, and the fixtures a
## well-behaved client cannot produce — is
## ``tests/integration/t_observation_socket_write_path``.
##
## WHY THIS FILE EXISTS SEPARATELY. Every clause below is a REFUSAL: a
## report with no sample time, one stamped in the future, one too stale to
## mean anything, a payload that runs out halfway. The campaign's working
## conventions say a refusal asserted where it is convenient to reach is
## the defect that has shipped twelve-plus unfalsifiable checks, and the
## convenient place to reach these is from outside a running daemon, where
## a well-behaved client cannot produce any of them. So they are asserted
## on the pure predicate and on the pure decoder, at the exact values that
## straddle each boundary, with the accepting case beside every refusing
## one — a refusal that fires on everything is not a refusal.

import std/[os, strutils, unittest]

import runquota_core
import runquota_daemon
import runquota_observation_store
import runquota_protocol

suite "observation_write_path_rules":

  # -------------------------------------------------------------------------
  # Capture is on without any flag
  # -------------------------------------------------------------------------

  test "the default store path is host-wide, beside the host identity":
    # THE DEFAULT IS A PATH, NOT AN ABSENCE. `observationDbPath` used to
    # default to "" and "" meant capture off, which made "capture is on
    # without any flag" unstatable.
    check defaultObservationDbFile().len > 0
    check defaultObservationDbFile() == hostWideStateDir / "observations.sqlite3"
    check defaultObservationDbFile().parentDir ==
      defaultHostIdentityFile().parentDir
    # Nothing per-user may appear in it, for the reason `identity.nim`
    # gives: HOME differs between two users of one host, and a host-wide
    # daemon whose store moved with the user would present one machine as
    # several.
    let home = getEnv("HOME")
    if home.len > 0:
      check not defaultObservationDbFile().startsWith(home)

  test "an operator who relocates the host state relocates the store":
    let relocated = observationDbBeside("/somewhere/else/host-id")
    check relocated == "/somewhere/else/observations.sqlite3"
    # An empty argument is the default host, not the current directory.
    check observationDbBeside("") == defaultObservationDbFile()

  test "capture is enabled with no flag at all, and --no-write-stats disables it":
    var config = defaultDaemonConfig()
    config.hostIdentityFilePath = "/scratch/state/host-id"

    # (1) NOTHING SET: the host default. This is the gate clause "asserts
    # capture is on without any flag" at the configuration boundary; the
    # integration file asserts it against rows a real daemon wrote.
    check config.observationDbPath.len == 0
    check config.writeStatsDisabled == false
    check effectiveObservationDbPath(config) == "/scratch/state/observations.sqlite3"

    # (2) AN EXPLICIT PATH WINS OVER THE DEFAULT.
    var explicitConfig = config
    explicitConfig.observationDbPath = "/tmp/named.sqlite3"
    check effectiveObservationDbPath(explicitConfig) == "/tmp/named.sqlite3"

    # (3) THE OFF SWITCH, and it is not "leave the path empty": an empty
    # path is now the default-on case, so the two states have to be
    # distinguishable in the config itself.
    var disabledConfig = config
    disabledConfig.writeStatsDisabled = true
    check effectiveObservationDbPath(disabledConfig) == ""

    # (4) AND IT WINS OVER AN EXPLICIT PATH. `--observation-db X
    # --no-write-stats` is off, in either argument order, rather than
    # ambiguous. Without this the off switch would be silently defeated by
    # a path set in a config file or a wrapper script.
    var bothConfig = explicitConfig
    bothConfig.writeStatsDisabled = true
    check effectiveObservationDbPath(bothConfig) == ""

  # -------------------------------------------------------------------------
  # A hostile or malformed report is refused, not partially applied
  # -------------------------------------------------------------------------

  proc same(a, b: LeaseObservationMessage): bool =
    ## Field-wise because ``SessionId``/``LeaseId`` are distinct types with
    ## no structural ``==``. Every field is compared: a helper that skipped
    ## one would be the thing that lets a half-applied decode through.
    a.sessionId.value == b.sessionId.value and
      a.leaseId.value == b.leaseId.value and
      a.cpuMilliPct == b.cpuMilliPct and
      a.rssBytes == b.rssBytes and
      a.sampledAtUnixMillis == b.sampledAtUnixMillis

  proc observationAt(sampledAt: int64): LeaseObservationMessage =
    LeaseObservationMessage(
      sessionId: sessionId(1),
      leaseId: leaseId(7),
      cpuMilliPct: 12_500'u32,
      rssBytes: 4_000_000_000'u64,
      sampledAtUnixMillis: uint64(max(0'i64, sampledAt)))

  test "a report is accepted only inside the window in which it means anything":
    const now = 1_700_000_000_000'i64

    # THE ACCEPTING CASE FIRST. A predicate that refuses everything
    # satisfies every refusal clause below and destroys the feature, which
    # is the failure mode M11's record calls out by name ("clamped at zero"
    # implemented as "always zero").
    check leaseObservationRefusal(observationAt(now), now) == ""

    # NO SAMPLE TIME AT ALL. Zero is not a plausible instant, and a report
    # that does not say when it was read cannot be judged stale or fresh.
    check leaseObservationRefusal(observationAt(0), now).len > 0
    check "no sample time" in leaseObservationRefusal(observationAt(0), now)

    # FROM THE FUTURE. Accepted up to the stated skew, refused one
    # millisecond past it -- BOTH SIDES OF THE BOUNDARY, because a bound
    # asserted only from the refusing side is satisfied by a predicate that
    # refuses the whole neighbourhood.
    check leaseObservationRefusal(
      observationAt(now + ObservationFutureSkewMillis), now) == ""
    check leaseObservationRefusal(
      observationAt(now + ObservationFutureSkewMillis + 1), now).len > 0
    check "future" in leaseObservationRefusal(
      observationAt(now + ObservationFutureSkewMillis + 1), now)

    # TOO STALE TO SUBTRACT. `foreign = host_total - sum(self)` means
    # nothing unless both terms describe about the same instant; M11 found
    # this the expensive way at a gap of milliseconds.
    check leaseObservationRefusal(
      observationAt(now - ObservationMaxAgeMillis), now) == ""
    check leaseObservationRefusal(
      observationAt(now - ObservationMaxAgeMillis - 1), now).len > 0
    check "stale" in leaseObservationRefusal(
      observationAt(now - ObservationMaxAgeMillis - 1), now)

  test "a report survives the wire unchanged, and a damaged one applies nothing":
    let sent = LeaseObservationMessage(
      sessionId: sessionId(9),
      leaseId: leaseId(4242),
      cpuMilliPct: 1_600_000'u32,
      rssBytes: 68_719_476_736'u64,
      sampledAtUnixMillis: 1_700_000_000_123'u64)
    let payload = encodeLeaseObservation(sent)

    var received: LeaseObservationMessage
    check decodeLeaseObservation(payload, received)
    check same(received, sent)

    # ALL OR NOTHING, ASSERTED RATHER THAN DESCRIBED. The target message is
    # PRE-LOADED with a sentinel and must come back carrying the sentinel
    # unchanged after every rejected payload. A decoder that assigned its
    # fields as it read them -- the obvious implementation -- passes a
    # `check not decode(...)` and fails this, and "half a report was
    # applied" is precisely the state the gate forbids.
    let sentinel = LeaseObservationMessage(
      sessionId: sessionId(999),
      leaseId: leaseId(999),
      cpuMilliPct: 999'u32,
      rssBytes: 999'u64,
      sampledAtUnixMillis: 999'u64)

    var truncated = sentinel
    check not decodeLeaseObservation(payload[0 ..< payload.len - 3], truncated)
    check same(truncated, sentinel)

    var empty = sentinel
    check not decodeLeaseObservation("", empty)
    check same(empty, sentinel)

    # ONE BYTE SHORT OF THE LAST FIELD: the reader has consumed four whole
    # fields and fails on the fifth, which is the case a field-by-field
    # decoder gets furthest with.
    var almost = sentinel
    check not decodeLeaseObservation(payload[0 ..< payload.len - 1], almost)
    check same(almost, sentinel)

    # TRAILING BYTES. A frame carrying more than this message is not this
    # message: silently ignoring the tail is how a length-confusion bug
    # becomes a parser that accepts two different wire shapes.
    var trailing = sentinel
    check not decodeLeaseObservation(payload & "\x00", trailing)
    check same(trailing, sentinel)

  test "the wire's integer percent is the percent ambient sums":
    check observedCpuPct(0'u32) == 0.0
    check observedCpuPct(1_000'u32) == 1.0
    check observedCpuPct(7_250'u32) == 7.25
    check observedCpuPct(1_600_000'u32) == 1600.0

  # -------------------------------------------------------------------------
  # The crash exit for in-flight self-reports
  # -------------------------------------------------------------------------

  test "an owner's reports are reaped together, and nobody else's are":
    clearSelfReportedExecutions()
    defer: clearSelfReportedExecutions()

    reportSelfExecution("lease-1", 10.0, 1_000, ownerKey = "session-a")
    reportSelfExecution("lease-2", 20.0, 2_000, ownerKey = "session-a")
    reportSelfExecution("lease-3", 30.0, 3_000, ownerKey = "session-b")
    check liveSelfReports().len == 3
    check sumSelfCpuPct(liveSelfReports()) == 60.0

    # THE CRASH EXIT. Before M13 a report keyed by a bare execution id had
    # nothing the daemon's reclamation path could reap it BY, so a client
    # that died mid-execution leaked its figures for the daemon's whole
    # life. This is the reap, and its return value is what makes "the leak
    # is closed" distinguishable from "the leak was never exercised".
    check endSelfReportsForOwner("session-a") == 2
    check liveSelfReports().len == 1
    check liveSelfReports()[0].executionId == "lease-3"
    check sumSelfCpuPct(liveSelfReports()) == 30.0
    check sumSelfRssBytes(liveSelfReports()) == 3_000

    # IDEMPOTENT: reaping a session that has already been reaped drops
    # nothing and reports nothing. A reclamation path may run twice (an
    # orderly close followed by the connection dropping), and a count that
    # grew on the second run would be a lie about how many reports leaked.
    check endSelfReportsForOwner("session-a") == 0
    check liveSelfReports().len == 1

  test "an unowned report is never swept by somebody else's teardown":
    clearSelfReportedExecutions()
    defer: clearSelfReportedExecutions()

    # The default `ownerKey` is empty, which is what every pre-M13 caller
    # passes. Such a report belongs to no session, and sweeping "everything
    # with no owner" on one session's teardown would make the reaped set
    # depend on which session happened to end first.
    reportSelfExecution("unowned", 5.0, 500)
    reportSelfExecution("owned", 6.0, 600, ownerKey = "session-a")
    check liveSelfReports().len == 2

    check endSelfReportsForOwner("") == 0
    check liveSelfReports().len == 2

    check endSelfReportsForOwner("session-a") == 1
    check liveSelfReports().len == 1
    check liveSelfReports()[0].executionId == "unowned"

    # The unowned one still has its ordinary exit.
    endSelfReportedExecution("unowned")
    check liveSelfReports().len == 0

  test "re-reporting an execution replaces its owner as well as its figures":
    clearSelfReportedExecutions()
    defer: clearSelfReportedExecutions()

    # A lease id is unique to the daemon that granted it, so this cannot
    # arise from two sessions -- but the live set is keyed by the execution
    # id alone, and an update that left a stale owner behind would leave
    # the report reapable by a session that no longer holds it.
    reportSelfExecution("lease-1", 10.0, 1_000, ownerKey = "session-a")
    reportSelfExecution("lease-1", 11.0, 1_100, ownerKey = "session-b")
    check liveSelfReports().len == 1
    check liveSelfReports()[0].cpuPct == 11.0
    check liveSelfReports()[0].ownerKey == "session-b"
    check endSelfReportsForOwner("session-a") == 0
    check endSelfReportsForOwner("session-b") == 1
    check liveSelfReports().len == 0

  test "self figures reach the row, and foreign is what is left of the host":
    # The arithmetic M13 now feeds, asserted end to end from reports the
    # protocol could have delivered. `attributeAmbientSample` is M11's and
    # is tested to the bit there; what is new here is that the reports
    # carry owners and still sum the same.
    clearSelfReportedExecutions()
    defer: clearSelfReportedExecutions()

    reportSelfExecution("lease-1", observedCpuPct(7_250'u32),
      3_500_000_000'i64, ownerKey = "session-a")
    reportSelfExecution("lease-2", observedCpuPct(2_750'u32),
      1_500_000_000'i64, ownerKey = "session-b")

    let previous = HostLoadReading(
      available: true, atUnixMillis: 1_000,
      cpuTotalMillis: 0, cpuBusyMillis: 0,
      memTotalBytes: 128_000_000_000, memAvailableBytes: 100_000_000_000,
      swapInPages: 0, loadAvg1m: 1.0, ioQueueDepth: 0.0)
    let current = HostLoadReading(
      available: true, atUnixMillis: 2_000,
      cpuTotalMillis: 16_000, cpuBusyMillis: 8_000,
      memTotalBytes: 128_000_000_000, memAvailableBytes: 100_000_000_000,
      swapInPages: 0, loadAvg1m: 1.0, ioQueueDepth: 0.0)
    check classifyReadings(previous, current) == rpAdvanced

    let row = attributeAmbientSample("host-x", previous, current,
      liveSelfReports())
    check row.cpuBusyPct == 50.0
    check row.selfCpuPct == 10.0
    check row.selfRssBytes == 5_000_000_000'i64
    check row.foreignCpuPct == 40.0
    check row.foreignRssBytes == 28_000_000_000'i64 - 5_000_000_000'i64

    # AND THE CRASH EXIT MOVES THE COLUMN. Without this the reap is a
    # bookkeeping change nobody could observe in the data.
    check endSelfReportsForOwner("session-a") == 1
    let afterReap = attributeAmbientSample("host-x", previous, current,
      liveSelfReports())
    check afterReap.selfCpuPct == 2.75
    check afterReap.foreignCpuPct == 47.25
