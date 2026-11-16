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
## ON WINDOWS the transport is a named semaphore instead, the form GNU make
## 4.4 and cargo's `jobserver` crate both use there: `--jobserver-auth=NAME`
## with no `fifo:`/`sem:` prefix, NAME created with `CreateSemaphoreA` and
## joined by a client with `OpenSemaphoreA`. A token is a unit of the
## semaphore's count; acquiring is `WaitForSingleObject` and returning is
## `ReleaseSemaphore`. A semaphore's maximum count is fixed at creation, so
## the bridge creates it with a generous ceiling and keeps its own handle open
## for the command's whole life; the semaphore is destroyed once the last
## handle (the bridge's and the command tree's) closes. The platform
## differences in leftover cleanup, terminal handling and nested joining are
## noted at the Windows procs below.
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
## A MOVING WIDTH. Against a daemon that negotiates widths, a host lease is
## one request for the range MIN..PREF, declared resizable: the daemon may
## widen it while slots are free and narrow it back towards its grant when
## other work waits. The bridge reports the width it holds every
## `ResizePollMillis` (`LeaseResized`) and follows the target in each
## answer: widening by writing the extra tokens into the FIFO at once,
## narrowing by reading tokens back as the command returns them and keeping
## them. A token a running process holds is never taken and no process is
## signalled; while a narrowing is owed the bridge waits on the FIFO, so it
## is a reader of each returned token like the tool's own.
##
## EXIT STATUS: as `runquota run` -- the command's status, 128 + N for a
## command killed by signal N, 2 for bad arguments, 1 when no lease could be
## had, 127 when the command could not be started. With no daemon answering
## the command runs unchanged, with no jobserver.
import std/[monotimes, options, os, strutils, times]
when defined(posix):
  import std/posix
when defined(windows):
  import std/winlean

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
  JobserverSemaphoreEnvVar* = "RUNQUOTA_JOBSERVER_SEMAPHORE"
    ## The Windows sibling of `JobserverFifoEnvVar`: the bridge's semaphore
    ## name. A nested `runquota jobserver` that finds it, and finds `MAKEFLAGS`
    ## still naming it, joins this jobserver instead of taking its own lease.
  DefaultMemoryPerSlot* = 512'u64 * 1024'u64 * 1024'u64
    ## What a host lease reserves per granted slot when `--mem` is not
    ## given. A nominal figure: the bridge cannot know the tool's footprint,
    ## and the daemon's learned estimate under the stats key raises it once
    ## the key has history.
  TokenByte = '+'
    ## GNU make writes `+`; clients hand back whatever byte they read, so
    ## the value only matters for being one byte.
  LeftoverGraceMillis = 2000
  ResizePollMillis* = 100
    ## How often a resizable bridge reports its width and fetches the target.
    ## RQSP is request and response, so this bounds how long a target set in
    ## an admission pass waits before the jobserver follows it. One small
    ## exchange per tenth of a second is far inside the measurement budget.
  OwedPollMillis = 5
    ## How long one wait on the FIFO lasts while a narrowing is owed, between
    ## checks on the command.
    ## How long what is left of the command's process group gets between
    ## SIGTERM and SIGKILL once the command itself has exited.

type
  JobserverOptions* = object
    minWidth*: int
    preferredWidth*: int ## 0 until resolved
    memoryBytes*: uint64 ## 0 = the default for the lease kind
    memoryGiven*: bool
    statsKey*: string
    project*: string
    entryPoint*: string
      ## Sizing declarations for the session (`--project`,
      ## `--entry-point`); empty leaves `RUNQUOTA_PROJECT` /
      ## `RUNQUOTA_ENTRY_POINT` to the client library.
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

proc bridgeMakeflagsWindows*(inherited: string; slots: int; semName: string):
    string =
  ## The Windows sibling of `bridgeMakeflags`: the inherited words that are not
  ## about jobs, then ` -j --jobserver-fds=NAME --jobserver-auth=NAME`. This is
  ## exactly what cargo's `jobserver` crate emits on Windows
  ## (`mflags_env`): a BARE `-j` with no number, both flag spellings, and the
  ## BARE semaphore name with no `fifo:`/`sem:` prefix.
  ##
  ## The `-j` carries NO number on purpose. On Windows cargo treats a numeric
  ## `-jN` as an additional hard cap, so a `-jN` equal to the grant would make
  ## the jobserver redundant and mask the token count; a bare `-j` leaves the
  ## semaphore the sole authority over parallelism, as the protocol intends and
  ## as `slots` is otherwise unused here (it stays in the signature to mirror
  ## the POSIX `bridgeMakeflags`). GNU make 4.4 reads the same spelling.
  discard slots
  var kept: seq[string] = @[]
  for word in inherited.splitWhitespace():
    if not isJobserverWord(word):
      kept.add word
  result = (if kept.len > 0: " " & kept.join(" ") else: "")
  result.add " -j --jobserver-fds=" & semName & " --jobserver-auth=" & semName

proc semaphoreNamedByMakeflags*(makeflags: string): string =
  ## The semaphore a `MAKEFLAGS` names (its last `--jobserver-auth=` word), or
  ## "". The bare name after `=`, with no `fifo:` prefix to strip -- a value
  ## that still carries the POSIX `fifo:` form is not a Windows semaphore name
  ## and is rejected, so an inherited POSIX `MAKEFLAGS` cannot be mistaken for
  ## one of ours.
  for word in makeflags.splitWhitespace():
    const prefix = "--jobserver-auth="
    if word.startsWith(prefix):
      let value = word[prefix.len .. ^1]
      result = if value.startsWith("fifo:"): "" else: value

proc joinsInheritedBridgeWindows*(makeflags, bridgeSemaphore: string): bool =
  ## The Windows sibling of `joinsInheritedBridge`: the bridge's marker names
  ## a semaphore and the `MAKEFLAGS` the tools below it pass on still names the
  ## same one. A marker alone is not enough -- a tool in between may have
  ## started its own jobserver, and then that one owns this process's implicit
  ## token.
  bridgeSemaphore.len > 0 and
    semaphoreNamedByMakeflags(makeflags) == bridgeSemaphore

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
    of "--project":
      if i + 1 >= args.len or args[i + 1].len == 0:
        error = "--project needs a value"
        return false
      options.project = args[i + 1]
      i += 2
    of "--entry-point":
      if i + 1 >= args.len or args[i + 1].len == 0:
        error = "--entry-point needs a value"
        return false
      options.entryPoint = args[i + 1]
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

  proc issueTokens*(fifo: var JobserverFifo; count: int): int =
    ## Puts `count` more tokens into circulation (widening): written at once,
    ## as the target asks. Answers how many went in.
    if count <= 0:
      return 0
    let bytes = repeat(TokenByte, count)
    let wrote = posix.write(fifo.fd, bytes.cstring, bytes.len)
    if wrote > 0:
      fifo.served += wrote
      result = wrote

  proc withholdTokens*(fifo: var JobserverFifo; count: int;
                       waitMillis = 0): int =
    ## Takes up to `count` tokens out of circulation (narrowing), from those
    ## the command has RETURNED to the FIFO: a token a running process holds
    ## is not in the FIFO and cannot be taken. With `waitMillis` > 0 the
    ## bridge first waits that long for one to come back, so it reads a
    ## returned token as promptly as the tool itself would. Answers how many
    ## it took.
    if count <= 0:
      return 0
    if waitMillis > 0:
      var pfd = TPollfd(fd: fifo.fd, events: POLLIN)
      if posix.poll(addr pfd, 1, cint(waitMillis)) <= 0:
        return 0
    var buffer: array[256, char]
    let got = posix.read(fifo.fd, addr buffer[0], min(count, buffer.len))
    if got > 0:
      fifo.served -= got
      result = got

# ---------------------------------------------------------------------------
# The semaphore (Windows)
# ---------------------------------------------------------------------------

const JobserverSemaphoreCeiling* = 1024
  ## The fixed maximum count a bridge semaphore is created with. A semaphore
  ## cannot be released past the maximum set at creation, and the jobserver
  ## has to WIDEN past its initial grant when a resizable lease is negotiated
  ## upward, so the ceiling must sit above any width a single lease could ever
  ## reach on this host. A single lease is at most the host's CPU budget, and
  ## 1024 is far above any core count a single machine grants one lease today;
  ## the cost of the headroom is nil (a semaphore reserves nothing per unit of
  ## unused count), so it is set generously rather than tuned.

when defined(windows):
  type
    JobserverSemaphore* = object
      name*: string
      handle*: Handle
      served*: int

  proc createSemaphoreA(lpAttributes: pointer; lInitialCount, lMaximumCount: int32;
                        lpName: cstring): Handle {.
    stdcall, dynlib: "kernel32", importc: "CreateSemaphoreA".}

  proc openSemaphoreA(dwDesiredAccess: uint32; bInheritHandle: WINBOOL;
                      lpName: cstring): Handle {.
    stdcall, dynlib: "kernel32", importc: "OpenSemaphoreA".}

  proc releaseSemaphore(hSemaphore: Handle; lReleaseCount: int32;
                        lpPreviousCount: ptr int32): WINBOOL {.
    stdcall, dynlib: "kernel32", importc: "ReleaseSemaphore".}

  const WaitObject0 = 0'i32
    ## `WAIT_OBJECT_0`: `waitForSingleObject` acquired the token.

  var semaphoreCounter {.global.}: int

  proc uniqueSemaphoreName(): string =
    ## A name no concurrent bridge can collide with: this process's id, a
    ## per-process counter, and the low bits of the monotonic clock. Not the
    ## `jobserver` crate's literal scheme -- only the wire FORM has to match
    ## (a bare name created with `CreateSemaphoreA`), not the name itself.
    inc semaphoreCounter
    "runquota-jobserver-" & $getCurrentProcessId() & "-" & $semaphoreCounter &
      "-" & $(getMonoTime().ticks and 0x7fffffff)

  proc openJobserverSemaphore*(tokens: int): JobserverSemaphore =
    ## A fresh named semaphore holding `tokens` available units, created with
    ## the fixed ceiling so a later widening has room, and kept open by this
    ## process (the handle keeps the semaphore alive between its clients'
    ## waits). The command opens it by name through `--jobserver-auth=`.
    result.name = uniqueSemaphoreName()
    result.handle = 0
    let initial = max(0, tokens)
    result.handle = createSemaphoreA(nil, int32(initial),
      int32(JobserverSemaphoreCeiling), result.name.cstring)
    if result.handle == 0:
      raise newException(OSError, "cannot create the jobserver semaphore: " &
        $osLastError().int)
    result.served = initial

  proc drainTokens*(sem: JobserverSemaphore): int =
    ## How many tokens are back in the semaphore. Read once the command's tree
    ## is gone: every token a process still held went with it, unreturned, so
    ## this counts only the ones handed back. Acquired without waiting and not
    ## released again -- the handle is about to close.
    while waitForSingleObject(sem.handle, 0) == WaitObject0:
      inc result

  proc closeJobserverSemaphore*(sem: var JobserverSemaphore) =
    ## Drops this process's handle. The kernel destroys the semaphore once the
    ## last handle (this one and any the command tree still holds) is gone, so
    ## no new client can open it by name afterwards. Idempotent.
    if sem.handle != 0:
      discard closeHandle(sem.handle)
      sem.handle = 0

  proc issueTokens*(sem: var JobserverSemaphore; count: int): int =
    ## Puts `count` more tokens into circulation (widening): one
    ## `ReleaseSemaphore` of `count`, which the fixed ceiling leaves room for.
    ## Answers how many went in.
    if count <= 0:
      return 0
    if releaseSemaphore(sem.handle, int32(count), nil) != 0:
      sem.served += count
      result = count

  proc withholdTokens*(sem: var JobserverSemaphore; count: int;
                       waitMillis = 0): int =
    ## Takes up to `count` tokens out of circulation (narrowing), from those
    ## the command has RETURNED: each is acquired with a non-blocking wait and
    ## simply kept, so a token a running process holds is not in the semaphore
    ## and cannot be taken. With `waitMillis` > 0 the bridge first waits that
    ## long for one to come back, reading a returned token as promptly as the
    ## tool itself would. No process is signalled. Answers how many it took.
    if count <= 0:
      return 0
    var taken = 0
    if waitMillis > 0 and
        waitForSingleObject(sem.handle, int32(waitMillis)) == WaitObject0:
      inc taken
    while taken < count and waitForSingleObject(sem.handle, 0) == WaitObject0:
      inc taken
    sem.served -= taken
    result = taken

proc slotsForTarget*(targetMilli: uint32): int =
  ## The whole slots a target asks for: never more than it allows (a token
  ## too many would run a job nothing reserved), never fewer than one (the
  ## command's own implicit token is not the bridge's to take).
  max(1, int(targetMilli div 1000'u32))

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
                        lease: var RunQuotaLease; resizable: var bool;
                        error: var string): bool =
  ## A sub-lease of the inherited parent when there is a usable one, else a
  ## host lease: one resizable request for the range when the daemon
  ## negotiates widths, otherwise negotiated down the same ladder as
  ## `runquota run`'s.
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
  if client.supportsNegotiatedWidths():
    # ONE REQUEST FOR THE RANGE, RESIZABLE: the daemon grants the widest
    # width that is free and moves it while the command runs; the ladder
    # below is for a daemon that can only grant one value whole.
    var request = resourceRequest(label,
      milliCpu(uint32(preferred) * 1000'u32),
      bytes(options.hostMemoryFor(preferred))).withWidthRange(
        milliCpu(uint32(options.minWidth) * 1000'u32),
        milliCpu(uint32(preferred) * 1000'u32), resizable = true)
    request.commandStatsId = statsKey
    try:
      lease = session.requestLeaseWaiting(request)
      resizable = true
      return true
    except RunQuotaClientError as refusal:
      error = "no lease at width " & $options.minWidth & " or above: " &
        describeFailure(refusal.msg, client.lastDiagnostic)
      return false
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

when defined(posix):
  proc followLeaseWidth(child: var LaunchedProcess; lease: var RunQuotaLease;
                        fifo: var JobserverFifo; grantedSlots: int;
                        verbose: bool) =
    ## While the command runs, keep the tokens in circulation equal to the
    ## lease's target: report the width held (`LeaseResized`) every
    ## `ResizePollMillis` and whenever it changes, and follow each answer.
    ## Widening writes the extra tokens at once; narrowing keeps tokens the
    ## command returns until the width is down to the target. Returns when
    ## the command has exited; `waitForCompletion` then reads its status.
    var target = grantedSlots
    var lastReported = -1
    var nextReport = getMonoTime()
    var daemonLost = false
    while not child.pollCompletion():
      let held = fifo.served + 1
      if held < target:
        discard fifo.issueTokens(target - held)
      elif held > target:
        discard fifo.withholdTokens(held - target, OwedPollMillis)
      let now = getMonoTime()
      let width = fifo.served + 1
      if not daemonLost and (width != lastReported or now >= nextReport):
        try:
          let answer = lease.reportResized(milliCpu(uint32(width) * 1000'u32))
          let wanted = slotsForTarget(answer.cpuTargetMilli)
          if verbose and wanted != target:
            stderr.writeLine("runquota jobserver: lease " & $lease.id.value &
              " target " & $wanted & " (holding " & $width & ")")
          target = wanted
          lastReported = width
        except RunQuotaClientError as failure:
          # The daemon went away: keep the width held, as a lease of fixed
          # width would, and let the command finish.
          daemonLost = true
          if verbose:
            stderr.writeLine("runquota jobserver: cannot report the width (" &
              failure.msg & "); keeping " & $width)
        nextReport = now + initDuration(milliseconds = ResizePollMillis)
      if fifo.served + 1 <= target:
        sleep(OwedPollMillis * 4)

when defined(windows):
  proc followLeaseWidth(child: var LaunchedProcess; lease: var RunQuotaLease;
                        sem: var JobserverSemaphore; grantedSlots: int;
                        verbose: bool) =
    ## The Windows sibling of the FIFO `followLeaseWidth`: identical loop over
    ## the semaphore. Keep the tokens in circulation equal to the lease's
    ## target, report the width held (`LeaseResized`) every `ResizePollMillis`
    ## and whenever it changes, and follow each answer -- widening releases the
    ## extra tokens at once, narrowing keeps the tokens the command returns.
    var target = grantedSlots
    var lastReported = -1
    var nextReport = getMonoTime()
    var daemonLost = false
    while not child.pollCompletion():
      let held = sem.served + 1
      if held < target:
        discard sem.issueTokens(target - held)
      elif held > target:
        discard sem.withholdTokens(held - target, OwedPollMillis)
      let now = getMonoTime()
      let width = sem.served + 1
      if not daemonLost and (width != lastReported or now >= nextReport):
        try:
          let answer = lease.reportResized(milliCpu(uint32(width) * 1000'u32))
          let wanted = slotsForTarget(answer.cpuTargetMilli)
          if verbose and wanted != target:
            stderr.writeLine("runquota jobserver: lease " & $lease.id.value &
              " target " & $wanted & " (holding " & $width & ")")
          target = wanted
          lastReported = width
        except RunQuotaClientError as failure:
          daemonLost = true
          if verbose:
            stderr.writeLine("runquota jobserver: cannot report the width (" &
              failure.msg & "); keeping " & $width)
        nextReport = now + initDuration(milliseconds = ResizePollMillis)
      if sem.served + 1 <= target:
        sleep(OwedPollMillis * 4)

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

  when defined(posix):
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
    var resizable = false
    var pressure: SingleCommandPressure
    try:
      session = client.registerSession("runquota jobserver", clientVersion,
        options.project, options.entryPoint)
      # Build-wait pressure: the queue wait, reported at the grant
      # (`pressure-reports`, off by default).
      pressure = startSingleCommandPressure()
      pressure.noteRequested()
      if not acquireBridgeLease(session, client, options, statsKey,
          describeFailure, lease, resizable, error):
        stderr.writeLine("runquota jobserver: " & error)
        return 1
      pressure.reportGranted(session)
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
      # Below admission: the tree runs in its session group's cgroup where
      # this host allows it; a bridge inside a parent lease's tree stays
      # where its parent put it (`runquota_exec.treePlacement`).
      let placement = session.treePlacement(lease, root = launcherCgroupRoot(),
        jobPriorityOn = launcherJobPriorityOn(),
        qosOn = launcherQosOn())
      spec.applyPlacement(placement)
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
      if options.verbose:
        stderr.writeLine("runquota jobserver: " &
          placement.placementNote(child.info))
      let group = Pid(child.processGroupId)
      forwardGroup = cint(group)
      installGroupForwarding()
      let handed = handTerminalTo(group)
      lease.markRunning(childProcessId = child.info.processId,
        processGroupId = child.info.processGroupId)
      if resizable:
        followLeaseWidth(child, lease, fifo, slots, options.verbose)
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
        cpuProfile = completion.cpuProfile,
        sizing = completion.finishSizing())
      code = exitCodeOf(completion)
      ran = true
      lease.release()
      pressure.reportEnded(session)
      session.closeSession()
    except RunQuotaClientError as failure:
      # The command already ran (or never started); losing the daemon at the
      # end must not change its verdict.
      stderr.writeLine("runquota jobserver: " &
        describeFailure(failure.msg, client.lastDiagnostic))
      if not ran: code = 1
    code
  elif defined(windows):
    if joinsInheritedBridgeWindows(getEnv("MAKEFLAGS"),
        getEnv(JobserverSemaphoreEnvVar)):
      if options.verbose:
        stderr.writeLine("runquota jobserver: joining the jobserver at " &
          getEnv(JobserverSemaphoreEnvVar))
      # POSIX replaces this process with the command (`execvp`) so there is no
      # extra layer; Windows has no such primitive, so the command runs as a
      # normal child and this process exits with its exact status. One more
      # process in the tree, but the OBSERVABLE behaviour is identical: no new
      # lease is taken and the inherited semaphore (named in `MAKEFLAGS`) is
      # the one used.
      return runUnbridged(command)

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
    var resizable = false
    var pressure: SingleCommandPressure
    try:
      session = client.registerSession("runquota jobserver", clientVersion,
        options.project, options.entryPoint)
      pressure = startSingleCommandPressure()
      pressure.noteRequested()
      if not acquireBridgeLease(session, client, options, statsKey,
          describeFailure, lease, resizable, error):
        stderr.writeLine("runquota jobserver: " & error)
        return 1
      pressure.reportGranted(session)
    except RunQuotaClientError as failure:
      stderr.writeLine("runquota jobserver: " &
        describeFailure(failure.msg, client.lastDiagnostic))
      return 1

    let slots = lease.slotsOf()
    var sem: JobserverSemaphore
    try:
      sem = openJobserverSemaphore(tokensForSlots(slots))
    except OSError as failure:
      stderr.writeLine("runquota jobserver: " & failure.msg)
      try:
        lease.release()
        session.closeSession()
      except RunQuotaClientError:
        discard
      return 1
    defer: sem.closeJobserverSemaphore()

    let makeflags = bridgeMakeflagsWindows(getEnv("MAKEFLAGS"), slots, sem.name)
    let env = @["MAKEFLAGS=" & makeflags, "CARGO_MAKEFLAGS=" & makeflags,
      JobserverSemaphoreEnvVar & "=" & sem.name,
      WidthEnvVar & "=" & $slots, StatsKeyEnvVar & "=" & statsKey]
    if options.verbose:
      stderr.writeLine("runquota jobserver: lease " & $lease.id.value &
        " width " & $slots & ", " & $sem.served & " tokens via semaphore " &
        sem.name & ": " & command.join(" "))

    var code = 0
    var ran = false
    try:
      lease.markStarting()
      # Windows `CreateProcess` without `CREATE_NEW_CONSOLE` /
      # `CREATE_NEW_PROCESS_GROUP` already shares the parent's console, so the
      # command reaches the terminal with no explicit handoff (the POSIX
      # `handTerminalTo` has nothing to do here). There is likewise no
      # process-group signal forwarding: Windows has no SIGTERM/SIGINT to a
      # group to forward, and a console Ctrl+C already reaches the shared
      # console's processes, so there is no reasonable equivalent to wire up.
      var spec = commandSpec(command, env = env, stdio = inheritStdio,
        createProcessGroup = false)
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
      lease.markRunning(childProcessId = child.info.processId,
        processGroupId = child.info.processGroupId)
      if resizable:
        followLeaseWidth(child, lease, sem, slots, options.verbose)
      let completion = child.waitForCompletion()
      # What the command left running in its Job Object is ended before the
      # tokens go back, as on POSIX.
      let leftovers = endJobLeftovers(child)
      child.close()
      let returned = sem.drainTokens()
      if options.verbose:
        stderr.writeLine("runquota jobserver: returned " & $returned & " of " &
          $sem.served & " tokens" &
          (if leftovers: "; ended what the command left in its job" else: ""))
      # The semaphore handle goes before the finish and the release, in the
      # order the specification gives: nothing may find it once the slots are
      # back.
      sem.closeJobserverSemaphore()
      lease.finish(outcome = finishOutcome(completion),
        peakMemoryBytes = completion.peakResidentMemoryBytes,
        processCount = completion.processCount,
        totals = completion.totals,
        cpuProfile = completion.cpuProfile,
        sizing = completion.finishSizing())
      code = exitCodeOf(completion)
      ran = true
      lease.release()
      pressure.reportEnded(session)
      session.closeSession()
    except RunQuotaClientError as failure:
      stderr.writeLine("runquota jobserver: " &
        describeFailure(failure.msg, client.lastDiagnostic))
      if not ran: code = 1
    code
  else:
    stderr.writeLine("runquota jobserver: not available on this platform " &
      "yet (the named-semaphore jobserver has not shipped)")
    return 2
