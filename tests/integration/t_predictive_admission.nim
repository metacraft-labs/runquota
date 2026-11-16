## Predictive admission into the tails of running leases, corrected by CPU
## pressure, end to end: real `runquota run` processes launch real process
## trees under a private `runquotad`, the daemon learns their CPU shape from
## the finishes, and admission is observed from the trees' own clocks.
##
## WHAT IS GUARDED, each with the change that makes it fail:
##
## 1. A second job starts in the first's measured narrow tail. A job runs 3
##    CPUs for 4 s and then 1 CPU for 8 s more, on a budget of 4 CPUs plus
##    the profile's measurement error (`ProfileSlackMilli`, derived where it
##    is defined), and asks for exactly 3 CPUs. Under declared-width admission the second waits
##    for the first to end; with `admission.predictive = "on"` and the
##    shape learned from one earlier run, it starts in the first's tail, at
##    its minimum width, marked reclaimed (its trees run at nice +10 and,
##    where the user has a delegated cgroup v2 subtree, in the reclaimed
##    cgroup of a test-owned root while the first runs in its group's), and
##    the makespan of the pair is at least 20% shorter than under
##    declared-width admission measured in the same test. Mutation:
##    admitting by granted widths only (every lease predicted at its
##    charge) -- the second waits and the makespan bound fails.
## 2. With CPU pressure held above `admission.pressure-high`, no reclaimed
##    grant is issued while the first job is in its tail; a reading between
##    the thresholds keeps it so (hysteresis); one below
##    `admission.pressure-low` lets the second job in, reclaimed, while the
##    first is still in its tail. Mutations: ignoring pressure (the second
##    starts at the tail's start), and reopening below HIGH rather than low
##    (it starts at the in-between reading).
## 3. Reclaimed admission never grants memory beyond the budget, whatever
##    the CPU prediction says: with a held lease taking most of the memory,
##    the second job's CPU is predicted free in the first's tail but its
##    memory is not, and it is not admitted -- the summed memory of granted
##    leases never exceeds the budget at any poll; once the holder releases
##    the memory, the same job is admitted reclaimed at once (so CPU was
##    never what held it). Mutation: deciding the reclaimed grant on CPU
##    alone (dropping the every-other-dimension check in `reclaimWidth`).
## 4. Several reclaimed grants: each is charged and counted against the
##    rest, and together they never exceed the CPU predicted free. Beside
##    the first job (3 CPUs, then a 1-CPU tail) runs a 1-CPU job granted
##    from free capacity; three more 1-CPU jobs queue. In the tail the
##    predicted free CPU is budget - tail - 1 = 2 CPUs (+ the slack): two of
##    them are admitted reclaimed although the ledger is ALREADY over its
##    budget after the first, and the third is not, and starts at its own
##    weight only once the first job ends. Mutations: judging the ledger's
##    CPU in the every-other-dimension check (`fitsNow` without
##    `judgeCpu = false`) admits one; not adding a reclaimed grant to the
##    predicted demand for the rest of the pass (`noteReclaimed`) admits
##    three; a tolerance of up to ~990 milli-CPU in `fitsPredictedFree`
##    admits three. A smaller tolerance is below what an end-to-end test
##    can see (the tail is a measurement) and is pinned by the unit test.
## 5. Background demand counts: with the host's busy share held at 100%,
##    the second job is not reclaimed in the first's tail and waits for it
##    to end. Mutation: treating background demand as 0 in
##    `buildReclaimView`.
## 6. Without a shape, predictive admission is declared-width admission:
##    with profiles off in the client (totals arrive, no curve) and with
##    capture off in the daemon (nothing is learned at all), the second job
##    waits for the first to end and nothing is reclaimed. Mutation:
##    predicting an unshaped lease at 0, or at anything below its charge.
##
## WHY THE PRESSURE AND THE HOST'S BUSY SHARE ARE FILES. The daemon reads
## CPU pressure from a file of `/proc/pressure/cpu`'s format,
## `--cpu-pressure-file`, and takes the host's busy CPU share (from which
## background demand is computed) from `--host-cpu-busy-file`; these tests
## point both at files they write, because the subject is what admission
## does at a given pressure and background, and the host's own (a shared,
## loaded host) are neither controllable nor the same from one run to the
## next. Measured, not assumed: with the ambient sampler as the source,
## this file failed 3 runs in 6 while the full suite compiled beside it,
## each time with the daemon reporting background demand of 1954-4019
## milli-CPU (the 32-processor host fully busy), which correctly left no
## room to reclaim. The busy share is held at 0, so background demand is 0
## (its arithmetic is unit-tested). The PSI reader is tested against the
## kernel's real file in
## `libs/runquota_daemon/tests/t_predictive_admission_rules.nim`. Nothing
## else is substituted.
##
## ROBUSTNESS ON A LOADED HOST, without weakening the bound. The job's
## phases are bounded by WALL time (each burner spins until its deadline),
## so the makespans do not stretch with host load and the comparison is
## between two schedules, not two machines. A loaded host makes a burner
## get less than a CPU, so a TRAINING run on a full host learns a shape
## that under-reads, and the daemon then rightly admits early what the
## shape says fits: each training run is checked against the job's
## nominal shape and retrained under a fresh key when it under-reads
## (`ShapeToleranceMilli`, `train`). The uncontended ceiling is
## set to 100% (`--profile-uncontended-pct`): whether the host is busy when
## the suite runs is not what this test is about, and the verdict is
## unit-tested with the fold.
##
## FIXTURE: the test binary re-executes itself as the burner
## (`--spin SECONDS OUT`), so the workload depends on nothing outside this
## file. NO MOCKS beyond the two files above: the built `runquotad` and
## `runquota`, a real store, real processes.

when defined(linux):
  import std/[json, monotimes, os, osproc, streams, strtabs, strutils, unittest]
  import std/posix

  import runquota_client
  import runquota_core
  import runquota_process
  import cgroup_test_root
  import daemon_binary
  import private_daemon_fixture

  proc getpriority(which: cint; who: Id): cint {.importc, header: "<sys/resource.h>".}
  var PRIO_PROCESS {.importc, header: "<sys/resource.h>".}: cint

  proc monoNs(): int64 = getMonoTime().ticks

  proc spin(seconds: float64; output: string) =
    ## Spin one CPU until `seconds` of WALL time have passed. Writes
    ## `OUT.start` (start ns, the nice value it runs at and its cgroup) at
    ## once and
    ## `OUT` (start and end ns) at the end.
    let started = monoNs()
    let nice = getpriority(PRIO_PROCESS, Id(0))
    writeFile(output & ".start", $started & " " & $nice & " " &
      cgroupOfPid(getCurrentProcessId()) & "\n")
    let deadline = started + int64(seconds * 1e9)
    var x = 0'u64
    while monoNs() < deadline:
      for i in 0 ..< 50_000:
        x = x * 6364136223846793005'u64 + 1442695040888963407'u64
    writeFile(output, $started & " " & $monoNs() & " " & $(x and 1) & "\n")

  if paramCount() >= 3 and paramStr(1) == "--spin":
    spin(parseFloat(paramStr(2)), paramStr(3))
    quit(0)

  let self = getAppFilename()

  const
    ProfileSlackMilli = 12
      ## THE ONLY SLACK IN THE BUDGET, and where it comes from. The learned
      ## tail is a MEASUREMENT of a burner that uses exactly one CPU, so it
      ## reads 1000 milli-CPU plus the profile's error, and the second job
      ## (3000) fits beside it only if budget - tail >= 3000. A profile
      ## sample is the tree's CPU between two readings divided by the real
      ## time between them (`runquota_core/cpu_profile`, `profile`), so:
      ## * CPU TIMES ARE IN CLOCK TICKS. `/proc/<pid>/stat` reports them in
      ##   USER_HZ = 100 ticks (`getconf CLK_TCK`), so each reading is
      ##   truncated by under 10 ms and a difference of two errs by under
      ##   10 ms, for each process whose CPU moves between them: one in the
      ##   tail (the shell has none; the reaped wide burners' time is a
      ##   constant in its `cutime`). The launcher reads the tree on its
      ##   10 ms wait poll at the first poll past each one-second grid
      ##   point, so a sample spans at least 990 ms: < 10.1 milli-CPU;
      ## * THE SPAN IS IN WHOLE MILLISECONDS of the monotonic clock, so it
      ##   errs by under 1 ms in ~1000 (< 1 milli-CPU), and the division
      ##   rounds (0.5 milli-CPU).
      ## A late reading does NOT move CPU into a sample's mean: the late
      ## sample's span is longer by the same time. That bounds a tail sample
      ## at 1000 + 11.6, so 12; a shape point is a time-weighted mean of
      ## samples and errs by no more. Two points are outside this bound and
      ## are not what the fit below rests on: the first tail point, whose
      ## sample can carry the wide burners' last milliseconds (they start a
      ## few ms after the launch the grid counts from), which only delays the
      ## second job by one point; and the last two points (from 10.8 s),
      ## which hold the final sample: it is closed with the launcher's exact
      ## `wait4` total, so it also collects what every earlier tick-truncated
      ## reading of every process left out, and reads up to ~1020. No
      ## admission window here reaches them: they end by 9.5 s of the 12 s
      ## run. With less slack the second job's fit would
      ## turn on that noise; with more, the test would admit a second job
      ## the prediction does not actually leave room for.
    Budget = 4000 + ProfileSlackMilli
    JobKeyBase = "tail-job"
    TrainAttempts = 4
    ShapeToleranceMilli = 300
      ## How far below its nominal value a wide-phase point of the TRAINING
      ## run may read before that run is judged contended and retrained.
      ## Not a bound any assertion uses: a check on the test's INPUT. A
      ## shape that under-reads the wide phase (burners that got less than
      ## their CPUs because the shared host was full) tells the daemon there
      ## is room where there is none, and it then correctly admits early --
      ## measured once, with point 6 at 1766 instead of ~2330 while a large
      ## build ran beside the test. The uncontended verdict that keeps such
      ## runs out of production shapes is switched off here
      ## (`--profile-uncontended-pct 100`, see the header), so the test
      ## checks its own input instead. 300 is the largest under-read that
      ## cannot make any case here admit early: the tightest fit is case 4's
      ## (a 1-CPU job beside a 1-CPU job, admitted when the first job reads
      ## at most budget - 2000 = 2012), and the lowest nominal wide-phase
      ## point is point 6's 2333 (two thirds wide); 2333 - 2012 = 321.
      ## Every other wide point is nominally 3000. A tighter check retrains
      ## on noise the cases are immune to: on a host at load 24 a training
      ## run read its wide points up to 190 low (point 6: 57 low).
    MiB = 1024'u64 * 1024'u64

  var jobKey = JobKeyBase
    ## The stats key the jobs run under; a retrained run takes a fresh one,
    ## so a contended shape is not folded into the next attempt's.

  type
    JobTimes = object
      started: bool
      startNs: int64     ## the earliest burner start
      wideEndNs: int64   ## the end of the wide phase
      endNs: int64       ## the end of the last burner
      nice: int
      cgroup: string     ## the tail burner's cgroup

  proc jobScript(dir: string; wide, tail: float64): string =
    ## Three burners: two for `wide` seconds, one for `wide + tail`: 3 CPUs
    ## then 1.
    createDir(dir)
    quoteShell(self) & " --spin " & $wide & " " & quoteShell(dir / "w1") &
      " & " & quoteShell(self) & " --spin " & $wide & " " &
      quoteShell(dir / "w2") & " & " & quoteShell(self) & " --spin " &
      $(wide + tail) & " " & quoteShell(dir / "t") & " & wait"

  proc timesOf(dir: string): JobTimes =
    if not fileExists(dir / "t.start"):
      return
    result.started = true
    let first = readFile(dir / "t.start").splitWhitespace()
    result.startNs = parseBiggestInt(first[0])
    result.nice = parseInt(first[1])
    if first.len >= 3: result.cgroup = first[2]
    for name in ["w1", "w2"]:
      if fileExists(dir / name & ".start"):
        result.startNs = min(result.startNs,
          parseBiggestInt(readFile(dir / name & ".start").splitWhitespace()[0]))
      if fileExists(dir / name):
        result.wideEndNs = max(result.wideEndNs,
          parseBiggestInt(readFile(dir / name).splitWhitespace()[1]))
    if fileExists(dir / "t"):
      result.endNs = parseBiggestInt(readFile(dir / "t").splitWhitespace()[1])

  proc writePressure(path: string; pct: float64) =
    ## The daemon's CPU pressure, in `/proc/pressure/cpu`'s format; written
    ## whole and renamed into place so a reader never sees half a file.
    let tmp = path & ".tmp"
    writeFile(tmp, "some avg10=" & formatFloat(pct, ffDecimal, 2) &
      " avg60=0.00 avg300=0.00 total=0\n" &
      "full avg10=0.00 avg60=0.00 avg300=0.00 total=0\n")
    moveFile(tmp, path)

  proc startDaemon(root, socket: string; predictive: bool; capture = true;
                   cpuMilli = Budget; memoryBytes = 0'u64): Process =
    writeFile(root / "host.toml", "schema = \"runquota.host-config.v1\"\n" &
      "[admission]\n" &
      "predictive = \"" & (if predictive: "on" else: "off") & "\"\n" &
      "horizon = \"1s\"\n")
    if not fileExists(root / "psi"):
      writePressure(root / "psi", 0.0)
    writeFile(root / "host-busy", "0\n")
    var args = @["--socket", socket,
      "--host-config", root / "host.toml",
      "--host-identity-file", root / "host-id",
      "--observation-db", root / "observations.sqlite3",
      "--estimate-db", root / "est.sqlite",
      "--cpu-milli", $cpuMilli,
      "--memory-pressure-source", "unavailable",
      "--ambient-sample-interval-millis", "200",
      "--profile-uncontended-pct", "100",
      "--cpu-pressure-file", root / "psi",
      "--host-cpu-busy-file", root / "host-busy"]
    if capture:
      args.add(["--measurement", "capture=on"])
    if memoryBytes > 0'u64:
      args.add(["--memory-bytes", $memoryBytes])
    startProcess(daemonPath(), env = privateEnv(socket), args = args,
      options = {poStdErrToStdOut})

  proc inspect(socket, subject: string): JsonNode =
    putEnv("RUNQUOTA_ENDPOINT_SCOPE", "private")
    putEnv("RUNQUOTA_SOCKET", socket)
    var client = connectDefault()
    defer: client.close()
    parseJson(client.inspectionJson(subject))

  proc awaitCapture(socket: string): bool =
    for _ in 0 ..< 600:
      let (code, text) = cli(privateEnv(socket), ["observations", "--json"])
      if code == 0 and "\"capture_enabled\":true" in text:
        return true
      sleep(50)

  proc clientEnv(socket: string; profiles = true): StringTableRef =
    result = privateEnv(socket)
    result["RUNQUOTA_MEASUREMENT"] =
      if profiles: "profiles=on" else: "profiles=off"

  proc startJob(env: StringTableRef; script: string): Process =
    startProcess(cliPath(), env = env, args = ["run", "--width", "3:3",
      "--stats-key", jobKey, "--", "/bin/sh", "-c", script],
      options = {poStdErrToStdOut})

  proc finish(job: Process): (int, string) =
    let text = job.outputStream.readAll()
    let code = job.waitForExit()
    job.close()
    (code, text)

  proc runJob(env: StringTableRef; script: string): (int, string) =
    startJob(env, script).finish()

  proc estimateOf(socket: string): JsonNode =
    for entry in inspect(socket, "estimates")["cpu_estimates"]:
      if entry["key"].getStr.endsWith("\0" & jobKey):
        return entry
    newJNull()

  proc reclaimedGranted(socket: string): int =
    inspect(socket, "status")["admission_prediction"]["reclaimed_granted"].getInt

  proc ordered(a, b: JobTimes): (JobTimes, JobTimes) =
    if a.startNs <= b.startNs: (a, b) else: (b, a)

  proc seconds(ns: int64): string = formatFloat(float64(ns) / 1e9, ffDecimal, 2)

  proc pair(root: string; env: StringTableRef; wide, tail: float64):
      tuple[makespanNs: int64, first, second: JobTimes, outputs: string] =
    ## Two identical jobs started together; the makespan from their launch
    ## to both exits.
    let t0 = monoNs()
    let a = startJob(env, jobScript(root / "a", wide, tail))
    let b = startJob(env, jobScript(root / "b", wide, tail))
    let (codeA, textA) = a.finish()
    let (codeB, textB) = b.finish()
    result.makespanNs = monoNs() - t0
    result.outputs = textA & textB
    check codeA == 0
    check codeB == 0
    (result.first, result.second) = ordered(timesOf(root / "a"),
      timesOf(root / "b"))

  proc nominalPoint(k: int; wide, tail: float64): float64 =
    ## The shape point `k` of a perfectly measured job: 3 CPUs for `wide`
    ## seconds, then 1, time-weighted over the point's twentieth.
    let total = wide + tail
    let lo = total * float64(k) / 20.0
    let hi = total * float64(k + 1) / 20.0
    let wideSpan = max(0.0, min(hi, wide) - lo)
    (3000.0 * wideSpan + 1000.0 * (hi - lo - wideSpan)) / (hi - lo)

  proc underReadPoint(shape: JsonNode; wide, tail: float64): int =
    ## The first point overlapping the wide phase that reads more than
    ## `ShapeToleranceMilli` below nominal, or -1.
    for k in 0 ..< shape.len:
      if (wide + tail) * float64(k) / 20.0 >= wide:
        break
      if float64(shape[k].getInt) < nominalPoint(k, wide, tail) -
          float64(ShapeToleranceMilli):
        return k
    -1

  proc train(socket, root: string; env: StringTableRef; wide, tail: float64;
             wantShape = true) =
    for attempt in 1 .. TrainAttempts:
      jobKey = JobKeyBase & "-" & $attempt
      let (code, text) = runJob(env, jobScript(root / ("train" & $attempt),
        wide, tail))
      checkpoint text
      check code == 0
      let entry = estimateOf(socket)
      checkpoint $entry
      prerequisite entry.kind == JObject, "the daemon learned nothing for " &
        jobKey
      if not wantShape:
        return
      prerequisite entry["shape_milli_cpu"].kind == JArray,
        "the training run was not folded into a shape: " & $entry
      echo "learned shape ", entry["shape_milli_cpu"], " durations ",
        entry["expected_duration_by_width"]
      let bad = underReadPoint(entry["shape_milli_cpu"], wide, tail)
      if bad < 0:
        return
      echo "training run ", attempt, " was contended (point ", bad,
        " under-read); retraining under a fresh key"
    prerequisite false, "every training run was contended (" &
      $TrainAttempts & " attempts): the host never left the job its CPUs"

  suite "predictive admission into tails":
    test "a second job starts in the first's narrow tail, and the pair ends at least 20% sooner":
      # DECLARED-WIDTH ADMISSION: the same pair, predictive off.
      var declared: int64
      block:
        let root = scratchDir("rqtaild")
        defer: removeDir(root)
        let socket = root / "ep" / "d.sock"
        let daemon = startDaemon(root, socket, predictive = false)
        defer: stopOwned(daemon)
        prerequisite awaitSocket(daemon, socket),
          daemon.startupContext("the daemon did not bind " & socket)
        prerequisite awaitCapture(socket), "capture never came on"
        let env = clientEnv(socket)
        train(socket, root, env, 4.0, 8.0)
        let run = pair(root, env, 4.0, 8.0)
        checkpoint run.outputs
        declared = run.makespanNs
        echo "declared-width makespan ", seconds(declared), " s; second ",
          "started ", seconds(run.second.startNs - run.first.startNs),
          " s after the first"
        # Sanity: under declared widths the second waits for the first.
        check run.second.startNs >= run.first.endNs
        check run.second.nice == 0
        check reclaimedGranted(socket) == 0
      # PREDICTIVE ADMISSION.
      let root = scratchDir("rqtailp")
      defer: removeDir(root)
      let socket = root / "ep" / "d.sock"
      let daemon = startDaemon(root, socket, predictive = true)
      defer: stopOwned(daemon)
      prerequisite awaitSocket(daemon, socket),
        daemon.startupContext("the daemon did not bind " & socket)
      prerequisite awaitCapture(socket), "capture never came on"
      let env = clientEnv(socket)
      # Below admission (Linux cgroups): the trees are placed in a root of
      # this test's own, so the reclaimed grant the DAEMON made is seen to
      # land in the reclaimed subtree. Without a delegated subtree the rest
      # of the case still runs, and only this check is reported skipped.
      var cgroupReason = ""
      let cgroupRoot = delegatedTestRoot(cgroupReason)
      if cgroupRoot.len > 0:
        env[CgroupRootEnvVar] = cgroupRoot
      defer:
        let problem = removeTestRoot(cgroupRoot)
        check problem == ""
      train(socket, root, env, 4.0, 8.0)
      let run = pair(root, env, 4.0, 8.0)
      checkpoint run.outputs
      let predictive = run.makespanNs
      checkpoint "admission: " &
        $inspect(socket, "status")["admission_prediction"]
      echo "predictive makespan ", seconds(predictive), " s; second started ",
        seconds(run.second.startNs - run.first.startNs), " s after the ",
        "first, whose wide phase ended at ",
        seconds(run.first.wideEndNs - run.first.startNs), " s and which ended ",
        "at ", seconds(run.first.endNs - run.first.startNs), " s"
      # In the tail: after the wide phase, before the end.
      check run.second.startNs >= run.first.wideEndNs
      check run.second.startNs < run.first.endNs
      # Reclaimed, so at the lower weight; the first is not.
      check run.second.nice == 10
      check run.first.nice == 0
      check reclaimedGranted(socket) == 1
      if cgroupRoot.len > 0:
        let relativeRoot = cgroupRoot[CgroupMountPoint.len .. ^1]
        check run.second.cgroup == relativeRoot & "/" & ReclaimedDirName &
          "/" & SharedLeafName
        check run.first.cgroup.startsWith(relativeRoot & "/" & GroupDirPrefix)
        check run.first.cgroup.endsWith("/" & SharedLeafName)
      else:
        echo "SKIPPED (the reclaimed cgroup check only): " & cgroupReason
      # The bound: at least 20% shorter than declared-width admission.
      checkpoint "makespan " & seconds(predictive) & " s vs declared " &
        seconds(declared) & " s"
      check float64(predictive) <= 0.8 * float64(declared)

    test "CPU pressure above pressure-high stops reclaimed grants until it falls below pressure-low":
      let root = scratchDir("rqtailpsi")
      defer: removeDir(root)
      let socket = root / "ep" / "d.sock"
      writePressure(root / "psi", 50.0)
      let daemon = startDaemon(root, socket, predictive = true)
      defer: stopOwned(daemon)
      prerequisite awaitSocket(daemon, socket),
        daemon.startupContext("the daemon did not bind " & socket)
      prerequisite awaitCapture(socket), "capture never came on"
      let env = clientEnv(socket)
      train(socket, root, env, 4.0, 8.0)
      let a = startJob(env, jobScript(root / "a", 4.0, 8.0))
      let b = startJob(env, jobScript(root / "b", 4.0, 8.0))
      # Wait for the first to start, then into its tail.
      var firstDir = ""
      for _ in 0 ..< 600:
        if timesOf(root / "a").started: firstDir = root / "a"
        elif timesOf(root / "b").started: firstDir = root / "b"
        if firstDir.len > 0: break
        sleep(10)
      prerequisite firstDir.len > 0, "neither job started"
      let otherDir = if firstDir == root / "a": root / "b" else: root / "a"
      let firstStart = timesOf(firstDir).startNs
      proc sleepUntil(offsetSeconds: float64) =
        let target = firstStart + int64(offsetSeconds * 1e9)
        while monoNs() < target: sleep(20)
      sleepUntil(7.0)
      # Pressure above high: three seconds into the tail, nothing reclaimed.
      let closed = inspect(socket, "status")["admission_prediction"]
      checkpoint $closed
      check closed["cpu_pressure"]["gate_closed"].getBool
      check not timesOf(otherDir).started
      check reclaimedGranted(socket) == 0
      # Between the thresholds: still closed.
      writePressure(root / "psi", 7.0)
      sleepUntil(8.5)
      check not timesOf(otherDir).started
      check reclaimedGranted(socket) == 0
      # Below low: the second job is let in, still in the first's tail.
      writePressure(root / "psi", 1.0)
      var admittedAt = 0'i64
      for _ in 0 ..< 150:
        if timesOf(otherDir).started:
          admittedAt = monoNs()
          break
        sleep(20)
      if admittedAt == 0:
        # What admission saw, so a failure names its cause.
        checkpoint "status: " & $inspect(socket, "status")["admission_prediction"]
      check admittedAt > 0
      let (codeA, textA) = a.finish()
      let (codeB, textB) = b.finish()
      checkpoint textA & textB
      check codeA == 0 and codeB == 0
      let first = timesOf(firstDir)
      let second = timesOf(otherDir)
      echo "pressure released at 8.5 s; second started at ",
        seconds(second.startNs - first.startNs), " s; first ended at ",
        seconds(first.endNs - first.startNs), " s"
      check second.startNs >= firstStart + 8_500_000_000'i64
      check second.startNs < first.endNs
      check second.nice == 10
      check reclaimedGranted(socket) == 1

    test "reclaimed admission never grants memory beyond the budget":
      let root = scratchDir("rqtailmem")
      defer: removeDir(root)
      let socket = root / "ep" / "d.sock"
      const memoryBudget = 1100'u64 * MiB
      let daemon = startDaemon(root, socket, predictive = true,
        cpuMilli = 5000 + ProfileSlackMilli, memoryBytes = memoryBudget)
      defer: stopOwned(daemon)
      prerequisite awaitSocket(daemon, socket),
        daemon.startupContext("the daemon did not bind " & socket)
      prerequisite awaitCapture(socket), "capture never came on"
      let env = clientEnv(socket)
      # A holder takes 1 CPU and most of the memory. Each job declares
      # 128 MiB (`runquota run`'s nominal figure): one fits beside the
      # holder (1028 MiB), two do not (1156 MiB > 1100 MiB).
      putEnv("RUNQUOTA_ENDPOINT_SCOPE", "private")
      putEnv("RUNQUOTA_SOCKET", socket)
      var holderClient = connectDefault()
      defer: holderClient.close()
      var holderSession = holderClient.registerSession("memory-holder", "0.1.0")
      var holder = holderSession.requestLease(resourceRequest("hold",
        milliCpu(1000), bytes(900'u64 * MiB)))
      prerequisite holder.active, "the holder was not granted"
      holder.markStarting()
      holder.markRunning(childProcessId = uint64(getCurrentProcessId()))
      train(socket, root, env, 4.0, 8.0)
      proc grantedMemory(): uint64 =
        for lease in inspect(socket, "leases")["leases"]:
          if lease["state"].getStr in ["granted", "starting", "running"] and
              lease["parent_lease_id"].getInt == 0:
            result += uint64(lease["resources"]["memory_bytes"].getBiggestInt)
      let a = startJob(env, jobScript(root / "a", 4.0, 8.0))
      let b = startJob(env, jobScript(root / "b", 4.0, 8.0))
      var firstDir = ""
      var peak = 0'u64
      for _ in 0 ..< 600:
        if timesOf(root / "a").started: firstDir = root / "a"
        elif timesOf(root / "b").started: firstDir = root / "b"
        if firstDir.len > 0: break
        sleep(10)
      prerequisite firstDir.len > 0, "neither job started"
      let otherDir = if firstDir == root / "a": root / "b" else: root / "a"
      let firstStart = timesOf(firstDir).startNs
      # Three seconds into the first's tail: the second's CPU is predicted
      # free there (5 CPUs + the slack - the holder's 1 - the tail's 1 = 3),
      # its memory is not.
      while monoNs() < firstStart + 7_000_000_000'i64:
        peak = max(peak, grantedMemory())
        sleep(100)
      checkpoint "granted memory peaked at " & $(peak div MiB) & " MiB"
      check peak <= memoryBudget
      check not timesOf(otherDir).started
      check reclaimedGranted(socket) == 0
      # The holder lets the memory go: the same job is admitted at once,
      # reclaimed -- CPU never was what held it.
      holder.release()
      var admitted = false
      for _ in 0 ..< 150:
        peak = max(peak, grantedMemory())
        if timesOf(otherDir).started:
          admitted = true
          break
        sleep(20)
      if not admitted:
        # What admission saw, so a failure names its cause.
        checkpoint "status: " & $inspect(socket, "status")["admission_prediction"]
        checkpoint "leases: " & $inspect(socket, "leases")
      check admitted
      while a.running or b.running:
        peak = max(peak, grantedMemory())
        sleep(100)
      let (codeA, textA) = a.finish()
      let (codeB, textB) = b.finish()
      checkpoint textA & textB
      check codeA == 0 and codeB == 0
      let first = timesOf(firstDir)
      let second = timesOf(otherDir)
      check second.startNs < first.endNs
      check second.nice == 10
      check reclaimedGranted(socket) == 1
      check peak <= memoryBudget
      holderSession.closeSession()

    test "several reclaimed grants together never exceed the predicted free CPU":
      let root = scratchDir("rqtailmany")
      defer: removeDir(root)
      let socket = root / "ep" / "d.sock"
      let daemon = startDaemon(root, socket, predictive = true)
      defer: stopOwned(daemon)
      prerequisite awaitSocket(daemon, socket),
        daemon.startupContext("the daemon did not bind " & socket)
      prerequisite awaitCapture(socket), "capture never came on"
      let env = clientEnv(socket)
      train(socket, root, env, 4.0, 8.0)
      proc startSmall(dir: string): Process =
        ## One CPU for 14 s, under a key with no shape (predicted at its
        ## charge); outlives the first job's 12 s.
        createDir(dir)
        startProcess(cliPath(), env = env, args = ["run", "--width", "1:1",
          "--stats-key", "small-job", "--", self, "--spin", "14",
          dir / "t"], options = {poStdErrToStdOut})
      proc awaitStart(dir: string): bool =
        for _ in 0 ..< 1000:
          if timesOf(dir).started: return true
          sleep(10)
      let a = startJob(env, jobScript(root / "a", 4.0, 8.0))
      prerequisite awaitStart(root / "a"), "the first job did not start"
      # Granted from free capacity: 3 + 1 CPUs fill the 4-CPU ledger.
      let b = startSmall(root / "b")
      prerequisite awaitStart(root / "b"), "the 1-CPU job did not start"
      var queued: seq[Process]
      for name in ["c", "d", "e"]:
        queued.add(startSmall(root / name))
        sleep(200)
      var outputs = ""
      for job in @[a, b] & queued:
        let (code, text) = job.finish()
        outputs.add(text)
        check code == 0
      checkpoint outputs
      checkpoint "admission: " &
        $inspect(socket, "status")["admission_prediction"]
      let first = timesOf(root / "a")
      check timesOf(root / "b").nice == 0
      var inTail, afterEnd = 0
      for name in ["c", "d", "e"]:
        let t = timesOf(root / name)
        echo name, " started ", seconds(t.startNs - first.startNs),
          " s after the first (wide phase ended at ",
          seconds(first.wideEndNs - first.startNs), " s, first ended at ",
          seconds(first.endNs - first.startNs), " s), nice ", t.nice
        if t.startNs >= first.wideEndNs and t.startNs < first.endNs and
            t.nice == 10:
          inc inTail
        elif t.startNs >= first.endNs and t.nice == 0:
          inc afterEnd
      # Two reclaimed in the tail, the third at its own weight after it.
      check inTail == 2
      check afterEnd == 1
      check reclaimedGranted(socket) == 2

    test "background demand from a busy host leaves no room to reclaim":
      let root = scratchDir("rqtailbusy")
      defer: removeDir(root)
      let socket = root / "ep" / "d.sock"
      let daemon = startDaemon(root, socket, predictive = true)
      defer: stopOwned(daemon)
      prerequisite awaitSocket(daemon, socket),
        daemon.startupContext("the daemon did not bind " & socket)
      prerequisite awaitCapture(socket), "capture never came on"
      let env = clientEnv(socket)
      train(socket, root, env, 4.0, 8.0)
      # Every processor busy: whatever the budget leaves outside RunQuota
      # is full, and the rest is the leases' own predicted demand or more.
      writeFile(root / "host-busy", "100\n")
      let run = pair(root, env, 4.0, 8.0)
      checkpoint run.outputs
      let prediction = inspect(socket, "status")["admission_prediction"]
      checkpoint $prediction
      check run.second.startNs >= run.first.endNs
      check run.second.nice == 0
      check reclaimedGranted(socket) == 0
      check "background" in prediction["last_reclaim_decision"].getStr
      check prediction["host_busy_source"].getStr ==
        root / "host-busy"

  suite "without a shape, declared-width admission":
    test "profiles off in the client: totals but no curve, nothing reclaimed":
      let root = scratchDir("rqtailnoshape")
      defer: removeDir(root)
      let socket = root / "ep" / "d.sock"
      let daemon = startDaemon(root, socket, predictive = true)
      defer: stopOwned(daemon)
      prerequisite awaitSocket(daemon, socket),
        daemon.startupContext("the daemon did not bind " & socket)
      prerequisite awaitCapture(socket), "capture never came on"
      let env = clientEnv(socket, profiles = false)
      train(socket, root, env, 1.5, 1.5, wantShape = false)
      let entry = estimateOf(socket)
      check entry["shape_milli_cpu"].kind == JNull
      check entry["expected_duration_by_width"].len == 1
      let run = pair(root, env, 1.5, 1.5)
      checkpoint run.outputs
      check run.second.startNs >= run.first.endNs
      check run.second.nice == 0
      check reclaimedGranted(socket) == 0

    test "capture off in the daemon: nothing learned, nothing reclaimed":
      let root = scratchDir("rqtailnocap")
      defer: removeDir(root)
      let socket = root / "ep" / "d.sock"
      let daemon = startDaemon(root, socket, predictive = true, capture = false)
      defer: stopOwned(daemon)
      prerequisite awaitSocket(daemon, socket),
        daemon.startupContext("the daemon did not bind " & socket)
      let env = clientEnv(socket)
      let (code, text) = runJob(env, jobScript(root / "train", 1.5, 1.5))
      checkpoint text
      check code == 0
      let run = pair(root, env, 1.5, 1.5)
      checkpoint run.outputs
      check run.second.startNs >= run.first.endNs
      check run.second.nice == 0
      check reclaimedGranted(socket) == 0
      let prediction = inspect(socket, "status")["admission_prediction"]
      check prediction["predictive"].getBool
