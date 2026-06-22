import std/[os, osproc, strutils, times, unittest]

when defined(posix):
  import std/posix

import runquota_client
import runquota_core
import runquota_exec
import runquota_process

# Regression coverage for forking leased actions. A forking action's leader
# (here a shell) exits quickly but leaves a backgrounded `sleep` that inherits
# the stdout/stderr pipe write-ends. Completion detection must gate on the
# *leased process itself* being reaped — not on every inherited pipe reaching
# EOF — otherwise the lingering descendant keeps the pipes open, EOF never
# arrives, the supervisor blocks forever and never emits LeaseFinished. This
# mirrors real forking tools (e.g. `cc` spawning `cc1`/`as`, or a
# process-monitor shim's helpers).

proc daemonPath(): string =
  getCurrentDir() / "build" / "bin" / "runquotad"

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

proc req(label: string): ResourceRequest =
  resourceRequest(label, milliCpu(100), bytes(1024 * 1024))

suite "forking_lease_completion":
  test "waitForCompletion returns for a forking action that leaves a child":
    when defined(posix):
      var child = launchProcess(commandSpec(["/bin/sh", "-c",
        "sleep 30 & echo forked-done"]))
      let start = epochTime()
      let completion = child.waitForCompletion(10000)
      let elapsed = epochTime() - start
      child.close()
      # The shell exits 0 quickly; we must observe completion in well under the
      # 10s timeout (NOT a timeout-driven kill) even though `sleep` lingers.
      check completion.exited
      check completion.exitCode == 0
      check not completion.timedOut
      check elapsed < 3.0
      check completion.stdout.contains("forked-done")
      # Clean up the lingering sleep (best effort).
      if child.processGroupId > 0:
        discard kill(Pid(-child.processGroupId), SIGKILL)
    else:
      skip()

  test "leased forking action completes and emits LeaseFinished":
    let socketDir = getTempDir() / ("runquota-bug2-" & $getCurrentProcessId())
    let socketPath = socketDir / "runquotad.sock"
    if dirExists(socketDir):
      removeDir(socketDir)
    createDir(socketDir)
    check fileExists(daemonPath())

    let daemon = startProcess(
      daemonPath(),
      args = [
        "--socket", socketPath,
        "--cpu-milli", "2000",
        "--memory-bytes", $((1024'u64 * 1024'u64 * 1024'u64))
      ],
      options = {poStdErrToStdOut}
    )
    try:
      waitForDaemon(socketPath)
      var client = connectDefault()
      var session = client.registerSession("bug2-forking", versionString())

      let beforeLease = client.daemonStatus().totalFinished
      let start = epochTime()
      let execution = session.runWithLease(
        req("forking-action"),
        ["/bin/sh", "-c", "sleep 30 & echo forked-done"]
      )
      let elapsed = epochTime() - start

      check elapsed < 5.0
      check execution.leaseFinishedSent
      check execution.leaseReleased
      check execution.process.exited
      check execution.process.exitCode == 0
      check execution.process.stdout.contains("forked-done")
      check client.daemonStatus().totalFinished > beforeLease

      session.closeSession()
      client.close()
    finally:
      if daemon.running:
        daemon.terminate()
        discard daemon.waitForExit(3000)
      daemon.close()
      if dirExists(socketDir):
        removeDir(socketDir)
