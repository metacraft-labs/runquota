import std/[envvars, os, osproc, strutils, unittest]

when defined(posix):
  import std/posix

import runquota_client
import runquota_core
import runquota_protocol

const HelperModeEnv = "RUNQUOTA_E2E_CRASH_MODE"

var daemonCounter = 0

proc daemonPath(): string =
  getCurrentDir() / "build" / "bin" / "runquotad"

proc testRequest(label: string): ResourceRequest =
  resourceRequest(
    label,
    milliCpu(1000),
    bytes(128'u64 * 1024'u64 * 1024'u64)
  )

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

proc readStatus(): DaemonStatusMessage =
  var client = connectDefault()
  defer: client.close()
  client.daemonStatus()

proc waitForStatus(activeSessions, activeLeases, supervisorLost,
                   finishedLeases: uint32; totalFinished: uint64): DaemonStatusMessage =
  var last = DaemonStatusMessage()
  var lastError = ""
  for _ in 0 ..< 80:
    try:
      last = readStatus()
      if last.activeSessions == activeSessions and
          last.activeLeases == activeLeases and
          last.supervisorLostLeases == supervisorLost and
          last.finishedLeases == finishedLeases and
          last.totalFinished == totalFinished:
        return last
    except CatchableError as error:
      lastError = error.msg
    sleep(50)
  raise newException(
    OSError,
    "status did not converge: sessions=" & $last.activeSessions &
      " leases=" & $last.activeLeases &
      " supervisor_lost=" & $last.supervisorLostLeases &
      " finished=" & $last.finishedLeases &
      " total_finished=" & $last.totalFinished &
      " last_error=" & lastError
  )

proc spawnHelper(mode: string; args: openArray[string] = []): owned(Process) =
  putEnv(HelperModeEnv, mode)
  try:
    result = startProcess(
      getAppFilename(),
      args = args,
      options = {poStdErrToStdOut}
    )
  finally:
    delEnv(HelperModeEnv)

proc waitForReady(path: string) =
  for _ in 0 ..< 100:
    if fileExists(path):
      return
    sleep(50)
  raise newException(OSError, "helper did not report ready: " & path)

proc blockUntilKilled() =
  while true:
    sleep(1000)

proc forceKillSupervisor(process: var owned(Process)) =
  when defined(posix):
    check kill(Pid(process.processID), SIGKILL) == 0
  else:
    process.terminate()
  discard process.waitForExit(3000)
  check not process.running

proc runGrantedLeak(exitCode: int): int =
  var client = connectDefault()
  var session = client.registerSession("e2e-crash-granted", "0.1.0")
  var lease = session.requestLease(testRequest("granted-leak"))
  discard lease.id
  exitCode

proc runGrantedUntilKilled(readyPath: string): int =
  var client = connectDefault()
  var session = client.registerSession("e2e-crash-granted-kill", "0.1.0")
  var lease = session.requestLease(testRequest("granted-kill"))
  discard lease.id
  writeFile(readyPath, "ready")
  blockUntilKilled()
  0

proc runStartingLeak(): int =
  var client = connectDefault()
  var session = client.registerSession("e2e-crash-starting", "0.1.0")
  var lease = session.requestLease(testRequest("starting-leak"))
  lease.markStarting()
  32

proc runStartingUntilKilled(readyPath: string): int =
  var client = connectDefault()
  var session = client.registerSession("e2e-crash-starting-kill", "0.1.0")
  var lease = session.requestLease(testRequest("starting-kill"))
  lease.markStarting()
  writeFile(readyPath, "ready")
  blockUntilKilled()
  0

proc runRunningLeak(pidPath: string): int =
  var child = startProcess(
    "/bin/sleep",
    args = ["30"],
    options = {poStdErrToStdOut}
  )
  writeFile(pidPath, $child.processID)
  var client = connectDefault()
  var session = client.registerSession("e2e-crash-running", "0.1.0")
  var lease = session.requestLease(testRequest("running-leak"))
  lease.markRunning(childProcessId = uint64(child.processID))
  child.close()
  33

proc runRunningUntilKilled(readyPath, pidPath: string): int =
  var child = startProcess(
    "/bin/sleep",
    args = ["30"],
    options = {poStdErrToStdOut}
  )
  writeFile(pidPath, $child.processID)
  var client = connectDefault()
  var session = client.registerSession("e2e-crash-running-kill", "0.1.0")
  var lease = session.requestLease(testRequest("running-kill"))
  lease.markRunning(childProcessId = uint64(child.processID))
  writeFile(readyPath, "ready")
  child.close()
  blockUntilKilled()
  0

proc terminatePidFile(pidPath: string) =
  if not fileExists(pidPath):
    return
  let pid = parseInt(readFile(pidPath).strip())
  when defined(posix):
    discard kill(Pid(pid), SIGTERM)
  removeFile(pidPath)

let helperMode = getEnv(HelperModeEnv)
if helperMode.len > 0:
  case helperMode
  of "granted-normal":
    quit runGrantedLeak(0)
  of "granted-abnormal":
    quit runGrantedLeak(31)
  of "granted-kill":
    let args = commandLineParams()
    if args.len != 1:
      quit 2
    quit runGrantedUntilKilled(args[0])
  of "starting-abnormal":
    quit runStartingLeak()
  of "starting-kill":
    let args = commandLineParams()
    if args.len != 1:
      quit 2
    quit runStartingUntilKilled(args[0])
  of "running-abnormal":
    let args = commandLineParams()
    if args.len != 1:
      quit 2
    quit runRunningLeak(args[0])
  of "running-kill":
    let args = commandLineParams()
    if args.len != 2:
      quit 2
    quit runRunningUntilKilled(args[0], args[1])
  else:
    quit 2

template withDaemon(body: untyped) =
  inc daemonCounter
  let socketDir {.inject.} = "/tmp" / ("rq" & $getCurrentProcessId() & "-" & $daemonCounter)
  let socketPath {.inject.} = socketDir / "runquotad.sock"
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
    body
  finally:
    if process.running:
      process.terminate()
      discard process.waitForExit(3000)
    process.close()
    if dirExists(socketDir):
      removeDir(socketDir)

suite "e2e_runquota_client_exit_releases_lease":
  test "explicit release still clears the lease before session close":
    withDaemon:
      var client = connectDefault()
      var session = client.registerSession("e2e-crash-explicit", "0.1.0")
      var lease = session.requestLease(testRequest("explicit-release"))
      lease.release()
      session.closeSession()
      client.close()

      let status = waitForStatus(0'u32, 0'u32, 0'u32, 0'u32, 0'u64)
      check status.totalGranted == 1'u64

  test "normal supervisor exit releases granted-but-not-started lease":
    withDaemon:
      var helper = spawnHelper("granted-normal")
      check helper.waitForExit(3000) == 0
      helper.close()

      let status = waitForStatus(0'u32, 0'u32, 0'u32, 0'u32, 0'u64)
      check status.totalGranted == 1'u64

  test "abnormal supervisor exit also releases granted-but-not-started lease":
    withDaemon:
      var helper = spawnHelper("granted-abnormal")
      check helper.waitForExit(3000) == 31
      helper.close()

      let status = waitForStatus(0'u32, 0'u32, 0'u32, 0'u32, 0'u64)
      check status.totalGranted == 1'u64

  test "forced supervisor kill releases granted-but-not-started lease":
    withDaemon:
      let readyPath = socketDir / "granted.ready"
      var helper = spawnHelper("granted-kill", [readyPath])
      try:
        waitForReady(readyPath)
        forceKillSupervisor(helper)

        let status = waitForStatus(0'u32, 0'u32, 0'u32, 0'u32, 0'u64)
        check status.totalGranted == 1'u64
      finally:
        if helper.running:
          helper.terminate()
          discard helper.waitForExit(3000)
        helper.close()

  test "starting lease becomes supervisor-lost on supervisor exit":
    withDaemon:
      var helper = spawnHelper("starting-abnormal")
      check helper.waitForExit(3000) == 32
      helper.close()

      let status = waitForStatus(0'u32, 1'u32, 1'u32, 0'u32, 0'u64)
      check status.totalGranted == 1'u64

  test "forced supervisor kill marks starting lease supervisor-lost":
    withDaemon:
      let readyPath = socketDir / "starting.ready"
      var helper = spawnHelper("starting-kill", [readyPath])
      try:
        waitForReady(readyPath)
        forceKillSupervisor(helper)

        let status = waitForStatus(0'u32, 1'u32, 1'u32, 0'u32, 0'u64)
        check status.totalGranted == 1'u64
        check status.totalFinished == 0'u64
      finally:
        if helper.running:
          helper.terminate()
          discard helper.waitForExit(3000)
        helper.close()

  test "running lease becomes supervisor-lost without LeaseFinished inference":
    withDaemon:
      let childPidPath = socketDir / "child.pid"
      var helper = spawnHelper("running-abnormal", [childPidPath])
      try:
        check helper.waitForExit(3000) == 33
        helper.close()

        let status = waitForStatus(0'u32, 1'u32, 1'u32, 0'u32, 0'u64)
        check status.totalGranted == 1'u64
        check status.totalFinished == 0'u64
      finally:
        terminatePidFile(childPidPath)

  test "forced supervisor kill marks running lease supervisor-lost without LeaseFinished inference":
    withDaemon:
      let readyPath = socketDir / "running.ready"
      let childPidPath = socketDir / "child-kill.pid"
      var helper = spawnHelper("running-kill", [readyPath, childPidPath])
      try:
        waitForReady(readyPath)
        forceKillSupervisor(helper)

        let status = waitForStatus(0'u32, 1'u32, 1'u32, 0'u32, 0'u64)
        check status.totalGranted == 1'u64
        check status.totalFinished == 0'u64
      finally:
        if helper.running:
          helper.terminate()
          discard helper.waitForExit(3000)
        helper.close()
        terminatePidFile(childPidPath)
