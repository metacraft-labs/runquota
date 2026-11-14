## `runquota jobserver`: hold one lease for a command and serve it a GNU make
## jobserver whose tokens are that lease's slots.
##
##   runquota jobserver [--width MIN[:PREF]] [--mem SIZE] [--stats-key KEY]
##                      [--verbose] -- COMMAND [ARG...]
##
## This is the bridge for tools that already speak the GNU make jobserver
## protocol (GNU make 4.4, cargo and rustc, ninja 1.13, GCC's
## `-flto=jobserver`). Unlike `runquota run`, nothing about the tool's command
## line has to be known: the tool asks the jobserver for a token before each
## extra job and gives it back afterwards, so its parallelism follows the
## lease by construction.
##
## TOKEN ARITHMETIC. A jobserver client holds one IMPLICIT token for itself
## and reads a token from the jobserver only for each job beyond the first
## (GNU make's protocol, and cargo's: an inherited jobserver of three tokens
## gives four concurrent rustc). An N-slot grant therefore serves N - 1
## tokens; serving N would run N + 1 jobs.
##
## THE TRANSPORT is the GNU make 4.4 named FIFO,
## `--jobserver-auth=fifo:PATH`
## (https://www.gnu.org/software/make/manual/html_node/POSIX-Jobserver.html).
## The bridge creates it in a fresh 0700 directory, keeps it open read-write
## for the command's whole life (so token writes never block and a reader
## never sees end-of-file), and removes it when the command ends.
##
## NESTING. With `RUNQUOTA_PARENT_LEASE` set (by `runquota acquire`,
## `runquota run` or another supervising client), the lease is a SUB-LEASE of
## that parent: its slots come out of the parent's grant and never from the
## host ledger, so a nested tool cannot queue on the host behind its own
## parent. Inside a bridge the jobserver itself is the nesting mechanism: the
## bridge removes `RUNQUOTA_PARENT_LEASE` from its command's environment (its
## whole width is already out as tokens), and a `runquota jobserver` started
## inside another bridge's tree joins that bridge's jobserver, as a recursive
## make joins its parent's.
##
## EXIT STATUS: as `runquota run` -- the command's status, 128 + N for a
## command killed by signal N, 2 for bad arguments, 1 when no lease could be
## had, 127 when the command could not be started. With no daemon answering
## the command runs unchanged, with no jobserver.
import std/[options, os, strutils]
when defined(posix):
  import std/posix

import runquota_client
import runquota_core
import runquota_exec
import runquota_process
import runquota_protocol
import runquota_cli_support/run_command

const
  JobserverFifoEnvVar* = "RUNQUOTA_JOBSERVER_FIFO"
    ## Exported to the command: the bridge's FIFO. A nested
    ## `runquota jobserver` that finds it, and finds `MAKEFLAGS` still naming
    ## it, joins this jobserver instead of taking a lease of its own.
  DefaultMemoryPerSlot* = 512'u64 * 1024'u64 * 1024'u64
    ## What a host lease reserves per granted slot when `--mem` is not
    ## given. A nominal figure: the bridge cannot know the tool's footprint,
    ## and the daemon's learned estimate under the stats key raises it once
    ## the key has history.
  TokenByte = '+'
    ## GNU make writes `+`; clients hand back whatever byte they read, so
    ## the value only matters for being one byte.
  LeftoverGraceMillis = 2000
    ## How long what is left of the command's process group gets between
    ## SIGTERM and SIGKILL once the command itself has exited.

type
  JobserverOptions* = object
    minWidth*: int
    preferredWidth*: int ## 0 until resolved
    memoryBytes*: uint64 ## 0 = the default for the lease kind
    memoryGiven*: bool
    statsKey*: string
    verbose*: bool
    command*: seq[string]

# ---------------------------------------------------------------------------
# Pure helpers (unit-tested in tests/unit/t_jobserver_bridge.nim)
# ---------------------------------------------------------------------------

proc tokensForSlots*(slots: int): int =
  ## The tokens an N-slot grant serves: N - 1, since the command holds the
  ## Nth implicitly. Never negative.
  max(0, slots - 1)

proc parseMemorySize*(text: string; value: var uint64): bool =
  ## Bytes, or a whole number with a `KiB`, `MiB` or `GiB` suffix (also
  ## `K`, `M`, `G`). Zero is refused: an explicit reservation of nothing is
  ## the default spelled wrongly.
  var digits = text.strip()
  var multiplier = 1'u64
  for (suffix, factor) in [("KiB", 1024'u64), ("MiB", 1024'u64 * 1024),
      ("GiB", 1024'u64 * 1024 * 1024), ("K", 1024'u64),
      ("M", 1024'u64 * 1024), ("G", 1024'u64 * 1024 * 1024)]:
    if digits.endsWith(suffix):
      digits = digits[0 ..< digits.len - suffix.len]
      multiplier = factor
      break
  if digits.len == 0 or digits.len > 12:
    return false
  for ch in digits:
    if ch notin {'0' .. '9'}:
      return false
  let number = parseBiggestUInt(digits)
  if number == 0'u64 or number > high(uint64) div multiplier:
    return false
  value = uint64(number) * multiplier
  true

proc isJobserverWord(word: string): bool =
  ## The `MAKEFLAGS` words that describe a jobserver or a job count. The
  ## bridge drops them all before adding its own: a stale count or an
  ## outer make's jobserver must not survive beside the bridge's.
  word.startsWith("-j") or word.startsWith("--jobs") or
    word.startsWith("--jobserver-auth=") or
    word.startsWith("--jobserver-fds=")

proc bridgeMakeflags*(inherited: string; slots: int; fifoPath: string):
    string =
  ## The `MAKEFLAGS` (and `CARGO_MAKEFLAGS`) the command receives: the
  ## inherited words that are not about jobs, then ` -jN
  ## --jobserver-auth=fifo:PATH`, which is how GNU make 4.4 itself spells a
  ## FIFO jobserver to its children. The leading space matters to make: a
  ## first word without a dash is read as single-letter flags.
  var kept: seq[string] = @[]
  for word in inherited.splitWhitespace():
    if not isJobserverWord(word):
      kept.add word
  result = (if kept.len > 0: " " & kept.join(" ") else: "")
  result.add " -j" & $max(1, slots) & " --jobserver-auth=fifo:" & fifoPath

proc fifoNamedByMakeflags*(makeflags: string): string =
  ## The FIFO a `MAKEFLAGS` names (its last `--jobserver-auth=fifo:` word,
  ## which is the one make itself honours), or "".
  for word in makeflags.splitWhitespace():
    const prefix = "--jobserver-auth=fifo:"
    if word.startsWith(prefix):
      result = word[prefix.len .. ^1]

proc joinsInheritedBridge*(makeflags, bridgeFifo: string): bool =
  ## Whether this process runs inside another bridge's jobserver: the
  ## bridge's marker names a FIFO and the `MAKEFLAGS` the tools below it
  ## pass on still names the same one. A marker alone is not enough -- a
  ## tool in between may have started its own jobserver, and then that one
  ## is what this process's implicit token belongs to.
  bridgeFifo.len > 0 and fifoNamedByMakeflags(makeflags) == bridgeFifo

proc isWidthFlagProgram*(program: string): bool =
  ## The jobserver clients whose explicit width flag OVERRIDES an inherited
  ## jobserver. Measured 2026-11-14 against a 3-token FIFO: `make -j`,
  ## `make -j8` and `ninja -j8` each ran 8 jobs; without the flag, 4.
  let name = extractFilename(program)
  name in ["make", "gmake", "ninja"]

proc stripWidthFlags*(command: seq[string]; removed: var seq[string]):
    seq[string] =
  ## `command` without `-j`, `-jN`, `-j N`, `--jobs`, `--jobs=N` and
  ## `--jobs N` when its program is make or ninja; unchanged otherwise.
  ## Only those spellings: a flag cluster such as `-kj8` is left alone, and
  ## nothing after a `--` is touched.
  if command.len == 0 or not isWidthFlagProgram(command[0]):
    return command
  proc allDigits(text: string): bool =
    text.len > 0 and text.allCharsInSet({'0' .. '9'})
  result = @[command[0]]
  var i = 1
  while i < command.len:
    let arg = command[i]
    if arg == "--":
      result.add command[i .. ^1]
      break
    if arg == "-j" or arg == "--jobs":
      removed.add arg
      if i + 1 < command.len and allDigits(command[i + 1]):
        removed.add command[i + 1]
        inc i
    elif (arg.startsWith("-j") and allDigits(arg[2 .. ^1])) or
        (arg.startsWith("--jobs=") and allDigits(arg[7 .. ^1])):
      removed.add arg
    else:
      result.add arg
    inc i

proc parseJobserverArgs*(args: seq[string]; options: var JobserverOptions;
                         error: var string): bool =
  options = JobserverOptions(minWidth: 1)
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
    of "--mem":
      if i + 1 >= args.len or
          not parseMemorySize(args[i + 1], options.memoryBytes):
        error = "--mem takes a size in bytes, or with a KiB, MiB or GiB " &
          "suffix, above 0"
        return false
      options.memoryGiven = true
      i += 2
    of "--stats-key":
      if i + 1 >= args.len or args[i + 1].len == 0:
        error = "--stats-key needs a value"
        return false
      options.statsKey = args[i + 1]
      i += 2
    of "--verbose", "-v":
      options.verbose = true
      inc i
    of "--":
      options.command = args[i + 1 .. ^1]
      i = args.len
    else:
      error = "unknown jobserver argument: " & arg
      return false
  if options.command.len == 0:
    error = "missing command; usage: runquota jobserver [--width MIN[:PREF]] " &
      "[--mem SIZE] [--stats-key KEY] -- COMMAND [ARG...]"
    return false
  true

# ---------------------------------------------------------------------------
# The FIFO
# ---------------------------------------------------------------------------

type
  JobserverFifo* = object
    dir*: string
    path*: string
    fd*: cint
    served*: int

when defined(posix):
  proc mkdtemp(pattern: cstring): cstring {.importc, header: "<stdlib.h>".}

  proc openJobserverFifo*(tokens: int): JobserverFifo =
    ## A fresh FIFO holding `tokens` bytes, in a fresh 0700 directory under
    ## the temporary directory, opened read-write and close-on-exec by this
    ## process. The command opens it by path; this descriptor is what keeps
    ## the tokens alive between their readers.
    var pattern = getTempDir() / "runquota-js.XXXXXX"
    let made = mkdtemp(pattern.cstring)
    if made.isNil:
      raise newException(OSError, "cannot create a directory for the " &
        "jobserver: " & $strerror(errno))
    result.dir = $made
    result.path = result.dir / "fifo"
    result.fd = -1
    if mkfifo(result.path.cstring, Mode(0o600)) != 0:
      let reason = $strerror(errno)
      discard rmdir(result.dir.cstring)
      raise newException(OSError, "cannot create the jobserver FIFO: " &
        reason)
    result.fd = posix.open(result.path.cstring,
      O_RDWR or O_NONBLOCK or O_CLOEXEC)
    if result.fd < 0:
      let reason = $strerror(errno)
      discard unlink(result.path.cstring)
      discard rmdir(result.dir.cstring)
      raise newException(OSError, "cannot open the jobserver FIFO: " & reason)
    if tokens > 0:
      let bytes = repeat(TokenByte, tokens)
      # A FIFO's buffer is at least PIPE_BUF (4 KiB) and a grant is far
      # narrower than that, so one write puts every token in at once.
      if posix.write(result.fd, bytes.cstring, bytes.len) != bytes.len:
        let reason = $strerror(errno)
        discard posix.close(result.fd)
        discard unlink(result.path.cstring)
        discard rmdir(result.dir.cstring)
        raise newException(OSError, "cannot fill the jobserver FIFO: " &
          reason)
    result.served = tokens

  proc drainTokens*(fifo: JobserverFifo): int =
    ## How many tokens are back in the FIFO. Read once the command's tree
    ## is gone: every token a process still held went with it.
    var buffer: array[256, char]
    while true:
      let got = posix.read(fifo.fd, addr buffer[0], buffer.len)
      if got <= 0: break
      result += got

  proc closeJobserverFifo*(fifo: var JobserverFifo) =
    ## Removes the FIFO and its directory. A process that still has the
    ## FIFO open keeps its descriptor, but no new one can find it.
    if fifo.fd >= 0:
      discard posix.close(fifo.fd)
      fifo.fd = -1
    # Idempotent: the names are forgotten once removed, so a second call
    # (the deferred one) cannot remove a path someone has made since.
    if fifo.path.len > 0:
      discard unlink(fifo.path.cstring)
      fifo.path = ""
    if fifo.dir.len > 0:
      discard rmdir(fifo.dir.cstring)
      fifo.dir = ""

# ---------------------------------------------------------------------------
# Signals, the terminal, and what the command leaves behind
# ---------------------------------------------------------------------------

when defined(posix):
  var forwardGroup: cint = 0
    ## The process group of the command THIS process started, or 0. Plain
    ## integer because a signal handler may touch nothing else.

  proc forwardToGroup(signal: cint) {.noconv.} =
    ## The command runs in its own group, so a signal sent to the bridge --
    ## by `kill`, or by a terminal that still has the bridge in front --
    ## would otherwise not reach it, and the bridge would then release the
    ## lease with the command still running.
    if forwardGroup > 0:
      discard kill(Pid(-forwardGroup), signal)

  proc installGroupForwarding() =
    signal(SIGTERM, forwardToGroup)
    signal(SIGHUP, forwardToGroup)
    signal(SIGINT, forwardToGroup)

  proc removeGroupForwarding() =
    ## Once the group is gone there is nothing to forward to, and a handler
    ## left in place would make the bridge itself deaf to SIGINT, SIGTERM
    ## and SIGHUP while it finishes and releases the lease.
    forwardGroup = 0
    signal(SIGTERM, SIG_DFL)
    signal(SIGHUP, SIG_DFL)
    signal(SIGINT, SIG_DFL)

  proc swapDisposition(sig: cint; handler: proc (s: cint) {.noconv.}): proc (s: cint) {.noconv.} {.
    importc: "signal", header: "<signal.h>".}
    ## C `signal`, for the previous disposition `std/posix` does not return.

  proc handTerminalTo(group: Pid): bool =
    ## Puts `group` in the terminal's foreground, as a shell does for a job
    ## it starts, when this process is itself in front of a terminal on its
    ## standard input; answers whether it did. Without it a tool that reads
    ## or reconfigures the terminal (a credential prompt, a progress bar
    ## that sets modes) would be stopped by SIGTTIN or SIGTTOU in its
    ## background group. SIGTTOU is ignored around the call because a
    ## process changing the foreground group from the background gets one.
    if isatty(STDIN_FILENO) == 0 or tcgetpgrp(STDIN_FILENO) != getpgrp():
      return false
    let previous = swapDisposition(SIGTTOU, SIG_IGN)
    result = tcsetpgrp(STDIN_FILENO, group) == 0
    discard swapDisposition(SIGTTOU, previous)
    if result:
      # The command may have touched the terminal before it was in front
      # and been stopped for it; it is in front now.
      discard kill(Pid(-group), SIGCONT)

  proc takeTerminalBack() =
    let previous = swapDisposition(SIGTTOU, SIG_IGN)
    discard tcsetpgrp(STDIN_FILENO, getpgrp())
    discard swapDisposition(SIGTTOU, previous)

  proc groupAlive(group: Pid): bool =
    kill(Pid(-group), 0) == 0

  proc endLeftovers*(group: Pid): bool =
    ## Ends what is left of the command's process group after the command
    ## itself has exited: SIGTERM, then SIGKILL after a grace period.
    ## Answers whether anything was left.
    ##
    ## THESE PROCESSES ARE THE COMMAND'S OWN: the group was created for it
    ## by this process and nothing else joins it. They would otherwise go
    ## on using CPU, and holding tokens, after the lease is released, where
    ## no reservation accounts for them -- a killed `make` leaves its
    ## recipes running, a killed `cargo` its rustc. A process that means to
    ## outlive the build leaves the group (`setsid`), as daemons do, and is
    ## not touched.
    if group <= 0 or not groupAlive(group):
      return false
    result = true
    discard kill(Pid(-group), SIGTERM)
    var waited = 0
    while waited < LeftoverGraceMillis and groupAlive(group):
      sleep(20)
      waited += 20
    if groupAlive(group):
      discard kill(Pid(-group), SIGKILL)

  proc execInPlace(command: seq[string]): int =
    ## Replaces this process with `command`, environment unchanged. Returns
    ## only when the exec failed.
    stdout.flushFile()
    stderr.flushFile()
    let argv = allocCStringArray(command)
    defer: deallocCStringArray(argv)
    discard execvp(command[0].cstring, argv)
    stderr.writeLine("runquota jobserver: cannot start " & command[0] & ": " &
      $strerror(errno))
    127

# ---------------------------------------------------------------------------
# The verb
# ---------------------------------------------------------------------------

proc exitCodeOf(completion: ProcessCompletion): int =
  if completion.exited: completion.exitCode
  elif completion.signaled: 128 + completion.signal
  else: 1

proc slotsOf(lease: RunQuotaLease): int =
  ## Whole slots in a grant (a fractional grant rounds up: it was paid for).
  max(1, (int(lease.resources.cpu.value) + 999) div 1000)

proc runUnbridged(command: seq[string]): int =
  ## No daemon: run the command as given, with no jobserver.
  try:
    var child = launchProcess(commandSpec(command, stdio = inheritStdio,
      createProcessGroup = false))
    let completion = child.waitForCompletion()
    child.close()
    exitCodeOf(completion)
  except CatchableError as error:
    stderr.writeLine("runquota jobserver: cannot start " & command[0] & ": " &
      error.msg)
    127

proc hostMemoryFor(options: JobserverOptions; slots: int): uint64 =
  if options.memoryGiven: options.memoryBytes
  else: DefaultMemoryPerSlot * uint64(slots)

proc acquireBridgeLease(session: var RunQuotaSession;
                        client: var RunQuotaClient;
                        options: JobserverOptions; statsKey: string;
                        describeFailure: proc(message: string;
                          last: Diagnostic): string;
                        lease: var RunQuotaLease; error: var string): bool =
  ## A sub-lease of the inherited parent when there is a usable one, else a
  ## host lease negotiated down the same ladder as `runquota run`'s.
  let label = "jobserver " & extractFilename(options.command[0])
  let preferred = preferredWidthFor(RunOptions(minWidth: options.minWidth,
    preferredWidth: options.preferredWidth), statsKey)
  let parent = parentLeaseFromEnvironment()
  if parent.isSome and client.supportsSubLeases():
    try:
      lease = session.requestSubLeaseWaiting(parent.get(), label, statsKey,
        milliCpu(uint32(options.minWidth) * 1000'u32),
        milliCpu(uint32(preferred) * 1000'u32),
        # Inside the parent's reservation unless the caller says otherwise.
        bytes(if options.memoryGiven: options.memoryBytes else: 0'u64))
      if options.verbose:
        stderr.writeLine("runquota jobserver: sub-lease " & $lease.id.value &
          " of parent lease " & $parent.get().value)
      return true
    except RunQuotaClientError as refusal:
      if client.lastDiagnostic.code != diagInvalidArgument:
        error = describeFailure(refusal.msg, client.lastDiagnostic)
        return false
      # THE PARENT IS UNUSABLE -- stale, ended, or another user's. There is
      # nothing to wait behind, so the host is the right place to ask; a
      # leftover variable must not make the command unrunnable.
      stderr.writeLine("runquota jobserver: " & ParentLeaseEnvVar & "=" &
        $parent.get().value & " cannot be used (" & refusal.msg &
        "); taking a host lease")
  elif parent.isSome:
    stderr.writeLine("runquota jobserver: the daemon predates sub-leases; " &
      "taking a host lease although " & ParentLeaseEnvVar & " is set")
  var lastError = ""
  for width in widthLadder(preferred, options.minWidth):
    var request = resourceRequest(label,
      milliCpu(uint32(width) * 1000'u32),
      bytes(options.hostMemoryFor(width)))
    request.commandStatsId = statsKey
    try:
      lease = session.requestLeaseWaiting(request)
      return true
    except RunQuotaClientError as refusal:
      lastError = describeFailure(refusal.msg, client.lastDiagnostic)
  error = "no lease at width " & $options.minWidth & " or above: " & lastError
  false

proc runJobserver*(args: seq[string];
                   describeFailure: proc(message: string;
                     last: Diagnostic): string;
                   clientVersion: string): int =
  ## The `jobserver` verb.
  var options: JobserverOptions
  var error = ""
  if not parseJobserverArgs(args, options, error):
    stderr.writeLine("runquota jobserver: " & error)
    return 2
  var removed: seq[string] = @[]
  let command = stripWidthFlags(options.command, removed)
  if removed.len > 0 and options.verbose:
    stderr.writeLine("runquota jobserver: removed " & removed.join(" ") &
      " from the command line: an explicit width overrides the jobserver")

  when not defined(posix):
    stderr.writeLine("runquota jobserver: not available on this platform " &
      "yet (the named-semaphore jobserver has not shipped)")
    return 2
  else:
    if joinsInheritedBridge(getEnv("MAKEFLAGS"),
        getEnv(JobserverFifoEnvVar)):
      if options.verbose:
        stderr.writeLine("runquota jobserver: joining the jobserver at " &
          getEnv(JobserverFifoEnvVar))
      return execInPlace(command)

    let statsKey =
      if options.statsKey.len > 0: options.statsKey
      else: deriveStatsKey(command, getCurrentDir())

    var client: RunQuotaClient
    try:
      client = connectDefault()
    except CatchableError as failure:
      if options.verbose:
        stderr.writeLine("runquota jobserver: no daemon reached (" &
          failure.msg & "); running the command unchanged")
      return runUnbridged(command)
    defer: client.close()

    var session: RunQuotaSession
    var lease: RunQuotaLease
    try:
      session = client.registerSession("runquota jobserver", clientVersion)
      if not acquireBridgeLease(session, client, options, statsKey,
          describeFailure, lease, error):
        stderr.writeLine("runquota jobserver: " & error)
        return 1
    except RunQuotaClientError as failure:
      stderr.writeLine("runquota jobserver: " &
        describeFailure(failure.msg, client.lastDiagnostic))
      return 1

    let slots = lease.slotsOf()
    var fifo: JobserverFifo
    try:
      fifo = openJobserverFifo(tokensForSlots(slots))
    except OSError as failure:
      stderr.writeLine("runquota jobserver: " & failure.msg)
      try:
        lease.release()
        session.closeSession()
      except RunQuotaClientError:
        discard
      return 1
    defer: fifo.closeJobserverFifo()

    let makeflags = bridgeMakeflags(getEnv("MAKEFLAGS"), slots, fifo.path)
    let env = @["MAKEFLAGS=" & makeflags, "CARGO_MAKEFLAGS=" & makeflags,
      JobserverFifoEnvVar & "=" & fifo.path,
      WidthEnvVar & "=" & $slots, StatsKeyEnvVar & "=" & statsKey]
    if options.verbose:
      stderr.writeLine("runquota jobserver: lease " & $lease.id.value &
        " width " & $slots & ", " & $fifo.served & " tokens at " & fifo.path &
        ": " & command.join(" "))

    var code = 0
    var ran = false
    try:
      lease.markStarting()
      var spec = commandSpec(command, env = env, stdio = inheritStdio,
        createProcessGroup = true)
      # The bridge's whole width is out as tokens: a sub-lease of its lease
      # would count the same slots twice (see the module header).
      spec.unsetEnv = @[ParentLeaseEnvVar]
      var child: LaunchedProcess
      try:
        child = launchProcess(spec)
      except CatchableError as failure:
        lease.finish(outcome = launchFailed())
        lease.release()
        session.closeSession()
        stderr.writeLine("runquota jobserver: cannot start " & command[0] &
          ": " & failure.msg)
        return 127
      let group = Pid(child.processGroupId)
      forwardGroup = cint(group)
      installGroupForwarding()
      let handed = handTerminalTo(group)
      lease.markRunning(childProcessId = child.info.processId,
        processGroupId = child.info.processGroupId)
      let completion = child.waitForCompletion()
      if handed:
        takeTerminalBack()
      let leftovers = endLeftovers(group)
      removeGroupForwarding()
      child.close()
      let returned = fifo.drainTokens()
      if options.verbose:
        stderr.writeLine("runquota jobserver: returned " & $returned & " of " &
          $fifo.served & " tokens" &
          (if leftovers: "; ended what the command left in its group" else: ""))
      # The FIFO goes before the finish and the release, in the order the
      # specification gives: nothing may find it once the slots are back.
      fifo.closeJobserverFifo()
      lease.finish(outcome = finishOutcome(completion),
        peakMemoryBytes = completion.peakResidentMemoryBytes,
        processCount = completion.processCount,
        totals = completion.totals,
        cpuProfile = completion.cpuProfile)
      code = exitCodeOf(completion)
      ran = true
      lease.release()
      session.closeSession()
    except RunQuotaClientError as failure:
      # The command already ran (or never started); losing the daemon at the
      # end must not change its verdict.
      stderr.writeLine("runquota jobserver: " &
        describeFailure(failure.msg, client.lastDiagnostic))
      if not ran: code = 1
    code
