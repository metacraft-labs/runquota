## A `connect` whose `Hello` fails closes the connection it opened before it
## raises, whichever step failed: the daemon refused the `Hello`, answered it
## with something other than `HelloOk`, answered with a `HelloOk` that does
## not decode, or never answered within the handshake timeout.
##
## WHY. `connect` opens the transport first and then sends the `Hello`. On
## each of those four paths it used to raise with the half-built client, and
## its open socket, dropped: a one-shot launcher kept the descriptor until it
## exited, a caller that retries or a long-lived process that probes the
## endpoint accumulated them, and the daemon kept each accepted connection
## until it noticed the peer was gone. `spec/RunQuota-Protocol-And-Client-
## Libraries.md` (reprobuild-pm) describes a connection's life as `Hello`,
## then requests, then close; a client that fails to establish a session
## releases what it opened.
##
## WHAT IS CHECKED, FROM BOTH ENDS.
##   * The client: after `connect` raises, this process holds exactly the
##     descriptors it held before the call (`/proc/self/fd`), so no socket is
##     left behind.
##   * The listener: the stub, once it has answered (or, for the timeout case,
##     deliberately not answered), waits for the peer's end of stream and
##     exits 0 only if it sees one. A connection still open after its bound
##     exits non-zero.
##
## THE STUB SERVER, AND WHY IT IS ONE. The real `runquotad` cannot be made to
## answer a `Hello` with a malformed `HelloOk`, a frame of another kind, or
## silence; and it refuses a `Hello` only for reasons this client cannot be
## made to give (see `t_hello_refusal_is_a_refused_error`, whose stub this
## follows). So a forked child speaks the protocol instead, framing each
## answer with the same `encodeFrame` the daemon uses. What is under test is
## the client's handling of the answer, not the daemon's production of it.
##
## LINUX ONLY: `/proc/self/fd` is the descriptor inventory the issue names,
## and the stub's end-of-stream probe uses POSIX `poll`/`recv`.
##
## FALSIFIABILITY. Removing the close on `connect`'s error path leaves the
## descriptor open: the client-side count check fails in every case, and the
## stub times out waiting for end of stream and exits non-zero.

import std/[os, unittest]

when defined(linux):
  import std/[monotimes, net, osproc, posix, strutils, tempfiles, times]

  import runquota_client
  import runquota_core
  import runquota_ipc
  import runquota_protocol

  const
    stubEnvVar = "RUNQUOTA_TEST_FAILED_HELLO_STUB"
    stubModeVar = "RUNQUOTA_TEST_FAILED_HELLO_STUB_MODE"
    # How long the stub waits for the client to close its end. Generous: on a
    # contended host the client may take a while to get from the raise to
    # the end of the test, and a fixed client still closes before raising.
    closeWaitMs = 20_000
    # The handshake timeout the "silent" case runs under: short, so the case
    # finishes quickly, and far below `closeWaitMs`.
    silentHandshakeTimeoutMs = 300
    stubExitClosed = 0
    stubExitStillOpen = 3
    stubExitNoHello = 4

  proc peerClosed(connection: LocalConnection; waitMs: int): bool =
    ## True once the peer's end of stream is read within `waitMs`. Any byte
    ## the peer sends instead is discarded and the wait goes on: only end of
    ## stream (or a reset, which also means the peer let go) counts.
    let fd = connection.socket.getFd()
    let deadline = getMonoTime() + initDuration(milliseconds = waitMs)
    var buffer: array[256, char]
    while true:
      let remaining = inMilliseconds(deadline - getMonoTime())
      if remaining <= 0:
        return false
      var pollFd = TPollfd(fd: cint(fd), events: POLLIN)
      let ready = poll(addr pollFd, 1, cint(remaining))
      if ready < 0:
        if errno == EINTR: continue
        return false
      if ready == 0:
        return false
      let got = recv(fd, addr buffer[0], buffer.len, 0)
      if got == 0:
        return true
      if got < 0:
        if errno == EINTR or errno == EAGAIN: continue
        return errno == ECONNRESET

  proc runStub(socketPath, mode: string) =
    ## One connection: read the `Hello`, answer it as `mode` says, then wait
    ## for the client to close its end.
    var listener = bindEndpoint(unixEndpoint(socketPath))
    var connection = acceptConnection(listener)
    var frame: RqspFrame
    if not connection.receiveFrame(frame):
      quit(stubExitNoHello)
    let requestId = frame.header.requestId
    case mode
    of "refuse":
      let payload = encodeProtocolError(ProtocolErrorMessage(
        diagnostic: diagnostic(diagDenied, "this client is refused")))
      connection.sendFrame(encodeFrame(rqError,
        FrameFlagResponse or FrameFlagError, requestId, payload))
    of "wrong-kind":
      # A well-formed response of a kind that does not answer a `Hello`.
      connection.sendFrame(encodeFrame(rqStatusResponse, FrameFlagResponse,
        requestId, ""))
    of "bad-hello-ok":
      # The right kind, with a payload no `HelloOk` decodes from.
      connection.sendFrame(encodeFrame(rqHelloOk, FrameFlagResponse,
        requestId, "\xff\xff\xff"))
    of "silent":
      discard
    else:
      quit("unknown stub mode " & mode, 2)
    let closed = connection.peerClosed(closeWaitMs)
    connection.close()
    listener.close()
    quit(if closed: stubExitClosed else: stubExitStillOpen)

  when isMainModule:
    let stubSocket = getEnv(stubEnvVar)
    if stubSocket.len > 0:
      runStub(stubSocket, getEnv(stubModeVar))

  proc socketExists(path: string): bool =
    try:
      discard getFileInfo(path, followSymlink = false)
      true
    except OSError:
      false

  proc privateSocketPath(): string =
    ## A rendezvous directory this process owns, mode 0700, as
    ## `requireTrustedEndpointDir` requires.
    let dir = createTempDir("rq-failed-hello-", "")
    setFilePermissions(dir, {fpUserRead, fpUserWrite, fpUserExec})
    dir / "rq.sock"

  proc startStub(socketPath, mode: string): Process =
    putEnv(stubEnvVar, socketPath)
    putEnv(stubModeVar, mode)
    result = startProcess(getAppFilename(), options = {poParentStreams})
    delEnv(stubEnvVar)
    delEnv(stubModeVar)
    for _ in 0 ..< 500:
      if socketExists(socketPath): return
      sleep(10)
    doAssert false, "the stub never bound " & socketPath

  proc openDescriptors(): seq[string] =
    ## This process's open descriptors, each as `<fd> -> <target>`, read
    ## from `/proc/self/fd`. The directory descriptor `walkDir` holds while
    ## it lists them is left out: it is open only during the listing, and
    ## its number differs between two snapshots taken with a different set
    ## of descriptors open, which is exactly what is being compared.
    for entry in walkDir("/proc/self/fd"):
      let fd = entry.path.extractFilename
      var target = ""
      try:
        target = expandSymlink(entry.path)
      except OSError:
        # Gone by the time its link is read: the listing's own descriptor.
        continue
      if target.startsWith("/proc/"):
        continue
      result.add(fd & " -> " & target)

  template failedConnectLeavesNothingOpen(mode: string) =
    ## A template, not a proc: `check` marks the enclosing `test` failed
    ## only when it expands inside the test's body. Called from a proc, a
    ## failed check prints its message and the test still reports OK.
    let socketPath = privateSocketPath()
    let stub = startStub(socketPath, mode)
    defer:
      if stub.running: stub.terminate()
      discard stub.waitForExit()
      stub.close()
      removeDir(socketPath.parentDir)
    let before = openDescriptors()
    var raised = false
    try:
      var client = connect(unixEndpoint(socketPath))
      # Unreachable when the stub misbehaves as told; closed so a broken
      # stub fails the `raised` check below rather than leaking.
      client.close()
    except RunQuotaClientError:
      raised = true
    let after = openDescriptors()
    check raised
    check after == before
    # The listener's view: it saw the connection closed.
    check stub.waitForExit() == stubExitClosed

  suite "a failed Hello closes the connection it opened":

    test "a refused Hello":
      failedConnectLeavesNothingOpen("refuse")

    test "a Hello answered by something other than HelloOk":
      failedConnectLeavesNothingOpen("wrong-kind")

    test "a HelloOk that does not decode":
      failedConnectLeavesNothingOpen("bad-hello-ok")

    test "a Hello never answered within the handshake timeout":
      putEnv("RUNQUOTA_HANDSHAKE_TIMEOUT_MS", $silentHandshakeTimeoutMs)
      defer: delEnv("RUNQUOTA_HANDSHAKE_TIMEOUT_MS")
      failedConnectLeavesNothingOpen("silent")

else:
  # Not exercised here, and said so: a file that compiled to an empty
  # program would exit 0 having run nothing (reprobuild-pm issue
  # 2026-11-17-runquota-test-files-guarded-whole-by-a-platform-condition-
  # pass-with-zero-cases).
  suite "a failed Hello closes the connection it opened":
    test "Linux only (/proc/self/fd)":
      echo "t_failed_hello_closes_its_connection: NOT EXERCISED on this " &
        "platform; its descriptor inventory is Linux's /proc/self/fd"
      skip()
