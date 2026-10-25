## M13d: the rendezvous is SHARED, lives at a FIXED path, and is reached
## through GROUP MEMBERSHIP.
##
## WHY THIS FILE EXISTS. M13c enforced the scope boundaries faithfully and
## then found several of its own gate clauses NOT EXPRESSIBLE, because the
## endpoint was `<runtime>/runquota-$UID/runquotad.sock` inside a `0700`
## directory. The failure that produces is worse than a second uid being
## locked out: the path was DERIVED FROM THE CALLER, so user B did not get
## `EACCES` -- B computed a DIFFERENT path, found nothing there, and
## started a daemon of their own. A host-wide daemon degraded silently into
## one daemon per user, which is exactly what the host-wide decision exists
## to prevent, and every check M13c added then guarded a boundary nothing
## could cross.
##
## NEGATIVE CONTROLS ARE THE GATE. A fixed path that resolves, a directory
## that verifies and a socket that binds all pass with or without this
## work. So the clauses below are written as refusals with the REASON they
## were refused for, and the caller-independence clause is written as a
## difference that must NOT appear when the caller's environment is
## changed underneath it.
##
## WHAT THIS FILE DELIBERATELY DOES NOT CLAIM: it is single-uid. "A uid in
## the group connects and a uid outside it cannot" is asserted in
## `tests/integration/t_shared_endpoint_second_uid.nim`, against a real
## second uid, because a single-uid run of that clause proves nothing.
##
## No mocks. Real directories, real modes, real groups this host already
## has, and a real bound socket.

import private_broker_owner
import std/[os, osproc, streams, strutils, unittest]
import daemon_endpoint

when defined(posix):
  import std/posix
  import runquota_process

import runquota_ipc

# Real re-executed children exercise the startup reader's OS pipe/EOF boundary.
# Their small explicit output protocol is the fixture under test, not a mock
# broker or a replacement for any daemon/kernel integration assertion.
when defined(posix):
  if paramCount() >= 2 and paramStr(1) == "--startup-reader-control":
    case paramStr(2)
    of "complete":
      doAssert paramCount() == 2
      echo "startup-one"
      echo "startup-two"
      echo "startup-three"
      quit(0)
    of "short":
      doAssert paramCount() == 2
      echo "owned-child-refusal"
      quit(7)
    of "waiting":
      doAssert paramCount() == 5
      let ready = paramStr(3)
      let release = paramStr(4)
      let parent = parseInt(paramStr(5))
      doAssert not fileExists(release)
      echo "owned-child-still-running"
      stdout.flushFile()
      # Publish readiness BEFORE EOF can wake the parent. EOF itself, not
      # this marker, proves every real stdout writer has closed.
      writeFile(ready, $getCurrentProcessId())
      stdout.close()
      stderr.close()
      while not fileExists(release):
        # A timed-out parent must not strand this owned control child.
        if int(getppid()) != parent: quit(9)
        sleep(10)
      quit(0)
    else:
      quit(8)


proc scratchDir(name: string): string =
  # SHORT ON PURPOSE. Nim's `Sockaddr_un_path_length` is 92 on macOS and
  # `toSockAddr` refuses `path.len >= 92`, so 91 characters is the whole
  # budget. A plain macOS `TMPDIR` is 49 characters before anything is
  # appended; inside `nix develop` it is 21, which is why an over-long
  # fixture is green in the sanctioned shell and fails nowhere anyone
  # looks.
  #
  #   49 (TMPDIR) + 12 (this dir) + 3 (/ep) + 7 (/d.sock) = 71
  result = getTempDir() / ("rq" & $getCurrentProcessId() & name)
  removeDir(result)
  createDir(result)
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})

# WHAT IS POSIX-ONLY HERE, AND WHY. Everything about the rendezvous
# DIRECTORY -- its creation, owner, group and mode, the socket's mode, and
# the group-resolved policy -- is POSIX-only by design: on Windows the
# endpoint is a named pipe with no directory, which `docs/database.md`
# §"Provisioning the host-wide state directory and the rendezvous" records
# as "— (named pipes)" with no owner, group or mode. Those cases are reported
# skipped on Windows. The fixed-endpoint cases have a Windows arm, and so do
# the per-user SEGMENT cases that put a mode on a file: a Windows segment's
# mode is the projection of its DACL onto owner / group / everybody else
# (`runquota_ipc/segment_mode`, and `RunQuota-Shared-Memory-Structures.md`
# §"Segment files and their mode on Windows"), so the same modes are set and
# the same refusals are required of the same `segmentTrust`.

template segmentFileCase(body: untyped) =
  ## The on-disk half of a segment case. POSIX modes where the kernel stores
  ## one; the DACL's projection on Windows. Anywhere else there is no segment
  ## to put a mode on, and the case FAILS rather than passing by doing
  ## nothing.
  when defined(posix) or defined(windows):
    body
  else:
    checkpoint("no segment-file mode on this platform")
    fail()

proc setMode(path: string; mode: int): bool =
  ## ``chmod(2)`` on POSIX; on Windows, the protected DACL that projects onto
  ## ``mode``. The same call the shipped code makes (`setSegmentFileMode`).
  when defined(posix):
    chmod(path.cstring, Mode(mode)) == 0
  else:
    setSegmentFileMode(path, mode)

when defined(posix):
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

  proc groupOf(path: string): int64 =
    var info: Stat
    if lstat(path.cstring, info) != 0:
      return -1
    int64(info.st_gid)

  proc myGroups(): seq[int64] =
    ## The caller's REAL kernel credential set. `getgroups(2)` and not
    ## `id -G`: `id` answers from the directory service and can list groups
    ## the process does not actually carry, and it is the process's
    ## credentials that decide a `connect(2)`.
    var buffer: array[0 .. 255, Gid]
    let count = getgroups(cint(buffer.len), addr buffer)
    for i in 0 ..< max(0, int(count)):
      result.add(int64(buffer[i]))

  proc policyFor(group: int64): RendezvousPolicy =
    ## The configuration a correctly-deployed host would have.
    ##
    ## NOTHING HERE CHGRPS ANYTHING, and that is a repair rather than a
    ## simplification. The first version of this file built its fixtures with
    ## `chown(path, -1, gid)`, which only a member of `gid` (or root) may do.
    ## It passed inside `nix develop`, where `TMPDIR` lives under
    ## `/private/tmp` and BSD group inheritance had ALREADY made the fixture
    ## group-`wheel`, so the chown was a no-op that trivially succeeded --
    ## and failed with EPERM outside the dev shell, where `TMPDIR` is
    ## group-`staff`. It would fail on Linux for a third reason: no setgid
    ## inheritance on `/tmp` at all. That is precisely the shape this file's
    ## header warns about for `Sockaddr_un_path_length`, reintroduced for
    ## group ownership.
    ##
    ## The repair is to notice that the POLICY IS DATA: a "wrong group" is an
    ## integer in this object, not a state the filesystem has to be talked
    ## into. So the directory keeps whatever group it was born with and the
    ## policy is written to match, or deliberately not to.
    RendezvousPolicy(
      ownerUid: int64(getuid()),
      groupGid: group,
      groupName: "runquota-fixture",
      directoryMode: endpointDirectoryMode,
      socketMode: endpointSocketMode,
      scope: rendezvousShared
    )

  proc makeDir(path: string; mode: int): string =
    createDir(path)
    check chmod(path.cstring, Mode(mode)) == 0
    path

  proc otherThan(gid: int64): int64 =
    ## A gid that is definitely not `gid`. It does not have to exist: what is
    ## under test is the COMPARISON between what the directory carries and
    ## what the policy names.
    if gid == 0: 1'i64 else: 0'i64

  proc systemDirectory(): string =
    ## A directory this process neither owns nor shares a group with, which
    ## every Unix has: `/usr` is root-owned and root-grouped on macOS and on
    ## Linux alike, and no unprivileged account is in gid 0.
    for candidate in ["/usr", "/", "/etc", "/bin"]:
      var info: Stat
      if lstat(candidate.cstring, info) != 0: continue
      if not S_ISDIR(info.st_mode): continue
      if int64(info.st_uid) == int64(getuid()): continue
      if int64(info.st_gid) in myGroups(): continue
      if (int(info.st_mode) and 0o022) != 0: continue
      return candidate
    ""

suite "shared_endpoint_fixed_path":
  test "the default endpoint is a FIXED system path with nothing caller-derived in it":
    # The client-side override would make this a statement about the
    # environment, not about the default.
    let savedOverride = getEnv("RUNQUOTA_SOCKET")
    delEnv("RUNQUOTA_SOCKET")
    defer:
      if savedOverride.len > 0: putEnv("RUNQUOTA_SOCKET", savedOverride)
    let path = defaultEndpoint().path
    when defined(windows):
      # The Windows form of the same fixed path: ONE pipe name for the
      # host. It used to be `\\.\pipe\runquota-$USERNAME`, the Windows form
      # of the same defect (see `windowsHostWideEndpointPath`).
      check path == windowsHostWideEndpointPath
      check path == r"\\.\pipe\runquota\runquotad"
      let user = getEnv("USERNAME")
      if user.len > 0:
        check user.toLowerAscii notin path.toLowerAscii
    else:
      check path == hostWideEndpointDir / endpointSocketName
      check path.startsWith("/")
      check path == "/var/run/runquota/runquotad.sock" or
        path == "/run/runquota/runquotad.sock"

    # THE DEFECT, STATED AS A PROPERTY. `runquota-$UID` is a uid rendered
    # into a path, so the path contained a digit. Nothing caller-derived
    # can survive this assertion, and it goes red against the pre-M13d
    # default on any host whose uid is not the empty string -- which is
    # every host.
    for ch in path:
      check not ch.isDigit()
    when defined(posix):
      check ($getuid()) notin path
    check "runquota-" notin path
    check not path.startsWith(getHomeDir())
    check getHomeDir() notin path

  test "the default endpoint does not move when the caller's environment does":
    ## THE DECIDING CONTROL, and it is repetition rather than shape: the
    ## variables changed below are exactly the ones that DIFFER BETWEEN TWO
    ## USERS on one machine, and the old default read every one of them.
    ## Two resolutions that disagree mean two users find two daemons.
    ##
    ## `USERNAME` and `LOCALAPPDATA` are the Windows members of that set --
    ## the old Windows default was `\\.\pipe\runquota-$USERNAME` -- and are
    ## varied on every platform, where they change nothing either.
    let savedRuntime = getEnv("XDG_RUNTIME_DIR")
    let savedTmp = getEnv("TMPDIR")
    let savedHome = getEnv("HOME")
    let savedUser = getEnv("USERNAME")
    let savedLocal = getEnv("LOCALAPPDATA")
    let savedOverride = getEnv("RUNQUOTA_SOCKET")
    delEnv("RUNQUOTA_SOCKET")
    let baseline = defaultEndpoint().path
    try:
      putEnv("XDG_RUNTIME_DIR", "/run/user/1000")
      putEnv("TMPDIR", "/tmp/alice")
      putEnv("HOME", "/home/alice")
      putEnv("USERNAME", "alice")
      putEnv("LOCALAPPDATA", r"C:\Users\alice\AppData\Local")
      let asAlice = defaultEndpoint().path
      putEnv("XDG_RUNTIME_DIR", "/run/user/1001")
      putEnv("TMPDIR", "/tmp/bob")
      putEnv("HOME", "/home/bob")
      putEnv("USERNAME", "bob")
      putEnv("LOCALAPPDATA", r"C:\Users\bob\AppData\Local")
      let asBob = defaultEndpoint().path
      check asAlice == asBob
      check asAlice == baseline
      check "alice" notin asAlice
      check "bob" notin asBob
    finally:
      if savedRuntime.len > 0: putEnv("XDG_RUNTIME_DIR", savedRuntime)
      else: delEnv("XDG_RUNTIME_DIR")
      if savedTmp.len > 0: putEnv("TMPDIR", savedTmp)
      else: delEnv("TMPDIR")
      putEnv("HOME", savedHome)
      if savedUser.len > 0: putEnv("USERNAME", savedUser)
      else: delEnv("USERNAME")
      if savedLocal.len > 0: putEnv("LOCALAPPDATA", savedLocal)
      else: delEnv("LOCALAPPDATA")
      if savedOverride.len > 0: putEnv("RUNQUOTA_SOCKET", savedOverride)

  test "the fixed endpoint directory is NOT created on demand":
    when defined(posix):
      ## Provisioned by the install step, exactly like the host-wide state
      ## directory and for a sharper reason: whichever process created it
      ## would decide its GROUP, and the group is the admission list for the
      ## whole managed-resource system on this host.
      ##
      ## The group is PINNED so the refusal is the SHARED deployment's,
      ## which is what an operator provisioning a host-wide daemon is being
      ## told to create. Left to the shipped default it would be whichever
      ## scope this particular host happens to resolve, and the assertion
      ## below would mean two different things on two machines.
      let saved = getEnv("RUNQUOTA_ENDPOINT_GROUP")
      putEnv("RUNQUOTA_ENDPOINT_GROUP", $int64(getgid()))
      defer:
        if saved.len > 0: putEnv("RUNQUOTA_ENDPOINT_GROUP", saved)
        else: delEnv("RUNQUOTA_ENDPOINT_GROUP")
      check rendezvousPolicy().scope == rendezvousShared
      if dirExists(hostWideEndpointDir):
        # A host that HAS been provisioned cannot express this clause; say
        # so rather than passing vacuously.
        echo "  (skipped: " & hostWideEndpointDir & " exists on this host)"
        check dirExists(hostWideEndpointDir)
      else:
        var raised = false
        var message = ""
        try:
          ensureEndpointDir(unixEndpoint(hostWideEndpointDir / endpointSocketName))
        except EndpointTrustError as error:
          raised = true
          message = error.msg
        check raised
        check hostWideEndpointDir in message
        check "install step" in message
        # It names the command, so an operator who hits this does not have
        # to go and find a runbook.
        check "mkdir -p " & hostWideEndpointDir in message
        check "chown" in message
        check "0750" in message
        check not dirExists(hostWideEndpointDir)

    else:
      skip()

when defined(posix):
  suite "shared_endpoint_group_boundary_rules":
    test "a correctly owned, correctly grouped 0750 directory is ACCEPTED":
      let root = scratchDir("okdir")
      defer: removeDir(root)
      let dir = makeDir(root / "ep", 0o750)
      check modeOf(dir) == 0o750
      let trust = endpointDirectoryTrust(unixEndpoint(dir / "d.sock"),
        policyFor(groupOf(dir)))
      check trust.reason == trustOk
      check trust.message == ""
      check trust.groupGid == groupOf(dir)

    test "the APPLICATION check does not refuse a legitimate non-member":
      ## THE CLAUSE THAT KEEPS THE REAL BOUNDARY TESTABLE. A caller who owns
      ## nothing here and is in none of these groups still gets `trustOk`,
      ## because the predicate compares the STAT against the POLICY and never
      ## reads the caller's own uid or group list. That is what leaves the
      ## `connect(2)` after it to be refused by the KERNEL. Were the
      ## predicate to consult the caller's membership it would fire first,
      ## the filesystem boundary would never be exercised, and a build with
      ## the mode set to `0777` would still look like it refused non-members.
      ##
      ## `/usr` is the fixture because every Unix has it, root owns it, root
      ## groups it, and no unprivileged account is in gid 0 -- so this is a
      ## genuine outsider's view WITHOUT needing a chgrp this process is not
      ## allowed to perform. The policy quotes the directory's own mode: what
      ## is under test here is the IDENTITY comparison, and the mode rule has
      ## its own clauses below.
      let foreign = systemDirectory()
      check foreign.len > 0
      if foreign.len > 0:
        check ownerOf(foreign) != int64(getuid())
        check groupOf(foreign) notin myGroups()
        let trust = endpointDirectoryTrust(unixEndpoint(foreign / "d.sock"),
          RendezvousPolicy(ownerUid: ownerOf(foreign),
            groupGid: groupOf(foreign), groupName: "runquota-fixture",
            directoryMode: modeOf(foreign), socketMode: endpointSocketMode,
            scope: rendezvousShared))
        check trust.reason == trustOk
        check trust.message == ""

    test "a directory in the WRONG group is REFUSED, and named":
      ## NO CHGRP. The directory keeps whatever group it was born with -- and
      ## what that is differs between `/private/tmp` (gid 0, by BSD
      ## inheritance), a private `/var/folders` `TMPDIR` (the caller's gid)
      ## and Linux `/tmp` (the caller's gid, no inheritance at all). The
      ## policy is written to disagree with whatever was found, so the clause
      ## means the same thing on every one of them.
      let root = scratchDir("wgroup")
      defer: removeDir(root)
      let dir = makeDir(root / "ep", 0o750)
      let actual = groupOf(dir)
      let configured = otherThan(actual)
      check configured != actual
      let trust = endpointDirectoryTrust(unixEndpoint(dir / "d.sock"),
        policyFor(configured))
      check trust.reason == trustForeignGroup
      check trust.path == dir
      check trust.groupGid == actual
      check dir in trust.message
      check ("gid " & $actual) in trust.message
      check ("gid " & $configured) in trust.message
      # The mode is correct, so the mode check cannot be what refused it.
      check trust.mode == 0o750
      check "0750" in trust.message

    test "OWNERSHIP is reported ahead of group and ahead of mode":
      ## CHECK ORDER IS LOAD-BEARING and this is the counterfactual for it.
      ## The path below is wrong in all three ways at once -- foreign owner,
      ## foreign group, wrong mode -- and must be reported as an OWNERSHIP
      ## problem. Every real foreign-owned directory on Unix is `0755`, so a
      ## mode-first order would refuse them all for the wrong reason and
      ## leave the ownership check untestable; a group-first order would do
      ## the same.
      let foreign = systemDirectory()
      check foreign.len > 0
      if foreign.len > 0:
        check ownerOf(foreign) != int64(getuid())
        check modeOf(foreign) != endpointDirectoryMode
        let wrongGroup = otherThan(groupOf(foreign))
        check groupOf(foreign) != wrongGroup
        let trust = endpointDirectoryTrust(unixEndpoint(foreign / "rq.sock"),
          policyFor(wrongGroup))
        check trust.reason == trustForeignOwner
        check ("owned by uid " & $ownerOf(foreign)) in trust.message

    test "group- or other-WRITABLE is refused whatever the group says":
      ## The invariant that survives the mode change. `0770` in the RIGHT
      ## group is the mode a lax deployment reaches for when it wants "the
      ## team" to share a build box, and it is still a directory every member
      ## of that group can plant a socket in.
      let root = scratchDir("wwide")
      defer: removeDir(root)
      for mode in [0o770, 0o777, 0o752, 0o756]:
        let dir = makeDir(root / ("ep" & $mode), mode)
        check modeOf(dir) == mode
        # The policy names the directory's OWN group, so nothing but the
        # mode can be what refuses it.
        let trust = endpointDirectoryTrust(unixEndpoint(dir / "d.sock"),
          policyFor(groupOf(dir)))
        check trust.reason == trustBadMode
        check modeText(mode) in trust.message
        check "group- or world-writable" in trust.message

    test "a merely loose 0755 rendezvous is refused as an unverified mode":
      let root = scratchDir("loose5")
      defer: removeDir(root)
      let dir = makeDir(root / "ep", 0o755)
      let trust = endpointDirectoryTrust(unixEndpoint(dir / "d.sock"),
        policyFor(groupOf(dir)))
      check trust.reason == trustBadMode
      check "0755" in trust.message
      check "0750" in trust.message
      check "MUST NOT be assumed" in trust.message

  suite "shared_endpoint_socket_mode":
    # THE GROUP IS CONFIGURED EXPLICITLY IN BOTH TESTS, because the shipped
    # default depends on whether this host has a `runquota` group and a
    # fixture that inherited that would assert one thing on a provisioned
    # host and another on a bare one. Each scope is pinned and asserted.

    test "with a group, the rendezvous is 0750 and the socket is 0660":
      let privateOwner = bindPrivateBrokerOwnerToCaller()
      defer: restorePrivateBrokerOwner(privateOwner)
      let saved = getEnv("RUNQUOTA_ENDPOINT_GROUP")
      putEnv("RUNQUOTA_ENDPOINT_GROUP", $int64(getgid()))
      defer:
        if saved.len > 0: putEnv("RUNQUOTA_ENDPOINT_GROUP", saved)
        else: delEnv("RUNQUOTA_ENDPOINT_GROUP")
      let root = scratchDir("sock")
      defer: removeDir(root)
      let dir = root / "ep"
      let socketPath = dir / "d.sock"
      check rendezvousPolicy().scope == rendezvousShared
      var listener = bindEndpoint(unixEndpoint(socketPath))
      try:
        var info: Stat
        check lstat(socketPath.cstring, info) == 0
        check S_ISSOCK(info.st_mode)
        check modeOf(socketPath) == 0o660
        # Never world-anything. A `0666` socket would connect for everybody
        # and satisfy every other clause in this file -- and on Darwin that
        # is not theoretical: the socket's own mode IS enforced on
        # `connect(2)`.
        check (modeOf(socketPath) and 0o007) == 0
        check groupOf(socketPath) == int64(getgid())
        check modeOf(dir) == 0o750
        check (modeOf(dir) and 0o007) == 0
        check groupOf(dir) == int64(getgid())
      finally:
        listener.close()

    test "with NO resolvable group, the rendezvous degrades to 0700 / 0600":
      let privateOwner = bindPrivateBrokerOwnerToCaller()
      defer: restorePrivateBrokerOwner(privateOwner)
      ## THE DECIDING CONTROL FOR THE NO-GROUP RULING, and the reason it is a
      ## bound socket rather than a comment: on a host with no `runquota`
      ## group the endpoint is owner-only and SAYS so, instead of keeping a
      ## group-traversable mode whose group nothing verified.
      let saved = getEnv("RUNQUOTA_ENDPOINT_GROUP")
      putEnv("RUNQUOTA_ENDPOINT_GROUP", "runquota-no-such-group-m13d")
      defer:
        if saved.len > 0: putEnv("RUNQUOTA_ENDPOINT_GROUP", saved)
        else: delEnv("RUNQUOTA_ENDPOINT_GROUP")
      let policy = rendezvousPolicy()
      check policy.scope == rendezvousSingleUser
      check policy.groupGid == -1
      check policy.directoryMode == 0o700
      check policy.socketMode == 0o600
      # The two scopes are DISTINGUISHABLE, and by more than a mode: the
      # report is what an operator reads.
      let report = rendezvousDegradationReport(policy)
      check report.len > 0
      check "single-user" in report
      check "runquota-no-such-group-m13d" in report
      check "owner-only" in report
      check "0700" in report
      check "0600" in report

      let root = scratchDir("sock1u")
      defer: removeDir(root)
      let dir = root / "ep"
      let socketPath = dir / "d.sock"
      var listener = bindEndpoint(unixEndpoint(socketPath))
      try:
        check modeOf(socketPath) == 0o600
        check modeOf(dir) == 0o700
        # NOT group-traversable. This is the whole difference: an endpoint
        # left at 0750 with the group check skipped would be reachable by
        # whatever group it inherited, which is a boundary nobody chose and
        # nothing verified.
        check (modeOf(dir) and 0o070) == 0
        check (modeOf(socketPath) and 0o077) == 0
      finally:
        listener.close()

    test "the two scopes are not the same policy, stated as an inequality":
      ## So that collapsing them -- resolving no group and carrying on with
      ## the shared modes -- fails HERE and visibly rather than by quietly
      ## producing an unverified boundary.
      check singleUserEndpointDirectoryMode != endpointDirectoryMode
      check singleUserEndpointSocketMode != endpointSocketMode
      check (singleUserEndpointDirectoryMode and 0o077) == 0
      check (singleUserEndpointSocketMode and 0o077) == 0
      check (endpointDirectoryMode and 0o040) != 0
      check (endpointSocketMode and 0o060) != 0

      let saved = getEnv("RUNQUOTA_ENDPOINT_GROUP")
      defer:
        if saved.len > 0: putEnv("RUNQUOTA_ENDPOINT_GROUP", saved)
        else: delEnv("RUNQUOTA_ENDPOINT_GROUP")
      putEnv("RUNQUOTA_ENDPOINT_GROUP", $int64(getgid()))
      let shared = rendezvousPolicy()
      putEnv("RUNQUOTA_ENDPOINT_GROUP", "runquota-no-such-group-m13d")
      let degraded = rendezvousPolicy()
      check shared.scope != degraded.scope
      check shared.directoryMode != degraded.directoryMode
      check shared.socketMode != degraded.socketMode
      check rendezvousDegradationReport(shared) == ""
      check rendezvousDegradationReport(degraded).len > 0
      # `endpointDirectoryPermissions` follows the scope, so a fixture that
      # asks for "the rendezvous mode" gets the right one on either host.
      check fpGroupExec in endpointDirectoryPermissions(shared)
      check fpGroupExec notin endpointDirectoryPermissions(degraded)

else:
  suite "shared_endpoint_group_boundary_rules":
    for name in [
        "a correctly owned, correctly grouped 0750 directory is ACCEPTED",
        "the APPLICATION check does not refuse a legitimate non-member",
        "a directory in the WRONG group is REFUSED, and named",
        "OWNERSHIP is reported ahead of group and ahead of mode",
        "group- or other-WRITABLE is refused whatever the group says",
        "a merely loose 0755 rendezvous is refused as an unverified mode"]:
      test name:
        skip()

  suite "shared_endpoint_socket_mode":
    for name in [
        "with a group, the rendezvous is 0750 and the socket is 0660",
        "with NO resolvable group, the rendezvous degrades to 0700 / 0600",
        "the two scopes are not the same policy, stated as an inequality"]:
      test name:
        skip()

suite "shared_endpoint_per_user_state_is_unaffected":
  # THE CLAUSE A CORRECT-LOOKING WIDENING WOULD DESTROY. Making the budget
  # segment and the observation ring group-accessible "for consistency"
  # with the rendezvous would satisfy every other assertion in this file
  # and remove the boundary they all exist to protect. So it is asserted
  # here, against the rendezvous constants, rather than left implied.

  test "per-user segments did NOT follow the rendezvous":
    check requiredSegmentMode(segmentPerUser) == 0o600
    check not segmentIsGroupReadable(segmentPerUser)
    # No group bits and no other bits AT ALL -- not merely "not writable".
    check (requiredSegmentMode(segmentPerUser) and 0o077) == 0
    # And they are a different rule from the rendezvous, stated as an
    # inequality so collapsing the two fails HERE and visibly.
    check requiredSegmentMode(segmentPerUser) != endpointDirectoryMode
    check requiredSegmentMode(segmentPerUser) != endpointSocketMode
    check endpointSocketMode == 0o660
    check endpointDirectoryMode == 0o750

  test "a per-user segment at the RENDEZVOUS modes is REFUSED":
    segmentFileCase:
      let root = scratchDir("segmode")
      defer: removeDir(root)
      for mode in [endpointSocketMode, 0o640, 0o660, 0o750]:
        let path = root / ("ring" & $mode & ".seg")
        writeFile(path, "x")
        check setMode(path, mode)
        let trust = segmentTrust(path, segmentPerUser)
        check trust.reason == trustBadMode
        check path in trust.message
        check "0600" in trust.message

  test "segment trust never consults the rendezvous group":
    ## Structural, and it is what stops a future "make it consistent"
    ## change from being invisible: a per-user segment whose group is the
    ## rendezvous group is still judged by the per-user rule, and a `0600`
    ## file in ANY group is accepted while a group-readable one in the same
    ## group is not.
    ## No chgrp: the file keeps whatever group it was born with, which
    ## differs by host and by `TMPDIR`, and the point is that the per-user
    ## rule does not care WHICH group it is.
    segmentFileCase:
      let root = scratchDir("seggrp")
      defer: removeDir(root)
      let path = root / "budget.seg"
      writeFile(path, "x")
      check setMode(path, 0o600)
      when defined(posix):
        check groupOf(path) >= 0
      else:
        # A Windows file's group is a SID in its security descriptor, the
        # counterpart of `st_gid`; it has one whether or not any entry of
        # the DACL names it.
        check readFileSecurity(path).group.len > 0
      check segmentTrust(path, segmentPerUser).reason == trustOk

      check setMode(path, 0o640)
      check segmentTrust(path, segmentPerUser).reason == trustBadMode

when defined(posix):
  suite "private_broker_owner_and_startup_controls":
    test "private owner scope restores absent, empty and configured values on error":
      let originalExists = existsEnv("RUNQUOTA_ENDPOINT_OWNER_UID")
      let originalValue = getEnv("RUNQUOTA_ENDPOINT_OWNER_UID")
      let groupExists = existsEnv("RUNQUOTA_ENDPOINT_GROUP")
      let groupValue = getEnv("RUNQUOTA_ENDPOINT_GROUP")
      defer:
        if originalExists: putEnv("RUNQUOTA_ENDPOINT_OWNER_UID", originalValue)
        else: delEnv("RUNQUOTA_ENDPOINT_OWNER_UID")
      for state in ["absent", "empty", "configured"]:
        case state
        of "absent": delEnv("RUNQUOTA_ENDPOINT_OWNER_UID")
        of "empty": putEnv("RUNQUOTA_ENDPOINT_OWNER_UID", "")
        else: putEnv("RUNQUOTA_ENDPOINT_OWNER_UID", "0")
        let beforeExists = existsEnv("RUNQUOTA_ENDPOINT_OWNER_UID")
        let beforeValue = getEnv("RUNQUOTA_ENDPOINT_OWNER_UID")
        var raised = false
        try:
          let privateOwner = bindPrivateBrokerOwnerToCaller()
          defer: restorePrivateBrokerOwner(privateOwner)
          check rendezvousPolicy().ownerUid == int64(getuid())
          check existsEnv("RUNQUOTA_ENDPOINT_GROUP") == groupExists
          check getEnv("RUNQUOTA_ENDPOINT_GROUP") == groupValue
          raise newException(ValueError, "owned scope exception control")
        except ValueError:
          raised = true
        check raised
        check existsEnv("RUNQUOTA_ENDPOINT_OWNER_UID") == beforeExists
        check getEnv("RUNQUOTA_ENDPOINT_OWNER_UID") == beforeValue
        block:
          let privateOwner = bindPrivateBrokerOwnerToCaller()
          defer: restorePrivateBrokerOwner(privateOwner)
          check rendezvousPolicy().ownerUid == int64(getuid())
        check existsEnv("RUNQUOTA_ENDPOINT_OWNER_UID") == beforeExists
        check getEnv("RUNQUOTA_ENDPOINT_OWNER_UID") == beforeValue

    test "default owner remains the real named account, or the actual caller":
      let originalExists = existsEnv("RUNQUOTA_ENDPOINT_OWNER_UID")
      let originalValue = getEnv("RUNQUOTA_ENDPOINT_OWNER_UID")
      defer:
        if originalExists: putEnv("RUNQUOTA_ENDPOINT_OWNER_UID", originalValue)
        else: delEnv("RUNQUOTA_ENDPOINT_OWNER_UID")
      delEnv("RUNQUOTA_ENDPOINT_OWNER_UID")
      let named = getpwnam("runquota")
      let expected = if named == nil: int64(getuid()) else: int64(named.pw_uid)
      check rendezvousPolicy().ownerUid == expected
      block:
        let privateOwner = bindPrivateBrokerOwnerToCaller()
        defer: restorePrivateBrokerOwner(privateOwner)
        check rendezvousPolicy().ownerUid == int64(getuid())
      check not existsEnv("RUNQUOTA_ENDPOINT_OWNER_UID")
      check rendezvousPolicy().ownerUid == expected
      putEnv("RUNQUOTA_ENDPOINT_OWNER_UID", "0")
      check rendezvousPolicy().ownerUid == 0

    test "owner refusal names the configured owner without claiming the caller uid":
      let root = scratchDir("ownerdiag")
      defer: removeDir(root)
      let dir = makeDir(root / "ep", 0o750)
      let foreign = systemDirectory()
      check foreign.len > 0
      if foreign.len > 0:
        let configured = ownerOf(foreign)
        check configured != int64(getuid())
        var policy = policyFor(groupOf(dir))
        policy.ownerUid = configured
        let trust = endpointDirectoryTrust(unixEndpoint(dir / "d.sock"), policy)
        check trust.reason == trustForeignOwner
        check trust.ownerUid == int64(getuid())
        check ("configured daemon owner uid " & $configured) in trust.message
        check "this process runs as uid" notin trust.message
        check ("owned by uid " & $int64(getuid())) in trust.message
        check "0750" in trust.message

    test "private caller policy restores both exact environment states":
      let ownerHad = existsEnv("RUNQUOTA_ENDPOINT_OWNER_UID")
      let ownerOld = getEnv("RUNQUOTA_ENDPOINT_OWNER_UID")
      let groupHad = existsEnv("RUNQUOTA_ENDPOINT_GROUP")
      let groupOld = getEnv("RUNQUOTA_ENDPOINT_GROUP")
      defer:
        try:
          if groupHad: putEnv("RUNQUOTA_ENDPOINT_GROUP", groupOld)
          else: delEnv("RUNQUOTA_ENDPOINT_GROUP")
        finally:
          if ownerHad: putEnv("RUNQUOTA_ENDPOINT_OWNER_UID", ownerOld)
          else: delEnv("RUNQUOTA_ENDPOINT_OWNER_UID")
      let root = scratchDir("policystates")
      defer: removeDir(root)
      let dir = makeDir(root / "ep", 0o750)
      let fixtureGid = privateEndpointGroup(dir)
      for ownerState in 0 .. 2:
        for groupState in 0 .. 2:
          if ownerState == 0: delEnv("RUNQUOTA_ENDPOINT_OWNER_UID")
          else: putEnv("RUNQUOTA_ENDPOINT_OWNER_UID", if ownerState == 1: "" else: "0")
          if groupState == 0: delEnv("RUNQUOTA_ENDPOINT_GROUP")
          else: putEnv("RUNQUOTA_ENDPOINT_GROUP", if groupState == 1: "" else: $otherThan(fixtureGid))
          let ownerBefore = getEnv("RUNQUOTA_ENDPOINT_OWNER_UID")
          let groupBefore = getEnv("RUNQUOTA_ENDPOINT_GROUP")
          block:
            let binding = bindPrivateBrokerPolicyToCaller(fixtureGid)
            defer: restorePrivateBrokerPolicy(binding)
            check rendezvousPolicy().ownerUid == int64(getuid())
            check rendezvousPolicy().groupGid == fixtureGid
          check existsEnv("RUNQUOTA_ENDPOINT_OWNER_UID") == (ownerState != 0)
          check getEnv("RUNQUOTA_ENDPOINT_OWNER_UID") == ownerBefore
          check existsEnv("RUNQUOTA_ENDPOINT_GROUP") == (groupState != 0)
          check getEnv("RUNQUOTA_ENDPOINT_GROUP") == groupBefore
          var raised = false
          try:
            let binding = bindPrivateBrokerPolicyToCaller(fixtureGid)
            defer: restorePrivateBrokerPolicy(binding)
            check rendezvousPolicy().ownerUid == int64(getuid())
            check rendezvousPolicy().groupGid == fixtureGid
            raise newException(ValueError, "private policy body exception")
          except ValueError:
            raised = true
          check raised
          check existsEnv("RUNQUOTA_ENDPOINT_OWNER_UID") == (ownerState != 0)
          check getEnv("RUNQUOTA_ENDPOINT_OWNER_UID") == ownerBefore
          check existsEnv("RUNQUOTA_ENDPOINT_GROUP") == (groupState != 0)
          check getEnv("RUNQUOTA_ENDPOINT_GROUP") == groupBefore
          # Match callers that defer restoration before endpoint setup. A
          # genuine missing endpoint fails before assignment, leaving the token
          # inactive; its deferred restore must leave inherited state intact.
          block:
            var unbound: PrivateBrokerCallerPolicyBinding
            defer: restorePrivateBrokerPolicy(unbound)
            expect OSError:
              unbound = bindPrivateBrokerPolicyToCaller(
                privateEndpointGroup(dir / "not-created"))
          check existsEnv("RUNQUOTA_ENDPOINT_OWNER_UID") == (ownerState != 0)
          check getEnv("RUNQUOTA_ENDPOINT_OWNER_UID") == ownerBefore
          check existsEnv("RUNQUOTA_ENDPOINT_GROUP") == (groupState != 0)
          check getEnv("RUNQUOTA_ENDPOINT_GROUP") == groupBefore
          # A real rejected setup argument must not mutate either variable.
          expect ValueError:
            discard bindPrivateBrokerPolicyToCaller(-1)
          check existsEnv("RUNQUOTA_ENDPOINT_OWNER_UID") == (ownerState != 0)
          check getEnv("RUNQUOTA_ENDPOINT_OWNER_UID") == ownerBefore
          check existsEnv("RUNQUOTA_ENDPOINT_GROUP") == (groupState != 0)
          check getEnv("RUNQUOTA_ENDPOINT_GROUP") == groupBefore

    test "private policy does not replace the real named default group":
      let groupHad = existsEnv("RUNQUOTA_ENDPOINT_GROUP")
      let groupOld = getEnv("RUNQUOTA_ENDPOINT_GROUP")
      defer:
        if groupHad: putEnv("RUNQUOTA_ENDPOINT_GROUP", groupOld)
        else: delEnv("RUNQUOTA_ENDPOINT_GROUP")
      delEnv("RUNQUOTA_ENDPOINT_GROUP")
      let named = getgrnam("runquota")
      let expected = if named == nil: -1'i64 else: int64(named.gr_gid)
      check rendezvousPolicy().groupGid == expected
      let root = scratchDir("policydefault")
      defer: removeDir(root)
      let dir = makeDir(root / "ep", 0o750)
      block:
        let binding = bindPrivateBrokerPolicyToCaller(privateEndpointGroup(dir))
        defer: restorePrivateBrokerPolicy(binding)
        check rendezvousPolicy().groupGid == groupOf(dir)
      check not existsEnv("RUNQUOTA_ENDPOINT_GROUP")
      check rendezvousPolicy().groupGid == expected

    test "private policy accepts the actual endpoint group and still refuses a foreign policy":
      let root = scratchDir("policyactual")
      defer: removeDir(root)
      let dir = makeDir(root / "ep", 0o750)
      let fixtureGid = privateEndpointGroup(dir)
      let endpoint = unixEndpoint(dir / "d.sock")
      let groupHad = existsEnv("RUNQUOTA_ENDPOINT_GROUP")
      let groupOld = getEnv("RUNQUOTA_ENDPOINT_GROUP")
      defer:
        if groupHad: putEnv("RUNQUOTA_ENDPOINT_GROUP", groupOld)
        else: delEnv("RUNQUOTA_ENDPOINT_GROUP")
      let foreignGid = otherThan(fixtureGid)
      putEnv("RUNQUOTA_ENDPOINT_GROUP", $foreignGid)
      block:
        # Owner-only selection intentionally preserves the inherited wrong
        # group. The same real endpoint therefore refuses before opt-in.
        let ownerOnly = bindPrivateBrokerOwnerToCaller()
        defer: restorePrivateBrokerOwner(ownerOnly)
        check rendezvousPolicy().groupGid == foreignGid
        check endpointDirectoryTrust(endpoint).reason == trustForeignGroup
      block:
        let binding = bindPrivateBrokerPolicyToCaller(fixtureGid)
        defer: restorePrivateBrokerPolicy(binding)
        check endpointDirectoryTrust(endpoint).reason == trustOk
        let wrong = policyFor(foreignGid)
        check endpointDirectoryTrust(endpoint, wrong).reason == trustForeignGroup
        var listener = bindEndpoint(endpoint)
        try:
          check modeOf(dir) == 0o750
          check groupOf(dir) == fixtureGid
          check modeOf(dir / "d.sock") == 0o660
          check groupOf(dir / "d.sock") == fixtureGid
          var client = connectEndpoint(endpoint)
          client.close()
        finally:
          listener.close()
      check existsEnv("RUNQUOTA_ENDPOINT_GROUP")
      check getEnv("RUNQUOTA_ENDPOINT_GROUP") == $foreignGid

    test "startup reader keeps the complete original three-line protocol":
      let child = startProcess(getAppFilename(),
        args = ["--startup-reader-control", "complete"],
        options = {poStdErrToStdOut})
      defer: child.close()
      check readRequiredStartupLines(child, 3, "complete control") ==
        @["startup-one", "startup-two", "startup-three"]
      check child.waitForExit() == 0

    test "startup EOF preserves the real child prefix and remains a failure":
      let child = startProcess(getAppFilename(),
        args = ["--startup-reader-control", "short"],
        options = {poStdErrToStdOut})
      defer: child.close()
      var message = ""
      try:
        discard readRequiredStartupLines(child, 3, "short control")
      except IOError as error:
        message = error.msg
      check "1 of 3 required lines" in message
      check "owned-child-refusal" in message
      check "child exit=" in message
      check child.waitForExit() == 7

    test "EOF diagnostics do not wait for a still-running child":
      let root = scratchDir("runningeof")
      setFilePermissions(root, {fpUserRead, fpUserWrite, fpUserExec})
      defer: removeDir(root)
      let ready = root / "ready"
      let release = root / "release"
      check not fileExists(ready)
      check not fileExists(release)
      # The declared launcher closes the original pipe writer aliases and
      # inherited non-stdio descriptors before exec. Closing 1/2 therefore
      # produces real EOF while this actual child is still waiting for us.
      var child = launchProcess(commandSpec([getAppFilename(),
        "--startup-reader-control", "waiting", ready, release,
        $getCurrentProcessId()], createProcessGroup = false))
      check child.processGroupId == int(getpgrp())
      check getpgid(Pid(child.pid)) == getpgrp()
      var output: Stream = nil
      var pendingFd = cint(child.stdoutFd)
      child.stdoutFd = -1
      try:
        var info: Stat
        doAssert pendingFd >= 0 and fstat(pendingFd, info) == 0
        doAssert S_ISFIFO(info.st_mode)
        let flags = fcntl(pendingFd, F_GETFL, 0)
        doAssert flags >= 0
        doAssert fcntl(pendingFd, F_SETFL, flags and not O_NONBLOCK) == 0
        var file: File
        if not open(file, FileHandle(pendingFd), fmRead):
          raise newException(IOError, "could not take owned stdout pipe")
        output = newFileStream(file)
        pendingFd = -1 # FileStream is now the sole owner of this descriptor.
        var message = ""
        try:
          discard readRequiredStartupLines(child, output, 3, "waiting control")
        except IOError as error:
          message = error.msg
        check output.atEnd()
        check "1 of 3 required lines" in message
        check "owned-child-still-running" in message
        check "child exit=-1" in message
        check runquota_process.running(child)
        check fileExists(ready)
        check readFile(ready) == $child.pid
        check not fileExists(release)
      finally:
        try:
          # Release only AFTER true EOF and live-child assertions. No made-up
          # stream/status or extra startup retry can satisfy this control.
          writeFile(release, "release")
        except CatchableError:
          # This child stays in the original test's bounded process group.
          # Do not use group cancellation: only this still-owned, unreaped
          # child PID may be signalled if its release marker cannot be written.
          if runquota_process.running(child):
            discard posix.kill(Pid(child.pid), SIGTERM)
          raise
        finally:
          if not output.isNil: output.close()
          elif pendingFd >= 0: discard posix.close(pendingFd)
          let completion = child.waitForCompletion()
          check completion.exited and completion.exitCode == 0
          child.close()
      removeFile(ready)
      removeFile(release)
