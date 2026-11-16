## Host CPU pressure, and the gate it drives in admission.
##
## WHAT THE SIGNAL IS. On Linux, the *some* ``avg10`` of
## ``/proc/pressure/cpu``: the share of the last ten seconds in which at
## least one runnable task waited for a CPU, in percent
## (https://docs.kernel.org/accounting/psi.html). It measures what a
## prediction can only guess: whether the work on the host already wants
## more CPU than it has. The daemon may read another file of the same
## format instead (``runquotad --cpu-pressure-file``), which is how tests
## hold the signal where they need it.
##
## WHAT THE GATE DOES. Admission uses the signal to stop doing two things
## that add load the ledger did not reserve: admitting RECLAIMED work (into
## CPU predicted free) and WIDENING resizable leases. The gate is a
## hysteresis, so a reading hovering at one threshold does not flap the
## decision on every pass:
##
## * it CLOSES when the reading is above ``high``;
## * it OPENS when the reading is below ``low``;
## * in between, it keeps its state; it starts open.
##
## A signal that cannot be read leaves the gate's state alone and is
## reported as unavailable; what admission does then is its decision (no
## reclaimed grants, since a wrong prediction would go uncorrected, and
## widening as if there were no gate).
##
## MACOS AND WINDOWS. There is no ``/proc/pressure/cpu`` there. A file named
## with ``--cpu-pressure-file`` is read on every platform (the parse is pure,
## portable text; it is how tests hold the signal). With no such override the
## macOS reader still answers unavailable until its run-queue reading arrives,
## while WINDOWS reads the Performance Data Helper counter ``\System\Processor
## Queue Length`` -- the threads ready to run but waiting for a processor, the
## signal Task Manager reads for CPU contention. That count is normalized to
## the gate's 0..100 scale (``WindowsQueuePressureScale``) so a value in the
## same units reaches the same gate, the way the macOS run-queue reading will:
## nothing above the reader changes by platform. The Windows reading is an
## APPROXIMATION of PSI, not the same measurement -- it is an instantaneous
## queue sample, where PSI's ``avg10`` is a ten-second time average -- so it
## is noisier and carries no history; the gate's hysteresis and its read
## cadence stand in for the averaging.
##
## The gate and the parser are pure; only ``readCpuPressure`` (and, on
## Windows, the PDH query it makes when no file overrides it) touches the
## system.

import std/strutils

when defined(windows):
  import std/cpuinfo

const
  DefaultCpuPressureFile* = "/proc/pressure/cpu"
  DefaultPressureHighPct* = 10.0
    ## Above this, reclaimed admission and widening stop.
  DefaultPressureLowPct* = 5.0
    ## Below this, they resume.
  CpuPressureReadIntervalMillis* = 500'i64
    ## The most often the signal is read. The kernel recomputes ``avg10``
    ## every two seconds, so reading it more often learns nothing.
  WindowsQueuePressureScale* = 10.0
    ## Pressure units per ready-but-waiting thread per logical processor, used
    ## to normalize Windows' ``\System\Processor Queue Length`` (a raw thread
    ## count) onto the gate's 0..100 scale:
    ## ``min(100, queueLength / logicalProcessors * WindowsQueuePressureScale)``.
    ## At this scale one ready thread per core reads 10 -- the gate's default
    ## close point (``DefaultPressureHighPct``), a host with as many threads
    ## queued as it has cores -- and half that reads 5, the default reopen
    ## point. The shared thresholds therefore keep a defensible physical
    ## meaning on Windows without a platform-specific default.

type
  CpuPressureSample* = object
    available*: bool
    someAvg10Pct*: float64
    detail*: string
      ## Why it is unavailable, when it is.

  CpuPressureGate* = object
    closed*: bool
      ## Reclaimed admission and widening are stopped.
    lastSample*: CpuPressureSample
    lastReadMillis*: int64
    read*: bool
      ## At least one reading has been attempted.
    closures*: uint64
      ## How many times the gate has closed (for inspection).

proc parseCpuPressure*(text: string): CpuPressureSample =
  ## The ``some`` line's ``avg10`` from a PSI file:
  ## ``some avg10=1.23 avg60=0.40 avg300=0.10 total=123456``. Unavailable,
  ## with the reason, when there is no such line or field or it is not a
  ## number in 0..100.
  for line in text.splitLines():
    let fields = line.strip().splitWhitespace()
    if fields.len == 0 or fields[0] != "some":
      continue
    for field in fields[1 .. ^1]:
      if field.startsWith("avg10="):
        let raw = field["avg10=".len .. ^1]
        var value = 0.0
        try:
          value = parseFloat(raw)
        except ValueError:
          return CpuPressureSample(available: false,
            detail: "avg10 is not a number: " & raw)
        if value < 0.0 or value > 100.0 or value != value:
          return CpuPressureSample(available: false,
            detail: "avg10 out of range: " & raw)
        return CpuPressureSample(available: true, someAvg10Pct: value)
    return CpuPressureSample(available: false,
      detail: "the some line has no avg10")
  CpuPressureSample(available: false, detail: "no some line")

proc readCpuPressureFile(path: string): CpuPressureSample =
  ## Read and parse a PSI-format file. Portable text: the same on every
  ## platform, which is what lets ``--cpu-pressure-file`` hold the signal for
  ## tests wherever they run.
  let text =
    try:
      readFile(path)
    except IOError, OSError:
      return CpuPressureSample(available: false,
        detail: "cannot read " & path)
  result = parseCpuPressure(text)
  if not result.available:
    result.detail = path & ": " & result.detail

when defined(windows):
  type
    PdhHandle = int
      ## A ``PDH_HQUERY`` / ``PDH_HCOUNTER``: HANDLE-sized, 0 until opened.
    PdhCounterValueDouble {.pure.} = object
      ## ``PDH_FMT_COUNTERVALUE`` read as a double: a ``DWORD`` status, then
      ## (after the natural 8-byte alignment the union forces) the value.
      cStatus: uint32
      reserved: uint32
      doubleValue: float64

  const
    PdhErrorSuccess = 0'i32
    PdhFmtDouble = 0x00000200'u32
    ProcessorQueueLengthCounter = "\\System\\Processor Queue Length"

  proc pdhOpenQueryW(dataSource: WideCString; userData: uint;
    query: ptr PdhHandle): int32
    {.stdcall, dynlib: "pdh.dll", importc: "PdhOpenQueryW".}
  proc pdhAddEnglishCounterW(query: PdhHandle; counterPath: WideCString;
    userData: uint; counter: ptr PdhHandle): int32
    {.stdcall, dynlib: "pdh.dll", importc: "PdhAddEnglishCounterW".}
  proc pdhCollectQueryData(query: PdhHandle): int32
    {.stdcall, dynlib: "pdh.dll", importc: "PdhCollectQueryData".}
  proc pdhGetFormattedCounterValue(counter: PdhHandle; format: uint32;
    counterType: ptr uint32; value: ptr PdhCounterValueDouble): int32
    {.stdcall, dynlib: "pdh.dll", importc: "PdhGetFormattedCounterValue".}
  proc pdhCloseQuery(query: PdhHandle): int32
    {.stdcall, dynlib: "pdh.dll", importc: "PdhCloseQuery".}

  proc readWindowsProcessorQueuePressure(): CpuPressureSample =
    ## The production default on Windows: ``\System\Processor Queue Length``
    ## through PDH, normalized onto the gate's 0..100 scale. The counter is
    ## instantaneous, so one ``PdhCollectQueryData`` suffices (unlike a rate
    ## counter, which needs two). ``PdhAddEnglishCounterW`` names the counter
    ## in English whatever the host locale is.
    var query: PdhHandle = 0
    if pdhOpenQueryW(nil, 0, addr query) != PdhErrorSuccess:
      return CpuPressureSample(available: false,
        detail: "PdhOpenQueryW failed")
    defer: discard pdhCloseQuery(query)
    var counter: PdhHandle = 0
    if pdhAddEnglishCounterW(query,
        newWideCString(ProcessorQueueLengthCounter), 0, addr counter) !=
        PdhErrorSuccess:
      return CpuPressureSample(available: false,
        detail: "PdhAddEnglishCounterW(" & ProcessorQueueLengthCounter &
          ") failed")
    if pdhCollectQueryData(query) != PdhErrorSuccess:
      return CpuPressureSample(available: false,
        detail: "PdhCollectQueryData failed")
    var value: PdhCounterValueDouble
    var counterType: uint32 = 0
    if pdhGetFormattedCounterValue(counter, PdhFmtDouble, addr counterType,
        addr value) != PdhErrorSuccess:
      return CpuPressureSample(available: false,
        detail: "PdhGetFormattedCounterValue failed")
    let cores = max(1, countProcessors())
    var pct = value.doubleValue / float64(cores) * WindowsQueuePressureScale
    if pct < 0.0: pct = 0.0
    if pct > 100.0: pct = 100.0
    CpuPressureSample(available: true, someAvg10Pct: pct)

proc readCpuPressure*(path: string): CpuPressureSample =
  ## Read the CPU pressure signal. A ``--cpu-pressure-file`` override (any
  ## path but the default) is read as a PSI-format file on every platform;
  ## with no override, Linux reads the default PSI file, Windows the native
  ## PDH queue-length reader, and macOS answers unavailable for now.
  when defined(windows):
    if path == DefaultCpuPressureFile:
      readWindowsProcessorQueuePressure()
    else:
      readCpuPressureFile(path)
  else:
    readCpuPressureFile(path)

proc observe*(gate: var CpuPressureGate; sample: CpuPressureSample;
              highPct, lowPct: float64; nowMillis: int64) =
  ## Fold one reading into the gate (the hysteresis in the module header).
  gate.lastSample = sample
  gate.lastReadMillis = nowMillis
  gate.read = true
  if not sample.available:
    return
  if not gate.closed and sample.someAvg10Pct > highPct:
    gate.closed = true
    inc gate.closures
  elif gate.closed and sample.someAvg10Pct < lowPct:
    gate.closed = false

proc due*(gate: CpuPressureGate; nowMillis: int64): bool =
  ## Whether a new reading should be taken now.
  not gate.read or nowMillis - gate.lastReadMillis >=
    CpuPressureReadIntervalMillis

proc allowsReclaim*(gate: CpuPressureGate): bool =
  ## Reclaimed admission needs a reading, and an open gate: without the
  ## signal a prediction that is wrong would go uncorrected.
  gate.lastSample.available and not gate.closed

proc allowsWidening*(gate: CpuPressureGate): bool =
  ## Widening stops while the gate is closed; with no signal it proceeds as
  ## it did before the gate existed.
  not (gate.lastSample.available and gate.closed)
