## THE STORE'S FILES ARE NOT A SECOND WAY TO THE ROWS.
##
## THE PROPERTY. `runquotad` is one daemon per host, so one observation store
## holds every user's executions, and the daemon is its only reader: a query
## goes over the socket, where the daemon scopes it to the calling uid from
## the peer's credentials (`AGENTS.md`, "Boundaries"; `docs/database.md`,
## `executions.owner_uid`). That rule binds RunQuota's own clients by a
## source inspection. It binds nobody else unless the kernel enforces it,
## because a user who can `open(2)` the store file needs no client at all:
## the file is plain SQLite, and reading it skips the uid scoping, the
## explicit widening and the hardware qualification in one step. So the
## property asserted here is the one the rule depends on:
##
##   a user of the host who is neither the daemon's account nor the owner of
##   an execution cannot read that execution out of the store's files.
##
## THE ATTACK, AND WHY IT IS SHAPED THIS WAY. Three real uids take part:
##
##   * the DAEMON's account, which owns the state directory and the store;
##   * the OWNER, a participant who takes one lease through the shipped CLI,
##     so the daemon records one execution under the owner's uid;
##   * the READER, another participant -- in the admission group, as any
##     user allowed to use RunQuota on the host is -- who is not the owner
##     and not the daemon, and who goes for the FILES rather than the
##     socket: it opens the store, copies it and its write-ahead log to a
##     directory of its own, and asks SQLite for the rows.
##
## The reader being IN the admission group is the point, not a convenience.
## The group is what admits a user to the socket, so it is the population
## the daemon's uid scoping exists to keep apart; a reader outside it would
## only show that strangers are kept out, which a group-readable store also
## does.
##
## THE DAEMON IS STARTED THE WAY THE SHIPPED SERVICE STARTS IT. The state
## directory gets the provisioned mode from `nix/host-state.nix`, and the
## daemon gets the umask the service unit in
## `nix/modules/runquotad-nixos.nix` sets. Both are READ FROM THOSE FILES
## rather than written here as literals, so the fixture cannot drift from
## what ships: whatever the unit would create on a real host is what the
## reader is pointed at.
##
## PAIRED, SO AN EMPTY STORE CANNOT PASS. Before the reader runs, the
## daemon's own account reads the same file and must find the owner's
## execution in it, attributed to the owner's uid. Without that a store
## nothing was written to would satisfy "the reader saw no rows".
##
## THE UIDS ARE NIX BUILD USERS, for the reason
## `t_shared_endpoint_second_uid` gives: a host without `sudo` has no other
## real second uid, and concurrent builds each run as a different one. The
## daemon lives in one long-running build and the owner in a second that
## stays open until the end, so the reader's build cannot be handed either
## of their uids -- and the three being distinct is asserted, not assumed.
##
## No mocks: the real `runquotad`, the shipped CLI taking a real lease, real
## uids, the files the daemon really wrote, and the `sqlite3` tool anybody
## on the host could run.
##
## POSIX ONLY. The boundary is a file mode and a group. On Windows the same
## question is about the state directory's DACL and needs its own fixture;
## every case is reported skipped there.

when not defined(posix):
  import std/unittest

  suite "observation_store_second_uid_preflight":
    for name in [
        "the shipped binaries are placed where a second uid can reach them",
        "the service's umask and state directory mode are read from what ships",
        "a real second uid is available"]:
      test name:
        skip()

  suite "observation_store_unreadable_by_second_uid":
    test "a participant cannot read another user's executions out of the store's files":
      skip()
else:
  import std/[os, osproc, posix, strutils, tables, times, unittest, sequtils]

  import daemon_binary
  import private_broker_owner
  # The engine exports RUNQUOTA_ENDPOINT_SCOPE=private to every action it runs;
  # the daemon here is a host-scope one, so that must not be inherited.
  useHostEndpointScope()

  const
    serviceModule = "nix/modules/runquotad-nixos.nix"
    hostStateFile = "nix/host-state.nix"
    rowsMarker = "--- rows ---"
    leaseMarker = "--- lease ---"
    leaseToken = "store-owner-lease-ok"

  proc modeOf(path: string): int =
    var info: Stat
    if lstat(path.cstring, info) != 0: return -1
    int(info.st_mode) and 0o7777

  proc ownerOf(path: string): int64 =
    var info: Stat
    if lstat(path.cstring, info) != 0: return -1
    int64(info.st_uid)

  proc quotedSetting(path, key: string): string =
    ## The double-quoted value of the first `key = "..."` line in a Nix
    ## file, or "" when there is none. Read as text on purpose: evaluating
    ## the module would need the whole flake, and all that is wanted is the
    ## literal an operator would read in the same place.
    if not fileExists(path): return ""
    for line in readFile(path).splitLines():
      let trimmed = line.strip()
      if not trimmed.startsWith(key): continue
      let rest = trimmed[key.len .. ^1].strip()
      if not rest.startsWith("="): continue
      let first = rest.find('"')
      let last = rest.rfind('"')
      if first >= 0 and last > first:
        return rest[first + 1 ..< last]
    ""

  proc isOctalMode(text: string): bool =
    text.len in 3 .. 4 and text.allCharsInSet({'0' .. '7'})

  const requiredFixtureTools = ["bash", "mkdir", "chmod", "mv", "cp", "rm",
                                "cat", "sleep", "printf", "id", "stat",
                                "sqlite3"]

  proc requireFixtureTool(name: string): string =
    # Preserve named argv[0] dispatch for Nix coreutils multicall aliases.
    result = findExe(name, followSymlinks = false)
    if result.len == 0 or not result.startsWith("/nix/store/"):
      raise newException(ValueError,
        "second-UID fixture requires an immutable Nix-backed tool: " & name)

  let fixtureTools = block:
    var selected = initTable[string, string]()
    for name in requiredFixtureTools:
      selected[name] = requireFixtureTool(name)
    selected

  proc fixtureToolRoots(): seq[string] =
    for name in requiredFixtureTools:
      let path = fixtureTools[name]
      let boundary = path.find('/', "/nix/store/".len)
      if boundary < 0:
        raise newException(ValueError,
          "invalid immutable fixture tool path: " & name)
      let root = path[0 ..< boundary]
      if root notin result: result.add(root)

  proc fixturePath(): string =
    var directories: seq[string] = @[]
    for name in requiredFixtureTools:
      let directory = parentDir(fixtureTools[name])
      if directory notin directories: directories.add(directory)
    directories.join(":")

  proc nixBuildExe(): string =
    # `followSymlinks = false` is load-bearing: `nix-build` is a symlink to
    # the multicall `nix` binary, which dispatches on `argv[0]`.
    findExe("nix-build", followSymlinks = false)

  proc buildArgs(expression: string): seq[string] =
    # The builds exist to supply distinct real credentials on THIS host's
    # filesystem. A sandboxed build has a private /tmp and could reach
    # neither the socket nor the store; build-user separation and the
    # kernel's permission checks are untouched by this option.
    @["--no-out-link", "--option", "sandbox", "false", expression]

  proc script(lines: varargs[string]): string =
    ## Joined with explicit newlines: a script assembled from triple-quoted
    ## segments loses the break at each seam, and the build still succeeds
    ## with an empty `$out`.
    lines.join("\n") & "\n"

  proc writeExpression(workDir, nonce, scriptPath: string): string =
    result = workDir / "build.nix"
    writeFile(result,
      "derivation {\n" &
      "  name = \"rq-store-" & nonce & "\";\n" &
      "  system = builtins.currentSystem;\n" &
      "  builder = builtins.storePath \"" & fixtureTools["bash"] & "\";\n" &
      "  runtimeToolRoots = [ " & fixtureToolRoots().mapIt(
        "(builtins.storePath \"" & it & "\")").join(" ") & " ];\n" &
      "  args = [ \"" & scriptPath & "\" ];\n" &
      "}\n")

  proc prepareBuild(label, body: string): tuple[workDir, expression: string] =
    ## The derivation name carries a nonce, so two runs are two builds
    ## rather than one build and one cache hit.
    let nonce = $getCurrentProcessId() & "-" & $int(epochTime() * 1000.0) &
      "-" & label
    let workDir = "/tmp" / ("rqstore" & nonce)
    createDir(workDir)
    discard chmod(workDir.cstring, Mode(0o755))
    let scriptPath = workDir / "build.sh"
    writeFile(scriptPath, body)
    discard chmod(scriptPath.cstring, Mode(0o755))
    (workDir, writeExpression(workDir, nonce, scriptPath))

  proc runAsSecondUid(label, body: string): string =
    ## Runs `body` as a Nix build user and returns what it wrote to `$out`.
    let (workDir, expression) = prepareBuild(label, body)
    let built = execProcess(nixBuildExe(),
      args = buildArgs(expression),
      env = nil, options = {poStdErrToStdOut})
    var storePath = ""
    for line in built.splitLines():
      let trimmed = line.strip()
      if trimmed.startsWith("/nix/store/"):
        storePath = trimmed
    if storePath.len == 0 or not fileExists(storePath):
      echo "  nix-build produced no output for " & label & ":"
      echo built
      return ""
    result = readFile(storePath)
    removeDir(workDir)

  var backgroundWorkDirs: seq[string] = @[]

  proc startAsSecondUid(label, body: string): Process =
    ## The same, left RUNNING: the build holds its uid for as long as it
    ## lasts, which is what keeps a later build from being handed it.
    let (workDir, expression) = prepareBuild(label, body)
    backgroundWorkDirs.add(workDir)
    startProcess(nixBuildExe(), args = buildArgs(expression),
      options = {poStdErrToStdOut})

  proc cleanBackgroundWorkDirs() =
    for workDir in backgroundWorkDirs:
      try:
        removeDir(workDir)
      except OSError:
        discard
    backgroundWorkDirs.setLen(0)

  proc stopBuild(build: var Process) =
    discard build.waitForExit(120_000)
    if build.running:
      build.terminate()
      discard build.waitForExit(10_000)
    if build.running:
      build.kill()
      discard build.waitForExit(10_000)

  proc parseReport(text: string): Table[string, string] =
    ## The `key=value` lines above the rows marker.
    result = initTable[string, string]()
    for line in text.splitLines():
      if line == rowsMarker or line == leaseMarker: break
      let at = line.find('=')
      if at > 0:
        result[line[0 ..< at]] = line[at + 1 .. ^1]

  proc rowsIn(text: string): seq[string] =
    ## The `owner_uid|execution_id|duration_millis` lines after the rows
    ## marker.
    var seen = false
    for line in text.splitLines():
      if line == rowsMarker:
        seen = true
      elif seen and line.strip().len > 0:
        result.add(line.strip())

  proc rowsOwnedBy(rows: seq[string]; uid: string): seq[string] =
    for row in rows:
      if row.split('|')[0] == uid:
        result.add(row)

  proc gidsIn(field: string): seq[int64] =
    for part in field.split({',', ' '}):
      if part.len > 0:
        try:
          result.add(int64(parseBiggestInt(part.strip())))
        except ValueError:
          discard

  proc waitForFile(path: string; rounds: int): bool =
    for _ in 0 ..< rounds:
      if fileExists(path): return true
      sleep(50)
    fileExists(path)

  type FixtureError = object of CatchableError

  proc fixture(holds: bool; what: string) =
    ## A PRECONDITION OF THE CASE, NOT ITS CLAIM. Raised rather than
    ## `require`d: `require` quits the process on the spot, which would
    ## leave two builds and a daemon running with nothing to stop them. An
    ## exception unwinds through the `finally` that does, and the runner
    ## reports the case failed with this text -- which names the fixture, so
    ## it cannot be read as the store having been found readable.
    if not holds:
      raise newException(FixtureError, "fixture precondition failed: " & what)

  # ---------------------------------------------------------------------------
  # Fixture, computed once from this host and from what the repository ships.
  # ---------------------------------------------------------------------------

  var toolDir = ""
  var serviceUmask = ""
  var stateDirectoryMode = ""
  var memberGid = -1'i64

  suite "observation_store_second_uid_preflight":
    test "the shipped binaries are placed where a second uid can reach them":
      ## The build tree can be unreachable for another uid (a home directory
      ## is commonly `0750`), so the binaries are copied to a directory that
      ## is not.
      check fileExists(daemonPath())
      check fileExists(cliPath())
      toolDir = "/tmp" / ("rqstorebin" & $getCurrentProcessId())
      removeDir(toolDir)
      createDir(toolDir)
      check chmod(toolDir.cstring, Mode(0o755)) == 0
      copyFile(daemonPath(), toolDir / "runquotad")
      copyFile(cliPath(), toolDir / "runquota")
      check chmod((toolDir / "runquotad").cstring, Mode(0o755)) == 0
      check chmod((toolDir / "runquota").cstring, Mode(0o755)) == 0

    test "the service's umask and state directory mode are read from what ships":
      serviceUmask = quotedSetting(serviceModule, "UMask")
      stateDirectoryMode = quotedSetting(hostStateFile, "mode")
      echo "  service umask " & serviceUmask & " (" & serviceModule &
        "), state directory mode " & stateDirectoryMode & " (" &
        hostStateFile & ")"
      # A value that did not parse would start the daemon under whatever
      # umask the builder has, and the case below would then be about a
      # configuration nobody ships.
      check isOctalMode(serviceUmask)
      check isOctalMode(stateDirectoryMode)

    test "a real second uid is available":
      check nixBuildExe().len > 0
      if nixBuildExe().len > 0:
        let report = parseReport(runAsSecondUid("ids", script(
          "set -e",
          "export PATH=" & quoteShell(fixturePath()),
          "{",
          "  echo \"uid=$(id -u)\"",
          "  echo \"groups=$(id -G)\"",
          "} > \"$out\" 2>&1")))
        check report.hasKey("uid")
        if report.hasKey("uid"):
          # A SECOND UID, not this one.
          check report["uid"] != $int64(getuid())
          let groups = gidsIn(report.getOrDefault("groups"))
          check groups.len > 0
          if groups.len > 0:
            # Every build user is in the build group and, inside a build,
            # in nothing else; it stands in for the admission group here
            # exactly as it does for the shared endpoint.
            memberGid = groups[0]
            echo "  second uid " & report["uid"] & " groups " & $groups &
              ", admission group " & $memberGid

  suite "observation_store_unreadable_by_second_uid":
    test "a participant cannot read another user's executions out of the store's files":
      if toolDir.len == 0 or memberGid < 0 or
          not isOctalMode(serviceUmask) or
          not isOctalMode(stateDirectoryMode):
        echo "  NOT RUN: the preflight above did not produce the fixture"
        check false
      else:
        let root = "/tmp" / ("rqsf" & $getCurrentProcessId())
        removeDir(root)
        createDir(root)
        check chmod(root.cstring, Mode(0o755)) == 0
        let rv = root / "rv"
        createDir(rv)
        # 1777: three uids this process cannot create files for each leave
        # their reports here. The boundary under test is `state`, below it.
        check chmod(rv.cstring, Mode(0o1777)) == 0
        let socketPath = rv / "ep" / "d.sock"
        let stateDir = rv / "state"
        let dbPath = stateDir / "observations.sqlite3"
        let stopFlag = rv / "stop"
        let auditFlag = rv / "audit"
        let auditReport = rv / "audit-report"
        let auditError = rv / "audit-error"
        let ownerReport = rv / "owner-report"
        let readyFlag = rv / "ready"
        let daemonLog = rv / "daemon.log"
        # Whose execution, which one, and how long it ran: three columns
        # that are never NULL, so a row read is a row shown.
        let rowQuery = quoteShell(
          "select owner_uid || '|' || execution_id || '|' || " &
          "duration_millis from executions;")

        # -------------------------------------------------------------------
        # THE DAEMON'S ACCOUNT. State directory at the provisioned mode, the
        # daemon under the service unit's umask, capture on.
        # -------------------------------------------------------------------
        var daemon = startAsSecondUid("daemon", script(
          "set -e",
          "export PATH=" & quoteShell(fixturePath()),
          "export RUNQUOTA_ENDPOINT_GROUP=" & $memberGid,
          "broker_uid=$(id -u)",
          "case \"$broker_uid\" in ''|*[!0-9]*) exit 1;; esac",
          "export RUNQUOTA_ENDPOINT_OWNER_UID=\"$broker_uid\"",
          "mkdir -p " & stateDir,
          "chmod " & stateDirectoryMode & " " & stateDir,
          # Created BEFORE the umask below applies, so this process can
          # still read the log whatever the service's umask is.
          ": > " & daemonLog,
          # THE UMASK IS THE SERVICE UNIT'S, and it is applied to the daemon
          # alone: the reports this script writes for the test must stay
          # readable by a uid outside the group.
          "( umask " & serviceUmask & "; exec " & toolDir & "/runquotad" &
            " --socket " & socketPath &
            " --observation-db " & dbPath &
            # Capture is off by default; this case reads what it records.
            " --measurement capture=on" &
            " --host-identity-file " & stateDir & "/host-id" &
            " --ambient-sample-interval-millis 0" &
            " >> " & daemonLog & " 2>&1 ) &",
          "pid=$!",
          "j=0",
          "while [ $j -lt 600 ]; do",
          "  [ -S " & socketPath & " ] && break",
          "  sleep 0.1",
          "  j=$((j+1))",
          "done",
          "echo ready > " & readyFlag,
          "i=0",
          "while [ $i -lt 900 ]; do",
          # THE CONTROL: the store read by the account that owns it. What
          # the file's owner, group and mode are is reported from here too,
          # by the one uid certain to be able to see them.
          "  if [ -e " & auditFlag & " ]; then",
          "    {",
          "      echo \"uid=$broker_uid\"",
          "      echo \"store=$(stat -c '%a %u %g' " & dbPath &
            " 2>/dev/null || echo missing)\"",
          "      echo '" & rowsMarker & "'",
          "      sqlite3 -readonly -batch -noheader " & dbPath & " " &
            rowQuery & " 2> " & auditError & " || true",
          "    } > " & auditReport & ".tmp",
          "    mv " & auditReport & ".tmp " & auditReport,
          "  fi",
          "  [ -e " & stopFlag & " ] && break",
          "  kill -0 $pid 2>/dev/null || break",
          "  sleep 0.2",
          "  i=$((i+1))",
          "done",
          "kill $pid 2>/dev/null || true",
          "sleep 0.5",
          "kill -9 $pid 2>/dev/null || true",
          "cp " & daemonLog & " \"$out\" 2>/dev/null || " &
            "echo no-daemon-log > \"$out\"",
          # Only the uid that made these can unmake them.
          "rm -rf " & rv & "/ep " & stateDir))
        var owner: Process
        var ownerStarted = false
        try:
          var captureReady = false
          for _ in 0 ..< 1200:
            if fileExists(readyFlag) and fileExists(daemonLog):
              for line in readFile(daemonLog).splitLines():
                if line.startsWith("runquota observation store ") and
                    line.endsWith("; capture enabled"):
                  captureReady = true
                  break
              if captureReady: break
            sleep(50)
          if not captureReady and fileExists(daemonLog):
            echo readFile(daemonLog)
          fixture(captureReady, "the daemon did not report capture enabled")
          let daemonUid = $ownerOf(rv / "ep")
          # The state directory is as provisioned, and it is the daemon's.
          fixture(modeOf(stateDir) == parseOctInt(stateDirectoryMode),
            "the state directory does not have the provisioned mode")
          fixture($ownerOf(stateDir) == daemonUid,
            "the state directory is not the daemon's")

          # -----------------------------------------------------------------
          # THE OWNER: a participant whose one lease becomes one execution.
          # Its build stays open until the end, holding its uid.
          # -----------------------------------------------------------------
          owner = startAsSecondUid("owner", script(
            "set -e",
            "export PATH=" & quoteShell(fixturePath()),
            "export RUNQUOTA_ENDPOINT_GROUP=" & $memberGid,
            "export RUNQUOTA_ENDPOINT_OWNER_UID=" & daemonUid,
            "{",
            "  echo \"uid=$(id -u)\"",
            "  echo \"groups=$(id -G)\"",
            "  echo '" & leaseMarker & "'",
            "  RUNQUOTA_SOCKET=" & socketPath & " " & toolDir &
              "/runquota acquire --cpu 1000 --mem 64MB" &
              " --label store-owner -- printf " & quoteShell("%s\\n") &
              " " & leaseToken & " || echo \"lease-exit=$?\"",
            "} > " & ownerReport & ".tmp 2>&1",
            "mv " & ownerReport & ".tmp " & ownerReport,
            "i=0",
            "while [ $i -lt 900 ]; do",
            "  [ -e " & stopFlag & " ] && break",
            "  sleep 0.2",
            "  i=$((i+1))",
            "done",
            "echo done > \"$out\""))
          ownerStarted = true
          fixture(waitForFile(ownerReport, 1200),
            "the owner's build wrote no report")
          let ownerText = readFile(ownerReport)
          let ownerUid = parseReport(ownerText).getOrDefault("uid")
          if leaseToken notin ownerText:
            echo ownerText
          fixture(ownerUid.len > 0, "the owner reported no uid")
          fixture(leaseToken in ownerText, "the owner's lease did not run")
          fixture(ownerUid != daemonUid,
            "the owner was handed the daemon's uid")

          # -----------------------------------------------------------------
          # THE CONTROL: the daemon's account finds the owner's execution in
          # the store, attributed to the owner. This is what makes "the
          # reader saw none" a statement about the reader.
          # -----------------------------------------------------------------
          writeFile(auditFlag, "audit\n")
          var audit = ""
          for _ in 0 ..< 200:
            if fileExists(auditReport):
              audit = readFile(auditReport)
              if rowsIn(audit).rowsOwnedBy(ownerUid).len > 0: break
            sleep(100)
          let recorded = rowsIn(audit).rowsOwnedBy(ownerUid)
          if recorded.len == 0:
            echo audit
            if fileExists(auditError): echo readFile(auditError)
            echo readFile(daemonLog)
          fixture(recorded.len >= 1,
            "the daemon's account found no execution of the owner's in the store")
          let storeFacts = parseReport(audit).getOrDefault("store")
          echo "  daemon uid " & daemonUid & ", owner uid " & ownerUid &
            "; store (mode uid gid as its owner sees it): " & storeFacts

          # -----------------------------------------------------------------
          # THE READER: a third uid, in the admission group, going for the
          # files. It is asked for its whole reading, not for a verdict.
          # -----------------------------------------------------------------
          let readerText = runAsSecondUid("reader", script(
            "export PATH=" & quoteShell(fixturePath()),
            "store=" & dbPath,
            "copy=\"$NIX_BUILD_TOP/copy.sqlite3\"",
            "{",
            "  echo \"uid=$(id -u)\"",
            "  echo \"groups=$(id -G)\"",
            "  if cat \"$store\" > /dev/null 2>&1; then",
            "    echo read_store=OK",
            "  else",
            "    echo read_store=DENIED",
            "  fi",
            # The write-ahead log is part of the store while the daemon
            # runs: rows it has committed may still be only there.
            "  cp \"$store\" \"$copy\" 2>/dev/null",
            "  cp \"$store-wal\" \"$copy-wal\" 2>/dev/null",
            "  echo '" & rowsMarker & "'",
            "  if [ -s \"$copy\" ]; then",
            "    sqlite3 -batch -noheader \"$copy\" " & rowQuery & " 2>&1",
            "  fi",
            "} > \"$out\" 2>&1",
            "exit 0"))
          let reader = parseReport(readerText)
          let readerUid = reader.getOrDefault("uid")
          fixture(readerUid.len > 0, "the reader reported no uid")
          # THREE DISTINCT UIDS, asserted: a reader that was the owner would
          # be reading its own rows, and one that was the daemon its own
          # file.
          fixture(readerUid != ownerUid, "the reader was handed the owner's uid")
          fixture(readerUid != daemonUid,
            "the reader was handed the daemon's uid")
          # And a PARTICIPANT: admitted to the socket by the same group the
          # store's file carries.
          fixture(memberGid in gidsIn(reader.getOrDefault("groups")),
            "the reader is not in the admission group")

          let disclosed = rowsIn(readerText).rowsOwnedBy(ownerUid)
          if reader.getOrDefault("read_store") != "DENIED" or
              disclosed.len > 0:
            echo "  uid " & readerUid & " is neither the daemon (" &
              daemonUid & ") nor the owner (" & ownerUid & "), and read " &
              $disclosed.len & " execution(s) of uid " & ownerUid &
              " from " & dbPath
            echo "  (mode uid gid: " & storeFacts &
              "; daemon umask " & serviceUmask &
              ") without asking the daemon:"
            for row in disclosed:
              echo "    owner_uid|execution_id|duration_millis = " & row

          # THE PROPERTY. The kernel refuses the open...
          check reader.getOrDefault("read_store") == "DENIED"
          # ...and nothing of the owner's reached the reader by any route
          # through the files.
          check disclosed.len == 0
        finally:
          writeFile(stopFlag, "stop\n")
          daemon.stopBuild()
          check not daemon.running
          daemon.close()
          if ownerStarted:
            owner.stopBuild()
            check not owner.running
            owner.close()
          cleanBackgroundWorkDirs()
          try:
            removeDir(root)
            removeDir(toolDir)
          except OSError:
            # Anything a build user left is the build user's; do not fail
            # the case over cleanup.
            discard
