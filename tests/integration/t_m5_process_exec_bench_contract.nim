import std/[json, os, osproc, strutils, unittest]

import runquota_client
import runquota_core
import runquota_exec
import runquota_process

const FixtureOutput = "--m5-fixture-output"
const FixtureCwdEnv = "--m5-fixture-cwd-env"
const FixtureSleep = "--m5-fixture-sleep"
const FixtureEnvName = "RUNQUOTA_M5_CHILD_ENV"
const FixtureRecord = "runquota-m5-cwd-env.txt"

if commandLineParams().len == 1 and commandLineParams()[0] == FixtureOutput:
  stdout.write("m5 stdout\n")
  stderr.write("m5 stderr\n")
  quit 0

if commandLineParams().len == 1 and commandLineParams()[0] == FixtureCwdEnv:
  let cwd = getCurrentDir()
  let envValue = getEnv(FixtureEnvName)
  stdout.write("m5 cwd=" & cwd & "\n")
  stdout.write("m5 env=" & envValue & "\n")
  stderr.write("m5 cwd-env stderr\n")
  writeFile(FixtureRecord, "cwd=" & cwd & "\nenv=" & envValue & "\n")
  quit 0

if commandLineParams().len == 1 and commandLineParams()[0] == FixtureSleep:
  sleep(5000)
  quit 0

proc daemonPath(): string =
  getCurrentDir() / "build" / "bin" / "runquotad"

proc cliPath(): string =
  getCurrentDir() / "build" / "bin" / "runquota"

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

proc prepareDir(path: string) =
  if dirExists(path):
    removeDir(path)
  createDir(path)

proc checkCwdEnvRecord(path, expectedEnv: string) =
  let recordPath = path / FixtureRecord
  check fileExists(recordPath)
  let record = readFile(recordPath)
  check record.contains("cwd=")
  check record.contains("env=" & expectedEnv)

proc hasMetricWithExtra(jsonText, namePart, extraPart: string): bool =
  let root = parseJson(jsonText)
  for item in root.items:
    if item{"name"}.getStr().contains(namePart) and
        item{"extra"}.getStr().contains(extraPart):
      return true

suite "m5_process_exec_bench_contract":
  test "benchmark recipes are present":
    let justfile = readFile("Justfile")
    check justfile.contains("bench-runquota-process-execution")
    check justfile.contains("bench-runquota-ipc")
    check fileExists("scripts/run-m5-benchmark.sh")
    check fileExists("benchmarks/lib/runquota_m5_bench.nim")

  test "process helper captures output and cancels process group":
    let profile = backendProfile()
    check profile.directArgv
    check not profile.implicitShell
    check profile.outputCapture.contains("bounded")

    var outputChild = launchProcess(commandSpec([getAppFilename(), FixtureOutput]))
    let output = outputChild.waitForCompletion(3000)
    outputChild.close()
    check output.exited
    check output.exitCode == 0
    check output.stdout.contains("m5 stdout")
    check output.stderr.contains("m5 stderr")
    check output.stdoutBytes > 0
    check output.stderrBytes > 0

    var sleeping = launchProcess(commandSpec([getAppFilename(), FixtureSleep]))
    sleep(50)
    let cancelled = sleeping.cancelAndWait(3000)
    sleeping.close()
    check cancelled.cancelled
    check cancelled.signaled or cancelled.timedOut
    check cancelled.elapsedMillis < 3500

  test "process helper applies cwd and environment to child":
    let cwdDir = getTempDir() / ("runquota-m5-direct-cwd-env-" & $getCurrentProcessId())
    prepareDir(cwdDir)
    try:
      var child = launchProcess(commandSpec(
        [getAppFilename(), FixtureCwdEnv],
        cwd = cwdDir,
        env = [FixtureEnvName & "=direct-cwd-env"],
        stdoutLimit = 4096,
        stderrLimit = 4096
      ))
      let completion = child.waitForCompletion(3000)
      child.close()

      check completion.exited
      check completion.exitCode == 0
      check completion.processId > 0
      check completion.processGroupId > 0
      check completion.stdout.contains("m5 cwd=")
      check completion.stdout.contains("m5 env=direct-cwd-env")
      check completion.stderr.contains("m5 cwd-env stderr")
      check completion.processCount > 0
      checkCwdEnvRecord(cwdDir, "direct-cwd-env")
    finally:
      if dirExists(cwdDir):
        removeDir(cwdDir)

  test "lease-bound helper and CLI use real daemon protocol":
    let socketDir = getTempDir() / ("runquota-m5-test-" & $getCurrentProcessId())
    let socketPath = socketDir / "runquotad.sock"
    if dirExists(socketDir):
      removeDir(socketDir)
    createDir(socketDir)
    check fileExists(daemonPath())
    check fileExists(cliPath())

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
      var session = client.registerSession("m5-helper-contract", versionString())

      let leaseCwdDir = socketDir / "lease-cwd-env"
      prepareDir(leaseCwdDir)
      let beforeLease = client.daemonStatus().totalFinished
      let execution = session.runWithLease(
        req("helper-cwd-env-output"),
        [getAppFilename(), FixtureCwdEnv],
        cwd = leaseCwdDir,
        env = [FixtureEnvName & "=lease-cwd-env"],
        stdoutLimit = 4096,
        stderrLimit = 4096
      )
      check execution.leaseFinishedSent
      check execution.leaseReleased
      check execution.backend.name == backendProfile().name
      check execution.backend.directArgv
      check not execution.backend.implicitShell
      check execution.process.exited
      check execution.process.exitCode == 0
      check execution.process.processId > 0
      check execution.process.processGroupId > 0
      check execution.process.processCount > 0
      check execution.process.stdout.contains("m5 cwd=")
      check execution.process.stdout.contains("m5 env=lease-cwd-env")
      check execution.process.stderr.contains("m5 cwd-env stderr")
      check execution.process.stdoutBytes > 0
      check execution.process.stderrBytes > 0
      check client.daemonStatus().totalFinished > beforeLease
      checkCwdEnvRecord(leaseCwdDir, "lease-cwd-env")

      let beforeCli = client.daemonStatus().totalFinished
      let cliOutput = execProcess(
        cliPath(),
        args = [
          "acquire",
          "--cpu", "100",
          "--mem", "1MiB",
          "--label", "cli-helper-output",
          "--",
          getAppFilename(),
          FixtureOutput
        ],
        env = nil,
        options = {poUsePath}
      )
      check cliOutput.contains("m5 stdout")
      check client.daemonStatus().totalFinished > beforeCli

      session.closeSession()
      client.close()
    finally:
      if daemon.running:
        daemon.terminate()
        discard daemon.waitForExit(3000)
      daemon.close()
      if dirExists(socketDir):
        removeDir(socketDir)

  test "process benchmark quick path emits cwd env workload evidence":
    let output = execProcess(
      "scripts/run-m5-benchmark.sh",
      args = ["process", "--quick"],
      options = {poUsePath}
    )
    check hasMetricWithExtra(output, "raw-cwd-env fixture", "cwd_env=verified")
    check hasMetricWithExtra(output, "lease-cwd-env fixture", "cwd_env=verified")
    check hasMetricWithExtra(output, "lease-output-capture bytes", "LeaseFinished=true")
