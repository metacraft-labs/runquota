## A daemon that answers `Hello` with an RQSP `Error` frame raises
## `RunQuotaRefusedError`, carrying the daemon's diagnostic; a daemon that
## closes the connection without answering raises a `RunQuotaClientError`
## that is NOT one.
##
## WHY. A launcher that adopts a shared daemon has to tell "it refused me"
## from "it does not answer": the second may be a daemon shutting down, worth
## waiting for; the first is a daemon serving its other clients, and neither
## waiting nor stopping it changes its answer. Before this type existed both
## arrived as the same `RunQuotaClientError`, and reprobuild's per-user
## adopt loop waited 120 s on a refusing daemon and then advised stopping it.
##
## THE STUB SERVER, AND WHY IT IS ONE. The real `runquotad` refuses a `Hello`
## only for reasons this client cannot be made to give: an incompatible
## protocol major (fixed at compile time), a declared uid other than the
## peer's (`connect` derives it), a namespace claim the kernel contradicts
## (needs a sandbox whose namespaces the daemon reads as its own), an owner
## hash collision. So a forked child speaks the protocol instead, and frames
## its refusal exactly as the daemon's `sendError` does: `encodeProtocolError`
## of the diagnostic, `encodeFrame(rqError, FrameFlagResponse or
## FrameFlagError, <request id>, ...)`. What is under test is the client's
## reading of that frame, and the frame is byte-for-byte the daemon's.
##
## FALSIFIABILITY. Before `RunQuotaRefusedError`, the first case fails to
## compile; with the type declared but `readResponse` still raising the plain
## `RunQuotaClientError`, its check for a `RunQuotaRefusedError` fails.

import std/[os, osproc, tempfiles, unittest]

import runquota_client
import daemon_endpoint
import runquota_core
import runquota_ipc
import runquota_protocol

const
  stubEnvVar = "RUNQUOTA_TEST_REFUSING_STUB"
  stubModeVar = "RUNQUOTA_TEST_REFUSING_STUB_MODE"
  refusalText = "client claims another user namespace, but its peer " &
    "credentials name the client itself, in the daemon's"
  refusalDetail = "namespace tokens describe the client"

proc runStub(socketPath, mode: string) =
  ## One connection: read the `Hello`, then refuse it (`refuse`) or close
  ## without a word (`silent`). `endpointForPath` rather than `unixEndpoint`
  ## directly: on Windows this transport is a named pipe, and
  ## `endpointForPath` is the one place that already knows how to map a
  ## `.sock`-shaped path onto one deterministically.
  var listener = bindEndpoint(endpointForPath(socketPath))
  var connection = acceptConnection(listener)
  var frame: RqspFrame
  if connection.receiveFrame(frame) and mode == "refuse":
    let payload = encodeProtocolError(ProtocolErrorMessage(
      diagnostic: diagnostic(diagDenied, refusalText, refusalDetail)))
    connection.sendFrame(encodeFrame(rqError,
      FrameFlagResponse or FrameFlagError, frame.header.requestId, payload))
  connection.close()
  listener.close()

when isMainModule:
  let stubSocket = getEnv(stubEnvVar)
  if stubSocket.len > 0:
    runStub(stubSocket, getEnv(stubModeVar))
    quit(0)

proc privateSocketPath(): string =
  ## A rendezvous directory this process owns, mode 0700, as
  ## `requireTrustedEndpointDir` requires. On Windows the directory is
  ## never the endpoint itself (`endpointForPath` maps it onto a named
  ## pipe), but it is still removed in `stopStub` below, so creating it the
  ## same way on every OS is simplest.
  let dir = createTempDir("rq-refusal-", "")
  setFilePermissions(dir, {fpUserRead, fpUserWrite, fpUserExec})
  dir / "rq.sock"

proc startStub(socketPath, mode: string): Process =
  putEnv(stubEnvVar, socketPath)
  putEnv(stubModeVar, mode)
  result = startProcess(getAppFilename(), options = {poParentStreams})
  delEnv(stubEnvVar)
  delEnv(stubModeVar)
  for _ in 0 ..< 500:
    if endpointIsBound(socketPath): return
    sleep(10)
  doAssert false, "the stub never bound " & socketPath

proc stopStub(stub: Process; socketPath: string) =
  if stub.running: stub.terminate()
  discard stub.waitForExit()
  stub.close()
  removeDir(socketPath.parentDir)

suite "a refused Hello":

  test "an Error frame answering Hello raises RunQuotaRefusedError with the daemon's diagnostic":
    let socketPath = privateSocketPath()
    let stub = startStub(socketPath, "refuse")
    defer: stopStub(stub, socketPath)
    var caught: ref RunQuotaRefusedError = nil
    try:
      var client = connect(endpointForPath(socketPath))
      client.close()
    except RunQuotaRefusedError as error:
      caught = error
    check caught != nil
    if caught != nil:
      check caught.msg == refusalText
      check caught.diagnostic.code == diagDenied
      check caught.diagnostic.message == refusalText
      check caught.diagnostic.detail == refusalDetail
      # Still a `RunQuotaClientError`: every existing handler keeps working.
      check caught of RunQuotaClientError

  test "a daemon that closes without answering is not a refusal":
    let socketPath = privateSocketPath()
    let stub = startStub(socketPath, "silent")
    defer: stopStub(stub, socketPath)
    var caught: ref RunQuotaClientError = nil
    try:
      var client = connect(endpointForPath(socketPath))
      client.close()
    except RunQuotaClientError as error:
      caught = error
    check caught != nil
    if caught != nil:
      check not (caught of RunQuotaRefusedError)
