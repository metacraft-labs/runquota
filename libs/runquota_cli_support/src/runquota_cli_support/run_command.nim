## `runquota run`: take a CPU lease, hand the grant to the command through an
## adapter, run it, release the lease.
##
##   runquota run [--width MIN[:PREF]] [--stats-key KEY] [--adapter NAME]
##                [--cap] [--verbose] -- COMMAND [ARG...]
##
## This is the bridge for build tools that have no RunQuota client of
## their own: the tool keeps its own parallelism, and this wrapper makes
## that parallelism as wide as the lease it holds (see `run_adapters` for the
## per-tool rules). The lease/session/launch machinery is the same that
## `runquota acquire` uses; the differences are that the child inherits the
## terminal (its output streams instead of being captured and replayed) and
## that the width is negotiated rather than fixed.
##
## EXIT STATUS
##   the child's exit status when it ran;
##   128 + N when the child was killed by signal N (as `acquire` reports);
##   2   bad arguments, or `--cap` (not available yet);
##   1   the daemon refused or lost the lease, so the command never ran;
##   127 the command could not be started.
## SIGTERM and SIGHUP sent to the wrapper are forwarded to the command;
## SIGINT is left to the terminal, which delivers it to the command itself.
## No daemon answering is NOT an error: the command runs unchanged and
## unbounded, as `acquire` does, because the absence of an authority is not a
## failure of the work.
import std/[cpuinfo, options, os, strutils]
when defined(posix):
  import std/posix

import runquota_client
import runquota_core
import runquota_exec
import runquota_process
import runquota_protocol
import runquota_cli_support/run_adapters

const
  RunLeaseMemoryBytes* = 128'u64 * 1024'u64 * 1024'u64
    ## What the lease declares for memory. The wrapper cannot know the
    ## tool's footprint; this is the same nominal figure `acquire` uses, and
    ## a learned estimate (when the daemon has one under the stats key)
    ## takes precedence on the daemon side.
  DefaultPreferredWidthCap* = 8
    ## `PREF` defaults to the host's logical CPU count capped here: a
    ## single build or test run seldom scales past it, and the remainder
    ## stays available to the other sessions sharing the budget.
  WidthEnvVar* = "RUNQUOTA_RUN_WIDTH"
    ## Exported to the child: the grant in slots, for scripts and tools that
    ## no adapter covers.
  StatsKeyEnvVar* = "RUNQUOTA_RUN_STATS_KEY"

type
  RunOptions* = object
    minWidth*: int
    preferredWidth*: int
      ## 0 until resolved: the default depends on the host.
    statsKey*: string
    adapter*: string ## "" = detect, "none" = no adaptation
    cap*: bool
    verbose*: bool
    listAdapters*: bool
    command*: seq[string]

when defined(posix):
  var forwardTarget: cint = 0
    ## The pid of the child THIS process started, or 0. Plain integer
    ## because a signal handler may touch nothing else.

  proc forwardTerminationSignal(signal: cint) {.noconv.} =
    ## SIGTERM and SIGHUP sent to the wrapper alone would otherwise end it
    ## with the child still running and its lease already released, so the
    ## child would keep consuming CPU the daemon no longer accounts for.
    ## Forwarded to the one pid we started.
    if forwardTarget > 0:
      discard kill(Pid(forwardTarget), signal)

  proc ignoreInterruptHere(signal: cint) {.noconv.} =
    ## SIGINT from a terminal already reaches the child, which shares this
    ## process's group; forwarding it too would deliver it twice and tools
    ## treat a second interrupt as "abort now". A HANDLER rather than
    ## SIG_IGN, because an ignored disposition survives exec and the child
    ## would inherit it.
    discard

  proc installSignalForwarding() =
    signal(SIGTERM, forwardTerminationSignal)
    signal(SIGHUP, forwardTerminationSignal)
    signal(SIGINT, ignoreInterruptHere)

proc cExit(status: cint) {.importc: "exit", header: "<stdlib.h>", noreturn.}

proc exitWithStatus*(status: int) {.noreturn.} =
  ## Ends the process with `status` unchanged. Nim's own `quit` narrows a
  ## POSIX status to the range of a signed byte (Nim 2.2.4: `quit 143`
  ## exits 127), which would turn every `128 + signal` this wrapper reports
  ## into 127. The C `exit` keeps the low eight bits and still flushes
  ## stdio.
  stdout.flushFile()
  stderr.flushFile()
  if status in 0 .. 127:
    quit(status)
  cExit(cint(status))

proc defaultPreferredWidth*(): int =
  max(1, min(countProcessors(), DefaultPreferredWidthCap))

proc parseWidthRange*(text: string; minWidth, preferredWidth: var int):
    bool =
  ## `N` is a fixed width (MIN = PREF = N); `MIN:PREF` a range; `MIN:`
  ## leaves PREF to the default (0 here, resolved later); `:PREF` leaves
  ## MIN at 1. Widths are whole slots from 1 up.
  proc number(part: string; value: var int): bool =
    if part.len == 0 or part.len > 6: return false
    for ch in part:
      if ch notin {'0' .. '9'}: return false
    value = parseInt(part)
    value >= 1
  let colon = text.find(':')
  if colon < 0:
    if not number(text, minWidth): return false
    preferredWidth = minWidth
    return true
  let left = text[0 ..< colon]
  let right = text[colon + 1 .. ^1]
  minWidth = 1
  preferredWidth = 0
  if left.len > 0 and not number(left, minWidth): return false
  if right.len > 0 and not number(right, preferredWidth): return false
  preferredWidth == 0 or preferredWidth >= minWidth

proc parseRunArgs*(args: seq[string]; options: var RunOptions;
                   error: var string): bool =
  options = RunOptions(minWidth: 1)
  var i = 0
  while i < args.len:
    let arg = args[i]
    case arg
    of "--width":
      if i + 1 >= args.len or
          not parseWidthRange(args[i + 1], options.minWidth,
            options.preferredWidth):
        error = "--width takes N or MIN:PREF with whole numbers from 1 " &
          "(MIN <= PREF)"
        return false
      i += 2
    of "--stats-key":
      if i + 1 >= args.len or args[i + 1].len == 0:
        error = "--stats-key needs a value"
        return false
      options.statsKey = args[i + 1]
      i += 2
    of "--adapter":
      if i + 1 >= args.len:
        error = "--adapter needs a name (or list, none)"
        return false
      let name = args[i + 1]
      if name == "list":
        options.listAdapters = true
      elif name != "none" and findAdapter(name) < 0:
        error = "unknown adapter '" & name & "'; try --adapter list"
        return false
      else:
        options.adapter = name
      i += 2
    of "--cap":
      options.cap = true
      inc i
    of "--verbose", "-v":
      options.verbose = true
      inc i
    of "--":
      options.command = args[i + 1 .. ^1]
      i = args.len
    else:
      error = "unknown run argument: " & arg
      return false
  if options.listAdapters:
    return true
  if options.command.len == 0:
    error = "missing command; usage: runquota run [--width MIN[:PREF]] " &
      "[--stats-key KEY] [--adapter NAME] -- COMMAND [ARG...]"
    return false
  true

proc projectNameOf*(dir: string): string =
  ## The project a working directory belongs to: the base name of the
  ## nearest ancestor holding a `.git` entry (directory or file, so
  ## worktrees count), else the base name of the directory itself.
  var current = absolutePath(dir)
  while true:
    if dirExists(current / ".git") or fileExists(current / ".git"):
      return extractFilename(current)
    let parent = parentDir(current)
    if parent.len == 0 or parent == current: break
    current = parent
  extractFilename(absolutePath(dir))

proc deriveStatsKey*(command: seq[string]; cwd: string): string =
  ## `run/<program>@<project>`: the program's base name plus the project of
  ## the working directory, so the same tool in different projects learns
  ## separate shapes. The `run/` prefix keeps these apart from keys other
  ## clients choose.
  let program = if command.len > 0: baseName(command[0]) else: "command"
  "run/" & program & "@" & projectNameOf(cwd)

proc learnedWidth*(statsKey: string): Option[int] =
  ## HOOK FOR THE LEARNED WIDTH. When the daemon exposes per-key CPU
  ## profile totals (the peak slots a command under this key has used over
  ## its recent runs), this returns that peak and `runquota run` without
  ## `--width` requests it as its preferred width instead of the default.
  ## Until then there is nothing to learn from, so the answer is none and
  ## the default applies. Do not synthesise a number here: a plausible
  ## figure in place of a measured one is worse than none.
  discard statsKey
  none(int)

proc preferredWidthFor*(options: RunOptions; statsKey: string): int =
  ## The width asked for first: an explicit PREF, else the learned width
  ## for the key, else the host default; never below MIN.
  var wanted = options.preferredWidth
  if wanted == 0:
    let learned = learnedWidth(statsKey)
    wanted = if learned.isSome: learned.get() else: defaultPreferredWidth()
  max(wanted, options.minWidth)

proc widthLadder*(preferred, minimum: int): seq[int] =
  ## The widths to try, widest first: PREF, then halves of it, ending at
  ## MIN. The daemon grants a lease whole or refuses it, so a range is
  ## negotiated by asking again lower after a refusal.
  var width = preferred
  while width > minimum:
    result.add width
    width = max(minimum, width div 2)
  result.add minimum

proc grantedSlots(lease: RunQuotaLease): int =
  ## Whole slots in a grant (a fractional grant rounds up: it was paid for).
  let milli = int(lease.resources.cpu.value)
  max(1, (milli + 999) div 1000)

proc exitCodeOf(completion: ProcessCompletion): int =
  if completion.exited: completion.exitCode
  elif completion.signaled: 128 + completion.signal
  else: 1

proc runUnleased(command: seq[string]; env: seq[string]): int =
  ## No daemon: run the command as given.
  try:
    var child = launchProcess(commandSpec(command, env = env,
      stdio = inheritStdio, createProcessGroup = false))
    let completion = child.waitForCompletion()
    child.close()
    exitCodeOf(completion)
  except CatchableError as error:
    stderr.writeLine("runquota run: cannot start " & command[0] & ": " &
      error.msg)
    127

proc chooseAdapter(options: RunOptions): int =
  case options.adapter
  of "none": -1
  of "": detectAdapter(options.command)
  else: findAdapter(options.adapter)

proc runRun*(args: seq[string];
             describeFailure: proc(message: string; last: Diagnostic): string;
             clientVersion: string): int =
  ## The `run` verb. `describeFailure` renders a client error the way the
  ## rest of the CLI does (message plus the daemon's detail).
  var options: RunOptions
  var error = ""
  if not parseRunArgs(args, options, error):
    stderr.writeLine("runquota run: " & error)
    return 2
  if options.listAdapters:
    echo renderAdapterList()
    return 0
  if options.cap:
    # `--cap` is enforcement of the grant through the kernel's CPU
    # controller. That belongs to the host enforcement work, not to this
    # wrapper; accepting the flag and not enforcing would be a lie.
    stderr.writeLine("runquota run: --cap is not available yet " &
      "(CPU-limit enforcement has not shipped)")
    return 2

  let statsKey =
    if options.statsKey.len > 0: options.statsKey
    else: deriveStatsKey(options.command, getCurrentDir())
  let adapterIndex = chooseAdapter(options)
  let adapters = registry()

  var client: RunQuotaClient
  try:
    client = connectDefault()
  except CatchableError as failure:
    if options.verbose:
      stderr.writeLine("runquota run: no daemon reached (" & failure.msg &
        "); running the command unchanged")
    return runUnleased(options.command, @[StatsKeyEnvVar & "=" & statsKey])
  defer: client.close()

  var session = client.registerSession("runquota run", clientVersion)
  var lease: RunQuotaLease
  var granted = false
  try:
    let ladder = widthLadder(preferredWidthFor(options, statsKey),
      options.minWidth)
    var lastError = ""
    for width in ladder:
      var request = resourceRequest("run " & baseName(options.command[0]),
        milliCpu(uint32(width) * 1000'u32), bytes(RunLeaseMemoryBytes))
      request.commandStatsId = statsKey
      try:
        lease = session.requestLeaseWaiting(request)
        granted = true
        break
      except RunQuotaClientError as refusal:
        lastError = describeFailure(refusal.msg, client.lastDiagnostic)
    if not granted:
      stderr.writeLine("runquota run: no lease at width " &
        $options.minWidth & " or above: " & lastError)
      return 1
  except RunQuotaClientError as failure:
    stderr.writeLine("runquota run: " &
      describeFailure(failure.msg, client.lastDiagnostic))
    return 1

  let slots = grantedSlots(lease)
  var command = options.command
  var env = @[WidthEnvVar & "=" & $slots, StatsKeyEnvVar & "=" & statsKey]
  if adapterIndex >= 0:
    let outcome = applyAdapter(adapters[adapterIndex], options.command, slots)
    command = outcome.argv
    env.add outcome.env
    if options.verbose:
      for note in outcome.notes:
        stderr.writeLine("runquota run: " & adapters[adapterIndex].name &
          ": " & note)
  if options.verbose:
    stderr.writeLine("runquota run: lease " & $lease.id & " width " &
      $slots & ": " & command.join(" "))

  var code = 0
  var ran = false
  when defined(posix):
    installSignalForwarding()
  try:
    lease.markStarting()
    var child: LaunchedProcess
    try:
      child = launchProcess(commandSpec(command, env = env,
        stdio = inheritStdio, createProcessGroup = false))
    except CatchableError as failure:
      lease.finish(outcome = launchFailed())
      lease.release()
      session.closeSession()
      stderr.writeLine("runquota run: cannot start " & command[0] & ": " &
        failure.msg)
      return 127
    when defined(posix):
      forwardTarget = cint(child.info.processId)
    lease.markRunning(childProcessId = child.info.processId)
    let completion = child.waitForCompletion()
    when defined(posix):
      forwardTarget = 0
    child.close()
    lease.finish(outcome = finishOutcome(completion),
      peakMemoryBytes = completion.peakResidentMemoryBytes,
      processCount = completion.processCount)
    code = exitCodeOf(completion)
    ran = true
    lease.release()
    session.closeSession()
  except RunQuotaClientError as failure:
    # The command already ran (or never started); losing the daemon at the
    # end must not change its verdict.
    stderr.writeLine("runquota run: " &
      describeFailure(failure.msg, client.lastDiagnostic))
    if not ran: code = 1
  code
