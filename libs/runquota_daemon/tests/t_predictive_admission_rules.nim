## The pure rules of predictive admission: what a running lease is
## predicted to use over the admission horizon, what background demand is,
## the CPU pressure gate's hysteresis, the PSI parser, and the host file's
## predictive keys.
##
## The end-to-end behaviour, through a real `runquotad` with real process
## trees, is `tests/integration/t_predictive_admission.nim`; this file pins
## the decisions those tests rest on, each with the change that breaks it.
##
## NO MOCKS: the modules under test are pure functions of their inputs, so
## the inputs are written out. The one file read is a real
## `/proc/pressure/cpu`, when the kernel has one.

import std/[options, os, unittest]

import runquota_daemon/cpu_shape
import runquota_daemon/cpu_pressure
import runquota_daemon/prediction
import runquota_daemon/host_config

proc tailShape(): CpuShape =
  ## 3 CPUs for the first 7 points, 1 CPU for the rest: a run with a
  ## narrow tail.
  for k in 0 ..< ShapePoints:
    result[k] = if k < 7: 3000'u32 else: 1000'u32

proc forecast(elapsed: int64; expected = 12_000'u64; known = true): LeaseForecast =
  LeaseForecast(chargeMilli: 3000, shapeKnown: known, shape: tailShape(),
    expectedDurationMillis: expected, elapsedMillis: elapsed)

suite "predicted demand over the horizon":
  test "a lease in its narrow tail is predicted at the tail":
    # 12 s expected, points of 0.6 s: point 7 starts at 4.2 s.
    check forecast(4_210).predictedDemandMilli(1_000) == 1000'u32
    check forecast(8_000).predictedDemandMilli(2_000) == 1000'u32

  test "a window reaching back into the wide phase takes the wide phase":
    # Mutation: reading only the point at `now` (ignoring the horizon)
    # predicts 1000 at 4.0 s although point 6 (3.6-4.2 s) is wide.
    check forecast(3_500).predictedDemandMilli(1_000) == 3000'u32
    check forecast(4_100).predictedDemandMilli(1_000) == 3000'u32
    # The horizon reaches FORWARD: at 3.0 s with a 2 s horizon the window
    # is still wide.
    check forecast(3_000).predictedDemandMilli(2_000) == 3000'u32

  test "a window ending exactly on a point boundary does not reach it":
    # [3.0, 3.6) ends where point 6 starts; both are wide anyway, so use a
    # shape whose next point is higher.
    var f = forecast(3_000)
    f.shape[6] = 5000'u32
    check f.predictedDemandMilli(600) == 3000'u32
    check f.predictedDemandMilli(601) == 5000'u32

  test "the horizon is cut at the expected end":
    # At 11.5 s a 10 s horizon covers only points 19..19.
    check forecast(11_500).predictedDemandMilli(10_000) == 1000'u32

  test "a lease past its expected duration is predicted at its charge":
    check forecast(12_000).predictedDemandMilli(1_000) == 3000'u32
    check forecast(30_000).predictedDemandMilli(0) == 3000'u32

  test "with no shape or no expected duration, the charge: declared width":
    # Mutation: answering 0 (or the shape's tail) for an unreadable lease
    # admits reclaimed work beside leases nothing is known about.
    check forecast(5_000, known = false).predictedDemandMilli(1_000) == 3000'u32
    check forecast(5_000, expected = 0).predictedDemandMilli(1_000) == 3000'u32
    check forecast(-5).predictedDemandMilli(1_000) == 3000'u32

  test "demand now is the point at now":
    check forecast(4_210).predictedDemandMilli(0) == 1000'u32
    check forecast(4_190).predictedDemandMilli(0) == 3000'u32

suite "background demand and predicted free CPU":
  test "foreign work runs first on the processors the budget leaves out":
    # 32 processors, a 4-CPU budget: 28 CPUs of foreign work cost nothing.
    check backgroundDemandMilli(29_000, 1_000, 28_000) == 0'u64
    check backgroundDemandMilli(31_000, 1_000, 28_000) == 2_000'u64
    # The daemon's own leases are not foreign.
    check backgroundDemandMilli(4_000, 4_000, 0) == 0'u64
    check backgroundDemandMilli(3_000, 4_000, 0) == 0'u64

  test "predicted free saturates at zero":
    check predictedFreeMilli(4_000, 1_000, 0) == 3_000'u64
    check predictedFreeMilli(4_000, 3_000, 2_000) == 0'u64

  test "a held host busy share parses, and anything else is unknown":
    var pct = -1.0
    check parseHostBusyPct("0\n", pct) and pct == 0.0
    check parseHostBusyPct("  87.5 ", pct) and pct == 87.5
    check parseHostBusyPct("100", pct) and pct == 100.0
    pct = -1.0
    for bad in ["", "  ", "busy", "-1", "100.5", "nan", "inf", "1 2"]:
      check not parseHostBusyPct(bad, pct)
    check pct == -1.0

  test "a reclaimed minimum fits the predicted free CPU exactly, no more":
    # The daemon's whole CPU decision for a reclaimed grant. Mutation: any
    # tolerance (`minimum <= free + slack`, or `<` for `<=`) breaks one of
    # these, which no end-to-end test can see below its measurement error.
    check fitsPredictedFree(3_000, 3_000'u64)
    check not fitsPredictedFree(3_001, 3_000'u64)
    check not fitsPredictedFree(1, 0'u64)
    check fitsPredictedFree(1_000, 3_000'u64)

suite "the CPU pressure gate":
  proc sample(pct: float64): CpuPressureSample =
    CpuPressureSample(available: true, someAvg10Pct: pct)

  test "starts open; closes above high; stays closed between; opens below low":
    var gate: CpuPressureGate
    check not gate.closed
    gate.observe(sample(7.0), 10.0, 5.0, 0)
    check not gate.closed          # between, from open: stays open
    gate.observe(sample(10.5), 10.0, 5.0, 500)
    check gate.closed
    check gate.closures == 1'u64
    gate.observe(sample(7.0), 10.0, 5.0, 1000)
    # Mutation: opening below HIGH instead of below low reopens here.
    check gate.closed
    gate.observe(sample(5.0), 10.0, 5.0, 1500)
    check gate.closed              # not below low
    gate.observe(sample(4.9), 10.0, 5.0, 2000)
    check not gate.closed
    check gate.allowsReclaim and gate.allowsWidening

  test "a closed gate stops reclaim and widening":
    var gate: CpuPressureGate
    gate.observe(sample(50.0), 10.0, 5.0, 0)
    check not gate.allowsReclaim
    check not gate.allowsWidening

  test "an unreadable signal stops reclaim but not widening":
    var gate: CpuPressureGate
    gate.observe(CpuPressureSample(available: false, detail: "x"), 10.0, 5.0, 0)
    check not gate.allowsReclaim
    check gate.allowsWidening
    # And it does not move the gate's state.
    gate.observe(sample(50.0), 10.0, 5.0, 500)
    gate.observe(CpuPressureSample(available: false), 10.0, 5.0, 1000)
    check gate.closed

  test "readings are rate limited":
    var gate: CpuPressureGate
    check gate.due(0)
    gate.observe(sample(1.0), 10.0, 5.0, 1_000)
    check not gate.due(1_000 + CpuPressureReadIntervalMillis - 1)
    check gate.due(1_000 + CpuPressureReadIntervalMillis)

suite "the PSI reader":
  test "the some line's avg10":
    let text = "some avg10=12.34 avg60=1.00 avg300=0.10 total=123\n" &
      "full avg10=99.00 avg60=0.00 avg300=0.00 total=0\n"
    let s = parseCpuPressure(text)
    check s.available
    check abs(s.someAvg10Pct - 12.34) < 1e-9

  test "malformed input is unavailable, never a number":
    check not parseCpuPressure("").available
    check not parseCpuPressure("full avg10=1.0\n").available
    check not parseCpuPressure("some avg60=1.0\n").available
    check not parseCpuPressure("some avg10=abc\n").available
    check not parseCpuPressure("some avg10=101.0\n").available
    check not parseCpuPressure("some avg10=-1\n").available
    check not readCpuPressure("/nonexistent/pressure").available

  test "the kernel's own file parses":
    if fileExists(DefaultCpuPressureFile):
      let s = readCpuPressure(DefaultCpuPressureFile)
      checkpoint s.detail
      check s.available
      check s.someAvg10Pct >= 0.0 and s.someAvg10Pct <= 100.0
    else:
      echo "no ", DefaultCpuPressureFile, " on this host: the kernel has no PSI"

suite "the host file's predictive keys":
  proc parsed(admission: string): HostConfig =
    parseHostConfig("schema = \"runquota.host-config.v1\"\n[admission]\n" &
      admission, "host.toml")

  test "absent keys are absent":
    let host = parsed("")
    check host.admissionPredictive.isNone
    check host.admissionHorizonMillis.isNone
    check host.pressureHighPct.isNone and host.pressureLowPct.isNone

  test "each key reads":
    let host = parsed("predictive = \"on\"\nhorizon = \"1500ms\"\n" &
      "pressure-high = \"20\"\npressure-low = \"2.5\"\n")
    check host.admissionPredictive == some(true)
    check host.admissionHorizonMillis == some(1500'i64)
    check host.pressureHighPct == some(20.0)
    check host.pressureLowPct == some(2.5)
    check parsed("predictive = \"off\"\n").admissionPredictive == some(false)

  test "bad values are refused":
    for bad in ["predictive = \"yes\"\n", "predictive = on\n",
                "horizon = \"0s\"\n", "horizon = \"ten\"\n",
                "pressure-high = \"101\"\n", "pressure-low = \"-1\"\n",
                "pressure-high = \"x\"\n",
                # low above high, also against the other's default
                "pressure-high = \"20\"\npressure-low = \"30\"\n",
                "pressure-high = \"4\"\n", "pressure-low = \"11\"\n"]:
      var refused = false
      try:
        discard parsed(bad)
      except HostConfigError as err:
        refused = true
        checkpoint err.msg
      checkpoint bad
      check refused

  test "config set accepts and renders the keys":
    let key = parseHostConfigKey("admission.predictive")
    check hostConfigEntry(key, "on") == "predictive = \"on\""
    check hostConfigEntry(parseHostConfigKey("admission.pressure-high"),
      "15") == "pressure-high = \"15\""
    for name in ["horizon", "pressure-low"]:
      discard parseHostConfigKey("admission." & name)
    var refused = false
    try:
      discard parseHostConfigKey("admission.reclaim")
    except HostConfigError:
      refused = true
    check refused
