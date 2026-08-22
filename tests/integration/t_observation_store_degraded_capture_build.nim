## M9 gate, clause 4 (the other half): a corrupt observation store degrades
## to no capture with a clear report, AND A BUILD OVER IT STILL SUCCEEDS.
##
## The build is real: a Nim source file compiled by the real compiler into
## a real binary, which is then executed and its output checked. The
## admission path is real: the compile runs under a real `runquotad` and a
## real lease taken by the real `runquota acquire` CLI. Nothing is mocked.
##
## The corrupt arm alone would prove very little — a store nothing ever
## writes to cannot fail a build no matter how broken it is. So the healthy
## arm runs FIRST and asserts that the same build, over an intact store,
## really does produce spine rows. That is what makes the corrupt arm's
## success a statement about degradation rather than about dead code.

import std/[nativesockets, options, os, osproc, streams, strutils, unittest]

import runquota_observation_store

proc scratchDir(name: string): string =
  # Kept short on purpose: a Unix-domain socket path is capped at ~104
  # bytes, and a chatty temporary directory name silently costs the daemon
  # its endpoint.
  result = getTempDir() / ("rq-obs-" & $getCurrentProcessId() & "-" & name)
  removeDir(result)
  # 0700, not whatever the umask leaves: `runquotad` and every client refuse a
  # rendezvous directory whose mode or owner they cannot vouch for.
  createDir(result)
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})

proc daemonPath(): string =
  getCurrentDir() / "build" / "bin" / "runquotad"

proc cliPath(): string =
  getCurrentDir() / "build" / "bin" / "runquota"

proc waitForSocket(socketPath: string) =
  for _ in 0 ..< 200:
    if fileExists(socketPath) or socketPath.startsWith("\\\\"):
      return
    sleep(25)

proc writeBuildInput(dir: string): string =
  result = dir / "hello.nim"
  writeFile(result, "echo \"observation-store-build-ok\"\n")

proc runBuildUnderLease(dir, source, binary: string): tuple[
    exitCode: int; output: string] =
  ## A genuine build, gated through the real CLI and the real daemon.
  let command = @[
    cliPath(), "acquire", "--cpu", "1000", "--mem", "512MB",
    "--label", "observation-store-build", "--",
    findExe("nim"), "c", "--hints:off", "--verbosity:0",
    "--nimcache:" & (dir / "nimcache"), "--out:" & binary, source
  ]
  let process = startProcess(command[0], args = command[1 .. ^1],
    options = {poStdErrToStdOut})
  let output = process.outputStream.readAll()
  let code = process.waitForExit()
  process.close()
  (code, output)

type DaemonHandle = object
  process: Process
  startupLines: seq[string]

proc startDaemon(socketPath, observationDb, identityFile: string):
    DaemonHandle =
  # `--host-identity-file` keeps the test off the operator's real machine
  # identity: without it this test would read, or create, the `host_id`
  # the developer's own daemon uses.
  let process = startProcess(
    daemonPath(),
    args = ["--socket", socketPath, "--observation-db", observationDb,
            "--host-identity-file", identityFile],
    options = {poStdErrToStdOut}
  )
  waitForSocket(socketPath)
  var lines: seq[string] = @[]
  # The daemon prints exactly three startup lines whenever a store path was
  # given, and then goes quiet: the endpoint, the observation-store report,
  # and the host-identity/hardware-profile report. Reading precisely those
  # three cannot deadlock against a daemon that never writes again.
  for _ in 0 ..< 3:
    lines.add(process.outputStream.readLine())
  DaemonHandle(process: process, startupLines: lines)

proc stop(handle: var DaemonHandle) =
  if handle.process.running:
    handle.process.terminate()
    discard handle.process.waitForExit(5000)
  handle.process.close()

proc waitForExecutionRows(path: string; atLeast: int): int =
  for _ in 0 ..< 100:
    let store = openObservationStore(path)
    if store.captureEnabled:
      result = store.readExecutions().len
      if result >= atLeast:
        return
    sleep(100)

suite "observation_store_degraded_capture_build":
  test "a build over a healthy store succeeds and is recorded":
    let dir = scratchDir("h")
    defer: removeDir(dir)
    let socketPath = dir / "runquotad.sock"
    let dbPath = dir / "observations.sqlite"
    let identityFile = dir / "host-id"
    let source = writeBuildInput(dir)
    let binary = dir / "hello.bin"
    check fileExists(daemonPath())
    check fileExists(cliPath())
    putEnv("RUNQUOTA_SOCKET", socketPath)

    var hostId = ""
    var profileId = ""
    var daemon = startDaemon(socketPath, dbPath, identityFile)
    try:
      check daemon.startupLines[1].contains("capture enabled")
      check daemon.startupLines[2].contains("hardware profile")

      let build = runBuildUnderLease(dir, source, binary)
      check build.exitCode == 0
      check fileExists(binary)
      check execProcess(binary).strip() == "observation-store-build-ok"

      check waitForExecutionRows(dbPath, 1) >= 1
      let store = openObservationStore(dbPath)
      check store.captureEnabled
      let runs = store.readRuns()
      check runs.len >= 1
      check runs[0].tool == "runquota acquire"
      check runs[0].hostId.len > 0
      check not runs[0].hostId.contains(getHostName())
      # Opaque and fixed-shape, which is the assertion the containment
      # check above cannot make on a host whose name is short.
      check isOpaqueId(runs[0].hostId, "host-")
      # Guarded so a daemon that wrote its identity somewhere else fails
      # the restart assertions below too, rather than taking the test out
      # with an IO exception before they are ever reached.
      check fileExists(identityFile)
      if fileExists(identityFile):
        check readFile(identityFile).strip() == runs[0].hostId

      let executions = store.readExecutions()
      check executions.len >= 1
      check executions[0].runId == runs[0].runId
      check executions[0].hostId == runs[0].hostId
      check executions[0].leaseId.isSome
      check executions[0].termination == tExited
      check executions[0].exitStatus == 0
      check executions[0].durationMillis >= 0

      # M10: the execution carries the hardware dimension OS-6 needs, and
      # it is the profile that was current when it ran.
      let profiles = store.readHostProfiles()
      check profiles.len == 1
      check profiles[0].hostId == runs[0].hostId
      check executions[0].hostProfileId == some(profiles[0].profileId)
      check profiles[0].validToUnixMillis.isNone
      check profiles[0].validFromUnixMillis <= executions[0].startedAtUnixMillis
      check profiles[0].profileHash.startsWith("sha256:")
      # A real machine was described, not a row of placeholders.
      check profiles[0].cpuModel != unknownField
      check profiles[0].ramBytes > 0
      check profiles[0].logicalCores >= 1
      check profiles[0].diskClass != dcUnknown
      check profiles[0].profileHash ==
        profileHash(hardwareProfile(profiles[0]))
      check daemon.startupLines[2].contains(profiles[0].profileId)
      check daemon.startupLines[2].contains(runs[0].hostId)

      hostId = runs[0].hostId
      profileId = profiles[0].profileId
    finally:
      daemon.stop()

    # Re-running with unchanged hardware must not accumulate. This is the
    # gate's "re-running" clause against a real daemon rather than against
    # a library call: a second process, a second store open, a second
    # detection, and the same two rows.
    check hostId.len > 0
    let secondSocket = dir / "second.sock"
    putEnv("RUNQUOTA_SOCKET", secondSocket)
    var restarted = startDaemon(secondSocket, dbPath, identityFile)
    try:
      check restarted.startupLines[1].contains("capture enabled")
      let store = openObservationStore(dbPath)
      check store.captureEnabled
      let hosts = store.readHosts()
      check hosts.len == 1
      check hosts[0].hostId == hostId
      let profiles = store.readHostProfiles()
      check profiles.len == 1
      check profiles[0].profileId == profileId
      check profiles[0].validToUnixMillis.isNone
      # And the restarted daemon agrees it is the same machine on the same
      # hardware, rather than merely having failed to write.
      check restarted.startupLines[2].contains(hostId)
      check restarted.startupLines[2].contains(profileId)
    finally:
      restarted.stop()

  test "a build over a corrupt store still succeeds, and capture is off":
    let dir = scratchDir("c")
    defer: removeDir(dir)
    let socketPath = dir / "runquotad.sock"
    let dbPath = dir / "observations.sqlite"

    # Build a real store first, then truncate it: a store that never held
    # anything would be an easier target than the one an operator has.
    block:
      let store = openObservationStore(dbPath)
      check store.captureEnabled
      check store.insertHost(HostRow(hostId: "h1", createdAtUnixMillis: 1,
        lastBootId: "b1"))
    let data = readFile(dbPath)
    check data.len > 4096
    writeFile(dbPath, data[0 ..< data.len div 2])
    let corruptSize = getFileSize(dbPath)

    let source = writeBuildInput(dir)
    let binary = dir / "hello.bin"
    putEnv("RUNQUOTA_SOCKET", socketPath)

    var daemon = startDaemon(socketPath, dbPath, dir / "host-id")
    try:
      # The report is clear, and it is on stdout where an operator sees it.
      check daemon.startupLines[1].contains("corrupt")
      check daemon.startupLines[1].contains("capture disabled")
      check daemon.startupLines[1].contains(dbPath)
      # And the identity line says the host and the profile were not
      # recorded, rather than claiming a profile nothing was written to.
      check daemon.startupLines[2].contains("not recorded")
      check not fileExists(dir / "host-id")

      let build = runBuildUnderLease(dir, source, binary)
      check build.exitCode == 0
      check fileExists(binary)
      check execProcess(binary).strip() == "observation-store-build-ok"

      # Degraded to NO capture, and the corrupt file was not repaired.
      let store = openObservationStore(dbPath)
      check store.status == ssCorrupt
      check not store.captureEnabled
      check getFileSize(dbPath) == corruptSize

      # The daemon is still a daemon: it kept serving through the build.
      check daemon.process.running
    finally:
      daemon.stop()
