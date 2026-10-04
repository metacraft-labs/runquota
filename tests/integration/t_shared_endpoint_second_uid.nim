## M13d: THE GATE IS A SECOND UID.
##
## This file executes the clauses M13c recorded as NOT RUN because they
## were NOT EXPRESSIBLE against a `runquota-$UID` endpoint inside a `0700`
## directory: a second uid attaching and being attributed correctly, and a
## second uid attempting a spoofed owner. Honest-but-unexecuted is a debt
## rather than a pass, so they are run here rather than left standing.
##
## THREE DIFFERENT UIDS TAKE PART, AND NONE OF THEM IS SIMULATED. This host
## has no passwordless `sudo`, so `su`, `sudo -u` and `dscl` are all
## unavailable. What IS available is Nix's build users: each concurrent
## `nix-build` runs as a different `_nixbld<N>`, with a real uid and a real
## kernel credential set. So:
##
##   * `runquotad` runs inside a long-running build, as one build user;
##   * the MEMBER client runs inside a second, concurrent build, as a
##     DIFFERENT build user that shares the daemon's group;
##   * the NON-MEMBER is this test process, which is in neither.
##
## THE MEMBER REACHES THE SOCKET THROUGH THE GROUP BITS, not the owner
## bits, which is the only arrangement that tests what the gate asks about.
## An earlier attempt ran the daemon as this uid with a builder as the
## client, and could not express the member half at all: `getgroups(2)`
## inside a Nix build returns ONLY the build group, whatever `id -G` says
## -- `id` answers from the directory service and the kernel answers from
## the process's credentials, and it is the kernel that decides a
## `connect(2)`. That is also why the group list below is read with
## `getgroups` (through the probe binary) rather than with `id`.
##
## WHICH LAYER REFUSED IS OBSERVED, NOT ASSUMED. The probe runs the
## application-level directory check FIRST and reports its answer, then
## attempts a RAW `connect(2)` and reports the raw errno. The non-member
## case is a pass only when the application check said `trustOk` and the
## KERNEL said `EACCES`: an application check that fired first would leave
## the filesystem boundary untested, and these assertions catch exactly
## that.
##
## PAIRED, so a build that refused everybody would fail rather than pass:
## the same daemon, the same socket, one uid served and one refused.
##
## No mocks anywhere -- a real `runquotad`, real distinct uids, real
## groups, a real `connect(2)`, the shipped CLI taking a real lease, and
## `owner_uid` read back out of the SQLite file the daemon wrote.
## Native builder tools are required immutable Nix-store inputs, not assumed
## /usr/bin or /bin executables. Their real closure is carried by each derivation.
## The leased child is external printf, whose tool identity supports Nix
## provisioning; the shell's echo builtin is only used inside builder scripts.
## Capture readiness is separate from socket readiness: sessions opened during
## store verification are intentionally not recorded (docs/database.md,
## "When the endpoint appears"). Wait for the capture-enabled startup line
## before opening the session whose persisted owner this fixture checks.

## POSIX ONLY, BY DESIGN. The boundary under test is the rendezvous GROUP:
## membership admits a client through the directory's and the socket's group
## bits, and the kernel refuses a non-member. On Windows the endpoint is a
## named pipe with no directory and no group -- `docs/database.md`
## §"Provisioning the host-wide state directory and the rendezvous" lists the
## Windows rendezvous as "— (named pipes)" with no owner, group or mode -- and
## the second uids here are Nix build users. Every case is reported skipped
## on Windows.

when not defined(posix):
  import std/unittest

  suite "shared_endpoint_second_uid_preflight":
    for name in [
        "the probe and the shipped binaries are placed where a second uid can reach them",
        "a real second uid is available, in a group THIS uid is not in"]:
      test name:
        skip()

  suite "shared_endpoint_second_uid_group_boundary":
    test "a member connects and is served; a non-member is refused by the KERNEL":
      skip()
else:
  import std/[os, osproc, posix, strutils, tables, times, unittest, sequtils]

  import daemon_binary

  const probeSource = "tests/support/rendezvous_probe.nim"

  proc modeOf(path: string): int =
    var info: Stat
    if lstat(path.cstring, info) != 0: return -1
    int(info.st_mode) and 0o7777

  proc ownerOf(path: string): int64 =
    var info: Stat
    if lstat(path.cstring, info) != 0: return -1
    int64(info.st_uid)

  proc groupOf(path: string): int64 =
    var info: Stat
    if lstat(path.cstring, info) != 0: return -1
    int64(info.st_gid)

  proc socketExists(path: string): bool =
    var info: Stat
    lstat(path.cstring, info) == 0 and S_ISSOCK(info.st_mode)

  proc myGroups(): seq[int64] =
    result.add(int64(getegid()))
    var buffer: array[0 .. 255, Gid]
    let count = getgroups(cint(buffer.len), addr buffer)
    for i in 0 ..< max(0, int(count)):
      result.add(int64(buffer[i]))

  const requiredFixtureTools = ["bash", "mkdir", "chmod", "mv", "cp", "rm",
                                "sleep", "printf", "sqlite3"]

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
        raise newException(ValueError, "invalid immutable fixture tool path: " & name)
      let root = path[0 ..< boundary]
      if root notin result: result.add(root)

  proc fixturePath(): string =
    var directories: seq[string] = @[]
    for name in requiredFixtureTools:
      let directory = parentDir(fixtureTools[name])
      if directory notin directories: directories.add(directory)
    directories.join(":")

  proc nixBuildExe(): string =
    # `followSymlinks = false` IS LOAD-BEARING. `nix-build` is a symlink to
    # the multicall `nix` binary, which dispatches on `argv[0]`; resolving
    # the link hands the child `argv[0] == "nix"`, which parses the arguments
    # as the NEW CLI, where `--no-out-link` does not exist.
    findExe("nix-build", followSymlinks = false)

  proc buildArgs(expression: string): seq[string] =
    # These builds provide distinct real credentials while sharing the host's
    # rendezvous socket. A Linux Nix sandbox has a private /tmp and cannot
    # reach that socket or the fixture binaries. This per-invocation option
    # leaves Nix's build-user separation and the kernel permission checks intact.
    @["--no-out-link", "--option", "sandbox", "false", expression]

  proc script(lines: varargs[string]): string =
    ## Joined with EXPLICIT newlines, and that is not a style preference. Nim
    ## strips the leading newline of every triple-quoted literal, so a shell
    ## script assembled by interpolating into `"""..."""` segments loses the
    ## break at each seam: two `export` lines become one word, the command
    ## after them is never executed, and the build still SUCCEEDS with an
    ## empty `$out`. That is a control that cannot fail, and it is what this
    ## file did on its first run.
    lines.join("\n") & "\n"

  proc writeExpression(workDir, nonce, scriptPath: string): string =
    result = workDir / "probe.nix"
    writeFile(result,
      "derivation {\n" &
      "  name = \"rq-m13d-" & nonce & "\";\n" &
      "  system = builtins.currentSystem;\n" &
      "  builder = builtins.storePath \"" & fixtureTools["bash"] & "\";\n" &
      "  runtimeToolRoots = [ " & fixtureToolRoots().mapIt(
        "(builtins.storePath \"" & it & "\")").join(" ") & " ];\n" &
      "  args = [ \"" & scriptPath & "\" ];\n" &
      "}\n")

  proc prepareBuild(label, body: string): tuple[workDir, expression: string] =
    ## The derivation NAME carries a nonce, so two invocations in one run are
    ## two builds rather than one build and one cache hit. A cached answer is
    ## the classic shape of a control that cannot fail.
    let nonce = $getCurrentProcessId() & "-" & $int(epochTime() * 1000.0) &
      "-" & label
    let workDir = "/tmp" / ("rqnix" & nonce)
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
    ## The same, left RUNNING. The daemon lives inside this build for as long
    ## as the build lasts, which is what gives it a uid this test does not
    ## have -- and what lets a SECOND, concurrent build hold a third.
    ##
    ## The scratch directory cannot be removed here -- the build is still
    ## reading its script -- so it is remembered and cleaned up once the
    ## process is gone. A suite that leaves litter in `/tmp` on every
    ## run is a suite nobody will keep running.
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

  proc parseReport(text: string): Table[string, string] =
    result = initTable[string, string]()
    for line in text.splitLines():
      let at = line.find('=')
      if at > 0:
        result[line[0 ..< at]] = line[at + 1 .. ^1]

  proc section(text, name: string): string =
    ## One client build emits several reports separated by markers, and each
    ## has its own `uid=` line. Parsing the whole thing at once would let a
    ## later section's value answer for an earlier one.
    let markers = ["--- honest ---", "--- spoof ---", "--- lease ---"]
    let start = text.find("--- " & name & " ---")
    if start < 0:
      return ""
    var stop = text.len
    for marker in markers:
      let at = text.find(marker, start + 1)
      if at >= 0 and at < stop:
        stop = at
    text[start ..< stop]

  proc gidsIn(field: string): seq[int64] =
    for part in field.split(','):
      if part.len > 0:
        try:
          result.add(int64(parseBiggestInt(part.strip())))
        except ValueError:
          discard

  # ---------------------------------------------------------------------------
  # Fixture, computed once from this host's real uids and real group lists.
  # ---------------------------------------------------------------------------

  var builderUid = -1'i64
  var builderGroups: seq[int64] = @[]
  var memberGid = -1'i64
  var probeBinary = ""
  var toolDir = ""

  suite "shared_endpoint_second_uid_preflight":
    test "the probe and the shipped binaries are placed where a second uid can reach them":
      ## Shared `/tmp` exists on macOS and Linux. A private TMPDIR or
      ## the build tree can be inaccessible to a second uid: a macOS home directory is
      ## `0750`, so a Nix build user cannot traverse into it and every
      ## `exec` of a binary under it fails with EACCES. (Observed: the first
      ## version of this file ran the shipped CLI straight out of
      ## `build/bin` and got "Permission denied".)
      check fileExists(probeSource)
      check fileExists(daemonPath())
      check fileExists(cliPath())
      toolDir = "/tmp" / ("rqbin" & $getCurrentProcessId())
      removeDir(toolDir)
      createDir(toolDir)
      check chmod(toolDir.cstring, Mode(0o755)) == 0

      let compiler = findExe("nim")
      check compiler.len > 0
      if compiler.len > 0:
        let binaryPath = toolDir / "probe"
        # THE INNER COMPILE INHERITS THIS FILE'S BUILD MODE. Same rule as the
        # driver in `t_stats_table_concurrency`: a fixture binary built with a
        # hardcoded argument list is built the same way whatever the suite was
        # built with, so any property that only shows up optimised is asserted
        # against a debug binary and cannot fail.
        var buildArgs = @["c", "--threads:on",
                          "--nimcache:build/nimcache/rendezvous_probe_second_uid",
                          "--out:" & binaryPath]
        when defined(release):
          buildArgs.add("-d:release")
        buildArgs.add(probeSource)
        let build = execProcess(compiler, args = buildArgs,
          env = nil, options = {poStdErrToStdOut})
        if not fileExists(binaryPath):
          echo build
        check fileExists(binaryPath)
        if fileExists(binaryPath):
          check chmod(binaryPath.cstring, Mode(0o755)) == 0
          probeBinary = binaryPath
        copyFile(daemonPath(), toolDir / "runquotad")
        copyFile(cliPath(), toolDir / "runquota")
        check chmod((toolDir / "runquotad").cstring, Mode(0o755)) == 0
        check chmod((toolDir / "runquota").cstring, Mode(0o755)) == 0

    test "a real second uid is available, in a group THIS uid is not in":
      check nixBuildExe().len > 0
      check probeBinary.len > 0
      if nixBuildExe().len > 0 and probeBinary.len > 0:
        # The probe is asked about a path that does not exist; all that is
        # wanted here is the credentials it reports, and they come from
        # `getuid`/`getgroups` rather than from `id`.
        let report = parseReport(runAsSecondUid("ids", script(
          "set -e",
          "export PATH=" & quoteShell(fixturePath()),
          probeBinary & " /tmp/rq-no-such-socket > \"$out\" 2>&1")))
        check report.hasKey("uid")
        if report.hasKey("uid"):
          builderUid = int64(parseBiggestInt(report["uid"]))
          builderGroups = gidsIn(report.getOrDefault("groups"))
          # A SECOND UID, not this one. Without this the whole file would be
          # a single-uid run wearing a costume.
          check builderUid != int64(getuid())
          require builderGroups.len > 0
          memberGid = builderGroups[0]
          echo "  second uid " & $builderUid & " groups " & $builderGroups
          echo "  member gid " & $memberGid & ", this uid " &
            $int64(getuid()) & " groups " & $myGroups()
          # ...and it is a group THIS uid is not in, which is what makes the
          # test process a genuine non-member.
          check memberGid notin myGroups()

  suite "shared_endpoint_second_uid_group_boundary":
    test "a member connects and is served; a non-member is refused by the KERNEL":
      if builderUid < 0 or memberGid < 0 or probeBinary.len == 0:
        echo "  NOT RUN: the preflight above did not produce a second uid"
        check false
      else:
        let root = "/tmp" / ("rqsu" & $getCurrentProcessId())
        removeDir(root)
        createDir(root)
        check chmod(root.cstring, Mode(0o755)) == 0
        let rv = root / "rv"
        createDir(rv)
        # 1777: the daemon build, running as a uid this process cannot
        # create files for, has to be able to make its own rendezvous
        # directory here. The boundary under test is `ep` itself.
        check chmod(rv.cstring, Mode(0o1777)) == 0
        let socketPath = rv / "ep" / "d.sock"
        let dbPath = rv / "state" / "obs.sqlite"
        let stopFlag = rv / "stop"
        let auditFlag = rv / "audit"
        let ownerReport = rv / "execution-owners"
        let auditError = rv / "audit-error"
        let sqlite = fixtureTools["sqlite3"]
        require sqlite.len > 0

        # PATH is set explicitly: a Nix builder gets `PATH=/path-not-set`,
        # and the observation store shells out to `sqlite3`.
        var daemon = startAsSecondUid("daemon", script(
          "set -e",
          "export PATH=" & quoteShell(fixturePath()),
          "export RUNQUOTA_ENDPOINT_GROUP=" & $memberGid,
          "mkdir -p " & rv & "/state",
          "chmod 0755 " & rv & "/state",
          toolDir & "/runquotad --socket " & socketPath &
            " --observation-db " & dbPath &
            " --host-identity-file " & rv & "/state/host-id" &
            " > " & rv & "/daemon.log 2>&1 &",
          "pid=$!",
          # READINESS IS REPORTED FROM INSIDE, and it has to be. The
          # rendezvous directory is 0750 in a group this process is not in,
          # so this process cannot even `lstat` the socket -- which is the
          # boundary working, not a defect. The socket's own owner, group and
          # mode are therefore observed by the uid that CAN see them and
          # relayed through a file in the 1777 parent.
          "j=0",
          "while [ $j -lt 600 ]; do",
          "  [ -S " & socketPath & " ] && break",
          "  " & quoteShell(fixtureTools["sleep"]) & " 0.1",
          "  j=$((j+1))",
          "done",
          probeBinary & " --stat " &
            socketPath & " > " & rv & "/socket-stat 2>&1 || true",
          "echo ready > " & rv & "/ready",
          "i=0",
          "while [ $i -lt 900 ]; do",
          # Inspect persisted attribution as the database's real owner. The
          # outsider must not need write access to the daemon's SQLite files.
          "  if [ -e " & auditFlag & " ]; then",
          "    " & quoteShell(sqlite) & " -readonly -batch -noheader " &
            dbPath & " 'select owner_uid from executions;' > " &
            ownerReport & ".tmp 2> " & auditError & " || true",
          "    mv " & ownerReport & ".tmp " & ownerReport,
          "  fi",
          "  [ -e " & stopFlag & " ] && break",
          "  kill -0 $pid 2>/dev/null || break",
          "  " & quoteShell(fixtureTools["sleep"]) & " 0.2",
          "  i=$((i+1))",
          "done",
          "kill $pid 2>/dev/null || true",
          quoteShell(fixtureTools["sleep"]) & " 0.5",
          "kill -9 $pid 2>/dev/null || true",
          "cp " & rv & "/daemon.log \"$out\" 2>/dev/null || " &
            "echo no-daemon-log > \"$out\"",
          # The builder made these and only the builder can unmake them:
          # `ep` is 0750 in a group this process is not in, and `state` is
          # owned by the build user. Left behind they would be undeletable
          # litter under /tmp.
          "rm -rf " & rv & "/ep " & rv & "/state"))
        let readyFlag = rv / "ready"
        let daemonLog = rv / "daemon.log"
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
          check fileExists(readyFlag)
          if not captureReady and fileExists(daemonLog):
            echo readFile(daemonLog)
          require captureReady
          if fileExists(readyFlag):
            let socketStat = parseReport(readFile(rv / "socket-stat"))
            let daemonUid = ownerOf(rv / "ep")
            # The rendezvous belongs to a uid this test does not have, which
            # is the deployment shape: daemon-owned, group-traversable.
            check daemonUid != int64(getuid())
            check modeOf(rv / "ep") == 0o750
            check groupOf(rv / "ep") == memberGid
            # The socket itself, as seen by the only uid that can see it.
            check socketStat.getOrDefault("sock_mode") == "660"
            check socketStat.getOrDefault("sock_uid") == $daemonUid
            check socketStat.getOrDefault("sock_gid") == $memberGid
            # And THIS uid cannot even stat it, which is the boundary
            # reported from the outside.
            check not socketExists(socketPath)

            # ---------------------------------------------------------------
            # NON-MEMBER: this process. Not the owner, not in the group.
            # ---------------------------------------------------------------
            putEnv("RUNQUOTA_ENDPOINT_OWNER_UID", $daemonUid)
            putEnv("RUNQUOTA_ENDPOINT_GROUP", $memberGid)
            let outsider = parseReport(execProcess(probeBinary,
              args = [socketPath], env = nil, options = {poStdErrToStdOut}))
            delEnv("RUNQUOTA_ENDPOINT_OWNER_UID")
            delEnv("RUNQUOTA_ENDPOINT_GROUP")
            check outsider.getOrDefault("uid") == $int64(getuid())
            check memberGid notin gidsIn(outsider.getOrDefault("groups"))
            # THE DECIDING OBSERVATION. Our own predicate looked at the
            # directory and found it in order -- correct owner, correct
            # group, correct mode -- so NOTHING THIS PROJECT RUNS refused
            # this caller...
            check outsider.getOrDefault("app_trust") == "trustOk"
            check outsider.getOrDefault("app_message") == ""
            check outsider.getOrDefault("app_mode") == "0750"
            check outsider.getOrDefault("app_owner") == $daemonUid
            check outsider.getOrDefault("app_group") == $memberGid
            # ...and the connection failed anyway, in the kernel, with the
            # errno a directory without search permission produces.
            check outsider.getOrDefault("connect") == "EACCES"
            check outsider.getOrDefault("connect_errno") == $int(EACCES)
            check outsider.getOrDefault("hello") == "not-attempted"

            # ---------------------------------------------------------------
            # MEMBER: a third uid, in the daemon's group, reaching the socket
            # through the GROUP bits.
            # ---------------------------------------------------------------
            let clientText = runAsSecondUid("client", script(
              "set -e",
              "export PATH=" & quoteShell(fixturePath()),
              "export RUNQUOTA_ENDPOINT_GROUP=" & $memberGid,
              "export RUNQUOTA_ENDPOINT_OWNER_UID=" & $daemonUid,
              "{",
              "  echo '--- honest ---'",
              "  " & probeBinary & " " & socketPath,
              "  echo '--- spoof ---'",
              "  " & probeBinary & " " & socketPath & " " & $int64(getuid()),
              "  echo '--- lease ---'",
              "  RUNQUOTA_SOCKET=" & socketPath & " " & toolDir &
                "/runquota acquire --cpu 1000 --mem 64MB" &
                " --label m13d-second-uid -- " & quoteShell(fixtureTools["printf"]) &
                " " & quoteShell("%s\\n") & " m13d-second-uid-ok",
              "} > \"$out\" 2>&1"))

            let honest = parseReport(section(clientText, "honest"))
            let clientUid = honest.getOrDefault("uid")
            check clientUid.len > 0
            # THREE DISTINCT UIDS, stated as an assertion rather than hoped
            # for: a client that happened to be the daemon would reach the
            # socket through the OWNER bits and prove nothing about groups.
            check clientUid != $int64(getuid())
            check clientUid != $daemonUid
            check memberGid in gidsIn(honest.getOrDefault("groups"))
            check honest.getOrDefault("app_trust") == "trustOk"
            check honest.getOrDefault("app_mode") == "0750"
            check honest.getOrDefault("connect") == "OK"
            check honest.getOrDefault("hello") == "ok"

            # M13c's spoofed-owner clause, from a SECOND UID at last. The
            # single-uid version could only have one process declare a uid
            # nobody owned; this is a real other user declaring THIS one.
            let spoof = parseReport(section(clientText, "spoof"))
            check spoof.getOrDefault("uid") == clientUid
            check spoof.getOrDefault("connect") == "OK"
            check spoof.getOrDefault("declared_uid") == $int64(getuid())
            check spoof.getOrDefault("hello") == "error"
            check spoof.getOrDefault("hello_code") == "diagDenied"
            check $int64(getuid()) in spoof.getOrDefault("hello_message")
            check clientUid in spoof.getOrDefault("hello_message")
            check "peer credentials" in spoof.getOrDefault("hello_message")

            # AND THE ROW IS ATTRIBUTED TO THE MEMBER'S OWN UID. This is the
            # clause a single-uid host could not state at all: `owner_uid`
            # was a constant per store, so "read from peer credentials" and
            # "read from the client's declaration" were indistinguishable by
            # the recorded value.
            check "m13d-second-uid-ok" in section(clientText, "lease")
            writeFile(auditFlag, "audit\n")
            var owners: seq[string] = @[]
            for _ in 0 ..< 100:
              if fileExists(ownerReport):
                let report = readFile(ownerReport).strip()
                if report.len > 0:
                  owners = report.splitLines()
                  break
              sleep(100)
            if owners.len == 0:
              if fileExists(auditError): echo readFile(auditError)
              if fileExists(rv / "daemon.log"): echo readFile(rv / "daemon.log")
            check owners.len >= 1
            for owner in owners:
              check owner == clientUid
              check owner != $int64(getuid())
              check owner != $daemonUid
        finally:
          writeFile(stopFlag, "stop\n")
          discard daemon.waitForExit(120_000)
          if daemon.running:
            daemon.terminate()
            discard daemon.waitForExit(10_000)
          if daemon.running:
            daemon.kill()
            discard daemon.waitForExit(10_000)
          check not daemon.running
          daemon.close()
          cleanBackgroundWorkDirs()
          try:
            removeDir(root)
            removeDir(toolDir)
          except OSError:
            # Anything the build user left is the build user's; do not fail
            # the clause over cleanup.
            discard
