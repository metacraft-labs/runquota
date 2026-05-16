import std/[algorithm, math, os, osproc, strutils, times]

import runquota_client
import runquota_core
import runquota_exec
import runquota_process
import runquota_protocol

const FixtureNull = "--fixture-null"
const FixtureOutput = "--fixture-output"
const FixtureCwdEnv = "--fixture-cwd-env"
const FixtureSleep = "--fixture-sleep"
const FixtureTelemetry = "--fixture-telemetry"
const FixtureEnvName = "RUNQUOTA_M5_CHILD_ENV"
const FixtureRecord = "runquota-m5-cwd-env.txt"

type
  BenchMetric = object
    name: string
    unit: string
    value: float
    extra: string

proc fixtureMain(): bool =
  let args = commandLineParams()
  if args.len == 0:
    return false
  case args[0]
  of FixtureNull:
    quit 0
  of FixtureOutput:
    stdout.write("runquota stdout fixture\n")
    stderr.write("runquota stderr fixture\n")
    quit 0
  of FixtureCwdEnv:
    let cwd = getCurrentDir()
    let envValue = getEnv(FixtureEnvName)
    stdout.write("runquota cwd=" & cwd & "\n")
    stdout.write("runquota env=" & envValue & "\n")
    stderr.write("runquota cwd-env stderr\n")
    writeFile(FixtureRecord, "cwd=" & cwd & "\nenv=" & envValue & "\n")
    quit 0
  of FixtureSleep:
    let millis = if args.len >= 2: parseInt(args[1]) else: 1000
    sleep(millis)
    quit 0
  of FixtureTelemetry:
    var data = newSeq[byte](256 * 1024)
    for i in 0 ..< data.len:
      data[i] = byte(i and 0xff)
    sleep(250)
    stdout.write($data.len & "\n")
    quit 0
  else:
    false

if fixtureMain():
  quit 0

proc jsonEscape(value: string): string =
  for ch in value:
    case ch
    of '\\': result.add("\\\\")
    of '"': result.add("\\\"")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    else: result.add(ch)

proc addMetric(metrics: var seq[BenchMetric]; name, unit: string; value: float;
               extra: string) =
  metrics.add(BenchMetric(name: name, unit: unit, value: value, extra: extra))

proc emitJson(metrics: openArray[BenchMetric]) =
  stdout.write("[")
  for i, metric in metrics:
    if i > 0:
      stdout.write(",")
    stdout.write("{\"name\":\"" & jsonEscape(metric.name) & "\",")
    stdout.write("\"unit\":\"" & jsonEscape(metric.unit) & "\",")
    stdout.write("\"value\":" & formatFloat(metric.value, ffDecimal, 3) & ",")
    stdout.write("\"extra\":\"" & jsonEscape(metric.extra) & "\"}")
  stdout.write("]\n")

proc elapsedMillis(startSeconds: float): float =
  (epochTime() - startSeconds) * 1000.0

proc percentile(values: seq[float]; pct: float): float =
  if values.len == 0:
    return 0.0
  var sorted = values
  sorted.sort()
  let index = min(sorted.high, max(0, int((pct * float(sorted.len - 1)).round)))
  sorted[index]

proc measureLatencies(count: int; body: proc() {.closure.}): seq[float] =
  for _ in 0 ..< count:
    let start = epochTime()
    body()
    result.add(elapsedMillis(start))

proc addLatencyMetrics(metrics: var seq[BenchMetric]; workload: string;
                       values: seq[float]; extra: string) =
  metrics.addMetric(workload & " p50", "ms", percentile(values, 0.50), extra)
  metrics.addMetric(workload & " p95", "ms", percentile(values, 0.95), extra)

proc repoRoot(): string =
  getCurrentDir()

proc daemonPath(): string =
  repoRoot() / "build" / "bin" / "runquotad"

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

proc startDaemon(socketPath: string): Process =
  if not fileExists(daemonPath()):
    raise newException(OSError, "missing " & daemonPath() & "; run just build first")
  result = startProcess(
    daemonPath(),
    args = [
      "--socket", socketPath,
      "--cpu-milli", "8000",
      "--memory-bytes", $((8'u64 * 1024'u64 * 1024'u64 * 1024'u64))
    ],
    options = {poStdErrToStdOut}
  )
  waitForDaemon(socketPath)

proc stopDaemon(daemon: var Process) =
  if daemon.running:
    daemon.terminate()
    discard daemon.waitForExit(3000)
  daemon.close()

proc req(label: string): ResourceRequest =
  resourceRequest(label, milliCpu(100), bytes(1024 * 1024))

proc prepareDir(path: string) =
  if dirExists(path):
    removeDir(path)
  createDir(path)

proc checkCwdEnvRecord(path, expectedEnv: string) =
  let recordPath = path / FixtureRecord
  if not fileExists(recordPath):
    raise newException(ValueError, "cwd/env fixture did not write record in requested cwd")
  let record = readFile(recordPath)
  if not record.contains("cwd=") or not record.contains("env=" & expectedEnv):
    raise newException(ValueError, "cwd/env fixture record did not contain expected values")

proc runRaw(argv: openArray[string]; cwd = ""; env: openArray[string] = []): ProcessCompletion =
  var child = launchProcess(commandSpec(
    argv,
    cwd = cwd,
    env = env,
    stdoutLimit = 4096,
    stderrLimit = 4096
  ))
  result = child.waitForCompletion()
  child.close()

proc runParallelFixture(binary: string; count: int): float =
  var children: seq[LaunchedProcess] = @[]
  let start = epochTime()
  for _ in 0 ..< count:
    children.add(launchProcess(commandSpec([binary, FixtureSleep, "25"])))
  for i in 0 ..< children.len:
    let completion = children[i].waitForCompletion(3000)
    if not completion.exited or completion.exitCode != 0:
      raise newException(ValueError, "parallel short action did not exit cleanly")
    children[i].close()
  elapsedMillis(start)

proc addBackend(metrics: var seq[BenchMetric]; suite: string) =
  let profile = backendProfile()
  metrics.addMetric(
    suite & " backend profile",
    "count",
    1.0,
    "backend=" & profile.name &
      "; launch=" & profile.launchPrimitive &
      "; output=" & profile.outputCapture &
      "; completion=" & profile.completionWait &
      "; cancellation=" & profile.cancellation &
      "; telemetry=" & profile.telemetry &
      "; direct_argv=" & $profile.directArgv &
      "; implicit_shell=" & $profile.implicitShell
  )

proc runProcessSuite(quick: bool): seq[BenchMetric] =
  let binary = getAppFilename()
  let count = if quick: 4 else: 20
  let parallelCount = if quick: 4 else: 16
  let socketDir = getTempDir() / ("runquota-m5-process-" & $getCurrentProcessId())
  let socketPath = socketDir / "runquotad.sock"
  if dirExists(socketDir):
    removeDir(socketDir)
  createDir(socketDir)
  var daemon = startDaemon(socketPath)
  try:
    result.addBackend("process-execution")

    let rawNull = measureLatencies(count, proc () =
      let completion = runRaw([binary, FixtureNull])
      if not completion.exited or completion.exitCode != 0:
        raise newException(ValueError, "raw null spawn failed")
    )
    result.addLatencyMetrics("raw-null-spawn", rawNull, "helper=runquota_process; quick=" & $quick)

    let rawOutput = measureLatencies(count, proc () =
      let completion = runRaw([binary, FixtureOutput])
      if completion.stdoutBytes == 0 or completion.stderrBytes == 0:
        raise newException(ValueError, "output capture was not exercised")
    )
    result.addLatencyMetrics("raw-stdout-small", rawOutput, "bounded_capture=true; quick=" & $quick)

    let rawCwdDir = socketDir / "raw-cwd-env"
    prepareDir(rawCwdDir)
    let rawCwdEnv = measureLatencies(count, proc () =
      let completion = runRaw(
        [binary, FixtureCwdEnv],
        cwd = rawCwdDir,
        env = [FixtureEnvName & "=raw-bench-cwd-env"]
      )
      if not completion.exited or completion.exitCode != 0:
        raise newException(ValueError, "raw cwd/env fixture failed")
      if completion.processId == 0 or completion.processGroupId == 0 or completion.processCount == 0:
        raise newException(ValueError, "raw cwd/env fixture did not return process telemetry")
      if not completion.stdout.contains("runquota env=raw-bench-cwd-env") or
          not completion.stderr.contains("runquota cwd-env stderr"):
        raise newException(ValueError, "raw cwd/env fixture output was not captured")
      checkCwdEnvRecord(rawCwdDir, "raw-bench-cwd-env")
    )
    result.addLatencyMetrics(
      "raw-cwd-env fixture",
      rawCwdEnv,
      "helper=runquota_process; cwd_env=verified; output=stdout-stderr; quick=" & $quick
    )

    var client = connectDefault()
    var session = client.registerSession("m5-process-bench", versionString())
    let leaseNull = measureLatencies(count, proc () =
      let execution = session.runWithLease(req("lease-null-spawn"), [binary, FixtureNull])
      if not execution.leaseFinishedSent or not execution.leaseReleased:
        raise newException(ValueError, "lease-bound null spawn did not finish and release")
      if not execution.process.exited or execution.process.exitCode != 0:
        raise newException(ValueError, "lease-bound null spawn failed")
      if execution.backend.name != backendProfile().name or
          execution.process.processId == 0 or
          execution.process.processGroupId == 0 or
          execution.process.processCount == 0:
        raise newException(ValueError, "lease-bound null spawn did not return helper completion evidence")
    )
    result.addLatencyMetrics("lease-null-spawn", leaseNull, "daemon=real; ipc=RQSP; quick=" & $quick)

    let leaseCwdDir = socketDir / "lease-cwd-env"
    prepareDir(leaseCwdDir)
    let leaseCwdEnv = measureLatencies(count, proc () =
      let execution = session.runWithLease(
        req("lease-cwd-env"),
        [binary, FixtureCwdEnv],
        cwd = leaseCwdDir,
        env = [FixtureEnvName & "=lease-bench-cwd-env"],
        stdoutLimit = 4096,
        stderrLimit = 4096
      )
      if not execution.leaseFinishedSent or not execution.leaseReleased:
        raise newException(ValueError, "lease cwd/env fixture did not finish and release")
      if execution.backend.name != backendProfile().name or not execution.backend.directArgv:
        raise newException(ValueError, "lease cwd/env fixture did not report observed process backend")
      if not execution.process.exited or execution.process.exitCode != 0:
        raise newException(ValueError, "lease cwd/env fixture failed")
      if execution.process.processId == 0 or execution.process.processGroupId == 0 or
          execution.process.processCount == 0:
        raise newException(ValueError, "lease cwd/env fixture did not return process telemetry")
      if not execution.process.stdout.contains("runquota env=lease-bench-cwd-env") or
          not execution.process.stderr.contains("runquota cwd-env stderr"):
        raise newException(ValueError, "lease cwd/env fixture output was not captured")
      checkCwdEnvRecord(leaseCwdDir, "lease-bench-cwd-env")
    )
    result.addLatencyMetrics(
      "lease-cwd-env fixture",
      leaseCwdEnv,
      "daemon=real; ipc=RQSP; cwd_env=verified; output=stdout-stderr; telemetry=process-completion; quick=" & $quick
    )

    let leaseOutput = session.runWithLease(req("lease-output-capture"), [binary, FixtureOutput])
    if leaseOutput.stdoutBytes == 0 or leaseOutput.stderrBytes == 0:
      raise newException(ValueError, "lease-bound output capture was not exercised")
    result.addMetric(
      "lease-output-capture bytes",
      "bytes",
      float(leaseOutput.stdoutBytes + leaseOutput.stderrBytes),
      "daemon=real; LeaseFinished=true"
    )

    let parallelMs = runParallelFixture(binary, parallelCount)
    result.addMetric(
      "parallel-short-actions throughput",
      "ops/sec",
      float(parallelCount) / (parallelMs / 1000.0),
      "helpers=" & $parallelCount & "; command=fixture-sleep"
    )

    var cancellable = launchProcess(commandSpec([binary, FixtureSleep, "5000"]))
    sleep(50)
    let cancelStart = epochTime()
    let cancelled = cancellable.cancelAndWait(3000)
    cancellable.close()
    if not cancelled.cancelled or (not cancelled.signaled and not cancelled.timedOut):
      raise newException(ValueError, "cancellation did not terminate fixture")
    result.addMetric(
      "process-tree-cancel latency",
      "ms",
      elapsedMillis(cancelStart),
      "process_group=" & $cancellable.info.processGroupId
    )

    let telemetryExecution = session.runWithLease(req("telemetry-submit"), [binary, FixtureTelemetry])
    if not telemetryExecution.leaseFinishedSent or telemetryExecution.process.processCount == 0:
      raise newException(ValueError, "completion telemetry was not submitted")
    result.addMetric(
      "telemetry-submit peak-rss",
      "bytes",
      float(telemetryExecution.process.peakResidentMemoryBytes),
      "source=" & telemetryExecution.process.telemetrySource &
        "; process_count=" & $telemetryExecution.process.processCount
    )

    session.closeSession()
    client.close()
  finally:
    stopDaemon(daemon)
    if dirExists(socketDir):
      removeDir(socketDir)

proc runIpcSuite(quick: bool): seq[BenchMetric] =
  let binary = getAppFilename()
  let count = if quick: 4 else: 30
  let socketDir = getTempDir() / ("runquota-m5-ipc-" & $getCurrentProcessId())
  let socketPath = socketDir / "runquotad.sock"
  if dirExists(socketDir):
    removeDir(socketDir)
  createDir(socketDir)
  var daemon = startDaemon(socketPath)
  try:
    result.addBackend("ipc-latency")

    let handshake = measureLatencies(count, proc () =
      var client = connectDefault()
      client.close()
    )
    result.addLatencyMetrics("handshake", handshake, "transport=unix-socket; quick=" & $quick)

    var client = connectDefault()
    let register = measureLatencies(count, proc () =
      var session = client.registerSession("m5-ipc-register", versionString())
      session.closeSession()
    )
    result.addLatencyMetrics("register-session", register, "transport=unix-socket")

    var session = client.registerSession("m5-ipc", versionString())
    let serialLease = measureLatencies(count, proc () =
      var lease = session.requestLease(req("serial-lease"))
      lease.release()
    )
    result.addLatencyMetrics("serial-lease", serialLease, "daemon=real; protocol=RQSP")

    let offerRoundtrip = measureLatencies(count, proc () =
      let decisions = session.offerCandidates([toCandidate(1001, req("candidate-offer"))])
      if decisions.len != 1 or decisions[0].queued:
        raise newException(ValueError, "candidate offer was not granted")
      var lease = decisions[0].lease
      lease.release()
    )
    result.addLatencyMetrics("candidate-offer-roundtrip", offerRoundtrip, "batch_size=1")

    var requestIds: seq[uint64] = @[]
    let pipelinedStart = epochTime()
    for i in 0 ..< count:
      requestIds.add(session.sendCandidateOffer([toCandidate(uint64(2000 + i), req("pipelined"))]))
    for requestId in requestIds:
      for decision in session.receiveCandidateDecisions(requestId):
        var lease = decision.lease
        lease.release()
    let pipelinedMs = elapsedMillis(pipelinedStart)
    result.addMetric(
      "pipelined-lease-window throughput",
      "ops/sec",
      float(count) / (pipelinedMs / 1000.0),
      "inflight=" & $requestIds.len & "; max_inflight=" & $client.flow.maxInflightRequests
    )

    let batchSize = min(4, int(client.flow.maxCandidatesPerBatch))
    var batch: seq[LeaseCandidate] = @[]
    for i in 0 ..< batchSize:
      batch.add(toCandidate(uint64(3000 + i), req("batch")))
    let batchStart = epochTime()
    let batchDecisions = session.offerCandidates(batch)
    let batchMs = elapsedMillis(batchStart)
    if batchDecisions.len != batchSize:
      raise newException(ValueError, "candidate batch size mismatch")
    for decision in batchDecisions:
      var lease = decision.lease
      lease.release()
    result.addMetric(
      "candidate-decision-batch amortized",
      "ms",
      batchMs / float(batchSize),
      "batch_size=" & $batchSize
    )

    let telemetry = measureLatencies(count, proc () =
      let execution = session.runWithLease(req("telemetry-submit"), [binary, FixtureNull])
      if not execution.leaseFinishedSent or not execution.leaseReleased:
        raise newException(ValueError, "telemetry submit did not finish and release")
    )
    result.addLatencyMetrics("telemetry-submit", telemetry, "LeaseFinished=real; LeaseReleased=real")

    session.closeSession()
    client.close()
  finally:
    stopDaemon(daemon)
    if dirExists(socketDir):
      removeDir(socketDir)

proc main() =
  var suite = "process"
  var quick = false
  for arg in commandLineParams():
    case arg
    of "--suite=process": suite = "process"
    of "--suite=ipc": suite = "ipc"
    of "--quick": quick = true
    else:
      raise newException(ValueError, "unknown argument: " & arg)
  let metrics =
    if suite == "ipc":
      runIpcSuite(quick)
    else:
      runProcessSuite(quick)
  emitJson(metrics)

main()
