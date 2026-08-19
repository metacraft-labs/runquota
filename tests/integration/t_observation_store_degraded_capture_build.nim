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
  createDir(result)

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

proc startDaemon(socketPath, observationDb: string): DaemonHandle =
  let process = startProcess(
    daemonPath(),
    args = ["--socket", socketPath, "--observation-db", observationDb],
    options = {poStdErrToStdOut}
  )
  waitForSocket(socketPath)
  var lines: seq[string] = @[]
  # The daemon prints exactly two startup lines and then goes quiet: the
  # endpoint, and the observation-store report. Reading precisely those two
  # cannot deadlock against a daemon that never writes again.
  for _ in 0 ..< 2:
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
    let source = writeBuildInput(dir)
    let binary = dir / "hello.bin"
    check fileExists(daemonPath())
    check fileExists(cliPath())
    putEnv("RUNQUOTA_SOCKET", socketPath)

    var daemon = startDaemon(socketPath, dbPath)
    try:
      check daemon.startupLines[1].contains("capture enabled")

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
      let executions = store.readExecutions()
      check executions.len >= 1
      check executions[0].runId == runs[0].runId
      check executions[0].hostId == runs[0].hostId
      check executions[0].leaseId.isSome
      check executions[0].termination == tExited
      check executions[0].exitStatus == 0
      check executions[0].durationMillis >= 0
    finally:
      daemon.stop()

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

    var daemon = startDaemon(socketPath, dbPath)
    try:
      # The report is clear, and it is on stdout where an operator sees it.
      check daemon.startupLines[1].contains("corrupt")
      check daemon.startupLines[1].contains("capture disabled")
      check daemon.startupLines[1].contains(dbPath)

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
