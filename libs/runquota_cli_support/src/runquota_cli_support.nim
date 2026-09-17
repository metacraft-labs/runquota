import std/[os, osproc, strutils, times]

import runquota_client
import runquota_core
import runquota_exec
import runquota_process
# NARROWED ON PURPOSE. A plain `import runquota_ipc` here makes
# `connectDefault` ambiguous against `runquota_client`'s, which is the
# transport-level one no CLI path should reach for.
from runquota_ipc import defaultEndpoint, defaultStatsTablePath
import runquota_protocol
import runquota_stats_table
import runquota_cli_support/stats

proc wantsVersion*(args: openArray[string]): bool =
  args.len == 1 and args[0] in ["--version", "-V"]

proc renderVersion*(programName: string): string =
  programName & " " & versionString()

proc renderUsage*(programName: string): string =
  programName & " " & versionString() & "\n" &
    "usage:\n" &
    "  " & programName & " --version\n" &
    "  " & programName & " status [--json]\n" &
    "  " & programName & " sessions --json\n" &
    "  " & programName & " leases --json\n" &
    "  " & programName & " topology --json\n" &
    "  " & programName & " observations --json\n" &
    "  " & programName & " explain SESSION_ID\n" &
    "  " & programName & " daemon start|status\n" &
    "  " & programName & " stats-table [KEY]\n" &
    "  " & programName & " stats capture [--json]\n" &
    "  " & programName & " stats top [KEY] [--limit N] [--all-users] [--all-profiles] [--json]\n" &
    "  " & programName & " stats export [KEY] [--limit N] [--all-users] [--all-profiles] [--json]\n" &
    "    export writes one JSON object per execution to stdout (NDJSON) and its\n" &
    "    status to stderr, so 'stats export | jq ...' works; every recorded\n" &
    "    column is on the row, so jq does the ranking, percentiles and diffing.\n" &
    "    stats exit codes: 0 rows returned, 3 no answer (no-data/unknown-key/\n" &
    "    no-rows-in-scope), 4 no instrument (capture-off/daemon-unreachable/denied)\n" &
    "  " & programName & " acquire --cpu N --mem BYTES [--label TEXT] [--machine ID] [--stats-key KEY] [--benchmark] [-- COMMAND [ARG...]]"

proc parseMemory(value: string): uint64 =
  let lower = value.toLowerAscii()
  if lower.endsWith("gib"):
    return parseUInt(lower[0 ..< lower.len - 3]) * 1024'u64 * 1024'u64 * 1024'u64
  if lower.endsWith("mib"):
    return parseUInt(lower[0 ..< lower.len - 3]) * 1024'u64 * 1024'u64
  if lower.endsWith("kib"):
    return parseUInt(lower[0 ..< lower.len - 3]) * 1024'u64
  if lower.endsWith("gb"):
    return parseUInt(lower[0 ..< lower.len - 2]) * 1000'u64 * 1000'u64 * 1000'u64
  if lower.endsWith("mb"):
    return parseUInt(lower[0 ..< lower.len - 2]) * 1000'u64 * 1000'u64
  if lower.endsWith("kb"):
    return parseUInt(lower[0 ..< lower.len - 2]) * 1000'u64
  parseUInt(lower)

proc printStatus(json: bool): int =
  var client = connectDefault()
  defer: client.close()
  let status = client.daemonStatus()
  if json:
    echo inspectionStatusJson(status)
  else:
    echo "sessions: " & $status.activeSessions
    echo "leases: " & $status.activeLeases
    echo "supervisor_lost_leases: " & $status.supervisorLostLeases
    echo "finished_leases: " & $status.finishedLeases
    echo "total_granted: " & $status.totalGranted
    echo "total_finished: " & $status.totalFinished
    # Windows: surface memory-pressure capability + current sample so operators
    # can see whether the host backend is wired in. Identical text on every
    # platform; the value differs based on which backend signed off on it.
    echo "memory_pressure_available: " &
        $client.capabilities.memoryPressureAvailable
    echo "memory_pressure_required: " & $client.capabilities.memoryPressureRequired
    try:
      echo "memory_pressure: " & client.inspectionJson("pressure")
    except CatchableError:
      discard
  0

proc printInspection(subject: string; sessionId = sessionId(0)): int =
  var client = connectDefault()
  defer: client.close()
  echo client.inspectionJson(subject, sessionId)
  0

proc daemonProgramPath*(): string =
  let programName = addFileExt("runquotad", ExeExt)
  let sibling = getAppDir() / programName
  if fileExists(sibling):
    sibling
  else:
    programName

proc runDaemonStart(): int =
  try:
    discard printStatus(false)
    return 0
  except CatchableError:
    discard
  let process = startProcess(
    daemonProgramPath(),
    args = [],
    options = {poUsePath, poDaemon, poParentStreams}
  )
  process.close()
  for _ in 0 ..< 40:
    try:
      discard printStatus(false)
      return 0
    except CatchableError:
      sleep(50)
  echo "runquotad did not become ready"
  1

proc openPublishedTable*(): StatsTable =
  ## The client's read-only view of `runquotad`'s published aggregate table.
  ## Never raises and never blocks; an unavailable table is a miss.
  openDefaultStatsTable(defaultStatsTablePath(defaultEndpoint()))

proc socketEstimateFallback*(client: ptr RunQuotaClient): SocketEstimateFallback =
  ## THE ANSWER OF RECORD, and the reason the fast path above it is safe to
  ## have. M13a's ``statsSubjectDistribution`` read, over the socket, is what
  ## the daemon publishes into the table in the first place — the same rows,
  ## the same profile, the same number. So a table miss costs a round trip
  ## and changes no admission decision, which is what "a cache, not a second
  ## source of truth" has to mean to be worth anything.
  result = proc (statsKey: string; memoryBytes: var uint64): bool =
    try:
      let answer = client[].queryStats(statsSubjectDistribution,
        statsKey = statsKey)
      if answer.knowledge != statsKnowledgeWireKnown:
        return false
      for entry in answer.distributions:
        if entry.knowledge == statsKnowledgeWireKnown:
          memoryBytes = entry.peakRssBytesMax
          return true
      false
    except CatchableError:
      false

proc printStatsTable(statsKey: string): int =
  ## What the local view of the published table looks like, including the
  ## RETRY COUNTER — the one number that says whether the seqlock's retry
  ## path has ever actually run on this host.
  var table = openPublishedTable()
  defer: table.close()
  echo statsTableReport(table)
  if not daemonReachable(defaultEndpoint()):
    # UNAVAILABLE, SAID PLAINLY. Both answers this command can give live
    # behind `runquotad`: it is the only sanctioned reader of the store,
    # and it is the only writer of the published table. With no daemon
    # there is no source for either, and "not resident, ask over the
    # socket" would be directions to a door that is not there.
    echo standaloneStatsReport().detail
    return 0
  if statsKey.len > 0:
    var estimate: PublishedEstimate
    case table.lookupEstimate(statsKey, estimate)
    of stlHit:
      echo statsKey & ": " & $estimate.memoryBytes & " bytes over " &
        $estimate.sampleCount & " samples (" & $estimate.knowledge & ")"
    of stlAbsent:
      echo statsKey & ": not resident (ask over the socket)"
    of stlTorn:
      echo statsKey & ": torn under a concurrent publisher (ask over the socket)"
    of stlUnavailable:
      echo statsKey & ": no table attached (ask over the socket)"
  0

const StandaloneReportEnv* = "RUNQUOTA_REPORT_STANDALONE"
  ## Set to any non-empty value to have a standalone run print its own
  ## degradation to stderr.
  ##
  ## OFF BY DEFAULT, and that is the specification's decision rather than a
  ## preference: §"Standalone mode" says a missing daemon MUST NOT be
  ## reported as an error, and the stream a wrapped build writes its
  ## diagnostics to is the last place to volunteer a line that a log
  ## scanner, a CI annotation rule or a human in a hurry will read as one.
  ## The state is not hidden — it is one environment variable away, and it
  ## is the same shape as `RUNQUOTA_REPORT_ESTIMATE_SOURCE` beside it.

proc standaloneUnixMillis(): uint64 =
  uint64(max(0'i64, int64(epochTime() * 1000.0)))

proc standaloneOutcome(completion: ProcessCompletion): LeaseFinish =
  ## The same mapping ``runquota_exec.finishOutcome`` makes, and for the
  ## same reasons -- including the signal test coming before the cancel
  ## test, so a child killed by SIGTERM is named ``crashed`` and lands on
  ## ``signalled`` rather than losing the signal to a ``cancelled`` that
  ## has nowhere to carry it.
  let signal =
    if completion.signaled: uint32(max(completion.signal, 0)) else: 0'u32
  if signal != 0'u32:
    crashed(signal)
  elif completion.cancelled or completion.timedOut:
    cancelled()
  elif completion.exited and completion.exitCode > 0:
    failed(uint32(completion.exitCode))
  elif completion.exited:
    succeeded()
  else:
    cancelled()

proc runStandaloneAcquire(label, statsKey: string;
                          command: seq[string]): int =
  ## `runquota acquire` WITH NO DAEMON: run the work, buffer the
  ## observation, report no error.
  ##
  ## THE WHOLE OF M14 IS VISIBLE IN WHAT THIS PROC DOES NOT DO. It takes no
  ## lease, because there is no authority to grant one. It opens no
  ## database, because a client that wrote the store to compensate for a
  ## missing daemon would have put a database write on the per-execution
  ## path — forbidden by §"Standalone mode" and settled by the write path's
  ## first rule, that losing an observation is preferable to perturbing the
  ## work being observed. It invents no estimate, because there is nothing
  ## to learn one from and a plausible number in a measured column is worse
  ## than no number. And it returns the CHILD's exit status, because the
  ## absence of a daemon is not a failure of the work.
  ##
  ## SHORT-LIVED, so the buffered observation is dropped at exit. This
  ## process wraps one command; the connect attempt a long-lived client
  ## amortises over hundreds of executions would here be a large fraction
  ## of everything it did.
  var capture = initStandaloneCapture("runquota acquire", versionString(),
    "standalone", clShortLived)
  var exitCode = 0
  if command.len > 0:
    let startedAt = standaloneUnixMillis()
    var child = launchProcess(commandSpec(command))
    let completion = child.waitForCompletion()
    child.close()
    stdout.write(completion.stdout)
    stderr.write(completion.stderr)
    capture.record(deferredRecord(
      label = label,
      commandStatsId = statsKey,
      startedAtUnixMillis = startedAt,
      finishedAtUnixMillis = standaloneUnixMillis(),
      finish = standaloneOutcome(completion),
      peakRssBytes = completion.peakResidentMemoryBytes,
      processCount = completion.processCount))
    exitCode =
      if completion.exited: completion.exitCode
      elif completion.signaled: 128 + completion.signal
      else: 1
  # THROUGH THE SAME EXIT-FLUSH ENTRY POINT A LONG-LIVED CLIENT USES, on
  # purpose. What makes this process drop its observation is the LIFETIME
  # it declared, decided inside `planExitFlush`, and not a different call
  # site here — so "a short-lived client drops them" is a rule one place
  # implements rather than a coincidence of which branch was written where.
  let reason = capture.flushStandaloneAtExit(defaultEndpoint())
  if getEnv(StandaloneReportEnv).len > 0:
    stderr.writeLine(standaloneReport(capture, reason))
  exitCode

proc runDebugAcquire(args: seq[string]): int =
  var cpu = 1000'u32
  var memory = 128'u64 * 1024'u64 * 1024'u64
  var label = "debug"
  var machineId = ""
  var statsKey = ""
  var benchmark = false
  var command: seq[string] = @[]
  var i = 0
  while i < args.len:
    case args[i]
    of "--cpu":
      if i + 1 >= args.len: return 2
      cpu = uint32(parseUInt(args[i + 1]))
      i += 2
    of "--mem":
      if i + 1 >= args.len: return 2
      memory = parseMemory(args[i + 1])
      i += 2
    of "--label":
      if i + 1 >= args.len: return 2
      label = args[i + 1]
      i += 2
    of "--machine":
      if i + 1 >= args.len: return 2
      machineId = args[i + 1]
      i += 2
    of "--stats-key":
      if i + 1 >= args.len: return 2
      statsKey = args[i + 1]
      i += 2
    of "--benchmark":
      benchmark = true
      i += 1
    of "--":
      if i + 1 >= args.len:
        echo "missing command after --"
        return 2
      command = args[i + 1 .. ^1]
      i = args.len
    else:
      echo "unknown acquire argument: " & args[i]
      return 2
  # NO DAEMON IS NOT AN ERROR (OS-4, §"Standalone mode"). The CodeTracer
  # test runner explicitly MAY run without RunQuota and Reprobuild has
  # direct-mode invocations, so refusing here would fail work that has
  # nothing wrong with it. This supersedes the M7 rule under which a
  # direct-mode `--write-stats` failed clearly.
  var client: RunQuotaClient
  try:
    client = connectDefault()
  except CatchableError:
    return runStandaloneAcquire(label, statsKey, command)
  defer: client.close()
  var session = client.registerSession("runquota acquire", versionString())
  var request = resourceRequest(label, milliCpu(cpu), bytes(memory))
  if machineId.len > 0:
    request = request.forMachine(machineId)
  var estimateSource = esNone
  if statsKey.len > 0:
    request.commandStatsId = statsKey
    # THE ADMISSION ESTIMATE ARRIVES WITH THE REQUEST. Published table
    # first (no syscall), socket second, and no estimate at all third —
    # in which case the daemon's learned table is the fallback exactly as
    # it was before this milestone existed. The three arms produce the
    # same number wherever the number exists; only the cost differs.
    var table = openPublishedTable()
    defer: table.close()
    var estimateBytes = 0'u64
    estimateSource = table.resolveAdmissionEstimate(statsKey,
      socketEstimateFallback(addr client), estimateBytes)
    if estimateSource != esNone:
      request = request.withEstimate(estimateBytes)
    if getEnv("RUNQUOTA_REPORT_ESTIMATE_SOURCE").len > 0:
      # Not decoration: the emptied-table control has to show that the
      # SOURCE changed while the ANSWER did not, and neither fact is
      # observable from the outside otherwise.
      echo "estimate source " & $estimateSource & " bytes " & $estimateBytes &
        " " & statsTableReport(table)
  if benchmark:
    request = request.benchmarkRequest()
  if command.len > 0:
    let execution = session.runWithLease(request, command,
        waitForQueued = benchmark)
    stdout.write(execution.process.stdout)
    stderr.write(execution.process.stderr)
    session.closeSession()
    if execution.process.exited:
      return execution.process.exitCode
    if execution.process.signaled:
      return 128 + execution.process.signal
    return 1
  var lease =
    if benchmark:
      session.requestLeaseWaiting(request)
    else:
      session.requestLease(request)
  echo "lease " & $lease.id & " granted"
  lease.release()
  session.closeSession()
  echo "lease " & $lease.id & " released"
  0

# ---------------------------------------------------------------------------
# `runquota stats` — the observation store's read path, over the socket
# ---------------------------------------------------------------------------

const
  DefaultTopLimit = 20'u32
  DefaultExportLimit = 250'u32
    ## BOUNDED BY THE FRAME, AND THE NUMBERS ARE MEASURED RATHER THAN
    ## GUESSED. A full export row is **1424 bytes** on this schema — 49
    ## columns, most of them the `runs` and `host_profiles` context that
    ## makes a row readable on its own. A response must fit inside
    ## `DefaultMaxFrameBytes` (1 MiB), and measurement against a 2001-row
    ## store puts the wall between 600 rows (855 KB, works) and 700 rows
    ## (fails). So:
    ##
    ##   --limit 250  ->  356 KB   the default: pleasant, streams instantly
    ##   --limit 600  ->  855 KB   the measured ceiling, ~18% headroom
    ##   --limit 700  ->  the daemon closes the connection
    ##
    ## The ceiling is a ROW COUNT standing in for a BYTE COUNT, so a store
    ## with unusually wide rows (long branch names, long workspace ids)
    ## could still cross it under 600. That is why the transport failure
    ## below is handled as a first-class outcome rather than left to a
    ## catch-all: the static cap makes it rare, and the handler makes it
    ## legible when the cap is wrong.
  MaxExportLimit = 600'u32
  StatsProbeLimit = 200'u32
    ## THE PROBE IS A YES/NO QUESTION WITH A BOUND ON IT. It runs only when
    ## the real query came back empty, and only to decide whether that
    ## emptiness is the filters talking; an unbounded re-read at host scope
    ## across every profile would be the single most expensive query this
    ## CLI can issue, on the one path where nothing was found. The count it
    ## reports is therefore "at least this many", and the output says so.

proc statsScopeOf(options: StatsOptions): StatsScopeWire =
  if options.allUsers: statsScopeWireHost else: statsScopeWireOwner

proc statsSpanOf(options: StatsOptions): ProfileSpanWire =
  if options.allProfiles: profileSpanWireAll else: profileSpanWireSingle

proc probeRowCount(client: var RunQuotaClient; subject: StatsSubject;
                   statsKey: string): int =
  ## The same question at the WIDEST scope and span. A failure here is not
  ## an answer and must not become one: the probe only ever upgrades
  ## `unknown-key` to `no-rows-in-scope`, so losing it leaves the stricter
  ## of the two verdicts standing.
  try:
    let widened = client.queryStats(subject, statsKey,
      scope = statsScopeWireHost, span = profileSpanWireAll,
      limit = StatsProbeLimit)
    case subject
    of statsSubjectRanking: widened.rankings.len
    of statsSubjectExport, statsSubjectExtensionRows:
      widened.extensionRows.len
    of statsSubjectExecutions: widened.executions.len
    of statsSubjectDistribution:
      if widened.knowledge == statsKnowledgeWireKnown: 1 else: 0
  except CatchableError:
    0

proc render(view: StatsAnswerView; asJson: bool): string =
  if asJson: renderJson(view) else: renderHuman(view)

proc connectForStats(options: StatsOptions; client: var RunQuotaClient;
                     failed: var int): bool =
  ## NOT STANDALONE, AND THE ASYMMETRY WITH `acquire` IS DELIBERATE. A
  ## missing daemon lets work proceed; it does not let a question be
  ## answered. `daemonReachable` separates "nobody is listening" from
  ## "somebody is listening and refused us", which is what a protocol
  ## version mismatch looks like from here.
  try:
    client = connectDefault()
    return true
  except CatchableError as error:
    let detail =
      if daemonReachable(defaultEndpoint()):
        "the endpoint is bound but the handshake failed: " & error.msg
      else:
        error.msg
    let view = unreachableView(options, detail)
    if options.verb == svExport and not options.json:
      stderr.writeLine(statusLines(view))
    else:
      echo render(view, options.json)
    failed = exitCode(view.status)
    return false

proc runStatsTop(options: StatsOptions): int =
  var client: RunQuotaClient
  var failure = 0
  if not connectForStats(options, client, failure):
    return failure
  defer: client.close()
  let answer = client.queryStats(statsSubjectRanking, options.statsKey,
    scope = statsScopeOf(options), span = statsSpanOf(options),
    limit = options.limit)
  let probe =
    if answer.rankings.len == 0 and answer.captureEnabled:
      probeRowCount(client, statsSubjectRanking, options.statsKey)
    else: 0
  let view = viewOfRanking(options, answer, probe)
  echo render(view, options.json)
  exitCode(view.status)

proc runStatsExport(options: StatsOptions): int =
  ## THE ROWS GO TO STDOUT AND NOTHING ELSE EVER DOES. `runquota stats
  ## export | jq ...` is the whole point of the verb, so a status line —
  ## or an error message — in that stream would break it. Status goes to
  ## stderr and into the exit code, where it breaks nothing and is still
  ## impossible to miss.
  ##
  ## THE TRANSPORT FAILURE IS CAUGHT HERE RATHER THAN IN THE CATCH-ALL,
  ## and that is not tidiness. `runThinApp`'s handler `echo`s the message,
  ## which puts `daemon closed the RQSP connection` ON STDOUT, in the
  ## middle of the NDJSON — the one place a non-JSON line does real
  ## damage. It was observed doing exactly that at `--limit 700` before
  ## the ceiling above was measured.
  var client: RunQuotaClient
  var failure = 0
  if not connectForStats(options, client, failure):
    return failure
  defer: client.close()
  var view: StatsAnswerView
  try:
    let answer = client.queryStats(statsSubjectExport, options.statsKey,
      scope = statsScopeOf(options), span = statsSpanOf(options),
      limit = options.limit)
    let probe =
      if answer.extensionRows.len == 0 and answer.captureEnabled:
        probeRowCount(client, statsSubjectExport, options.statsKey)
      else: 0
    view = viewOfExport(options, answer, probe)
  except CatchableError as error:
    view = unreachableView(options,
      error.msg & " — a response this size may have exceeded the " &
      "transport's frame limit; retry with a smaller --limit (rows are " &
      "about 1.4 KB each).")
  if options.json:
    echo renderJson(view)
  else:
    # STDERR FIRST, so a reader watching a terminal sees why an empty
    # stream is empty before they see that it is empty.
    stderr.writeLine(statusLines(view))
    if view.rows.len > 0:
      echo renderNdjson(view)
  exitCode(view.status)

proc runStatsCapture(asJson: bool): int =
  ## "IS CAPTURE EVEN ON?" — asked the way every other verb asks it, from
  ## the same `captureEnabled` field they gate their answers on.
  var options = StatsOptions(verb: svCapture, json: asJson)
  var client: RunQuotaClient
  var failure = 0
  if not connectForStats(options, client, failure):
    return failure
  defer: client.close()
  let answer = client.queryStats(statsSubjectRanking, "", limit = 1'u32)
  var detail = "{}"
  try:
    detail = client.inspectionJson("observations")
  except CatchableError:
    discard
  echo renderCapture(answer.captureEnabled, detail, asJson)
  exitCode(if answer.captureEnabled: asOk else: asCaptureOff)

proc parseStatsOptions(args: seq[string]; options: var StatsOptions): bool =
  ## Returns false on anything unrecognised. A misspelt flag must not be
  ## absorbed into a query that then answers about something else.
  if args.len == 0:
    return false
  try:
    options.verb = parseEnum[StatsVerb](args[0])
  except ValueError:
    return false
  options.limit =
    if options.verb == svExport: DefaultExportLimit else: DefaultTopLimit
  var index = 1
  if index < args.len and not args[index].startsWith("--"):
    options.statsKey = args[index]
    index += 1
  while index < args.len:
    case args[index]
    of "--json":
      options.json = true
      index += 1
    of "--all-users":
      options.allUsers = true
      index += 1
    of "--all-profiles":
      options.allProfiles = true
      index += 1
    of "--limit":
      if index + 1 >= args.len: return false
      options.limit = uint32(parseUInt(args[index + 1]))
      index += 2
    else:
      return false
  if options.verb == svExport:
    # REFUSED, NOT CLAMPED. A caller who asked for 5000 rows and silently
    # got 1200 would draw conclusions from a window they did not choose;
    # a caller told the bound can decide whether it matters.
    if options.limit == 0'u32 or options.limit > MaxExportLimit:
      return false
  true

proc runStats(programName: string; args: seq[string]): int =
  var options = StatsOptions()
  if not parseStatsOptions(args, options):
    # A REFUSAL WITH THE SHAPE IN IT. A misspelt verb or flag that exited
    # silently would be indistinguishable, at a glance, from a query that
    # found nothing -- which is the one confusion this whole surface
    # exists to remove.
    #
    # ON STDERR, because `stats export` writes NDJSON to stdout and the
    # rule that nothing else ever does has to hold on the error paths too
    # -- those are exactly the paths a caller has not looked at yet.
    stderr.writeLine("unrecognised 'stats' invocation")
    stderr.writeLine(renderUsage(programName))
    return 2
  case options.verb
  of svCapture: runStatsCapture(options.json)
  of svTop: runStatsTop(options)
  of svExport: runStatsExport(options)

proc runThinApp*(programName: string): int =
  let args = commandLineParams()
  if wantsVersion(args):
    echo renderVersion(programName)
    return 0
  if args.len >= 1:
    try:
      case args[0]
      of "status":
        return printStatus(args.len == 2 and args[1] == "--json")
      of "sessions":
        if args.len == 2 and args[1] == "--json":
          return printInspection("sessions")
      of "leases":
        if args.len == 2 and args[1] == "--json":
          return printInspection("leases")
      of "topology":
        if args.len == 2 and args[1] == "--json":
          return printInspection("topology")
      of "observations":
        # Whether capture is on, which store is open, and how many
        # in-flight client reports were accepted, refused or dropped.
        # `--no-write-stats` and a store that degraded look identical from
        # outside otherwise, and an operator who cannot tell them apart
        # cannot tell a deliberate decision from a broken host.
        if args.len == 2 and args[1] == "--json":
          return printInspection("observations")
      of "explain":
        if args.len == 2:
          return printInspection("explain", sessionId(parseUInt(args[1])))
      of "daemon":
        if args.len == 2 and args[1] == "start":
          return runDaemonStart()
        if args.len == 2 and args[1] == "status":
          return printStatus(false)
      of "stats-table":
        # The published aggregate table as THIS client sees it. Reading it
        # costs no round trip, which is the entire point, so an operator
        # asking what the daemon has published does not perturb the daemon.
        if args.len == 1:
          return printStatsTable("")
        if args.len == 2:
          return printStatsTable(args[1])
      of "stats":
        # THE OBSERVATION STORE'S READ PATH. Distinct from `stats-table`
        # above, which is the published aggregate CACHE as this client maps
        # it: that one answers "what has the daemon published for
        # admission", this one answers "what has this host recorded".
        return runStats(programName, args[1 .. ^1])
      of "acquire":
        return runDebugAcquire(args[1 .. ^1])
      else:
        discard
    except CatchableError as error:
      echo error.msg
      return 1
  echo renderUsage(programName)
  0
