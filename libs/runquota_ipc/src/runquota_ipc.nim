import std/[net, nativesockets, os, strutils, times]

when defined(posix):
  import std/posix
  when defined(macosx) or defined(freebsd) or defined(openbsd):
    proc getpeereid(socket: SocketHandle; euid: ptr Uid; egid: ptr Gid): cint {.
      importc, header: "<unistd.h>".}
  when defined(linux):
    type
      LinuxPeerCred {.importc: "struct ucred", header: "<sys/socket.h>", bycopy.} = object
        pid {.importc: "pid".}: Pid
        uid {.importc: "uid".}: Uid
        gid {.importc: "gid".}: Gid

    const SoPeerCred = cint(17)

when defined(windows):
  # Windows: native named-pipe transport implementation. We use winlean for
  # the low-level pieces and call a handful of advapi32 functions that
  # winlean does not expose directly. The Windows daemon spawns one
  # listener thread that pre-creates a pipe instance, calls
  # ConnectNamedPipe to wait for a client, hands the connected handle to
  # a worker thread, then loops to pre-create the next instance.
  import std/winlean

  const
    # Windows: PIPE_UNLIMITED_INSTANCES from winbase.h.
    PIPE_UNLIMITED_INSTANCES = 255'i32
    PIPE_ACCESS_DUPLEX_W = 0x00000003'i32
    PIPE_TYPE_BYTE_W = 0x00000000'i32
    PIPE_READMODE_BYTE_W = 0x00000000'i32
    PIPE_WAIT_W = 0x00000000'i32
    PIPE_REJECT_REMOTE_CLIENTS_W = 0x00000008'i32
    NMPWAIT_USE_DEFAULT_WAIT = 0x00000000'i32
    GENERIC_READ_W = 0x80000000'i32
    GENERIC_WRITE_W = 0x40000000'i32
    OPEN_EXISTING_W = 3'i32
    DefaultPipeBufferSize = 65536'i32
    # Windows: GetTokenInformation TokenUser class (TOKEN_INFORMATION_CLASS=1).
    TokenUserClass = 1'i32
    TOKEN_QUERY_W = 0x0008'i32
    ERROR_PIPE_CONNECTED = 535'i32
    ERROR_NO_DATA = 232'i32
    ERROR_BROKEN_PIPE = 109'i32

  type
    WinHandle = winlean.Handle

  proc createNamedPipeW(
    lpName: WideCString,
    dwOpenMode: int32,
    dwPipeMode: int32,
    nMaxInstances: int32,
    nOutBufferSize: int32,
    nInBufferSize: int32,
    nDefaultTimeOut: int32,
    lpSecurityAttributes: pointer
  ): WinHandle {.stdcall, dynlib: "kernel32.dll", importc: "CreateNamedPipeW".}

  proc connectNamedPipe(
    hNamedPipe: WinHandle, lpOverlapped: pointer
  ): WINBOOL {.stdcall, dynlib: "kernel32.dll", importc: "ConnectNamedPipe".}

  proc disconnectNamedPipe(
    hNamedPipe: WinHandle
  ): WINBOOL {.stdcall, dynlib: "kernel32.dll", importc: "DisconnectNamedPipe".}

  proc waitNamedPipeW(
    lpName: WideCString, nTimeOut: int32
  ): WINBOOL {.stdcall, dynlib: "kernel32.dll", importc: "WaitNamedPipeW".}

  proc getNamedPipeClientProcessId(
    Pipe: WinHandle, ClientProcessId: ptr int32
  ): WINBOOL {.stdcall, dynlib: "kernel32.dll", importc: "GetNamedPipeClientProcessId".}

  proc openProcessToken(
    ProcessHandle: WinHandle, DesiredAccess: int32, TokenHandle: ptr WinHandle
  ): WINBOOL {.stdcall, dynlib: "advapi32.dll", importc: "OpenProcessToken".}

  proc getTokenInformation(
    TokenHandle: WinHandle, TokenInformationClass: int32,
    TokenInformation: pointer, TokenInformationLength: int32,
    ReturnLength: ptr int32
  ): WINBOOL {.stdcall, dynlib: "advapi32.dll", importc: "GetTokenInformation".}

  proc convertSidToStringSidW(
    Sid: pointer, StringSid: ptr ptr uint16
  ): WINBOOL {.stdcall, dynlib: "advapi32.dll", importc: "ConvertSidToStringSidW".}

  proc localFree(hMem: pointer): pointer {.stdcall, dynlib: "kernel32.dll", importc: "LocalFree".}

  proc getCurrentProcessHandle(): WinHandle {.stdcall, dynlib: "kernel32.dll", importc: "GetCurrentProcess".}

  proc closeHandleW(hObject: WinHandle): WINBOOL {.stdcall, dynlib: "kernel32.dll", importc: "CloseHandle".}

import runquota_ipc/types as ipcTypes
import runquota_core
import runquota_protocol

export ipcTypes

const libraryName* = "runquota_ipc"

proc libraryInfo*(): ipcTypes.LibraryInfo =
  ipcTypes.LibraryInfo(name: libraryName)

proc unixEndpoint*(path: string): Endpoint =
  Endpoint(kind: endpointUnixSocket, path: path)

when defined(windows):
  # Windows: build the spec-defined named-pipe path. We sanitise the user
  # name so the path stays well-formed regardless of locale or special chars.
  proc namedPipeEndpoint*(path: string): Endpoint =
    Endpoint(kind: endpointNamedPipe, path: path)

  proc sanitiseUserToken(token: string): string =
    result = newStringOfCap(token.len)
    for ch in token:
      if ch.isAlphaNumeric or ch == '-' or ch == '_' or ch == '.':
        result.add(ch)
      else:
        result.add('_')

  proc currentUserToken(): string =
    # Windows: prefer USERNAME but fall back to a literal "default" so the
    # daemon still has a usable per-process endpoint even in stripped envs.
    let username = getEnv("USERNAME")
    if username.len > 0:
      sanitiseUserToken(username)
    else:
      "default"

  proc defaultWindowsPipePath(): string =
    r"\\.\pipe\runquota-" & currentUserToken()

  proc windowsPipeToken(path: string): string =
    ## A stable, short, pipe-name-safe token derived from `path` (FNV-1a over
    ## the case-folded path -- Windows paths are case-insensitive). Computed
    ## inline rather than via std/hashes so it does not depend on that
    ## module's build-specific string hashing: a server and a client given
    ## the same path must always derive the same pipe name.
    var h = 0xcbf29ce484222325'u64
    for ch in path.toLowerAscii():
      h = h xor uint64(ord(ch))
      h = h * 0x100000001b3'u64
    toHex(h)

proc endpointForPath*(path: string): Endpoint =
  ## Resolve a user-supplied endpoint path -- a `--socket` argument or the
  ## RUNQUOTA_SOCKET override -- to a concrete endpoint. On POSIX this is a
  ## Unix-domain socket. On Windows, which this transport serves with named
  ## pipes, a path already in `\\.\pipe\...` form is used as-is; any other
  ## path (e.g. a `.sock` path from a cross-platform caller such as the CMake
  ## generator benchmark) is mapped deterministically onto a named pipe, so a
  ## server and a client handed the same path always meet on the same pipe.
  when defined(windows):
    if path.startsWith(r"\\.\pipe\") or path.startsWith(r"\\?\pipe\"):
      namedPipeEndpoint(path)
    else:
      namedPipeEndpoint(r"\\.\pipe\runquota-" & windowsPipeToken(path))
  else:
    unixEndpoint(path)

# ---------------------------------------------------------------------------
# The rendezvous path, and the trust that has to be verified rather than
# assumed.
#
# Normative specification:
# ``reprobuild-specs/RunQuota-Shared-Memory-Transport.md`` §"Trust and the
# privilege boundary", §"Mechanism".
#
# ``runquotad`` is ONE DAEMON PER HOST, not one per user: bounding load on a
# machine requires a single authority over that machine's resources, and
# per-user daemons would each admit against their own view of a budget they
# in fact share. Everything below follows from that.
#
# THE RENDEZVOUS IS SHARED, NOT PER-USER, AND THAT FOLLOWS FROM THE DAEMON
# BEING HOST-WIDE. The endpoint used to be ``<runtime>/runquota-$UID/…``,
# and the failure that produced is worse than unreachability: the path was
# DERIVED FROM THE CALLER'S IDENTITY, so a second user did not get
# ``EACCES`` -- they computed a DIFFERENT path, found nothing there, and
# started a daemon of their own. The deployment degraded silently to one
# daemon per user, which is exactly what the host-wide decision exists to
# prevent, and every scope check in this file then guarded a boundary
# nothing could cross. So the endpoint now lives at a FIXED system path
# with nothing caller-derived anywhere in it, and reaching it is gated by
# GROUP MEMBERSHIP rather than by uid.
#
# The attack this defends against is on the PATH, not on the connection.
# ``<tmp>/runquota-$UID`` is a predictable name, and where
# ``XDG_RUNTIME_DIR`` is absent -- bare Linux, containers, any session
# without ``pam_systemd`` -- its parent is a world-writable ``/tmp``. Another
# user can create that directory BEFORE the daemon starts and thereby own the
# rendezvous point. Checking the credentials of whoever connects
# (``peerIdentity`` below, and it is still required) cannot detect this,
# because by then the socket is already sitting in a directory somebody else
# controls.
#
# Relying on ``umask`` is equally insufficient, and worse because it is
# quiet: ``createDir`` with no mode asks for ``0o777`` and gets whatever the
# umask leaves, typically ``0755``, and the happy path works either way. So
# the mode is explicit on creation AND verified on every daemon start and
# every client attach, and wrong ownership or mode is a refusal rather than a
# fallback.
#
# THE TWO REQUIREMENTS PULL AGAINST EACH OTHER AND THAT IS THE DESIGN.
# Shared access is why the mode cannot be ``0700``; squatting is why the
# mode cannot be assumed. They reconcile because the directory is
# DAEMON-OWNED at a FIXED path: group members traverse and connect, nobody
# but the daemon creates or replaces, and both facts are checked rather
# than trusted.
#
# WHICH LAYER REFUSES A NON-MEMBER MATTERS. The refusal that counts is the
# KERNEL's -- no search permission on a ``0750`` directory whose group the
# caller is not in -- and the predicate below is deliberately written so it
# does NOT fire for a legitimate non-member: a non-member sees the correct
# owner, the correct group and the correct mode, so ``trustOk`` comes back
# and the ``connect(2)`` that follows is refused by the filesystem. An
# application-level check that fired first would leave the real boundary
# untested.
# ---------------------------------------------------------------------------

type
  PathTrustReason* = enum
    ## Why a rendezvous path was accepted or refused.
    ##
    ## The reason is part of the API rather than only part of the message:
    ## "was refused" and "was refused FOR THE RIGHT REASON" are different
    ## assertions, and a caller that can only see a message cannot tell an
    ## ownership check that fired from one that was skipped while the mode
    ## check happened to refuse the same path anyway.
    trustOk
    trustMissing
      ## Nothing at that path. Not an error by itself: the daemon is about
      ## to create it, and a client gets a plain connect failure.
    trustUnreadable
    trustWrongType
      ## Checked with ``lstat``, so a symlink planted at the rendezvous
      ## path lands here rather than being followed to a target whose mode
      ## says nothing about the link.
    trustForeignOwner
    trustForeignGroup
      ## The directory is owned by the right uid but carries the wrong
      ## GROUP. Distinct from ``trustForeignOwner`` because it is a
      ## different deployment mistake with a different repair: the group is
      ## what the kernel admits callers by, so a rendezvous in the wrong
      ## group is one no client can reach, or -- worse -- one the wrong
      ## population can.
    trustBadMode

  PathTrust* = object
    reason*: PathTrustReason
    path*: string
    mode*: int
      ## The mode found on disk, or -1 when it could not be read.
    ownerUid*: int64
      ## The owning uid found on disk, or -1 when it could not be read.
    groupGid*: int64
      ## The owning gid found on disk, or -1 when it could not be read.
    message*: string
      ## Empty exactly when ``reason`` is ``trustOk``. Always names the
      ## offending path, and names the mode whenever one was read.

  EndpointTrustError* = object of OSError
    ## Raised instead of falling back. A rendezvous directory that fails
    ## these checks is not a degraded mode to carry on in.

  SegmentScope* = enum
    ## THE PER-USER RULE IS NOT UNIFORM, and code that assumes it is will
    ## break the design rather than enforce it.
    ##
    ## The budget and the observation ring are written by clients, so they
    ## are one per user and ``0600``. The aggregate stats table is written
    ## only by ``runquotad`` and read by every client: a page no client can
    ## write cannot be used by one user to perturb another, so it needs no
    ## isolation at all, and every client MUST be able to read it or the
    ## zero-IPC estimate becomes one account's privilege. Group-readable
    ## rather than world-readable because the keys are opaque but the table
    ## still exposes the shape of another user's work.
    ##
    ## Applying ``0600`` uniformly here would make the host-wide table
    ## unreadable by every user but one.
    segmentPerUser
    segmentHostWide

const
  endpointDirectoryMode* = 0o750
    ## The rendezvous directory. NOT ``0700``: a private mode on a SHARED
    ## rendezvous locks out every user but one, which is the same defect as
    ## running a daemon per user. Daemon-owned, traversable by the
    ## ``runquota`` group, and never group- or other-WRITABLE -- that last
    ## is the invariant, and the exact mode is how it is enforced.
  endpointSocketMode* = 0o660
    ## The socket itself: group ``runquota``, so a member may connect and a
    ## non-member is refused by the filesystem. NOT decoration: Darwin
    ## enforces a Unix socket's own mode on ``connect(2)``, verified by a
    ## paired control from a second uid through one traversable ``0755``
    ## directory -- ``0660`` refused, ``0666`` connected, ``0600``
    ## refused.
  singleUserEndpointDirectoryMode* = 0o700
    ## THE DEGRADED RENDEZVOUS, used when the ``runquota`` group cannot be
    ## resolved on this host. See ``RendezvousScope``.
  singleUserEndpointSocketMode* = 0o600
  perUserSegmentMode* = 0o600
    ## Budget and observation-ring segments. PER-USER STATE DOES NOT FOLLOW
    ## THE RENDEZVOUS. The rendezvous became group-accessible because it is
    ## where a client FINDS the daemon; the budget word and the observation
    ## ring are where a client's own work is written, and widening those to
    ## match would satisfy every other rule here while destroying the
    ## boundary the rules exist for.
  hostWideSegmentMode* = 0o640
    ## The aggregate stats table: daemon-written, group-readable, and
    ## deliberately NOT ``0600``.
  hostStateDirectoryMode* = 0o755
    ## The host-wide state directory (``/var/db/runquota``,
    ## ``/var/lib/runquota``). This is the mode all three provisioning
    ## routes in ``nix/host-state.nix``, the NixOS module and the by-hand
    ## runbook write, and the daemon verifies it rather than merely
    ## checking the directory exists.
  defaultRendezvousGroup* = "runquota"
    ## The group whose membership is the admission control for "may you
    ## participate in the managed-resource system on this host".
  defaultRendezvousUser* = "runquota"
    ## The account ``runquotad`` runs as under the shipped install step.
  endpointSocketName* = "runquotad.sock"

  # THE FIXED SYSTEM PATH. Nothing in it derives from the caller: no uid,
  # no `HOME`, no `XDG_RUNTIME_DIR`, no `TMPDIR`. Two different users
  # compute the same string, which is the only way a host-wide daemon is
  # reachable at all -- and the only way a second user gets `EACCES`
  # instead of quietly starting a daemon of their own.
  #
  # Duplicated, machine-readably, in `nix/host-state.nix`, which is what
  # the install step provisions from;
  # `tests/integration/t_host_identity_refusal.nim` asserts the two agree.
  hostWideEndpointDir* =
    when defined(windows):
      ""
    elif defined(macosx):
      "/var/run/runquota"
    else:
      "/run/runquota"

type
  RendezvousScope* = enum
    ## WHAT THE ENDPOINT'S ADMISSION BOUNDARY ACTUALLY IS on this host.
    ##
    ## A GROUP THAT CANNOT BE RESOLVED MUST NOT SILENTLY SWITCH THE GROUP
    ## CHECK OFF. The group IS the admission boundary: with no group there
    ## is no boundary, and an endpoint that kept ``0750`` while skipping
    ## the group comparison would be traversable by whatever group it
    ## happened to inherit -- a real boundary nobody chose, verified
    ## against nothing.
    ##
    ## Refusing to start is the wrong answer here, and the reason it is
    ## wrong is the same reason it was RIGHT for ``host_id``: admission is
    ## the mission. A host that has not created the group yet would lose
    ## its whole build-capacity governor over a missing group entry.
    ##
    ## So the degradation is VISIBLE INSTEAD OF SILENT, and it degrades
    ## the CLAIM rather than the enforcement: with no group, the endpoint
    ## becomes ``0700``/``0600``, owner-only, and the daemon says so. The
    ## host-wide daemon visibly becomes a per-user one -- which is a
    ## boundary the kernel really enforces and this code really verifies --
    ## rather than invisibly becoming no boundary at all.
    ##
    ## NOTE HOW THIS DIFFERS FROM THE ``host_id`` RULING. There the thing
    ## that failed was observation, which is advisory, so capture went off
    ## and admission carried on. Here the thing that fails IS the
    ## boundary, so "carry on without it" is not available; what is
    ## available is a smaller boundary, stated out loud.
    rendezvousShared
      ## The ``runquota`` group resolved. Directory ``0750``, socket
      ## ``0660``, group-gated, group equality verified.
    rendezvousSingleUser
      ## The group could not be resolved. Directory ``0700``, socket
      ## ``0600``, owner-only. Reported by ``rendezvousDegradationReport``.

  RendezvousPolicy* = object
    ## WHO the rendezvous must belong to, and HOW it must be moded. Carried
    ## as a value rather than read from constants at each call site so the
    ## daemon and the client verify the same thing against the same
    ## configuration, and so a test can state the configuration instead of
    ## having to be the account it names.
    ownerUid*: int64
      ## The uid ``runquotad`` runs as. THE CLIENT CHECK IS NOW ABOUT THIS
      ## AND NOT ABOUT ``getuid()``: a shared rendezvous is owned by the
      ## daemon, so a client asserting "owned by me" would refuse every
      ## correctly-deployed host and accept nothing else.
    groupGid*: int64
      ## The gid of ``groupName``, or -1 when the host has no such group.
      ## -1 means the group EQUALITY check cannot be made; the
      ## never-group-writable invariant still is, because it lives in the
      ## mode.
    groupName*: string
    directoryMode*: int
    socketMode*: int
    scope*: RendezvousScope
      ## ``rendezvousSingleUser`` EXACTLY WHEN ``groupGid < 0``. Carried as
      ## its own field rather than recomputed at each site so a caller
      ## cannot forget to ask, and so a test can assert which of the two a
      ## host is in without inferring it from a mode.

const statsTableSegmentName* = "stats-table"
  ## The published aggregate table lives beside the socket, in the same
  ## host-wide, daemon-owned rendezvous directory — because it is
  ## discovered the same way and by the same population. It does NOT go in
  ## the state directory: that holds durable identity, and this is a
  ## working set that may be dropped, resized or zeroed at any moment.

proc defaultStatsTablePath*(endpoint: Endpoint): string =
  ## Where the published aggregate table is, derived from the endpoint so
  ## the two cannot end up in different directories — a table published
  ## somewhere the clients of THIS daemon do not look is an unpublished
  ## table with extra moving parts, and it fails silently as a permanently
  ## cold cache.
  case endpoint.kind
  of endpointUnixSocket: parentDir(endpoint.path) / statsTableSegmentName
  of endpointNamedPipe, endpointUnsupported: ""

proc requiredSegmentMode*(scope: SegmentScope): int =
  ## The mode a segment of ``scope`` must be created with and verified at.
  ## Segment files themselves arrive with the shared-memory transport; this
  ## is the rule they adopt, kept beside the directory rule because the two
  ## are the same requirement applied to different objects.
  case scope
  of segmentPerUser: perUserSegmentMode
  of segmentHostWide: hostWideSegmentMode

proc segmentIsGroupReadable*(scope: SegmentScope): bool =
  (requiredSegmentMode(scope) and 0o040) != 0

proc modeText*(mode: int): string =
  if mode < 0: "unknown" else: toOct(mode, 4)

proc groupText*(policy: RendezvousPolicy): string =
  if policy.groupGid >= 0:
    policy.groupName & " (gid " & $policy.groupGid & ")"
  else:
    policy.groupName & " (no such group on this host)"

when defined(posix):
  proc lookupUserUid(name: string): int64 =
    if name.len == 0:
      return -1
    let entry = getpwnam(name.cstring)
    if entry == nil: -1 else: int64(entry.pw_uid)

  proc lookupGroupGid(name: string): int64 =
    ## By name, or by NUMERIC GID. The numeric form exists because a group
    ## can be real and unnamed to this process -- a host that has not
    ## created `runquota` yet, a directory-service lookup that is
    ## unavailable -- and "the group could not be resolved" must not be a
    ## quiet way to switch the group check off.
    if name.len == 0:
      return -1
    try:
      return int64(parseBiggestInt(name))
    except ValueError:
      discard
    let entry = getgrnam(name.cstring)
    if entry == nil: -1 else: int64(entry.gr_gid)

proc rendezvousPolicy*(): RendezvousPolicy =
  ## The configuration both halves verify against.
  ##
  ## ``ownerUid`` resolves, in order: an explicit
  ## ``RUNQUOTA_ENDPOINT_OWNER_UID``; the ``runquota`` account, when the
  ## host has one; this process's own uid. The last is the single-account
  ## development case, where the daemon and the client ARE the same person
  ## and "the daemon's uid" and "my uid" coincide -- which is why the
  ## fallback is not a hole: it never widens what is accepted beyond one
  ## uid.
  ##
  ## ``groupGid`` resolves ``RUNQUOTA_ENDPOINT_GROUP`` (default
  ## ``runquota``) by name or by numeric gid. A host without that group
  ## yields -1, AND THAT CHANGES THE SCOPE rather than merely skipping a
  ## check: the policy becomes ``rendezvousSingleUser``, ``0700``/``0600``,
  ## owner-only, and ``rendezvousDegradationReport`` says so. See
  ## ``RendezvousScope`` for why silently dropping the group comparison is
  ## the one answer that is not available.
  when defined(posix):
    let groupName = getEnv("RUNQUOTA_ENDPOINT_GROUP", defaultRendezvousGroup)
    var owner = -1'i64
    let ownerOverride = getEnv("RUNQUOTA_ENDPOINT_OWNER_UID")
    if ownerOverride.len > 0:
      try:
        owner = int64(parseBiggestInt(ownerOverride))
      except ValueError:
        owner = -1
    if owner < 0:
      owner = lookupUserUid(defaultRendezvousUser)
    if owner < 0:
      owner = int64(getuid())
    let gid = lookupGroupGid(groupName)
    if gid >= 0:
      RendezvousPolicy(
        ownerUid: owner,
        groupGid: gid,
        groupName: groupName,
        directoryMode: endpointDirectoryMode,
        socketMode: endpointSocketMode,
        scope: rendezvousShared
      )
    else:
      RendezvousPolicy(
        ownerUid: owner,
        groupGid: -1,
        groupName: groupName,
        directoryMode: singleUserEndpointDirectoryMode,
        socketMode: singleUserEndpointSocketMode,
        scope: rendezvousSingleUser
      )
  else:
    # Windows: named pipes, no directory and no mode. Reported as shared
    # because nothing has been degraded -- the kernel object namespace
    # carries its own ACL.
    RendezvousPolicy(
      ownerUid: -1, groupGid: -1, groupName: defaultRendezvousGroup,
      directoryMode: endpointDirectoryMode, socketMode: endpointSocketMode,
      scope: rendezvousShared
    )

proc rendezvousDegradationReport*(policy = rendezvousPolicy()): string =
  ## Empty EXACTLY when the endpoint is the shared, group-gated one.
  ##
  ## Non-empty is the whole point: the difference between "host-wide, and
  ## the group is what admits you" and "per-user, because this host has no
  ## such group" must be visible to whoever reads the daemon's output, not
  ## merely present in a comment. `runquotad` appends this to its listening
  ## line.
  case policy.scope
  of rendezvousShared: ""
  of rendezvousSingleUser:
    " (single-user mode: no group \"" & policy.groupName &
      "\" on this host, so the endpoint is owner-only -- directory " &
      modeText(policy.directoryMode) & ", socket " &
      modeText(policy.socketMode) &
      "; create the group and restart to serve every member of it)"

proc endpointDirectoryPermissions*(policy = rendezvousPolicy()):
    set[FilePermission] =
  ## The rendezvous directory's mode as a permission set, for callers that
  ## have to CREATE such a directory (fixtures, mostly). Derived from the
  ## shipped policy rather than written as a literal: the mode is ``0750``
  ## where a ``runquota`` group exists and ``0700`` where it does not, and
  ## anything hardcoding either one is green on one kind of host and red on
  ## the other.
  result = {}
  let mode = policy.directoryMode
  if (mode and 0o400) != 0: result.incl fpUserRead
  if (mode and 0o200) != 0: result.incl fpUserWrite
  if (mode and 0o100) != 0: result.incl fpUserExec
  if (mode and 0o040) != 0: result.incl fpGroupRead
  if (mode and 0o020) != 0: result.incl fpGroupWrite
  if (mode and 0o010) != 0: result.incl fpGroupExec
  if (mode and 0o004) != 0: result.incl fpOthersRead
  if (mode and 0o002) != 0: result.incl fpOthersWrite
  if (mode and 0o001) != 0: result.incl fpOthersExec

when defined(posix):
  proc inspectPath*(path: string; wantDirectory: bool; requiredMode: int;
                    expectedOwnerUid: int64; label: string;
                    expectedGroupGid = -1'i64): PathTrust =
    ## The single implementation of "is this path trustworthy", shared by
    ## the rendezvous directory and by segment files.
    ##
    ## CHECK ORDER IS LOAD-BEARING. Ownership is checked before mode, so a
    ## directory owned by another user is reported as an ownership problem
    ## even when its mode is also wrong. Were the mode checked first, a
    ## build with the ownership check removed would still refuse most
    ## foreign directories -- for the wrong reason -- and the ownership
    ## check would be untestable. Every real foreign-owned directory on
    ## Unix is ``0755``, which is what makes mode-first fatal here. The
    ## group check sits BETWEEN the two, with ownership and group -- the
    ## two identity facts -- ahead of the mode.
    ##
    ## ``requiredMode < 0`` means "no exact mode is specified": the path
    ## must still not be group- or other-writable, which is the invariant,
    ## but the caller has not committed to a single legal mode. Used for
    ## a state directory an operator named explicitly, where the exact mode
    ## is their decision and "somebody else can replace what lives there"
    ## is still not.
    result = PathTrust(reason: trustOk, path: path, mode: -1, ownerUid: -1,
                       groupGid: -1, message: "")
    if path.len == 0:
      result.reason = trustMissing
      result.message = "runquota " & label & ": no path was given"
      return
    var info: Stat
    # `lstat`, not `stat`: following a symlink would check the mode of
    # whatever it points at while the daemon binds through the link.
    if lstat(path.cstring, info) != 0:
      let code = errno
      if code == ENOENT or code == ENOTDIR:
        result.reason = trustMissing
        result.message = "runquota " & label & " " & path & ": does not exist"
      else:
        result.reason = trustUnreadable
        result.message = "runquota " & label & " " & path &
          ": cannot be inspected (errno " & $code & ")"
      return
    result.mode = int(info.st_mode) and 0o7777
    result.ownerUid = int64(info.st_uid)
    result.groupGid = int64(info.st_gid)
    let isDirectory = S_ISDIR(info.st_mode)
    let isRegular = S_ISREG(info.st_mode)
    if (wantDirectory and not isDirectory) or
        ((not wantDirectory) and not isRegular):
      result.reason = trustWrongType
      result.message = "runquota " & label & " " & path & ": mode " &
        modeText(result.mode) & " is not a " &
        (if wantDirectory: "directory" else: "regular file") &
        "; refusing to use it as a rendezvous path"
      return
    if result.ownerUid != expectedOwnerUid:
      result.reason = trustForeignOwner
      result.message = "runquota " & label & " " & path &
        ": refusing a path owned by uid " & $result.ownerUid &
        " with mode " & modeText(result.mode) &
        "; this process runs as uid " & $expectedOwnerUid &
        ", and a rendezvous point another user owns is a rendezvous point " &
        "another user controls"
      return
    if expectedGroupGid >= 0 and result.groupGid != expectedGroupGid:
      # THE GROUP IS THE ADMISSION BOUNDARY, so a wrong one is not
      # cosmetic. Too narrow and the daemon is unreachable by the users it
      # exists to bound; too wide and the wrong population may participate.
      # Either way the kernel is enforcing a different rule from the one
      # that was configured, which is precisely what must not be assumed.
      result.reason = trustForeignGroup
      result.message = "runquota " & label & " " & path &
        ": refusing a path in group gid " & $result.groupGid &
        " with mode " & modeText(result.mode) &
        "; the configured group is gid " & $expectedGroupGid &
        ", and group membership is what the kernel admits callers by"
      return
    let writable = (result.mode and 0o022) != 0
    if requiredMode < 0:
      # No exact mode demanded, but the invariant is not negotiable.
      if writable:
        result.reason = trustBadMode
        result.message = "runquota " & label & " " & path &
          ": refusing mode " & modeText(result.mode) &
          "; it is group- or world-writable, so another user can replace " &
          "what lives there"
        return
    elif result.mode != requiredMode:
      result.reason = trustBadMode
      result.message = "runquota " & label & " " & path &
        ": refusing mode " & modeText(result.mode) & ", required " &
        modeText(requiredMode) &
        (if writable:
          "; it is group- or world-writable, so another user can replace " &
            "what lives there"
        else:
          "; the mode was not verified as created and MUST NOT be assumed")
      return

proc endpointDirectoryTrust*(endpoint: Endpoint;
                             policy = rendezvousPolicy()): PathTrust =
  ## Whether the directory the endpoint's socket lives in may be used.
  ## ``trustMissing`` is reported rather than refused: the daemon is about
  ## to create it with an explicit mode, and a client gets an ordinary
  ## connect failure.
  ##
  ## THE PREDICATE'S SHAPE CHANGED WITH THE ENDPOINT. It used to assert
  ## ``owner == getuid()`` and ``mode == 0700``, which was coherent while
  ## the rendezvous was per-user and is exactly backwards now: a shared
  ## rendezvous is owned by the DAEMON, and a client demanding it be owned
  ## by itself would refuse every correctly-deployed host. What is asserted
  ## instead is the daemon's configured uid, the configured group, and --
  ## the invariant that survives both -- never group- or other-writable.
  case endpoint.kind
  of endpointUnixSocket:
    when defined(posix):
      inspectPath(parentDir(endpoint.path), wantDirectory = true,
        requiredMode = policy.directoryMode,
        expectedOwnerUid = policy.ownerUid,
        label = "endpoint directory",
        expectedGroupGid = policy.groupGid)
    else:
      PathTrust(reason: trustOk, path: "", mode: -1, ownerUid: -1,
                groupGid: -1, message: "")
  of endpointNamedPipe, endpointUnsupported:
    # Windows: named pipes live in the kernel object namespace, so there is
    # no directory to own and no mode to widen.
    PathTrust(reason: trustOk, path: "", mode: -1, ownerUid: -1, groupGid: -1,
              message: "")

proc segmentTrust*(path: string; scope: SegmentScope;
                   expectedOwnerUid = -1'i64): PathTrust =
  ## Whether a shared-memory segment file may be mapped. Exposed now, and
  ## deliberately not called from anywhere yet, so the segments the
  ## shared-memory transport introduces adopt this rule instead of growing
  ## a second one.
  ##
  ## PER-USER STATE DOES NOT FOLLOW THE RENDEZVOUS, and this proc is where
  ## that is enforced. The rendezvous directory became group-traversable
  ## and its socket group-writable; the budget segment and the observation
  ## ring did NOT. So no ``RendezvousPolicy`` reaches this code: the owner
  ## is the calling user, the group is not consulted at all, and the mode
  ## comes from ``requiredSegmentMode``.
  when defined(posix):
    let owner =
      if expectedOwnerUid >= 0: expectedOwnerUid else: int64(getuid())
    inspectPath(path, wantDirectory = false,
      requiredMode = requiredSegmentMode(scope),
      expectedOwnerUid = owner,
      label = "segment")
  else:
    PathTrust(reason: trustOk, path: path, mode: -1, ownerUid: -1, groupGid: -1,
              message: "")

proc endpointDirectoryRefusal*(endpoint: Endpoint;
                               policy = rendezvousPolicy()): string =
  ## The refusal message, or the empty string when the directory is
  ## trustworthy or simply not there yet.
  let trust = endpointDirectoryTrust(endpoint, policy)
  if trust.reason in {trustOk, trustMissing}: "" else: trust.message

proc requireTrustedEndpointDir*(endpoint: Endpoint;
                                policy = rendezvousPolicy()) =
  let refusal = endpointDirectoryRefusal(endpoint, policy)
  if refusal.len > 0:
    raise newException(EndpointTrustError, refusal)

proc defaultEndpoint*(): Endpoint =
  let overridePath = getEnv("RUNQUOTA_SOCKET")
  if overridePath.len > 0:
    return endpointForPath(overridePath)
  when defined(posix):
    # A FIXED SYSTEM PATH, AND NOTHING CALLER-DERIVED IN IT.
    #
    # This used to be `<XDG_RUNTIME_DIR or TMPDIR>/runquota-$UID`, and the
    # `$UID` is the whole defect: user B did not fail to reach user A's
    # daemon, B COMPUTED A DIFFERENT PATH, found nothing, and started a
    # second daemon. Two daemons then admitted against their own view of
    # one machine's budget, which is RunQuota's primary mission failing in
    # the case it was built for -- and it failed SILENTLY, because both
    # users saw a working system.
    #
    # `XDG_RUNTIME_DIR` was not merely a bad default, it is unusable here
    # by construction: it is per-user `0700` by definition, so no fixed
    # path inside it can be shared.
    unixEndpoint(hostWideEndpointDir / endpointSocketName)
  elif defined(windows):
    # Windows: named pipes don't need a parent directory and live in the
    # NPFS namespace, so just return the canonical per-user path.
    namedPipeEndpoint(defaultWindowsPipePath())
  else:
    Endpoint(kind: endpointUnsupported, path: "")

proc provisionEndpointDirCommand*(directory: string;
                                  policy = rendezvousPolicy()): string =
  ## The exact command an operator runs on a host the install step has not
  ## reached. Named in the refusal itself, for the same reason the
  ## host-state refusal names its own: an operator left to guess creates
  ## the directory as whoever is logged in, which is the failure the rule
  ## exists to prevent.
  when defined(posix):
    "sudo mkdir -p " & directory & " && sudo chown " & $policy.ownerUid &
      ":" & policy.groupName & " " & directory & " && sudo chmod " &
      modeText(policy.directoryMode) & " " & directory
  else:
    "mkdir " & directory

when defined(posix):
  proc createRendezvousDirTree(path: string; policy: RendezvousPolicy) =
    ## Creates every missing component with an EXPLICIT mode, and puts the
    ## configured group on the components it created.
    ##
    ## ``mkdir(2)``'s mode argument is still masked by the umask, so a
    ## component this call created is chmod'ed to exactly the policy mode
    ## afterwards. A component that already existed is left alone and left
    ## to the verification that follows: silently tightening a directory
    ## somebody else made would turn the refusal this whole section is
    ## about into a repair.
    if path.len == 0 or path == "/":
      return
    var missing: seq[string] = @[]
    var walk = path
    while walk.len > 0 and walk != "/" and not dirExists(walk):
      missing.add(walk)
      let parent = parentDir(walk)
      if parent == walk:
        break
      walk = parent
    for i in countdown(missing.high, 0):
      let component = missing[i]
      if mkdir(component.cstring, Mode(policy.directoryMode)) != 0:
        if errno != EEXIST:
          raise newException(OSError,
            "runquota endpoint directory " & component &
              ": cannot create (errno " & $errno & ")")
      else:
        if policy.groupGid >= 0:
          # -1 as the uid leaves the owner alone; only the group moves.
          discard chown(component.cstring, cast[Uid](-1'i32),
                        Gid(policy.groupGid))
        discard chmod(component.cstring, Mode(policy.directoryMode))

  proc applySocketMode*(path: string; policy: RendezvousPolicy) =
    ## ``0660``, group ``runquota``, applied to the bound socket.
    ##
    ## The socket's own mode is belt to the directory's braces: some
    ## kernels enforce it on ``connect(2)`` and some historically did not,
    ## so the directory's search bit is what the non-member refusal
    ## actually rests on. Setting both means the boundary does not depend
    ## on which kernel this is.
    if policy.groupGid >= 0:
      discard chown(path.cstring, cast[Uid](-1'i32), Gid(policy.groupGid))
    discard chmod(path.cstring, Mode(policy.socketMode))

proc ensureEndpointDir*(endpoint: Endpoint; policy = rendezvousPolicy()) =
  ## Creates the rendezvous directory with an explicit mode and then
  ## VERIFIES it. Both halves are required: creating it correctly says
  ## nothing about a directory that was already there when we arrived.
  ##
  ## THE FIXED HOST-WIDE PATH IS NOT CREATED HERE. It is provisioned by the
  ## install step, exactly like the host-wide state directory and for the
  ## same reason: a path any caller can create is a path any caller can
  ## create DIFFERENTLY, with whatever owner and group the first starter
  ## happened to have -- and a rendezvous whose group is whoever started
  ## the daemon is a rendezvous with the wrong admission list. A path an
  ## operator named explicitly (``--socket``) is their decision and is
  ## still created on demand.
  case endpoint.kind
  of endpointUnixSocket:
    if endpoint.path.len > 0:
      let directory = parentDir(endpoint.path)
      when defined(posix):
        if directory == hostWideEndpointDir and not dirExists(directory):
          raise newException(EndpointTrustError,
            "runquota endpoint directory " & directory &
              ": does not exist. It is created by the RunQuota install " &
              "step, never by the daemon; provision it with: " &
              provisionEndpointDirCommand(directory, policy))
        createRendezvousDirTree(directory, policy)
      else:
        createDir(directory)
      requireTrustedEndpointDir(endpoint, policy)
  of endpointNamedPipe, endpointUnsupported:
    # Windows: named pipes live in the kernel object namespace; no fs dir.
    discard

when defined(windows):
  proc raiseLastWinError(prefix: string) =
    raise newException(OSError, prefix & ": Windows error " & $osLastError().int32)

  proc createServerPipe(name: string; first: bool): WinHandle =
    # Windows: per CreateNamedPipeW, FILE_FLAG_FIRST_PIPE_INSTANCE (0x80000) is
    # required on the first instance to detect path collisions. Subsequent
    # instances must omit it. We also reject remote clients for security.
    var openMode = PIPE_ACCESS_DUPLEX_W
    if first:
      openMode = openMode or 0x00080000'i32  # FILE_FLAG_FIRST_PIPE_INSTANCE
    let mode = PIPE_TYPE_BYTE_W or PIPE_READMODE_BYTE_W or PIPE_WAIT_W or
      PIPE_REJECT_REMOTE_CLIENTS_W
    result = createNamedPipeW(
      newWideCString(name),
      openMode,
      mode,
      PIPE_UNLIMITED_INSTANCES,
      DefaultPipeBufferSize,
      DefaultPipeBufferSize,
      0'i32,
      nil
    )
    if result == INVALID_HANDLE_VALUE:
      raiseLastWinError("CreateNamedPipeW failed for " & name)

  proc connectClient(handle: WinHandle): bool =
    # Windows: ConnectNamedPipe returns 0 with last-error ERROR_PIPE_CONNECTED
    # when the client raced ahead and is already on the pipe. Both outcomes
    # mean "ready to use".
    let rc = connectNamedPipe(handle, nil)
    if rc != 0:
      return true
    let err = osLastError().int32
    if err == ERROR_PIPE_CONNECTED:
      return true
    false

proc connectEndpoint*(endpoint: Endpoint): LocalConnection =
  case endpoint.kind
  of endpointUnixSocket:
    when defined(windows):
      raise newException(OSError, "Unix-socket endpoints are not supported on Windows")
    else:
      # EVERY CLIENT ATTACH, not only every daemon start. `getpeereid` below
      # validates who CONNECTS; this validates the path they connect
      # through, and a client that skipped it would happily hand its
      # requests to a socket another user planted.
      requireTrustedEndpointDir(endpoint)
      var socket = newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_NONE)
      # A session holds this socket open across `runWithLease`, i.e. across the
      # fork+exec of the leased command. Close-on-exec keeps the daemon
      # connection out of the child, where a reproducibility monitor would read
      # it as opaque external input. `std/net` offers no way to pass
      # SOCK_CLOEXEC to `socket(2)`, so this is the earliest point available.
      setCloseOnExec(cint(socket.getFd()))
      socket.connectUnix(endpoint.path)
      LocalConnection(kind: endpointUnixSocket, socket: socket, endpoint: endpoint)
  of endpointNamedPipe:
    when defined(windows):
      # Windows: open the pipe with read+write access. If the server is
      # accepting another client right now (all instances busy), the call
      # would fail with ERROR_PIPE_BUSY; we wait briefly and retry.
      let wide = newWideCString(endpoint.path)
      var handle: WinHandle = INVALID_HANDLE_VALUE
      for attempt in 0 ..< 5:
        handle = createFileW(
          wide,
          GENERIC_READ_W or GENERIC_WRITE_W,
          0'i32,
          nil,
          OPEN_EXISTING_W,
          0'i32,
          0
        )
        if handle != INVALID_HANDLE_VALUE:
          break
        let err = osLastError().int32
        if err == 231'i32:  # Windows: ERROR_PIPE_BUSY
          discard waitNamedPipeW(wide, NMPWAIT_USE_DEFAULT_WAIT)
          continue
        raiseLastWinError("CreateFileW failed for " & endpoint.path)
      if handle == INVALID_HANDLE_VALUE:
        raise newException(OSError, "could not open named pipe " & endpoint.path)
      LocalConnection(kind: endpointNamedPipe, pipeHandle: int(handle), endpoint: endpoint)
    else:
      raise newException(OSError, "named-pipe endpoints are only supported on Windows")
  else:
    raise newException(OSError, "unsupported RunQuota endpoint")

proc connectDefault*(): LocalConnection =
  connectEndpoint(defaultEndpoint())

proc bindEndpoint*(endpoint: Endpoint): LocalListener =
  case endpoint.kind
  of endpointUnixSocket:
    when defined(windows):
      raise newException(OSError, "Unix-socket endpoints are not supported on Windows")
    else:
      let policy = rendezvousPolicy()
      ensureEndpointDir(endpoint, policy)
      if fileExists(endpoint.path):
        removeFile(endpoint.path)
      var socket = newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_NONE)
      setCloseOnExec(cint(socket.getFd()))
      socket.bindUnix(endpoint.path)
      # 0660, group `runquota`: a member may connect, a non-member is
      # refused by the filesystem rather than by anything this process
      # runs.
      applySocketMode(endpoint.path, policy)
      socket.listen()
      LocalListener(kind: endpointUnixSocket, socket: socket, endpoint: endpoint)
  of endpointNamedPipe:
    when defined(windows):
      # Windows: pre-create the first pipe instance so the listener has an
      # instance ready for the very first accept call.
      let handle = createServerPipe(endpoint.path, first = true)
      LocalListener(
        kind: endpointNamedPipe,
        pendingPipeHandle: int(handle),
        endpoint: endpoint
      )
    else:
      raise newException(OSError, "named-pipe endpoints are only supported on Windows")
  else:
    raise newException(OSError, "unsupported RunQuota endpoint")

proc acceptConnection*(listener: var LocalListener): LocalConnection =
  case listener.kind
  of endpointUnixSocket:
    when defined(windows):
      raise newException(OSError, "Unix-socket endpoints are not supported on Windows")
    else:
      var client: owned(Socket)
      listener.socket.accept(client)
      # `accept(2)` never inherits the listener's CLOEXEC flag, so the accepted
      # descriptor has to be marked separately.
      setCloseOnExec(cint(client.getFd()))
      LocalConnection(kind: endpointUnixSocket, socket: client, endpoint: listener.endpoint)
  of endpointNamedPipe:
    when defined(windows):
      # Windows: ConnectNamedPipe on the pre-created instance, then pre-create
      # the next instance so the next accept call is ready to go.
      let activeHandle = WinHandle(listener.pendingPipeHandle)
      if not connectClient(activeHandle):
        raiseLastWinError("ConnectNamedPipe failed")
      let nextHandle = createServerPipe(listener.endpoint.path, first = false)
      listener.pendingPipeHandle = int(nextHandle)
      LocalConnection(
        kind: endpointNamedPipe,
        pipeHandle: int(activeHandle),
        endpoint: listener.endpoint
      )
    else:
      raise newException(OSError, "named-pipe endpoints are only supported on Windows")
  else:
    raise newException(OSError, "unsupported RunQuota endpoint")

proc acceptNativeConnection*(listener: var LocalListener): AcceptedConnection =
  case listener.kind
  of endpointUnixSocket:
    when defined(windows):
      raise newException(OSError, "Unix-socket endpoints are not supported on Windows")
    else:
      let accepted = nativesockets.accept(listener.socket.getFd())
      if accepted[0] == osInvalidSocket:
        raiseOSError(osLastError())
      setCloseOnExec(cint(accepted[0]))
      AcceptedConnection(kind: endpointUnixSocket, handle: accepted[0])
  of endpointNamedPipe:
    when defined(windows):
      # Windows: accept by completing ConnectNamedPipe on the parked instance,
      # then pre-create the replacement.
      let activeHandle = WinHandle(listener.pendingPipeHandle)
      if not connectClient(activeHandle):
        raiseLastWinError("ConnectNamedPipe failed")
      let nextHandle = createServerPipe(listener.endpoint.path, first = false)
      listener.pendingPipeHandle = int(nextHandle)
      AcceptedConnection(kind: endpointNamedPipe, pipeHandle: int(activeHandle))
    else:
      raise newException(OSError, "named-pipe endpoints are only supported on Windows")
  else:
    raise newException(OSError, "unsupported RunQuota endpoint")

proc localConnection*(accepted: AcceptedConnection): LocalConnection =
  case accepted.kind
  of endpointUnixSocket:
    LocalConnection(
      kind: endpointUnixSocket,
      socket: newSocket(accepted.handle, AF_UNIX, SOCK_STREAM, IPPROTO_NONE),
      endpoint: Endpoint(kind: endpointUnixSocket, path: "")
    )
  of endpointNamedPipe:
    when defined(windows):
      LocalConnection(
        kind: endpointNamedPipe,
        pipeHandle: accepted.pipeHandle,
        endpoint: Endpoint(kind: endpointNamedPipe, path: "")
      )
    else:
      raise newException(OSError, "named-pipe endpoints are only supported on Windows")
  else:
    raise newException(OSError, "unsupported accepted connection")

when defined(windows):
  proc readPeerSidFromHandle(pipe: WinHandle; identity: var PeerIdentity) =
    # Windows: best-effort peer identity. We open the client's process for
    # token query only; if any step fails we leave the identity as
    # peerIdentityUnavailable. The textual SID is returned to callers so the
    # daemon can log it.
    var clientPid: int32 = 0
    if getNamedPipeClientProcessId(pipe, addr clientPid) == 0:
      return
    identity.processId = uint64(clientPid)
    identity.kind = peerIdentityProcess
    const PROCESS_QUERY_LIMITED_INFORMATION = 0x1000'i32
    let processHandle = openProcess(
      PROCESS_QUERY_LIMITED_INFORMATION,
      0'i32,
      int32(clientPid)
    )
    if processHandle == 0:
      return
    var tokenHandle: WinHandle = 0
    if openProcessToken(WinHandle(processHandle), TOKEN_QUERY_W, addr tokenHandle) == 0:
      discard closeHandleW(WinHandle(processHandle))
      return
    var needed: int32 = 0
    discard getTokenInformation(tokenHandle, TokenUserClass, nil, 0, addr needed)
    if needed <= 0:
      discard closeHandleW(tokenHandle)
      discard closeHandleW(WinHandle(processHandle))
      return
    var buffer = newString(needed)
    if getTokenInformation(
      tokenHandle, TokenUserClass, addr buffer[0], needed, addr needed) != 0:
      # Windows: TOKEN_USER layout is { SID_AND_ATTRIBUTES Sid; }; SID_AND_ATTRIBUTES
      # is { PSID Sid; DWORD Attributes; }. So the first pointer-sized field is
      # a pointer to the SID we want to stringify.
      let sidPtr = cast[ptr pointer](addr buffer[0])[]
      var stringSid: ptr uint16 = nil
      if convertSidToStringSidW(sidPtr, addr stringSid) != 0 and stringSid != nil:
        identity.sid = $cast[WideCString](stringSid)
        discard localFree(stringSid)
    discard closeHandleW(tokenHandle)
    discard closeHandleW(WinHandle(processHandle))

proc peerIdentity*(connection: LocalConnection): PeerIdentity =
  case connection.kind
  of endpointUnixSocket:
    when defined(macosx) or defined(freebsd) or defined(openbsd):
      var uid: Uid
      var gid: Gid
      if getpeereid(connection.socket.getFd(), addr uid, addr gid) == 0:
        return PeerIdentity(
          kind: peerIdentityUser,
          processId: 0'u64,
          userId: uint64(uid),
          groupId: uint64(gid),
          sid: ""
        )
    elif defined(linux):
      var credentials: LinuxPeerCred
      var credentialsLen = SockLen(sizeof(credentials))
      if getsockopt(
        connection.socket.getFd(),
        SOL_SOCKET,
        SoPeerCred,
        addr credentials,
        addr credentialsLen
      ) == 0:
        return PeerIdentity(
          kind: peerIdentityProcess,
          processId: uint64(credentials.pid),
          userId: uint64(credentials.uid),
          groupId: uint64(credentials.gid),
          sid: ""
        )
    PeerIdentity(
      kind: peerIdentityUnavailable,
      processId: 0'u64,
      userId: 0'u64,
      groupId: 0'u64,
      sid: ""
    )
  of endpointNamedPipe:
    when defined(windows):
      result = PeerIdentity(
        kind: peerIdentityUnavailable,
        processId: 0'u64,
        userId: 0'u64,
        groupId: 0'u64,
        sid: ""
      )
      readPeerSidFromHandle(WinHandle(connection.pipeHandle), result)
      return result
    else:
      PeerIdentity(
        kind: peerIdentityUnavailable,
        processId: 0'u64,
        userId: 0'u64,
        groupId: 0'u64,
        sid: ""
      )
  else:
    PeerIdentity(
      kind: peerIdentityUnavailable,
      processId: 0'u64,
      userId: 0'u64,
      groupId: 0'u64,
      sid: ""
    )

proc close*(connection: var LocalConnection) =
  case connection.kind
  of endpointUnixSocket:
    if connection.socket != nil:
      connection.socket.close()
      connection.socket = nil
  of endpointNamedPipe:
    when defined(windows):
      if connection.pipeHandle != 0:
        # Windows: FlushFileBuffers would wait for the client to drain; we
        # only need DisconnectNamedPipe semantics on the server side, but
        # this proc is also called on the client side, where CloseHandle
        # alone is correct. Calling CloseHandle on a disconnected pipe is
        # always safe.
        discard closeHandleW(WinHandle(connection.pipeHandle))
        connection.pipeHandle = 0
    else:
      discard
  else:
    discard

proc close*(listener: var LocalListener) =
  case listener.kind
  of endpointUnixSocket:
    if listener.socket != nil:
      listener.socket.close()
    if listener.endpoint.path.len > 0 and fileExists(listener.endpoint.path):
      removeFile(listener.endpoint.path)
  of endpointNamedPipe:
    when defined(windows):
      if listener.pendingPipeHandle != 0:
        discard closeHandleW(WinHandle(listener.pendingPipeHandle))
        listener.pendingPipeHandle = 0
    else:
      discard
  else:
    discard

when defined(windows):
  proc winReadExact(handle: WinHandle; size: int; data: var string): bool =
    data.setLen(size)
    var offset = 0
    while offset < size:
      var got: int32 = 0
      let want = int32(size - offset)
      let rc = readFile(handle, addr data[offset], want, addr got, nil)
      if rc == 0:
        let err = osLastError().int32
        if err == ERROR_BROKEN_PIPE:
          data.setLen(0)
          return false
        # Windows: any other I/O error is fatal for this connection.
        data.setLen(0)
        return false
      if got <= 0:
        data.setLen(0)
        return false
      offset += int(got)
    true

  proc winWriteAll(handle: WinHandle; data: string): bool =
    if data.len == 0:
      return true
    var offset = 0
    while offset < data.len:
      var wrote: int32 = 0
      let want = int32(data.len - offset)
      let rc = writeFile(handle, unsafeAddr data[offset], want, addr wrote, nil)
      if rc == 0 or wrote <= 0:
        return false
      offset += int(wrote)
    true

proc readExactSocket(socket: Socket; size: int; data: var string;
                     timeoutMs = 0): bool =
  ## Read exactly ``size`` bytes from ``socket``. When ``timeoutMs > 0`` the
  ## read is bounded by an absolute deadline: a blocking ``recv`` that would
  ## have to hit the kernel is first gated behind a ``poll(POLLIN)`` for the
  ## remaining budget, and the read fails (returns false) if the peer goes
  ## quiet. This is used ONLY for the client connection handshakes (Hello /
  ## RegisterSession / CloseSession): a runquota daemon that accepts the
  ## connection but never returns a complete frame — a wedged, stale, or
  ## protocol-incompatible daemon — would otherwise block the client forever
  ## in ``recv``. (Observed on macOS in the reprobuild dev-env exec suite,
  ## where a healthy-but-silent runquotad left ``repro exec`` wedged for hours
  ## because the handshake had no timeout, so the engine's documented
  ## ``fallbackToRunQuotaBypass`` degradation never engaged.) Long-running
  ## reads — the session grant stream, which may legitimately block waiting
  ## for capacity — pass ``timeoutMs == 0`` and keep the unbounded behaviour.
  ##
  ## CRITICAL: ``Socket`` is buffered (``newSocket`` defaults to
  ## ``buffered = true``). A single kernel ``recv`` for the frame header pulls
  ## the frame BODY into the socket's userspace buffer too, so the body read
  ## must NOT poll the raw fd — ``poll`` reports the kernel socket as having no
  ## data even though the bytes are already buffered in userspace, and the read
  ## would spuriously time out. Gate the poll on ``hasDataBuffered`` so we only
  ## wait on the kernel fd when Nim's userspace buffer is actually empty.
  data.setLen(0)
  var remaining = size
  let deadline =
    if timeoutMs > 0: epochTime() + timeoutMs.float / 1000.0
    else: 0.0
  while remaining > 0:
    when defined(posix):
      if deadline > 0.0 and not socket.hasDataBuffered():
        let remainingMs = int((deadline - epochTime()) * 1000.0)
        if remainingMs <= 0:
          return false
        let fd = socket.getFd()
        var fds = TPollfd(fd: cast[cint](fd), events: POLLIN, revents: 0)
        let rc = poll(addr(fds), Tnfds(1), cint(remainingMs))
        if rc <= 0:
          # rc == 0: timed out; rc < 0: poll() error. Either way the
          # handshake cannot make progress — fail rather than block.
          return false
    let part = socket.recv(remaining)
    if part.len == 0:
      return false
    data.add(part)
    remaining -= part.len
  true

proc sendFrame*(connection: var LocalConnection; frame: string) =
  case connection.kind
  of endpointUnixSocket:
    connection.socket.send(frame)
  of endpointNamedPipe:
    when defined(windows):
      if not winWriteAll(WinHandle(connection.pipeHandle), frame):
        raiseLastWinError("WriteFile on named pipe failed")
    else:
      raise newException(OSError, "named-pipe send is only supported on Windows")
  else:
    raise newException(OSError, "unsupported RunQuota connection")

proc readExact(connection: var LocalConnection; size: int; data: var string;
               timeoutMs = 0): bool =
  case connection.kind
  of endpointUnixSocket:
    readExactSocket(connection.socket, size, data, timeoutMs)
  of endpointNamedPipe:
    when defined(windows):
      winReadExact(WinHandle(connection.pipeHandle), size, data)
    else:
      false
  else:
    false

proc receiveFrame*(connection: var LocalConnection; frame: var RqspFrame;
                   frameDiagnostic: var Diagnostic; timeoutMs = 0): bool =
  ## Read one RQSP frame. ``timeoutMs > 0`` bounds each underlying read with an
  ## absolute deadline (see ``readExactSocket``); used for the quick control
  ## handshakes. ``timeoutMs == 0`` keeps the unbounded blocking behaviour for
  ## long-running reads such as the grant stream.
  frameDiagnostic = okDiagnostic()
  var headerBytes: string
  if not connection.readExact(int(RqspHeaderLen), headerBytes, timeoutMs):
    return false
  var header: FrameHeader
  if not decodeFrameHeader(headerBytes, header):
    frameDiagnostic = diagnostic(diagProtocol, "invalid RQSP frame header")
    return false
  if header.payloadLen > DefaultMaxFrameBytes:
    frame = RqspFrame(header: header, payload: "")
    frameDiagnostic = diagnostic(
      diagProtocol,
      "RQSP frame exceeds negotiated flow-control limit",
      "max_frame_bytes=" & $DefaultMaxFrameBytes
    )
    return false
  var payload: string
  if not connection.readExact(int(header.payloadLen), payload, timeoutMs):
    return false
  frame = RqspFrame(header: header, payload: payload)
  true

proc receiveFrame*(connection: var LocalConnection; frame: var RqspFrame;
                   timeoutMs = 0): bool =
  var frameDiagnostic = okDiagnostic()
  connection.receiveFrame(frame, frameDiagnostic, timeoutMs)
