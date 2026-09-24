import std/[os, osproc, strutils, times, unittest]

when defined(posix):
  import std/posix
else:
  import std/winlean

from runquota_ipc import endpointDirectoryPermissions
import runquota_client
import runquota_core
import runquota_exec
import runquota_process
import daemon_binary
import scratch_root

# Regression coverage for forking leased actions. A forking action's leader
# (here a shell) exits quickly but leaves a backgrounded `sleep` that inherits
# the stdout/stderr pipe write-ends. Completion detection must gate on the
# *leased process itself* being reaped — not on every inherited pipe reaching
# EOF — otherwise the lingering descendant keeps the pipes open, EOF never
# arrives, the supervisor blocks forever and never emits LeaseFinished. This
# mirrors real forking tools (e.g. `cc` spawning `cc1`/`as`, or a
# process-monitor shim's helpers).
#
# ON WINDOWS THE LEADER IS THIS BINARY, not `/bin/sh`, which is not a path
# there. It starts a copy of itself that inherits its standard handles --
# the pipe write-ends, exactly as the backgrounded `sleep` does -- prints
# the same line and exits, leaving the copy alive for 30 s.

const
  LeaderArg = "--forking-leader"
  LingerArg = "--forking-linger"
  LingerPidPrefix = "linger-pid="

if paramCount() == 1 and paramStr(1) == LingerArg:
  sleep(30_000)
  quit 0

if paramCount() == 1 and paramStr(1) == LeaderArg:
  let linger = startProcess(getAppFilename(), args = [LingerArg],
    options = {poParentStreams})
  echo LingerPidPrefix, linger.processID
  echo "forked-done"
  quit 0

proc forkingCommand(): seq[string] =
  when defined(posix):
    @["/bin/sh", "-c", "sleep 30 & echo forked-done"]
  else:
    @[getAppFilename(), LeaderArg]

proc reapLinger(output: string) =
  ## Best-effort cleanup of the lingering descendant, found by the pid the
  ## Windows leader printed. (The POSIX arm kills the process group.)
  when defined(windows):
    for line in output.splitLines():
      if line.startsWith(LingerPidPrefix):
        const ProcessTerminate = 0x0001'i32
        let pid = parseInt(line[LingerPidPrefix.len .. ^1].strip())
        let handle = openProcess(ProcessTerminate, 0, int32(pid))
        if handle != 0:
          discard terminateProcess(handle, 1)
          discard closeHandle(handle)
  else:
    discard output

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
    block:
      var child = launchProcess(commandSpec(forkingCommand()))
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
      when defined(posix):
        if child.processGroupId > 0:
          discard kill(Pid(-child.processGroupId), SIGKILL)
      reapLinger(completion.stdout)

  test "leased forking action completes and emits LeaseFinished":
    let socketDir = getTempDir() / ("runquota-bug2-" & $getCurrentProcessId())
    let socketPath = socketDir / "runquotad.sock"
    if dirExists(socketDir):
      removeScratchRoot(socketDir)
    createDir(socketDir)
    # THE MODE THE SHIPPED POLICY REQUIRES, not a literal. This directory is
    # the RENDEZVOUS `runquotad` binds in, and the rendezvous mode is 0750
    # where a `runquota` group exists and 0700 (owner-only, single-user mode)
    # where it does not -- so a fixture hardcoding either one is green on one
    # kind of host and red on the other. Fixture only; the modes themselves
    # are asserted in tests/unit/t_shared_endpoint_rules.nim.
    setFilePermissions(socketDir, endpointDirectoryPermissions())
    check fileExists(daemonPath())

    let daemon = startProcess(
      daemonPath(),
      args = [
        "--socket", socketPath,
        # The host state -- identity and observation store -- in the scratch
        # directory, never the machine's: without it this daemon read and wrote
        # the host-wide store other daemons on the host are using.
        "--host-identity-file", socketPath.parentDir / "host-id",
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
        forkingCommand()
      )
      let elapsed = epochTime() - start
      reapLinger(execution.process.stdout)

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
        removeScratchRoot(socketDir)
