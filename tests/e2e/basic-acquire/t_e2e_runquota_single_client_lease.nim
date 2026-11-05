import std/[os, osproc, unittest]

import runquota_client
import runquota_core
from runquota_ipc import endpointDirectoryPermissions
import daemon_binary
import scratch_root
import private_broker_owner

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
      removeScratchRoot(socketDir)
    createDir(socketDir)
    let privatePolicy = bindPrivateBrokerPolicyToCaller(privateEndpointGroup(socketDir))
    defer: restorePrivateBrokerPolicy(privatePolicy)
    # Declare this newly created endpoint's independently inspected group
    # before selecting its mode or launching either participant. It therefore
    # exercises shared0750/0660; named-service defaults are tested separately.
    setFilePermissions(socketDir, endpointDirectoryPermissions())
    check fileExists(daemonPath())

    let process = startProcess(
      daemonPath(),
      args = ["--socket", socketPath,
      # The host state in the scratch directory, never the machine's.
      "--host-identity-file", socketPath.parentDir / "host-id"],
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
      check status.supervisorLostLeases == 0'u32
      check status.finishedLeases == 0'u32
      check status.totalGranted == 1'u64
      check status.totalFinished == 0'u64
    finally:
      if process.running:
        process.terminate()
        discard process.waitForExit(3000)
      process.close()
      removeScratchRoot(socketDir)
