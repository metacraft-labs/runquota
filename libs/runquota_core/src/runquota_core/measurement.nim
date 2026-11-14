## Measurement switches: one name per measurement RunQuota takes, and one
## spelling for turning each of them on or off.
##
## WHY A REGISTRY. Every figure RunQuota records about a build costs the build
## something: a daemon thread writing rows, a client walking `/proc` while it
## waits for its child, a profile sampled at a cadence. The budget for all of
## that together is one percent of the build's wall time and CPU time, and the
## overhead gate (`benchmarks/lib/runquota_overhead_gate.nim`) is what checks
## it. The gate can only check a measurement it can turn off, and it can only
## attribute a cost to one measurement if each can be turned off on its own.
## So every measurement is named here, once, and both the daemon flag and the
## client environment variable are parsed by the one parser below.
##
## WHO TAKES WHAT. A measurement is taken either by `runquotad` or by the
## client that launched the process tree (Reprobuild, `runquota acquire`), and
## the switch lives where the measurement is taken:
##
## * daemon-side measurements: `runquotad --measurement NAME=on|off[,...]`;
## * client-side measurements: the `RUNQUOTA_MEASUREMENT` environment variable,
##   same value syntax, read by `runquota_process` at every launch.
##
## Either spelling accepts every name, so one value can be handed to both
## sides; a switch for the other side's measurement is accepted and has no
## effect there. `all=on` / `all=off` sets every measurement, and later entries
## override earlier ones, so `all=off,capture=on` reads as written.
##
## NOT YET IMPLEMENTED IS A STATE, NOT AN ABSENCE. Measurements later work
## will add (profiles, pressure reports, sizing data, metrics export) are
## registered now, with `implemented = false`. Their switches parse and do
## nothing, and the gate reports them as not measured rather than as measured
## and free. A measurement becomes real by flipping its row here and honouring
## its switch where it is taken; no spelling changes.
##
## Static-helper library rules apply (no `ref` types): this module is imported
## by `runquota_process`, which compiles as a static library.

import std/[atomics, os, strutils]

type
  Measurement* = enum
    ## Every measurement RunQuota takes or will take. The string is the
    ## spelling used by every switch.
    measureCapture = "capture"
      ## Daemon: the observation store's execution rows, extension rows and
      ## self-report intake. `--no-write-stats` is the older spelling of
      ## `capture=off`.
    measureAmbientSampling = "ambient-sampling"
      ## Daemon: the host-wide ambient load sampler.
      ## `--ambient-sample-interval-millis 0` is the older spelling of
      ## `ambient-sampling=off`.
    measureTreeSampling = "tree-sampling"
      ## Client: the launching client's samples of its child tree's resident
      ## memory and process count while it waits for the child, which become
      ## the finish's peak memory and process count.
    measureProfiles = "profiles"
      ## Client: CPU profiles of the launched tree, sent with the finish.
    measurePressureReports = "pressure-reports"
      ## Client: build-wait pressure counters, sent to the daemon.
    measureSizingData = "sizing-data"
      ## Client: the memory profile and declarations sizing replay needs.
    measureMetricsExport = "metrics-export"
      ## Daemon: the periodic metrics text file for capacity tools.

  MeasurementSide* = enum
    ## Where a measurement is taken, and therefore where its switch is read.
    measuredByDaemon = "daemon"
    measuredByClient = "client"

  MeasurementInfo* = object
    side*: MeasurementSide
    implemented*: bool
      ## False until the measurement exists. Its switch parses and does
      ## nothing; the overhead gate reports it as not measured.
    defaultOn*: bool
      ## Whether it is taken when no switch names it. A measurement that has
      ## not passed the overhead gate is off by default.

  MeasurementSet* = set[Measurement]
    ## The measurements that are ON.

const
  measurementEnvVar* = "RUNQUOTA_MEASUREMENT"
    ## The client-side switch. Same value syntax as `runquotad --measurement`.

  measurementRegistry*: array[Measurement, MeasurementInfo] = [
    # IMPLEMENTED, AND OFF BY DEFAULT: the overhead gate measured it above
    # the budget (it costs more than the measurement budget allows). It is
    # turned back on by default only when a gate run passes with it on.
    measureCapture: MeasurementInfo(side: measuredByDaemon, implemented: true,
      defaultOn: false),
    # On by default. It writes into the observation store, so it samples
    # only while `capture` is on.
    measureAmbientSampling: MeasurementInfo(side: measuredByDaemon,
      implemented: true, defaultOn: true),
    # IMPLEMENTED, AND OFF BY DEFAULT, for the same reason as `capture`.
    # With it off a finish still carries the largest single process's peak
    # memory (`ru_maxrss`) from the completion totals.
    measureTreeSampling: MeasurementInfo(side: measuredByClient,
      implemented: true, defaultOn: false),
    # IMPLEMENTED, AND OFF BY DEFAULT until the overhead gate passes with
    # it on (see the specification's measurement switches section).
    measureProfiles: MeasurementInfo(side: measuredByClient,
      implemented: true, defaultOn: false),
    measurePressureReports: MeasurementInfo(side: measuredByClient,
      implemented: false, defaultOn: false),
    measureSizingData: MeasurementInfo(side: measuredByClient,
      implemented: false, defaultOn: false),
    # IMPLEMENTED, AND OFF BY DEFAULT: the daemon writes the file only
    # where `runquotad --metrics-textfile PATH` names one.
    measureMetricsExport: MeasurementInfo(side: measuredByDaemon,
      implemented: true, defaultOn: false),
  ]

proc defaultMeasurements*(): MeasurementSet =
  ## The measurements that are on when no switch is given.
  for m in Measurement:
    if measurementRegistry[m].defaultOn:
      result.incl(m)

proc implementedMeasurements*(): MeasurementSet =
  ## The measurements that exist and can therefore cost anything.
  for m in Measurement:
    if measurementRegistry[m].implemented:
      result.incl(m)

proc parseMeasurementName*(text: string; m: var Measurement): bool =
  ## Exact, lower-case spellings only, like every other RunQuota enum switch:
  ## a misspelt name is a refusal rather than a silently ignored switch.
  for candidate in Measurement:
    if text == $candidate:
      m = candidate
      return true
  false

proc measurementNames*(): string =
  ## Every accepted name, for diagnostics.
  var names: seq[string]
  for m in Measurement:
    names.add($m)
  names.join(", ")

proc applyMeasurementSwitches*(text: string; measurements: var MeasurementSet;
                               explicitOn, explicitOff: var MeasurementSet):
                               string =
  ## Apply `NAME=on|off[,NAME=on|off...]` to `measurements`, left to right.
  ## Returns "" on success, or why the text was refused; on refusal
  ## `measurements` is left exactly as it was, so a half-applied switch can
  ## never take effect. `explicitOn` / `explicitOff` collect what the text
  ## named (a later entry for the same name replaces an earlier one), so a
  ## caller with an older spelling of the same switch can refuse a
  ## contradiction instead of letting argument order decide.
  var working = measurements
  var namedOn = explicitOn
  var namedOff = explicitOff
  let trimmed = text.strip()
  if trimmed.len == 0:
    return "an empty measurement switch; expected NAME=on|off, NAME one " &
      "of all, " & measurementNames()
  for rawEntry in trimmed.split(','):
    let entry = rawEntry.strip()
    let eq = entry.find('=')
    if eq <= 0 or eq == entry.len - 1:
      return "measurement switch '" & entry & "' is not NAME=on|off"
    let name = entry[0 ..< eq].strip()
    let value = entry[eq + 1 .. ^1].strip()
    var on: bool
    case value
    of "on": on = true
    of "off": on = false
    else:
      return "measurement switch '" & entry & "': the value must be on " &
        "or off, got '" & value & "'"
    if name == "all":
      for m in Measurement:
        if on:
          working.incl(m)
          namedOn.incl(m)
          namedOff.excl(m)
        else:
          working.excl(m)
          namedOff.incl(m)
          namedOn.excl(m)
      continue
    var m: Measurement
    if not parseMeasurementName(name, m):
      return "unknown measurement '" & name & "'; expected all, " &
        measurementNames()
    if on:
      working.incl(m)
      namedOn.incl(m)
      namedOff.excl(m)
    else:
      working.excl(m)
      namedOff.incl(m)
      namedOn.excl(m)
  measurements = working
  explicitOn = namedOn
  explicitOff = namedOff
  ""

proc applyMeasurementSwitches*(text: string;
                               measurements: var MeasurementSet): string =
  ## As above, for a caller that does not need to know what was named.
  var namedOn, namedOff: MeasurementSet
  applyMeasurementSwitches(text, measurements, namedOn, namedOff)

proc formatMeasurementSwitches*(measurements: MeasurementSet): string =
  ## The switch text that reproduces `measurements` exactly, every name
  ## spelt out: what the overhead gate hands to both sides, and what a
  ## report prints so a reader sees the state without knowing the defaults.
  var parts: seq[string]
  for m in Measurement:
    parts.add($m & "=" & (if m in measurements: "on" else: "off"))
  parts.join(",")

proc measurementsJson*(measurements: MeasurementSet): string =
  ## `{"capture":"on",...}` over every registered measurement, with the
  ## not-yet-implemented ones reported as such rather than as on or off.
  result = "{"
  var first = true
  for m in Measurement:
    if not first:
      result.add(',')
    first = false
    let state =
      if not measurementRegistry[m].implemented: "not-implemented"
      elif m in measurements: "on"
      else: "off"
    result.add("\"" & $m & "\":\"" & state & "\"")
  result.add('}')

proc clientMeasurementsFrom*(value: string; problem: var string):
    MeasurementSet =
  ## The client-side measurement set for an environment value: the defaults
  ## with `value` applied. An unset (empty) value is the defaults. A value
  ## that does not parse yields the defaults and says why in `problem`; the
  ## caller decides whether to warn. A client does not refuse to run a build
  ## over a malformed measurement switch, because the switch governs
  ## bookkeeping about the work, never the work.
  problem = ""
  result = defaultMeasurements()
  if value.len == 0:
    return
  var parsed = result
  problem = applyMeasurementSwitches(value, parsed)
  if problem.len == 0:
    result = parsed

var malformedSwitchReported: Atomic[bool]
  ## Set once a malformed `RUNQUOTA_MEASUREMENT` has been reported, so a build
  ## of a thousand actions says it once rather than a thousand times.

proc clientMeasurements*(): MeasurementSet =
  ## The client-side measurement set from `RUNQUOTA_MEASUREMENT`. Read at
  ## every call, which is once per launch: an environment lookup is far
  ## below anything a launch costs, and caching it would make a test that
  ## changes the variable between launches see a stale answer.
  var problem: string
  result = clientMeasurementsFrom(getEnv(measurementEnvVar, ""), problem)
  if problem.len > 0 and not malformedSwitchReported.exchange(true):
    try:
      stderr.writeLine("runquota: ignoring " & measurementEnvVar & ": " &
        problem & "; using the default measurements")
    except IOError:
      discard
