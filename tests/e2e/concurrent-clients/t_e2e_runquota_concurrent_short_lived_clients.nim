import std/[os, osproc, unittest]

import runquota_client
import runquota_protocol
from runquota_ipc import endpointDirectoryPermissions
import daemon_binary

proc truePath(): string =
  for path in ["/usr/bin/true", "/bin/true"]:
    if fileExists(path):
      return path
  "true"

proc waitForDaemon(socketPath: string) =
  putEnv("RUNQUOTA_SOCKET", socketPath)
  var lastError = ""
  for _ in 0 ..< 100:
    try:
      var client = connectDefault()
      client.close()
      return
    except CatchableError as error:
      lastError = error.msg
      sleep(50)
  raise newException(OSError, "runquotad did not become ready: " & lastError)

proc readStatus(): DaemonStatusMessage =
  var client = connectDefault()
  defer: client.close()
  client.daemonStatus()

proc waitForQuietDaemon(totalFinished: uint64): DaemonStatusMessage =
  var last = DaemonStatusMessage()
  var lastError = ""
  for _ in 0 ..< 100:
    try:
      last = readStatus()
      if last.activeSessions == 0'u32 and
          last.activeLeases == 0'u32 and
          last.queuedLeases == 0'u32 and
          last.supervisorLostLeases == 0'u32 and
          last.totalFinished == totalFinished:
        return last
    except CatchableError as error:
      lastError = error.msg
    sleep(50)
  raise newException(
    OSError,
    "daemon did not settle after concurrent clients: sessions=" & $last.activeSessions &
      " leases=" & $last.activeLeases &
      " queued=" & $last.queuedLeases &
      " lost=" & $last.supervisorLostLeases &
      " total_finished=" & $last.totalFinished &
      " last_error=" & lastError
  )

suite "e2e_runquota_concurrent_short_lived_clients":
  test "real daemon accepts many concurrent short-lived acquire clients":
    let clientCount = 32
    let socketDir = "/tmp" / ("rq-concurrent-" & $getCurrentProcessId())
    let socketPath = socketDir / "runquotad.sock"
    if dirExists(socketDir):
      removeDir(socketDir)
    createDir(socketDir)
    # THE MODE THE SHIPPED POLICY REQUIRES, not a literal. This directory is
    # the RENDEZVOUS `runquotad` binds in, and the rendezvous mode is 0750
    # where a `runquota` group exists and 0700 (owner-only, single-user mode)
    # where it does not -- so a fixture hardcoding either one is green on one
    # kind of host and red on the other. Fixture only; the modes themselves
    # are asserted in tests/unit/t_shared_endpoint_rules.nim.
    setFilePermissions(socketDir, endpointDirectoryPermissions())
    check fileExists(daemonPath())
    check fileExists(cliPath())

    let daemon = startProcess(
      daemonPath(),
      args = [
        "--socket", socketPath,
        "--cpu-milli", "32000",
        "--memory-bytes", $(32'u64 * 1024'u64 * 1024'u64 * 1024'u64),
        "--pool", "link=2"
      ],
      options = {poStdErrToStdOut}
    )
    try:
      waitForDaemon(socketPath)

      var clients: seq[owned(Process)] = @[]
      for i in 0 ..< clientCount:
        clients.add(startProcess(
          cliPath(),
          args = [
            "acquire",
            "--cpu", "1000",
            "--mem", "1048576",
            "--label", "short-lived-" & $i,
            "--", truePath()
          ],
          options = {poStdErrToStdOut}
        ))

      for i in 0 ..< clients.len:
        check clients[i].waitForExit(5000) == 0
        clients[i].close()

      let status = waitForQuietDaemon(uint64(clientCount))
      check status.totalGranted == uint64(clientCount)
      check daemon.running
    finally:
      if daemon.running:
        daemon.terminate()
        discard daemon.waitForExit(3000)
      daemon.close()
      if dirExists(socketDir):
        removeDir(socketDir)
