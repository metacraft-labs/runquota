## Standalone (daemonless) capture: what a client does with its
## observations when there is no ``runquotad`` to send them to.
##
## Normative specification:
## ``reprobuild-specs/RunQuota-Observation-Store.md`` §"Standalone mode",
## and invariant OS-4 ("degrade, never fail").
##
## THE OBVIOUS IMPLEMENTATION OF THIS FILE WOULD BE THE WRONG ONE, and it
## is worth saying why in the file that would have contained it. With no
## daemon present, the tempting move is to have the client open the store
## and write the row itself: the rows stay correct, nothing is lost, and it
## reads as the MORE faithful degradation. It is forbidden. It puts a
## database write on the per-execution path this entire design exists to
## keep clear, and the write path's first rule already settles the trade —
## *losing an observation is always preferable to perturbing the work being
## observed.* So this module buffers in memory and nothing else. It links
## no store, opens no file, and spawns no process; there is nothing here
## that could touch a database even by accident.
##
## WHAT DEGRADES, PRECISELY:
##
## * observations are buffered in a BOUNDED in-memory ring;
## * a LONG-LIVED client makes ONE best-effort flush over the socket when
##   it exits — one attempt, whether or not it succeeds;
## * a SHORT-LIVED client drops them, because the single attempt would be
##   most of what the process costs;
## * either way the window is reported as INCOMPLETE via
##   ``capture_completeness``, never as complete;
## * cross-invocation aggregation and learned-estimate serving are reported
##   as UNAVAILABLE rather than answered from whatever happens to be to
##   hand.

import runquota_core
import runquota_protocol

const DefaultStandaloneCapacity* = 1024
  ## How many executions the buffer holds before it starts losing them.
  ##
  ## BOUNDED IS THE POINT, not the number. An unbounded buffer turns a
  ## missing daemon into a memory leak proportional to the length of the
  ## build, which is a way of failing the work being observed — the one
  ## outcome OS-4 forbids. Losses are counted, so a bounded buffer is
  ## honest where an unbounded one would be merely optimistic.

type
  ClientLifetime* = enum
    ## How long the client behind this buffer lives, which is the whole
    ## content of the flush decision.
    clShortLived
      ## One or a few executions and then exit — a `runquota acquire`
      ## wrapping a single command. Its buffered observations are DROPPED:
      ## the connect attempt at exit would be a large fraction of what the
      ## process cost in the first place, and the specification says a
      ## short-lived client drops them.
    clLongLived
      ## A test runner or a build driver that will run many executions.
      ## It MAY make a single best-effort flush at exit, amortised over
      ## everything it ran.

  StandaloneFlushReason* = enum
    ## Why the exit flush did what it did. Reported rather than inferred:
    ## "no rows arrived" is the same observation for a client that dropped
    ## them by policy, a client that had none, and a client whose single
    ## attempt found no daemon, and those are three different states.
    sfShortLivedDrop
    sfNothingBuffered
    sfAttempted
    sfAlreadyPlanned

  StandaloneFlushPlan* = object
    attempt*: bool
      ## Whether the caller is to make the one connect attempt.
    reason*: StandaloneFlushReason
    message*: DeferredObservationsMessage
      ## Meaningful only when ``attempt`` is true.

  StandaloneCapture* = object
    ## The buffer, and everything anyone is entitled to know about it.
    ##
    ## A plain object with a ``seq``: no ``ref``, because
    ## ``runquota_client`` is a static-helper library and may not define
    ## one.
    lifetime*: ClientLifetime
    capacity*: int
    tool*: string
    toolVersion*: string
    invocationKind*: string
    records: seq[DeferredExecutionRecord]
    droppedObservations*: uint32
      ## Counted, per OS-2. Losses from the bounded buffer while running,
      ## plus everything abandoned at exit.
    recorded*: uint64
      ## Everything ever offered to this buffer, so "buffered + dropped"
      ## can be checked against it rather than trusted.
    exitFlushPlanned*: bool
    flushAttempts*: int
      ## MUST NEVER EXCEED ONE. "A single best-effort flush" is a bound,
      ## and a bound nobody counts is a wish.
    deliveredRecords*: int

proc initStandaloneCapture*(tool, toolVersion, invocationKind: string;
                            lifetime: ClientLifetime;
                            capacity = DefaultStandaloneCapacity):
                            StandaloneCapture =
  StandaloneCapture(
    lifetime: lifetime,
    capacity: max(1, capacity),
    tool: tool,
    toolVersion: toolVersion,
    invocationKind: invocationKind,
    records: @[],
    droppedObservations: 0'u32,
    recorded: 0'u64,
    exitFlushPlanned: false,
    flushAttempts: 0,
    deliveredRecords: 0
  )

proc completeness*(capture: StandaloneCapture): CaptureCompleteness =
  ## ALWAYS ``ccDegraded``, and there is no argument that reaches any other
  ## value from here.
  ##
  ## A window nothing drained while it was open is incomplete by
  ## construction. Even a buffer that dropped nothing was never *observed*:
  ## no daemon was sampling ambient load beside it, no host or hardware
  ## profile was established for it, and whether the single exit flush
  ## lands is not knowable at the moment the verdict is formed. OS-2 says a
  ## thin sample must never be presentable as a complete one, and this is
  ## the thinnest sample the system produces.
  ##
  ## Deliberately NOT a function of ``droppedObservations``: making it
  ## conditional is exactly how "complete" gets back in, on the run that
  ## happened to fit.
  ccDegraded

proc bufferedCount*(capture: StandaloneCapture): int =
  capture.records.len

proc buffered*(capture: StandaloneCapture): seq[DeferredExecutionRecord] =
  capture.records

proc record*(capture: var StandaloneCapture;
             record: DeferredExecutionRecord) =
  ## Buffer one finished execution. NEVER RAISES, NEVER BLOCKS, NEVER
  ## TOUCHES A FILE.
  ##
  ## When the buffer is full the OLDEST record is discarded rather than the
  ## newest: a truncated window ending at the moment of the loss would say
  ## less about the run than one that keeps moving, and the count says how
  ## much was lost either way.
  inc capture.recorded
  if capture.records.len >= capture.capacity:
    capture.records.delete(0)
    inc capture.droppedObservations
  capture.records.add(record)

proc planExitFlush*(capture: var StandaloneCapture): StandaloneFlushPlan =
  ## Decide, ONCE, what happens to the buffer at exit.
  ##
  ## Called by the exiting client. Every path through it marks the decision
  ## as taken, so a second call cannot produce a second attempt however the
  ## caller is wired — an exit hook that also runs on an explicit close is
  ## the ordinary way "a single flush" quietly becomes two.
  if capture.exitFlushPlanned:
    return StandaloneFlushPlan(attempt: false, reason: sfAlreadyPlanned)
  capture.exitFlushPlanned = true

  if capture.lifetime == clShortLived:
    # DROPPED BY POLICY, and counted so the drop is visible.
    capture.droppedObservations += uint32(capture.records.len)
    capture.records = @[]
    return StandaloneFlushPlan(attempt: false, reason: sfShortLivedDrop)

  if capture.records.len == 0 and capture.droppedObservations == 0:
    return StandaloneFlushPlan(attempt: false, reason: sfNothingBuffered)

  inc capture.flushAttempts
  StandaloneFlushPlan(
    attempt: true,
    reason: sfAttempted,
    message: DeferredObservationsMessage(
      tool: capture.tool,
      toolVersion: capture.toolVersion,
      invocationKind: capture.invocationKind,
      completeness: capture.completeness(),
      droppedObservations: capture.droppedObservations,
      records: capture.records
    )
  )

proc finishExitFlush*(capture: var StandaloneCapture; delivered: bool) =
  ## Record what the one attempt achieved and empty the buffer either way.
  ## An undelivered batch is a DROP, counted as one: a client that quietly
  ## forgot the difference would report the same numbers whether the daemon
  ## was there or not.
  if delivered:
    capture.deliveredRecords = capture.records.len
  else:
    capture.droppedObservations += uint32(capture.records.len)
  capture.records = @[]

# ---------------------------------------------------------------------------
# What a standalone client is allowed to say about statistics
# ---------------------------------------------------------------------------

type
  StandaloneAnswer* = enum
    ## The only two shapes an answer may take with no daemon present.
    saUnavailable
      ## There is nobody to ask. Say so.
    saFaked
      ## Never produced by this module; named so that "unavailable rather
      ## than faked" is a distinction the code can state and a test can
      ## check, instead of a sentence in a document.

  StandaloneStatsReport* = object
    aggregation*: StandaloneAnswer
    learnedEstimate*: StandaloneAnswer
    detail*: string

proc standaloneStatsReport*(): StandaloneStatsReport =
  ## Cross-invocation aggregation and learned-estimate serving, with no
  ## daemon: both UNAVAILABLE.
  ##
  ## Both live behind `runquotad` — it is the only sanctioned reader of the
  ## store, and the published aggregate table is written by it and by
  ## nothing else. With no daemon there is no source for either, and the
  ## honest report is that there is none. The alternative on offer is
  ## always some plausible-looking number to hand (a default, a previous
  ## run's figure, the request's own reservation), and every one of them is
  ## an invention presented in a column whose entire purpose is to hold a
  ## measurement.
  StandaloneStatsReport(
    aggregation: saUnavailable,
    learnedEstimate: saUnavailable,
    detail: "no runquotad: cross-invocation aggregation and learned " &
      "estimates are unavailable"
  )

proc standaloneReport*(capture: StandaloneCapture;
                       reason: StandaloneFlushReason): string =
  ## One line an operator can read, and the only thing a standalone client
  ## prints about its own degradation.
  ##
  ## NOT AN ERROR, and it must not read as one. §"Standalone mode": a
  ## missing daemon MUST NOT be reported as an error and MUST NOT cause a
  ## run to fail.
  "runquota: no daemon; capture " & $capture.completeness() &
    ", buffered " & $capture.bufferedCount() &
    ", dropped " & $capture.droppedObservations &
    ", flush " & $reason &
    "; " & standaloneStatsReport().detail
