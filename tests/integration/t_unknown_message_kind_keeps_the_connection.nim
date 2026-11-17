## A MESSAGE KIND THE DAEMON DOES NOT KNOW IS ANSWERED, NOT HUNG UP ON.
##
## reprobuild-specs/RunQuota-Protocol-And-Client-Libraries.md, "Encoding":
## unknown `msg_type` values MUST be rejected with `UnsupportedMessage`; the
## rejection answers that one request, and the daemon MUST NOT close the
## connection for it, so the other sessions and leases on the connection are
## unaffected. Recorded as reprobuild-pm issue
## `issues/2026-11-16-runquotad-closes-the-connection-on-an-unknown-message-kind.md`
## (deleted in the commit that lands this test).
##
## THE DEFECT. Every daemon up to RQSP minor 9 decoded the frame header with
## a `msg_type` bound by its own enum, failed on any kind it did not know,
## and returned from the connection loop: the connection closed and every
## session on it was cleaned up, its granted leases with it. The specs had
## recorded that only for daemons below minor 1. Minor 10
## (`UnsupportedMessageMinor`) is the first that conforms.
##
## WHAT IS PROVOKED. One connection, one session, one lease GRANTED AND
## STILL HELD. Then frames of kinds no daemon assigns are written on that
## same connection, with a payload, under request ids of their own. The test
## asserts, in order:
##
## * each request is answered with an `Error` frame carrying
##   `diagUnsupportedMessage`, correlated by ITS request id;
## * a frame of an unknown kind that is not a request -- the request flag
##   clear, or the id zero -- is skipped without a reply, and the
##   connection goes on;
## * the held lease is still the daemon's: it can be marked starting and
##   running and finished on the same connection;
## * the same session can then be granted a second lease;
## * a frame whose header layout is invalid still ends the connection, and
##   is NOT answered under the previous request's id.
##
## A second test covers a peer that has not said Hello: its unknown kind is
## answered, and the connection then ends.
##
## RED ON THE MINOR-9 DAEMON (runquota 6ff9731, the test binary of this
## change run against a `runquotad` built from that commit), in this order:
## `protocolMinor was 9`; the reply to the first unknown kind came under
## request id 3 when 4 was sent (the old reader left the previous frame's
## header in place and the daemon answered the decode failure under it);
## its code was `diagProtocol`; then the next frame failed with a broken
## pipe, because the daemon had closed the connection.
##
## NO MOCKS. A real `runquotad` from `build/bin` on a real scratch endpoint,
## the ordinary client library for the session and leases, and the
## connection that library opened for the raw frames.
##
## EVERY FATAL PRECONDITION UNWINDS. `requireUnwinding`
## (`tests/support/unwinding_require.nim`) raises instead of `quit`ting, so
## the `defer` that stops the private daemon runs even when a precondition
## fails -- which on a non-conforming daemon is the expected outcome. A
## plain `require` left that daemon running after a red run.

import private_broker_owner
import std/[os, osproc, unittest]

import runquota_client
import runquota_core
import runquota_ipc
import runquota_protocol
import daemon_binary
import daemon_endpoint
import scratch_root
import unwinding_require

const MiB = 1024'u64 * 1024'u64

proc scratchDir(tag: string): string =
  ## Short on POSIX: `sun_path` is 104 bytes on macOS. Windows names a pipe.
  let base =
    when defined(windows): getTempDir()
    else: "/tmp"
  result = base / ("rq-" & tag & "-" & $getCurrentProcessId())
  removeDir(result)
  createDir(result)
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})

proc startDaemon(socketPath: string): Process =
  ## The daemon is not yet owned by any `defer` of the caller, so a startup
  ## that fails here stops it before re-raising.
  result = startProcess(daemonPath(), args = ["--socket", socketPath,
      "--host-identity-file", socketPath.parentDir / "host-id"],
    options = {poStdErrToStdOut})
  try:
    for _ in 0 ..< 400:
      if endpointIsBound(socketPath): break
      sleep(25)
    discard readRequiredStartupLines(result, 3,
      "t_unknown_message_kind_keeps_the_connection")
  except CatchableError:
    result.kill()
    discard result.waitForExit(5000)
    result.close()
    raise

proc stop(process: Process) =
  if process.running:
    process.terminate()
    discard process.waitForExit(5000)
  if process.running:
    process.kill()
    discard process.waitForExit(5000)
  process.close()

proc frameOfUnknownKind(kindRaw: uint16; requestId: uint64;
    payload: string; flags = FrameFlagRequest): string =
  ## A well-formed request frame whose `msg_type` is ``kindRaw``. Built from
  ## the production encoder and patched at the `msg_type` field (bytes 8-9,
  ## little-endian after magic, version and header_len), so every other
  ## field is exactly what a real client writes.
  result = encodeFrame(rqStatusRequest, flags, requestId, payload)
  result[8] = char(kindRaw and 0xFF'u16)
  result[9] = char(kindRaw shr 8)

suite "unknown_message_kind_keeps_the_connection":

  test "an unknown kind is answered with UnsupportedMessage and the session survives":
    let privateOwner = bindPrivateBrokerOwnerToCaller()
    defer: restorePrivateBrokerOwner(privateOwner)
    let root = scratchDir("unkind")
    defer: removeScratchRoot(root)
    let endpointPolicy = bindPrivateBrokerPolicyToCaller(privateEndpointGroup(root))
    defer: restorePrivateBrokerPolicy(endpointPolicy)
    setFilePermissions(root, endpointDirectoryPermissions())
    let socketPath = root / "d.sock"

    var daemon = startDaemon(socketPath)
    defer: daemon.stop()
    requireUnwinding(endpointIsBound(socketPath), "the daemon bound no endpoint")

    var client = connect(endpointForPath(socketPath))
    defer: client.close()
    check client.capabilities.protocolMinor >= UnsupportedMessageMinor

    var session = client.registerSession("unknown-kind", "0.1.0")
    var held = session.requestLease(resourceRequest("held",
      milliCpu(1000), bytes(64'u64 * MiB)))
    requireUnwinding(held.active, "the first lease was not granted")

    # Kinds no daemon assigns: the top of the range, one past the last
    # assigned kind this build knows, and zero, which no kind has ever used.
    let unknownKinds = [0xFFFE'u16, uint16(ord(high(RqspMessageKind))) + 1'u16,
      0'u16]
    for kindRaw in unknownKinds:
      checkpoint("msg_type=" & $kindRaw)
      # Frames that are NOT requests first: nobody waits on them, so they
      # get no reply, and if one did the reply read below would carry its id
      # instead of the request's. A request is the request flag set AND a
      # non-zero id, so each half is tested alone: the flag clear under a
      # real id (an id alone must not draw a reply), the flag set under id 0,
      # and neither.
      client.connection.sendFrame(frameOfUnknownKind(kindRaw,
        0xA5A5_0000'u64 + uint64(kindRaw), "one-way, id set", flags = 0'u16))
      client.connection.sendFrame(frameOfUnknownKind(kindRaw, 0'u64,
        "one-way, flag set"))
      client.connection.sendFrame(frameOfUnknownKind(kindRaw, 0'u64,
        "one-way", flags = 0'u16))
      inc client.nextRequestId
      let requestId = client.nextRequestId
      client.connection.sendFrame(frameOfUnknownKind(kindRaw, requestId,
        "payload the daemon must skip, not parse"))
      var reply: RqspFrame
      var replyDiagnostic: Diagnostic
      let answered = client.connection.receiveFrame(reply, replyDiagnostic,
        timeoutMs = 10_000)
      if not answered:
        checkpoint("the daemon closed the connection instead of answering: " &
          replyDiagnostic.message)
      requireUnwinding(answered, "no reply to msg_type=" & $kindRaw)
      check reply.header.requestId == requestId
      check reply.header.messageKind == rqError
      check (reply.header.flags and FrameFlagError) != 0'u16
      var error: ProtocolErrorMessage
      requireUnwinding(decodeProtocolError(reply.payload, error),
        "the reply is not a protocol error")
      check error.diagnostic.code == diagUnsupportedMessage
      check error.diagnostic.detail == "msg_type=" & $kindRaw

    # The held lease is still this connection's: its lifecycle completes.
    held.markStarting()
    held.markRunning(childProcessId = uint64(getCurrentProcessId()))
    held.finish(outcome = succeeded(), processCount = 1'u32)

    # And the same session is still served.
    var second = session.requestLease(resourceRequest("second",
      milliCpu(1000), bytes(64'u64 * MiB)))
    check second.active
    second.markStarting()
    second.markRunning(childProcessId = uint64(getCurrentProcessId()))
    second.finish(outcome = succeeded(), processCount = 1'u32)

    # A header whose layout is invalid still ends the connection: the
    # daemon cannot find the frame's end. It is not answered under the id
    # of the request before it, which the old reader did.
    var garbage = frameOfUnknownKind(0xFFFE'u16, 0'u64, "")
    garbage[0] = 'X'
    client.connection.sendFrame(garbage)
    var afterGarbage: RqspFrame
    var garbageDiagnostic: Diagnostic
    check not client.connection.receiveFrame(afterGarbage, garbageDiagnostic,
      timeoutMs = 10_000)
    check afterGarbage.header.requestId == 0'u64

    check daemon.running

  test "before Hello an unknown kind is answered and the connection ends":
    let privateOwner = bindPrivateBrokerOwnerToCaller()
    defer: restorePrivateBrokerOwner(privateOwner)
    let root = scratchDir("unkind-pre")
    defer: removeScratchRoot(root)
    let endpointPolicy = bindPrivateBrokerPolicyToCaller(privateEndpointGroup(root))
    defer: restorePrivateBrokerPolicy(endpointPolicy)
    setFilePermissions(root, endpointDirectoryPermissions())
    let socketPath = root / "d.sock"

    var daemon = startDaemon(socketPath)
    defer: daemon.stop()
    requireUnwinding(endpointIsBound(socketPath), "the daemon bound no endpoint")

    var raw = connectEndpoint(endpointForPath(socketPath))
    defer: raw.close()
    raw.sendFrame(frameOfUnknownKind(0xFFFE'u16, 9'u64, "before hello"))
    var reply: RqspFrame
    var replyDiagnostic: Diagnostic
    requireUnwinding(raw.receiveFrame(reply, replyDiagnostic,
      timeoutMs = 10_000), "no reply before Hello")
    check reply.header.requestId == 9'u64
    var error: ProtocolErrorMessage
    requireUnwinding(decodeProtocolError(reply.payload, error),
      "the reply is not a protocol error")
    check error.diagnostic.code == diagUnsupportedMessage
    var next: RqspFrame
    check not raw.receiveFrame(next, replyDiagnostic, timeoutMs = 10_000)

    # And the daemon still serves a peer that says Hello.
    var client = connect(endpointForPath(socketPath))
    defer: client.close()
    check client.capabilities.protocolMinor >= UnsupportedMessageMinor
    check daemon.running
