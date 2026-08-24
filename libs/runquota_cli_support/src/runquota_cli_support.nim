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

proc standaloneOutcome(completion: ProcessCompletion): LeaseFinishOutcome =
  if completion.cancelled or completion.timedOut:
    leaseFinishCancelled
  elif completion.signaled:
    leaseFinishCrashed
  elif completion.exited and completion.exitCode == 0:
    leaseFinishSucceeded
  else:
    leaseFinishFailed

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
      outcome = standaloneOutcome(completion),
      exitStatus =
        if completion.exited: uint32(max(completion.exitCode, 0)) else: 0'u32,
      signal =
        if completion.signaled: uint32(max(completion.signal, 0)) else: 0'u32,
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
      of "acquire":
        return runDebugAcquire(args[1 .. ^1])
      else:
        discard
    except CatchableError as error:
      echo error.msg
      return 1
  echo renderUsage(programName)
  0
