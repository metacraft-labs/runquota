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
  # The finish's own evidence, and the termination vocabulary it reaches
  # -------------------------------------------------------------------------
  #
  # BOTH CLAUSES BELOW ARE REFUSALS, and the fixtures they need are ones a
  # well-behaved client library cannot be asked to build: `RunQuotaLease
  # .finish` takes `outcome` and `hardLimitOrOom` as two separate defaulted
  # parameters and cross-validates neither, so "a finish that contradicts
  # itself" is reachable from a real client but not from a sensible one.
  # That is exactly the shape the campaign's conventions say goes vacuous
  # when asserted from outside a running daemon, so it is asserted here on
  # the pure predicate, at the values that straddle the boundary, with the
  # accepting case beside every refusing one.

  proc finishOf(outcome: LeaseFinishOutcome; exitCode = 0'u32;
                signal = 0'u32;
                hardLimitOrOom = false): LeaseFinishedMessage =
    LeaseFinishedMessage(
      sessionId: sessionId(1),
      leaseId: leaseId(7),
      outcome: outcome,
      exitCode: exitCode,
      signal: signal,
      peakMemoryBytes: 2_250_000_000'u64,
      processCount: 3'u32,
      majorPageFaults: 11'u64,
      pressureEvents: 0'u32,
      hardLimitOrOom: hardLimitOrOom,
      diagnostic: okDiagnostic())

  proc recordOf(outcome: LeaseFinishOutcome; exitStatus = 0'u32;
                signal = 0'u32): DeferredExecutionRecord =
    DeferredExecutionRecord(
      label: "probe",
      commandStatsId: "probe-key",
      startedAtUnixMillis: 1_700_000_000_000'u64,
      finishedAtUnixMillis: 1_700_000_000_500'u64,
      exitStatus: exitStatus,
      signal: signal,
      outcome: outcome,
      peakRssBytes: 2_250_000_000'u64,
      processCount: 3'u32,
      majorPageFaults: 11'u64)

  test "a finish claiming a kill beside a clean exit is refused":
    # THE ACCEPTING CASES FIRST, and there are more of them than refusing
    # ones on purpose. A predicate that refused everything would satisfy
    # every clause below and empty the store instead of keeping it honest.
    check leaseFinishedContradiction(finishOf(leaseFinishSucceeded)) == ""
    check leaseFinishedContradiction(
      finishOf(leaseFinishFailed, exitCode = 1'u32)) == ""
    check leaseFinishedContradiction(finishOf(leaseFinishCancelled)) == ""
    check leaseFinishedContradiction(finishOf(leaseFinishLaunchFailed)) == ""

    # AN ORDINARY SIGNAL KILL IS UNTOUCHED, in both spellings. A signalled
    # process has no exit status at all, so `exit_status = 0` beside
    # `signalled` reads as "not applicable" rather than as a claim of
    # success -- and a rule that refused it would discard every signalled
    # row a real supervisor writes, which is a far larger loss than the
    # one this rule exists to prevent.
    check leaseFinishedContradiction(
      finishOf(leaseFinishCrashed, signal = 11'u32)) == ""
    check leaseFinishedContradiction(finishOf(leaseFinishCrashed)) == ""

    # THE ROW THE SPECIFICATION NAMES. `oom_killed` beside `exit_status`
    # 137 is evidence that reconciles; beside `exit_status` 0 with no
    # signal it asserts both that the process was killed for exceeding
    # memory and that it exited successfully.
    check leaseFinishedContradiction(
      finishOf(leaseFinishResourceLimit, exitCode = 137'u32)) == ""
    check leaseFinishedContradiction(
      finishOf(leaseFinishResourceLimit)).len > 0
    check "exit status 0" in leaseFinishedContradiction(
      finishOf(leaseFinishResourceLimit))

    # EITHER KILL FIELD ALONE REACHES THE RULE. They are two independent
    # pieces of evidence on the wire, set by different kinds of supervisor,
    # and neither is required to agree with the other -- so the rule is
    # stated against the exit they are reported beside, never against the
    # other field.
    check leaseFinishedContradiction(
      finishOf(leaseFinishFailed, signal = 9'u32,
        hardLimitOrOom = true)) == ""
    check leaseFinishedContradiction(
      finishOf(leaseFinishFailed, hardLimitOrOom = true)).len > 0
    # And the flag alone still overrides nothing: an outcome that says the
    # work SUCCEEDED cannot be reconciled with a kill however the exit
    # reads, which is the one clause that is about the two fields.
    check leaseFinishedContradiction(
      finishOf(leaseFinishSucceeded, exitCode = 137'u32,
        hardLimitOrOom = true)).len > 0
    check "successful finish" in leaseFinishedContradiction(
      finishOf(leaseFinishSucceeded, exitCode = 137'u32,
        hardLimitOrOom = true))

    # A DEADLINE KILL IS THE SAME SHAPE, so the member added to make
    # `timeout` reachable does not arrive with the hole this closes.
    check leaseFinishedContradiction(
      finishOf(leaseFinishTimedOut, signal = 9'u32)) == ""
    check leaseFinishedContradiction(
      finishOf(leaseFinishTimedOut, exitCode = 124'u32)) == ""
    check leaseFinishedContradiction(finishOf(leaseFinishTimedOut)).len > 0

  test "a standalone record carries the same rule, on its own fields":
    check deferredRecordContradiction(recordOf(leaseFinishSucceeded)) == ""
    check deferredRecordContradiction(
      recordOf(leaseFinishFailed, exitStatus = 1'u32)) == ""
    check deferredRecordContradiction(
      recordOf(leaseFinishCrashed, signal = 11'u32)) == ""
    check deferredRecordContradiction(recordOf(leaseFinishCrashed)) == ""
    check deferredRecordContradiction(
      recordOf(leaseFinishResourceLimit, exitStatus = 137'u32)) == ""
    check deferredRecordContradiction(
      recordOf(leaseFinishResourceLimit)).len > 0
    check deferredRecordContradiction(
      recordOf(leaseFinishTimedOut, signal = 9'u32)) == ""
    check deferredRecordContradiction(recordOf(leaseFinishTimedOut)).len > 0

  test "every termination the schema names is reachable from a real finish":
    # A VALUE NO CODE CAN PRODUCE IS A CLAIM THE SCHEMA MAKES AND THE
    # DAEMON CANNOT KEEP. `tTimeout` was exactly that: it appeared nowhere
    # in runquota outside its own enum declaration, no `LeaseFinishOutcome`
    # reached it, and a timed-out execution landed on the spine as
    # `signalled` -- true, and useless to a reader asking why a test stopped.
    #
    # ENUMERATION, NOT EXISTENCE. The assertion is on the WHOLE SET the
    # mapping can produce. A one-value expectation would have been
    # satisfied by an implementation that reached four of the five and
    # happened to reach the one somebody remembered to name.
    var leased: set[Termination] = {}
    for msg in [
        finishOf(leaseFinishSucceeded),
        finishOf(leaseFinishFailed, exitCode = 1'u32),
        finishOf(leaseFinishCrashed, signal = 11'u32),
        finishOf(leaseFinishResourceLimit, exitCode = 137'u32),
        finishOf(leaseFinishTimedOut, signal = 9'u32),
        finishOf(leaseFinishCancelled),
        finishOf(leaseFinishLaunchFailed)]:
      leased.incl(observationTermination(msg))
    check leased == {tExited, tSignalled, tTimeout, tOomKilled, tRefused}

    # THE STANDALONE PATH REACHES THE SAME FIVE. A word that exists on one
    # of the two write paths and not the other would make "was this a
    # timeout" answerable only for executions that happened to hold a
    # lease.
    var standalone: set[Termination] = {}
    for record in [
        recordOf(leaseFinishSucceeded),
        recordOf(leaseFinishFailed, exitStatus = 1'u32),
        recordOf(leaseFinishCrashed, signal = 11'u32),
        recordOf(leaseFinishResourceLimit, exitStatus = 137'u32),
        recordOf(leaseFinishTimedOut, signal = 9'u32),
        recordOf(leaseFinishCancelled),
        recordOf(leaseFinishLaunchFailed)]:
      standalone.incl(deferredTermination(record))
    check standalone == {tExited, tSignalled, tTimeout, tOomKilled, tRefused}

    # AND THE DEADLINE SURVIVES THE SIGNAL IT WAS DELIVERED WITH. A timeout
    # kill IS a signal kill, so a mapping that tested `signal` first would
    # answer `signalled` and throw the deadline away -- which is what the
    # daemon did before `leaseFinishTimedOut` existed, and what it would go
    # back to doing if the two tests were reordered.
    check observationTermination(
      finishOf(leaseFinishTimedOut, signal = 9'u32)) == tTimeout
    check deferredTermination(
      recordOf(leaseFinishTimedOut, signal = 9'u32)) == tTimeout
    # A memory kill delivered by the same signal still says WHAT FOR.
    check observationTermination(
      finishOf(leaseFinishFailed, signal = 9'u32,
        hardLimitOrOom = true)) == tOomKilled

    # AND MEMORY PRECEDES THE DEADLINE, which is the half of the ordering
    # the clauses above do NOT constrain: every fixture they use sets at
    # most one kind of kill, so swapping the memory test and the deadline
    # test past each other leaves them all green. Only a finish carrying
    # BOTH -- a supervisor that watched an `ru_maxrss` cross a hard limit
    # AND holds a deadline of its own -- can tell the two orders apart,
    # and it is the case where the memory fact is the more specific one:
    # `timeout` says the supervisor stopped waiting, `oom_killed` says
    # WHAT the process did to earn it.
    #
    # LEASED PATH ONLY, and not from an oversight. `DeferredExecutionRecord`
    # carries no `hardLimitOrOom`, so `outcome` is the whole of its kill
    # evidence and a standalone record cannot claim both kinds at once --
    # the ordering is unobservable there rather than untested.
    check observationTermination(
      finishOf(leaseFinishTimedOut, signal = 9'u32,
        hardLimitOrOom = true)) == tOomKilled
    # The fixture above must be one the write path would actually accept,
    # or the clause is about a row that never gets made.
    check leaseFinishedContradiction(
      finishOf(leaseFinishTimedOut, signal = 9'u32,
        hardLimitOrOom = true)) == ""

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
