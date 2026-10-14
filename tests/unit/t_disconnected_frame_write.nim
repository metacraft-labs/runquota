# A deliberately silent real socket peer models a wedged daemon; a healthy
# daemon cannot exercise backpressure because it drains incoming requests.
# Child supervision makes the original unbounded-write defect fail, not hang.
import std/[os, osproc, unittest]

when defined(posix):
  import std/[net, nativesockets, posix, monotimes, times, strutils, tempfiles]
  import runquota_ipc
  import runquota_client
  import runquota_core
  import runquota_protocol
  import child_watchdog

  var msgDontWait {.importc: "MSG_DONTWAIT", header: "<sys/socket.h>".}: cint

  const Frame = "completion-report"

  proc exerciseWrite(disconnected: bool; timeoutMs = 0): int =
    var handles: array[2, cint]
    doAssert posix.socketpair(posix.AF_UNIX, posix.SOCK_STREAM, 0, handles) == 0
    var connection = LocalConnection(kind: endpointUnixSocket,
      socket: newSocket(SocketHandle(handles[0]), net.AF_UNIX,
        net.SOCK_STREAM, IPPROTO_NONE))
    defer: connection.socket.close()
    let peer = newSocket(SocketHandle(handles[1]), net.AF_UNIX,
      net.SOCK_STREAM, IPPROTO_NONE)
    if disconnected:
      peer.close()
      try:
        connection.sendFrame(Frame, timeoutMs)
      except OSError as error:
        return if error.errorCode in [int32(EPIPE), int32(ECONNRESET)]: 0 else: 2
      return 3
    defer: peer.close()
    connection.sendFrame(Frame, timeoutMs)
    return if peer.recv(Frame.len) == Frame: 0 else: 4

  proc exerciseHugeTimeout(): int =
    # An operator-sized RUNQUOTA_HANDSHAKE_TIMEOUT_MS beyond the nanosecond
    # clock or poll's cint range must saturate, not raise a Defect.
    var handles: array[2, cint]
    doAssert posix.socketpair(posix.AF_UNIX, posix.SOCK_STREAM, 0, handles) == 0
    var writer = LocalConnection(kind: endpointUnixSocket,
      socket: newSocket(SocketHandle(handles[0]), net.AF_UNIX,
        net.SOCK_STREAM, IPPROTO_NONE))
    defer: writer.close()
    var reader = LocalConnection(kind: endpointUnixSocket,
      socket: newSocket(SocketHandle(handles[1]), net.AF_UNIX,
        net.SOCK_STREAM, IPPROTO_NONE))
    defer: reader.close()
    var diag: Diagnostic
    doAssert writer.sendFrame(
      encodeFrame(rqStatusRequest, FrameFlagRequest, 7, "probe"), diag, high(int))
    var frame: RqspFrame
    doAssert reader.receiveFrame(frame, 3_000_000_000)
    doAssert frame.header.requestId == 7 and frame.payload == "probe"
    0

  proc exerciseSilentPeer(mode: string): int =
    let root = createTempDir("rq-write-", "")
    defer: removeDir(root)
    setFilePermissions(root, {fpUserRead, fpUserWrite, fpUserExec})
    let path = root / "s"
    let listener = newSocket(net.AF_UNIX, net.SOCK_STREAM, IPPROTO_NONE)
    defer: listener.close()
    listener.bindUnix(path)
    listener.listen()
    var connection = connectEndpoint(unixEndpoint(path))
    defer: connection.close()
    var peer: owned(Socket)
    listener.accept(peer)
    defer: peer.close()
    # A small real kernel buffer makes a modest frame exceed available space.
    var bufferSize = cint(4096)
    doAssert setsockopt(connection.socket.getFd(), SOL_SOCKET, SO_SNDBUF,
      addr bufferSize, SockLen(sizeof(bufferSize))) == 0
    let payload = repeat("x", 1024 * 1024)
    let originalFlags = fcntl(connection.socket.getFd(), F_GETFL, 0)
    doAssert originalFlags >= 0
    const BudgetMs = 150
    if mode == "slow":
      when defined(macosx):
        var lowWater = cint(128)
        doAssert setsockopt(connection.socket.getFd(), SOL_SOCKET, SO_SNDLOWAT,
          addr lowWater, SockLen(sizeof(lowWater))) == 0
        var size = SockLen(sizeof(lowWater))
        doAssert getsockopt(connection.socket.getFd(), SOL_SOCKET, SO_SNDLOWAT,
          addr lowWater, addr size) == 0
        doAssert lowWater > 1
      let readerPid = fork()
      doAssert readerPid >= 0
      if readerPid == 0:
        var bytesRead = 0
        var chunk: array[128, char]
        for iteration in 0 ..< 15:
          sleep(20)
          let received = posix.recv(peer.getFd(), addr chunk[0], chunk.len,
            msgDontWait)
          if received > 0:
            bytesRead += received
        quit(if bytesRead > 0: 0 else: 1)
      var diag: Diagnostic
      let started = getMonoTime()
      doAssert not connection.sendFrame(payload, diag, BudgetMs)
      let elapsed = (getMonoTime() - started).inMilliseconds
      doAssert diag.code == diagProtocol and "timed out" in diag.message
      doAssert elapsed >= 100 and elapsed < 1000
      var status: cint
      doAssert waitpid(readerPid, status, 0) == readerPid
      doAssert WIFEXITED(status) and WEXITSTATUS(status) == 0
    elif mode == "silent":
      var diag: Diagnostic
      let started = getMonoTime()
      doAssert not connection.sendFrame(payload, diag, BudgetMs)
      let elapsed = (getMonoTime() - started).inMilliseconds
      doAssert diag.code == diagProtocol
      doAssert "timed out" in diag.message
      doAssert elapsed >= 100 and elapsed < 1000
      # Evidence that this was a partial write into a live peer, not an
      # immediate failure on a closed socket or a write that never started.
      var received: array[4096, char]
      doAssert posix.recv(peer.getFd(), addr received[0], received.len,
        msgDontWait) > 0
    elif mode == "partial":
      var diag: Diagnostic
      doAssert not connection.sendFrame(payload, diag, BudgetMs)
      # A truncated frame leaves the stream unframeable. The peer must see end
      # of input rather than wait forever for the frame's missing tail, and a
      # later frame must not be spliced into the middle of the truncated one.
      var drained = 0
      var sawEof = false
      var received: array[65536, char]
      while drained <= payload.len:
        var fds = TPollfd(fd: cint(peer.getFd()), events: POLLIN)
        if poll(addr fds, Tnfds(1), cint(BudgetMs)) <= 0:
          break
        let got = posix.recv(peer.getFd(), addr received[0], received.len, 0)
        if got <= 0:
          sawEof = got == 0
          break
        drained += got
      doAssert drained > 0 and drained < payload.len
      doAssert sawEof
      var spliced = false
      try:
        spliced = connection.sendFrame(Frame, diag, BudgetMs)
      except OSError:
        discard
      doAssert not spliced
    else:
      var client = RunQuotaClient(connection: connection,
        flow: defaultFlowControlLimits())
      putEnv("RUNQUOTA_HANDSHAKE_TIMEOUT_MS", $BudgetMs)
      if mode == "status":
        # Fill the send buffer before the tiny status request, so only the
        # request's write deadline can release the caller.
        when defined(macosx):
          doAssert fcntl(connection.socket.getFd(), F_SETFL,
            originalFlags or O_NONBLOCK) == 0
        try:
          while posix.send(connection.socket.getFd(), unsafeAddr payload[0],
              payload.len, msgDontWait) > 0:
            discard
        finally:
          when defined(macosx):
            doAssert fcntl(connection.socket.getFd(), F_SETFL, originalFlags) == 0
      let started = getMonoTime()
      var failed = false
      try:
        if mode == "status":
          discard client.daemonStatus(BudgetMs)
        else:
          discard client.registerSession(payload, "test")
      except RunQuotaClientError:
        failed = true
      let elapsed = (getMonoTime() - started).inMilliseconds
      doAssert failed
      doAssert client.lastDiagnostic.code == diagProtocol
      doAssert "write timed out" in client.lastDiagnostic.message
      doAssert client.inflightRequestIds.len == 0
      doAssert elapsed >= 100 and elapsed < 1000
    doAssert fcntl(connection.socket.getFd(), F_GETFL, 0) == originalFlags
    0

  if paramCount() == 2 and paramStr(1) == "--frame-write-child":
    let mode = paramStr(2)
    if mode == "huge-timeout":
      quit(exerciseHugeTimeout())
    if mode in ["silent", "partial", "register", "status", "slow"]:
      quit(exerciseSilentPeer(mode))
    quit(exerciseWrite(mode.startsWith("disconnected"),
      if mode.endsWith("-bounded"): 150 else: 0))

  proc checkWrite(mode: string) =
    # A suppressed EPIPE can spin forever inside std/net.send. Supervise the
    # call in a child so this regression fails without wedging the test runner.
    let child = startSupervisedChild(getAppFilename(),
      ["--frame-write-child", mode])
    defer: child.close()
    let exitCode = child.waitBounded(10)
    if exitCode == -1:
      child.killProcessTree()
    check exitCode == 0
    check not child.running()

  suite "local frame writes":
    test "a connected peer receives the complete frame":
      checkWrite("connected")

    test "a disconnected peer raises an OS error without hanging":
      checkWrite("disconnected")

    test "bounded writes deliver frames and report disconnected peers":
      checkWrite("connected-bounded")
      checkWrite("disconnected-bounded")

    test "oversized timeouts saturate instead of overflowing":
      checkWrite("huge-timeout")

    test "a peer that accepts but never reads times out a partial write":
      checkWrite("silent")

    test "a slowly draining peer cannot restart the full-frame deadline":
      checkWrite("slow")

    test "a partially written frame poisons the connection for both ends":
      checkWrite("partial")

    test "session registration propagates its write timeout as a client error":
      checkWrite("register")

    test "status probe bounds its write to an already full socket":
      checkWrite("status")
else:
  suite "local frame writes":
    test "Unix socket disconnect regression requires POSIX":
      skip()
