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
## THE LEASE CARRIES A STATS KEY, AND FOR A WHILE IT DID NOT — which made
## every figure this suite published a figure about a path no real client
## takes. `commandStatsId` is what a stats key travels in, and the daemon
## skips a large part of its completion work when it is empty; every shipped
## client sets it (`reprobuild`'s adapter sets it on every request), and this
## benchmark did not, because `resourceRequest`'s first parameter is the
## LABEL and the field has to be assigned separately. The suite therefore
## reported 0.0012 ms for a write path whose expensive half never ran. A
## measurement that cannot fail is not a measurement, so the keyed arm below
## is now the headline.
##
## BOTH ARMS ARE CARRIED, keyed and keyless, because the difference between
## them turned out to be the dominant term and a reader who sees only one of
## them cannot tell which of the two numbers applies to their client. The
## keyless pair is exactly what this suite used to report.
##
## THE ARMS ARE INTERLEAVED, NOT RUN IN SEQUENCE, and this is the M11
## lesson applied to a different quantity. A single before/after pair on a
## workstation somebody is using measures the machine's mood as much as the
## code: M11 watched the host-wide busy figure wander between 56% and 88%
## over twenty consecutive one-second readings, and single repetitions of a
## known load ranged from -1.52 to 1.69 of it. Two daemons are therefore
## alive at the same time and each round times all four executions —
## {capture, control} x {keyed, keyless} — in a ROTATING order, so the
## paired difference cancels drift on any timescale longer than a round and
## no arm is systematically first. The paired median is the headline; the
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
  BenchStatsKey = "m13-bench-stats-key"
    ## ONE KEY, REUSED, because that is what a build does: a stats key names
    ## a kind of work, not an occurrence of it, so a fresh key per round
    ## would measure a permanently cold aggregate nobody has.

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

# HOW THIS BINARY WAS COMPILED, decided by the compiler rather than reported
# by the caller. A published result carries it so a reader can tell whether
# two numbers are comparable at all: this repository's benchmarks were built
# `opt: none` for their entire history, while the shm arm they are weighed
# against is `-d:release`, and nothing on either result said so. A flag could
# be passed wrongly; `when defined` cannot.
const BuildMode* = when defined(release): "release" else: "debug"

proc emitJson(metrics: openArray[BenchMetric]) =
  stdout.write("[")
  for i, metric in metrics:
    if i > 0:
      stdout.write(",")
    stdout.write("{\"name\":\"" & jsonEscape(metric.name) & "\",")
    stdout.write("\"unit\":\"" & jsonEscape(metric.unit) & "\",")
    stdout.write("\"value\":" & formatFloat(metric.value, ffDecimal, 4) & ",")
    stdout.write("\"extra\":\"" &
      jsonEscape(metric.extra & "; build=" & BuildMode) & "\"}")
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

proc timeOneExecution(session: var RunQuotaSession; label: string;
                      statsKey: string): float =
  ## One whole execution, timed end to end. Nothing sleeps inside the
  ## window: a sleep would put a constant in both arms and shrink the
  ## RELATIVE difference the gate asks about without changing the absolute
  ## one, which is the classic way to make an overhead look small.
  let start = epochTime()
  var request = resourceRequest(label, milliCpu(100), bytes(1024 * 1024))
  # ASSIGNED, NOT PASSED. `resourceRequest`'s first parameter is the label;
  # the stats key is a separate field, and leaving it empty is what made
  # this benchmark measure the wrong path for the whole of M13's life.
  request.commandStatsId = statsKey
  var lease = session.requestLease(request)
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
  var keyedCapture: seq[float] = @[]
  var keyedControl: seq[float] = @[]
  var keyedPaired: seq[float] = @[]
  var keylessCapture: seq[float] = @[]
  var keylessControl: seq[float] = @[]
  var keylessPaired: seq[float] = @[]
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
      discard timeOneExecution(captureSession, "warmup", BenchStatsKey)
      discard timeOneExecution(captureSession, "warmup", "")
      discard timeOneExecution(controlSession, "warmup", BenchStatsKey)
      discard timeOneExecution(controlSession, "warmup", "")

    # THE FOUR ARMS, and each round runs all four so every difference below
    # is a paired one.
    const
      ArmCaptureKeyed = 0
      ArmCaptureKeyless = 1
      ArmControlKeyed = 2
      ArmControlKeyless = 3
      ArmCount = 4
    for i in 0 ..< rounds:
      # ORDER ROTATES WITHIN THE ROUND as well as the arms alternating
      # between rounds. Whichever execution runs first in a round pays for
      # whatever the scheduler did between rounds, and a fixed order would
      # hand that cost to the same arm every time.
      var round: array[ArmCount, float]
      for step in 0 ..< ArmCount:
        let arm = (i + step) mod ArmCount
        round[arm] =
          case arm
          of ArmCaptureKeyed:
            timeOneExecution(captureSession, "capture", BenchStatsKey)
          of ArmCaptureKeyless:
            timeOneExecution(captureSession, "capture", "")
          of ArmControlKeyed:
            timeOneExecution(controlSession, "control", BenchStatsKey)
          else:
            timeOneExecution(controlSession, "control", "")
      keyedCapture.add(round[ArmCaptureKeyed])
      keyedControl.add(round[ArmControlKeyed])
      keyedPaired.add(round[ArmCaptureKeyed] - round[ArmControlKeyed])
      keylessCapture.add(round[ArmCaptureKeyless])
      keylessControl.add(round[ArmControlKeyless])
      keylessPaired.add(round[ArmCaptureKeyless] - round[ArmControlKeyless])

    captureSession.closeSession()
    captureClient.close()
    controlSession.closeSession()
    controlClient.close()

    # THE CAPTURE ARM MUST ACTUALLY HAVE CAPTURED. A benchmark of a write
    # path that wrote nothing is a benchmark of nothing, and a store that
    # silently degraded would report a flattering figure.
    let storePath = captureState / "observations.sqlite3"
    # TWO ROWS PER ROUND: the capture arm runs a keyed and a keyless
    # execution, and both are recorded.
    let expectedRows = 2 * rounds
    for _ in 0 ..< 200:
      let store = openObservationStore(storePath)
      if store.captureEnabled:
        storeRows = store.readExecutions().len
        if storeRows >= expectedRows:
          break
      sleep(50)
    if storeRows < expectedRows:
      raise newException(ValueError,
        "capture arm recorded " & $storeRows & " of " & $expectedRows &
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

  let keyedMedian = median(keyedPaired)
  let keyedControlMedian = median(keyedControl)
  let keylessMedian = median(keylessPaired)
  let keylessControlMedian = median(keylessControl)
  let shape = "rounds=" & $rounds & "; warmup=" & $WarmupRounds &
    "; rows=" & $storeRows & "; interleaved=paired; arms=4"

  # THE HEADLINE IS THE KEYED PAIR, because every shipped client sets a
  # stats key. The keyless pair is reported beside it, unrenamed in
  # meaning but now explicitly labelled, so the two are never confused
  # again.
  result.addMetric(
    "observation write path added latency, stats key set (paired median)",
    "ms", keyedMedian, shape)
  result.addMetric(
    "observation write path added latency, stats key set (paired mean)",
    "ms", mean(keyedPaired), shape)
  result.addMetric(
    "observation write path added latency, stats key set (pooled median)",
    "ms", median(keyedCapture) - keyedControlMedian, shape)
  result.addMetric(
    "observation write path added latency, stats key set (paired p95)",
    "ms", percentile(keyedPaired, 0.95), shape)
  result.addMetric(
    "observation write path added latency, NO stats key (paired median)",
    "ms", keylessMedian, shape)
  result.addMetric(
    "observation write path added latency, NO stats key (paired p95)",
    "ms", percentile(keylessPaired, 0.95), shape)
  result.addMetric("execution latency, capture ON, stats key set p50", "ms",
    median(keyedCapture), shape)
  result.addMetric("execution latency, capture ON, stats key set p95", "ms",
    percentile(keyedCapture, 0.95), shape)
  result.addMetric("execution latency, capture ON, NO stats key p50", "ms",
    median(keylessCapture), shape)
  result.addMetric("execution latency, capture ON, NO stats key p95", "ms",
    percentile(keylessCapture, 0.95), shape)
  result.addMetric(
    "execution latency, capture OFF (control), stats key set p50", "ms",
    keyedControlMedian, shape)
  result.addMetric(
    "execution latency, capture OFF (control), stats key set p95", "ms",
    percentile(keyedControl, 0.95), shape)
  result.addMetric(
    "execution latency, capture OFF (control), NO stats key p50", "ms",
    keylessControlMedian, shape)
  result.addMetric(
    "observation write path added latency, stats key set (relative)",
    "percent",
    (if keyedControlMedian > 0.0: 100.0 * keyedMedian / keyedControlMedian
     else: 0.0),
    shape)
  result.addMetric(
    "observation write path added latency, NO stats key (relative)",
    "percent",
    (if keylessControlMedian > 0.0:
       100.0 * keylessMedian / keylessControlMedian
     else: 0.0),
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
