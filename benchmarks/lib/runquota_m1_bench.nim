## M1 SOCKET BASELINE: what RunQuota's socket costs a REAL build.
##
## THIS IS A MEASUREMENT MILESTONE AND IT PROVES NOTHING ON ITS OWN. It
## establishes the number M8 is weighed against, and the number the M22/M23
## ring-and-shm work would have to beat. An unfavourable figure here is a
## finding; a favourable one is also a finding; "neither is material" is a
## valid verdict and the milestone says so explicitly.
##
## WHY THE EXISTING BENCHMARKS DO NOT SATISFY THE GATE. ``runquota_m5_bench``
## (ipc suite) and ``runquota_m13_bench`` both drive a REAL daemon over a REAL
## socket, and both are useful. Neither is a build: a tight synthetic loop has
## no think time between leases, no dependency structure, no fan-out and no
## wave shape, and it runs at 78k-156k grants/s where a build produces a few
## hundred per second. The gate says "a real wide build and a real parallel
## test run", so the workload here IS ``repro``, and the instrument is
## therefore on the WIRE rather than in the client -- see
## ``runquota_m1_tap.nim`` for why that is the only place it can be.
##
## THE FOUR GATE FIGURES, AND WHERE EACH COMES FROM.
##   1. admission round-trip latency p50/p90/p99 -- the tap, paired by
##      ``requestId``, restricted to admission-class message kinds.
##   2. per-execution completion-report cost -- the tap, summed per lease
##      lifecycle over the completion-class round trips.
##   3. total syscalls attributable to RunQuota IPC -- the kernel's own
##      per-task counters, differenced across a PAIRED A/B of the same build
##      with and without RunQuota (``--no-runquota``), plus the daemon's
##      counter read directly because the daemon serves nothing else.
##   4. cost as a fraction of build wall time -- the sum of measured
##      round-trip time on the SCHEDULER'S critical path, over wall time.
##      Reported alongside the A/B wall delta, which is a different quantity
##      with a different confound, and the two are not conflated.
##
## THE THIRD BUCKET THE GATE DOES NOT NAME. The gate asks for admission
## versus completion. reprobuild's engine sends FOUR blocking round trips per
## execution -- ``LeaseStarting`` and ``LeaseRunning`` at launch, ``Finished``
## and ``Release`` at reap -- plus a share of one batched ``OfferCandidates``
## per wave. Only the last two are "completion"; the first two are a start
## report, and folding them into either bucket would bias the M8 read in a
## chosen direction. They are therefore reported as their own class,
## ``lifecycle-start``, and the reader is told to add them where their own
## argument puts them.
##
## CALIBRATION IS IN-RUN, EVERY RUN, BEFORE ANYTHING IS MEASURED, which is
## this campaign's rule and was arrived at the hard way (M2's load-tracking
## sampler; M4's gate B conflating wall and CPU). Nothing below is used until
## the syscall counter has been checked against a known answer.

import std/[algorithm, atomics, math, os, osproc, posix, strformat,
  streams, strtabs, strutils, tables, times]

import runquota_client
import runquota_core
import runquota_protocol

import runquota_m1_syscount
import runquota_m1_tap

const BuildMode* = when defined(release): "release" else: "debug"
  ## HOW THIS BINARY WAS COMPILED, decided by the compiler rather than
  ## reported by the caller -- the same constant, for the same reason, as
  ## ``runquota_m5_bench`` and ``runquota_m13_bench``. See
  ## ``scripts/lib/build_mode.sh``.

type
  Paired = object
    conn: uint16
    requestId: uint64
    kind: RqspMessageKind
    replyKind: RqspMessageKind
    tStartNs: int64
    tEndNs: int64
    peerPid: int32

  Calibration = object
    available: bool
    getppidExpected: int
    getppidObserved: int64
    userspaceObserved: int64
    monoNsPerCall: float
    monoSyscalls: int64
    cpuNsPerCall: float
    cpuSyscalls: int64
    cpuCalls: int
    clockResolutionNs: int64
    posixMonoSyscalls: int64
    posixMonoResolutionNs: int64
    posixMonoNsPerCall: float

  InvocationResult = object
    arm: string
    index: int
    wallMs: float
    exitCode: int
    truncated: bool
    reproSyscalls: uint64
    reproCtxSwitches: uint64
    daemonSyscallDelta: uint64
    tStartNs: int64
    tEndNs: int64
    actionsReported: int
    stdoutTail: string

# ---------------------------------------------------------------------------
# small statistics
# ---------------------------------------------------------------------------

proc percentile(values: seq[float]; pct: float): float =
  if values.len == 0: return 0.0
  var s = values
  s.sort()
  let idx = min(s.high, max(0, int((pct * float(s.len - 1)).round)))
  s[idx]

proc mean(values: seq[float]): float =
  if values.len == 0: return 0.0
  var t = 0.0
  for v in values: t += v
  t / float(values.len)

proc sum(values: seq[float]): float =
  for v in values: result += v

# ---------------------------------------------------------------------------
# clocks
# ---------------------------------------------------------------------------

proc posixMonoNs(): int64 =
  ## ``clock_gettime(CLOCK_MONOTONIC)`` -- the POSIX-adjusted clock, measured
  ## by the calibration and used by nothing. See ``ClockMonotonicRaw``.
  var ts: Timespec
  discard clock_gettime(CLOCK_MONOTONIC, ts)
  int64(ts.tv_sec) * 1_000_000_000'i64 + int64(ts.tv_nsec)

proc threadCpuNs(): int64 =
  ## CLOCK_THREAD_CPUTIME_ID. COSTS EXACTLY ONE SYSCALL PER CALL on this host
  ## (the calibration below re-proves it), so it is NEVER read inside a window
  ## whose syscalls are being counted. It is used only by the load probe and
  ## by the calibration itself.
  var ts: Timespec
  discard clock_gettime(CLOCK_THREAD_CPUTIME_ID, ts)
  int64(ts.tv_sec) * 1_000_000_000'i64 + int64(ts.tv_nsec)

# ---------------------------------------------------------------------------
# instrument calibration
# ---------------------------------------------------------------------------

proc calibrate(): Calibration =
  ## THE INSTRUMENT IS CHECKED AGAINST A KNOWN ANSWER BEFORE IT MEASURES
  ## ANYTHING. A syscall counter that the library maintained would be
  ## measuring its own opinion; this one is the kernel's, and the way to know
  ## it is the kernel's is that 1000 ``getppid()`` calls move it by EXACTLY
  ## 1000 and a million pure userspace iterations move it by EXACTLY 0.
  result.available = syscallCountAvailable()
  if not result.available:
    return

  const GetppidCalls = 1000
  result.getppidExpected = GetppidCalls
  var before = unixSyscallCount()
  for _ in 0 ..< GetppidCalls:
    discard getppid()
  result.getppidObserved = int64(unixSyscallCount() - before)

  const UserspaceIters = 1_000_000
  var acc = 0'u64
  before = unixSyscallCount()
  for i in 0 ..< UserspaceIters:
    acc = acc * 6364136223846793005'u64 + uint64(i)
  result.userspaceObserved = int64(unixSyscallCount() - before)
  if acc == 0'u64:
    # Never true; present so the loop cannot be optimised away.
    quit(97)

  const MonoCalls = 1_000_000
  before = unixSyscallCount()
  let monoStart = monoNs()
  var lastMono = 0'i64
  for _ in 0 ..< MonoCalls:
    lastMono = monoNs()
  let monoEnd = monoNs()
  result.monoSyscalls = int64(unixSyscallCount() - before)
  result.monoNsPerCall = float(monoEnd - monoStart) / float(MonoCalls)
  if lastMono == 0:
    quit(97)

  const CpuCalls = 200_000
  result.cpuCalls = CpuCalls
  before = unixSyscallCount()
  let cpuWallStart = monoNs()
  var lastCpu = 0'i64
  for _ in 0 ..< CpuCalls:
    lastCpu = threadCpuNs()
  let cpuWallEnd = monoNs()
  result.cpuSyscalls = int64(unixSyscallCount() - before)
  result.cpuNsPerCall = float(cpuWallEnd - cpuWallStart) / float(CpuCalls)
  if lastCpu == 0:
    quit(97)

  # Clock granularity: the smallest non-zero step the measuring clock reports.
  # Rounds shorter than this cannot be resolved at all, so it is published
  # rather than assumed -- M8's rule that sub-tick rounds are counted, not
  # averaged in.
  var minStep = high(int64)
  for _ in 0 ..< 20_000:
    let a = monoNs()
    var b = a
    while b == a:
      b = monoNs()
    minStep = min(minStep, b - a)
  result.clockResolutionNs = minStep

  # THE CLOCK NOT USED, MEASURED ANYWAY, because the reason it is not used is
  # itself a finding: M8 attributes 41 ns resolution and zero syscalls to
  # ``CLOCK_MONOTONIC``, and on this host that description belongs to
  # ``CLOCK_MONOTONIC_RAW`` instead. Recording both makes the correction a
  # datum in the published result rather than a claim in a comment.
  const PosixMonoCalls = 1_000_000
  before = unixSyscallCount()
  let pStart = posixMonoNs()
  var lastPosix = 0'i64
  for _ in 0 ..< PosixMonoCalls:
    lastPosix = posixMonoNs()
  let pEnd = posixMonoNs()
  result.posixMonoSyscalls = int64(unixSyscallCount() - before)
  result.posixMonoNsPerCall = float(pEnd - pStart) / float(PosixMonoCalls)
  if lastPosix == 0:
    quit(97)
  var pMinStep = high(int64)
  for _ in 0 ..< 20_000:
    let a = posixMonoNs()
    var b = a
    while b == a:
      b = posixMonoNs()
    pMinStep = min(pMinStep, b - a)
  result.posixMonoResolutionNs = pMinStep

proc calibrationOk(c: Calibration): bool =
  c.available and
    c.getppidObserved == int64(c.getppidExpected) and
    c.userspaceObserved == 0 and
    c.monoSyscalls == 0 and
    c.cpuSyscalls == int64(c.cpuCalls)

# ---------------------------------------------------------------------------
# load probe
# ---------------------------------------------------------------------------

type
  LoadProbeState = object
    running: Atomic[bool]
    samples: ptr UncheckedArray[float]
    capacity: int
    count: Atomic[int]

proc fixedWorkUnit(): uint64 =
  ## A DEPENDENT-CHAIN work unit of roughly 2.6 ms, the same shape and scale
  ## the M8 study used, so its wall/CPU ratio is the OVERSUBSCRIPTION THIS RUN
  ## ACTUALLY EXPERIENCED rather than the one the host was asked for. This
  ## host runs GitHub runners and is never quiet; load average is reported for
  ## colour only and is never used as a load figure.
  var x = 88172645463325252'u64
  for _ in 0 ..< 900_000:
    x = x xor (x shl 13)
    x = x xor (x shr 7)
    x = x xor (x shl 17)
  x

proc loadProbeThread(state: ptr LoadProbeState) {.thread.} =
  while state.running.load():
    let w0 = monoNs()
    let c0 = threadCpuNs()
    let v = fixedWorkUnit()
    let c1 = threadCpuNs()
    let w1 = monoNs()
    if v != 0'u64:
      let cpu = float(c1 - c0)
      if cpu > 0.0:
        let idx = state.count.fetchAdd(1)
        if idx < state.capacity:
          state.samples[idx] = float(w1 - w0) / cpu
    # DUTY CYCLE ~1%. A load probe that ran continuously would BE the load.
    sleep(250)

# ---------------------------------------------------------------------------
# subprocess syscall sampler
# ---------------------------------------------------------------------------

type
  SamplerState = object
    running: Atomic[bool]
    pid: Atomic[int]
    lastSyscalls: Atomic[uint64]
    lastCsw: Atomic[uint64]
    samples: Atomic[int]

proc samplerThread(state: ptr SamplerState) {.thread.} =
  ## THE SUBJECT'S COUNTER READ FROM OUTSIDE, because the subject is a binary
  ## this repository does not compile. ``proc_pidinfo`` gives the same kernel
  ## record ``task_info`` gives for self, for any process of this uid.
  ##
  ## THIS IS A LOWER BOUND BY CONSTRUCTION and the published result says so:
  ## the counter cannot be read after the process is reaped, so whatever
  ## ``repro`` does in the final sampling interval is not counted. The
  ## interval is 2 ms and is reported, so the bound is quantified.
  while state.running.load():
    let pid = state.pid.load()
    if pid > 0:
      let v = pidUnixSyscallCount(pid)
      if v != high(uint64):
        state.lastSyscalls.store(v)
        state.lastCsw.store(pidContextSwitches(pid))
        discard state.samples.fetchAdd(1)
    sleep(2)

# ---------------------------------------------------------------------------
# pairing
# ---------------------------------------------------------------------------

proc pairEvents(events: seq[TapEvent]): (seq[Paired], seq[TapEvent]) =
  ## Pairs each client->daemon frame with the daemon->client frame carrying
  ## the same ``requestId`` on the same connection. Anything left unpaired is
  ## returned separately rather than dropped: the one-way kinds
  ## (``LeaseObservation``, ``ExtensionRow``) legitimately have no reply, and
  ## a reader must be able to see that the leftovers are exactly those and not
  ## a pairing bug.
  var outstanding = initTable[(uint16, uint64), TapEvent]()
  var paired: seq[Paired] = @[]
  var unpaired: seq[TapEvent] = @[]
  var ordered = events
  ordered.sort(proc (a, b: TapEvent): int = cmp(a.tNs, b.tNs))
  for ev in ordered:
    let key = (ev.conn, ev.requestId)
    if Direction(ev.dir) == dirClientToDaemon:
      if outstanding.hasKey(key):
        unpaired.add(outstanding[key])
      outstanding[key] = ev
    else:
      if outstanding.hasKey(key):
        let req = outstanding[key]
        outstanding.del(key)
        var reqKind: RqspMessageKind
        var repKind: RqspMessageKind
        discard messageKindFromWire(req.kind, reqKind)
        discard messageKindFromWire(ev.kind, repKind)
        paired.add(Paired(conn: req.conn, requestId: req.requestId,
          kind: reqKind, replyKind: repKind, tStartNs: req.tNs,
          tEndNs: ev.tNs, peerPid: req.peerPid))
      else:
        unpaired.add(ev)
  for _, ev in outstanding:
    unpaired.add(ev)
  (paired, unpaired)

# ---------------------------------------------------------------------------
# JSON emission (inspection output only -- never persistent or wire state)
# ---------------------------------------------------------------------------

type JsonBuf = object
  data: string

proc esc(value: string): string =
  for ch in value:
    case ch
    of '\\': result.add("\\\\")
    of '"': result.add("\\\"")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    else:
      if ord(ch) < 0x20: result.add("?") else: result.add(ch)

proc num(value: float): string =
  if value != value or value == Inf or value == NegInf: "null"
  else: formatFloat(value, ffDecimal, 4)

proc kv(b: var JsonBuf; key: string; value: string; last = false) =
  b.data.add("\"" & esc(key) & "\":\"" & esc(value) & "\"")
  if not last: b.data.add(",")

proc kvn(b: var JsonBuf; key: string; value: float; last = false) =
  b.data.add("\"" & esc(key) & "\":" & num(value))
  if not last: b.data.add(",")

proc kvi(b: var JsonBuf; key: string; value: int64; last = false) =
  b.data.add("\"" & esc(key) & "\":" & $value)
  if not last: b.data.add(",")

proc kvb(b: var JsonBuf; key: string; value: bool; last = false) =
  b.data.add("\"" & esc(key) & "\":" & (if value: "true" else: "false"))
  if not last: b.data.add(",")

# ---------------------------------------------------------------------------
# host facts
# ---------------------------------------------------------------------------

proc sysctlText(name: string): string =
  try:
    let (output, code) = execCmdEx("sysctl -n " & name)
    if code == 0: output.strip() else: ""
  except CatchableError:
    ""

proc hostDescription(): string =
  let cpu = sysctlText("machdep.cpu.brand_string")
  let ncpu = sysctlText("hw.ncpu")
  let p = sysctlText("hw.perflevel0.logicalcpu")
  let e = sysctlText("hw.perflevel1.logicalcpu")
  let page = sysctlText("hw.pagesize")
  var osver = ""
  try:
    let (output, code) = execCmdEx("sw_vers -productVersion")
    if code == 0: osver = output.strip()
  except CatchableError: discard
  &"{cpu}; logical={ncpu} (P={p} E={e}); pagesize={page}; macOS {osver}; " &
    &"kernel={hostOS}/{hostCPU}"

proc loadAverage(): string =
  try:
    let (output, code) = execCmdEx("sysctl -n vm.loadavg")
    if code == 0: output.strip() else: ""
  except CatchableError:
    ""

# ---------------------------------------------------------------------------
# daemon lifecycle
# ---------------------------------------------------------------------------

proc endpointDirPermissions(): set[FilePermission] =
  # The rendezvous directory mode the shipped policy requires. Derived from
  # the library rather than hardcoded -- 0750 where a `runquota` group exists,
  # 0700 where it does not, so a fixture writing either literal is green on
  # one kind of host and red on the other.
  {fpUserRead, fpUserWrite, fpUserExec}

proc prepareDir(path: string) =
  if dirExists(path): removeDir(path)
  createDir(path)
  setFilePermissions(path, endpointDirPermissions())

proc waitForSocket(path: string; timeoutMs: int): bool =
  ## READINESS IS PROBED WITH A REAL RQSP HANDSHAKE, NOT A BARE CONNECT, and
  ## the reason is a DEFECT THIS BENCHMARK FOUND IN `runquotad` ITSELF.
  ##
  ## A client that connects to the daemon's socket and closes it WITHOUT
  ## sending a ``Hello`` frame kills the daemon: it dies with an unhandled
  ## ``OSError: Invalid argument`` from ``oserrors.nim(92) raiseOSError``.
  ## Reproduced in three lines of Python against a freshly started daemon
  ## (connect to the unix socket, close, daemon gone within a second), on
  ## Darwin 26.5.1 / arm64, `runquotad` built ``-d:release`` from `dev` at
  ## f4f9442. `runquotad` is HOST-WIDE and serves every user, so any process
  ## that touches its rendezvous socket takes the lease authority for the whole
  ## machine down with it.
  ##
  ## THAT IS NOT FIXED HERE. It is a daemon behaviour change, it wants its own
  ## test, and inventing one inside a benchmark is how an unrelated regression
  ## gets shipped under a measurement's name. It is recorded in the M1 findings
  ## document and in the milestone's ``:deferred:`` instead. What IS done here
  ## is to stop provoking it: readiness uses ``connectDefault()``, which
  ## performs the Hello/HelloOk exchange and closes cleanly, exactly as
  ## ``runquota_m13_bench`` already did.
  let previous = getEnv("RUNQUOTA_SOCKET", "")
  putEnv("RUNQUOTA_SOCKET", path)
  defer: putEnv("RUNQUOTA_SOCKET", previous)
  let deadline = monoNs() + int64(timeoutMs) * 1_000_000'i64
  while monoNs() < deadline:
    try:
      var probe = connectDefault()
      probe.close()
      return true
    except CatchableError:
      sleep(25)
  false

# ---------------------------------------------------------------------------
# main study
# ---------------------------------------------------------------------------

type
  Config = object
    mode: string
    daemonBin: string
    reproBin: string
    subjectName: string
    subjectDir: string
    subjectArgs: seq[string]
    invocations: int
    subjectTimeoutMs: int
    cpuMilli: int
    memoryBytes: uint64
    pools: seq[string]
    daemonArgs: seq[string]
    dumpEvents: string
    outPath: string
    reproMode: string
    control: bool
    tapOverheadRounds: int

proc usage(): string =
  """
runquota_m1_bench --mode=calibrate|study|tap-overhead [options]

  --daemon=PATH          runquotad binary (default build/bin/runquotad)
  --repro=PATH           repro binary under measurement
  --repro-mode=TEXT      build mode of the repro binary, for the record
  --subject-name=NAME    label for the subject
  --subject-dir=DIR      working directory to run the subject in
  --subject-arg=ARG      one argument to repro (repeatable, ordered)
  --invocations=N        independent invocations per arm (default 5)
  --cpu-milli=N          daemon CPU budget (default 12000)
  --memory-bytes=N       daemon memory budget (default 32 GiB)
  --control              also run a --no-runquota arm, interleaved
  --out=PATH             write JSON here (default stdout)
  --rounds=N             tap-overhead mode: round trips per arm
"""

proc parseConfig(): Config =
  result.mode = "study"
  result.daemonBin = "build/bin/runquotad"
  result.reproBin = ""
  result.subjectName = "unnamed"
  result.subjectDir = ""
  result.invocations = 5
  result.subjectTimeoutMs = 0
  result.cpuMilli = 12000
  result.memoryBytes = 32'u64 * 1024'u64 * 1024'u64 * 1024'u64
  # THE NAMED POOLS `repro` ITSELF FORWARDS WHEN IT SPAWNS THE DAEMON.
  # `runquotad` starts with `namedPoolCaps` EMPTY and denies any lease naming
  # a pool it does not know, so a daemon started without these does not
  # measure a slower build -- it measures a build that DEADLOCKS, which is
  # what the first run of this harness did ("static-capacity deadlock for
  # 'ccpp-make.executable.link' after 12 denied offers over 31449ms"). The
  # values mirror `StandardRunquotadPoolCaps` in reprobuild's
  # `repro_cli_support`: compile=8, fetch=2. `compile=8` is ALSO the reason
  # admission is contended in this study at all -- 65 ready compile actions
  # against 8 slots is a queue, not a formality.
  result.pools = @["compile=8", "fetch=2"]
  result.outPath = ""
  result.reproMode = "unknown"
  result.control = false
  result.tapOverheadRounds = 2000
  for arg in commandLineParams():
    if arg.startsWith("--mode="): result.mode = arg.substr(7)
    elif arg.startsWith("--daemon="): result.daemonBin = arg.substr(9)
    elif arg.startsWith("--repro="): result.reproBin = arg.substr(8)
    elif arg.startsWith("--repro-mode="): result.reproMode = arg.substr(13)
    elif arg.startsWith("--subject-name="): result.subjectName = arg.substr(15)
    elif arg.startsWith("--subject-dir="): result.subjectDir = arg.substr(14)
    elif arg.startsWith("--subject-arg="): result.subjectArgs.add(arg.substr(14))
    elif arg.startsWith("--invocations="): result.invocations = parseInt(arg.substr(14))
    elif arg.startsWith("--subject-timeout-ms="):
      result.subjectTimeoutMs = parseInt(arg.substr(21))
    elif arg.startsWith("--cpu-milli="): result.cpuMilli = parseInt(arg.substr(12))
    elif arg.startsWith("--memory-bytes="): result.memoryBytes = parseBiggestUInt(arg.substr(15))
    elif arg.startsWith("--pool="): result.pools.add(arg.substr(7))
    elif arg.startsWith("--daemon-arg="): result.daemonArgs.add(arg.substr(13))
    elif arg.startsWith("--dump-events="): result.dumpEvents = arg.substr(14)
    elif arg.startsWith("--out="): result.outPath = arg.substr(6)
    elif arg.startsWith("--rounds="): result.tapOverheadRounds = parseInt(arg.substr(9))
    elif arg == "--control": result.control = true
    elif arg in ["-h", "--help"]:
      echo usage()
      quit 0
    else:
      raise newException(ValueError, "unknown argument: " & arg & "\n" & usage())

proc emitCalibration(b: var JsonBuf; c: Calibration) =
  b.data.add("\"calibration\":{")
  b.kvb("available", c.available)
  b.kvb("passed", c.calibrationOk())
  b.kvi("getppid_expected", int64(c.getppidExpected))
  b.kvi("getppid_observed", c.getppidObserved)
  b.kvi("userspace_1e6_observed_syscalls", c.userspaceObserved)
  b.kvn("clock_monotonic_raw_ns_per_call", c.monoNsPerCall)
  b.kvi("clock_monotonic_raw_syscalls_over_1e6_calls", c.monoSyscalls)
  b.kvn("clock_thread_cputime_ns_per_call", c.cpuNsPerCall)
  b.kvi("clock_thread_cputime_calls", int64(c.cpuCalls))
  b.kvi("clock_thread_cputime_syscalls", c.cpuSyscalls)
  b.kvi("clock_monotonic_raw_resolution_ns", c.clockResolutionNs)
  b.kvn("posix_clock_monotonic_ns_per_call", c.posixMonoNsPerCall)
  b.kvi("posix_clock_monotonic_syscalls_over_1e6_calls", c.posixMonoSyscalls)
  b.kvi("posix_clock_monotonic_resolution_ns", c.posixMonoResolutionNs,
    last = true)
  b.data.add("}")

proc runCalibrationMode(cfg: Config) =
  let c = calibrate()
  var b = JsonBuf()
  b.data.add("{")
  b.kv("mode", "calibrate")
  b.kv("build", BuildMode)
  b.kv("host", hostDescription())
  b.emitCalibration(c)
  b.data.add("}")
  if cfg.outPath.len > 0: writeFile(cfg.outPath, b.data & "\n")
  else: echo b.data
  if not c.calibrationOk():
    stderr.writeLine("CALIBRATION FAILED; refusing to report a measurement " &
      "from an instrument that did not check out")
    quit 3

# --- the study ------------------------------------------------------------

type
  DrainCtx = object
    ## THE DAEMON'S OUTPUT MUST BE DRAINED OR THE DAEMON STOPS.
    ##
    ## This cost a run. ``startProcess`` with a captured stdout hands the child
    ## a pipe; ``runquotad`` logs to it; nothing read it; the pipe filled at 64
    ## KiB and the daemon blocked in ``write`` forever. The visible symptom was
    ## not a daemon error -- it was a `repro` build that HUNG, because a client
    ## blocked on a lease response that a wedged daemon would never send, and a
    ## tap reporting three upstream connect failures and zero frames. A study
    ## that published that would have published "a build makes no RunQuota IPC".
    ##
    ## So a thread drains it into a log file, and the log is quoted in the
    ## result whenever an invocation fails.
    running: Atomic[bool]
    process: Process
    path: string

type Study = object
  cfg: Config
  cal: Calibration
  root: string
  daemonSocket: string
  tapSocket: string
  daemon: Process
  daemonLog: string
  drainCtx: ptr DrainCtx
  tap: ptr TapState
  daemonPid: int
  results: seq[InvocationResult]
  loadRatios: seq[float]
  warmupWallMs: float
  warmupExit: int
  warmupActions: int

proc drainThread(ctx: ptr DrainCtx) {.thread.} =
  var log = open(ctx.path, fmWrite)
  try:
    let stream = ctx.process.outputStream
    while ctx.running.load():
      var line = ""
      if stream.readLine(line):
        log.writeLine(line)
        log.flushFile()
      else:
        break
  except CatchableError:
    discard
  finally:
    close(log)

proc daemonAlive(s: var Study): bool =
  s.daemon != nil and s.daemon.running

proc startDaemon(s: var Study) =
  let daemonDir = s.root / "daemon"
  prepareDir(daemonDir)
  let stateDir = s.root / "state"
  prepareDir(stateDir)
  s.daemonSocket = daemonDir / "runquotad.sock"
  if not fileExists(s.cfg.daemonBin):
    raise newException(OSError, "missing daemon binary: " & s.cfg.daemonBin)
  var daemonArgs = @[
    "--socket", s.daemonSocket,
    "--host-identity-file", stateDir / "host-id",
    "--cpu-milli", $s.cfg.cpuMilli,
    "--memory-bytes", $s.cfg.memoryBytes
  ]
  for pool in s.cfg.pools:
    daemonArgs.add("--pool")
    daemonArgs.add(pool)
  # EXTRA DAEMON FLAGS, so the SAME harness can run the capture-disabled
  # control. `--daemon-arg=--no-write-stats` turns off the observation store,
  # its writer thread, the ambient sampler and the self-report intake -- the
  # exact one-flag control `runquota_m13_bench` established -- and running the
  # identical build against both daemons is what turns "completion reporting
  # dominates" into a statement about WHICH PART of completion reporting.
  for extra in s.cfg.daemonArgs:
    daemonArgs.add(extra)
  s.daemon = startProcess(s.cfg.daemonBin, args = daemonArgs,
    options = {poStdErrToStdOut})
  s.daemonPid = s.daemon.processID
  s.daemonLog = s.root / "runquotad.log"
  s.drainCtx = cast[ptr DrainCtx](allocShared0(sizeof(DrainCtx)))
  s.drainCtx.running.store(true)
  s.drainCtx.process = s.daemon
  s.drainCtx.path = s.daemonLog
  var drainHandle = new(Thread[ptr DrainCtx])
  createThread(drainHandle[], drainThread, s.drainCtx)
  if not waitForSocket(s.daemonSocket, 15000):
    var tail = ""
    if fileExists(s.daemonLog):
      tail = readFile(s.daemonLog)
    raise newException(OSError, "runquotad did not become reachable at " &
      s.daemonSocket & "\n--- daemon log ---\n" & tail)

proc startTap(s: var Study) =
  let tapDir = s.root / "tap"
  prepareDir(tapDir)
  s.tapSocket = tapDir / "runquotad.sock"
  s.tap = newTapState()
  s.tap.setUpstream(s.daemonSocket)
  let fd = listenUnix(s.tapSocket)
  if cint(fd) < 0:
    raise newException(OSError, "could not bind tap socket " & s.tapSocket)
  setFilePermissions(s.tapSocket, {fpUserRead, fpUserWrite})
  s.tap.listenFd.store(int(cint(fd)))
  var acceptThread = new(Thread[ptr TapState])
  createThread(acceptThread[], acceptLoop, s.tap)
  if not waitForSocket(s.tapSocket, 5000):
    raise newException(OSError, "tap socket did not accept connections")

proc reproEnv(s: Study; withRunQuota: bool; socket = ""): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    result[key] = value
  # NEVER LET THE SUBJECT SPAWN ITS OWN DAEMON. If it did, the tap would see
  # nothing and the run would look like a build that makes no IPC at all --
  # a silent zero, which is the most dangerous shape a measurement can take.
  result["REPROBUILD_AUTO_RUNQUOTA"] = "0"
  if withRunQuota:
    result["RUNQUOTA_SOCKET"] = (if socket.len > 0: socket else: s.tapSocket)
    result.del("REPROBUILD_NO_RUNQUOTA")
  else:
    result["REPROBUILD_NO_RUNQUOTA"] = "1"
    result.del("RUNQUOTA_SOCKET")

proc actionsFromOutput(text: string): int =
  for line in text.splitLines():
    let idx = line.find("actions=")
    if idx >= 0:
      var digits = ""
      var i = idx + len("actions=")
      while i < line.len and line[i] in Digits:
        digits.add(line[i])
        inc i
      if digits.len > 0:
        result = parseInt(digits)

proc runOnce(s: var Study; arm: string; index: int;
             socket = ""): InvocationResult =
  var sampler = cast[ptr SamplerState](allocShared0(sizeof(SamplerState)))
  sampler.running.store(true)
  sampler.pid.store(0)
  sampler.lastSyscalls.store(0)
  sampler.lastCsw.store(0)
  sampler.samples.store(0)
  var samplerThreadHandle = new(Thread[ptr SamplerState])
  createThread(samplerThreadHandle[], samplerThread, sampler)

  let daemonBefore = pidUnixSyscallCount(s.daemonPid)
  let args = s.cfg.subjectArgs
  # THE WARMUP IS A RUNQUOTA ARM, and it has to be, for a reason that is not
  # about warming anything. `repro-daemon` is a PERSISTENT process that the
  # first invocation starts and every later one reuses, and it keeps the
  # environment it was started with -- so a warmup that ran with
  # `REPROBUILD_NO_RUNQUOTA=1` left a build daemon that would not talk to
  # RunQuota AT ALL for the rest of the study, and the tap then reported a
  # `Hello` and nothing else. That is precisely the SILENT ZERO
  # `reproEnv`'s own comment warns about, arriving through a door it did not
  # cover; `arm == "runquota"` is false for the string "warmup". The warmup
  # is still run STRAIGHT AT THE DAEMON rather than through the tap -- the
  # caller passes `s.daemonSocket` -- so nothing it does can reach a
  # percentile.
  let env = s.reproEnv(arm != "control", socket)
  let tStart = monoNs()
  var child = startProcess(s.cfg.reproBin, workingDir = s.cfg.subjectDir,
    args = args, env = env, options = {poStdErrToStdOut})
  sampler.pid.store(child.processID)
  # A BOUNDED WINDOW, WHEN ASKED FOR. Some subjects do not finish in a time a
  # paired five-invocation study can afford -- reprobuild's own `repro test`
  # declares 2785 actions and runs for hours. Truncating it still yields real
  # per-message admission and reporting latencies from a real parallel test
  # run; what it CANNOT yield is gate figure 4, because a fraction of wall time
  # needs a whole build's wall time. The result records `truncated` so no
  # reader can mistake one for the other.
  var truncated = false
  var output = ""
  if s.cfg.subjectTimeoutMs > 0:
    var waited = 0
    while waited < s.cfg.subjectTimeoutMs and child.running:
      sleep(200)
      waited += 200
    if child.running:
      truncated = true
      child.terminate()
      discard child.waitForExit(10000)
      if child.running:
        child.kill()
        discard child.waitForExit(10000)
  try:
    output = child.outputStream.readAll()
  except CatchableError:
    output = ""
  let code = child.waitForExit()
  let tEnd = monoNs()
  sampler.running.store(false)
  joinThread(samplerThreadHandle[])
  let daemonAfter = pidUnixSyscallCount(s.daemonPid)
  child.close()

  result = InvocationResult(
    arm: arm,
    index: index,
    wallMs: float(tEnd - tStart) / 1_000_000.0,
    exitCode: code,
    reproSyscalls: sampler.lastSyscalls.load(),
    reproCtxSwitches: sampler.lastCsw.load(),
    daemonSyscallDelta:
      (if daemonBefore == high(uint64) or daemonAfter == high(uint64): 0'u64
       else: daemonAfter - daemonBefore),
    tStartNs: tStart,
    tEndNs: tEnd,
    truncated: truncated,
    actionsReported: actionsFromOutput(output),
    stdoutTail: output.splitLines()[max(0, output.splitLines().len - 12) .. ^1].join("\n")
  )
  deallocShared(sampler)
  if code != 0 and not truncated:
    stderr.writeLine("SUBJECT EXITED " & $code & " (arm=" & arm & " index=" &
      $index & "); the run below does not measure a successful build")
    stderr.writeLine(result.stdoutTail)

proc classStats(b: var JsonBuf; name: string; values: seq[float]) =
  b.data.add("\"" & name & "\":{")
  b.kvi("count", int64(values.len))
  b.kvn("p50_us", percentile(values, 0.50))
  b.kvn("p90_us", percentile(values, 0.90))
  b.kvn("p99_us", percentile(values, 0.99))
  b.kvn("max_us", (if values.len == 0: 0.0 else: max(values)))
  b.kvn("mean_us", mean(values))
  b.kvn("total_ms", sum(values) / 1000.0, last = true)
  b.data.add("}")

proc runStudy(cfg: Config) =
  var s = Study(cfg: cfg)
  s.cal = calibrate()
  if not s.cal.calibrationOk():
    stderr.writeLine("CALIBRATION FAILED; refusing to measure")
    quit 3
  if cfg.reproBin.len == 0 or not fileExists(cfg.reproBin):
    raise newException(OSError, "missing --repro=PATH")
  if cfg.subjectDir.len == 0 or not dirExists(cfg.subjectDir):
    raise newException(OSError, "missing --subject-dir=DIR")

  s.root = getTempDir() / ("rq-m1-" & $getCurrentProcessId())
  prepareDir(s.root)
  let loadAvgBefore = loadAverage()

  var loadState = cast[ptr LoadProbeState](allocShared0(sizeof(LoadProbeState)))
  loadState.capacity = 4096
  loadState.samples = cast[ptr UncheckedArray[float]](
    allocShared0(loadState.capacity * sizeof(float)))
  loadState.running.store(true)
  loadState.count.store(0)
  var loadThread = new(Thread[ptr LoadProbeState])
  createThread(loadThread[], loadProbeThread, loadState)

  try:
    s.startDaemon()

    # A WARMUP INVOCATION, RUN STRAIGHT AT THE DAEMON so the tap never sees
    # it. The first build of a project pays for things that are not
    # per-execution cost and happen once: the provider compile, a cold action
    # cache, a page cache that has not seen the tree. Discarding it is the
    # M13 warmup rule; running it OUTSIDE the tap rather than filtering it
    # afterwards means there is no chance of it reaching a percentile.
    let warmup = s.runOnce("warmup", -1, socket = s.daemonSocket)
    s.warmupWallMs = warmup.wallMs
    s.warmupExit = warmup.exitCode
    s.warmupActions = warmup.actionsReported

    s.startTap()

    # INTERLEAVED, NOT SEQUENTIAL -- the M13 lesson applied to a whole build
    # instead of a single execution. A block of RunQuota runs followed by a
    # block of control runs measures the machine's mood as much as the code
    # on a host whose load average moved 28 -> 110 during this campaign.
    for i in 0 ..< cfg.invocations:
      # THE DAEMON IS CHECKED ALIVE BEFORE EVERY INVOCATION. A dead lease
      # authority does not make a build fail; it makes it HANG, and a harness
      # that noticed only afterwards would have spent an hour producing
      # nothing.
      if not s.daemonAlive():
        raise newException(OSError,
          "runquotad exited before invocation " & $i & "; see " & s.daemonLog)
      if (i and 1) == 0:
        s.results.add(s.runOnce("runquota", i))
        if cfg.control: s.results.add(s.runOnce("control", i))
      else:
        if cfg.control: s.results.add(s.runOnce("control", i))
        s.results.add(s.runOnce("runquota", i))
  finally:
    loadState.running.store(false)
    joinThread(loadThread[])
    if s.tap != nil:
      s.tap.accepting.store(false)

  let n = min(loadState.count.load(), loadState.capacity)
  for i in 0 ..< n:
    s.loadRatios.add(loadState.samples[i])

  # Give in-flight frames a moment to land before the buffer is read.
  sleep(200)
  let events = if s.tap != nil: snapshot(s.tap) else: @[]
  let (paired, unpaired) = pairEvents(events)

  # THE RAW EVENT STREAM, optionally, so a reader can re-derive every
  # percentile below rather than trusting this program's arithmetic.
  if cfg.dumpEvents.len > 0:
    createDir(cfg.dumpEvents.parentDir)
    var dump = open(cfg.dumpEvents, fmWrite)
    dump.writeLine("t_ns,dir,kind,request_id,payload_len,conn,peer_pid")
    for ev in events:
      dump.writeLine($ev.tNs & "," & $ev.dir & "," & kindName(ev.kind) & "," &
        $ev.requestId & "," & $ev.payloadLen & "," & $ev.conn & "," &
        $ev.peerPid)
    close(dump)

  var b = JsonBuf()
  b.data.add("{")
  b.kv("mode", "study")
  b.kv("milestone", "M1")
  b.kv("subject", cfg.subjectName)
  b.kv("subject_dir", cfg.subjectDir)
  b.kv("subject_args", cfg.subjectArgs.join(" "))
  b.kv("runquota_build_mode", BuildMode)
  b.kv("repro_build_mode", cfg.reproMode)
  b.kv("repro_bin", cfg.reproBin)
  b.kv("daemon_bin", cfg.daemonBin)
  b.kv("host", hostDescription())
  b.kv("load_average_before", loadAvgBefore)
  b.kv("load_average_after", loadAverage())
  b.kvi("daemon_cpu_milli", int64(cfg.cpuMilli))
  b.kv("daemon_pools", cfg.pools.join(","))
  b.kv("daemon_extra_args", cfg.daemonArgs.join(" "))
  b.kvi("invocations", int64(cfg.invocations))
  b.kvn("warmup_wall_ms", s.warmupWallMs)
  b.kvi("warmup_exit_code", int64(s.warmupExit))
  b.kvi("warmup_actions_reported", int64(s.warmupActions))
  b.kvb("control_arm", cfg.control)
  b.emitCalibration(s.cal)
  b.data.add(",")

  # measured oversubscription
  b.data.add("\"measured_load\":{")
  b.kvi("fixed_work_units", int64(s.loadRatios.len))
  b.kvn("wall_over_cpu_p50", percentile(s.loadRatios, 0.50))
  b.kvn("wall_over_cpu_p90", percentile(s.loadRatios, 0.90))
  b.kvn("wall_over_cpu_min", (if s.loadRatios.len == 0: 0.0 else: min(s.loadRatios)))
  b.kvn("wall_over_cpu_max", (if s.loadRatios.len == 0: 0.0 else: max(s.loadRatios)),
    last = true)
  b.data.add("},")

  # tap health
  b.data.add("\"tap\":{")
  b.kvi("frames", int64(events.len))
  b.kvi("paired_round_trips", int64(paired.len))
  b.kvi("unpaired_frames", int64(unpaired.len))
  b.kvi("connections", int64(s.tap.connSeq.load()))
  b.kvi("accept_errors", int64(s.tap.acceptErrors.load()))
  b.kvi("upstream_errors", int64(s.tap.upstreamErrors.load()))
  b.kvb("overflowed", s.tap.overflowed.load(), last = true)
  b.data.add("},")

  # which pids spoke RQSP
  var pids = initCountTable[int32]()
  for ev in events:
    pids.inc(ev.peerPid)
  b.data.add("\"peer_pids\":[")
  var firstPid = true
  for pid, count in pids:
    if not firstPid: b.data.add(",")
    firstPid = false
    b.data.add("{\"pid\":" & $pid & ",\"frames\":" & $count & "}")
  b.data.add("],")

  # per message kind
  var byKind = initTable[string, seq[float]]()
  var byClass = initTable[string, seq[float]]()
  for p in paired:
    let us = float(p.tEndNs - p.tStartNs) / 1000.0
    byKind.mgetOrPut($p.kind, @[]).add(us)
    byClass.mgetOrPut($costClass(p.kind), @[]).add(us)

  b.data.add("\"by_message_kind\":{")
  var firstKind = true
  for kind, values in byKind:
    if not firstKind: b.data.add(",")
    firstKind = false
    classStats(b, kind.substr(2), values)
  b.data.add("},")

  b.data.add("\"by_cost_class\":{")
  var firstClass = true
  for cls, values in byClass:
    if not firstClass: b.data.add(",")
    firstClass = false
    classStats(b, cls.substr(2), values)
  b.data.add("},")

  # one-way frames: no reply exists, so no latency does either
  var oneWay = initCountTable[string]()
  for ev in unpaired:
    if Direction(ev.dir) == dirClientToDaemon:
      oneWay.inc(kindName(ev.kind))
  b.data.add("\"one_way_sends\":{")
  var firstOw = true
  for kind, count in oneWay:
    if not firstOw: b.data.add(",")
    firstOw = false
    b.data.add("\"" & esc(kind) & "\":" & $count)
  b.data.add("},")

  # per invocation
  b.data.add("\"invocations_detail\":[")
  for i, r in s.results:
    if i > 0: b.data.add(",")
    var windowUs = 0.0
    var admissionUs = 0.0
    var completionUs = 0.0
    var startUs = 0.0
    var sessionUs = 0.0
    var leaseCount = 0
    for p in paired:
      if p.tStartNs >= r.tStartNs and p.tEndNs <= r.tEndNs:
        let us = float(p.tEndNs - p.tStartNs) / 1000.0
        windowUs += us
        case costClass(p.kind)
        of ccAdmission: admissionUs += us
        of ccCompletion:
          completionUs += us
          if p.kind == rqReleaseLease: inc leaseCount
        of ccSession: sessionUs += us
        of ccOther: discard
        if p.kind in {rqLeaseStarting, rqLeaseRunning}:
          startUs += us
          completionUs -= us
    b.data.add("{")
    b.kv("arm", r.arm)
    b.kvi("index", int64(r.index))
    b.kvn("wall_ms", r.wallMs)
    b.kvi("exit_code", int64(r.exitCode))
    b.kvb("truncated", r.truncated)
    b.kvi("actions_reported", int64(r.actionsReported))
    b.kvi("leases_completed", int64(leaseCount))
    b.kvi("repro_unix_syscalls", int64(r.reproSyscalls))
    b.kvi("repro_context_switches", int64(r.reproCtxSwitches))
    b.kvi("daemon_unix_syscalls", int64(r.daemonSyscallDelta))
    b.kvn("ipc_total_ms", windowUs / 1000.0)
    b.kvn("ipc_admission_ms", admissionUs / 1000.0)
    b.kvn("ipc_lifecycle_start_ms", startUs / 1000.0)
    b.kvn("ipc_completion_ms", completionUs / 1000.0)
    b.kvn("ipc_session_ms", sessionUs / 1000.0)
    b.kvn("ipc_fraction_of_wall_percent",
      (if r.wallMs > 0.0: 100.0 * (windowUs / 1000.0) / r.wallMs else: 0.0))
    # THE SUBJECT'S OWN LAST WORDS, kept for every invocation rather than
    # only failing ones. A build that exited non-zero has not measured what
    # the gate asks about, and a published result must make that impossible
    # to miss.
    b.kv("subject_tail", r.stdoutTail, last = true)
    b.data.add("}")
  b.data.add("]")
  b.data.add("}")

  if cfg.outPath.len > 0:
    createDir(cfg.outPath.parentDir)
    writeFile(cfg.outPath, b.data & "\n")
    stderr.writeLine("wrote " & cfg.outPath)
  else:
    echo b.data

  if s.daemon != nil:
    if s.daemon.running: s.daemon.terminate()
    discard s.daemon.waitForExit(5000)
    s.daemon.close()
  if dirExists(s.root): removeDir(s.root)

# --- tap overhead control -------------------------------------------------

proc runTapOverhead(cfg: Config) =
  ## THE CONTROL THAT MAKES THE TAP'S NUMBERS READABLE. Identical lease
  ## traffic is driven straight at the daemon and through the tap; the
  ## difference is the tap's inflation, and it is SUBTRACTED FROM NOTHING --
  ## it is published beside the result as the band inside which the tapped
  ## figures should be read.
  ##
  ## The driver here IS synthetic, and that is correct for a control: what is
  ## being isolated is the instrument, not the workload.
  let cal = calibrate()
  if not cal.calibrationOk():
    stderr.writeLine("CALIBRATION FAILED; refusing to measure")
    quit 3

  var s = Study(cfg: cfg)
  s.root = getTempDir() / ("rq-m1t-" & $getCurrentProcessId())
  prepareDir(s.root)
  var directRtt: seq[float] = @[]
  var tappedRtt: seq[float] = @[]
  var paired: seq[float] = @[]
  var directTap: seq[float] = @[]
  var tapMeasured: seq[float] = @[]
  try:
    s.startDaemon()
    s.startTap()

    proc lifecycleRtt(socket: string; label: string): float =
      ## ONE ADMISSION ROUND TRIP, client-observed, on a session that is
      ## already registered -- the same quantity the tap reports for
      ## ``RequestLease``, measured from the place the tap cannot stand.
      putEnv("RUNQUOTA_SOCKET", socket)
      var client = connectDefault()
      var session = client.registerSession(label, "0.1.0")
      let t0 = monoNs()
      var lease = session.requestLease(resourceRequest(label, milliCpu(100),
        bytes(1024 * 1024)))
      let t1 = monoNs()
      if not lease.active:
        raise newException(ValueError, "control lease was not granted")
      lease.release()
      session.closeSession()
      client.close()
      float(t1 - t0) / 1000.0

    # A session per round is deliberate: it keeps the two arms structurally
    # identical and stops a long-lived connection's socket buffer state from
    # diverging between them.
    let rounds = max(50, cfg.tapOverheadRounds div 20)
    for i in 0 ..< 20:
      discard lifecycleRtt(s.daemonSocket, "tapctl-warmup")
      discard lifecycleRtt(s.tapSocket, "tapctl-warmup")
    for i in 0 ..< rounds:
      if (i and 1) == 0:
        let d = lifecycleRtt(s.daemonSocket, "tapctl-direct")
        let t = lifecycleRtt(s.tapSocket, "tapctl-tapped")
        directRtt.add(d); tappedRtt.add(t); paired.add(t - d)
      else:
        let t = lifecycleRtt(s.tapSocket, "tapctl-tapped")
        let d = lifecycleRtt(s.daemonSocket, "tapctl-direct")
        directRtt.add(d); tappedRtt.add(t); paired.add(t - d)

    s.tap.accepting.store(false)
    sleep(200)
    let events = snapshot(s.tap)
    let (tapPaired, _) = pairEvents(events)
    for p in tapPaired:
      if p.kind == rqRequestLease:
        tapMeasured.add(float(p.tEndNs - p.tStartNs) / 1000.0)
  finally:
    if s.daemon != nil:
      if s.daemon.running: s.daemon.terminate()
      discard s.daemon.waitForExit(5000)
      s.daemon.close()
    if dirExists(s.root): removeDir(s.root)

  var b = JsonBuf()
  b.data.add("{")
  b.kv("mode", "tap-overhead")
  b.kv("build", BuildMode)
  b.kv("host", hostDescription())
  b.kv("load_average", loadAverage())
  b.emitCalibration(cal)
  b.data.add(",")
  classStats(b, "request_lease_direct_us", directRtt)
  b.data.add(",")
  classStats(b, "request_lease_through_tap_us", tappedRtt)
  b.data.add(",")
  classStats(b, "tap_reported_request_lease_us", tapMeasured)
  b.data.add(",")
  b.data.add("\"paired_tapped_minus_direct_us\":{")
  b.kvi("count", int64(paired.len))
  b.kvn("median", percentile(paired, 0.50))
  b.kvn("p90", percentile(paired, 0.90))
  b.kvn("mean", mean(paired), last = true)
  b.data.add("},")
  b.data.add("\"tap_reported_minus_direct_median_us\":" &
    num(percentile(tapMeasured, 0.50) - percentile(directRtt, 0.50)))
  b.data.add("}")
  if cfg.outPath.len > 0:
    createDir(cfg.outPath.parentDir)
    writeFile(cfg.outPath, b.data & "\n")
    stderr.writeLine("wrote " & cfg.outPath)
  else: echo b.data

proc runClientCost(cfg: Config) =
  ## GATE FIGURE 3, AND THE ONLY HONEST WAY TO GET IT.
  ##
  ## "Total syscalls attributable to RunQuota IPC" is a property of the
  ## CLIENT, and this repository does not compile the client -- `repro` does.
  ## Worse, the frames do not even come from the `repro` process a caller
  ## spawns: the tap's peer credentials show them arriving from the BUILD
  ## WORKER inside `repro-daemon`, a third process. Differencing that
  ## process's total syscall count between the RunQuota and `--no-runquota`
  ## arms would difference two numbers dominated by the build itself -- tens
  ## of thousands of syscalls of compiler spawning, file I/O and hashing --
  ## and call the noise an IPC cost.
  ##
  ## So the per-round-trip cost is measured EXACTLY, in a controlled harness,
  ## against the same real daemon over the same real socket, using the SAME
  ## `runquota_client` library `repro` links; and it is MULTIPLIED by the
  ## round-trip counts the tap observed on the real build. Both factors are
  ## measured; neither is assumed. The daemon's own side needs no such
  ## treatment -- it is measured directly on the real build, because during a
  ## study invocation the daemon serves nothing else.
  ##
  ## This also yields a DIRECT, UN-TAPPED client-observed latency for every
  ## message kind, which is an independent cross-check on the tapped figures.
  let cal = calibrate()
  if not cal.calibrationOk():
    stderr.writeLine("CALIBRATION FAILED; refusing to measure")
    quit 3

  var s = Study(cfg: cfg)
  # SHORT, DELIBERATELY. macOS caps a unix socket path at 104 bytes and
  # `getTempDir()` alone is 48 of them here; a descriptive directory name
  # ("rq-m1-clientcost-<pid>") pushed the daemon's socket past the limit and it
  # died at startup with "socket path too long".
  s.root = getTempDir() / ("rq-m1c-" & $getCurrentProcessId())
  prepareDir(s.root)

  const Rounds = 2000
  const Warmup = 100
  var lat = initTable[string, seq[float]]()
  var sysc = initTable[string, int64]()
  var counted = initTable[string, int]()

  proc note(name: string; startNs, endNs: int64; syscalls: int64) =
    lat.mgetOrPut(name, @[]).add(float(endNs - startNs) / 1000.0)
    sysc[name] = sysc.getOrDefault(name) + syscalls
    counted[name] = counted.getOrDefault(name) + 1

  try:
    s.startDaemon()
    putEnv("RUNQUOTA_SOCKET", s.daemonSocket)
    var client = connectDefault()
    var session = client.registerSession("m1-client-cost", "0.1.0")

    for i in 0 ..< (Rounds + Warmup):
      let measured = i >= Warmup
      template step(name: string; body: untyped) =
        let sBefore = unixSyscallCount()
        let t0 = monoNs()
        body
        let t1 = monoNs()
        let delta = int64(unixSyscallCount() - sBefore)
        if measured: note(name, t0, t1, delta)

      var lease: RunQuotaLease
      step "RequestLease":
        lease = session.requestLease(resourceRequest("m1-client-cost",
          milliCpu(100), bytes(1024 * 1024)))
      if not lease.active:
        raise newException(ValueError, "client-cost lease was not granted")
      step "LeaseStarting":
        lease.markStarting()
      step "LeaseRunning":
        lease.markRunning(childProcessId = uint64(getCurrentProcessId()))
      step "LeaseFinished":
        lease.finish(outcome = succeeded(), peakMemoryBytes = 1_048_576'u64,
          processCount = 1'u32)
      step "ReleaseLease":
        lease.release()

    session.closeSession()
    client.close()
  finally:
    if s.daemon != nil:
      if s.daemon.running: s.daemon.terminate()
      discard s.daemon.waitForExit(5000)
      s.daemon.close()
    if dirExists(s.root): removeDir(s.root)

  var b = JsonBuf()
  b.data.add("{")
  b.kv("mode", "client-cost")
  b.kv("build", BuildMode)
  b.kv("host", hostDescription())
  b.kv("load_average", loadAverage())
  b.kvi("rounds", int64(Rounds))
  b.emitCalibration(cal)
  b.data.add(",")
  b.data.add("\"per_round_trip\":{")
  var first = true
  for name, values in lat:
    if not first: b.data.add(",")
    first = false
    b.data.add("\"" & esc(name) & "\":{")
    b.kvi("count", int64(values.len))
    b.kvn("client_p50_us", percentile(values, 0.50))
    b.kvn("client_p90_us", percentile(values, 0.90))
    b.kvn("client_p99_us", percentile(values, 0.99))
    b.kvn("unix_syscalls_total", float(sysc.getOrDefault(name)))
    b.kvn("unix_syscalls_per_round_trip",
      float(sysc.getOrDefault(name)) / float(max(1, counted.getOrDefault(name))),
      last = true)
    b.data.add("}")
  b.data.add("}}")
  if cfg.outPath.len > 0:
    createDir(cfg.outPath.parentDir)
    writeFile(cfg.outPath, b.data & "\n")
    stderr.writeLine("wrote " & cfg.outPath)
  else: echo b.data

proc main() =
  let cfg = parseConfig()
  case cfg.mode
  of "calibrate": runCalibrationMode(cfg)
  of "study": runStudy(cfg)
  of "tap-overhead": runTapOverhead(cfg)
  of "client-cost": runClientCost(cfg)
  else:
    stderr.writeLine("unknown --mode=" & cfg.mode)
    quit 2

main()
