## Measurement switches: the one spelling (`NAME=on|off[,...]`) shared by
## `runquotad --measurement` and the client's `RUNQUOTA_MEASUREMENT`, its
## application to the daemon's configuration, and the one client-side
## measurement that exists today, `tree-sampling`, honouring it.
##
## WHY THESE CLAUSES. The measurement overhead gate turns measurements off to
## learn what they cost. A switch that silently does nothing makes the gate
## compare two identical configurations and pass every measurement as free,
## so each switch is checked here against the behaviour it governs, not only
## against its parser:
##
## * the parser refuses a misspelt name, a value other than on/off and an
##   empty switch, and a refusal changes nothing;
## * later entries override earlier ones, and `all` covers every name;
## * `capture=off` and `ambient-sampling=off` set the daemon fields that
##   govern them, and an explicit `=on` against the older off flags is a
##   refused contradiction rather than an argument-order race;
## * with `RUNQUOTA_MEASUREMENT=tree-sampling=off` a launched child's
##   completion carries no peak memory and says the sampler was off; with
##   the default it carries a measured peak. Falsifying mutation: ignore the
##   switch in `runquota_process` (sample unconditionally) and the "off"
##   case reports a non-zero peak and fails.
##
## NO MOCKS. The real parser, the real daemon configuration type and a real
## child process launched through `runquota_process`.

import std/[os, strutils, unittest]

import runquota_core/measurement
import runquota_daemon
import runquota_ipc
import runquota_process

proc withMeasurementEnv(value: string; body: proc ()) =
  let had = existsEnv(measurementEnvVar)
  let previous = getEnv(measurementEnvVar)
  if value.len == 0: delEnv(measurementEnvVar)
  else: putEnv(measurementEnvVar, value)
  try:
    body()
  finally:
    if had: putEnv(measurementEnvVar, previous)
    else: delEnv(measurementEnvVar)

suite "measurement switch parser":
  test "names, all, and later entries override earlier ones":
    var set = defaultMeasurements()
    check applyMeasurementSwitches("all=off", set) == ""
    check set == {}
    check applyMeasurementSwitches("all=off,capture=on", set) == ""
    check set == {measureCapture}
    check applyMeasurementSwitches("capture=on, capture=off", set) == ""
    check set == {}
    check applyMeasurementSwitches(" tree-sampling = on ", set) == ""
    check set == {measureTreeSampling}

  test "refusals name the problem and change nothing":
    let before = defaultMeasurements()
    for bad in ["", "capture", "capture=", "=on", "capture=yes",
                "capture=On", "captur=off", "all=off,profile=on"]:
      var set = before
      let problem = applyMeasurementSwitches(bad, set)
      checkpoint "switch: '" & bad & "' -> " & problem
      check problem.len > 0
      check set == before
    var set = before
    check "unknown measurement 'captur'" in
      applyMeasurementSwitches("captur=off", set)

  test "explicit on and off are tracked for contradiction checks":
    var set = defaultMeasurements()
    var namedOn, namedOff: MeasurementSet
    check applyMeasurementSwitches("all=off,capture=on", set, namedOn,
      namedOff) == ""
    check measureCapture in namedOn
    check measureCapture notin namedOff
    check measureAmbientSampling in namedOff

  test "the formatted switch text reproduces the set exactly":
    for wanted in [MeasurementSet({}), defaultMeasurements(),
                   implementedMeasurements(), {measureProfiles}]:
      var parsed = defaultMeasurements()
      check applyMeasurementSwitches(formatMeasurementSwitches(wanted),
        parsed) == ""
      check parsed == wanted

  test "the registry says which measurements exist and where they are taken":
    check measurementRegistry[measureCapture].side == measuredByDaemon
    check measurementRegistry[measureTreeSampling].side == measuredByClient
    for m in [measurePressureReports, measureSizingData]:
      check not measurementRegistry[m].implemented
      # Not implemented, so not on by default: a measurement is on by
      # default only once it has passed the overhead gate.
      check not measurementRegistry[m].defaultOn
    # CPU profiles exist, are taken by the launching client, and stay off by
    # default until the overhead gate passes with them on.
    check measurementRegistry[measureProfiles].implemented
    check measurementRegistry[measureProfiles].side == measuredByClient
    check not measurementRegistry[measureProfiles].defaultOn
    check measureProfiles notin defaultMeasurements()
    check implementedMeasurements() ==
      {measureCapture, measureAmbientSampling, measureTreeSampling,
       measureProfiles, measureMetricsExport}
    check not measurementRegistry[measureMetricsExport].defaultOn

  test "a malformed client value falls back to the defaults and says why":
    var problem: string
    check clientMeasurementsFrom("", problem) == defaultMeasurements()
    check problem == ""
    check clientMeasurementsFrom("tree-sampling=off", problem) ==
      defaultMeasurements() - {measureTreeSampling}
    check problem == ""
    check clientMeasurementsFrom("tree-sampling=maybe", problem) ==
      defaultMeasurements()
    check problem.len > 0

suite "daemon measurement switches":
  test "off switches set the fields that govern the measurements":
    var config = defaultDaemonConfig(defaultEndpoint())
    check daemonMeasurements(config) ==
      {measureCapture, measureAmbientSampling}
    check config.applyDaemonMeasurementSwitches(["capture=off",
      "ambient-sampling=off"]) == ""
    check config.writeStatsDisabled
    check config.ambientSampleIntervalMillis == 0
    check daemonMeasurements(config) == {}

  test "client-side and not-yet-implemented names are accepted and inert":
    var config = defaultDaemonConfig(defaultEndpoint())
    let before = config.ambientSampleIntervalMillis
    check config.applyDaemonMeasurementSwitches(
      ["tree-sampling=off,profiles=on,pressure-reports=on"]) == ""
    check not config.writeStatsDisabled
    check config.ambientSampleIntervalMillis == before

  test "metrics-export follows the text file it writes to":
    var config = defaultDaemonConfig(defaultEndpoint())
    # Off by default: there is no file to write.
    check measureMetricsExport notin daemonMeasurements(config)
    # On names nowhere to write, so it is refused rather than inert.
    check "needs --metrics-textfile" in
      config.applyDaemonMeasurementSwitches(["metrics-export=on"])
    check "needs --metrics-textfile" in
      config.applyDaemonMeasurementSwitches(["all=on"])
    config.metricsTextfilePath = "/var/lib/textfile/runquota.prom"
    check measureMetricsExport in daemonMeasurements(config)
    check config.applyDaemonMeasurementSwitches(["metrics-export=on"]) == ""
    check config.metricsTextfilePath.len > 0
    check config.applyDaemonMeasurementSwitches(["metrics-export=off"]) == ""
    check config.metricsTextfilePath == ""
    check measureMetricsExport notin daemonMeasurements(config)

  test "an explicit on against an older off flag is refused, not ordered":
    var config = defaultDaemonConfig(defaultEndpoint())
    config.writeStatsDisabled = true
    config.ambientSampleIntervalMillis = 0
    check "contradicts --no-write-stats" in
      config.applyDaemonMeasurementSwitches(["capture=on"])
    check "contradicts --ambient-sample-interval-millis" in
      config.applyDaemonMeasurementSwitches(["ambient-sampling=on"])
    # Agreeing with the older flags is fine.
    check config.applyDaemonMeasurementSwitches(["all=off"]) == ""

  test "a refused switch leaves the configuration unchanged":
    var config = defaultDaemonConfig(defaultEndpoint())
    check config.applyDaemonMeasurementSwitches(
      ["capture=off", "bogus=off"]).len > 0
    check not config.writeStatsDisabled

when defined(linux) or defined(macosx):
  proc runChild(): ProcessCompletion =
    # Long enough for several 100 ms samples; a real resident set to see.
    var child = launchProcess(commandSpec(@["/bin/sh", "-c", "sleep 0.6"]))
    child.waitForCompletion()

  suite "tree-sampling honours its switch":
    test "off: no peak memory, and the completion says the sampler was off":
      withMeasurementEnv("tree-sampling=off") do ():
        let completion = runChild()
        check completion.exited
        check completion.peakResidentMemoryBytes == 0'u64
        check completion.telemetrySource.startsWith("off")

    test "default: a measured peak":
      withMeasurementEnv("") do ():
        let completion = runChild()
        check completion.exited
        check completion.peakResidentMemoryBytes > 0'u64
        check not completion.telemetrySource.startsWith("off")

    test "all=off turns it off too":
      withMeasurementEnv("all=off") do ():
        check runChild().peakResidentMemoryBytes == 0'u64
