## The measurement overhead gate.
##
## WHAT IT ANSWERS. Every figure RunQuota records about a build (the
## observation store's rows, the ambient sampler, the launching client's
## samples of its child tree, its CPU profiles, the capacity metrics file,
## and the pressure reports and sizing data still to come) has a budget:
## with all of them on, a build may take at most 1% more wall time and 1%
## more CPU time than with all of them off. A measurement that misses the budget is off by default.
## This program is the judge: it runs a workload with the measurements off
## and on, repeatedly and interleaved, until the 95% confidence interval of
## the difference is within +-0.5%, and then passes or fails it. The
## statistics, and why they are these, are in
## `runquota_overhead_gate/statistics.nim`.
##
## HOW THE ARMS DIFFER. Only by the measurement switches
## (`runquota_core/measurement`): the OFF arm sets every measurement off, the
## ON arm sets on every measurement that is implemented (or only the one
## named by `--measure`). The same switch text goes to the daemon as
## `runquotad --measurement` and to the client as `RUNQUOTA_MEASUREMENT`. Each
## arm has its own private `runquotad`, started once, and the gate asks each
## daemon which measurements it is taking before the first round and refuses
## to run if the answer is not the arm's configuration: a gate that compared
## two identical daemons would pass every measurement, vacuously.
##
## THE MEMORY-CAP SWITCH (`--switch=memory-cap[:STAGE]`, `run-64` only).
## The per-task memory cap must add no measurable overhead, so it is judged
## one stage of its Linux mechanism at a time (`MemoryCapStage`:
## `controller`, `leaf`, `limits`, `classify`, each including the ones
## before it), with cgroup placement ON IN BOTH ARMS so only the cap
## differs. Each arm has a gate-owned cgroup root of its own, because
## enabling the memory controller on a root is itself what the first stage
## costs. The bottom arm is the cap mode off: `RUNQUOTA_MEMORY_CAP` unset,
## and the host file the launching client reads leaving `[enforcement]
## memoryCap` off. The other arms set `RUNQUOTA_MEMORY_CAP` to a per-run cap
## far above the work's need, and `RUNQUOTA_MEMORY_CAP_STAGE`, paired so
## that each comparison adds exactly one stage (`memoryCapArms`). Not
## `RUNQUOTA_MEMORY_CAP=off`: that LIFTS the cap but, where the host file
## turns the cap on, still measures the tree in a leaf of its own. Before the
## first round each arm runs one probe through `runquota run` that reports
## what its own cgroup carries, and the gate refuses to run unless each arm
## is at the level its configuration names (`memoryCapConfigProblem`): an
## ON arm whose launches apply no cap would otherwise compare two identical
## arms and pass, vacuously. The report carries each root's
## `cgroup.stat` `nr_dying_descendants` before the first round and after
## the latest run: a removed leaf whose pages are still charged lingers as
## a dying memory cgroup, which is part of what the `classify` stage costs.
##
## WINDOWS has a different mechanism and no stages: one job-wide hard limit
## (`JOB_OBJECT_LIMIT_JOB_MEMORY`, set at process creation alongside atomic
## job placement, `PROC_THREAD_ATTRIBUTE_JOB_LIST`), not several cgroup
## placement steps, so `--switch=memory-cap:STAGE` is refused there and the
## plain switch judges the whole mechanism against none, the same shape as
## Linux's own plain switch. The OFF arm leaves `RUNQUOTA_MEMORY_CAP` unset;
## the ON arm sets it to the same per-run cap Linux uses, far above the
## work's need, so the limit applies and is never reached. Before the first
## round each arm runs its own probe (`--win-memcap-probe`, this binary's
## own cargo-style self-reinvocation) that reads its own job's
## `JOB_OBJECT_LIMIT_JOB_MEMORY` back (`QueryInformationJobObject` with a
## NULL job handle: "the calling process's own job"), and the gate refuses
## to run unless each arm shows the limit its configuration names, for the
## same reason the Linux probe exists: an ON arm whose launches apply no cap
## would otherwise compare two identical arms and pass, vacuously. The
## actions themselves are this binary's own `--run64-spin` worker (also
## cargo-style), launched and joined without a POSIX shell
## (`process_cost.runMeasuredFanOut`, `WaitForMultipleObjects`) since
## `run64Script`'s shell `&`/`wait` fan-out has no portable Windows
## equivalent.
##
## THE CASES.
##
## * `reprobuild-64`: a 64-action Reprobuild build
##   (`benchmarks/fixtures/reprobuild-64-actions`) against a private
##   `runquotad`, the engine run in-process (`REPRO_DAEMON=off`) so the
##   client-side switch reaches the process that launches the actions.
## * `cargo-jobserver`: a wide cargo test under `runquota jobserver`. Not
##   available until `runquota jobserver` exists; the case refuses with exit
##   status 4 rather than passing.
## * `synthetic`: the gate's own instrument check. Each run is a child that
##   burns a fixed number of iterations, with an optional injected overhead
##   in the ON arm and an optional periodic disturbance standing in for a
##   burst of foreign load on a shared host. Its only purpose is to show that
##   the gate detects an overhead it should detect and passes one it should
##   pass.
##
## WHAT A RUN PRINTS. A JSON report (to `--out` and to stdout) with the
## verdict, both estimates and intervals, every round's figures, the switch
## text of each arm, the measurements not yet implemented (named, so nobody
## reads their absence as "free"), host load at start and end, and the
## elapsed time. Exit status: 0 pass, 1 fail, 2 usage, 3 inconclusive,
## 4 case unavailable, 5 a run could not be measured (a build failed, a
## daemon would not start).
##
## Linux is the platform this has run on most; `run-64` (plain and with
## `--switch=memory-cap`) has also run on Windows, end to end against real
## `runquota`/`runquotad` binaries. The macOS code paths compile but have
## not been run.

import std/[algorithm, cpuinfo, json, monotimes, os, strutils, tempfiles, times]

when defined(posix):
  # `std/posix` on a non-POSIX target falls back to `posix_other` (its
  # generic "every other OS" arm), which still DECLARES `Pid` and a long
  # list of POSIX procs with `importc`/`header` pragmas naming headers
  # Windows does not have -- harmless at `nim check` (a pragma alone needs
  # no header), fatal at C codegen the moment anything using them is
  # reachable. Importing it only here, instead of unconditionally as
  # before, is what keeps `Pid` resolving to `process_cost.Pid` alone on
  # Windows (imported below) instead of two ambiguous types.
  import std/posix

import runquota_client
import runquota_core/measurement
import runquota_core
import runquota_process

import runquota_overhead_gate/process_cost
import runquota_overhead_gate/statistics

type
  Arm* = enum
    armOff = "off"
    armOn = "on"

  CaseRun* = proc (arm: Arm; round: int): RunCost {.closure.}
  CaseStop* = proc () {.closure.}

  GateCase* = object
    name*: string
    run*: CaseRun
    stop*: CaseStop
    details*: JsonNode

  GateConfig* = object
    caseName*: string
    policy*: GatePolicy
    maxSeconds*: float
    measure*: string            ## "all" or one measurement name
    switch*: string
      ## "" (the arms differ by measurements) or an ENFORCEMENT switch the
      ## arms differ by instead (`cgroups`); the measurements are then the
      ## baseline in both arms.
    cliBin*: string
      ## The `runquota` CLI, for the `run-64` case.
    baseline*: MeasurementSet
      ## Measurements on in BOTH arms (`--baseline`), so the one under test
      ## is judged on top of them. Needed for a measurement that only has
      ## something to do when another is on: ambient sampling writes into
      ## the observation store, so it samples only where capture is on.
    outPath*: string
    # synthetic
    burnIterations*: int
    disturbancePercent*: float
    disturbanceEvery*: int
    syntheticChild*: string
      ## The executable that serves `--synthetic-child=N`; empty means this
      ## program. The gate's test points it at the test binary itself.
    injectPercent*: float
    # reprobuild
    daemonBin*: string
    engineBin*: string
    fixtureDir*: string
    cpuMilli*: int
    memoryBytes*: uint64
    keepScratch*: bool

  GateResult* = object
    decision*: GateDecision
    rounds*: seq[RoundSample]
    elapsedSeconds*: float
    report*: JsonNode

  CaseUnavailable* = object of CatchableError
    ## The case cannot run on this tree yet. Never a pass.

const
  exitPass* = 0
  exitFail* = 1
  exitUsage* = 2
  exitInconclusive* = 3
  exitUnavailable* = 4
  exitError* = 5

# ---------------------------------------------------------------------------
# The memory-cap switch: the arms' configuration and its check
# ---------------------------------------------------------------------------

type
  MemoryCapLevel* = enum
    ## How much of the memory cap a launched tree's own cgroup shows, as
    ## the probe run inside it sees it. `classify` adds only reads at the
    ## end of the tree, invisible from inside, so it shows as `limits`.
    mclNone = "none"
      ## No memory controller on the tree's cgroup.
    mclController = "controller"
      ## The memory controller, in the group's shared leaf.
    mclLeaf = "leaf"
      ## A `cap-` leaf of its own, `memory.max` = max.
    mclLimits = "limits"
      ## A `cap-` leaf with `memory.max` = the gate's cap and
      ## `memory.oom.group` = 1.
    mclUnknown = "unknown"
      ## Anything else (the probe failed, or another cap was applied).

  MemoryCapArm* = object
    ## One arm of a memory-cap comparison.
    cap*: string
      ## `RUNQUOTA_MEMORY_CAP` for the arm's clients; "" leaves it unset
      ## (the host file's mode decides: the bottom arm).
    stage*: string
      ## `RUNQUOTA_MEMORY_CAP_STAGE`; "" leaves it unset (the whole
      ## mechanism).
    level*: MemoryCapLevel
      ## What the configuration check must observe in the arm.

const
  GateMemoryCap* = "1G"
    ## The ON arm's per-run cap: far above what one `run-64` action (a shell
    ## loop) needs, so the cap is applied and never reached.
  GateMemoryCapBytes* = 1'u64 shl 30
  MemoryCapSwitch* = "memory-cap"

proc isMemoryCapSwitch*(switch: string): bool =
  switch == MemoryCapSwitch or switch.startsWith(MemoryCapSwitch & ":")

proc memoryCapArms*(switch: string): array[Arm, MemoryCapArm] =
  ## The two arms of `--switch=memory-cap[:STAGE]`. Each comparison adds
  ## EXACTLY ONE stage, except the plain switch, which is the whole
  ## mechanism against none of it:
  ##
  ##   switch                  OFF arm                  ON arm
  ##   memory-cap              unset                    cap 1G, all stages
  ##   memory-cap:controller   unset                    cap 1G, controller
  ##   memory-cap:leaf         cap 1G, controller       cap 1G, leaf
  ##   memory-cap:limits       cap 1G, leaf             cap 1G, limits
  ##   memory-cap:classify     cap 1G, limits           cap 1G, classify
  ##
  ## "unset" is the cap mode off: no `RUNQUOTA_MEMORY_CAP`, so the host
  ## file's mode decides, and with its `memoryCap` off (absent) the tree is
  ## placed exactly as without the feature. A per-run size is a cap in
  ## kill mode when the host file leaves the cap off. The configuration
  ## check (`memoryCapConfigProblem`) refuses a host where either arm does
  ## not show its level. ValueError for an unknown stage.
  let none = MemoryCapArm(cap: "", stage: "", level: mclNone)
  proc capped(stage: MemoryCapStage): MemoryCapArm =
    MemoryCapArm(cap: GateMemoryCap, stage: $stage, level:
      case stage
      of mcsController: mclController
      of mcsLeaf: mclLeaf
      of mcsLimits, mcsClassify: mclLimits)
  if switch == MemoryCapSwitch:
    return [none, MemoryCapArm(cap: GateMemoryCap, stage: "",
      level: mclLimits)]
  if not isMemoryCapSwitch(switch):
    raise newException(ValueError, "not a memory-cap switch: " & switch)
  let name = switch[MemoryCapSwitch.len + 1 .. ^1]
  var stage: MemoryCapStage
  if name.len == 0 or not parseMemoryCapStage(name, stage):
    raise newException(ValueError, "unknown memory-cap stage '" & name &
      "'; expected controller, leaf, limits or classify")
  case stage
  of mcsController: [none, capped(mcsController)]
  of mcsLeaf: [capped(mcsController), capped(mcsLeaf)]
  of mcsLimits: [capped(mcsLeaf), capped(mcsLimits)]
  of mcsClassify: [capped(mcsLimits), capped(mcsClassify)]

const memoryCapProbeScript* =
  "p=$(sed -n 's/^0:://p' /proc/self/cgroup); d=/sys/fs/cgroup$p; " &
  "echo \"cgroup=$p\"; if [ -e \"$d/memory.max\" ]; then echo memory=1; " &
  "echo \"max=$(cat \"$d/memory.max\")\"; " &
  "echo \"oomgroup=$(cat \"$d/memory.oom.group\")\"; else echo memory=0; fi"
  ## Run as the action of one `runquota run`: what the tree's own cgroup
  ## carries, one `key=value` per line.

proc memoryCapProbeLevel*(probeOutput: string; capBytes: uint64):
    MemoryCapLevel =
  ## The level `memoryCapProbeScript`'s output shows (`MemoryCapLevel`).
  var cgroup, memory, max, oomGroup = ""
  var seen = false
  for line in probeOutput.splitLines():
    let eq = line.find('=')
    if eq <= 0:
      continue
    let value = line[eq + 1 .. ^1].strip()
    case line[0 ..< eq]
    of "cgroup":
      cgroup = value
      seen = true
    of "memory": memory = value
    of "max": max = value
    of "oomgroup": oomGroup = value
    else: discard
  if not seen or cgroup.len == 0:
    return mclUnknown
  if memory == "0":
    return mclNone
  if memory != "1":
    return mclUnknown
  let ownLeaf = cgroup.extractFilename.startsWith(CapLeafPrefix)
  if not ownLeaf:
    return (if max == "max": mclController else: mclUnknown)
  if max == "max":
    return mclLeaf
  if max == $capBytes and oomGroup == "1":
    return mclLimits
  mclUnknown

proc memoryCapConfigProblem*(arms: array[Arm, MemoryCapArm];
                             observed: array[Arm, MemoryCapLevel]): string =
  ## "" when each arm's probe showed the level its configuration names;
  ## otherwise why the gate refuses to run. An ON arm that applies no cap
  ## (the CLI ignores the variable, the cap is off, there is no cgroup
  ## root) is the case this exists for: it would make the arms identical,
  ## and the gate would pass a cost it never measured.
  for arm in Arm:
    if observed[arm] != arms[arm].level:
      return "the " & $arm & " arm (" & MemoryCapEnvVar &
        (if arms[arm].cap.len > 0: "=" & arms[arm].cap else: " unset") & (if arms[arm].stage.len > 0: " " &
          MemoryCapStageEnvVar & "=" & arms[arm].stage else: "") &
        ") was configured for the memory cap at '" & $arms[arm].level &
        "' but its launch showed '" & $observed[arm] & "'" &
        (if arm == armOn and observed[arm] == mclNone:
          ": its launches apply no cap, so the comparison would be vacuous"
         else: "")
  ""

proc envValue(env: openArray[string]; key: string): string =
  ## The value of `key` in a `KEY=VALUE` environment list, or "".
  for entry in env:
    if entry.startsWith(key & "="):
      return entry[key.len + 1 .. ^1]
  ""

proc memoryCapSpawnPath*(arm: MemoryCapArm; launcherEnv: openArray[string]):
    string =
  ## How the arm's launchers create a capped tree, from the arm's stage and
  ## the environment they run with: `clone3` (into the leaf) from the
  ## `limits` stage on; `fork` (and the child's own join) below that stage
  ## or when `LD_PRELOAD` is set in the launcher's environment, because a
  ## raw clone3 skips the C library's fork handlers that preload shims
  ## rely on; `uncapped` for an arm with no cap. Derived, not observed: a
  ## kernel or seccomp filter that refuses clone3 also falls back to fork,
  ## which the tree cannot see from inside.
  if arm.level == mclNone:
    return "uncapped"
  if arm.level != mclLimits:
    return "fork"
  if envValue(launcherEnv, "LD_PRELOAD").len > 0: "fork" else: "clone3"

proc ldPreloadWarning*(gateEnv: openArray[string]): string =
  ## The warning the gate prints when its own environment sets
  ## `LD_PRELOAD` (an agent harness's command-trace shim, for one): its
  ## clients inherit it, so their capped trees take the fork path, and a
  ## `limits` or `classify` verdict is then a verdict on the fork, not on
  ## clone3. "" when it is not set.
  let preload = envValue(gateEnv, "LD_PRELOAD")
  if preload.len == 0:
    return ""
  "WARNING: LD_PRELOAD is set in the gate's environment (" & preload &
    "); the launchers inherit it and create capped trees with the " &
    "ordinary fork instead of clone3, so a limits or classify verdict " &
    "from this run is a verdict on the fork path"

proc nrDyingDescendants*(root: string): int =
  ## `nr_dying_descendants` of `root`'s `cgroup.stat`, -1 when unreadable.
  try:
    for line in readFile(root / "cgroup.stat").splitLines():
      let fields = line.splitWhitespace()
      if fields.len == 2 and fields[0] == "nr_dying_descendants":
        return parseInt(fields[1])
  except IOError, OSError, ValueError:
    discard
  -1

# ---------------------------------------------------------------------------
# The arms' measurement switches
# ---------------------------------------------------------------------------

proc armMeasurements*(measure: string; arm: Arm;
                      baseline: MeasurementSet = {}): MeasurementSet =
  ## OFF: the baseline (nothing by default). ON: the baseline plus every
  ## implemented measurement, or plus only `measure`.
  if arm == armOff:
    return baseline
  if measure == "all":
    return baseline + implementedMeasurements()
  var m: Measurement
  if not parseMeasurementName(measure, m):
    raise newException(ValueError, "unknown measurement '" & measure &
      "'; expected all, " & measurementNames())
  if not measurementRegistry[m].implemented:
    raise newException(CaseUnavailable, "measurement '" & measure &
      "' is not implemented yet, so it has no cost to measure")
  baseline + {m}

proc armSwitchText*(cfg: GateConfig; arm: Arm): string =
  ## The measurement switches of `arm`: the measurement under test on top
  ## of the baseline in the ON arm, or, when the gate judges an
  ## enforcement switch (`--switch`), the baseline in both arms.
  if cfg.switch.len > 0:
    formatMeasurementSwitches(cfg.baseline)
  else:
    formatMeasurementSwitches(armMeasurements(cfg.measure, arm, cfg.baseline))

proc firstArm*(round: int): Arm =
  ## Which arm a round runs first: OFF in even rounds, ON in odd ones, so an
  ## order effect (a cache warmed by whichever ran first) cancels over pairs
  ## of rounds.
  if round mod 2 == 0: armOff else: armOn

proc notImplemented(): seq[string] =
  for m in Measurement:
    if not measurementRegistry[m].implemented:
      result.add($m)

proc capabilityRecords(): seq[JsonNode] =
  ## RQE-AREQ4: a measurement this OS cannot take is reported as such, in the
  ## report and on stderr, so a verdict for "all" is never read as covering
  ## it. The CPU profile sampler reads the launcher's descendants from
  ## `/proc` on Linux and through libproc on macOS; on any other OS its
  ## switch is inert, so "all" there does not measure it.
  when not (defined(linux) or defined(macosx)):
    result.add(%*{"measurement": "profiles", "os": hostOS,
      "status": "unavailable",
      "reason": "CPU profiles are taken from /proc (Linux) or libproc " &
        "(macOS); the switch is inert on this OS, so no cost was measured " &
        "for it"})
    stderr.writeLine "capability: profiles is unavailable on " & hostOS &
      " (Linux and macOS only); not covered by this verdict"

# ---------------------------------------------------------------------------
# Synthetic case
# ---------------------------------------------------------------------------

proc burn*(iterations: int): uint64 =
  ## The synthetic child's work: a xorshift loop the optimiser cannot fold.
  var x = 0x9E3779B97F4A7C15'u64
  for _ in 0 ..< iterations:
    x = x xor (x shl 13)
    x = x xor (x shr 7)
    x = x xor (x shl 17)
  x

proc disturbed*(cfg: GateConfig; round: int; arm: Arm): bool =
  ## Whether the synthetic run of `round`/`arm` is hit by a disturbance: the
  ## arm that runs FIRST in every `disturbanceEvery`-th round, starting with
  ## round 0. A burst of foreign load lands on whatever is running, and the
  ## first run of a round is the one a burst that started between rounds
  ## catches. `disturbanceEvery` should be odd: the first arm alternates
  ## from round to round, so an odd period alternates the disturbed arm too
  ## and the disturbances cancel in the mean while still widening the
  ## interval, as real noise does.
  if cfg.disturbancePercent == 0 or cfg.disturbanceEvery <= 0 or round < 0:
    return false
  round mod cfg.disturbanceEvery == 0 and arm == firstArm(round)

proc syntheticIterations*(cfg: GateConfig; round: int; arm: Arm): int =
  ## The work of one synthetic run: the base, scaled by a disturbance when
  ## one hits it and by the injected overhead in the ON arm.
  var scale = 1.0
  if cfg.disturbed(round, arm):
    scale *= 1 + cfg.disturbancePercent / 100
  if arm == armOn:
    scale *= 1 + cfg.injectPercent / 100
  int(float(cfg.burnIterations) * scale)

proc currentEnv(): seq[string] =
  for key, value in envPairs():
    result.add(key & "=" & value)

proc syntheticCase(cfg: GateConfig; scratch: string): GateCase =
  let self = if cfg.syntheticChild.len > 0: cfg.syntheticChild
             else: getAppFilename()
  let log = scratch / "synthetic.log"
  let env = currentEnv()
  result.name = "synthetic"
  result.run = proc (arm: Arm; round: int): RunCost =
    let iterations = syntheticIterations(cfg, round, arm)
    runMeasured([self, "--synthetic-child=" & $iterations], env, "", log)
  result.stop = proc () = discard
  result.details = %*{
    "burn_iterations": cfg.burnIterations,
    "disturbance_percent": cfg.disturbancePercent,
    "disturbance_every": cfg.disturbanceEvery,
    "inject_percent": cfg.injectPercent,
  }

# ---------------------------------------------------------------------------
# Reprobuild case
# ---------------------------------------------------------------------------

type
  PrivateDaemon* = object
    pid: Pid
    socket: string
    log: string

proc socketPath*(daemon: PrivateDaemon): string =
  ## The daemon's private endpoint, for a client environment (`runEnv`).
  daemon.socket

proc daemonEnv(): seq[string] =
  ## The daemon's environment: this one, minus anything that would point it
  ## at another endpoint or change its lifetime, plus the explicit private
  ## endpoint policy and "stop when the gate exits".
  const isolation = ["RUNQUOTA_ENDPOINT_SCOPE", "RUNQUOTA_ENDPOINT_OWNER_UID",
    "RUNQUOTA_ENDPOINT_GROUP", "RUNQUOTA_SOCKET", "RUNQUOTA_USER_ENDPOINT_DIR",
    "RUNQUOTA_EXIT_WITH_PARENT", "RUNQUOTA_EXIT_WITH_PARENT_PID",
    "RUNQUOTA_MEASUREMENT", "LISTEN_PID", "LISTEN_FDS", "LISTEN_FDNAMES"]
  for key, value in envPairs():
    if key notin isolation:
      result.add(key & "=" & value)
  when not defined(windows):
    # Windows has no `private` endpoint scope; `startDaemon`'s named-pipe
    # socket name already gives each arm's daemon the same isolation this
    # gives on POSIX (`runquota_ipc`: "private RunQuota endpoints require
    # POSIX").
    result.add("RUNQUOTA_ENDPOINT_SCOPE=private")
  result.add("RUNQUOTA_EXIT_WITH_PARENT=1")

proc inspectObservations(socket: string): JsonNode =
  ## Ask the daemon at `socket` for its observation report. Uses a real
  ## Hello exchange: a bare connect-and-close is not a client.
  let previousSocket = getEnv("RUNQUOTA_SOCKET", "")
  let hadScope = existsEnv("RUNQUOTA_ENDPOINT_SCOPE")
  let previousScope = getEnv("RUNQUOTA_ENDPOINT_SCOPE", "")
  putEnv("RUNQUOTA_SOCKET", socket)
  when not defined(windows):
    # No `private` scope on Windows; `socket` is already a named pipe
    # unique to this arm (`startDaemon`), so the default `host` scope gives
    # the same isolation.
    putEnv("RUNQUOTA_ENDPOINT_SCOPE", "private")
  defer:
    putEnv("RUNQUOTA_SOCKET", previousSocket)
    if hadScope: putEnv("RUNQUOTA_ENDPOINT_SCOPE", previousScope)
    else: delEnv("RUNQUOTA_ENDPOINT_SCOPE")
  var client = connectDefault()
  defer: client.close()
  parseJson(client.inspectionJson("observations"))

proc stopDaemon*(daemon: PrivateDaemon) =
  ## Ends a daemon THIS GATE started, by its pid: a soft terminate (SIGTERM
  ## on POSIX; Windows has no softer-than-`TerminateProcess` signal, so
  ## `daemonTerminate`/`daemonKillNow` do the same thing there), then a
  ## hard one if it has not exited within 20 s, and reaps it. A pid of 0
  ## (never started, or already reaped) is nothing to stop. Raises nothing,
  ## so it is safe in a `finally` that must not mask the exception being
  ## propagated.
  if daemon.pid <= 0:
    return
  daemonTerminate(daemon.pid)
  let deadline = getMonoTime() + initDuration(seconds = 20)
  while getMonoTime() < deadline:
    if daemonTryReap(daemon.pid):
      return
    sleep(50)
  daemonKillNow(daemon.pid)
  daemonReapBlocking(daemon.pid)

const DaemonReadyMillis* = 60_000
  ## How long `startDaemon` waits for a daemon to answer by default.

proc startDaemon*(cfg: GateConfig; root: string; arm: Arm; switches: string;
                  readyBudgetMillis = DaemonReadyMillis): PrivateDaemon =
  ## Starts the arm's private `runquotad` in `root / $arm` and returns it
  ## once it answers an observation inspection, waiting at most
  ## `readyBudgetMillis` (a parameter so a test can drive the real daemon
  ## past its deadline).
  ##
  ## THE HELPER OWNS THE DAEMON UNTIL IT RETURNS. The caller receives the
  ## pid only from the return value, so a daemon this proc has spawned and
  ## then leaves by an exception -- the wait running out while it is still
  ## starting, a refused inspection, or a Defect -- is stopped here, and the
  ## arm directory, which this proc created and only the daemon has used, is
  ## removed. Before this, the wait raised with the daemon still running and
  ## nobody holding its pid (reprobuild-pm
  ## `issues/2026-11-21-runquota-benchmark-harnesses-leak-a-running-daemon-when-start-up-fails.md`;
  ## the rule is `spec/Benchmark-Designs/Shared-Benchmark-Design-Guidelines.md`,
  ## "Processes A Harness Starts"). A `finally` guarded by a flag rather than
  ## `except CatchableError`, so a Defect is covered too, and nothing in the
  ## cleanup raises over the exception being propagated.
  let dir = root / $arm
  let createdDir = not dirExists(dir)
  var handedBack = false
  try:
    createDir(dir)
    when defined(windows):
      # Windows has no `private` endpoint scope (`runquota_ipc`: "private
      # RunQuota endpoints require POSIX") -- the transport there is a
      # named pipe under the default `host` scope instead of a filesystem
      # socket, isolated the way `tests/support/windows_daemon_fixture.nim`
      # isolates one: a name no concurrent run collides with.
      result.socket = r"\\.\pipe\runquota-gate-" & $getCurrentProcessId() &
        "-" & $arm & "-" & $getMonoTime().ticks
    else:
      # The daemon refuses an endpoint directory anyone else could enter.
      setFilePermissions(dir, {fpUserRead, fpUserWrite, fpUserExec})
      result.socket = dir / "rq.sock"
      if result.socket.len > 100:
        raise newException(ValueError, "socket path too long for a Unix " &
          "socket (" & $result.socket.len & " bytes): " & result.socket &
          "; set TMPDIR to a shorter directory")
    result.log = dir / "runquotad.log"
    var args = @[cfg.daemonBin,
      "--socket", result.socket,
      "--host-config", dir / "host.toml",
      "--host-identity-file", dir / "host-id",
      "--observation-db", dir / "observations.sqlite3",
      "--estimate-db", dir / "estimates.sqlite3",
      "--cpu-milli", $cfg.cpuMilli,
      "--memory-bytes", $cfg.memoryBytes,
      "--measurement", switches]
    # `metrics-export` writes a file only where one is named, and refuses an
    # `=on` that names none; the arm that takes it writes into its own
    # directory, at the daemon's default cadence.
    var parsed: MeasurementSet
    if applyMeasurementSwitches(switches, parsed) == "" and
        measureMetricsExport in parsed:
      args.add(["--metrics-textfile", dir / "runquota.prom"])
    result.pid = spawnChild(args, daemonEnv(), dir, result.log)
    let deadline = getMonoTime() +
      initDuration(milliseconds = readyBudgetMillis)
    var lastError = ""
    while getMonoTime() < deadline:
      if daemonTryReap(result.pid):
        # Reaped here: the pid is no longer this daemon's, and the cleanup
        # below must not signal whatever process reuses it.
        result.pid = 0
        raise newException(OSError, "runquotad (" & $arm & ") exited " &
          "during start-up; log " & result.log & ":\n" & readFile(result.log))
      try:
        discard inspectObservations(result.socket)
        handedBack = true
        return
      except CatchableError as err:
        lastError = err.msg
        sleep(50)
    raise newException(OSError, "runquotad (" & $arm & ") did not answer at " &
      result.socket & " within " & $readyBudgetMillis & " ms: " & lastError)
  finally:
    if not handedBack:
      stopDaemon(result)
      # Reaped now. Should the compiler have built `result` in the caller's
      # own location (a return-value optimisation), the caller must not find
      # this pid there and signal whatever process reuses it.
      result.pid = 0
      if createdDir:
        try: removeDir(dir)
        except CatchableError: discard

proc verifyDaemonMeasurements(daemon: PrivateDaemon; arm: Arm;
                              wanted: MeasurementSet): JsonNode =
  ## The daemon's own account of the measurements it takes must be the
  ## arm's, for every implemented daemon-side measurement.
  let report = inspectObservations(daemon.socket)
  let reported = report{"observations", "measurements"}
  if reported.isNil:
    raise newException(OSError, "runquotad (" & $arm & ") does not report " &
      "its measurements; it predates the measurement switches")
  for m in Measurement:
    let info = measurementRegistry[m]
    if not info.implemented or info.side != measuredByDaemon:
      continue
    let expected = if m in wanted: "on" else: "off"
    let actual = reported{$m}.getStr("")
    if actual != expected:
      raise newException(OSError, "runquotad (" & $arm & ") reports " & $m &
        "=" & actual & ", the arm configured " & expected)
  reported

proc settledDaemonCpuSeconds(pid: Pid): float =
  ## The daemon's CPU once it has finished the work this run gave it.
  ##
  ## THE DAEMON'S TAIL BELONGS TO THE RUN. The build exits once its finishes
  ## are acknowledged, but the daemon writes their rows and republishes their
  ## aggregates on background threads after that. Read at the build's exit,
  ## that tail would land in the window of whichever arm runs next, where
  ## nobody counts it (each arm reads only its own daemon), and the gate
  ## would undercount exactly the cost it exists to find. So the reading is
  ## taken once the daemon's CPU counter has stood still for
  ## `quietMillis`, which is many times the aggregate publisher's cadence;
  ## an idle daemon reaches that at once, so the wait costs nothing in the
  ## OFF arm. A daemon that never goes quiet (it should: the gate's
  ## daemons serve nobody else) is read at `capMillis`, and the run counts
  ## everything it did until then.
  const
    pollMillis = 50
    quietMillis = 500
    capMillis = 10_000
  var last = processCpuSeconds(pid)
  var quietFor = 0
  var waited = 0
  while quietFor < quietMillis and waited < capMillis:
    sleep(pollMillis)
    waited += pollMillis
    let now = processCpuSeconds(pid)
    if now == last:
      quietFor += pollMillis
    else:
      quietFor = 0
      last = now
  last

proc engineHonoursClientSwitch(engine: string): bool =
  ## Whether the engine binary carries the client-side switch's variable
  ## name. An engine built against a RunQuota older than the switches
  ## ignores `RUNQUOTA_MEASUREMENT`, and its ON and OFF arms would take the
  ## same client-side measurements: the gate refuses that rather than
  ## reporting a client-side cost of zero.
  try:
    readFile(engine).contains(measurementEnvVar)
  except IOError:
    false

proc copyFixture(source, dest: string) =
  createDir(dest)
  for kind, path in walkDir(source):
    if kind == pcFile:
      copyFile(path, dest / path.extractFilename)

proc reprobuildEnv(root: string; arm: Arm; socket, switches: string):
    seq[string] =
  ## The engine's environment. Everything it would share with the user's
  ## own builds -- the build daemon, the stores, the action cache, the
  ## RunQuota endpoint -- is redirected into this arm's scratch.
  const dropped = ["RUNQUOTA_SOCKET", "RUNQUOTA_MEASUREMENT",
    "RUNQUOTA_ENDPOINT_SCOPE", "REPRO_DAEMON", "REPROBUILD_NO_RUNQUOTA",
    "REPROBUILD_AUTO_RUNQUOTA", "REPROBUILD_WORK_ROOT",
    "REPROBUILD_ACTION_CACHE_ROOT", "REPROBUILD_STORE_ROOT",
    "REPRO_STORE_ROOT", "REPRO_LOCAL_STORE", "REPRO_CACHE_DISABLE"]
  for key, value in envPairs():
    if key notin dropped:
      result.add(key & "=" & value)
  let dir = root / $arm
  result.add("RUNQUOTA_SOCKET=" & socket)
  when not defined(windows):
    result.add("RUNQUOTA_ENDPOINT_SCOPE=private")
  result.add("RUNQUOTA_MEASUREMENT=" & switches)
  # IN-PROCESS. A persistent build daemon keeps the environment it was
  # started with, so the client-side switch would never reach the process
  # that launches the actions; and it would never auto-spawn a daemon of
  # its own, which would leave the arm's daemon unmeasured.
  result.add("REPRO_DAEMON=off")
  result.add("REPROBUILD_AUTO_RUNQUOTA=0")
  result.add("REPRO_CACHE_DISABLE=1")
  result.add("REPROBUILD_WORK_ROOT=" & dir / "work")
  result.add("REPROBUILD_ACTION_CACHE_ROOT=" & dir / "action-cache")
  for key in ["REPROBUILD_STORE_ROOT", "REPRO_STORE_ROOT",
              "REPRO_LOCAL_STORE"]:
    result.add(key & "=" & dir / "store")

const fixtureActionCount = 64
  ## `benchmarks/fixtures/reprobuild-64-actions/repro.nim`'s `actionCount`.

proc reprobuildCase(cfg: GateConfig; scratch: string): GateCase =
  if cfg.switch.len > 0:
    # Reprobuild's per-action launches do not place their trees, so both
    # arms would run the same build and the gate would pass a cost it never
    # measured.
    raise newException(CaseUnavailable, "the reprobuild-64 case cannot " &
      "judge --switch=" & cfg.switch & ": Reprobuild's actions are not " &
      "placed in cgroups; use --case=run-64")
  for (label, path) in [("runquotad", cfg.daemonBin),
                        ("reprobuild engine", cfg.engineBin)]:
    if path.len == 0 or not fileExists(path):
      raise newException(CaseUnavailable, "the " & label &
        " binary is missing: '" & path & "'")
  if not fileExists(cfg.fixtureDir / "repro.nim"):
    raise newException(CaseUnavailable, "no fixture at " & cfg.fixtureDir)
  let clientSide = block:
    var any = false
    for m in armMeasurements(cfg.measure, armOn, cfg.baseline):
      if measurementRegistry[m].side == measuredByClient:
        any = true
    any
  if clientSide and not engineHonoursClientSwitch(cfg.engineBin):
    raise newException(CaseUnavailable, cfg.engineBin & " does not read " &
      measurementEnvVar & ": it was built against a RunQuota without the " &
      "measurement switches. Rebuild it with RUNQUOTA_SRC pointing at this " &
      "checkout")
  var daemons: array[Arm, PrivateDaemon]
  # THE CASE OWNS ITS DAEMONS UNTIL IT RETURNS. `main` stops a case only
  # once `makeCase` has handed it back, so a failure after the first arm's
  # daemon is up -- the second arm's start-up, a refused measurement check, a
  # fixture copy -- stops every daemon already started before it propagates
  # (reprobuild-pm
  # `issues/2026-11-21-runquota-benchmark-harnesses-leak-a-running-daemon-when-start-up-fails.md`).
  # An arm that never started holds pid 0, which `stopDaemon` skips.
  # A `defer` (a `finally` over the rest of the proc), so a Defect is
  # covered too.
  var handedBack = false
  defer:
    if not handedBack:
      for arm in Arm:
        stopDaemon(daemons[arm])
  var reported = newJObject()
  var switches: array[Arm, string]
  var projects: array[Arm, string]
  for arm in Arm:
    switches[arm] = formatMeasurementSwitches(armMeasurements(cfg.measure, arm, cfg.baseline))
    daemons[arm] = startDaemon(cfg, scratch, arm, switches[arm])
    reported[$arm] = verifyDaemonMeasurements(daemons[arm], arm,
      armMeasurements(cfg.measure, arm, cfg.baseline))
    projects[arm] = scratch / $arm / "project"
    copyFixture(cfg.fixtureDir, projects[arm])
  let engine = cfg.engineBin
  result.name = "reprobuild-64"
  result.run = proc (arm: Arm; round: int): RunCost =
    let daemon = daemons[arm]
    let before = processCpuSeconds(daemon.pid)
    let log = scratch / $arm / "build.log"
    result = runMeasured(
      [engine, "build", "--tool-provisioning=path", "--log=summary"],
      reprobuildEnv(scratch, arm, daemon.socket, switches[arm]),
      projects[arm], log)
    let after = settledDaemonCpuSeconds(daemon.pid)
    result.daemonCpuSeconds = after - before
    result.cpuSeconds += result.daemonCpuSeconds
    # A BUILD THAT RAN NOTHING IS NOT A MEASUREMENT. A cache hit, or a
    # recipe that lowered to fewer actions, would compare two cheap runs and
    # call the difference the measurements' cost; the scheduler's own count
    # is the check.
    var ranAll = false
    try:
      ranAll = ("scheduler: actions=" & $fixtureActionCount) in readFile(log)
    except IOError:
      discard
    if result.exitStatus == 0 and not ranAll:
      raise newException(OSError, "the " & $arm & " build (round " &
        $round & ") did not schedule " & $fixtureActionCount &
        " actions; see " & log)
    if result.exitStatus != 0:
      var tail = ""
      try:
        let lines = readFile(log).splitLines()
        tail = lines[max(0, lines.len - 30) .. ^1].join("\n")
      except IOError:
        discard
      raise newException(OSError, "the " & $arm & " build (round " & $round &
        ") exited " & $result.exitStatus & "; " & log & ":\n" & tail)
  result.stop = proc () =
    for arm in Arm:
      stopDaemon(daemons[arm])
  result.details = %*{
    "engine": cfg.engineBin,
    "daemon": cfg.daemonBin,
    "fixture": cfg.fixtureDir,
    "cpu_milli": cfg.cpuMilli,
    "memory_bytes": $cfg.memoryBytes,
    "daemon_reported_measurements": reported,
  }
  handedBack = true

# ---------------------------------------------------------------------------
# run-64: the same 64 actions, each through `runquota run`
# ---------------------------------------------------------------------------
#
# WHY. Cgroup placement is done by RunQuota's own launchers (`runquota run`,
# `acquire -- CMD`, `jobserver`), not by Reprobuild's per-action launches,
# so the Reprobuild case never exercises it. This case runs the Reprobuild
# fixture's work -- 64 actions of the same shell loop -- with each action
# launched by `runquota run`, all 64 started at once and queued by the arm's
# daemon against the case's budget, so every action pays the whole launcher
# path, placement included when it is on.

const
  run64ActionCount = 64
  run64LoopTurns = 150_000
    ## `benchmarks/fixtures/reprobuild-64-actions/repro.nim`'s `iterations`.
  migrationProbeSamples = 300

proc run64Script(cli: string): string =
  ## The driver: start 64 `runquota run` processes, wait for each, fail if
  ## any failed. Each action writes its loop count to `out-N.txt`, which the
  ## case counts and removes after the run.
  "fail=0; pids=''; i=0; while [ $i -lt " & $run64ActionCount & " ]; do " &
    quoteShell(cli) & " run --width 1 --adapter none -- sh -c " &
    quoteShell("j=0; while [ $j -lt " & $run64LoopTurns &
      " ]; do j=$((j+1)); done; echo $j > out-$0.txt") & " $i & " &
    "pids=\"$pids $!\"; i=$((i+1)); done; " &
    "for p in $pids; do wait $p || fail=1; done; exit $fail"

proc gateCgroupRoot(): string =
  ## A gate-owned cgroup root below this user's delegated subtree, beside
  ## `runquota.slice`, or "". cgroup v2 is Linux-only; callers already treat
  ## "" (no root) as a reason to refuse `--switch=cgroups`
  ## (`CaseUnavailable`) or, for `--switch=memory-cap`, as "this OS enforces
  ## the cap by a different mechanism" (Windows: a Job Object). Resolved as
  ## a launcher would (with the agent session's marker, so a gate run from
  ## an agent session keeps its root), read-only: the gate asks no manager
  ## and writes nothing. A gate under another limited cgroup would have its
  ## clients' trees held inside that cgroup, not beside `runquota.slice`, so
  ## it gets no root.
  when defined(linux):
    let own = try: readFile("/proc/self/cgroup") except IOError, OSError: ""
    let default = resolveCgroupRoot("", own, int(getuid()),
      hostSwitchOn = true, agentScope = getEnv(AgentSessionScopeEnvVar).strip(),
      mayAsk = false)
    if not default.usable or default.holder.len > 0:
      return ""
    default.path.parentDir / ("runquota-gate-" & $getpid() & ".slice")
  else:
    ""

proc removeGateCgroups(root: string) =
  ## Remove the gate's root once its trees are gone, deepest first. Kills
  ## nothing: every tree in it was this gate's and has exited.
  if root.len == 0 or not dirExists(root):
    return
  var dirs: seq[string]
  for path in walkDirRec(root, yieldFilter = {pcDir}, followFilter = {pcDir}):
    dirs.add(path)
  dirs.sort(proc (a, b: string): int = cmp(b.len, a.len))
  dirs.add(root)
  for dir in dirs:
    for _ in 0 ..< 200:
      if removeEmptyCgroup(dir): break
      sleep(50)

proc migrationProbe(root: string): JsonNode =
  ## The migration alone: fork `migrationProbeSamples` children, one at a
  ## time, each writing itself into a gate-owned leaf's `cgroup.procs` and
  ## timing that one write (the step that takes the kernel's cgroup
  ## threadgroup lock for writing), reported to the parent on a pipe.
  ## cgroup v2 is Linux-only; `--switch=cgroups` (this proc's only caller)
  ## already refuses on every other OS for want of a delegated subtree
  ## (`CaseUnavailable`), so the non-Linux arm below should never run --
  ## it exists so the file compiles everywhere, not to be reached.
  when defined(linux):
    let target = targetFor(CgroupRoot(state: crsExplicit, path: root),
      "migration-probe", sessionPriorityNormal, reclaimed = false)
    var problem = ""
    if not prepareTarget(target, problem):
      raise newException(OSError, "migration probe: " & problem)
    var samples: seq[int64]
    for i in 0 ..< migrationProbeSamples:
      let fd = posix.open(cstring(target.leafPath / "cgroup.procs"),
        O_WRONLY or O_CLOEXEC)
      if fd < 0:
        raise newException(OSError, "migration probe: cannot open the leaf")
      var fds: array[0..1, cint]
      if pipe(fds) != 0:
        raise newException(OSError, "migration probe: pipe")
      let pid = fork()
      if pid == 0:
        let t0 = getMonoTime().ticks
        let ok = posix.write(fd, cstring("0"), 1) == 1
        var elapsed = getMonoTime().ticks - t0
        if not ok: elapsed = -1
        discard posix.write(fds[1], addr elapsed, sizeof(elapsed))
        exitnow(0)
      discard posix.close(fds[1])
      discard posix.close(fd)
      var elapsed = -1'i64
      discard posix.read(fds[0], addr elapsed, sizeof(elapsed))
      discard posix.close(fds[0])
      var status: cint
      discard waitpid(pid, status, 0)
      if elapsed < 0:
        raise newException(OSError, "migration probe: a child could not join")
      samples.add(elapsed)
    discard removeEmptyCgroup(target.leafPath)
    discard removeEmptyCgroup(target.dirPath)
    samples.sort()
    var total = 0'i64
    for x in samples: total += x
    proc at(q: float): int64 = samples[min(samples.high, int(q * float(samples.len)))]
    %*{"samples": samples.len, "unit": "microseconds",
       "mean": float(total) / float(samples.len) / 1000.0,
       "median": float(at(0.5)) / 1000.0, "p90": float(at(0.9)) / 1000.0,
       "p99": float(at(0.99)) / 1000.0, "max": float(samples[^1]) / 1000.0}
  else:
    raise newException(OSError,
      "migration probe: cgroup v2 is Linux-only (reached on " & hostOS & ")")

proc runEnv*(socket, switches, cgroupRoot: string; qos = "";
            memoryCap = MemoryCapArm()): seq[string] =
  ## A `runquota run` client's environment for one arm: the arm's daemon,
  ## its measurement switches and its cgroup root, for `--switch=qos` the
  ## macOS priority-policy switch (`RUNQUOTA_QOS`: `off` / `on`), and for
  ## `--switch=memory-cap` the arm's per-run cap and stage; no session
  ## group, parent lease, or memory-cap setting inherited from whoever
  ## started the gate.
  const dropped = ["RUNQUOTA_SOCKET", "RUNQUOTA_MEASUREMENT",
    "RUNQUOTA_ENDPOINT_SCOPE", "RUNQUOTA_CGROUP_ROOT", "RUNQUOTA_QOS",
    "RUNQUOTA_SESSION",
    "RUNQUOTA_SESSION_PRIORITY", "RUNQUOTA_SESSION_CACHE_TTL",
    "RUNQUOTA_PARENT_LEASE", MemoryCapEnvVar, MemoryCapStageEnvVar]
  for key, value in envPairs():
    if key notin dropped:
      result.add(key & "=" & value)
  result.add("RUNQUOTA_SOCKET=" & socket)
  when not defined(windows):
    result.add("RUNQUOTA_ENDPOINT_SCOPE=private")
  result.add("RUNQUOTA_MEASUREMENT=" & switches)
  result.add("RUNQUOTA_CGROUP_ROOT=" & cgroupRoot)
  if qos.len > 0:
    result.add("RUNQUOTA_QOS=" & qos)
  if memoryCap.cap.len > 0:
    result.add(MemoryCapEnvVar & "=" & memoryCap.cap)
  if memoryCap.stage.len > 0:
    result.add(MemoryCapStageEnvVar & "=" & memoryCap.stage)

proc probeMemoryCapLevel*(cli: string; env: seq[string]; dir: string):
    tuple[level: MemoryCapLevel, output: string] =
  ## One `runquota run` of `memoryCapProbeScript` in an arm's environment:
  ## the level its tree's cgroup showed, and the probe's output.
  let log = dir / "memory-cap-probe.log"
  let cost = runMeasured([cli, "run", "--width", "1", "--adapter", "none",
    "--", "/bin/sh", "-c", memoryCapProbeScript], env, dir, log)
  result.output = try: readFile(log) except IOError, OSError: ""
  result.level =
    if cost.exitStatus != 0: mclUnknown
    else: memoryCapProbeLevel(result.output, GateMemoryCapBytes)

proc winMemoryCapProbeLevel(probeOutput: string; capBytes: uint64):
    MemoryCapLevel =
  ## `serveWinMemCapProbe`'s output, read the way `memoryCapProbeLevel`
  ## reads the Linux probe's: one `key=value` per line.
  var hasLimit = false
  var limitBytes = 0'u64
  var seenHasLimit = false
  for line in probeOutput.splitLines():
    let eq = line.find('=')
    if eq <= 0:
      continue
    let value = line[eq + 1 .. ^1].strip()
    case line[0 ..< eq]
    of "has_limit":
      hasLimit = value == "1"
      seenHasLimit = true
    of "limit_bytes":
      limitBytes = try: parseBiggestUInt(value) except ValueError: 0'u64
    else: discard
  if not seenHasLimit:
    return mclUnknown
  if not hasLimit:
    return mclNone
  if limitBytes == capBytes: mclLimits else: mclUnknown

proc probeMemoryCapLevelWindows(cli, self: string; env: seq[string];
                                dir: string):
    tuple[level: MemoryCapLevel; output: string] =
  ## One `runquota run` of `--win-memcap-probe` in an arm's environment:
  ## the level its own job showed, and the probe's output -- the Windows
  ## sibling of `probeMemoryCapLevel`.
  let log = dir / "memory-cap-probe.log"
  let cost = runMeasured([cli, "run", "--width", "1", "--adapter", "none",
    "--", self, "--win-memcap-probe"], env, dir, log)
  result.output = try: readFile(log) except IOError, OSError: ""
  result.level =
    if cost.exitStatus != 0: mclUnknown
    else: winMemoryCapProbeLevel(result.output, GateMemoryCapBytes)

proc run64RunWindows(cfg: GateConfig; arm: Arm; daemon: PrivateDaemon;
                     env: seq[string]; dir, self: string): RunCost =
  ## `run64CaseWindowsMemoryCap`'s one round: `run64ActionCount` actions,
  ## each this binary's own `--run64-spin` worker launched by `runquota
  ## run`, started together and joined (`process_cost.runMeasuredFanOut`)
  ## -- `run64Script`'s shell `&`/`wait` fan-out, without a POSIX shell.
  var argvs: seq[seq[string]]
  for i in 0 ..< run64ActionCount:
    argvs.add(@[cfg.cliBin, "run", "--width", "1", "--adapter", "none",
      "--", self, "--run64-spin", $run64LoopTurns,
      dir / ("out-" & $i & ".txt")])
  let before = processCpuSeconds(daemon.pid)
  # `runMeasuredFanOut` exists on Windows only; this round is reached only
  # from `run64Case`'s Windows branch, and the guard keeps the gate
  # compiling everywhere else.
  when defined(windows):
    result = runMeasuredFanOut(argvs, env, dir, dir)
  else:
    raise newException(OSError, "run64RunWindows is the Windows driver; " &
      "it is never reached on " & hostOS)
  let after = settledDaemonCpuSeconds(daemon.pid)
  result.daemonCpuSeconds = after - before
  result.cpuSeconds += result.daemonCpuSeconds
  var ran = 0
  for kind, path in walkDir(dir):
    if kind == pcFile and path.extractFilename.startsWith("out-"):
      if readFile(path).strip() == $run64LoopTurns: inc ran
      removeFile(path)
  if result.exitStatus != 0 or ran != run64ActionCount:
    raise newException(OSError, "the " & $arm & " run had " &
      $result.exitStatus & " failing action(s) and " & $ran & " of " &
      $run64ActionCount & " actions done; logs under " & dir)

proc run64CaseWindowsMemoryCap(cfg: GateConfig; scratch: string): GateCase =
  ## `--switch=memory-cap` on Windows. No stages: the mechanism has none --
  ## one job-wide hard limit, set or not, not several cgroup-placement
  ## steps -- so this judges the whole mechanism in one comparison. The OFF
  ## arm leaves `RUNQUOTA_MEMORY_CAP` unset; the ON arm sets it to
  ## `GateMemoryCap`, far above what one run-64 action needs, so the cap
  ## applies (`JOB_OBJECT_LIMIT_JOB_MEMORY`) and is never reached -- the
  ## same "applied, never breached" shape the Linux arms use (module
  ## header, THE MEMORY-CAP SWITCH).
  let memoryArms = memoryCapArms(MemoryCapSwitch)
  var daemons: array[Arm, PrivateDaemon]
  var handedBack = false
  defer:
    if not handedBack:
      for arm in Arm: stopDaemon(daemons[arm])
  var switches: array[Arm, string]
  var dirs: array[Arm, string]
  let self = getAppFilename()
  for arm in Arm:
    switches[arm] = armSwitchText(cfg, arm)
    daemons[arm] = startDaemon(cfg, scratch, arm, switches[arm])
    dirs[arm] = scratch / $arm / "work"
    createDir(dirs[arm])
  proc armEnv(arm: Arm): seq[string] =
    runEnv(daemons[arm].socket, switches[arm], "", "", memoryArms[arm])
  # THE MEMORY-CAP CONFIGURATION CHECK, before the first round: as on
  # Linux, each arm's launch must show the level its configuration names,
  # or the run is refused -- never a pass (an ON arm applying no cap would
  # compare two identical arms).
  var observed: array[Arm, MemoryCapLevel]
  var outputs: array[Arm, string]
  for arm in Arm:
    (observed[arm], outputs[arm]) = probeMemoryCapLevelWindows(cfg.cliBin,
      self, armEnv(arm), dirs[arm])
  let problem = memoryCapConfigProblem(memoryArms, observed)
  if problem.len > 0:
    raise newException(CaseUnavailable, "memory-cap configuration check: " &
      problem & "; probe output: off: " &
      outputs[armOff].strip().replace("\n", " ") & " | on: " &
      outputs[armOn].strip().replace("\n", " "))
  result.name = "run-64"
  result.run = proc (arm: Arm; round: int): RunCost =
    try:
      run64RunWindows(cfg, arm, daemons[arm], armEnv(arm), dirs[arm], self)
    except OSError as err:
      raise newException(OSError, "round " & $round & ": " & err.msg)
  result.stop = proc () =
    for arm in Arm: stopDaemon(daemons[arm])
  result.details = %*{
    "cli": cfg.cliBin,
    "daemon": cfg.daemonBin,
    "actions": run64ActionCount,
    "loop_turns_per_action": run64LoopTurns,
    "mechanism": "windows-job-object",
    "memory_cap": {
      "cap": {"off": memoryArms[armOff].cap, "on": memoryArms[armOn].cap},
      "observed_has_limit": {"off": $(observed[armOff] != mclNone),
        "on": $(observed[armOn] != mclNone)},
      "probe_output": {"off": outputs[armOff], "on": outputs[armOn]}}}
  handedBack = true

proc run64Case(cfg: GateConfig; scratch: string): GateCase =
  for (label, path) in [("runquotad", cfg.daemonBin), ("runquota", cfg.cliBin)]:
    if path.len == 0 or not fileExists(path):
      raise newException(CaseUnavailable, "the " & label &
        " binary is missing: '" & path & "'")
  let memoryCapOn = isMemoryCapSwitch(cfg.switch)
  if cfg.switch.len > 0 and cfg.switch notin ["cgroups", "qos"] and
      not memoryCapOn:
    raise newException(ValueError, "unknown --switch: " & cfg.switch &
      "; expected cgroups, qos, memory-cap or memory-cap:STAGE")
  when not defined(macosx):
    if cfg.switch == "qos":
      raise newException(CaseUnavailable, "--switch=qos judges the macOS " &
        "priority policy and this is not macOS")
  when defined(windows):
    if memoryCapOn:
      if cfg.switch != MemoryCapSwitch:
        raise newException(CaseUnavailable, "--switch=" & cfg.switch &
          " names a cgroup stage, and Windows's memory cap has none (one " &
          "job-wide limit, not several placement steps); use " &
          "--switch=memory-cap")
      return run64CaseWindowsMemoryCap(cfg, scratch)
  when not defined(linux) and not defined(windows):
    if memoryCapOn:
      raise newException(CaseUnavailable, "--switch=memory-cap is " &
        "implemented for Linux and Windows only, and this is " & hostOS)
  var memoryArms: array[Arm, MemoryCapArm]
  if memoryCapOn:
    memoryArms = memoryCapArms(cfg.switch)   # ValueError: a usage error
  var cgroupRoots: array[Arm, string] = ["off", "off"]
  var probe = newJNull()
  let gateRoot =
    if cfg.switch == "cgroups" or memoryCapOn: gateCgroupRoot() else: ""
  # The memory-cap switch places BOTH arms, each under a root of its own:
  # the first stage is the memory controller on the root, and a root
  # shared by the arms would give the OFF arm the ON arm's controller.
  var armRoots: array[Arm, string]
  if memoryCapOn and gateRoot.len > 0:
    for arm in Arm:
      armRoots[arm] = gateRoot.changeFileExt("") & "-" & $arm & ".slice"
  var daemons: array[Arm, PrivateDaemon]
  # THE CASE OWNS WHAT IT SET UP UNTIL IT RETURNS: the daemons of the arms
  # already started, and the gate's cgroup root, which the migration probe
  # populates. `main` calls `stop` only on a case `makeCase` handed back, so
  # a failure on the way -- the probe, the second arm's start-up, a work
  # directory -- undoes both here before it propagates (reprobuild-pm
  # `issues/2026-11-21-runquota-benchmark-harnesses-leak-a-running-daemon-when-start-up-fails.md`).
  # A `defer` (a `finally` over the rest of the proc), so a Defect is
  # covered too; the cleanup raises nothing over the propagating exception.
  var handedBack = false
  defer:
    if not handedBack:
      for arm in Arm:
        stopDaemon(daemons[arm])
      try:
        removeGateCgroups(gateRoot)
        for arm in Arm: removeGateCgroups(armRoots[arm])
      except CatchableError: discard
  if cfg.switch == "cgroups":
    if gateRoot.len == 0:
      raise newException(CaseUnavailable, "--switch=cgroups needs a " &
        "delegated cgroup v2 subtree for this user, and there is none")
    cgroupRoots[armOn] = gateRoot
    probe = migrationProbe(gateRoot)
  if memoryCapOn:
    if gateRoot.len == 0:
      raise newException(CaseUnavailable, "--switch=" & cfg.switch &
        " needs a delegated cgroup v2 subtree for this user, and there " &
        "is none")
    cgroupRoots = armRoots
  var switches: array[Arm, string]
  var dirs: array[Arm, string]
  for arm in Arm:
    switches[arm] = armSwitchText(cfg, arm)
    daemons[arm] = startDaemon(cfg, scratch, arm, switches[arm])
    dirs[arm] = scratch / $arm / "work"
    createDir(dirs[arm])
  let script = run64Script(cfg.cliBin)
  proc armEnv(arm: Arm): seq[string] =
    runEnv(daemons[arm].socket, switches[arm], cgroupRoots[arm],
      (if cfg.switch == "qos": (if arm == armOn: "on" else: "off") else: ""),
      (if memoryCapOn: memoryArms[arm] else: MemoryCapArm()))
  # THE MEMORY-CAP CONFIGURATION CHECK, before the first round: each arm's
  # launch must show the level its configuration names, or the run is
  # refused (never a pass).
  var memoryCapJson = newJNull()
  if memoryCapOn:
    var gateEnv: seq[string]
    for key, value in envPairs():
      gateEnv.add(key & "=" & value)
    let warning = ldPreloadWarning(gateEnv)
    if warning.len > 0:
      stderr.writeLine(warning)
    var observed: array[Arm, MemoryCapLevel]
    var outputs: array[Arm, string]
    for arm in Arm:
      (observed[arm], outputs[arm]) = probeMemoryCapLevel(cfg.cliBin,
        armEnv(arm), dirs[arm])
    let problem = memoryCapConfigProblem(memoryArms, observed)
    if problem.len > 0:
      raise newException(CaseUnavailable, "memory-cap configuration " &
        "check: " & problem & "; probe output: off: " &
        outputs[armOff].strip().replace("\n", " ") & " | on: " &
        outputs[armOn].strip().replace("\n", " "))
    memoryCapJson = %*{
      "cap": {"off": memoryArms[armOff].cap, "on": memoryArms[armOn].cap},
      "stage": {"off": memoryArms[armOff].stage,
        "on": memoryArms[armOn].stage},
      "observed_level": {"off": $observed[armOff], "on": $observed[armOn]},
      "spawn_path": {
        "off": memoryCapSpawnPath(memoryArms[armOff], armEnv(armOff)),
        "on": memoryCapSpawnPath(memoryArms[armOn], armEnv(armOn))},
      "spawn_path_basis": "derived from each arm's stage and its " &
        "launchers' LD_PRELOAD; a kernel that refuses clone3 also falls " &
        "back to fork, which this does not see",
      "warning": warning,
      "nr_dying_descendants": {
        "before": {"off": nrDyingDescendants(cgroupRoots[armOff]),
          "on": nrDyingDescendants(cgroupRoots[armOn])},
        "after": {"off": -1, "on": -1}}}
  let dying = memoryCapJson
  result.name = "run-64"
  result.run = proc (arm: Arm; round: int): RunCost =
    let daemon = daemons[arm]
    let before = processCpuSeconds(daemon.pid)
    let log = scratch / $arm / "run.log"
    result = runMeasured(["/bin/sh", "-c", script], armEnv(arm),
      dirs[arm], log)
    if dying.kind == JObject:
      # After the latest run of this arm: the report is built from these
      # details once the rounds end, so it carries the last reading.
      dying["nr_dying_descendants"]["after"][$arm] =
        %nrDyingDescendants(cgroupRoots[arm])
    let after = settledDaemonCpuSeconds(daemon.pid)
    result.daemonCpuSeconds = after - before
    result.cpuSeconds += result.daemonCpuSeconds
    var ran = 0
    for kind, path in walkDir(dirs[arm]):
      if kind == pcFile and path.extractFilename.startsWith("out-"):
        if readFile(path).strip() == $run64LoopTurns: inc ran
        removeFile(path)
    if result.exitStatus != 0 or ran != run64ActionCount:
      var tail = ""
      try:
        let lines = readFile(log).splitLines()
        tail = lines[max(0, lines.len - 30) .. ^1].join("\n")
      except IOError:
        discard
      raise newException(OSError, "the " & $arm & " run (round " & $round &
        ") exited " & $result.exitStatus & " with " & $ran & " of " &
        $run64ActionCount & " actions done; " & log & ":\n" & tail)
  result.stop = proc () =
    for arm in Arm:
      stopDaemon(daemons[arm])
    removeGateCgroups(gateRoot)
    for arm in Arm:
      removeGateCgroups(armRoots[arm])
  result.details = %*{
    "cli": cfg.cliBin,
    "daemon": cfg.daemonBin,
    "actions": run64ActionCount,
    "loop_turns_per_action": run64LoopTurns,
    "cpu_milli": cfg.cpuMilli,
    "cgroup_root": {"off": cgroupRoots[armOff], "on": cgroupRoots[armOn]},
    "migration_probe": probe,
    "memory_cap": memoryCapJson,
  }
  handedBack = true

# ---------------------------------------------------------------------------
# The loop
# ---------------------------------------------------------------------------

proc estimateJson(e: MetricEstimate): JsonNode =
  %*{"rounds": e.rounds, "overhead": e.overhead, "lower": e.lower,
     "upper": e.upper, "half_width": e.halfWidth}

proc runGate*(cfg: GateConfig; gateCase: GateCase;
              progress = true): GateResult =
  ## Run interleaved rounds of `gateCase` until `decide` stops, a warm-up
  ## pair first (discarded: the first build of each arm compiles and caches
  ## what every later one reuses).
  let started = getMonoTime()
  let loadStart = loadAverage()
  let psiStart = cpuPressureSomeAvg10()
  discard gateCase.run(armOff, -1)
  discard gateCase.run(armOn, -1)
  var rounds: seq[RoundSample]
  var daemonCpu: seq[tuple[off, on: float]]
  var decision: GateDecision
  while true:
    var costs: array[Arm, RunCost]
    let first = firstArm(rounds.len)
    let order = [first, (if first == armOff: armOn else: armOff)]
    for arm in order:
      costs[arm] = gateCase.run(arm, rounds.len)
    rounds.add(RoundSample(
      offWall: costs[armOff].wallSeconds, onWall: costs[armOn].wallSeconds,
      offCpu: costs[armOff].cpuSeconds, onCpu: costs[armOn].cpuSeconds))
    daemonCpu.add((off: costs[armOff].daemonCpuSeconds,
      on: costs[armOn].daemonCpuSeconds))
    let elapsed = float((getMonoTime() - started).inMilliseconds) / 1000
    let exhausted = rounds.len >= cfg.policy.maxRounds or
      (cfg.maxSeconds > 0 and elapsed >= cfg.maxSeconds)
    decision = decide(rounds, cfg.policy, exhausted)
    if progress and (rounds.len mod 10 == 0 or
        decision.verdict != verdictContinue):
      let w = decision.estimates[metricWall]
      let c = decision.estimates[metricCpu]
      stderr.writeLine("round " & $rounds.len & ": wall " &
        formatFloat(w.overhead * 100, ffDecimal, 2) & "% +-" &
        formatFloat(w.halfWidth * 100, ffDecimal, 2) & ", cpu " &
        formatFloat(c.overhead * 100, ffDecimal, 2) & "% +-" &
        formatFloat(c.halfWidth * 100, ffDecimal, 2))
    if decision.verdict != verdictContinue:
      break
  result.decision = decision
  result.rounds = rounds
  result.elapsedSeconds =
    float((getMonoTime() - started).inMilliseconds) / 1000
  var roundsJson = newJArray()
  for i, r in rounds:
    roundsJson.add(%*{"off_wall": r.offWall, "on_wall": r.onWall,
      "off_cpu": r.offCpu, "on_cpu": r.onCpu,
      "off_daemon_cpu": daemonCpu[i].off,
      "on_daemon_cpu": daemonCpu[i].on})
  result.report = %*{
    "gate": "runquota-measurement-overhead",
    "case": gateCase.name,
    "verdict": $decision.verdict,
    "reason": decision.reason,
    "wall": estimateJson(decision.estimates[metricWall]),
    "cpu": estimateJson(decision.estimates[metricCpu]),
    "policy": {"budget": cfg.policy.budget,
      "precision_half_width": cfg.policy.precision,
      "confidence": cfg.policy.confidence,
      "min_rounds": cfg.policy.minRounds,
      "max_rounds": cfg.policy.maxRounds,
      "max_seconds": cfg.maxSeconds},
    "measure": cfg.measure,
    "baseline": formatMeasurementSwitches(cfg.baseline),
    "switch": cfg.switch,
    "switches": {
      "off": armSwitchText(cfg, armOff),
      "on": armSwitchText(cfg, armOn)},
    "not_implemented_not_measured": notImplemented(),
    "capabilities": capabilityRecords(),
    "host": {"cpus": countProcessors(), "os": hostOS, "arch": hostCPU,
      "load_start": loadStart, "load_end": loadAverage(),
      "cpu_psi_some_avg10_start": psiStart,
      "cpu_psi_some_avg10_end": cpuPressureSomeAvg10()},
    "started_unix": unixNow(),
    "elapsed_seconds": result.elapsedSeconds,
    "case_details": gateCase.details,
    "rounds": roundsJson,
  }

proc exitStatusFor*(verdict: GateVerdict): int =
  case verdict
  of verdictPass: exitPass
  of verdictFail: exitFail
  of verdictInconclusive, verdictContinue: exitInconclusive

# ---------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------

const usageText = """
runquota_overhead_gate --case=reprobuild-64|run-64|cargo-jobserver|synthetic [options]

  --measure=all|NAME          ON arm: every implemented measurement, or one
  --baseline=NAME[,NAME...]   on in BOTH arms (e.g. capture, under which
                              ambient-sampling has a store to write to)
  --switch=cgroups|qos        judge an ENFORCEMENT switch instead: the arms
                              differ only by the client's RUNQUOTA_CGROUP_ROOT
                              (off / a gate-owned root), or, for qos (macOS),
                              by its RUNQUOTA_QOS (off / on); run-64 only
  --switch=memory-cap[:STAGE] judge the memory cap (Linux and Windows);
                              run-64 only. Linux: placement on in both
                              arms, the whole mechanism against none, or
                              STAGE (controller|leaf|limits|classify)
                              against the stage before it. Windows has no
                              stages (one job-wide limit, not several
                              placement steps): :STAGE is refused, and the
                              plain switch judges the whole mechanism
                              against none, the same as Linux's own plain
                              switch
  --budget-percent=1          allowed overhead
  --precision-percent=0.5     required 95% interval half-width
  --min-rounds=10 --max-rounds=200 --max-minutes=90
  --out=PATH                  also write the JSON report here
  --keep-scratch              keep the scratch directory

  reprobuild-64:
    --daemon=PATH --engine=PATH --fixture=DIR
    --cpu-milli=4000 --memory-bytes=8589934592

  run-64:
    --daemon=PATH --cli=PATH --cpu-milli=4000 --memory-bytes=8589934592

  synthetic:
    --burn-iterations=N --inject-percent=0
    --disturbance-percent=0 --disturbance-every=25

exit: 0 pass, 1 fail, 2 usage, 3 inconclusive, 4 case unavailable,
      5 error (a run could not be measured)
"""

proc parseGateArgs*(args: openArray[string]): GateConfig =
  result = GateConfig(policy: defaultGatePolicy(), maxSeconds: 90 * 60,
    measure: "all", burnIterations: 200_000_000, disturbanceEvery: 25,
    cpuMilli: 4000, memoryBytes: 8'u64 shl 30)
  for arg in args:
    let eq = arg.find('=')
    let key = if eq < 0: arg else: arg[0 ..< eq]
    let value = if eq < 0: "" else: arg[eq + 1 .. ^1]
    case key
    of "--case": result.caseName = value
    of "--measure": result.measure = value
    of "--switch": result.switch = value
    of "--cli": result.cliBin = value
    of "--baseline":
      for name in value.split(','):
        var m: Measurement
        if not parseMeasurementName(name.strip(), m):
          raise newException(ValueError, "unknown measurement '" & name &
            "' in --baseline")
        result.baseline.incl(m)
    of "--budget-percent": result.policy.budget = parseFloat(value) / 100
    of "--precision-percent":
      result.policy.precision = parseFloat(value) / 100
    of "--min-rounds": result.policy.minRounds = parseInt(value)
    of "--max-rounds": result.policy.maxRounds = parseInt(value)
    of "--max-minutes": result.maxSeconds = parseFloat(value) * 60
    of "--out": result.outPath = value
    of "--keep-scratch": result.keepScratch = true
    of "--daemon": result.daemonBin = value
    of "--engine": result.engineBin = value
    of "--fixture": result.fixtureDir = value
    of "--cpu-milli": result.cpuMilli = parseInt(value)
    of "--memory-bytes": result.memoryBytes = parseBiggestUInt(value)
    of "--burn-iterations": result.burnIterations = parseInt(value)
    of "--disturbance-percent":
      result.disturbancePercent = parseFloat(value)
    of "--disturbance-every": result.disturbanceEvery = parseInt(value)
    of "--inject-percent": result.injectPercent = parseFloat(value)
    else:
      raise newException(ValueError, "unknown argument: " & arg)
  if result.caseName.len == 0:
    raise newException(ValueError, "--case is required")
  if result.policy.minRounds < 2 or
      result.policy.maxRounds < result.policy.minRounds:
    raise newException(ValueError,
      "need 2 <= --min-rounds <= --max-rounds")

proc makeCase*(cfg: GateConfig; scratch: string): GateCase =
  case cfg.caseName
  of "synthetic": syntheticCase(cfg, scratch)
  of "reprobuild-64": reprobuildCase(cfg, scratch)
  of "run-64": run64Case(cfg, scratch)
  of "cargo-jobserver":
    # NOT YET, AND NEVER A PASS. The requirement names a wide cargo test
    # under `runquota jobserver`; until that command exists there is
    # nothing to run, and a case that reported success here would let a
    # gate pass on half its workload.
    raise newException(CaseUnavailable, "the cargo case runs a wide " &
      "cargo test under `runquota jobserver`, which does not exist yet; " &
      "this case is not available until it does")
  else:
    raise newException(ValueError, "unknown case: " & cfg.caseName)

proc serveSyntheticChild*(args: openArray[string]): bool =
  ## If invoked as the synthetic case's child (`--synthetic-child=N`), burn
  ## N iterations, print the result so the loop is not dead code, and
  ## return true; the caller then exits.
  for arg in args:
    if arg.startsWith("--synthetic-child="):
      echo burn(parseInt(arg[len("--synthetic-child=") .. ^1]))
      return true
  false

proc serveRun64Child*(args: openArray[string]): bool =
  ## If invoked as `run64CaseWindowsMemoryCap`'s own action
  ## (`--run64-spin TURNS OUTPATH`), count to TURNS and write it to OUTPATH
  ## -- the same contract `run64Script`'s shell loop keeps on POSIX
  ## (`run64Case`'s own check reads the file back and compares it against
  ## `run64LoopTurns`). Cargo-style self-reinvocation, like
  ## `serveSyntheticChild`; not gated to Windows, since nothing about it is
  ## platform-specific, but POSIX's `run64Case` never invokes it.
  if args.len == 3 and args[0] == "--run64-spin":
    let turns = try: parseInt(args[1]) except ValueError: -1
    if turns < 0:
      return false
    var counted = 0
    for _ in 0 ..< turns:
      inc counted
    writeFile(args[2], $counted)
    return true
  false

proc serveWinMemCapProbe*(args: openArray[string]): bool =
  ## If invoked as `run64CaseWindowsMemoryCap`'s configuration-check probe
  ## (`--win-memcap-probe`), print this process's own job's memory-cap
  ## limit as `key=value` lines -- the platform analogue of
  ## `memoryCapProbeScript` reading `/proc/self/cgroup` and `memory.max` on
  ## Linux. Atomic placement (`PROC_THREAD_ATTRIBUTE_JOB_LIST`) means any
  ## cap the launcher set is already in force by the time this runs. Only
  ## reachable on Windows (`readOwnJobMemoryCapLimit` exists only there);
  ## defined everywhere so the file compiles on every OS.
  if args.len == 1 and args[0] == "--win-memcap-probe":
    when defined(windows):
      let (hasLimit, limitBytes) = readOwnJobMemoryCapLimit()
      echo "has_limit=" & (if hasLimit: "1" else: "0")
      echo "limit_bytes=" & $limitBytes
      return true
    else:
      return false
  false

proc main(): int =
  let args = commandLineParams()
  if serveSyntheticChild(args):
    return 0
  if serveRun64Child(args):
    return 0
  if serveWinMemCapProbe(args):
    return 0
  var cfg: GateConfig
  try:
    cfg = parseGateArgs(args)
  except ValueError as err:
    stderr.writeLine(err.msg & "\n" & usageText)
    return exitUsage
  let scratch = createTempDir("rqgate", "")
  var gateCase: GateCase
  var started = false
  try:
    try:
      gateCase = makeCase(cfg, scratch)
      started = true
    except ValueError as err:
      stderr.writeLine(err.msg & "\n" & usageText)
      return exitUsage
    except CaseUnavailable as err:
      let report = %*{"gate": "runquota-measurement-overhead",
        "case": cfg.caseName, "verdict": "unavailable", "reason": err.msg}
      echo report.pretty
      if cfg.outPath.len > 0:
        writeFile(cfg.outPath, report.pretty & "\n")
      stderr.writeLine("UNAVAILABLE: " & err.msg)
      return exitUnavailable
    except CatchableError as err:
      stderr.writeLine("ERROR: " & err.msg)
      return exitError
    var outcome: GateResult
    try:
      outcome = runGate(cfg, gateCase)
    except CatchableError as err:
      stderr.writeLine("ERROR: " & err.msg)
      return exitError
    echo outcome.report.pretty
    if cfg.outPath.len > 0:
      writeFile(cfg.outPath, outcome.report.pretty & "\n")
    stderr.writeLine(($outcome.decision.verdict).toUpperAscii & ": " &
      outcome.decision.reason & " (" & $outcome.rounds.len & " rounds, " &
      formatFloat(outcome.elapsedSeconds, ffDecimal, 1) & " s)")
    return exitStatusFor(outcome.decision.verdict)
  finally:
    if started:
      gateCase.stop()
    if cfg.keepScratch:
      stderr.writeLine("scratch kept at " & scratch)
    else:
      # A stopped daemon's own log file can still be held by the kernel for
      # a short while after `gateCase.stop()` returns (observed on
      # Windows, after `TerminateProcess`: `GetExitCodeProcess` can stop
      # reporting STILL_ACTIVE slightly before every one of the process's
      # handles is released) -- `removeDir` right away can then fail with
      # "being used by another process" on a run that otherwise completed
      # (or failed) correctly. The same wait-and-retry
      # `removeGateCgroups` already uses for cgroup v2's own "not empty
      # yet" lag.
      for attempt in 0 ..< 20:
        try:
          removeDir(scratch)
          break
        except OSError:
          if attempt == 19: raise
          sleep(50)

when isMainModule:
  quit main()
