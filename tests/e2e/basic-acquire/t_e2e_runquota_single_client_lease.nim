import std/[os, osproc, unittest]

import runquota_client
import runquota_core

proc daemonPath(): string =
  getCurrentDir() / "build" / "bin" / "runquotad"

proc waitForDaemon(socketPath: string) =
  putEnv("RUNQUOTA_SOCKET", socketPath)
  var lastError = ""
  for _ in 0 ..< 80:
    try:
      var client = connectDefault()
      client.close()
      return
    except CatchableError as error:
      lastError = error.msg
      sleep(50)
  raise newException(OSError, "runquotad did not become ready: " & lastError)

suite "e2e_runquota_single_client_lease":
  test "real daemon grants and releases one local IPC lease":
    let socketDir = getTempDir() / ("runquota-e2e-" & $getCurrentProcessId())
    let socketPath = socketDir / "runquotad.sock"
    if dirExists(socketDir):
      removeDir(socketDir)
    createDir(socketDir)
    check fileExists(daemonPath())

    let process = startProcess(
      daemonPath(),
      args = ["--socket", socketPath],
      options = {poStdErrToStdOut}
    )
    try:
      waitForDaemon(socketPath)

      var client = connectDefault()
      var session = client.registerSession("e2e-basic-acquire", "0.1.0")
      var request = resourceRequest(
        "smoke",
        milliCpu(1000),
        bytes(128'u64 * 1024'u64 * 1024'u64)
      )
      var lease = session.requestLease(request)
      check lease.active
      check lease.resources.cpu.value == 1000'u32
      check lease.resources.memory.value == 128'u64 * 1024'u64 * 1024'u64

      lease.release()
      check not lease.active
      session.closeSession()
      client.close()

      var statusClient = connectDefault()
      let status = statusClient.daemonStatus()
      statusClient.close()
      check status.activeSessions == 0'u32
      check status.activeLeases == 0'u32
      check status.totalGranted == 1'u64
    finally:
      if process.running:
        process.terminate()
        discard process.waitForExit(3000)
      process.close()
      removeDir(socketDir)
