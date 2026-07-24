import std/[envvars, os, osproc, strutils, times, unittest]

when defined(macosx):
  import std/posix

import runquota_core
import runquota_host_macos

const
  FixtureModeEnv = "RUNQUOTA_MACOS_TELEMETRY_FIXTURE"
  FixtureLifetimeMillis = 20_000
  SentinelBytes = 64 * 1024 * 1024

proc sourcePath(parts: varargs[string]): string =
  result = getCurrentDir()
  for part in parts:
    result = result / part

when defined(macosx):
  type
    Timeval {.importc: "struct timeval", header: "<sys/time.h>",
               bycopy.} = object
      tv_sec {.importc.}: int64
      tv_usec {.importc.}: int32

    Rusage {.importc: "struct rusage", header: "<sys/resource.h>",
              bycopy.} = object
      ru_utime {.importc.}: Timeval
      ru_stime {.importc.}: Timeval

  proc getRusage(who: cint; usage: ptr Rusage): cint {.
    importc: "getrusage", header: "<sys/resource.h>".}

  proc alarm(seconds: cuint): cuint {.
    importc: "alarm", header: "<unistd.h>".}

  proc cpuUsageMicros(): uint64 =
    var usage: Rusage
    doAssert getRusage(0.cint, addr usage) == 0.cint
    let userMicros =
      uint64(usage.ru_utime.tv_sec) * 1_000_000'u64 +
      uint64(usage.ru_utime.tv_usec)
    let systemMicros =
      uint64(usage.ru_stime.tv_sec) * 1_000_000'u64 +
      uint64(usage.ru_stime.tv_usec)
    userMicros + systemMicros

  proc burnCpu(milliseconds: int): uint64 =
    let deadline = epochTime() + float(milliseconds) / 1000.0
    var accumulator = 0x9e3779b97f4a7c15'u64
    while epochTime() < deadline:
      for index in 0 ..< 10_000:
        accumulator = (accumulator xor uint64(index)) *
            6364136223846793005'u64 +
          1442695040888963407'u64
    accumulator

  proc startFixture(mode: string; args: openArray[string]): owned(Process) =
    putEnv(FixtureModeEnv, mode)
    try:
      result = startProcess(
        getAppFilename(),
        args = args,
        options = {poStdErrToStdOut}
      )
    finally:
      delEnv(FixtureModeEnv)

  proc waitForStop(stopPath: string) =
    let deadline = epochTime() + float(FixtureLifetimeMillis) / 1000.0
    while not fileExists(stopPath) and epochTime() < deadline:
      sleep(10)

  proc stopProcess(process: var owned(Process)) =
    if process.isNil:
      return
    if process.running:
      let exitCode = process.waitForExit(3000)
      if exitCode == -1 and process.running:
        process.terminate()
        discard process.waitForExit(3000)
    process.close()

  proc runLeaf(stopPath: string): int =
    discard burnCpu(75)
    waitForStop(stopPath)
    0

  proc runBranch(readyPath, stopPath: string): int =
    var leaf = startFixture("leaf", [stopPath])
    var leafClosed = false
    writeFile(readyPath, $getCurrentProcessId() & " " & $leaf.processID & "\n")
    let deadline = epochTime() + float(FixtureLifetimeMillis) / 1000.0
    while not fileExists(stopPath) and epochTime() < deadline:
      if not leafClosed and not leaf.running:
        discard leaf.waitForExit(100)
        leaf.close()
        leafClosed = true
      sleep(10)
    if not leafClosed:
      if leaf.running:
        leaf.terminate()
      discard leaf.waitForExit(3000)
      leaf.close()
    0

  proc runRoot(readyPath, branchReadyPath, stopPath: string): int =
    var branch = startFixture("branch", [branchReadyPath, stopPath])
    discard burnCpu(75)
    writeFile(readyPath, $getCurrentProcessId() & " " & $branch.processID & "\n")
    waitForStop(stopPath)
    if branch.running:
      branch.terminate()
    discard branch.waitForExit(3000)
    branch.close()
    0

  proc runSentinel(readyPath, stopPath: string): int =
    var ballast = newSeq[byte](SentinelBytes)
    for index in countup(0, ballast.high, 4096):
      ballast[index] = byte((index div 4096) and 0xff)
    writeFile(readyPath, $getCurrentProcessId() & "\n")
    waitForStop(stopPath)
    doAssert ballast[ballast.high - (ballast.high mod 4096)] >= 0'u8
    0

  proc waitForFile(path: string) =
    let deadline = epochTime() + 5.0
    while not fileExists(path) and epochTime() < deadline:
      sleep(10)
    if not fileExists(path):
      raise newException(OSError, "fixture did not report ready: " & path)

  proc fixturePids(path: string): seq[int] =
    for value in readFile(path).splitWhitespace():
      result.add(parseInt(value))

  let fixtureMode = getEnv(FixtureModeEnv)
  if fixtureMode.len > 0:
    let args = commandLineParams()
    case fixtureMode
    of "root":
      if args.len != 3:
        quit 2
      quit runRoot(args[0], args[1], args[2])
    of "branch":
      if args.len != 2:
        quit 2
      quit runBranch(args[0], args[1])
    of "leaf":
      if args.len != 1:
        quit 2
      quit runLeaf(args[0])
    of "sentinel":
      if args.len != 2:
        quit 2
      quit runSentinel(args[0], args[1])
    else:
      quit 2

suite "runquota_host_macos native process telemetry":
  test "process telemetry implementation has no subprocess path":
    let helperSource = readFile(sourcePath(
      "libs",
      "runquota_host_macos",
      "src",
      "runquota_host_macos",
      "process_telemetry.nim"
    ))
    let backendSource = readFile(sourcePath(
      "libs",
      "runquota_host_macos",
      "src",
      "runquota_host_macos.nim"
    ))
    for forbidden in [
      "std/osproc",
      "execProcess",
      "startProcess",
      "poUsePath",
      "/bin/ps"
    ]:
      check not helperSource.contains(forbidden)
    check not backendSource.contains("/bin/ps")
    check backendSource.contains(
      "sampleMacosProcessTreeTelemetryNative(rootProcessId)"
    )

  when defined(macosx):
    test "CPU totals use microseconds rather than Mach ticks or nanoseconds":
      let processId = uint64(getCurrentProcessId())
      let before = sampleMacosProcessTreeTelemetry(processId)
      let usageBefore = cpuUsageMicros()
      let accumulator = burnCpu(150)
      let usageAfter = cpuUsageMicros()
      let after = sampleMacosProcessTreeTelemetry(processId)

      check accumulator != 0'u64
      check before.diagnostic.code == diagOk
      check after.diagnostic.code == diagOk
      check after.cpuTimeMicros >= before.cpuTimeMicros
      check usageAfter > usageBefore
      let telemetryDelta = after.cpuTimeMicros - before.cpuTimeMicros
      let usageDelta = usageAfter - usageBefore
      check telemetryDelta >= usageDelta div 2'u64
      check telemetryDelta <= usageDelta * 3'u64 + 20_000'u64

    test "real process trees are sampled repeatedly without touching a sentinel":
      let fixtureDir = getTempDir() /
        ("runquota-macos-telemetry-" & $getCurrentProcessId())
      let rootReadyPath = fixtureDir / "root.ready"
      let branchReadyPath = fixtureDir / "branch.ready"
      let sentinelReadyPath = fixtureDir / "sentinel.ready"
      let stopPath = fixtureDir / "stop"
      if dirExists(fixtureDir):
        removeDir(fixtureDir)
      createDir(fixtureDir)

      var root = startFixture(
        "root",
        [rootReadyPath, branchReadyPath, stopPath]
      )
      var sentinel = startFixture(
        "sentinel",
        [sentinelReadyPath, stopPath]
      )
      defer:
        writeFile(stopPath, "stop\n")
        stopProcess(root)
        stopProcess(sentinel)
        if dirExists(fixtureDir):
          removeDir(fixtureDir)

      waitForFile(rootReadyPath)
      waitForFile(branchReadyPath)
      waitForFile(sentinelReadyPath)
      let rootPids = fixturePids(rootReadyPath)
      let branchPids = fixturePids(branchReadyPath)
      let sentinelPids = fixturePids(sentinelReadyPath)
      check rootPids.len == 2
      check branchPids.len == 2
      check sentinelPids.len == 1
      check rootPids[0] == root.processID
      check rootPids[1] == branchPids[0]

      let rootPid = uint64(rootPids[0])
      let branchPid = uint64(branchPids[0])
      let leafPid = uint64(branchPids[1])
      let sentinelPid = uint64(sentinelPids[0])
      let sentinelBefore = sampleMacosProcessTreeTelemetry(sentinelPid)
      check sentinelBefore.diagnostic.code == diagOk
      check sentinelBefore.rootAlive
      check sentinelBefore.processCount == 1'u32
      check sentinelBefore.residentMemoryBytes >= uint64(SentinelBytes div 2)

      discard alarm(15.cuint)
      defer:
        discard alarm(0.cuint)
      let repeatedStart = epochTime()
      var lastCpuMicros = 0'u64
      for _ in 0 ..< 20:
        let sampleStart = epochTime()
        let rootSample = sampleMacosProcessTreeTelemetry(rootPid)
        let sampleSeconds = epochTime() - sampleStart
        check sampleSeconds < 1.0
        check rootSample.diagnostic.code == diagOk
        check rootSample.rootAlive
        check rootSample.processCount == 3'u32
        check rootSample.residentMemoryBytes > 0'u64
        check rootSample.cpuTimeMicros > 0'u64
        check rootSample.cpuTimeMicros >= lastCpuMicros
        lastCpuMicros = rootSample.cpuTimeMicros

        let branchSample = sampleMacosProcessTreeTelemetry(branchPid)
        check branchSample.diagnostic.code == diagOk
        check branchSample.rootAlive
        check branchSample.processCount == 2'u32

        let leafSample = sampleMacosProcessTreeTelemetry(leafPid)
        check leafSample.diagnostic.code == diagOk
        check leafSample.rootAlive
        check leafSample.processCount == 1'u32
      check epochTime() - repeatedStart < 10.0

      check kill(Pid(leafPid), SIGKILL) == 0.cint
      var branchAfterExit: HostProcessTreeTelemetrySample
      let disappearanceDeadline = epochTime() + 3.0
      while epochTime() < disappearanceDeadline:
        branchAfterExit = sampleMacosProcessTreeTelemetry(branchPid)
        if branchAfterExit.diagnostic.code == diagOk and
            branchAfterExit.rootAlive and branchAfterExit.processCount == 1'u32:
          break
        sleep(10)
      check branchAfterExit.diagnostic.code == diagOk
      check branchAfterExit.rootAlive
      check branchAfterExit.processCount == 1'u32

      let vanished = sampleMacosProcessTreeTelemetry(leafPid)
      check vanished.diagnostic.code == diagUnavailable
      check not vanished.rootAlive
      check vanished.processCount == 0'u32

      let sentinelAfter = sampleMacosProcessTreeTelemetry(sentinelPid)
      check sentinel.running
      check sentinelAfter.diagnostic.code == diagOk
      check sentinelAfter.rootAlive
      check sentinelAfter.processCount == 1'u32
      check sentinelAfter.residentMemoryBytes >= uint64(SentinelBytes div 2)
  else:
    test "non-macOS builds report the backend as unavailable":
      let sample = sampleMacosProcessTreeTelemetry(123'u64)
      check sample.diagnostic.code == diagUnavailable
      check not sample.rootAlive
      check sample.processCount == 0'u32
      check sample.source == "macos-libproc"
