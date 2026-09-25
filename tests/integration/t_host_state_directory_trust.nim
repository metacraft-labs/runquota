## M13d: the host-wide state directory's OWNERSHIP AND MODE are verified on
## every daemon start, not merely its existence.
##
## WHAT WAS LEFT OPEN. M13c closed "existence is not trust" for the
## rendezvous directory and left the same half-check standing for the state
## directory: `resolveHostIdentity` asked `dirExists` and nothing else, so a
## `/var/db/runquota` owned by the wrong uid was accepted for as long as the
## daemon could still write in it. Exploiting THAT needs root, because
## `/var/db` is root-owned `0755` -- but the realistic failure needs nobody
## at all. An operator runs `sudo mkdir -p` and forgets the `chown`, or
## leaves the directory `0777`, and then any local user can replace
## `host-id` and thereby fork this machine's history in two or merge it with
## another machine's. Neither has a symptom at the point of use.
##
## NEGATIVE CONTROLS ARE THE GATE. A daemon that starts and captures proves
## nothing: it did that before this check existed. So every clause here is a
## REFUSAL asserted as one -- named path, named mode, capture off, and NO
## id minted -- and each is paired with the acceptance that would otherwise
## let "refuse everything" pass.
##
## THE DAEMON STILL SERVES. Admission is the mission: a machine's build
## capacity must not be taken out because a statistics directory has the
## wrong mode. That is the same answer OS-4 already gives to the
## neighbouring failure, and two different answers to two indistinguishable
## operator-visible failures would be the surprising design.
##
## No mocks: the real `runquotad` binary, real directories, real modes, and
## a really foreign-owned directory this host already has.

## ON WINDOWS THE SAME CLAUSES RUN AGAINST A DACL. Windows has no mode to
## read: what the kernel checks is the directory's owner and its ACL, so the
## Windows arm below builds its fixtures with `icacls` and reads them back
## with `whoami` and .NET's ACL API -- the operating system's own tools,
## never the code under test -- and asserts the same five refusals and
## acceptances, plus one the POSIX arm has no counterpart for: the `icacls`
## repair the refusal prints is itself asserted to produce a directory the
## daemon accepts. The rule is `docs/database.md` §"Provisioning the host-wide
## state directory and the rendezvous".

when defined(windows):
  import std/[os, osproc, streams, strutils, unittest]

  import runquota_ipc
  import runquota_observation_store
  import daemon_binary
  import daemon_endpoint
  import windows_acl_fixture

  proc scratchDir(name: string): string =
    result = getTempDir() / ("rq" & $getCurrentProcessId() & name)
    removeDir(result)
    createDir(result)

  proc containsMintedHostId(text: string): bool =
    ## True when `text` carries something SHAPED like a `host_id`.
    var start = 0
    while true:
      let at = text.find(hostIdPrefix, start)
      if at < 0:
        return false
      let stop = min(text.len, at + hostIdPrefix.len + 32)
      if isOpaqueId(text[at ..< stop], hostIdPrefix):
        return true
      start = at + 1

  const
    systemSid = "S-1-5-18"
    administratorsSid = "S-1-5-32-544"
    usersSid = "S-1-5-32-545"
    creatorOwnerSid = "S-1-3-0"
    ownerRightsSid = "S-1-3-4"
    # The rights that let a principal change what a directory holds. Spelled
    # out HERE rather than taken from `runquota_ipc`, so the precondition
    # below is the test's own reading of Windows and not the library's.
    writeRights = 0x2'u32 or 0x4'u32 or 0x10'u32 or 0x40'u32 or 0x100'u32 or
      0x10000'u32 or 0x40000'u32 or 0x80000'u32 or 0x10000000'u32 or
      0x40000000'u32

  proc foreignOwnedDirectory(): string =
    ## Owned by an account that is not this user, SYSTEM or Administrators,
    ## AND writable by nobody but its owner and those three, so ownership is
    ## the only check that can refuse it. On every Windows install the
    ## system directories are owned by `NT SERVICE\TrustedInstaller`, which
    ## is the counterpart of the POSIX arm's root-owned `/usr`.
    ##
    ## The OWNER comes from .NET's ACL API, not from RunQuota. The ACE list
    ## is read with `readDirectorySecurity` -- a fact reader with no policy
    ## in it -- and judged by this proc's own rule.
    let me = currentUserSid()
    let systemRoot = getEnv("SystemRoot", r"C:\Windows")
    for candidate in [systemRoot,
        getEnv("ProgramFiles", r"C:\Program Files"),
        systemRoot / "System32"]:
      if not dirExists(candidate): continue
      let owner = ownerSidOf(candidate)
      if owner in [me, systemSid, administratorsSid]: continue
      let facts = readDirectorySecurity(candidate)
      if facts.errorCode != 0 or not facts.daclPresent: continue
      if facts.ownerSid != owner: continue
      var othersCanWrite = false
      for ace in facts.aces:
        if ace.aceType in [1, 6, 10, 12]: continue
        if (ace.mask and writeRights) == 0: continue
        if ace.sid notin [owner, me, systemSid, administratorsSid,
                          creatorOwnerSid, ownerRightsSid]:
          othersCanWrite = true
      if othersCanWrite: continue
      return candidate
    ""

  type DaemonHandle = object
    process: Process
    startupLines: seq[string]

  proc startDaemon(socketPath, observationDb, identityFile: string):
      DaemonHandle =
    let process = startProcess(daemonPath(),
      args = ["--socket", socketPath, "--observation-db", observationDb,
              "--host-identity-file", identityFile],
      options = {poStdErrToStdOut})
    for _ in 0 ..< 400:
      if endpointIsBound(socketPath): break
      sleep(25)
    # EXACTLY THREE LINES, as on POSIX: a refusal that spilled onto a fourth
    # would leave every reader of the third misreading.
    var lines: seq[string] = @[]
    for _ in 0 ..< 3:
      lines.add(process.outputStream.readLine())
    DaemonHandle(process: process, startupLines: lines)

  proc stop(handle: var DaemonHandle) =
    if handle.process.running:
      handle.process.terminate()
      discard handle.process.waitForExit(5000)
    if handle.process.running:
      handle.process.kill()
      discard handle.process.waitForExit(5000)
    check not handle.process.running
    handle.process.close()

  proc removeFixture(root: string) =
    ## A daemon stopped with `TerminateProcess` can leave its `sqlite3`
    ## child holding the store open for a moment; the removal is retried
    ## within a bound rather than reported as the product's failure.
    for _ in 0 ..< 80:
      try:
        removeDir(root)
        return
      except OSError:
        sleep(25)
    removeDir(root)

  suite "host_state_directory_trust":
    test "a state directory this daemon owns and nobody else can write is ACCEPTED":
      ## THE PAIRED ACCEPTANCE, built the way the runbook builds it: the
      ## provisioning command the daemon itself prints, run through cmd.exe
      ## verbatim. Without this a build that refused every directory would
      ## satisfy every refusal below -- and a runbook whose command produced
      ## a directory the daemon refuses would be a runbook nobody can follow.
      let root = scratchDir("hsok")
      defer: removeFixture(root)
      let state = root / "state"
      let (code, output) = runCmdLine(provisionHostStateDirCommand(state))
      checkpoint(output)
      check code == 0
      check dirExists(state)
      check ownerSidOf(state) in [currentUserSid(), administratorsSid]
      var daemon = startDaemon(root / "ep" / "d.sock", root / "obs.sqlite",
        state / "host-id")
      try:
        check daemon.startupLines[1].contains("capture enabled")
        check containsMintedHostId(daemon.startupLines[2])
        check fileExists(state / "host-id")
      finally:
        daemon.stop()

    test "a WORLD-WRITABLE state directory is REFUSED, naming path and mode":
      ## The Windows "world-writable" is an ACE, and this one is not
      ## invented: it is what `C:\ProgramData` hands every directory created
      ## under it, so a bare `mkdir C:\ProgramData\runquota` -- what this
      ## repository's runbook used to say -- produces exactly this directory.
      let root = scratchDir("hswide")
      defer: removeFixture(root)
      let state = root / "state"
      createDir(state)
      restrictToOwnerAndSystem(state)
      grantUsersCreate(state)
      var daemon = startDaemon(root / "ep" / "d.sock", root / "obs.sqlite",
        state / "host-id")
      try:
        check daemon.startupLines[1].contains("capture enabled")
        let report = daemon.startupLines[2]
        # Named, not opaque: the path, the principal, the rights.
        check "host state directory" in report
        check state in report
        check usersSid in report
        check "(WD,AD,WEA,WA)" in report
        check "writable by a principal other than its owner" in report
        # The repair, with this daemon's account filled in.
        check ("icacls \"" & state & "\" /inheritance:r") in report
        check ("*" & currentUserSid() & ":(OI)(CI)F") in report
        check "capture disabled" in report
        # AND NOTHING WAS MINTED, and the daemon still serves.
        check not containsMintedHostId(report)
        check not fileExists(state / "host-id")
        check daemon.process.running
        check endpointIsBound(root / "ep" / "d.sock")
      finally:
        daemon.stop()

    test "the refusal is the SAME on a second start":
      let root = scratchDir("hstwice")
      defer: removeFixture(root)
      let state = root / "state"
      createDir(state)
      restrictToOwnerAndSystem(state)
      grantUsersCreate(state)
      var first = startDaemon(root / "ep" / "d1.sock", root / "obs.sqlite",
        state / "host-id")
      let firstReport = first.startupLines[2]
      first.stop()
      var second = startDaemon(root / "ep" / "d2.sock", root / "obs.sqlite",
        state / "host-id")
      try:
        check "host state directory" in firstReport
        check second.startupLines[2] == firstReport
        check not containsMintedHostId(second.startupLines[2])
      finally:
        second.stop()

    test "the icacls repair the refusal prints makes the directory ACCEPTED":
      ## WINDOWS ONLY, because only the Windows refusal prints a repair. A
      ## repair line that did not in fact produce an acceptable DACL would
      ## send an operator in a circle, so it is run -- verbatim, as printed --
      ## against the directory the refusal describes.
      let root = scratchDir("hsfix")
      defer: removeFixture(root)
      let state = root / "state"
      createDir(state)
      restrictToOwnerAndSystem(state)
      grantUsersCreate(state)
      var refused = startDaemon(root / "ep" / "d1.sock", root / "obs.sqlite",
        state / "host-id")
      let report = refused.startupLines[2]
      refused.stop()
      const marker = " -- tighten it with: "
      check marker in report
      if marker in report:
        let repair = report[report.find(marker) + marker.len .. ^1]
        check repair.startsWith("icacls ")
        let (code, output) = runCmdLine(repair)
        checkpoint(output)
        check code == 0
      var accepted = startDaemon(root / "ep" / "d2.sock", root / "obs.sqlite",
        state / "host-id")
      try:
        check "host state directory" notin accepted.startupLines[2]
        check containsMintedHostId(accepted.startupLines[2])
        check fileExists(state / "host-id")
      finally:
        accepted.stop()

    test "a state directory owned by ANOTHER uid is REFUSED as an ownership problem":
      ## The DACL cannot be what refuses this one: `foreignOwnedDirectory`
      ## only returns a directory nobody but its owner (and the principals
      ## that already control the host) can write. If the ownership check
      ## were removed this path would be ACCEPTED, and the daemon would mint
      ## into -- or read from -- a directory somebody else controls.
      let foreign = foreignOwnedDirectory()
      check foreign.len > 0
      if foreign.len > 0:
        let owner = ownerSidOf(foreign)
        check owner != currentUserSid()
        let root = scratchDir("hsforeign")
        defer: removeFixture(root)
        var daemon = startDaemon(root / "ep" / "d.sock", root / "obs.sqlite",
          foreign / "rq-m13d-host-id")
        try:
          let report = daemon.startupLines[2]
          check "host state directory" in report
          check foreign in report
          check ("owned by ") in report
          check owner in report
          check ("this process runs as ") in report
          check currentUserSid() in report
          check "capture disabled" in report
          check not containsMintedHostId(report)
          # It refused before writing anywhere it has no business writing.
          check not fileExists(foreign / "rq-m13d-host-id")
          check daemon.process.running
        finally:
          daemon.stop()

    test "a directory that is not there yet is reported by the PROVISIONING refusal, not this one":
      let root = scratchDir("hsmissing")
      defer: removeFixture(root)
      let absent = root / "absent"
      var daemon = startDaemon(root / "ep" / "d.sock", root / "obs.sqlite",
        absent / "host-id")
      try:
        let report = daemon.startupLines[2]
        check "does not exist" in report
        check "install step" in report
        # The Windows provisioning command: the `mkdir` AND the `icacls` that
        # makes what it created acceptable.
        check ("mkdir \"" & absent & "\" && icacls \"" & absent &
          "\" /reset && icacls \"" & absent & "\" /inheritance:r") in report
        check "host state directory" notin report
        check not containsMintedHostId(report)
        check not dirExists(absent)
      finally:
        daemon.stop()
else:
  import std/[os, osproc, posix, streams, strutils, unittest]

  import runquota_observation_store
  import daemon_binary

  proc scratchDir(name: string): string =
    # Short on purpose: Nim's `Sockaddr_un_path_length` is 92 on macOS and
    # `toSockAddr` refuses `path.len >= 92`. A plain macOS `TMPDIR` is 49
    # characters before anything is appended; inside `nix develop` it is 21.
    #
    #   49 (TMPDIR) + 13 (this dir) + 3 (/ep) + 7 (/d.sock) = 72
    result = getTempDir() / ("rq" & $getCurrentProcessId() & name)
    removeDir(result)
    createDir(result)
    setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})

  proc modeOf(path: string): int =
    var info: Stat
    if lstat(path.cstring, info) != 0: return -1
    int(info.st_mode) and 0o7777

  proc ownerOf(path: string): int64 =
    var info: Stat
    if lstat(path.cstring, info) != 0: return -1
    int64(info.st_uid)

  proc socketExists(path: string): bool =
    var info: Stat
    lstat(path.cstring, info) == 0 and S_ISSOCK(info.st_mode)

  proc foreignOwnedDirectory(): string =
    ## Owned by another uid and NOT group- or world-writable, so ownership is
    ## the only check that can refuse it. `/usr` and `/` are root-owned
    ## `0755` on macOS and on Linux.
    for candidate in ["/usr", "/", "/etc", "/bin"]:
      var info: Stat
      if lstat(candidate.cstring, info) != 0: continue
      if not S_ISDIR(info.st_mode): continue
      if int64(info.st_uid) == int64(getuid()): continue
      if (int(info.st_mode) and 0o022) != 0: continue
      return candidate
    ""

  proc containsMintedHostId(text: string): bool =
    ## True when `text` carries something SHAPED like a `host_id`. A refusal
    ## must not: the whole class of defect here is a startup line that reads
    ## as healthy because it names a well-formed id nothing wrote down.
    var start = 0
    while true:
      let at = text.find(hostIdPrefix, start)
      if at < 0:
        return false
      let stop = min(text.len, at + hostIdPrefix.len + 32)
      if isOpaqueId(text[at ..< stop], hostIdPrefix):
        return true
      start = at + 1

  type DaemonHandle = object
    process: Process
    startupLines: seq[string]

  proc startDaemon(socketPath, observationDb, identityFile: string):
      DaemonHandle =
    let process = startProcess(daemonPath(),
      args = ["--socket", socketPath, "--observation-db", observationDb,
              "--host-identity-file", identityFile],
      options = {poStdErrToStdOut})
    for _ in 0 ..< 400:
      if socketExists(socketPath): break
      sleep(25)
    # EXACTLY THREE LINES whenever a store path was given, and reading
    # precisely three is itself an assertion: a refusal that spilled onto a
    # fourth line would leave every reader of the third one misreading or
    # blocked.
    var lines: seq[string] = @[]
    for _ in 0 ..< 3:
      lines.add(process.outputStream.readLine())
    DaemonHandle(process: process, startupLines: lines)

  proc stop(handle: var DaemonHandle) =
    if handle.process.running:
      handle.process.terminate()
      discard handle.process.waitForExit(5000)
    if handle.process.running:
      handle.process.kill()
      discard handle.process.waitForExit(5000)
    check not handle.process.running
    handle.process.close()

  suite "host_state_directory_trust":
    test "a state directory this daemon owns and nobody else can write is ACCEPTED":
      ## THE PAIRED ACCEPTANCE. Without it a build that refused every
      ## directory would satisfy both refusals below.
      let root = scratchDir("hsok")
      defer: removeDir(root)
      let state = root / "state"
      createDir(state)
      check chmod(state.cstring, Mode(0o700)) == 0
      check ownerOf(state) == int64(getuid())
      var daemon = startDaemon(root / "ep" / "d.sock", root / "obs.sqlite",
        state / "host-id")
      try:
        check daemon.startupLines[1].contains("capture enabled")
        check containsMintedHostId(daemon.startupLines[2])
        check fileExists(state / "host-id")
      finally:
        daemon.stop()

    test "a WORLD-WRITABLE state directory is REFUSED, naming path and mode":
      ## `sudo mkdir -p` with a lax umask, or an operator reaching for
      ## `chmod 777` when the daemon could not write. Any local user can
      ## replace `host-id` in such a directory, and replacing `host-id` is
      ## how one machine's history gets forked or merged with another's.
      let root = scratchDir("hswide")
      defer: removeDir(root)
      let state = root / "state"
      createDir(state)
      check chmod(state.cstring, Mode(0o777)) == 0
      check modeOf(state) == 0o777
      var daemon = startDaemon(root / "ep" / "d.sock", root / "obs.sqlite",
        state / "host-id")
      try:
        check daemon.startupLines[1].contains("capture enabled")
        let report = daemon.startupLines[2]
        # Named, not opaque.
        check "host state directory" in report
        check state in report
        check "0777" in report
        check "group- or world-writable" in report
        check "capture disabled" in report
        # AND NOTHING WAS MINTED. An id that exists in one process and
        # nowhere else is precisely what must not escape.
        check not containsMintedHostId(report)
        check not fileExists(state / "host-id")
        # ...and the daemon is still serving leases, because admission is
        # the mission.
        check daemon.process.running
        check socketExists(root / "ep" / "d.sock")
      finally:
        daemon.stop()

    test "the refusal is the SAME on a second start":
      ## REPETITION, against a real process. The defect class this whole
      ## check belongs to is invisible within one invocation and only shows
      ## up across two: the pre-M13c code answered an unusable directory by
      ## minting a fresh id every start, and every line read as healthy.
      let root = scratchDir("hstwice")
      defer: removeDir(root)
      let state = root / "state"
      createDir(state)
      check chmod(state.cstring, Mode(0o777)) == 0
      var first = startDaemon(root / "ep" / "d1.sock", root / "obs.sqlite",
        state / "host-id")
      let firstReport = first.startupLines[2]
      first.stop()
      var second = startDaemon(root / "ep" / "d2.sock", root / "obs.sqlite",
        state / "host-id")
      try:
        check second.startupLines[2] == firstReport
        check not containsMintedHostId(second.startupLines[2])
      finally:
        second.stop()

    test "a state directory owned by ANOTHER uid is REFUSED as an ownership problem":
      ## The mode cannot be what refuses this one: the directory is `0755`,
      ## which is not group- or world-writable. If the ownership check were
      ## removed this path would be ACCEPTED, and the daemon would mint into
      ## -- or read from -- a directory somebody else controls.
      let foreign = foreignOwnedDirectory()
      check foreign.len > 0
      if foreign.len > 0:
        check (modeOf(foreign) and 0o022) == 0
        check ownerOf(foreign) != int64(getuid())
        let root = scratchDir("hsforeign")
        defer: removeDir(root)
        var daemon = startDaemon(root / "ep" / "d.sock", root / "obs.sqlite",
          foreign / "rq-m13d-host-id")
        try:
          let report = daemon.startupLines[2]
          check "host state directory" in report
          check foreign in report
          check ("owned by uid " & $ownerOf(foreign)) in report
          check ("uid " & $getuid()) in report
          check "capture disabled" in report
          check not containsMintedHostId(report)
          # It refused before writing anywhere it has no business writing.
          check not fileExists(foreign / "rq-m13d-host-id")
          check daemon.process.running
        finally:
          daemon.stop()

    test "a directory that is not there yet is reported by the PROVISIONING refusal, not this one":
      ## Two reports for one condition would be one report too many, and the
      ## provisioning refusal is the useful one because it names the command.
      ## This clause pins which of the two speaks.
      let root = scratchDir("hsmissing")
      defer: removeDir(root)
      var daemon = startDaemon(root / "ep" / "d.sock", root / "obs.sqlite",
        root / "absent" / "host-id")
      try:
        let report = daemon.startupLines[2]
        check "does not exist" in report
        check "install step" in report
        check "sudo mkdir -p " in report
        check "host state directory" notin report
        check not containsMintedHostId(report)
      finally:
        daemon.stop()
