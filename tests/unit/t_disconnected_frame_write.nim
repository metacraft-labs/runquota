import std/[os, osproc, unittest]

when defined(posix):
  import std/[net, nativesockets, posix]
  import runquota_ipc
  import child_watchdog

  const Frame = "completion-report"

  proc exerciseWrite(disconnected: bool): int =
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
        connection.sendFrame(Frame)
      except OSError as error:
        return if error.errorCode in [int32(EPIPE), int32(ECONNRESET)]: 0 else: 2
      return 3
    defer: peer.close()
    connection.sendFrame(Frame)
    return if peer.recv(Frame.len) == Frame: 0 else: 4

  if paramCount() == 2 and paramStr(1) == "--frame-write-child":
    quit(exerciseWrite(paramStr(2) == "disconnected"))

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
else:
  suite "local frame writes":
    test "Unix socket disconnect regression requires POSIX":
      skip()
