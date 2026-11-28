## `runquota nix-build-hook`: Nix daemon builds take RunQuota leases.
##
## A multi-user Nix installation builds in `nix-daemon`, outside the process
## tree of the user who asked for the build, so neither a lease nor a cgroup
## held by that user covers the build. This module plugs RunQuota into the one
## per-derivation extension point the daemon offers that can make a build
## WAIT: the build hook (`build-hook` in `nix.conf`,
## https://nix.dev/manual/nix/latest/command-ref/conf-file.html#conf-build-hook,
## the mechanism remote builders use,
## https://nix.dev/manual/nix/latest/advanced-topics/distributed-builds.html).
##
## THIS PROGRAM RUNS AS ROOT. In a multi-user installation the daemon, and
## so its build hook, runs as root, and the hook acts on data a local user
## controls: the user's environment and the derivations the user submitted.
## Every input is therefore bounded, every failure answers `# decline` (the
## build then runs as it would without the hook), and the only thing done on
## the user's behalf -- talking to `runquotad` -- is done by a separate
## process that has first become that user. See "SECURITY" below.
##
## HOW NIX DRIVES A BUILD HOOK (read from the Nix sources,
## `src/libstore/build/derivation-building-goal.cc` and
## `src/libstore/unix/build/hook-instance.cc`; the protocol is not part of
## the manual):
##
## * The daemon's per-connection worker starts the hook once per build
##   operation, in a session of its own, with its standard input a pipe from
##   the worker, standard output and error one pipe back to it, and the
##   verbosity as the last argument. It first writes every setting in force
##   for that connection, as `1, name, value` triples ended by `0` --
##   including `cores` and `max-jobs` as the CLIENT set them, since an
##   untrusted client may set both. The settings include credentials such as
##   `access-tokens`: this hook never keeps, logs or passes on any setting
##   but the four it uses (`readHookSettings`).
## * For each derivation that is ready to build, after it has taken the
##   derivation's output locks, the worker writes `"try"`, whether it would
##   build locally now (`amWilling`: fewer local builds than `max-jobs`), the
##   platform, the derivation path and the required features, and then reads
##   the hook's reply SYNCHRONOUSLY: a line `# accept`, `# decline`,
##   `# decline-permanently` or `# postpone`. A line beginning `@nix ` is a
##   structured log message, which the worker passes to the client. If the
##   hook dies before it replies the worker's read fails and so does the
##   BUILD, so the hook must answer every `try` it has read.
## * `# postpone` makes the worker drop the locks and try that derivation
##   again once `build-poll-interval` seconds have passed since it last woke
##   its waiting goals, without blocking anything else. `# decline` makes it
##   build the derivation itself, as if there were no hook (it takes the
##   locks again and waits for a local build slot if it has none).
##   `# decline-permanently` stops it asking this hook for the rest of the
##   build operation. (`# accept` would hand the build to the hook; the hook
##   could not build it locally, because the worker keeps holding the output
##   locks a local build needs.)
##
## WHAT THIS HOOK DOES WITH IT. Each derivation build gets one lease, in the
## session group of the user who requested it, for as many CPUs as the build
## will be given (`NIX_BUILD_CORES`: the connection's `cores`, or the
## machine's CPU count when that is 0, capped at the CPU count). While the
## lease is queued the hook answers `# postpone`; once it is granted it
## answers `# decline`, and the worker runs the build exactly as it would
## have without the hook. The hook never blocks the worker on the lease: a
## worker blocked in the hook stops draining its running builds' output, and
## a running build that cannot write cannot finish and return the capacity
## the blocked one is waiting for. Each `try` returns within
## `RequesterLookupMillis + ImmediateGrantMillis + ClaimConfirmMillis` plus
## the time to start a process and read the derivation.
##
## The lease is held by a separate HOLDER process per derivation
## (`runquota nix-build-hook --hold`), which:
##
## * runs as the requesting user: a root hook's holder drops to that user's
##   uid and gid, keeps no supplementary group but the endpoint's (when the
##   requester is a member of it) and checks that no privilege is left
##   before it connects, so the daemon reads the right
##   owner from peer credentials and the lease lands in that user's group,
##   never in root's;
## * gets only the RunQuota endpoint variables of the daemon's environment
##   and the requester's session variables, never the rest of either;
## * once its grant is claimed for a derivation, holds the lease for exactly
##   as long as the worker holds that derivation's output locks
##   (`/proc/locks`). The worker takes them before asking the hook, keeps
##   them for the whole build, and releases them when the build ends,
##   succeeds or fails, or when the worker dies. The holder releases the
##   lease after `ReleaseMisses` consecutive probes `ProbeMillis` apart find
##   the locks free (the worker re-takes them microseconds after the
##   `# decline`, so one free probe is not the end of the build);
## * reports the worker as the lease's child, so a holder that is killed
##   leaves the reservation in place until the worker is gone (the daemon's
##   supervisor-lost policy);
## * dies with the hook while its grant is unclaimed, so no queued request
##   outlives the build operation that made it, and leaves the hook's
##   process group, which the worker kills when that operation ends, so a
##   claimed lease is still given back after it.
##
## ON DARWIN the holder is two processes, because the release signal needs
## root there: no `/proc/locks` exists, and the kernel shows a process's
## descriptors (where the worker's output locks are) only to root or to the
## same uid. The process the hook starts stays as the hook's user and is the
## WATCHER (`watchHolder`); it forks the LEASE HOLDER, which drops to the
## requester and holds the lease exactly as above. The watcher forwards the
## claim, probes the worker's descriptors every `ProbeMillis`
## (`anyLockHeldBy`: an open descriptor on the lock file that took a
## `flock`), and after `ReleaseMisses` free probes closes the pipe to the
## lease holder, which then gives the lease back. Before the claim the
## watcher stands in for `PR_SET_PDEATHSIG`: when the hook's end of its
## standard input closes, it kills the queued lease holder; and a lease
## holder whose watcher is gone stops waiting for its grant
## (`requestLeaseWaiting`'s `cancelled`).
##
## THE REQUESTER. The worker serves one client connection. The hook is the
## worker's child; it finds the worker's accepted socket (the one that
## carries the daemon socket's name), asks the kernel for its peer and for
## the uid that created the peer socket (`sock_diag`, `UNIX_DIAG_PEER` and
## `UNIX_DIAG_UID`, https://man7.org/linux/man-pages/man7/sock_diag.7.html).
## That uid is the requester; the kernel set it when the client created its
## socket, and the client cannot choose it. The hook then looks for a
## process OF THAT UID that holds the peer end, pins it (a directory fd on
## `/proc/<pid>`, so a reused pid can never stand in for it), and reads
## `RUNQUOTA_SESSION`, `RUNQUOTA_SESSION_PRIORITY` and
## `RUNQUOTA_SESSION_CACHE_TTL` from its environment and its gid from its
## status. When no such process is found (a client in another PID
## namespace, a remote client through `nix-daemon --stdio`) the lease goes to
## the requester's `interactive` group; when the requester is unknown too,
## to the hook's own user. The RunQuota endpoint is the hook's own (the
## daemon's environment), never the client's.
##
## On darwin the same three steps use darwin's sources (`nix_hook_darwin`):
## the worker's accepted socket and its peer's pcb from the worker's
## descriptors (`proc_pidfdinfo`); the uid that created the peer socket
## from the kernel's list of local sockets (`net.local.stream.pcblist64`,
## `so_uid`); then a process of that uid holding a socket with that pcb,
## pinned by its start time read before the socket check and again after
## its environment is read (`KERN_PROCARGS2`), since darwin has no
## descriptor that pins a process.
##
## WHEN THERE IS NO RUNQUOTAD, builds still run: the hook answers
## `# decline`, says once per build operation that the builds are unadmitted,
## and tries the daemon again after `UnavailableRetryMillis`.
##
## SECURITY, in one list (each item is a rule the code below keeps):
##
## * Settings other than `cores`, `max-jobs`, `build-poll-interval` and
##   `store` are drained through a fixed scratch buffer and never become a
##   string; nothing this program writes (to the worker, to a holder, to
##   argv or to an environment) contains a setting.
## * Every length read from the worker is bounded; a string over its bound
##   is skipped, not allocated, so the stream never loses its place. A
##   stream that cannot be followed is answered `# decline-permanently`.
## * Every `try` is answered; an error deciding it answers `# decline`.
## * The environment read from a client process is that of a process whose
##   real uid is the kernel's owner of the client socket, read through a
##   pinned `/proc/<pid>` directory (darwin: a process whose start time is
##   the same before the socket check and after the read), bounded, and
##   only three variables are kept (the group name validated as a session
##   group name).
## * The privilege drop is setgroups, setgid, setuid, in that order, with
##   the group list of `holderGroupList`: the endpoint's group alone or none
##   on Linux; the gid first, then the endpoint's group, on darwin, where an
##   empty list means `{0}`. The endpoint's group is the one that owns the
##   directory of the hook's own endpoint, kept exactly when the requester
##   is a member of it (`endpointGroupFor`). Any failure stops the holder
##   before it connects; the result is checked (Linux: all four uids and
##   gids, exactly that group list, no capabilities; darwin: the real,
##   effective and saved ids and exactly that group list; and setuid(0)
##   refused); a root hook that knows the uid but not the gid drops to
##   `NoGroupGid`, never keeps root's group.
## * A holder closes every file descriptor it inherited past standard
##   input, output and error before it does anything else.
## * The darwin watcher, which keeps the hook's credential, takes input only
##   from the hook (the `claim` line, bounded) and from the kernel; it
##   writes nothing to the hook, opens no file and takes no lock, and its
##   only effect is closing the pipe to its own lease holder or killing that
##   child.
## * No file is written, and no path is created; the only files read are
##   `/proc` entries and the derivation (a regular file, bounded).
##
## PLATFORMS. The hook and its holder are POSIX code (process groups, `poll`
## on pipes, the privilege drop). The requester lookup and the release probe
## are Linux (`sock_diag`, `/proc`, `/proc/locks`) and darwin (`libproc`,
## `sysctl`, see `nix_hook_darwin`). Elsewhere on POSIX the lookup reports
## the requester unknown and the release probe reads `/proc/locks`. Where
## there is no POSIX -- Windows, which has no `nix-daemon` build hook -- only
## the portable parts are compiled (the wire format, the settings, the
## derivation, `/proc/locks` and `KERN_PROCARGS2` parsers, the session and
## credential checks), and the verb refuses, naming the platform, with a
## non-zero exit (`runNixBuildHook`).

import std/[json, monotimes, os, osproc, streams, strtabs, strutils, tables,
  times, uri]

when defined(posix):
  import std/posix

when defined(macosx):
  import nix_hook_darwin

import runquota_client
from runquota_ipc import defaultEndpoint
import runquota_core

const
  HookVerb* = "nix-build-hook"
  HoldFlag* = "--hold"
  ProbeMillis* = 100
    ## How often a holder looks at `/proc/locks` (a darwin watcher, at the
    ## worker's descriptors).
  ReleaseMisses* = 3
    ## Consecutive free probes before a holder decides the build has ended.
    ## The lease therefore outlives its build by at most
    ## `ProbeMillis * ReleaseMisses` (300 ms) plus one probe.
  ImmediateGrantMillis* = 250
    ## How long the hook waits, on the first try of a derivation, for its
    ## holder's first answer before it postpones. A free host then admits
    ## the build at once instead of one `build-poll-interval` later.
  ClaimConfirmMillis* = 250
    ## How long the hook waits for a holder to confirm a claim. A holder
    ## that does not (it gave its grant back and exited, or is wedged) is
    ## ended and the derivation is postponed, so a build never runs on a
    ## lease nobody holds.
  RequesterLookupMillis* = 200
    ## The bound on finding the client process (once per build operation).
    ## Past it the lease goes to the requester's `interactive` group.
  UnavailableRetryMillis* = 10_000
    ## After no daemon was reached, how long builds are declined unadmitted
    ## before the hook tries the daemon again.
  HolderGrantPollMillis* = 200
    ## How often a queued holder asks the daemon for its grant
    ## (`GrantNext`). A grant is used at the derivation's next `try`, which
    ## is at least a second away, so polling faster only loads the daemon.
  DefaultHookMemoryPerSlot* = 512'u64 * 1024'u64 * 1024'u64
    ## The memory reserved per CPU of a build lease (the jobserver's figure:
    ## Nix says nothing about a build's memory).
  NoGroupGid* = 65534
    ## The kernel's overflow gid (`nogroup`): what a root holder takes as its
    ## group when the requester's gid is unknown. It grants nothing. (macOS
    ## names no group 65534; a gid no group has grants nothing there too.)
  SettingNameLimit* = 256
  SettingValueLimit* = 4096
  DrvPathLimit* = 4096
  FeatureCountLimit* = 1 shl 16
  DrvFileLimit* = 16 * 1024 * 1024
    ## Bound on a derivation file read for its outputs.
  EnvironLimit* = 4 * 1024 * 1024
    ## Bound on a client's `/proc/<pid>/environ` (Linux caps the strings
    ## passed to `execve` at a quarter of the stack limit; 4 MiB is far above
    ## any real environment).
  SessionValueLimit* = 64
    ## Bound on the priority and cache-TTL values taken from a client.
  ClaimLineLimit* = 1024 * 1024
    ## Bound on one `claim` line from the hook to a darwin holder's watcher
    ## (a worker pid and one lock path per output, each path at most
    ## `DrvPathLimit` plus an output name).
  HolderLineLimit* = 4096
    ## Bound on one line from a holder to the hook.
  WatcherReapMillis* = 10_000
    ## How long a darwin watcher waits for its lease holder to give its
    ## lease back and exit before it kills it.
  SessionVars* = [SessionGroupEnvVar, SessionPriorityEnvVar,
    SessionCacheTtlEnvVar]
  HolderEndpointVars* = ["RUNQUOTA_SOCKET", "RUNQUOTA_ENDPOINT_SCOPE",
    "RUNQUOTA_ENDPOINT_OWNER_UID", "RUNQUOTA_ENDPOINT_GROUP",
    "RUNQUOTA_HANDSHAKE_TIMEOUT_MS"]
    ## The only variables of the hook's (the daemon's) environment a holder
    ## gets: the ones `connectDefault` reads to find and trust the endpoint.

# ---------------------------------------------------------------------------
# The Nix serialisation the worker writes to the hook
# ---------------------------------------------------------------------------
#
# Nix's `Sink`/`Source` format (src/libutil/serialise.cc): an integer is a
# little-endian u64; a string is its length as an integer, its bytes, and
# zero padding to a multiple of eight; a list of strings is a count and the
# strings.

proc readWireU64*(input: Stream): uint64 =
  ## One integer. Raises `EOFError` at end of input.
  var buffer: array[8, uint8]
  if input.readData(addr buffer[0], 8) != 8:
    raise newException(EOFError, "end of the worker's input")
  for i in countdown(7, 0):
    result = (result shl 8) or uint64(buffer[i])

proc wirePadding(length: uint64): int =
  int((8'u64 - length mod 8'u64) mod 8'u64)

proc drainWire(input: Stream; count: uint64) =
  ## Reads and discards `count` bytes through a fixed buffer, which is
  ## cleared afterwards: what is drained (a credential, say) never becomes a
  ## string and does not stay in memory.
  var scratch: array[4096, uint8]
  var remaining = count
  try:
    while remaining > 0'u64:
      let chunk = int(min(remaining, uint64(scratch.len)))
      if input.readData(addr scratch[0], chunk) != chunk:
        raise newException(EOFError, "end of the worker's input")
      remaining -= uint64(chunk)
  finally:
    zeroMem(addr scratch[0], scratch.len)

proc skipWireString*(input: Stream) =
  ## Skips one string, of any length, without keeping it.
  let length = input.readWireU64()
  input.drainWire(length)
  input.drainWire(uint64(wirePadding(length)))

proc readWireString*(input: Stream; value: var string; limit: int): bool =
  ## One string, into `value`, when it is at most `limit` bytes. A longer
  ## one is skipped (false, `value` empty): the stream stays in step and
  ## nothing of that size is allocated.
  let length = input.readWireU64()
  value = ""
  if length > uint64(limit):
    input.drainWire(length)
    input.drainWire(uint64(wirePadding(length)))
    return false
  value = newString(int(length))
  if length > 0 and input.readData(addr value[0], int(length)) != int(length):
    raise newException(EOFError, "end of the worker's input")
  input.drainWire(uint64(wirePadding(length)))
  true

proc wireU64*(value: uint64): string =
  ## The encoding of one integer (the tests write the worker's side).
  result = newString(8)
  for i in 0 ..< 8:
    result[i] = char((value shr (8 * i)) and 0xff)

proc wireString*(value: string): string =
  result = wireU64(uint64(value.len)) & value
  let padding = (8 - value.len mod 8) mod 8
  result.add(repeat('\0', padding))

proc wireStrings*(values: openArray[string]): string =
  result = wireU64(uint64(values.len))
  for value in values: result.add(wireString(value))

# ---------------------------------------------------------------------------
# Settings, widths and derivations
# ---------------------------------------------------------------------------

type
  HookSettings* = object
    ## The settings this hook reads from the worker's preamble; nothing else
    ## of the preamble is kept.
    cores*: int            ## `cores`; 0 means every CPU.
    maxJobs*: int          ## `max-jobs`; 0 means no local builds.
    pollIntervalSecs*: int ## `build-poll-interval`, at least 1.
    store*: string         ## `store`, to find the real store directory.

  DrvOutput* = object
    name*: string
    path*: string  ## Empty for an output whose path is not known yet.

  TryRequest* = object
    amWilling*: bool
    drvPath*: string   ## Empty when the worker sent one over `DrvPathLimit`.

proc parseNixInt(value: string; fallback, low, high: int): int =
  ## A setting's integer, clamped to `low .. high`; anything that does not
  ## parse keeps the fallback. (Nix writes `max-jobs = auto` as the CPU
  ## count already.) The clamp is what keeps a client's `cores = 10^18` from
  ## overflowing the width arithmetic below.
  try: clamp(parseInt(value.strip()), low, high)
  except ValueError: fallback

proc readHookSettings*(input: Stream): HookSettings =
  ## Reads the preamble. Only four settings are kept; every other value
  ## (credentials among them) is drained without being stored.
  result = HookSettings(cores: 0, maxJobs: 1, pollIntervalSecs: 5)
  var name, value: string
  while input.readWireU64() != 0'u64:
    if not input.readWireString(name, SettingNameLimit) or
        name notin ["cores", "max-jobs", "build-poll-interval", "store"]:
      input.skipWireString()
      continue
    if not input.readWireString(value, SettingValueLimit):
      continue
    case name
    of "cores": result.cores = parseNixInt(value, 0, 0, 1 shl 20)
    of "max-jobs": result.maxJobs = parseNixInt(value, 1, 0, 1 shl 20)
    of "build-poll-interval":
      result.pollIntervalSecs = parseNixInt(value, 5, 1, 3600)
    of "store": result.store = value
    else: discard

proc readTry*(input: Stream; request: var TryRequest): bool =
  ## The next request. False at end of input or on anything but `try`, which
  ## both mean the worker is done with the hook. Raises `ValueError` when
  ## the stream can no longer be followed (a feature list longer than
  ## `FeatureCountLimit`).
  var word: string
  try:
    if not input.readWireString(word, 16):
      return false
  except EOFError:
    return false
  if word != "try":
    return false
  request.amWilling = input.readWireU64() != 0'u64
  input.skipWireString()                       # the platform
  if not input.readWireString(request.drvPath, DrvPathLimit):
    request.drvPath = ""
  let features = input.readWireU64()
  if features > uint64(FeatureCountLimit):
    raise newException(ValueError, "list of " & $features & " features")
  for _ in 0'u64 ..< features:
    input.skipWireString()
  true

proc hostCpuCount*(): int =
  ## What Nix gives a build when `cores = 0`
  ## (`Settings::getDefaultCores`: the CPUs this process may run on).
  max(1, countProcessors())

proc leaseCpusFor*(cores, hostCpus: int): int =
  ## The lease width for a build: the `NIX_BUILD_CORES` the daemon will give
  ## it (https://nix.dev/manual/nix/latest/command-ref/conf-file.html#conf-cores),
  ## capped at the host's CPUs, which is all a build can use.
  let host = max(1, hostCpus)
  if cores <= 0 or cores > host: host else: cores

proc parseAtermString(text: string; pos: var int): string =
  ## One ATerm string literal starting at `pos` (a `"`), with Nix's escapes
  ## (`\"`, `\\`, `\n`, `\r`, `\t`).
  if pos >= text.len or text[pos] != '"':
    raise newException(ValueError, "expected a string at " & $pos)
  inc pos
  while pos < text.len:
    let c = text[pos]
    if c == '"':
      inc pos
      return
    if c == '\\':
      inc pos
      if pos >= text.len: break
      case text[pos]
      of 'n': result.add('\n')
      of 'r': result.add('\r')
      of 't': result.add('\t')
      else: result.add(text[pos])
    else:
      result.add(c)
    inc pos
  raise newException(ValueError, "unterminated string")

proc expectChar(text: string; pos: var int; c: char) =
  if pos >= text.len or text[pos] != c:
    raise newException(ValueError, "expected '" & $c & "' at " & $pos)
  inc pos

proc parseDrvOutputs*(text: string): seq[DrvOutput] =
  ## The outputs of a derivation in Nix's ATerm form
  ## (https://nix.dev/manual/nix/latest/protocols/derivation-aterm.html):
  ## `Derive([("out","/nix/store/…","",""),…],…` or the versioned
  ## `DrvWithVersion("xp-dyn-drv",[…],…`.
  var pos = 0
  if text.startsWith("Derive("):
    pos = "Derive(".len
  elif text.startsWith("DrvWithVersion("):
    pos = "DrvWithVersion(".len
    discard parseAtermString(text, pos)
    expectChar(text, pos, ',')
  else:
    raise newException(ValueError, "not a derivation")
  expectChar(text, pos, '[')
  while pos < text.len and text[pos] != ']':
    if text[pos] == ',': inc pos
    expectChar(text, pos, '(')
    var output = DrvOutput(name: parseAtermString(text, pos))
    expectChar(text, pos, ',')
    output.path = parseAtermString(text, pos)
    expectChar(text, pos, ',')
    discard parseAtermString(text, pos)
    expectChar(text, pos, ',')
    discard parseAtermString(text, pos)
    expectChar(text, pos, ')')
    result.add(output)
  expectChar(text, pos, ']')

proc storeUriParam(store, key: string): string =
  ## A `key=value` parameter of a store URI (`local?root=/x`), or "".
  let query = store.find('?')
  if query < 0: return ""
  for part in store[query + 1 .. ^1].split('&'):
    let eq = part.find('=')
    if eq > 0 and part[0 ..< eq] == key:
      return decodeUrl(part[eq + 1 .. ^1])
  ""

proc realStorePath*(logicalPath, store: string): string =
  ## Where a store path is on disk (`LocalFSStore::toRealPath`): under
  ## `real=` when the store names one, under `root=` + the store directory
  ## when it is a chroot store, and the logical path otherwise.
  let real = storeUriParam(store, "real")
  if real.len > 0:
    return real / extractFilename(logicalPath)
  let root = storeUriParam(store, "root")
  if root.len > 0:
    return root & logicalPath
  logicalPath

proc outputLockPaths*(drvPath: string; outputs: openArray[DrvOutput];
                      store: string): seq[string] =
  ## The files the worker locks before it builds a derivation
  ## (`DerivationBuildingGoal::tryToBuild`'s `lockFiles` and
  ## `PathLocks::lockPaths`, which adds `.lock`): `<real output>.lock` for
  ## an output whose path is known, `<real drv>.<output>.lock` otherwise.
  for output in outputs:
    if output.path.len > 0:
      result.add(realStorePath(output.path, store) & ".lock")
    else:
      result.add(realStorePath(drvPath, store) & "." & output.name & ".lock")

when defined(posix):
  proc readRegularFile*(path: string; limit: int): string =
    ## A regular file of at most `limit` bytes. Anything else (a FIFO that
    ## would block, a device, a larger file) raises `IOError`.
    let fd = posix.open(path.cstring, O_RDONLY or O_CLOEXEC or O_NONBLOCK)
    if fd < 0:
      raise newException(IOError, "cannot open " & path & ": " &
        osErrorMsg(osLastError()))
    defer: discard posix.close(fd)
    var info: Stat
    if fstat(fd, info) != 0 or not S_ISREG(info.st_mode):
      raise newException(IOError, path & " is not a regular file")
    if info.st_size > Off(limit):
      raise newException(IOError, path & " is larger than " & $limit & " bytes")
    result = newString(int(info.st_size))
    var got = 0
    while got < result.len:
      let n = posix.read(fd, addr result[got], result.len - got)
      if n <= 0: break
      got += n
    result.setLen(got)

# ---------------------------------------------------------------------------
# /proc/locks
# ---------------------------------------------------------------------------

type
  ProcLock* = object
    kind*: string   ## `FLOCK`, `POSIX`, `OFDLCK`, ...
    pid*: int
    major*, minor*: uint64
    inode*: uint64

proc parseProcLocks*(text: string): seq[ProcLock] =
  ## Lines such as `1: FLOCK  ADVISORY  WRITE 3708106 00:2c:859165123 0 EOF`
  ## (https://man7.org/linux/man-pages/man5/proc_locks.5.html). A blocked
  ## waiter's line carries `->` after the number and is skipped: it holds
  ## nothing. Malformed lines are skipped.
  for line in text.splitLines():
    let fields = line.splitWhitespace()
    if fields.len < 6 or fields[1] == "->":
      continue
    let device = fields[5].split(':')
    if device.len != 3: continue
    try:
      result.add(ProcLock(kind: fields[1], pid: parseInt(fields[4]),
        major: fromHex[uint64](device[0]), minor: fromHex[uint64](device[1]),
        inode: parseBiggestUInt(device[2])))
    except ValueError:
      discard

when defined(posix):
  proc deviceMajor(dev: Dev): uint64 =
    ## glibc's `major()` for a 64-bit `dev_t`.
    let d = uint64(dev)
    ((d shr 32) and 0xfffff000'u64) or ((d shr 8) and 0x00000fff'u64)

  proc deviceMinor(dev: Dev): uint64 =
    let d = uint64(dev)
    ((d shr 12) and 0xffffff00'u64) or (d and 0x000000ff'u64)

  proc lockHeldBy*(locks: openArray[ProcLock]; path: string; pid: int): bool =
    ## Whether `pid` holds a lock on the file now at `path`.
    var info: Stat
    if stat(path.cstring, info) != 0:
      return false
    let major = deviceMajor(info.st_dev)
    let minor = deviceMinor(info.st_dev)
    for lock in locks:
      if lock.pid == pid and lock.inode == uint64(info.st_ino) and
          lock.major == major and lock.minor == minor:
        return true
    false

  when defined(macosx):
    proc lockProbe*(paths: openArray[string]; pid: int): int =
      ## Darwin: whether `pid` holds Nix's lock on one of `paths`: 1 held,
      ## 0 free, -1 its descriptors could not all be read. Darwin has no
      ## `/proc/locks`; the kernel's list of `pid`'s descriptors says which
      ## files it has open and whether a `flock` was taken through each
      ## (`fileLockProbe`). Reading another uid's list needs root, which
      ## only the watcher of a root hook has.
      var files: seq[(uint64, uint64)] = @[]
      for path in paths:
        var info: Stat
        if stat(path.cstring, info) == 0:
          files.add((uint64(cast[uint32](info.st_dev)), uint64(info.st_ino)))
      fileLockProbe(pid, files)

  proc anyLockHeldBy*(paths: openArray[string]; pid: int): bool =
    ## Whether the process `pid` holds Nix's lock on one of `paths` (a
    ## `flock(2)` on the file now at that path). Never takes, tests or
    ## opens the lock itself: a probe that took it, even for an instant,
    ## could make the worker's own non-blocking `flock` fail.
    when defined(macosx):
      lockProbe(paths, pid) == 1
    else:
      var text = ""
      try:
        text = readFile("/proc/locks")
      except IOError:
        return false
      let locks = parseProcLocks(text)
      for path in paths:
        if locks.lockHeldBy(path, pid):
          return true
      false

# ---------------------------------------------------------------------------
# The requester
# ---------------------------------------------------------------------------

type
  Requester* = object
    ## Who asked the daemon for this build, as far as the hook can tell.
    uid*: int          ## -1 when unknown.
    gid*: int          ## -1 when unknown.
    pid*: int          ## 0 when the client process was not found.
    group*: string     ## `RUNQUOTA_SESSION` of the client, or "".
    priority*: string
    cacheTtl*: string
    how*: string       ## How it was found, for the log.

proc parseEnviron*(data: string): Table[string, string] =
  ## `/proc/<pid>/environ`: NUL-separated `NAME=value` entries.
  for entry in data.split('\0'):
    let eq = entry.find('=')
    if eq > 0:
      result[entry[0 ..< eq]] = entry[eq + 1 .. ^1]

proc parseProcArgs2*(data: string): tuple[argv, env: seq[string]] =
  ## Darwin's `KERN_PROCARGS2` block: `argc` as a native 32-bit integer,
  ## the executable path, NUL padding, then `argc` NUL-terminated arguments
  ## and the environment strings, ended by an empty string (anything after
  ## it -- the `apple[]` strings -- is not environment). This is the layout
  ## `exec_copyout_strings` writes (XNU `bsd/kern/kern_exec.c`) and
  ## `sysctl_procargsx` returns; `ps -E` reads it the same way. Malformed
  ## or truncated input yields what could be read.
  if data.len < 4:
    return
  var argc = 0
  for i in countdown(3, 0):
    argc = (argc shl 8) or int(uint8(data[i]))
  if argc < 0 or argc > data.len:
    return
  var pos = 4
  # The executable path, then its NUL padding.
  while pos < data.len and data[pos] != '\0': inc pos
  while pos < data.len and data[pos] == '\0': inc pos
  proc next(data: string; pos: var int): string =
    let start = pos
    while pos < data.len and data[pos] != '\0': inc pos
    result = data[start ..< pos]
    if pos < data.len: inc pos   # the NUL
  while result.argv.len < argc and pos < data.len:
    result.argv.add(next(data, pos))
  while pos < data.len:
    let entry = next(data, pos)
    if entry.len == 0: break
    result.env.add(entry)

proc sessionFromEnviron*(requester: var Requester; data: string) =
  ## The session variables of a client's environment, validated: a group
  ## that is not a valid session group name is dropped (with its priority
  ## and TTL), and so is an over-long priority or TTL, so a client cannot
  ## make its builds' leases fail -- and so run unadmitted -- by naming a
  ## group the daemon would refuse.
  let env = parseEnviron(data)
  let group = env.getOrDefault(SessionGroupEnvVar)
  if group.len == 0:
    return
  let problem = sessionGroupNameProblem(group)
  if problem.len > 0:
    requester.how.add("; its " & SessionGroupEnvVar & " is ignored (" &
      problem & ")")
    return
  requester.group = group
  let priority = env.getOrDefault(SessionPriorityEnvVar)
  if priority.len <= SessionValueLimit: requester.priority = priority
  let ttl = env.getOrDefault(SessionCacheTtlEnvVar)
  if ttl.len <= SessionValueLimit: requester.cacheTtl = ttl

proc parseStatusIds*(status: string; uid, gid: var int): bool =
  ## The real uid and gid from `/proc/<pid>/status`.
  var found = 0
  for line in status.splitLines():
    if line.startsWith("Uid:") or line.startsWith("Gid:"):
      let fields = line.splitWhitespace()
      if fields.len >= 2:
        try:
          let value = parseInt(fields[1])
          if line.startsWith("Uid:"): uid = value else: gid = value
          inc found
        except ValueError:
          discard
  found == 2

proc socketInode*(link: string): uint64 =
  ## The inode of a `socket:[N]` fd link, or 0.
  if link.startsWith("socket:[") and link.endsWith("]"):
    try:
      return parseBiggestUInt(link["socket:[".len ..< link.len - 1])
    except ValueError:
      discard
  0

when defined(linux):
  var
    ODirectory {.importc: "O_DIRECTORY", header: "<fcntl.h>".}: cint
    MsgDontWait {.importc: "MSG_DONTWAIT", header: "<sys/socket.h>".}: cint

  proc openatCall(dirfd: cint; path: cstring; flags: cint): cint {.
    importc: "openat", header: "<fcntl.h>", varargs.}
  proc readlinkatCall(dirfd: cint; path: cstring; buf: cstring;
                      size: csize_t): int {.
    importc: "readlinkat", header: "<unistd.h>".}
  proc fdopendirCall(fd: cint): ptr DIR {.
    importc: "fdopendir", header: "<dirent.h>".}

  proc readBoundedAt(dirFd: cint; name: string; limit: int): string =
    ## A `/proc/<pid>` entry read through the pinned directory `dirFd`, at
    ## most `limit` bytes. Raises `IOError` once the process is gone.
    let fd = openatCall(dirFd, name.cstring, O_RDONLY or O_CLOEXEC)
    if fd < 0:
      raise newException(IOError, "cannot open " & name & ": " &
        osErrorMsg(osLastError()))
    defer: discard posix.close(fd)
    var chunk = newString(65536)
    while result.len < limit:
      let n = posix.read(fd, addr chunk[0], min(chunk.len, limit - result.len))
      if n < 0:
        raise newException(IOError, "cannot read " & name & ": " &
          osErrorMsg(osLastError()))
      if n == 0: break
      result.add(chunk[0 ..< n])

  proc holdsSocketAt(dirFd: cint; wanted: string): bool =
    ## Whether the pinned process has an fd on the socket `wanted`
    ## (`socket:[N]`).
    let fdDir = openatCall(dirFd, "fd", O_RDONLY or O_CLOEXEC or ODirectory)
    if fdDir < 0:
      return false
    let dir = fdopendirCall(fdDir)
    if dir == nil:
      discard posix.close(fdDir)
      return false
    defer: discard closedir(dir)
    var link = newString(64)
    while true:
      let entry = readdir(dir)
      if entry == nil: break
      let name = $cast[cstring](addr entry.d_name[0])
      if name.len == 0 or name[0] == '.': continue
      let n = readlinkatCall(fdDir, name.cstring, link.cstring,
        csize_t(link.len))
      if n == wanted.len and link[0 ..< n] == wanted:
        return true
    false

  proc requesterAt(dirFd: cint; pid, uid: int): Requester =
    ## The client process pinned by `dirFd`, already known to hold the
    ## client end and to be owned by `uid`. Its environment is read only
    ## when its real uid is `uid` as well.
    result = Requester(uid: uid, gid: -1, pid: pid,
      how: "client pid " & $pid)
    try:
      var realUid, realGid = -1
      if not parseStatusIds(readBoundedAt(dirFd, "status", 65536),
          realUid, realGid) or realUid != uid:
        result.how.add(" does not run as uid " & $uid &
          "; its environment is not read")
        return
      result.gid = realGid
      result.sessionFromEnviron(readBoundedAt(dirFd, "environ", EnvironLimit))
    except IOError, OSError:
      result.how.add("; it exited before its environment was read")

  type
    UnixSocketInfo = object
      found: bool
      name: string
      peer: uint64
      uid: int

  proc netlinkU32(buffer: var string; value: uint32) =
    for i in 0 ..< 4: buffer.add(char((value shr (8 * i)) and 0xff))

  proc netlinkU16(buffer: var string; value: uint16) =
    for i in 0 ..< 2: buffer.add(char((value shr (8 * i)) and 0xff))

  proc readU32(data: string; at: int): uint32 =
    for i in countdown(3, 0):
      result = (result shl 8) or uint32(uint8(data[at + i]))

  proc readU16(data: string; at: int): uint16 =
    uint16(uint8(data[at])) or (uint16(uint8(data[at + 1])) shl 8)

  proc unixSocketInfo(inode: uint64): UnixSocketInfo =
    ## One AF_UNIX socket's bound name, peer inode and owner uid (the uid
    ## that created it), from the kernel (`sock_diag(7)`, an exact
    ## `SOCK_DIAG_BY_FAMILY` request). Never blocks: the kernel answers
    ## within `sendto`, and the read does not wait.
    const
      AfNetlink = cint(16)
      NetlinkSockDiag = cint(4)
      SockDiagByFamily = 20'u16
      NlmFRequest = 1'u16
      NlmsgError = 2'u16
      ShowName = 0x1'u32
      ShowPeer = 0x4'u32
      ShowUid = 0x40'u32
      AttrName = 0'u16
      AttrPeer = 2'u16
      AttrUid = 7'u16
      HeaderLen = 16 + 16   # nlmsghdr + unix_diag_msg
    result.uid = -1
    if inode == 0 or inode > uint64(high(uint32)):
      return
    let fd = socket(AfNetlink, SOCK_DGRAM or SOCK_CLOEXEC, NetlinkSockDiag)
    if cint(fd) < 0:
      return
    defer: discard posix.close(cint(fd))
    var request = ""
    request.netlinkU32(16 + 24)              # nlmsg_len
    request.netlinkU16(SockDiagByFamily)     # nlmsg_type
    request.netlinkU16(NlmFRequest)          # nlmsg_flags
    request.netlinkU32(1)                    # nlmsg_seq
    request.netlinkU32(0)                    # nlmsg_pid
    request.add(char(AF_UNIX))               # sdiag_family
    request.add('\0')                        # sdiag_protocol
    request.netlinkU16(0)                    # pad
    request.netlinkU32(0xffffffff'u32)       # udiag_states: all
    request.netlinkU32(uint32(inode))        # udiag_ino
    request.netlinkU32(ShowName or ShowPeer or ShowUid)
    request.netlinkU32(0xffffffff'u32)       # cookie: none
    request.netlinkU32(0xffffffff'u32)
    var kernel: Sockaddr_storage
    zeroMem(addr kernel, sizeof(kernel))
    cast[ptr uint16](addr kernel)[] = uint16(AfNetlink)
    if sendto(fd, addr request[0], request.len, 0,
        cast[ptr SockAddr](addr kernel), SockLen(12)) != request.len:
      return
    var reply = newString(8192)
    let got = recv(fd, addr reply[0], reply.len, MsgDontWait)
    if got < HeaderLen:
      return
    reply.setLen(got)
    let messageLen = int(readU32(reply, 0))
    let messageType = readU16(reply, 4)
    if messageType == NlmsgError or messageType != SockDiagByFamily or
        messageLen > got or messageLen < HeaderLen:
      return
    if uint64(readU32(reply, 16 + 4)) != inode:
      return
    result.found = true
    var at = HeaderLen
    while at + 4 <= messageLen:
      let attrLen = int(readU16(reply, at))
      let attrType = readU16(reply, at + 2)
      if attrLen < 4 or at + attrLen > messageLen: break
      let payload = reply[at + 4 ..< at + attrLen]
      case attrType
      of AttrName: result.name = payload.strip(leading = false, chars = {'\0'})
      of AttrPeer:
        if payload.len >= 4: result.peer = uint64(readU32(payload, 0))
      of AttrUid:
        if payload.len >= 4: result.uid = int(readU32(payload, 0))
      else: discard
      at += (attrLen + 3) and not 3

  proc socketInodesOf(pid: int): seq[uint64] =
    try:
      for kind, path in walkDir("/proc" / $pid / "fd"):
        try:
          let inode = socketInode(expandSymlink(path))
          if inode != 0: result.add(inode)
        except OSError:
          discard
    except OSError:
      discard

  proc findRequester*(workerPid: int;
                      budgetMillis = RequesterLookupMillis): Requester =
    ## The client of the daemon worker `workerPid` (see the module header).
    ## Returns within about `budgetMillis`.
    let deadline = getMonoTime() + initDuration(milliseconds = budgetMillis)
    result = Requester(uid: -1, gid: -1, how: "the client was not found")
    var accepted: seq[UnixSocketInfo] = @[]
    for inode in socketInodesOf(workerPid):
      let info = unixSocketInfo(inode)
      # The accepted connection carries the listening socket's name, a
      # filesystem path; the worker's other sockets (to a helper, or one an
      # LD_PRELOAD library opened on an abstract name) carry none, or an
      # abstract one (a leading NUL).
      if info.found and info.name.startsWith("/") and info.peer != 0:
        accepted.add(info)
    if accepted.len > 1:
      # More than one listening name: keep the daemon's own socket.
      let daemonSocket = getEnv("NIX_DAEMON_SOCKET_PATH",
        "/nix/var/nix/daemon-socket/socket")
      var named: seq[UnixSocketInfo] = @[]
      for info in accepted:
        if info.name == daemonSocket: named.add(info)
      accepted = named
    if accepted.len != 1:
      result.how = "the worker has " & $accepted.len &
        " named client connections"
      return
    # THE REQUESTER IS THE KERNEL'S OWNER OF THE CLIENT'S SOCKET: the uid
    # that created it (`sock_init_data`, net/core/sock.c). The worker's end
    # says nothing about the client (the kernel creates it for the
    # connection, owned by the network namespace's root), so it is the
    # peer that is asked. A client in another network namespace is not
    # found here (sock_diag looks in the hook's own).
    let clientEnd = unixSocketInfo(accepted[0].peer)
    if not clientEnd.found or clientEnd.uid < 0:
      result.how = "the client end of the connection was not found"
      return
    result.uid = clientEnd.uid
    let wanted = "socket:[" & $accepted[0].peer & "]"
    let me = getCurrentProcessId()
    # /proc lists pids in ascending order, so the first holder found is
    # the lowest pid: the client before any child it forked.
    for kind, dir in walkDir("/proc"):
      if getMonoTime() > deadline:
        result.how = "no client process found within " & $budgetMillis &
          " ms"
        return
      let name = extractFilename(dir)
      if name.len == 0 or not name[0].isDigit: continue
      var pid = 0
      try: pid = parseInt(name)
      except ValueError: continue
      if pid == workerPid or pid == me: continue
      # PINNED: every later read goes through this directory fd, which
      # refers to this process and no other; if it exits, the reads fail
      # rather than reach a process that reused its pid.
      let dirFd = posix.open(dir.cstring,
        O_RDONLY or O_CLOEXEC or ODirectory)
      if dirFd < 0: continue
      try:
        var info: Stat
        if fstat(dirFd, info) != 0 or int(info.st_uid) != result.uid:
          continue
        if not holdsSocketAt(dirFd, wanted):
          continue
        return requesterAt(dirFd, pid, result.uid)
      finally:
        discard posix.close(dirFd)
    result.how = "no process of uid " & $result.uid &
      " holds the client end (another PID namespace?)"
elif defined(macosx):
  proc requesterOfProcess(pid: int; before: ProcessIdentity;
                          uid: int): Requester =
    ## The client process `pid`, seen as `before` and since found holding
    ## the client end. Its environment and gid are kept only when it runs
    ## as `uid` and is STILL THE SAME PROCESS after the read: darwin has no
    ## descriptor that pins a process, so the pin is its start time read
    ## before the socket check and again after the environment (a pid is
    ## reused only once its process is gone, and the new one starts later).
    result = Requester(uid: uid, gid: -1, pid: pid,
      how: "client pid " & $pid)
    if before.ruid != uid:
      result.how.add(" does not run as uid " & $uid &
        "; its environment is not read")
      return
    var environ = ""
    try:
      environ = parseProcArgs2(procArgs(pid, EnvironLimit)).env.join("\0")
    except IOError:
      result.how.add("; its environment could not be read")
      return
    var after: ProcessIdentity
    if not processIdentity(pid, after) or not sameProcess(before, after) or
        after.ruid != uid:
      result.how.add("; it exited before its environment was read")
      return
    result.gid = before.rgid
    result.sessionFromEnviron(environ)

  proc findRequester*(workerPid: int;
                      budgetMillis = RequesterLookupMillis): Requester =
    ## The client of the daemon worker `workerPid` on darwin (see the
    ## module header): the worker's accepted socket from its descriptors,
    ## the uid that created the client's end from the kernel's socket list,
    ## then a process of that uid holding the client's end. Returns within
    ## about `budgetMillis`.
    let deadline = getMonoTime() + initDuration(milliseconds = budgetMillis)
    result = Requester(uid: -1, gid: -1, how: "the client was not found")
    var accepted: seq[UnixSocketEnd] = @[]
    for socket in unixSocketsOf(workerPid):
      # The accepted connection carries the listening socket's path (XNU
      # copies it, `unp_connect`); a listening socket the worker inherited
      # carries it too but has no peer.
      if socket.path.startsWith("/") and socket.conn != 0:
        accepted.add(socket)
    if accepted.len > 1:
      let daemonSocket = getEnv("NIX_DAEMON_SOCKET_PATH",
        "/nix/var/nix/daemon-socket/socket")
      var named: seq[UnixSocketEnd] = @[]
      for socket in accepted:
        if socket.path == daemonSocket: named.add(socket)
      accepted = named
    if accepted.len != 1:
      result.how = "the worker has " & $accepted.len &
        " named client connections"
      return
    # THE REQUESTER IS THE KERNEL'S OWNER OF THE CLIENT'S SOCKET: the uid of
    # the credential that created it, which the client cannot choose.
    let clientEnd = accepted[0].conn
    var uid = -1
    case socketOwner(clientEnd, accepted[0].pcb, uid)
    of 1:
      # The connection is still the one the owner was read for: a client
      # end that closed and was replaced at the same address in between
      # would show a different peer here.
      var still = false
      for socket in unixSocketsOf(workerPid):
        if socket.pcb == accepted[0].pcb and socket.conn == clientEnd:
          still = true
      if not still:
        result.how = "the client connection changed during the lookup"
        return
      result.uid = uid
    of 0:
      result.how = "the client end of the connection was not found"
      return
    else:
      result.how = "the kernel's list of local sockets could not be read"
      return
    let me = getCurrentProcessId()
    # Ascending, so the first holder found is the lowest pid: the client
    # before any child it forked (pids wrap, so this is a preference only).
    for pid in allPids():
      if getMonoTime() > deadline:
        result.how = "no client process found within " & $budgetMillis &
          " ms"
        return
      if pid == workerPid or pid == me: continue
      var before: ProcessIdentity
      if not processIdentity(pid, before) or before.uid != result.uid:
        continue
      if not holdsSocket(pid, clientEnd):
        continue
      return requesterOfProcess(pid, before, result.uid)
    result.how = "no process of uid " & $result.uid & " holds the client end"
else:
  proc findRequester*(workerPid: int;
                      budgetMillis = RequesterLookupMillis): Requester =
    Requester(uid: -1, gid: -1,
      how: "requester lookup is Linux and darwin only")

# ---------------------------------------------------------------------------
# Messages to the client
# ---------------------------------------------------------------------------

proc nixLogLine*(message: string; level = 1): string =
  ## A structured log message the worker forwards to the client
  ## (`handleJSONLogMessage`, the `@nix` prefix of Nix's internal JSON log
  ## format; level 1 is a warning, 0 an error). JSON keeps it on one line,
  ## so nothing in `message` can pose as a `# ` reply.
  "@nix " & $(%*{"action": "msg", "level": level, "msg": message})

# ---------------------------------------------------------------------------
# The privilege drop
# ---------------------------------------------------------------------------

type
  PrivilegeDropError* = object of CatchableError

  CredentialOps* = object
    ## The system calls of the privilege drop, injectable so the order, the
    ## failure paths and the checks can be tested without root.
    euid*: proc (): int
    setGroups*: proc (groups: seq[int]): cint
      ## `setgroups(2)` with exactly `groups` (`holderGroupList`).
    setGid*: proc (gid: int): cint     ## setgid(2): real, effective, saved
    setUid*: proc (uid: int): cint     ## setuid(2): real, effective, saved
    status*: proc (): string
      ## The kernel's view of this process's credential: `/proc/self/status`
      ## on Linux, `darwinCredentialStatus` on darwin.

when defined(macosx):
  proc darwinCredentialStatus*(): string =
    ## This process's credential as the kernel holds it (`KERN_PROC_PID`),
    ## in the shape of the `/proc/self/status` lines it stands in for:
    ## `Uid:` real, effective, saved; `Gid:` the same; `Groups:` the
    ## kernel's group list. Darwin has no filesystem ids and no capability
    ## sets. Raises `OSError` when the kernel does not answer.
    var credential: SelfCredential
    if not selfCredential(credential):
      raise newException(OSError,
        "the kernel did not report this process's credential")
    result = "Uid:\t" & $credential.ruid & "\t" & $credential.euid & "\t" &
      $credential.svuid & "\nGid:\t" & $credential.rgid & "\t" &
      $credential.egid & "\t" & $credential.svgid & "\nGroups:\t"
    for i, group in credential.groups:
      if i > 0: result.add(' ')
      result.add($group)
    result.add('\n')

when defined(posix):
  proc setgroupsCall(size: csize_t; list: ptr Gid): cint {.
    importc: "setgroups", header: "<grp.h>".}

  proc systemCredentialOps*(): CredentialOps =
    CredentialOps(
      euid: proc (): int = int(geteuid()),
      setGroups: proc (groups: seq[int]): cint =
        var list = newSeq[Gid](groups.len)
        for i, group in groups: list[i] = Gid(group)
        if list.len == 0: setgroupsCall(0, nil)
        else: setgroupsCall(csize_t(list.len), addr list[0]),
      setGid: proc (gid: int): cint = setgid(Gid(gid)),
      setUid: proc (uid: int): cint = setuid(Uid(uid)),
      status: proc (): string =
        when defined(macosx): darwinCredentialStatus()
        else: readFile("/proc/self/status"))

proc holderGroupList*(gid, endpointGroup: int; darwin: bool): seq[int] =
  ## The group list a dropped holder gets (Build-Engine § Nix daemon builds
  ## under leases, "The endpoint's group"): the endpoint's group when there
  ## is one (`endpointGroup >= 0`; see `endpointGroupFor`), and on darwin
  ## the requester's gid first. Linux: empty, or the endpoint's group
  ## alone. Darwin: `[gid]` or `[gid, endpoint group]`, because XNU turns an
  ## empty list into `{0}` -- the group `wheel` (`setgroups_internal`,
  ## `bsd/kern/kern_prot.c`: `if (ngrp < 1) { ngrp = 1; newgroups[0] = 0;
  ## }`) -- and keeps the effective gid as the list's first entry. On darwin
  ## `setgroups` also opts the process out of directory-service group
  ## resolution (`CRF_NOMEMBERD`, `kauth_cred_model_setgroups` in
  ## `bsd/kern/kern_credential.c`), which `setuid` then leaves off.
  if darwin: result.add(gid)
  if endpointGroup >= 0 and endpointGroup != gid:
    result.add(endpointGroup)

proc sameGroups(fields: seq[string]; want: seq[int]): bool =
  ## Whether a status line's groups are exactly `want`, as sets (Linux
  ## lists them sorted, darwin in the order they were set).
  if fields.len != want.len: return false
  for group in want:
    if $group notin fields: return false
  true

proc darwinCredentialProblem*(status: string; uid, gid: int;
                              endpointGroup = -1): string =
  ## What in a `darwinCredentialStatus` shows a drop to `uid`/`gid`
  ## incomplete, or "": the real, effective and saved uids and gids are
  ## the target and the group list is exactly `holderGroupList` (the
  ## effective gid first, then the endpoint's group when there is one).
  var seen: seq[string] = @[]
  for line in status.splitLines():
    let colon = line.find(':')
    if colon <= 0: continue
    let key = line[0 ..< colon]
    let fields = line[colon + 1 .. ^1].splitWhitespace()
    case key
    of "Uid", "Gid":
      let want = if key == "Uid": uid else: gid
      if fields.len != 3: return key & " has " & $fields.len & " fields"
      for field in fields:
        if field != $want: return key & " is " & fields.join(" ")
      seen.add(key)
    of "Groups":
      let want = holderGroupList(gid, endpointGroup, darwin = true)
      if fields.len == 0 or fields[0] != $gid or not sameGroups(fields, want):
        return "supplementary groups " & fields.join(" ")
      seen.add(key)
    else: discard
  for key in ["Uid", "Gid", "Groups"]:
    if key notin seen: return key & " is missing"
  ""

proc linuxCredentialProblem*(status: string; uid, gid: int;
                             endpointGroup = -1): string =
  ## What in `/proc/self/status` shows a drop to `uid`/`gid` incomplete, or
  ## "": every one of the real, effective, saved and filesystem uids and
  ## gids is the target, the supplementary groups are exactly
  ## `holderGroupList` (none, or the endpoint's group), and the permitted,
  ## effective and ambient capability sets are empty.
  var seen: seq[string] = @[]
  for line in status.splitLines():
    let colon = line.find(':')
    if colon <= 0: continue
    let key = line[0 ..< colon]
    let fields = line[colon + 1 .. ^1].splitWhitespace()
    case key
    of "Uid", "Gid":
      let want = if key == "Uid": uid else: gid
      if fields.len != 4: return key & " has " & $fields.len & " fields"
      for field in fields:
        if field != $want: return key & " is " & fields.join(" ")
      seen.add(key)
    of "Groups":
      if not sameGroups(fields, holderGroupList(gid, endpointGroup,
          darwin = false)):
        return "supplementary groups " & fields.join(" ")
      seen.add(key)
    of "CapPrm", "CapEff", "CapAmb":
      if fields.len != 1: return key & " is malformed"
      try:
        if fromHex[uint64](fields[0]) != 0'u64:
          return key & " is " & fields[0]
      except ValueError:
        return key & " is malformed"
      seen.add(key)
    else: discard
  for key in ["Uid", "Gid", "Groups", "CapPrm", "CapEff", "CapAmb"]:
    if key notin seen: return key & " is missing"
  ""

proc credentialProblem*(status: string; uid, gid: int;
                        endpointGroup = -1): string =
  ## The platform's check of `CredentialOps.status` after a drop: Linux's
  ## (`linuxCredentialProblem`) everywhere but darwin.
  when defined(macosx):
    darwinCredentialProblem(status, uid, gid, endpointGroup)
  else:
    linuxCredentialProblem(status, uid, gid, endpointGroup)

proc dropPrivilegesWith*(ops: CredentialOps; uid, gid: int;
                         endpointGroup = -1): string =
  ## Become `uid`/`gid` when running as root and the requester is someone
  ## else, keeping `endpointGroup` (-1: none) as the only supplementary
  ## group (`holderGroupList`). Returns what happened, for the log. Raises
  ## `PrivilegeDropError` -- and the caller must then not connect -- when
  ## any step fails or the result is not exactly the target: groups are
  ## set before the gid changes and the gid before the uid (after
  ## `setuid` there is no right left to do either).
  if ops.euid() != 0 or uid < 0 or uid == 0:
    return ""
  if gid < 0:
    raise newException(PrivilegeDropError,
      "the requester's group is unknown")
  if ops.setGroups(holderGroupList(gid, endpointGroup,
      darwin = defined(macosx))) != 0:
    raise newException(PrivilegeDropError, "setgroups: " &
      osErrorMsg(osLastError()))
  if ops.setGid(gid) != 0:
    raise newException(PrivilegeDropError, "setgid: " &
      osErrorMsg(osLastError()))
  if ops.setUid(uid) != 0:
    raise newException(PrivilegeDropError, "setuid: " &
      osErrorMsg(osLastError()))
  if ops.setUid(0) == 0:
    raise newException(PrivilegeDropError, "root could be regained")
  let problem = credentialProblem(ops.status(), uid, gid, endpointGroup)
  if problem.len > 0:
    raise newException(PrivilegeDropError, "after the drop: " & problem)
  "as uid " & $uid & " gid " & $gid &
    (if endpointGroup >= 0 and endpointGroup != gid:
       " and the endpoint's group " & $endpointGroup else: "")

# ---------------------------------------------------------------------------
# The endpoint's group
# ---------------------------------------------------------------------------

type
  GroupOps* = object
    ## The account and filesystem lookups behind `endpointGroupFor`,
    ## injectable so that membership, non-membership and every failure can
    ## be tested without a second account or root.
    directoryGroup*: proc (dir: string; gid: var int): string
      ## The group that owns `dir` (`stat`), or why it cannot be read.
    userName*: proc (uid: int): string
      ## The account name of `uid` (`getpwuid`), "" when there is none.
    groupsOf*: proc (name: string; baseGid: int; groups: var seq[int]): bool
      ## Every group of account `name`, `baseGid` included
      ## (`getgrouplist`); false when the database cannot answer.

proc endpointGroupFor*(ops: GroupOps; endpointPath: string;
                       privateScope: bool; uid, gid: int):
    tuple[group: int, diagnostic: string] =
  ## The group a holder dropped to `uid`/`gid` keeps besides `gid`: the
  ## group that owns the directory of `endpointPath` -- the endpoint the
  ## hook itself would connect to, never one a client names -- exactly when
  ## the requester is a member of it by the account database. -1 when
  ## there is none, with `diagnostic` saying why when that is not simply
  ## "no group needed" (Build-Engine § Nix daemon builds under leases, "The
  ## endpoint's group"). A private endpoint is owned by the daemon's user
  ## and adds no group.
  result = (-1, "")
  if uid <= 0 or privateScope or endpointPath.len == 0:
    return
  let dir = parentDir(endpointPath)
  var owner = -1
  let problem = ops.directoryGroup(dir, owner)
  if problem.len > 0 or owner < 0:
    result.diagnostic = "the endpoint directory " & dir &
      " cannot be read (" & problem & "); the holder keeps its gid alone"
    return
  if owner == gid:
    return                      # its own gid already admits it
  let name = ops.userName(uid)
  if name.len == 0:
    result.diagnostic = "uid " & $uid & " has no account name; the " &
      "holder keeps its gid alone"
    return
  var groups: seq[int] = @[]
  if not ops.groupsOf(name, gid, groups):
    result.diagnostic = "the groups of " & name & " cannot be read; the " &
      "holder keeps its gid alone"
    return
  if owner notin groups:
    result.diagnostic = name & " is not a member of group " & $owner &
      ", which owns " & dir & "; its holder cannot reach the endpoint"
    return
  result.group = owner

when defined(posix):
  when defined(macosx):
    proc getgrouplistCall(user: cstring; group: cint; groups: ptr cint;
                          ngroups: var cint): cint {.
      importc: "getgrouplist", header: "<unistd.h>".}
  else:
    proc getgrouplistCall(user: cstring; group: Gid; groups: ptr Gid;
                          ngroups: var cint): cint {.
      importc: "getgrouplist", header: "<grp.h>".}

  proc systemGroupOps*(): GroupOps =
    GroupOps(
      directoryGroup: proc (dir: string; gid: var int): string =
        var info: Stat
        if stat(dir.cstring, info) != 0:
          return osErrorMsg(osLastError())
        if not S_ISDIR(info.st_mode):
          return "not a directory"
        gid = int(info.st_gid)
        "",
      userName: proc (uid: int): string =
        let entry = getpwuid(Uid(uid))
        if entry == nil or entry.pw_name == nil: "" else: $entry.pw_name,
      groupsOf: proc (name: string; baseGid: int; groups: var seq[int]): bool =
        var room = 64
        while room <= 65536:
          var count = cint(room)
          when defined(macosx):
            var list = newSeq[cint](room)
            let rc = getgrouplistCall(name.cstring,
              cast[cint](uint32(baseGid)), addr list[0], count)
          else:
            var list = newSeq[Gid](room)
            let rc = getgrouplistCall(name.cstring, Gid(baseGid),
              addr list[0], count)
          if rc >= 0:
            groups.setLen(0)
            for i in 0 ..< min(int(count), room):
              # darwin passes gids as int: -2 (nobody) is 4294967294.
              groups.add(int(cast[uint32](list[i])))
            return true
          room *= 4
        false)

# ---------------------------------------------------------------------------
# The holder
# ---------------------------------------------------------------------------

type
  HoldOptions* = object
    label*: string
    cpuMilli*: uint32
    memoryBytes*: uint64
    uid*, gid*: int
    endpointGroup*: int    ## -1: none (`endpointGroupFor`).
    unclaimedMillis*: int

proc parseHoldArgs*(args: openArray[string]; options: var HoldOptions): bool =
  options = HoldOptions(uid: -1, gid: -1, endpointGroup: -1,
    unclaimedMillis: 10_000)
  var i = 0
  try:
    while i < args.len:
      if i + 1 >= args.len: return false
      let value = args[i + 1]
      case args[i]
      of "--label": options.label = value
      of "--cpu-milli":
        let milli = parseBiggestUInt(value)
        if milli > uint64(high(uint32)): return false
        options.cpuMilli = uint32(milli)
      of "--memory-bytes": options.memoryBytes = uint64(parseBiggestUInt(value))
      of "--uid": options.uid = parseInt(value)
      of "--gid": options.gid = parseInt(value)
      of "--endpoint-group":
        options.endpointGroup = parseInt(value)
        if options.endpointGroup < 0: return false
      of "--unclaimed-millis":
        options.unclaimedMillis = clamp(parseInt(value), 0, 3_600_000)
      else: return false
      i += 2
  except ValueError:
    return false
  options.cpuMilli > 0

when defined(posix):
  type
    LineReader* = object
      ## Lines from a descriptor, read without stdio buffering, so that
      ## `poll` on the descriptor says whether a line can be had.
      fd*: cint
      limit*: int       ## A longer line is an error (-1), not an allocation.
      buffer: string

  proc readLine*(reader: var LineReader; waitMillis: int;
                 line: var string): int =
    ## The next line: 1 read, 0 nothing within `waitMillis` (negative:
    ## wait forever), -1 end of input or a line over `limit`.
    let deadline = getMonoTime() + initDuration(milliseconds = max(0,
      waitMillis))
    while true:
      let nl = reader.buffer.find('\n')
      if nl >= 0:
        line = reader.buffer[0 ..< nl]
        reader.buffer = reader.buffer[nl + 1 .. ^1]
        return 1
      if reader.buffer.len > reader.limit:
        return -1
      var timeout = -1
      if waitMillis >= 0:
        timeout = max(0, int((deadline - getMonoTime()).inMilliseconds))
      var fds = [TPollfd(fd: reader.fd, events: POLLIN)]
      let ready = poll(addr fds[0], Tnfds(1), cint(timeout))
      if ready > 0:
        var chunk = newString(4096)
        let got = posix.read(reader.fd, addr chunk[0], chunk.len)
        if got < 0 and osLastError() == OSErrorCode(EINTR):
          continue
        if got <= 0:
          return -1
        reader.buffer.add(chunk[0 ..< got])
      elif ready < 0 and osLastError() != OSErrorCode(EINTR):
        return -1
      elif waitMillis >= 0 and getMonoTime() >= deadline:
        return 0

  when defined(macosx):
    proc watcherGone(): bool {.nimcall, gcsafe.} =
      ## A darwin lease holder's test, while its request is queued, of
      ## whether its watcher is still there: nothing is written on the pipe
      ## from the watcher before the claim, and a claim comes only after the
      ## grant, so standard input readable (data or end of file) means the
      ## watcher's end closed.
      var fds = [TPollfd(fd: 0, events: POLLIN)]
      poll(addr fds[0], Tnfds(1), 0) > 0 and
        (fds[0].revents and (POLLIN or POLLHUP or POLLERR)) != 0

  proc emit(line: string): bool =
    ## One line to the hook; false once the hook is gone.
    try:
      stdout.write(line & "\n")
      stdout.flushFile()
      true
    except IOError:
      false

  proc getdtablesizeCall(): cint {.importc: "getdtablesize",
    header: "<unistd.h>".}

  proc closeInheritedFds*() =
    ## Closes every descriptor past standard input, output and error. The
    ## hook inherits the worker's descriptors (the builder-output pipe on 4
    ## and 5 among them) and its other holders' pipes; none of them is this
    ## holder's to keep, and a holder that runs as a user must not carry root's.
    var fds: seq[cint] = @[]
    when defined(macosx):
      # No `/proc/self/fd`: the kernel lists this process's descriptors.
      # When it cannot, every possible descriptor is closed instead: a
      # holder must not keep what it inherited because a listing failed.
      var listed = false
      for entry in listFds(getCurrentProcessId(), listed):
        if entry.fd > 2: fds.add(cint(entry.fd))
      if not listed:
        for fd in 3 ..< min(int(getdtablesizeCall()), 1 shl 16):
          fds.add(cint(fd))
    else:
      try:
        for _, path in walkDir("/proc/self/fd"):
          try:
            let fd = parseInt(extractFilename(path))
            if fd > 2: fds.add(cint(fd))
          except ValueError:
            discard
      except OSError:
        discard
    for fd in fds:
      discard posix.close(fd)   # the listing's own fd is already closed: EBADF

  when defined(linux):
    proc prctlCall(option: cint; arg2: culong): cint {.
      varargs, importc: "prctl", header: "<sys/prctl.h>".}

    const
      PrSetPdeathsig = cint(1)
      PrSetNoNewPrivs = cint(38)

  proc tieToHook(tied: bool; hook: Pid) =
    ## While its grant is unclaimed a holder dies with the hook that started
    ## it, so no queued request outlives the hook (`PR_SET_PDEATHSIG`,
    ## https://man7.org/linux/man-pages/man2/prctl.2.html; set after the
    ## privilege drop, which clears it). Once claimed it must outlive the hook,
    ## which the worker kills as soon as its build operation is over.
    ## (Darwin has no `PR_SET_PDEATHSIG`; its watcher stands in for it, see
    ## `watchHolder`.)
    when defined(linux):
      discard prctlCall(PrSetPdeathsig,
        culong(if tied: SIGKILL else: cint(0)))
      if tied and getppid() != hook:
        quit(0)

  type
    HeldUntil = proc (worker: int; locks: seq[string]) {.closure.}
      ## Returns when the claimed build is over and the lease must go back.

  proc holdLease(options: HoldOptions; clientVersion: string;
                 cancelled: proc (): bool {.nimcall, gcsafe.};
                 onClaim: proc () {.closure.};
                 heldUntil: HeldUntil): int =
    ## The lease holder proper, already running as the requester: one lease
    ## for one derivation build. Speaks to the hook in lines on standard
    ## input and output: it writes `granted <milli>`, `unavailable <why>` or
    ## `refused <why>`; the hook writes `claim <worker pid> <lock path>...`
    ## (tab separated), which the holder confirms with `claimed`. While the
    ## request is queued, `cancelled` (when given) is asked every poll.
    var client: RunQuotaClient
    try:
      client = connectDefault()
    except CatchableError as failure:
      discard emit("unavailable no RunQuota daemon reached (" &
        failure.msg.replace('\n', ' ') & ")")
      return 0
    defer: client.close()
    var session: RunQuotaSession
    var lease: RunQuotaLease
    try:
      session = client.registerSession("nix-daemon build", clientVersion)
      let request = resourceRequest(options.label, milliCpu(options.cpuMilli),
        bytes(options.memoryBytes))
      lease = session.requestLeaseWaiting(request,
        pollMillis = HolderGrantPollMillis, cancelled = cancelled)
    except CatchableError as failure:
      if cancelled != nil and cancelled():
        # Nobody is waiting for this lease any more; the daemon drops the
        # queued request when the connection closes.
        return 0
      discard emit("refused " & failure.msg.replace('\n', ' '))
      return 1
    var input = LineReader(fd: 0, limit: ClaimLineLimit)
    var line = ""
    let answer =
      if emit("granted " & $lease.resources.cpu.value):
        input.readLine(options.unclaimedMillis, line)
      else: -1
    if answer != 1 or not line.startsWith("claim "):
      # Never claimed: the derivation was built by someone else, the worker
      # went away, or it is still waiting for a local build slot. Give the
      # capacity back; the next try asks again.
      try:
        lease.release()
        session.closeSession()
      except CatchableError:
        discard
      return 0
    let fields = line["claim ".len .. ^1].split('\t')
    var worker = 0
    try: worker = parseInt(fields[0])
    except ValueError: return 1
    let locks = fields[1 .. ^1]
    if onClaim != nil: onClaim()
    discard emit("claimed")
    try:
      lease.markStarting()
      # The worker stands in for the build: if this holder dies, the daemon
      # keeps the reservation until the worker is gone.
      lease.markRunning(childProcessId = uint64(worker))
    except CatchableError:
      discard
    heldUntil(worker, locks)
    try:
      lease.release()
      session.closeSession()
    except CatchableError:
      discard
    0

  when not defined(macosx):
    proc runHolder*(args: seq[string]; clientVersion: string): int =
      ## `runquota nix-build-hook --hold ...`: one lease for one derivation
      ## build (`holdLease`). It drops to the requester, ties itself to the
      ## hook until its grant is claimed, and once claimed holds the lease
      ## while the worker holds the build's output locks (`/proc/locks`).
      closeInheritedFds()
      var options: HoldOptions
      if not parseHoldArgs(args, options):
        discard emit("refused bad holder arguments")
        return 2
      let hook = getppid()
      try:
        discard dropPrivilegesWith(systemCredentialOps(), options.uid,
          options.gid, options.endpointGroup)
      except CatchableError as failure:
        discard emit("refused cannot act as the requester: " & failure.msg)
        return 1
      when defined(linux):
        # Nothing this process could exec may gain privileges again.
        discard prctlCall(PrSetNoNewPrivs, culong(1), culong(0), culong(0),
          culong(0))
      # Out of the hook's process group: the worker kills that group when its
      # build operation ends, and a claimed holder still has to give its lease
      # back after that.
      discard setsid()
      tieToHook(true, hook)
      holdLease(options, clientVersion, cancelled = nil,
        onClaim = proc () = tieToHook(false, hook),
        heldUntil = proc (worker: int; locks: seq[string]) =
          var misses = 0
          while misses < ReleaseMisses:
            sleep(ProbeMillis)
            if not dirExists("/proc" / $worker):
              break
            if anyLockHeldBy(locks, worker):
              misses = 0
            else:
              inc misses)

  else:
    proc childExited(child: Pid): bool =
      ## Whether the watcher's lease holder has exited (it is reaped then).
      var status: cint
      let reaped = waitpid(child, status, WNOHANG)
      reaped == child or (reaped < 0 and osLastError() != OSErrorCode(EINTR))

    proc reapWithin(child: Pid; millis: int) =
      ## Waits for the lease holder to exit, and kills it (its own child, by
      ## a pid that cannot be reused before it is reaped) if it has not
      ## within `millis`.
      let deadline = getMonoTime() + initDuration(milliseconds = millis)
      while getMonoTime() < deadline:
        if childExited(child): return
        sleep(20)
      discard kill(child, SIGKILL)
      var status: cint
      discard waitpid(child, status, 0)

    proc watchHolder(child: Pid; toChild: cint): int =
      ## THE WATCHER, darwin's stand-in for `/proc/locks` and
      ## `PR_SET_PDEATHSIG`. It keeps the hook's credential (root, under a
      ## multi-user daemon) because only root can read the descriptors of
      ## the root worker, and it does nothing a user could steer: its only
      ## input is the hook's `claim` line (the hook is root too); it reads
      ## the kernel's view of the worker; its only output is closing the
      ## pipe to its lease holder, which then gives the lease back. It
      ## writes nothing to the hook, opens no file and takes no lock.
      ##
      ## * Before the claim it watches the hook: the hook's end of standard
      ##   input closing means the hook is gone, and the queued lease holder
      ##   is killed, as `PR_SET_PDEATHSIG` kills a Linux holder.
      ## * It forwards the claim to the lease holder and from then on
      ##   ignores the hook, which the worker kills when its build operation
      ##   ends while the build it claimed may still be running.
      ## * It probes every `ProbeMillis` whether the worker -- the same
      ##   process, by its start time -- still holds a `flock` on one of the
      ##   build's output locks (`anyLockHeldBy`), and after `ReleaseMisses`
      ##   free probes, or once the worker is gone, closes the pipe.
      # Standard output and error are the pipe to the hook, and they belong
      # to the lease holder: the hook reads the end of that pipe as the
      # holder's exit, which must not wait for this process.
      let devNull = posix.open("/dev/null", O_RDWR)
      if devNull >= 0:
        discard dup2(devNull, 1)
        discard dup2(devNull, 2)
        discard posix.close(devNull)
      var fromHook = LineReader(fd: 0, limit: ClaimLineLimit)
      var line = ""
      while true:
        if childExited(child):
          return 0
        let got = fromHook.readLine(ProbeMillis, line)
        if got < 0:
          # The hook is gone before it claimed this lease.
          discard kill(child, SIGKILL)
          var status: cint
          discard waitpid(child, status, 0)
          return 0
        if got == 1 and line.startsWith("claim "):
          break
      let fields = line["claim ".len .. ^1].split('\t')
      var worker = 0
      try: worker = parseInt(fields[0])
      except ValueError: worker = 0
      let forwarded = line & "\n"
      var sent = 0
      while sent < forwarded.len:
        let n = posix.write(toChild, unsafeAddr forwarded[sent],
          forwarded.len - sent)
        if n > 0:
          sent += n
        elif n < 0 and osLastError() == OSErrorCode(EINTR):
          continue
        else:
          break   # the lease holder is gone; childExited ends the watch

      var identity: ProcessIdentity
      let known = worker > 0 and processIdentity(worker, identity)
      var misses = if known: 0 else: ReleaseMisses
      while misses < ReleaseMisses:
        sleep(ProbeMillis)
        if childExited(child):
          # It gave up (its grant was already gone) or was killed.
          return 0
        var now: ProcessIdentity
        if not processIdentity(worker, now) or not sameProcess(now, identity):
          break
        case lockProbe(fields[1 .. ^1], worker)
        of 1: misses = 0
        of 0: inc misses
        else: discard   # unreadable: neither held nor free; probe again
      discard posix.close(toChild)
      reapWithin(child, WatcherReapMillis)
      0

    proc runHolder*(args: seq[string]; clientVersion: string): int =
      ## `runquota nix-build-hook --hold ...` on darwin: TWO PROCESSES. The
      ## process the hook starts stays as the hook's user and becomes the
      ## watcher (`watchHolder`); its child drops to the requester and holds
      ## the lease (`holdLease`). The child talks to the hook directly on
      ## standard output; its standard input is a pipe from the watcher,
      ## which forwards the claim and closes the pipe when the build is over.
      closeInheritedFds()
      var options: HoldOptions
      if not parseHoldArgs(args, options):
        discard emit("refused bad holder arguments")
        return 2
      # A write to a pipe whose reader is gone is an error to handle, not a
      # signal that kills the process.
      signal(SIGPIPE, SIG_IGN)
      # Out of the hook's process group, both processes: the worker kills
      # that group when its build operation ends, and a claimed lease must
      # still be given back after that.
      discard setsid()
      var toChild: array[2, cint]
      if pipe(toChild) != 0:
        discard emit("refused cannot create the holder's pipe: " &
          osErrorMsg(osLastError()))
        return 1
      let child = fork()
      if child < 0:
        discard emit("refused cannot fork the holder: " &
          osErrorMsg(osLastError()))
        return 1
      if child == 0:
        # The lease holder.
        discard posix.close(toChild[1])
        discard dup2(toChild[0], 0)
        discard posix.close(toChild[0])
        # THE FORKED CHILD NEVER RETURNS into the caller's code: whatever
        # happens, it ends here with `exitnow` (no exit handlers of the
        # process it was forked from run).
        var code = 1
        try:
          try:
            discard dropPrivilegesWith(systemCredentialOps(), options.uid,
              options.gid, options.endpointGroup)
          except CatchableError as failure:
            discard emit("refused cannot act as the requester: " &
              failure.msg)
            exitnow(1)
          code = holdLease(options, clientVersion,
            cancelled = watcherGone,
            onClaim = nil,
            heldUntil = proc (worker: int; locks: seq[string]) =
              # Until the watcher closes the pipe (or dies).
              var input = LineReader(fd: 0, limit: ClaimLineLimit)
              var ignored = ""
              while input.readLine(-1, ignored) >= 0: discard)
        except CatchableError, Defect:
          code = 1
        exitnow(cint(code))
      discard posix.close(toChild[0])
      watchHolder(child, toChild[1])

# ---------------------------------------------------------------------------
# The hook
# ---------------------------------------------------------------------------

proc holderEnv*(requester: Requester): StringTableRef =
  ## A holder's environment: the RunQuota endpoint variables of the hook's
  ## own environment (the daemon's) and the requester's session variables.
  ## NOTHING ELSE of either is passed on: the daemon's environment may hold
  ## credentials (`NIX_CONFIG` with `access-tokens`, a token for a private
  ## cache), and a holder runs as the requesting user.
  result = newStringTable(modeCaseSensitive)
  for key in HolderEndpointVars:
    if existsEnv(key): result[key] = getEnv(key)
  if requester.group.len > 0:
    result[SessionGroupEnvVar] = requester.group
    if requester.priority.len > 0:
      result[SessionPriorityEnvVar] = requester.priority
    if requester.cacheTtl.len > 0:
      result[SessionCacheTtlEnvVar] = requester.cacheTtl

when defined(posix):
  type
    Holder = ref object
      process: Process
      output: LineReader   ## What the holder writes.
      event: string        ## The first event line, once read.

    HookState = object
      settings: HookSettings
      requester: Requester
      requesterKnown: bool
      endpointGroup: int   ## The holders' extra group, -1: none.
      workerPid: int
      pending: Table[string, Holder]
      claimed: seq[Holder]
      unavailableUntil: MonoTime
      warned: bool

  proc nextLine(holder: Holder; waitMillis: int; line: var string): int =
    ## The holder's next line: 1 read, 0 nothing within `waitMillis`, -1 the
    ## holder closed its output (or wrote something that is not a line).
    holder.output.readLine(waitMillis, line)

  proc readEvent(holder: Holder; waitMillis: int): bool =
    ## Reads what the holder has written; true once its first event is in.
    if holder.event.len > 0: return true
    var line = ""
    case holder.nextLine(waitMillis, line)
    of 1: holder.event = (if line.len > 0: line else: "exited")
    of -1: holder.event = "exited"
    else: return false
    true

  proc spawnHolder(state: HookState; drvPath: string): Holder =
    let cpus = leaseCpusFor(state.settings.cores, hostCpuCount())
    let unclaimed = 2 * state.settings.pollIntervalSecs * 1000 + 1000
    var args = @[HookVerb, HoldFlag,
      "--label", "nix " & extractFilename(drvPath),
      "--cpu-milli", $(cpus * 1000),
      "--memory-bytes", $(DefaultHookMemoryPerSlot * uint64(cpus)),
      "--unclaimed-millis", $unclaimed]
    if state.requester.uid >= 0:
      args.add(["--uid", $state.requester.uid])
      args.add(["--gid", $(if state.requester.gid >= 0: state.requester.gid
                           else: NoGroupGid)])
      if state.endpointGroup >= 0:
        args.add(["--endpoint-group", $state.endpointGroup])
    let process = startProcess(getAppFilename(), args = args,
      env = holderEnv(state.requester), options = {poStdErrToStdOut})
    Holder(process: process, output: LineReader(
      fd: cint(process.outputHandle), limit: HolderLineLimit))

  proc endHolder(holder: Holder) =
    ## Ends a holder this hook started (its own child, by its pid, which
    ## cannot be reused before it is waited for). SIGKILL, so a stopped
    ## holder cannot hold the worker here.
    ##
    ## On darwin the process is the watcher, and the lease holder is its
    ## child, running as the requester, who can stop it (same uid) so that
    ## it never notices its watcher die. The watcher made itself a process
    ## group leader (`setsid`) before it forked, so the group is killed
    ## first -- while the watcher is unreaped its pid, and so that group
    ## id, can belong to no one else -- then the watcher by pid, in case it
    ## had not yet called `setsid`. (A lease holder forked in the instant
    ## between the two is not killed here; it stops waiting when it sees
    ## its watcher's pipe close, unless its requester stopped it.)
    try:
      when defined(macosx):
        let pid = Pid(holder.process.processID)
        discard kill(-pid, SIGKILL)
      if holder.process.running:
        holder.process.kill()
        discard holder.process.waitForExit(2000)
      holder.process.close()
    except CatchableError:
      discard

  proc claim(holder: Holder; workerPid: int; locks: seq[string]): bool =
    ## Hands a granted holder its build; true once it has confirmed. A holder
    ## that already gave its grant back (its unclaimed time ran out) never
    ## confirms, and the build is not run on its lease.
    try:
      holder.process.inputStream.write("claim " & $workerPid & "\t" &
        locks.join("\t") & "\n")
      holder.process.inputStream.flush()
    except CatchableError:
      return false
    var line = ""
    holder.nextLine(ClaimConfirmMillis, line) == 1 and line == "claimed"

  proc reapClaimed(state: var HookState) =
    var kept: seq[Holder] = @[]
    for holder in state.claimed:
      if holder.process.running: kept.add(holder)
      else:
        try: holder.process.close()
        except CatchableError: discard
    state.claimed = kept

  proc warn(state: var HookState; message: string) =
    if not state.warned:
      stderr.write(nixLogLine("runquota: " & message) & "\n")
      state.warned = true

  proc decide*(state: var HookState; request: TryRequest): string =
    ## The reply to one `try`.
    state.reapClaimed()
    if state.settings.maxJobs <= 0:
      # `max-jobs = 0`: this worker never builds locally, so no lease would
      # ever be used. Declining lets Nix say so instead of postponing forever.
      return "decline"
    if request.drvPath.len == 0:
      return "decline"
    if getMonoTime() < state.unavailableUntil:
      return "decline"
    if not state.requesterKnown:
      state.requester = findRequester(state.workerPid)
      state.requesterKnown = true
      # The group the holders keep so they can reach the endpoint this hook
      # would connect to (its own endpoint, from the daemon's environment;
      # never one the client names). Only a root hook drops privileges.
      var groupNote = ""
      if geteuid() == 0 and state.requester.uid > 0:
        let found = endpointGroupFor(systemGroupOps(),
          defaultEndpoint().path,
          getEnv("RUNQUOTA_ENDPOINT_SCOPE", "host") == "private",
          state.requester.uid,
          if state.requester.gid >= 0: state.requester.gid else: NoGroupGid)
        state.endpointGroup = found.group
        groupNote = found.diagnostic
        if found.group >= 0:
          groupNote = "keeping the endpoint's group " & $found.group
      # Talkative (`-v`): who the leases are for, and how that was found.
      stderr.write(nixLogLine("runquota: leases for uid " &
        $state.requester.uid & " in group '" &
        (if state.requester.group.len > 0: state.requester.group
         else: "interactive") & "' (" & state.requester.how &
        (if groupNote.len > 0: "; " & groupNote else: "") & ")",
        level = 4) & "\n")

    var holder = state.pending.getOrDefault(request.drvPath)
    if holder == nil:
      let cap = max(1, min(state.settings.maxJobs, hostCpuCount()))
      if not request.amWilling or state.pending.len >= cap:
        return "postpone"
      try:
        holder = state.spawnHolder(request.drvPath)
      except CatchableError as failure:
        state.warn("cannot start the lease holder (" & failure.msg &
          "); building unadmitted")
        return "decline"
      state.pending[request.drvPath] = holder
      discard holder.readEvent(ImmediateGrantMillis)
    elif not holder.readEvent(0):
      return "postpone"
    if holder.event.len == 0:
      return "postpone"
    if holder.event.startsWith("granted "):
      if not request.amWilling:
        return "postpone"
      var locks: seq[string] = @[]
      try:
        locks = outputLockPaths(request.drvPath,
          parseDrvOutputs(readRegularFile(realStorePath(request.drvPath,
            state.settings.store), DrvFileLimit)), state.settings.store)
      except CatchableError as failure:
        state.warn("cannot read " & request.drvPath & " (" & failure.msg &
          "); building it unadmitted")
      state.pending.del(request.drvPath)
      if locks.len == 0:
        holder.endHolder()
        return "decline"
      if not holder.claim(state.workerPid, locks):
        # Its grant is gone; ask again on the next try.
        holder.endHolder()
        return "postpone"
      state.claimed.add(holder)
      return "decline"
    # `unavailable`, `refused`, or the holder exited without a word.
    state.pending.del(request.drvPath)
    holder.endHolder()
    if holder.event.startsWith("unavailable"):
      state.unavailableUntil = getMonoTime() +
        initDuration(milliseconds = UnavailableRetryMillis)
      state.warn(holder.event["unavailable".len .. ^1].strip() &
        "; nix-daemon builds run unadmitted")
    else:
      state.warn("no lease for " & request.drvPath & " (" & holder.event &
        "); building it unadmitted")
    "decline"

  proc reply(answer: string): bool =
    try:
      stderr.write("# " & answer & "\n")
      stderr.flushFile()
      true
    except IOError:
      false

  proc runNixBuildHook*(args: seq[string]; clientVersion: string): int =
    ## The `nix-build-hook` verb: `build-hook = <runquota> nix-build-hook` in
    ## `nix.conf` (Nix appends the verbosity), or `--hold` for a holder.
    if args.len >= 1 and args[0] == HoldFlag:
      return runHolder(args[1 .. ^1], clientVersion)
    let input = newFileStream(stdin)
    var state = HookState(workerPid: int(getppid()), endpointGroup: -1)
    try:
      state.settings = readHookSettings(input)
    except CatchableError:
      # The worker went away before its first `try`: nothing to answer.
      return 0
    var request: TryRequest
    while true:
      var more = false
      try:
        more = readTry(input, request)
      except EOFError:
        break
      except CatchableError as failure:
        # The stream cannot be followed any more. Stop being asked, so the
        # rest of this build operation runs without the hook rather than on
        # a misread request.
        state.warn("build hook stopped (" & failure.msg &
          "); building unadmitted")
        discard reply("decline-permanently")
        break
      if not more: break
      var answer = "decline"
      try:
        answer = state.decide(request)
      except CatchableError, Defect:
        # EVERY `try` IS ANSWERED. An error here must not leave the worker
        # reading a reply that never comes (the build would fail); declining
        # runs the build as it would run without the hook.
        state.warn("build hook error (" & getCurrentExceptionMsg() &
          "); building unadmitted")
        answer = "decline"
      if not reply(answer): break
    # The worker is done with this hook: no queued request outlives it.
    for _, holder in state.pending:
      holder.endHolder()
    0

else:
  proc unsupportedPlatformMessage*(): string =
    ## What the verb says where the hook cannot run.
    const platform = when defined(windows): "Windows" else: hostOS
    "runquota " & HookVerb & ": not supported on " & platform &
      ": the nix-daemon build hook runs on POSIX hosts only"

  proc runNixBuildHook*(args: seq[string]; clientVersion: string): int =
    ## The `nix-build-hook` verb where the hook cannot run (see PLATFORMS in
    ## the module header). It refuses, naming the platform, and exits 1: a
    ## hook that answered without admitting anything would let builds run
    ## unadmitted while looking installed.
    stderr.writeLine(unsupportedPlatformMessage())
    1
