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
  # The finish, and the termination vocabulary it reaches
  # -------------------------------------------------------------------------
  #
  # THE FIRST CLAUSE BELOW IS A COMPILATION TEST, and that is the whole
  # change this file records. There used to be a runtime predicate here
  # refusing a finish that claimed a kill beside exit status 0 and no
  # signal, because `RunQuotaLease.finish` took the conclusion and its
  # evidence as four independently defaulted parameters and cross-validated
  # none of them -- so the contradiction was one argument list away on the
  # public API and only the daemon could catch it. `LeaseFinish` has no
  # such argument list. The states are not refused, they are absent, and
  # the assertion that they are absent is one the COMPILER makes.
  #
  # WHAT SURVIVES AS A RUNTIME RULE IS ABOUT BYTES. A frame arrives as
  # three integers from whatever wrote them, and three integers can spell
  # combinations `LeaseFinish` has no room for; `leaseFinishFromWire` is
  # the constructor that re-establishes by hand what the type establishes
  # by construction everywhere else. Its clauses are asserted below at the
  # values that straddle each boundary, with an accepting case beside
  # every refusing one.

  test "a finish that contradicts itself does not compile":
    # POSITIVE CONTROLS FIRST, AND THEY ARE WHAT KEEPS THE REST FROM BEING
    # VACUOUS. `compiles` answers false for a misspelt identifier as
    # readily as for a type error, so a test made only of `not compiles`
    # clauses goes green the day the type is deleted, the day a field is
    # renamed, and the day somebody fat-fingers a constructor. Every
    # negative below has an affirmative twin here that fails if the names
    # stop meaning what the negative assumes.
    check compiles(LeaseFinish(kind: lfFailed, exitCode: 1'u32))
    check compiles(LeaseFinish(kind: lfCrashed, crashSignal: 11'u32))
    check compiles(LeaseFinish(kind: lfOomKilled,
      kill: KillEvidence(bySignal: true, signal: 9'u32)))
    check compiles(KillEvidence(bySignal: true, signal: 9'u32))
    check compiles(KillEvidence(bySignal: false, exitCode: 137'u32))
    check compiles(oomKilled(killedBySignal(9'u32)))
    check compiles(timedOut(killedWithExitCode(124'u32)))

    # A KILL CANNOT BE NAMED WITHOUT THE THING THAT EVIDENCES IT. There is
    # no arity of these constructors that omits the evidence, and no other
    # way to reach the kinds that carry it.
    check not compiles(oomKilled())
    check not compiles(timedOut())
    check not compiles(crashed())

    # A SUCCESS CANNOT CARRY A KILL'S EVIDENCE, because `lfSucceeded` has
    # no field to put one in. "A kill reported as a successful finish" was
    # the second of the two states the daemon used to refuse; this is
    # where it went.
    check not compiles(LeaseFinish(kind: lfSucceeded, exitCode: 137'u32))
    check not compiles(LeaseFinish(kind: lfSucceeded, crashSignal: 9'u32))
    check not compiles(LeaseFinish(kind: lfSucceeded,
      kill: KillEvidence(bySignal: true, signal: 9'u32)))
    check not compiles(LeaseFinish(kind: lfCancelled, exitCode: 1'u32))
    check not compiles(LeaseFinish(kind: lfLaunchFailed, crashSignal: 9'u32))

    # AND THE TWO KINDS OF EVIDENCE CANNOT BOTH BE PRESENT, which is the
    # refused state stated precisely: "exit status 0 AND signal 0" is a
    # CONJUNCTION over two fields, and a variant that holds one or the
    # other has no way to write the conjunction down at all.
    check not compiles(KillEvidence(bySignal: true, signal: 9'u32,
      exitCode: 137'u32))
    check not compiles(LeaseFinish(kind: lfCrashed, exitCode: 1'u32))
    check not compiles(LeaseFinish(kind: lfFailed, crashSignal: 9'u32))

  test "the one hole a variant leaves is closed by the constructors":
    # AN ARM HOLDING ONE INTEGER CAN STILL BE LEFT AT ZERO, and zero is
    # the value that means "no evidence". The type cannot forbid it; the
    # constructors can, and they are the only way in.
    expect ValueError: discard killedBySignal(0'u32)
    expect ValueError: discard killedWithExitCode(0'u32)
    expect ValueError: discard crashed(0'u32)
    # "Failed with exit status 0" is the same contradiction in a smaller
    # costume: a failure whose evidence says the process succeeded.
    expect ValueError: discard failed(0'u32)

    # AND THE ACCEPTING CASES, so the clauses above are not satisfied by
    # constructors that refuse everything.
    check killedBySignal(9'u32).signal == 9'u32
    check killedWithExitCode(137'u32).exitCode == 137'u32
    check crashed(11'u32).crashSignal == 11'u32
    check failed(1'u32).exitCode == 1'u32

  test "a supervisor with no evidence is told so rather than guessing":
    # THE DEGRADATION PATH, IN THE ONE PLACE EVERY CLIENT TAKES IT. A
    # supervisor that cannot recover a signal or a status has nothing to
    # evidence a kill with, and must say `cancelled()` instead of claiming
    # a deadline it cannot support.
    var kill: KillEvidence
    check not killEvidence(0'u32, 0'u32, kill)
    check killEvidence(0'u32, 9'u32, kill)
    check kill.bySignal
    check kill.signal == 9'u32
    check killEvidence(137'u32, 0'u32, kill)
    check not kill.bySignal
    check kill.exitCode == 137'u32
    # THE SIGNAL WINS WHEN BOTH ARE HELD: it is the kernel's own record of
    # the kill, and a status integer is at best a convention over it.
    check killEvidence(137'u32, 9'u32, kill)
    check kill.bySignal
    check kill.signal == 9'u32

  test "bytes that spell no finish are refused, and honest bytes are not":
    # THE ACCEPTING CASES FIRST, and there are more of them than refusing
    # ones on purpose. A constructor that refused everything would satisfy
    # every refusal clause below and empty the store instead of keeping it
    # honest.
    proc built(kind: LeaseFinishKind; exitCode = 0'u32;
               signal = 0'u32): LeaseFinish =
      check leaseFinishFromWire(uint32(ord(kind)), exitCode, signal,
        result) == ""

    proc refusal(kind: LeaseFinishKind; exitCode = 0'u32;
                 signal = 0'u32): string =
      var finish: LeaseFinish
      leaseFinishFromWire(uint32(ord(kind)), exitCode, signal, finish)

    check built(lfSucceeded).kind == lfSucceeded
    check built(lfFailed, exitCode = 1'u32).exitCode == 1'u32
    check built(lfCrashed, signal = 11'u32).crashSignal == 11'u32
    check built(lfCancelled).kind == lfCancelled
    check built(lfLaunchFailed).kind == lfLaunchFailed

    # THE ROW THE SPECIFICATION NAMES. `oom_killed` beside exit status 137
    # is evidence that reconciles, and so is `oom_killed` beside a signal;
    # beside neither it asserts both that the process was killed for
    # exceeding memory and that it exited successfully.
    check built(lfOomKilled, exitCode = 137'u32).kill.exitCode == 137'u32
    check built(lfOomKilled, signal = 9'u32).kill.signal == 9'u32
    check refusal(lfOomKilled).len > 0
    check "exit status 0 and no signal" in refusal(lfOomKilled)

    # A DEADLINE KILL IS THE SAME SHAPE, so the kind that makes `timeout`
    # reachable does not arrive with the hole this closes.
    check built(lfTimedOut, signal = 9'u32).kill.signal == 9'u32
    check built(lfTimedOut, exitCode = 124'u32).kill.exitCode == 124'u32
    check refusal(lfTimedOut).len > 0

    # BOTH KINDS OF EVIDENCE AT ONCE IS ALSO NOT A `KillEvidence`. The
    # wire carries two integers where the type carries one field, so bytes
    # can say what the type cannot hold -- and silently dropping one would
    # make the decoder accept two different spellings of one message.
    check refusal(lfOomKilled, exitCode = 137'u32, signal = 9'u32).len > 0
    check refusal(lfTimedOut, exitCode = 124'u32, signal = 15'u32).len > 0

    # A SUCCESS CARRYING EITHER, which no constructor can build and a
    # version-1 peer's frame would.
    check refusal(lfSucceeded, exitCode = 137'u32).len > 0
    check refusal(lfSucceeded, signal = 9'u32).len > 0

    # A FAILURE THAT NAMES A SIGNAL IS A CRASH, and a crash that names an
    # exit status is not one. The old wire let a client send both and the
    # daemon resolved the argument by testing the signal first; the two
    # spellings are now one message each.
    check refusal(lfFailed, exitCode = 1'u32, signal = 9'u32).len > 0
    check refusal(lfFailed).len > 0
    check refusal(lfCrashed).len > 0
    check refusal(lfCrashed, exitCode = 139'u32, signal = 11'u32).len > 0

    # WORK THAT PRODUCED NO VERDICT CANNOT CARRY ONE.
    check refusal(lfCancelled, exitCode = 1'u32).len > 0
    check refusal(lfLaunchFailed, signal = 9'u32).len > 0

    # AND AN ORDINAL PAST THE LAST KIND. Casting it into the enum is
    # undefined and could land anywhere, including on a kill.
    var beyond: LeaseFinish
    check leaseFinishFromWire(uint32(ord(high(LeaseFinishKind))) + 1'u32,
      0'u32, 0'u32, beyond).len > 0

  test "every termination the schema names is reachable from a real finish":
    # A VALUE NO CODE CAN PRODUCE IS A CLAIM THE SCHEMA MAKES AND THE
    # DAEMON CANNOT KEEP. `tTimeout` was exactly that: no outcome reached
    # it, and a timed-out execution landed on the spine as `signalled` --
    # true, and useless to a reader asking why a test stopped.
    #
    # ENUMERATION OVER THE WHOLE KIND SET, NOT A LIST SOMEBODY WROTE OUT.
    # `LeaseFinishKind` is iterated, so an eighth kind added later cannot
    # slip past this by being absent from a fixture list -- it has to be
    # given evidence here and it has to land somewhere.
    var reached: set[Termination] = {}
    for kind in LeaseFinishKind:
      # Each kind is given the evidence it requires and no more, which is
      # the same discipline the type enforces on every caller.
      let finish =
        case kind
        of lfSucceeded: succeeded()
        of lfFailed: failed(1'u32)
        of lfCrashed: crashed(11'u32)
        of lfOomKilled: oomKilled(killedWithExitCode(137'u32))
        of lfTimedOut: timedOut(killedBySignal(9'u32))
        of lfCancelled: cancelled()
        of lfLaunchFailed: launchFailed()
      reached.incl(observationTermination(finish))
    check reached == {tExited, tSignalled, tTimeout, tOomKilled, tRefused}

    # AND EACH WORD IS THE ONE THE KIND MEANS, not merely some word. The
    # set above is satisfied by any bijection; these are the mapping.
    check observationTermination(succeeded()) == tExited
    check observationTermination(failed(1'u32)) == tExited
    check observationTermination(crashed(11'u32)) == tSignalled
    check observationTermination(cancelled()) == tRefused
    check observationTermination(launchFailed()) == tRefused

    # THE DEADLINE SURVIVES THE SIGNAL IT WAS DELIVERED WITH. A timeout
    # kill IS a signal kill, and the old mapping was a ladder in which a
    # signal test placed above the deadline test would have answered
    # `signalled` and thrown the deadline away. There is no ladder left to
    # get wrong: the kind says which, and the signal is inside it.
    check observationTermination(timedOut(killedBySignal(9'u32))) == tTimeout
    check observationTermination(timedOut(killedWithExitCode(124'u32))) ==
      tTimeout
    # A memory kill delivered by the same signal still says WHAT FOR. This
    # used to depend on an ordering between two overlapping tests, with a
    # paragraph explaining which had to come first; a supervisor now
    # states the conclusion and there is no second test to order it
    # against.
    check observationTermination(oomKilled(killedBySignal(9'u32))) ==
      tOomKilled
    check observationTermination(oomKilled(killedWithExitCode(137'u32))) ==
      tOomKilled

  test "nothing that ran and was killed lands on the store's zero":
    # THE COLUMN IS READ BY SQL, NOT BY THIS FILE. `exit_status` is one
    # integer standing for two kinds of ending, and the reader it exists
    # for compares it against 0. A row reading `termination = signalled`
    # beside `exit_status = 0` asserts both that a signal ended this
    # process and that it exited of its own accord, successfully --
    # which is the pairing §"The Execution Spine" forbids by name, and
    # the same defect this whole type exists to abolish, one layer down.
    #
    # SO A SIGNALLED DEATH IS 128+N. Every shell, CI system and process
    # supervisor already renders it that way, so a reader who knows
    # nothing about RunQuota still reads 139 as "killed".
    check crashed(11'u32).exitStatus == 139'u32
    check oomKilled(killedBySignal(9'u32)).exitStatus == 137'u32
    check timedOut(killedBySignal(15'u32)).exitStatus == 143'u32

    # AND IT IS LOSSLESS, which is the other half of why it is not 0. The
    # signal arrives on the wire and the store has NO SIGNAL COLUMN, so a
    # zero discarded it with no way back.
    for signal in [1'u32, 9'u32, 11'u32, 15'u32, 31'u32, 64'u32]:
      check crashed(signal).exitStatus - SignalledExitStatusBase == signal
      check crashed(signal).exitStatus != 0'u32

    # A KILL EVIDENCED BY A STATUS KEEPS THAT STATUS UNCHANGED. It is
    # already the number the supervisor saw; adding 128 to it would be
    # inventing a signal nobody observed.
    check oomKilled(killedWithExitCode(137'u32)).exitStatus == 137'u32
    check timedOut(killedWithExitCode(124'u32)).exitStatus == 124'u32

    # NOT 128+N FOR EVERYTHING, which is the mutation the clauses above
    # would not catch on their own: an accessor that added the base
    # unconditionally satisfies every assertion so far.
    check succeeded().exitStatus == 0'u32
    check failed(1'u32).exitStatus == 1'u32
    check failed(3'u32).exitStatus == 3'u32
    check failed(139'u32).exitStatus == 139'u32

    # THE TWO ZEROES, TOLD APART. `lfSucceeded` is a measurement: the
    # process ran and returned 0. `lfCancelled`/`lfLaunchFailed` produced
    # no status at all, and their `termination` is `refused` -- the word
    # for work that never ran -- so the column is making no claim about a
    # process and the zero cannot be mistaken for one.
    check succeeded().exitStatus == 0'u32
    check observationTermination(succeeded()) == tExited
    check cancelled().exitStatus == 0'u32
    check launchFailed().exitStatus == 0'u32
    check observationTermination(cancelled()) == tRefused
    check observationTermination(launchFailed()) == tRefused

    # AND EVERY KIND THAT DESCRIBES A PROCESS WHICH RAN AND WAS ENDED BY
    # SOMETHING IS NON-ZERO. Enumerated over the kind set rather than
    # listed, so a future kind has to be placed on one side or the other.
    for kind in LeaseFinishKind:
      let finish =
        case kind
        of lfSucceeded: succeeded()
        of lfFailed: failed(1'u32)
        of lfCrashed: crashed(11'u32)
        of lfOomKilled: oomKilled(killedBySignal(9'u32))
        of lfTimedOut: timedOut(killedBySignal(15'u32))
        of lfCancelled: cancelled()
        of lfLaunchFailed: launchFailed()
      if observationTermination(finish) in {tSignalled, tOomKilled, tTimeout}:
        check finish.exitStatus != 0'u32

  test "the spine's column and the wire's fields are not the same number":
    # THE WIRE CARRIES THE FINISH; THE SPINE CARRIES A RENDERING OF IT.
    # One function for both would have to pick, and picking the spine's
    # number breaks the codec while picking the wire's reintroduces the
    # zero above -- so they are two functions and this is the clause that
    # says they must stay two.
    check crashed(11'u32).wireExitCode == 0'u32
    check crashed(11'u32).wireSignal == 11'u32
    check crashed(11'u32).exitStatus == 139'u32

    # CONFLATING THEM IS CAUGHT RATHER THAN MERELY DISCOURAGED: a frame
    # built from the spine's column does not decode, because "a crashed
    # finish carries an exit status" is one of the malformed shapes.
    var rebuilt: LeaseFinish
    check leaseFinishFromWire(uint32(ord(lfCrashed)),
      crashed(11'u32).exitStatus, crashed(11'u32).wireSignal, rebuilt).len > 0

    # AND THE WIRE'S OWN FIELDS DO ROUND-TRIP, so the clause above is
    # about the spine's number and not about a decoder that refuses
    # everything.
    check leaseFinishFromWire(uint32(ord(lfCrashed)),
      crashed(11'u32).wireExitCode, crashed(11'u32).wireSignal,
      rebuilt) == ""
    check rebuilt.crashSignal == 11'u32

  test "a standalone record's finish is refused on the same rule":
    # ONE RULE, ONE PLACE, BOTH WRITE PATHS. The deferred flush used to
    # carry its own copy of the contradiction check, over its own field
    # names, kept in step with the leased one by hand. Both now carry a
    # `LeaseFinish` and both are built by `leaseFinishFromWire`, so a
    # standalone row and an admitted row cannot disagree about what is
    # sayable.
    #
    # A CONTRADICTORY RECORD IS DROPPED AND COUNTED, NOT ALLOWED TO FAIL
    # THE BATCH. A batch is one client's entire exit flush; discarding a
    # hundred readable rows over the hundred-and-first is a larger loss
    # than the one the refusal exists to prevent (OS-4).
    proc recordOf(finish: LeaseFinish): DeferredExecutionRecord =
      DeferredExecutionRecord(
        label: "probe",
        commandStatsId: "probe-key",
        startedAtUnixMillis: 1_700_000_000_000'u64,
        finishedAtUnixMillis: 1_700_000_000_500'u64,
        finish: finish,
        peakRssBytes: 2_250_000_000'u64,
        processCount: 3'u32,
        majorPageFaults: 11'u64)

    let honest = DeferredObservationsMessage(
      tool: "probe", toolVersion: "1", invocationKind: "standalone",
      completeness: ccDegraded, droppedObservations: 0'u32,
      records: @[recordOf(succeeded()),
                 recordOf(oomKilled(killedWithExitCode(137'u32))),
                 recordOf(failed(2'u32))])
    var decoded: DeferredObservationsMessage
    var contradictory = 0
    check decodeDeferredObservations(encodeDeferredObservations(honest),
      decoded, contradictory)
    check contradictory == 0
    check decoded.records.len == 3

    # THE SAME BATCH WITH ONE RECORD'S KILL EVIDENCE ERASED ON THE WIRE.
    # Forged rather than constructed, because no client can construct it:
    # the middle record's three finish integers are rewritten in place to
    # `oom_killed, 0, 0`.
    var forged = encodeDeferredObservations(honest)
    let marker = encodeDeferredObservations(DeferredObservationsMessage(
      tool: "probe", toolVersion: "1", invocationKind: "standalone",
      completeness: ccDegraded, droppedObservations: 0'u32,
      records: @[recordOf(oomKilled(killedWithExitCode(137'u32)))]))
    # The exit-status word of that record, found by the value only it
    # carries, and zeroed.
    var at = -1
    for i in 0 .. forged.len - 4:
      if forged[i] == char(137) and forged[i + 1] == '\0' and
          forged[i + 2] == '\0' and forged[i + 3] == '\0':
        at = i
        break
    check at >= 0
    check marker.len > 0
    for i in 0 ..< 4:
      forged[at + i] = '\0'

    var survivors: DeferredObservationsMessage
    var dropped = 0
    check decodeDeferredObservations(forged, survivors, dropped)
    check dropped == 1
    # THE OTHER TWO SURVIVED, which is what makes the drop a degradation
    # rather than a batch failure.
    check survivors.records.len == 2
    check survivors.records[0].finish.kind == lfSucceeded
    check survivors.records[1].finish.kind == lfFailed
    # AND THE RUN STILL GETS WRITTEN, so the loss has a row to sit in:
    # a flush whose every record was malformed is not "nothing in it".
    check deferredObservationsRefusal(DeferredObservationsMessage(
      tool: "probe", toolVersion: "1", invocationKind: "standalone",
      completeness: ccDegraded, droppedObservations: 0'u32,
      records: @[]), contradictoryRecords = 1) == ""
    check deferredObservationsRefusal(DeferredObservationsMessage(
      tool: "probe", toolVersion: "1", invocationKind: "standalone",
      completeness: ccDegraded, droppedObservations: 0'u32,
      records: @[]), contradictoryRecords = 0).len > 0

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
