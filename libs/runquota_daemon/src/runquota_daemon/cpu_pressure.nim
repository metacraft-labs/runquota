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
## MACOS AND WINDOWS. There is no ``/proc/pressure/cpu`` there, so the
## reader answers unavailable (a file named with ``--cpu-pressure-file`` is
## still read on macOS; Windows has no reader). The macOS
## run-queue reading is to supply a value in the same units (percent) to the
## same gate, so nothing above the reader changes when it arrives.
##
## The gate and the parser are pure; only ``readCpuPressure`` touches the
## file system.

import std/strutils

const
  DefaultCpuPressureFile* = "/proc/pressure/cpu"
  DefaultPressureHighPct* = 10.0
    ## Above this, reclaimed admission and widening stop.
  DefaultPressureLowPct* = 5.0
    ## Below this, they resume.
  CpuPressureReadIntervalMillis* = 500'i64
    ## The most often the signal is read. The kernel recomputes ``avg10``
    ## every two seconds, so reading it more often learns nothing.

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

proc readCpuPressure*(path: string): CpuPressureSample =
  ## Read and parse ``path`` (``DefaultCpuPressureFile`` normally).
  when not defined(windows):
    let text =
      try:
        readFile(path)
      except IOError, OSError:
        return CpuPressureSample(available: false,
          detail: "cannot read " & path)
    result = parseCpuPressure(text)
    if not result.available:
      result.detail = path & ": " & result.detail
  else:
    CpuPressureSample(available: false, detail: "no CPU pressure source on " &
      "this platform")

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
