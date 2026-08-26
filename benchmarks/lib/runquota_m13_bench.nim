## M13 overhead benchmark: the per-execution latency the SOCKET write path
## adds, measured against a capture-disabled control.
##
## WHAT THE NUMBER IS FOR, AND WHAT IT IS NOT FOR. M13 is the FALLBACK
## path; the ring (M22) is the fast one, and the default-on decision moved
## to M22 with it. So this figure does not get a vote on whether capture is
## on by default — it exists because the fallback's cost has to be known.
## An unfavourable number here is a finding, not an argument.
##
## THE CONTROL IS ONE FLAG. Both arms run the same daemon binary, the same
## client library, the same lease lifecycle and the same message sequence,
## including the in-flight `LeaseObservation` report. The only difference
## is `--no-write-stats` on the control daemon, which turns off the store,
## the writer thread, the ambient sampler and the self-report intake. What
## is measured is therefore the daemon-side cost of capture and nothing
## else — not the cost of a different client, and not the cost of a
## different workload.
##
## THE ARMS ARE INTERLEAVED, NOT RUN IN SEQUENCE, and this is the M11
## lesson applied to a different quantity. A single before/after pair on a
## workstation somebody is using measures the machine's mood as much as the
## code: M11 watched the host-wide busy figure wander between 56% and 88%
## over twenty consecutive one-second readings, and single repetitions of a
## known load ranged from -1.52 to 1.69 of it. Two daemons are therefore
## alive at the same time and each round times ONE execution against each,
## in alternating order, so the paired difference cancels drift on any
## timescale longer than a round. The paired median is the headline; the
## pooled difference is reported beside it as a cross-check, exactly as
## M11 reports both.
##
## WHAT IS TIMED. One whole execution as a supervising client drives it:
## RequestLease, LeaseStarting, LeaseRunning, LeaseObservation,
## LeaseFinished, ReleaseLease. Five of those are round trips and the sixth
## is one-way, so every scrap of daemon-side work lands inside the measured
## window. The session is registered once per arm and outside the window,
## because a `runs` row is per session and per-execution cost is what the
## gate asks for.

import std/[algorithm, math, os, osproc, strutils, times]

from runquota_ipc import endpointDirectoryPermissions
import runquota_client
import runquota_core
import runquota_observation_store
import runquota_protocol

const
  DefaultRounds = 400
  QuickRounds = 60
  WarmupRounds = 20
    ## Discarded. The first executions of a run pay for lazily created
    ## threads, a cold SQLite file and a page cache that has not seen the
    ## store yet, and none of that is per-execution cost.

type
  BenchMetric = object
    name: string
    unit: string
    value: float
    extra: string

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
    stdout.write("\"value\":" & formatFloat(metric.value, ffDecimal, 4) & ",")
    stdout.write("\"extra\":\"" & jsonEscape(metric.extra) & "\"}")
  stdout.write("]\n")

proc percentile(values: seq[float]; pct: float): float =
  if values.len == 0:
    return 0.0
  var sorted = values
  sorted.sort()
  let index = min(sorted.high, max(0, int((pct * float(sorted.len - 1)).round)))
  sorted[index]

proc median(values: seq[float]): float =
  percentile(values, 0.5)

proc mean(values: seq[float]): float =
  if values.len == 0:
    return 0.0
  var total = 0.0
  for value in values:
    total += value
  total / float(values.len)

proc daemonPath(): string =
  getCurrentDir() / "build" / "bin" / "runquotad"

proc prepareDir(path: string) =
  if dirExists(path):
    removeDir(path)
  createDir(path)
  # THE MODE THE SHIPPED POLICY REQUIRES, derived rather than written as a
  # literal: 0750 where a `runquota` group exists, 0700 where it does not.
  setFilePermissions(path, endpointDirectoryPermissions())

proc prepareStateDir(path: string) =
  if dirExists(path):
    removeDir(path)
  createDir(path)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc waitForDaemon(socketPath: string) =
  putEnv("RUNQUOTA_SOCKET", socketPath)
  var lastError = ""
  for _ in 0 ..< 200:
    try:
      var probe = connectDefault()
      probe.close()
      return
    except CatchableError as error:
      lastError = error.msg
      sleep(25)
  raise newException(OSError, "runquotad did not become ready: " & lastError)

proc startArmDaemon(socketPath, identityFile: string;
                    captureOn: bool): Process =
  if not fileExists(daemonPath()):
    raise newException(OSError,
      "missing " & daemonPath() & "; run `just build` first")
  var args = @[
    "--socket", socketPath,
    "--host-identity-file", identityFile,
    "--cpu-milli", "64000",
    "--memory-bytes", $(64'u64 * 1024'u64 * 1024'u64 * 1024'u64)
  ]
  if not captureOn:
    args.add("--no-write-stats")
  result = startProcess(daemonPath(), args = args,
    options = {poStdErrToStdOut})
  waitForDaemon(socketPath)

proc stopDaemon(daemon: var Process) =
  if daemon.running:
    daemon.terminate()
    discard daemon.waitForExit(5000)
  if daemon.running:
    daemon.kill()
    discard daemon.waitForExit(5000)
  daemon.close()

proc timeOneExecution(session: var RunQuotaSession; label: string): float =
  ## One whole execution, timed end to end. Nothing sleeps inside the
  ## window: a sleep would put a constant in both arms and shrink the
  ## RELATIVE difference the gate asks about without changing the absolute
  ## one, which is the classic way to make an overhead look small.
  let start = epochTime()
  var lease = session.requestLease(resourceRequest(label, milliCpu(100),
    bytes(1024 * 1024)))
  if not lease.active:
    raise newException(ValueError, "benchmark lease was not granted")
  lease.markStarting()
  lease.markRunning(childProcessId = uint64(getCurrentProcessId()))
  lease.reportObservation(12_500'u32, 1_500_000_000'u64,
    uint64(unixMillisNow()))
  lease.finish(outcome = succeeded(),
    peakMemoryBytes = 1_048_576'u64, processCount = 1'u32)
  lease.release()
  (epochTime() - start) * 1000.0

proc runOverheadSuite(quick: bool): seq[BenchMetric] =
  let rounds = if quick: QuickRounds else: DefaultRounds
  let root = getTempDir() / ("rq-m13-bench-" & $getCurrentProcessId())
  let captureSocketDir = root / "on"
  let controlSocketDir = root / "off"
  let captureState = root / "on-state"
  let controlState = root / "off-state"
  prepareDir(root)
  setFilePermissions(root, {fpUserRead, fpUserWrite, fpUserExec})
  prepareDir(captureSocketDir)
  prepareDir(controlSocketDir)
  prepareStateDir(captureState)
  prepareStateDir(controlState)
  let captureSocket = captureSocketDir / "d.sock"
  let controlSocket = controlSocketDir / "d.sock"

  var captureDaemon = startArmDaemon(captureSocket,
    captureState / "host-id", captureOn = true)
  var controlDaemon: Process = nil
  var captureLatencies: seq[float] = @[]
  var controlLatencies: seq[float] = @[]
  var paired: seq[float] = @[]
  var storeRows = 0
  try:
    controlDaemon = startArmDaemon(controlSocket,
      controlState / "host-id", captureOn = false)

    putEnv("RUNQUOTA_SOCKET", captureSocket)
    var captureClient = connectDefault()
    var captureSession = captureClient.registerSession("m13-bench-capture",
      "0.1.0")

    putEnv("RUNQUOTA_SOCKET", controlSocket)
    var controlClient = connectDefault()
    var controlSession = controlClient.registerSession("m13-bench-control",
      "0.1.0")

    for i in 0 ..< WarmupRounds:
      discard timeOneExecution(captureSession, "warmup")
      discard timeOneExecution(controlSession, "warmup")

    for i in 0 ..< rounds:
      # ORDER ALTERNATES WITHIN THE ROUND as well as the arms alternating
      # between rounds. Whichever execution runs first in a round pays for
      # whatever the scheduler did between rounds, and a fixed order would
      # hand that cost to the same arm every time.
      if (i and 1) == 0:
        let onMs = timeOneExecution(captureSession, "capture")
        let offMs = timeOneExecution(controlSession, "control")
        captureLatencies.add(onMs)
        controlLatencies.add(offMs)
        paired.add(onMs - offMs)
      else:
        let offMs = timeOneExecution(controlSession, "control")
        let onMs = timeOneExecution(captureSession, "capture")
        captureLatencies.add(onMs)
        controlLatencies.add(offMs)
        paired.add(onMs - offMs)

    captureSession.closeSession()
    captureClient.close()
    controlSession.closeSession()
    controlClient.close()

    # THE CAPTURE ARM MUST ACTUALLY HAVE CAPTURED. A benchmark of a write
    # path that wrote nothing is a benchmark of nothing, and a store that
    # silently degraded would report a flattering figure.
    let storePath = captureState / "observations.sqlite3"
    for _ in 0 ..< 200:
      let store = openObservationStore(storePath)
      if store.captureEnabled:
        storeRows = store.readExecutions().len
        if storeRows >= rounds:
          break
      sleep(50)
    if storeRows < rounds:
      raise newException(ValueError,
        "capture arm recorded " & $storeRows & " of " & $rounds &
          " executions; the overhead figure would not be an overhead figure")
    if fileExists(controlState / "observations.sqlite3"):
      raise newException(ValueError,
        "the control arm wrote a store; it is not a control")
  finally:
    stopDaemon(captureDaemon)
    if controlDaemon != nil:
      stopDaemon(controlDaemon)
    if dirExists(root):
      removeDir(root)

  let pairedMedian = median(paired)
  let pooledDifference = median(captureLatencies) - median(controlLatencies)
  let controlMedian = median(controlLatencies)
  let shape = "rounds=" & $rounds & "; warmup=" & $WarmupRounds &
    "; rows=" & $storeRows & "; interleaved=paired"

  result.addMetric("observation write path added latency (paired median)",
    "ms", pairedMedian, shape)
  result.addMetric("observation write path added latency (paired mean)",
    "ms", mean(paired), shape)
  result.addMetric("observation write path added latency (pooled median)",
    "ms", pooledDifference, shape)
  result.addMetric("observation write path added latency (paired p95)",
    "ms", percentile(paired, 0.95), shape)
  result.addMetric("execution latency, capture ON p50", "ms",
    median(captureLatencies), shape)
  result.addMetric("execution latency, capture ON p95", "ms",
    percentile(captureLatencies, 0.95), shape)
  result.addMetric("execution latency, capture OFF (control) p50", "ms",
    controlMedian, shape)
  result.addMetric("execution latency, capture OFF (control) p95", "ms",
    percentile(controlLatencies, 0.95), shape)
  result.addMetric("observation write path added latency (relative)",
    "percent",
    (if controlMedian > 0.0: 100.0 * pairedMedian / controlMedian else: 0.0),
    shape)

proc main() =
  var quick = false
  for arg in commandLineParams():
    case arg
    of "--quick": quick = true
    else:
      raise newException(ValueError, "unknown argument: " & arg)
  emitJson(runOverheadSuite(quick))

main()
