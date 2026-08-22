## M13c: the scope rules themselves — the rendezvous directory's mode and
## ownership, the two DIFFERENT segment modes, and the host-wide identity
## path.
##
## NEGATIVE CONTROLS ARE THE GATE HERE. The happy path passes with or
## without the fix: a daemon that starts, a client that connects, and a
## directory that happens to be `0700` because the umask was `022` prove
## nothing at all about whether anything was checked. So every clause
## below is asserted as a REFUSAL, with the reason it was refused for, and
## the refusal is required to name the offending path and its mode rather
## than failing opaquely.
##
## No mocks. Real directories on the real filesystem, with real modes, and
## a really foreign-owned directory this host already has — the ownership
## clause cannot be forged by writing a fake uid into a stub, because a
## stub would be exactly as happy with the check removed.
##
## THE PER-USER RULE IS NOT UNIFORM, and a test that assumed it were would
## fail the correct implementation. The budget and observation-ring
## segments are per-user `0600`; the aggregate stats table is host-wide and
## group-readable BY DESIGN, because only the daemon writes it and a page
## no client can write cannot be used by one user to perturb another. The
## two are asserted in separate tests, from separate constants, so that a
## blanket "every segment is 0600" can never be what satisfies them.
##
## WHAT THIS FILE CANNOT DO ON A SINGLE-UID HOST is stated where it bites:
## the clause requiring two uids on one machine to resolve to the SAME
## `host_id` needs root or a container, and the single-uid substitute below
## is labelled as a substitute rather than passed off as the clause.

import std/[os, posix, strutils, unittest]

import runquota_ipc
import runquota_observation_store

proc scratchDir(name: string): string =
  # SHORT ON PURPOSE, and the arithmetic is the reason rather than taste.
  # Nim's `Sockaddr_un_path_length` is 92 on macOS and `toSockAddr` refuses
  # `path.len >= 92`, so 91 characters is the whole budget -- NOT the ~104
  # this used to say, which is the raw BSD `sun_path` size and 12 bytes
  # more than Nim will actually accept. A plain macOS `TMPDIR` is 49
  # characters before anything is appended; inside `nix develop` it is 21.
  # That gap is why a fixture can be over budget and still be green in the
  # sanctioned shell and in CI, which is exactly what happened here.
  #
  #   49 (TMPDIR) + 13 (this dir) + 3 (/ep) + 15 (/runquotad.sock) = 80
  result = getTempDir() / ("rq" & $getCurrentProcessId() & name)
  removeDir(result)
  createDir(result)
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})

proc modeOf(path: string): int =
  var info: Stat
  if lstat(path.cstring, info) != 0:
    return -1
  int(info.st_mode) and 0o7777

proc ownerOf(path: string): int64 =
  var info: Stat
  if lstat(path.cstring, info) != 0:
    return -1
  int64(info.st_uid)

proc foreignOwnedDirectory(): string =
  ## A directory this host already has that is owned by a uid other than
  ## ours AND is NOT group- or world-writable.
  ##
  ## Both halves matter. Foreign ownership is the thing under test; the
  ## absence of group/world write is what makes the ownership check the
  ## ONLY check that can refuse it, so a build with the ownership check
  ## removed stops refusing this path instead of refusing it for the wrong
  ## reason. `/usr` and `/` are root-owned `0755` on macOS and on Linux.
  for candidate in ["/usr", "/", "/etc", "/bin"]:
    var info: Stat
    if lstat(candidate.cstring, info) != 0:
      continue
    if not S_ISDIR(info.st_mode):
      continue
    if int64(info.st_uid) == int64(getuid()):
      continue
    if (int(info.st_mode) and 0o022) != 0:
      continue
    return candidate
  ""

suite "scope_boundary_rules_endpoint_directory":
  test "the endpoint directory is created 0700 by an explicit mode, not by the umask":
    # THE UMASK IS SET WIDE OPEN ON PURPOSE. `createDir` with no mode asks
    # for 0777 and gets whatever the umask leaves, so on a developer box
    # with umask 022 it lands on 0755 and the defect is invisible. Under
    # umask 0 an unfixed creation path produces a 0777 rendezvous
    # directory, which is the whole defect, in one line.
    let root = scratchDir("create")
    defer: removeDir(root)
    let dir = root / "ep"
    let saved = umask(Mode(0))
    try:
      ensureEndpointDir(unixEndpoint(dir / "runquotad.sock"))
    finally:
      discard umask(saved)
    check dirExists(dir)
    check modeOf(dir) == 0o700
    check ownerOf(dir) == int64(getuid())
    # And the directory it just made is one it will accept again, which is
    # what makes creation and verification one contract rather than two.
    check endpointDirectoryRefusal(unixEndpoint(dir / "runquotad.sock")) == ""

  test "a pre-created world-writable endpoint directory is REFUSED, and named":
    let root = scratchDir("world")
    defer: removeDir(root)
    let dir = root / "ep"
    createDir(dir)
    setFilePermissions(dir, {
      fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupWrite, fpGroupExec,
      fpOthersRead, fpOthersWrite, fpOthersExec})
    check modeOf(dir) == 0o777

    let trust = endpointDirectoryTrust(unixEndpoint(dir / "runquotad.sock"))
    check trust.reason == trustBadMode
    check trust.path == dir
    check trust.mode == 0o777
    # Named, not opaque: the offending path and the offending mode are both
    # in the message, and so is the mode that was required.
    check dir in trust.message
    check "0777" in trust.message
    check "0700" in trust.message
    check "group- or world-writable" in trust.message
    check endpointDirectoryRefusal(unixEndpoint(dir / "runquotad.sock")) ==
      trust.message

  test "a group-writable endpoint directory is REFUSED too":
    # 0770 is the mode a lax deployment reaches for when it wants "the
    # team" to share a build box. It is still a directory every member of
    # that group can plant a socket in.
    let root = scratchDir("group")
    defer: removeDir(root)
    let dir = root / "ep"
    createDir(dir)
    setFilePermissions(dir, {
      fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupWrite, fpGroupExec})
    check modeOf(dir) == 0o770
    let trust = endpointDirectoryTrust(unixEndpoint(dir / "runquotad.sock"))
    check trust.reason == trustBadMode
    check trust.mode == 0o770
    check "0770" in trust.message
    check "group- or world-writable" in trust.message

  test "a merely loose 0755 endpoint directory is REFUSED as well":
    # This is the one a lax umask produces, and it is the reason "mode is
    # verified" is not the same statement as "mode is not writable by
    # others". Nobody else can write here, and it is still refused,
    # because a mode that was never verified as created MUST NOT be
    # assumed.
    let root = scratchDir("loose")
    defer: removeDir(root)
    let dir = root / "ep"
    createDir(dir)
    setFilePermissions(dir, {
      fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
    check modeOf(dir) == 0o755
    let trust = endpointDirectoryTrust(unixEndpoint(dir / "runquotad.sock"))
    check trust.reason == trustBadMode
    check "0755" in trust.message
    check "0700" in trust.message

  test "an endpoint directory owned by another uid is REFUSED, as an OWNERSHIP problem":
    # THE ATTACK IS ON THE PATH, NOT ON THE CONNECTION. `getpeereid`
    # validates who connects; it cannot tell that the socket they are
    # connecting to sits in a directory somebody else owns and could have
    # planted. Both checks are needed and this is the one the peer check
    # does not make.
    let foreign = foreignOwnedDirectory()
    check foreign.len > 0
    if foreign.len > 0:
      check ownerOf(foreign) != int64(getuid())
      # Not group- or world-writable, so the MODE check cannot be what
      # refuses this. If it were, a build with the ownership check removed
      # would still refuse the path and the ownership check would be
      # untestable.
      check (modeOf(foreign) and 0o022) == 0

      let trust = endpointDirectoryTrust(unixEndpoint(foreign / "rq.sock"))
      check trust.path == foreign
      check trust.reason == trustForeignOwner
      check foreign in trust.message
      check ("owned by uid " & $ownerOf(foreign)) in trust.message
      check ("uid " & $getuid()) in trust.message
      check modeText(trust.mode) in trust.message

  test "a symlink at the rendezvous path is refused rather than followed":
    # Following it would check the mode of whatever it points at while the
    # daemon binds through the link, so the check would be reading a
    # different object from the one being used.
    let root = scratchDir("link")
    defer: removeDir(root)
    let real = root / "real"
    createDir(real)
    setFilePermissions(real, {fpUserRead, fpUserWrite, fpUserExec})
    let link = root / "ep"
    createSymlink(real, link)
    let trust = endpointDirectoryTrust(unixEndpoint(link / "runquotad.sock"))
    check trust.reason == trustWrongType
    check link in trust.message

  test "a directory that is not there yet is not a refusal":
    # The daemon is about to create it with an explicit mode, and a client
    # gets an ordinary connect failure. Refusing here would make the first
    # start of a daemon impossible.
    let root = scratchDir("absent")
    defer: removeDir(root)
    let dir = root / "not-yet"
    let trust = endpointDirectoryTrust(unixEndpoint(dir / "runquotad.sock"))
    check trust.reason == trustMissing
    check endpointDirectoryRefusal(unixEndpoint(dir / "runquotad.sock")) == ""

  test "connecting through a widened directory is REFUSED at attach time":
    # Verification happens on EVERY CLIENT ATTACH and not only at daemon
    # start: the directory was fine when the daemon bound and was widened
    # afterwards, which is precisely the window a start-only check leaves
    # open.
    let root = scratchDir("attach")
    defer: removeDir(root)
    let dir = root / "ep"
    let socketPath = dir / "runquotad.sock"
    var listener = bindEndpoint(unixEndpoint(socketPath))
    try:
      check modeOf(dir) == 0o700
      # A client attaches happily while the directory is still private.
      var ok = connectEndpoint(unixEndpoint(socketPath))
      ok.close()

      setFilePermissions(dir, {
        fpUserRead, fpUserWrite, fpUserExec,
        fpGroupRead, fpGroupWrite, fpGroupExec,
        fpOthersRead, fpOthersWrite, fpOthersExec})
      var refused = false
      var message = ""
      try:
        var late = connectEndpoint(unixEndpoint(socketPath))
        late.close()
      except EndpointTrustError as error:
        refused = true
        message = error.msg
      check refused
      check dir in message
      check "0777" in message
    finally:
      setFilePermissions(dir, {fpUserRead, fpUserWrite, fpUserExec})
      listener.close()

suite "scope_boundary_rules_segment_scopes":
  # THE THREE STRUCTURES DO NOT SHARE ONE RULE. These are separate tests
  # reading separate constants on purpose: a single blanket assertion over
  # "every segment" would either fail the correct implementation or, worse,
  # pass a wrong one that made the host-wide table unreadable.

  test "per-user segments are 0600":
    check requiredSegmentMode(segmentPerUser) == 0o600
    let root = scratchDir("peruser")
    defer: removeDir(root)
    let path = root / "budget.seg"
    writeFile(path, "x")
    setFilePermissions(path, {fpUserRead, fpUserWrite})
    check modeOf(path) == 0o600
    check segmentTrust(path, segmentPerUser).reason == trustOk

  test "a group- or world-writable per-user segment is REFUSED, and named":
    let root = scratchDir("segwide")
    defer: removeDir(root)
    for (perms, mode) in [
        ({fpUserRead, fpUserWrite, fpGroupRead, fpGroupWrite}, 0o660),
        ({fpUserRead, fpUserWrite, fpOthersRead, fpOthersWrite}, 0o606),
        ({fpUserRead, fpUserWrite, fpGroupRead, fpGroupWrite,
          fpOthersRead, fpOthersWrite}, 0o666)]:
      let path = root / ("ring-" & $mode & ".seg")
      writeFile(path, "x")
      setFilePermissions(path, perms)
      check modeOf(path) == mode
      let trust = segmentTrust(path, segmentPerUser)
      check trust.reason == trustBadMode
      check path in trust.message
      check modeText(mode) in trust.message
      check "0600" in trust.message
      check "group- or world-writable" in trust.message

  test "the host-wide stats table is group-readable and is NOT 0600":
    # BY DESIGN, and this is the clause a blanket per-segment 0600 would
    # break rather than enforce. Nothing but `runquotad` writes this table,
    # so it cannot be used by one user to perturb another; it is published
    # output, and every client must be able to read it or the zero-IPC
    # estimate becomes one account's privilege.
    check requiredSegmentMode(segmentHostWide) == 0o640
    check segmentIsGroupReadable(segmentHostWide)
    check (requiredSegmentMode(segmentHostWide) and 0o040) != 0

    let root = scratchDir("hostwide")
    defer: removeDir(root)
    let path = root / "stats.seg"
    writeFile(path, "x")
    setFilePermissions(path, {fpUserRead, fpUserWrite, fpGroupRead})
    check modeOf(path) == 0o640
    check segmentTrust(path, segmentHostWide).reason == trustOk

    # The same file at 0600 is REFUSED for the host-wide scope: a table no
    # second user can read is a table that has stopped being host-wide.
    setFilePermissions(path, {fpUserRead, fpUserWrite})
    check modeOf(path) == 0o600
    let tooTight = segmentTrust(path, segmentHostWide)
    check tooTight.reason == trustBadMode
    check "0600" in tooTight.message
    check "0640" in tooTight.message

  test "the host-wide rule is not the per-user rule":
    # Stated as its own assertion so that collapsing the two -- applying
    # 0600 uniformly -- fails HERE, visibly, rather than silently making
    # the stats table private and leaving every other assertion green.
    check requiredSegmentMode(segmentHostWide) !=
      requiredSegmentMode(segmentPerUser)
    check not segmentIsGroupReadable(segmentPerUser)
    check segmentIsGroupReadable(segmentHostWide)

  test "the host-wide table still refuses a group-WRITABLE mode":
    # Group-readable is the exception; group-writable is not. The reason
    # the table needs no isolation is that no client can write it.
    let root = scratchDir("hostwritable")
    defer: removeDir(root)
    let path = root / "stats.seg"
    writeFile(path, "x")
    setFilePermissions(path, {fpUserRead, fpUserWrite, fpGroupRead,
      fpGroupWrite})
    check modeOf(path) == 0o660
    let trust = segmentTrust(path, segmentHostWide)
    check trust.reason == trustBadMode
    check "0660" in trust.message
    check "group- or world-writable" in trust.message

  test "a segment owned by another uid is REFUSED":
    let foreign = foreignOwnedDirectory()
    check foreign.len > 0
    if foreign.len > 0:
      # A real regular file owned by another uid, inside it.
      var victim = ""
      for candidate in [foreign / "bin" / "sh", foreign / "sh",
                        "/bin/sh", "/usr/bin/env"]:
        if fileExists(candidate) and ownerOf(candidate) != int64(getuid()):
          victim = candidate
          break
      check victim.len > 0
      if victim.len > 0:
        let trust = segmentTrust(victim, segmentPerUser)
        check trust.reason == trustForeignOwner
        check victim in trust.message
        check ("owned by uid " & $ownerOf(victim)) in trust.message
        check modeText(trust.mode) in trust.message

suite "scope_boundary_rules_host_identity":
  test "host_id is read from a host-wide, daemon-owned path":
    let path = defaultHostIdentityFile()
    check path == hostWideStateDir / "host-id"
    check path.startsWith("/")
    # Nothing per-user may appear in it. A path under the home directory
    # is per-user by construction, and that is the defect: one machine
    # would present as one identity per account.
    check not path.startsWith(getHomeDir())
    check not path.contains(".local")
    check not path.contains("XDG")

  test "host_id does not move when the per-user environment does":
    ## SUBSTITUTE, AND LABELLED AS ONE. The gate's clause is two different
    ## uids on one host resolving to the same `host_id`, which needs root
    ## or a container; see the milestone report for that clause's status.
    ##
    ## What this asserts instead is the MECHANISM by which two uids used to
    ## diverge: `HOME`, `XDG_STATE_HOME` and `LOCALAPPDATA` are exactly the
    ## variables that differ between two users on one machine, and the
    ## per-user implementation read them. It is a weaker statement than the
    ## clause, and it is not a vacuous one — it goes red against the
    ## per-user path.
    let savedHome = getEnv("HOME")
    let savedState = getEnv("XDG_STATE_HOME")
    let savedLocal = getEnv("LOCALAPPDATA")
    let baseline = defaultHostIdentityFile()
    try:
      putEnv("HOME", "/home/alice")
      putEnv("XDG_STATE_HOME", "/home/alice/.local/state")
      putEnv("LOCALAPPDATA", r"C:\Users\alice\AppData\Local")
      let asAlice = defaultHostIdentityFile()
      putEnv("HOME", "/home/bob")
      putEnv("XDG_STATE_HOME", "/home/bob/.local/state")
      putEnv("LOCALAPPDATA", r"C:\Users\bob\AppData\Local")
      let asBob = defaultHostIdentityFile()
      check asAlice == asBob
      check asAlice == baseline
      check not asAlice.contains("alice")
      check not asBob.contains("bob")
    finally:
      putEnv("HOME", savedHome)
      if savedState.len > 0:
        putEnv("XDG_STATE_HOME", savedState)
      else:
        delEnv("XDG_STATE_HOME")
      if savedLocal.len > 0:
        putEnv("LOCALAPPDATA", savedLocal)
      else:
        delEnv("LOCALAPPDATA")

  test "two identity readers pointed at one host-wide file agree":
    ## The other half of the substitute: given ONE file, two independent
    ## resolutions produce one id rather than minting a second. That is the
    ## property the host-wide path buys and the per-user path destroys —
    ## the per-user path fails not by disagreeing about a shared file but
    ## by never sharing one.
    let root = scratchDir("identity")
    defer: removeDir(root)
    let shared = root / "host-id"
    let first = resolveHostIdentity(shared)
    check first.persisted
    check isOpaqueId(first.hostId, "host-")
    let second = resolveHostIdentity(shared)
    check second.hostId == first.hostId
    check second.path == first.path
