## Genuine-daemon transport controls. The proxy only forwards real frames;
## delaying, corrupting, or replaying one genuine response is necessary to
## exercise uncertainty that a healthy scheduler cannot produce on demand.
import std/[os, osproc, streams, json, tempfiles, times, monotimes]
import runquota_client, runquota_core, runquota_ipc, runquota_protocol
import daemon_binary, scratch_root

when defined(posix):
  import std/posix

  # Nim 2.2.4 does not expose this flag; bind the selected system header
  # rather than guessing its different Linux and Darwin numeric values.
  let noFollowOpenFlag {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint

  proc reapOwned(child: Process; stop: bool): bool =
    ## Only this Process object's unreaped child is signaled. A timed wait
    ## alone is never a drain: escalation is followed by an authoritative wait.
    ## Return true for escalation so cleanup cannot turn a timeout into success.
    try:
      if stop and child.running:
        child.terminate()
    finally:
      let code = child.waitForExit(1000)
      if code == -1:
        result = true
        try:
          child.kill()
        finally:
          discard child.waitForExit()
      child.close()

  proc requestProbe*(mode, endpoint: string) =
    putEnv("RUNQUOTA_SOCKET", endpoint)
    var client = runquota_client.connectDefault()
    if mode == "status":
      let status = client.daemonStatus()
      client.close()
      stdout.writeLine($(%*{"sessions": status.activeSessions,
        "leases": status.activeLeases, "grants": status.totalGranted}))
      return
    var session = client.registerSession("bounded-request-control", "1")
    let request = resourceRequest("bounded-control", milliCpu(100),
      bytes(16'u64 * 1024 * 1024))
    try:
      case mode
      of "negative", "overflow":
        when sizeof(int) <= sizeof(int32):
          if mode == "overflow":
            raise newException(ValueError,
              "An above-int32 timeout is not representable on this target")
        let before = client.nextRequestId
        var refused = false
        try:
          discard session.requestLease(request,
            timeoutMs = (if mode == "negative": -1 else: high(int)))
        except RunQuotaClientError:
          refused = true
        doAssert refused and client.nextRequestId == before
        doAssert client.state == csConnected and session.active
      of "timeout", "malformed", "unrelated":
        if mode == "unrelated": discard client.daemonStatus()
        var refused = false
        try:
          discard session.requestLease(request, timeoutMs = 100)
        except RunQuotaClientError:
          refused = true
        doAssert refused and client.state == csClosed and not session.active
      of "denial":
        var refused = false
        try:
          discard session.requestLease(resourceRequest("denied-control",
            milliCpu(100), bytes(512'u64 * 1024 * 1024)), timeoutMs = 1000)
        except RunQuotaClientError:
          refused = true
        doAssert refused and client.state == csConnected and session.active
        var lease = session.requestLease(request, timeoutMs = 1000)
        doAssert lease.active
        lease.release()
      of "default", "finite":
        var lease =
          if mode == "default": session.requestLease(request)
          else: session.requestLease(request, timeoutMs = 1000)
        doAssert lease.active
        lease.release()
      else:
        raise newException(ValueError, "Unknown bounded-request control")
    finally:
      if session.active: session.closeSession()
      client.close()
    stdout.writeLine("control passed")

  proc transportProxy*(target, endpoint, mode: string) =
    var listener = bindEndpoint(unixEndpoint(endpoint))
    defer: listener.close()
    var downstream = listener.acceptConnection()
    defer: downstream.close()
    var upstream = connectEndpoint(unixEndpoint(target))
    defer: upstream.close()
    var statusFrame: RqspFrame
    var haveStatus = false
    while true:
      var request: RqspFrame
      if not downstream.receiveFrame(request, 1000): break
      upstream.sendFrame(encodeFrame(request.header.messageKind,
        request.header.flags, request.header.requestId, request.payload), 1000)
      var response: RqspFrame
      doAssert upstream.receiveFrame(response, 1000)
      if response.header.messageKind == rqStatusResponse:
        statusFrame = response
        haveStatus = true
      if response.header.messageKind == rqLeaseGranted:
        case mode
        of "timeout": sleep(400)
        of "default-delayed": sleep(250)
        of "malformed": response.payload = ""
        of "unrelated":
          doAssert haveStatus
          for _ in 0 ..< 12:
            try:
              downstream.sendFrame(encodeFrame(statusFrame.header.messageKind,
                statusFrame.header.flags, statusFrame.header.requestId,
                statusFrame.payload), 1000)
            except OSError:
              return
            sleep(30)
        else: discard
      try:
        downstream.sendFrame(encodeFrame(response.header.messageKind,
          response.header.flags, response.header.requestId, response.payload), 1000)
      except OSError:
        return

  proc probe(executable, mode, endpoint: string): tuple[code: int, output: string] =
    let child = startProcess(executable,
      args = ["--request-probe", mode, endpoint], options = {poStdErrToStdOut})
    try:
      result.code = child.waitForExit(5000)
      if result.code == -1:
        raise newException(OSError, "Bounded request probe did not finish")
      result.output = child.outputStream.readAll()
    finally:
      if reapOwned(child, stop = true):
        raise newException(OSError, "Owned probe required hard cancellation")

  proc ownedSocketExists(path: string): bool =
    # std/os.fileExists deliberately rejects sockets. Require the actual
    # no-follow socket kind, expected owner, and private endpoint policy.
    var info: Stat
    result = posix.lstat(path.cstring, info) == 0 and S_ISSOCK(info.st_mode) and
      info.st_uid == getuid() and (info.st_mode and Mode(0o7777)) == Mode(0o600)

  proc realTransportScenario*(mode: string) =
    # Explicitly short and exclusive: macOS sun_path is only 104 bytes.
    let root = createTempDir("rqb-", "", "/tmp")
    var created: Stat
    doAssert posix.lstat(root.cstring, created) == 0
    doAssert S_ISDIR(created.st_mode) and created.st_uid == getuid()
    let rootFd = posix.open(root.cstring, O_RDONLY or noFollowOpenFlag)
    doAssert rootFd >= 0
    defer: discard posix.close(rootFd)
    var held: Stat
    doAssert posix.fstat(rootFd, held) == 0
    doAssert held.st_dev == created.st_dev and held.st_ino == created.st_ino
    doAssert held.st_uid == created.st_uid and S_ISDIR(held.st_mode)
    # createTempDir follows the caller's umask. Apply the daemon's strict
    # owner-only policy to this held, newly created directory, never a target
    # reached by following a symlink or a subsequently replaced pathname.
    doAssert posix.fchmod(rootFd, Mode(0o700)) == 0
    proc rootStillOwned(): bool =
      var current, opened: Stat
      result = posix.lstat(root.cstring, current) == 0 and
        posix.fstat(rootFd, opened) == 0 and S_ISDIR(current.st_mode) and
        S_ISDIR(opened.st_mode) and current.st_uid == created.st_uid and
        opened.st_uid == created.st_uid and current.st_dev == created.st_dev and
        opened.st_dev == created.st_dev and current.st_ino == created.st_ino and
        opened.st_ino == created.st_ino and
        (current.st_mode and Mode(0o7777)) == Mode(0o700) and
        (opened.st_mode and Mode(0o7777)) == Mode(0o700)
    defer:
      doAssert rootStillOwned(), "Owned test directory identity changed"
      removeScratchRoot(root)
    doAssert rootStillOwned()
    let endpoint = root / "daemon.sock"
    let proxyEndpoint = root / "proxy.sock"
    let oldOwner = getEnv("RUNQUOTA_ENDPOINT_OWNER_UID")
    let oldGroup = getEnv("RUNQUOTA_ENDPOINT_GROUP")
    putEnv("RUNQUOTA_ENDPOINT_OWNER_UID", $getuid())
    putEnv("RUNQUOTA_ENDPOINT_GROUP", "")
    defer:
      if oldOwner.len == 0: delEnv("RUNQUOTA_ENDPOINT_OWNER_UID")
      else: putEnv("RUNQUOTA_ENDPOINT_OWNER_UID", oldOwner)
      if oldGroup.len == 0: delEnv("RUNQUOTA_ENDPOINT_GROUP")
      else: putEnv("RUNQUOTA_ENDPOINT_GROUP", oldGroup)
    let daemon = startProcess(daemonPath(), args = ["--socket", endpoint,
      "--cpu-milli", "1000", "--memory-bytes", $(128 * 1024 * 1024),
      "--io-slots", "1", "--no-write-stats",
      "--host-identity-file", root / "host-id", "--estimate-db", root / "estimate.db"],
      options = {poStdErrToStdOut})
    defer:
      if reapOwned(daemon, stop = true):
        raise newException(OSError, "Owned daemon required hard cancellation")
    for _ in 0 ..< 100:
      if ownedSocketExists(endpoint): break
      doAssert daemon.running, "Owned daemon exited before socket readiness (exit " &
        $daemon.peekExitCode & ")"
      sleep(20)
    doAssert ownedSocketExists(endpoint)
    var proxy: Process
    defer:
      if proxy != nil:
        if reapOwned(proxy, stop = true):
          raise newException(OSError, "Owned proxy required hard cancellation")
    var selected = endpoint
    if mode in ["default-delayed", "timeout", "malformed", "unrelated"]:
      selected = proxyEndpoint
      proxy = startProcess(getAppFilename(),
        args = ["--transport-proxy", endpoint, selected, mode],
        options = {poStdErrToStdOut})
      for _ in 0 ..< 100:
        if ownedSocketExists(selected): break
        doAssert proxy.running, "Owned proxy exited before socket readiness (exit " &
          $proxy.peekExitCode & ")"
        sleep(20)
      doAssert ownedSocketExists(selected)
    let started = getMonoTime()
    let outcome = probe(getAppFilename(),
      (if mode == "default-delayed": "default" else: mode), selected)
    doAssert outcome.code == 0, outcome.output
    if mode == "default-delayed":
      doAssert getMonoTime() - started >= initDuration(milliseconds = 200)
    if proxy != nil:
      doAssert proxy.waitForExit(5000) == 0, proxy.outputStream.readAll()
    var reclaimed = false
    for _ in 0 ..< 100:
      let status = probe(getAppFilename(), "status", endpoint)
      doAssert status.code == 0, status.output
      let value = parseJson(status.output)
      if value["sessions"].getInt() == 0 and value["leases"].getInt() == 0:
        reclaimed = true
        break
      sleep(50)
    doAssert reclaimed, "Real daemon retained a late grant/session"
