## Explicit private endpoints use real daemon/client processes and filesystem
## objects. No mocks or NSS edits: documented host owner/group overrides model
## an installed account independently of the uid running the test. Expected
## modes are literals, never calculated through the policy under test.
## POSIX-only contract; Windows has no Unix rendezvous directory to verify.

when defined(posix):
  import std/[json, monotimes, os, osproc, posix, streams, strutils, strtabs,
    tempfiles, unittest]
  import runquota_ipc
  import daemon_binary
  from runquota_core/child_process import runCapturedProcess

  const PolicyKeys = ["RUNQUOTA_ENDPOINT_SCOPE", "RUNQUOTA_ENDPOINT_OWNER_UID",
    "RUNQUOTA_ENDPOINT_GROUP", "RUNQUOTA_SOCKET"]

  proc prerequisite(condition: bool; message = "fixture prerequisite failed") =
    # Always active, including release/danger; CatchableError unwinds owned
    # fixture cleanup instead of unittest.require's process-wide quit.
    if not condition: raise newException(IOError, message)

  proc scratchDir(prefix: string): string =
    result = createTempDir(prefix, "")
    setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})

  proc cleanEnvironment(): StringTableRef =
    result = newStringTable(modeCaseSensitive)
    for key, value in envPairs():
      if key notin PolicyKeys: result[key] = value

  proc modeOf(path: string): int =
    var info: Stat
    if lstat(path.cstring, info) != 0: return -1
    int(info.st_mode) and 0o7777

  proc isSocket(path: string): bool =
    var info: Stat
    lstat(path.cstring, info) == 0 and S_ISSOCK(info.st_mode)

  proc stop(daemon: Process): int {.discardable.} =
    if daemon.running:
      daemon.terminate()
    result = daemon.waitForExit(5000)
    if daemon.running:
      daemon.kill()
      discard daemon.waitForExit(5000)
      result = -1
    try:
      prerequisite not daemon.running, "owned daemon did not exit"
    finally:
      daemon.close()

  proc launch(root, socket: string; env: StringTableRef): Process =
    # Capture is enabled normally, with all mutable files inside this fixture.
    startProcess(daemonPath(), env = env, args = ["--socket", socket,
      "--host-config", root / "host.toml", "--estimate-db", root / "est.sqlite",
      "--observation-db", root / "obs.sqlite",
      "--host-identity-file", root / "host-id",
      "--ambient-sample-interval-millis", "0"],
      options = {poStdErrToStdOut})

  proc awaitSocket(daemon: Process; socket: string): bool =
    for _ in 0 ..< 400:
      if isSocket(socket): return true
      if not daemon.running: return false
      sleep(25)

  proc privateEnv(socket: string): StringTableRef =
    result = cleanEnvironment()
    result["RUNQUOTA_ENDPOINT_SCOPE"] = "private"
    result["RUNQUOTA_SOCKET"] = socket
    # These are valid, resolvable host settings that disagree with private
    # ownership. They must not leak into the explicitly private policy.
    result["RUNQUOTA_ENDPOINT_OWNER_UID"] = $(int64(geteuid()) + 1)
    result["RUNQUOTA_ENDPOINT_GROUP"] = $int64(getegid())

  proc cli(env: StringTableRef; args = @["status", "--json"]):
      tuple[code: int, output: string] =
    let captured = runCapturedProcess(cliPath(), args, env = env,
      options = {})
    prerequisite captured.failure.len == 0, captured.failure
    (captured.exitCode, captured.output & captured.error)

  suite "explicit private rendezvous":
    test "private daemon and actual client ignore installed host identity, and clean up":
      let root = scratchDir("rqp")
      defer: removeDir(root)
      let socket = root / "ep" / "d.sock"
      let env = privateEnv(socket)
      let daemon = launch(root, socket, env)
      defer: stop(daemon)
      prerequisite awaitSocket(daemon, socket)
      check "private invocation endpoint" in daemon.outputStream.readLine()
      check modeOf(root / "ep") == 0o700
      check modeOf(socket) == 0o600
      var info: Stat
      prerequisite lstat(socket.cstring, info) == 0
      check info.st_uid == geteuid()
      let connected = cli(env)
      checkpoint connected.output
      check connected.code == 0
      check "active_sessions" in connected.output
      # The socket and DB can exist before verification finishes. Ask the
      # real daemon, within the original ten-second readiness window.
      let captureDeadline = getMonoTime().ticks + 10_000_000_000'i64
      var captureReady = false
      while getMonoTime().ticks < captureDeadline:
        let inspection = cli(env, @["observations", "--json"])
        prerequisite inspection.code == 0, inspection.output
        let observations = parseJson(inspection.output)["observations"]
        if observations["capture_enabled"].getBool():
          check not observations["write_stats_disabled"].getBool()
          check observations["store_path"].getStr() == root / "obs.sqlite"
          captureReady = true
          break
        sleep(25)
      prerequisite captureReady, "private daemon did not enable capture"
      # Keep argv[0]'s named multicall alias (Nix coreutils dispatches by it).
      let printf = findExe("printf", followSymlinks = false)
      prerequisite printf.len > 0, "the normal test shell must supply printf"
      let executed = cli(env, @["acquire", "--cpu", "100", "--mem", "1048576",
        "--label", "private-policy-work", "--stats-key", "rq-private-policy",
        "--", printf, "private-lease-ok\n"])
      check executed.code == 0
      check executed.output == "private-lease-ok\n"
      let completed = cli(env)
      prerequisite completed.code == 0, completed.output
      let status = parseJson(completed.output)
      # A standalone fallback can run printf too. Only this daemon can
      # supply these completed-lease counters and the recorded execution.
      check status["total_granted"].getInt() == 1
      check status["total_finished"].getInt() == 1
      check status["active_leases"].getInt() == 0
      let exported = runCapturedProcess(cliPath(),
        @["stats", "export", "rq-private-policy", "--json"], env = env,
        options = {})
      prerequisite exported.failure.len == 0, exported.failure
      checkpoint exported.output & exported.error
      check exported.exitCode == 0
      let exportResult = parseJson(exported.output)
      check exportResult["capture_enabled"].getBool()
      let rows = exportResult["rows"]
      prerequisite rows.len == 1, exported.output
      let execution = rows[0]
      check execution["command_stats_id"].getStr() == "rq-private-policy"
      check execution["exit_status"].getInt() == 0
      let hostClient = cleanEnvironment()
      hostClient["RUNQUOTA_SOCKET"] = socket
      hostClient["RUNQUOTA_ENDPOINT_OWNER_UID"] = $int64(geteuid())
      hostClient["RUNQUOTA_ENDPOINT_GROUP"] = $int64(getegid())
      let refused = cli(hostClient)
      check refused.code != 0
      check "required 0750" in refused.output
      daemon.terminate()
      check daemon.waitForExit(5000) == 0
      check not isSocket(socket)

    test "default host still refuses a foreign owner and private directory modes":
      for foreignOwner in [true, false]:
        let root = scratchDir("rqh")
        defer: removeDir(root)
        let dir = root / "ep"
        createDir(dir)
        setFilePermissions(dir, {fpUserRead, fpUserWrite, fpUserExec})
        let socket = dir / "d.sock"
        let env = cleanEnvironment()
        env["RUNQUOTA_ENDPOINT_OWNER_UID"] =
          $(int64(geteuid()) + (if foreignOwner: 1 else: 0))
        env["RUNQUOTA_ENDPOINT_GROUP"] = $int64(getegid())
        let daemon = launch(root, socket, env)
        defer: stop(daemon)
        check daemon.waitForExit(5000) == 3
        let output = daemon.outputStream.readAll()
        checkpoint output
        check not isSocket(socket)
        if foreignOwner: check "configured daemon owner uid" in output
        else: check "required 0750" in output

    test "private daemon refuses wrong modes and symlink directories without repair":
      for symlink in [false, true]:
        let root = scratchDir("rqb")
        defer: removeDir(root)
        let dir = root / "ep"
        if symlink:
          createDir(root / "target")
          setFilePermissions(root / "target", {fpUserRead, fpUserWrite, fpUserExec})
          createSymlink(root / "target", dir)
        else:
          createDir(dir)
          setFilePermissions(dir, {fpUserRead, fpUserWrite, fpUserExec, fpGroupExec})
        let socket = dir / "d.sock"
        let daemon = launch(root, socket, privateEnv(socket))
        defer: stop(daemon)
        check daemon.waitForExit(5000) == 3
        let output = daemon.outputStream.readAll()
        checkpoint output
        check not isSocket(socket)
        if symlink: check "not a directory" in output
        else:
          check "required 0700" in output
          check modeOf(dir) == 0o710

    test "actual private client refuses a widened socket and a symlink socket":
      let root = scratchDir("rqc")
      defer: removeDir(root)
      let socket = root / "ep" / "d.sock"
      let env = privateEnv(socket)
      let daemon = launch(root, socket, env)
      defer: stop(daemon)
      prerequisite awaitSocket(daemon, socket)
      prerequisite cli(env).code == 0
      prerequisite chmod(socket.cstring, Mode(0o660)) == 0
      let widened = cli(env)
      check widened.code != 0
      check "required 0600" in widened.output
      prerequisite chmod(socket.cstring, Mode(0o600)) == 0
      prerequisite cli(env).code == 0
      let moved = socket & ".original"
      moveFile(socket, moved)
      createSymlink(moved, socket)
      let linked = cli(env)
      check linked.code != 0
      check "not a socket" in linked.output
      removeFile(socket)
      moveFile(moved, socket)
      check cli(env).code == 0

    test "private owner, reserved and relative paths fail closed; host checks stay independent":
      let root = scratchDir("rqt")
      defer: removeDir(root)
      let endpoint = unixEndpoint(root / "d.sock")
      var privatePolicy = privateRendezvousPolicy()
      check privatePolicy.scope == rendezvousPrivate
      check privatePolicy.ownerUid == int64(geteuid())
      privatePolicy.ownerUid += 1
      check endpointDirectoryTrust(endpoint, privatePolicy).reason == trustForeignOwner
      expect EndpointTrustError:
        discard bindEndpoint(endpoint, privatePolicy)
      let p = privateRendezvousPolicy()
      for path in ["", hostWideEndpointDir / "runquotad.sock", "relative/d.sock",
                   root / "d.sock" & '\0' & "suffix"]:
        expect EndpointTrustError:
          discard bindEndpoint(unixEndpoint(path), p)
        expect EndpointTrustError:
          discard connectEndpoint(unixEndpoint(path), p)
      check not isSocket(root / "d.sock")

    test "unknown scope and implicit default private selection are refused by real programs":
      let root = scratchDir("rqi")
      defer: removeDir(root)
      for scope in ["", "PRIVATE", "invalid"]:
        let socket = root / "d.sock"
        let env = cleanEnvironment()
        env["RUNQUOTA_ENDPOINT_SCOPE"] = scope
        let daemon = launch(root, socket, env)
        defer: stop(daemon)
        check daemon.waitForExit(5000) == 3
        let daemonRefusal = daemon.outputStream.readAll()
        check "RUNQUOTA_ENDPOINT_SCOPE must be host or private" in daemonRefusal
        check "unhandled exception" notin daemonRefusal
        check not isSocket(socket)
        let refusal = cli(env)
        check refusal.code != 0
        check "RUNQUOTA_ENDPOINT_SCOPE must be host or private" in refusal.output
      let env = cleanEnvironment()
      env["RUNQUOTA_ENDPOINT_SCOPE"] = "private"
      let refusal = cli(env)
      check refusal.code != 0
      check "outside the host rendezvous" in refusal.output

    test "host directory aliases with absent descendants are refused without touching them":
      let root = scratchDir("rqa")
      defer: removeDir(root)
      let alias = root / "host-parent"
      createSymlink(parentDir(hostWideEndpointDir), alias)
      let hostName = lastPathPart(hostWideEndpointDir)
      let absent = lastPathPart(root)
      let policy = privateRendezvousPolicy()
      # These are PURE checks, never bind/connect into system paths even
      # when a regression incorrectly returns trustMissing.
      for prefix in [hostWideEndpointDir, alias & "/" & hostName]:
        for suffix in ["/" & absent & "/child",
                       "/" & absent & "/child/../.."]:
          let endpoint = unixEndpoint(prefix & suffix & "/d.sock")
          let trust = endpointDirectoryTrust(endpoint, policy)
          check trust.reason == trustWrongType
          check "outside the host rendezvous" in trust.message
      # Exercise the real OS alias too when the OS supplies it. The
      # scratch alias above always covers the regression, on every POSIX host.
      let alternate = when defined(macosx): "/private/var/run" else: "/var/run"
      if dirExists(alternate) and dirExists(parentDir(hostWideEndpointDir)) and
          expandFilename(alternate) == expandFilename(parentDir(hostWideEndpointDir)):
        check endpointDirectoryTrust(unixEndpoint(alternate & "/" & hostName &
          "/" & absent & "/child/d.sock"), policy).reason == trustWrongType
      check not dirExists(hostWideEndpointDir & "/" & absent)

    test "an ordinary ancestor alias and symlink dotdot serve a real private client":
      let root = scratchDir("rqo")
      defer: removeDir(root)
      let actual = root / "actual"
      createDir(actual / "child")
      setFilePermissions(actual, {fpUserRead, fpUserWrite, fpUserExec})
      setFilePermissions(actual / "child", {fpUserRead, fpUserWrite, fpUserExec})
      let alias = root / "alias"
      createSymlink(actual / "child", alias)
      # Keep the raw spelling: joining/normalizing before resolving alias
      # would choose root/ep rather than actual/ep.
      let socket = alias & "/../ep/d.sock"
      let daemon = launch(root, socket, privateEnv(socket))
      defer: stop(daemon)
      prerequisite awaitSocket(daemon, socket), "ancestor-alias daemon did not bind"
      check isSocket(actual / "ep" / "d.sock")
      check modeOf(actual / "ep") == 0o700
      check not dirExists(root / "ep")
      let connected = cli(privateEnv(socket))
      check connected.code == 0
      check "active_sessions" in connected.output

    test "path resolution retains missing suffixes and refuses malformed ancestors before mutation":
      let root = scratchDir("rqr")
      defer: removeDir(root)
      createDir(root / "real" / "child")
      createDir(root / "boundary")
      createDir(root / "boundary-other")
      let alias = root / "alias"
      createSymlink(root / "real" / "child", alias)
      check resolveDirectoryPath(alias & "/../missing/x/../..") ==
        expandFilename(root / "real")
      check resolveDirectoryPath(alias & "/../missing/x/../../child") ==
        expandFilename(root / "real" / "child")
      check not directoryResolvesWithin(root / "boundary-other", root / "boundary")
      check directoryResolvesWithin(root, "/")
      check resolveDirectoryPath("/../../") == "/"
      let loop = root / "loop"
      createSymlink("loop", loop)
      let (file, name) = createTempFile("ancestor", "", root)
      file.close()
      let policy = privateRendezvousPolicy()
      for ancestor in [loop, name]:
        let socket = ancestor & "/absent/d.sock"
        let endpoint = unixEndpoint(socket)
        check endpointDirectoryTrust(endpoint, policy).reason == trustUnreadable
        expect EndpointTrustError:
          discard bindEndpoint(endpoint, policy)
        expect EndpointTrustError:
          discard connectEndpoint(endpoint, policy)
        check not isSocket(socket)
      check not dirExists(root / "absent")
      check fileExists(name)

    test "private policy fields cannot widen modes or select another principal":
      let root = scratchDir("rqv")
      defer: removeDir(root)
      for field in 0 .. 3:
        let directory = root / $field
        let endpoint = unixEndpoint(directory / "d.sock")
        var policy = privateRendezvousPolicy()
        case field
        of 0: policy.directoryMode = 0o750
        of 1: policy.socketMode = 0o660
        of 2: policy.ownerUid += 1
        else: policy.groupGid = int64(getegid())
        expect EndpointTrustError:
          discard bindEndpoint(endpoint, policy)
        expect EndpointTrustError:
          discard connectEndpoint(endpoint, policy)
        check not dirExists(directory)
        check not isSocket(endpoint.path)

    test "original one-argument callback types remain compatible":
      type Connector = proc(endpoint: Endpoint): LocalConnection {.nimcall.}
      type Binder = proc(endpoint: Endpoint): LocalListener {.nimcall.}
      let connector: Connector = connectEndpoint
      let binder: Binder = bindEndpoint
      check connector != nil
      check binder != nil

    test "unknown selector uses the existing endpoint trust error boundary":
      let hadScope = existsEnv("RUNQUOTA_ENDPOINT_SCOPE")
      let previous = getEnv("RUNQUOTA_ENDPOINT_SCOPE")
      defer:
        if hadScope: putEnv("RUNQUOTA_ENDPOINT_SCOPE", previous)
        else: delEnv("RUNQUOTA_ENDPOINT_SCOPE")
      putEnv("RUNQUOTA_ENDPOINT_SCOPE", "invalid")
      let root = scratchDir("rqe")
      defer: removeDir(root)
      let endpoint = unixEndpoint(root / "absent" / "d.sock")
      expect EndpointTrustError:
        discard connectEndpoint(endpoint)
      expect EndpointTrustError:
        discard bindEndpoint(endpoint)
      check not dirExists(root / "absent")

    test "a failed real prerequisite unwinds the exact ready daemon fixture":
      let root = scratchDir("rqf")
      defer: removeDir(root)
      let socket = root / "ep" / "d.sock"
      var daemon: Process
      var cleanupRan = false
      var ownedPid = 0
      var cleanedPid = 0
      var cleanedExit = -1
      # If the inner cleanup regresses, retain the real handle so this
      # negative control reports the defect and still reaps its own child.
      defer:
        if daemon != nil and not cleanupRan: stop(daemon)
      proc failingFixture() =
        daemon = launch(root, socket, privateEnv(socket))
        ownedPid = daemon.processID()
        defer:
          cleanedPid = daemon.processID()
          cleanedExit = stop(daemon)
          cleanupRan = true
        prerequisite awaitSocket(daemon, socket), "fixture never became ready"
        prerequisite cli(privateEnv(socket)).code == 0, "fixture client failed"
        prerequisite false, "controlled ready-fixture prerequisite failure"
      var caught = false
      try:
        failingFixture()
      except IOError as error:
        check error.msg == "controlled ready-fixture prerequisite failure"
        caught = true
      check caught
      check cleanupRan
      check ownedPid > 0
      check cleanedPid == ownedPid
      check cleanedExit == 0
      check not isSocket(socket)

    test "private bind preserves an existing endpoint and close preserves a replacement inode":
      let root = scratchDir("rqn")
      defer: removeDir(root)
      let endpoint = unixEndpoint(root / "d.sock")
      let policy = privateRendezvousPolicy()
      var first = bindEndpoint(endpoint, policy)
      defer: first.close()
      expect EndpointTrustError:
        discard bindEndpoint(endpoint, policy)
      check isSocket(endpoint.path)
      prerequisite unlink(endpoint.path.cstring) == 0
      var replacement = bindEndpoint(endpoint, policy)
      defer: replacement.close()
      first.close()
      check isSocket(endpoint.path)
      replacement.close()
      check not isSocket(endpoint.path)
