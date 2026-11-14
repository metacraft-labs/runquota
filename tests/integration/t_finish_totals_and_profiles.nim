## The tree's totals and CPU profile in a finish, end to end: a real
## `runquota acquire -- <command>` (the `runquota_exec` wrapper) launches a
## process tree under a private `runquotad`, and the execution row, the
## stored profile and the daemon's learned CPU estimate are read back.
##
## WHAT IS GUARDED.
##
## 1. Totals come from the launcher's wait for the tree's root, so they
##    include GRANDCHILDREN the root waited for. The fixture is a shell
##    that starts three burners of one CPU-second each and waits; the
##    finish must report at least 3 s of CPU. Falsifying mutation: report
##    only the direct child's own usage (the shell's `utime + stime` before
##    it is reaped, rather than `wait4`'s rusage) and the row carries about
##    0 s and fails. With `profiles` off (the default) no profile row is
##    written: the execution keeps its totals only.
## 2. With `RUNQUOTA_MEASUREMENT=profiles=on`, once with `tree-sampling`
##    off and once with it on (see the case), a tree that burns 8 CPUs for
##    10 s and then 2 CPUs for 20 s yields a profile within 10% of that
##    curve. Two comparisons, both at 10%:
##    * against the tree's REAL CPU use per second, read from the burners'
##      own CPU clocks: each burner records its CPU clock against the
##      monotonic clock every few milliseconds while it runs, so the CPU it
##      used in any one second is known exactly, not assumed spread evenly
##      over its life. This is independent of host load: a burner that was
##      starved of a core in some second says so for that second, so the
##      comparison measures the sampler, not the host;
##    * against the nominal curve (8000 then 2000 milli-CPUs), for the
##      seconds wholly inside each phase -- ONLY WHEN THE BURNERS GOT THEIR
##      CPU. The burners are bounded by CPU time, so on a host without 8
##      idle CPUs the first phase stretches and the nominal curve is simply
##      not what ran. Whether they got it is read from the same clocks
##      (every burner's wall time within 5% of its CPU time); when they did
##      not, the nominal comparison is skipped and the output says so and
##      why. The tolerance is never widened to make a loaded host pass.
##    Falsifying mutation: feed the sampler the live processes' own CPU
##    only (no reaped descendants' time): when the first phase's burners
##    are reaped the reading falls, the sampler holds it, and the second
##    phase reads as idle.
## 3. The daemon folds that uncontended profile into the key's learned
##    shape: twenty points, each within 10% of the burners' real CPU over
##    its twentieth of the run (and, when the burners got their CPU, the
##    first phase's near 8000 and the second's near 2000), and an expected
##    duration at the granted width. The
##    uncontended ceiling is set to 100% here (`--profile-uncontended-pct`)
##    because whether the host is busy when the suite runs is not what this
##    test is about; the verdict itself is unit-tested.
##
## FIXTURE: the test binary re-executes itself as the burner
## (`--burn SECONDS OUT`) and as a clock mark (`--mark OUT`), so the
## workload depends on nothing outside this file. NO MOCKS: the built
## `runquotad` and `runquota`, a real store, real processes.

when defined(linux):
  import std/[json, monotimes, options, os, osproc, strtabs, strutils, unittest]
  import std/posix

  import runquota_client
  import runquota_core
  import runquota_observation_store
  import runquota_protocol
  import daemon_binary
  import private_daemon_fixture

  proc cpuNanos(): int64 =
    var ts: Timespec
    discard clock_gettime(CLOCK_PROCESS_CPUTIME_ID, ts)
    int64(ts.tv_sec) * 1_000_000_000'i64 + int64(ts.tv_nsec)

  proc burn(seconds: float64; output: string) =
    ## Spin until this process has used `seconds` of CPU, then record when
    ## it started and ended (monotonic ns) and the CPU it used (µs) on the
    ## first line, followed by one `monotonic-ns cpu-ns` line per
    ## checkpoint: the CPU clock read against the monotonic clock every
    ## 5 ms or so, so the CPU this burner used in any window can be read
    ## off to within one checkpoint.
    let started = getMonoTime().ticks
    let target = int64(seconds * 1e9)
    let cpuStart = cpuNanos()
    var x = 0'u64
    var checkpoints = newStringOfCap(64 * 1024)
    var lastCheckpoint = started
    while true:
      for i in 0 ..< 100_000:
        x = x * 6364136223846793005'u64 + 1442695040888963407'u64
      let used = cpuNanos() - cpuStart
      let now = getMonoTime().ticks
      if now - lastCheckpoint >= 5_000_000 or used >= target:
        checkpoints.add($now & " " & $used & "\n")
        lastCheckpoint = now
      if used >= target:
        break
    let ended = getMonoTime().ticks
    let used = (cpuNanos() - cpuStart) div 1000
    writeFile(output, $started & " " & $ended & " " & $used & " " &
      $(x and 1) & "\n" & checkpoints)

  if paramCount() >= 3 and paramStr(1) == "--burn":
    burn(parseFloat(paramStr(2)), paramStr(3))
    quit(0)
  if paramCount() >= 2 and paramStr(1) == "--mark":
    writeFile(paramStr(2), $getMonoTime().ticks)
    quit(0)

  type Burn = object
    startNs, endNs: int64
    cpuMicros: int64
    clock: seq[(int64, int64)]
      ## (monotonic ns, CPU ns used so far), in time order.

  proc readBurn(path: string): Burn =
    let lines = readFile(path).splitLines()
    let parts = lines[0].splitWhitespace()
    result = Burn(startNs: parseBiggestInt(parts[0]),
      endNs: parseBiggestInt(parts[1]), cpuMicros: parseBiggestInt(parts[2]))
    result.clock.add((result.startNs, 0'i64))
    for line in lines[1 .. ^1]:
      let fields = line.splitWhitespace()
      if fields.len == 2:
        result.clock.add((parseBiggestInt(fields[0]),
          parseBiggestInt(fields[1])))

  proc cpuNanosAt(b: Burn; at: float64): float64 =
    ## The CPU this burner had used by monotonic time `at`, interpolated
    ## between its checkpoints: 0 before it started, all of it after.
    if b.clock.len == 0 or at <= float64(b.clock[0][0]):
      return 0.0
    for k in 1 ..< b.clock.len:
      let (t1, c1) = b.clock[k]
      if at <= float64(t1):
        let (t0, c0) = b.clock[k - 1]
        if t1 <= t0:
          return float64(c1)
        return float64(c0) + float64(c1 - c0) *
          (at - float64(t0)) / float64(t1 - t0)
    float64(b.clock[^1][1])

  proc cpuMilliIn(burns: openArray[Burn]; origin: int64;
                  loMillis, hiMillis: float64): float64 =
    ## The tree's mean CPU use, in milli-CPUs, over `[lo, hi)` ms after
    ## `origin`, from the burners' own clocks.
    if hiMillis <= loMillis:
      return 0.0
    var nanos = 0.0
    for b in burns:
      nanos += b.cpuNanosAt(float64(origin) + hiMillis * 1e6) -
        b.cpuNanosAt(float64(origin) + loMillis * 1e6)
    nanos / 1e6 / (hiMillis - loMillis) * 1000.0

  proc startDaemon(root, socket: string; extra: openArray[string]): Process =
    var args = @["--socket", socket,
      "--host-config", root / "host.toml",
      "--host-identity-file", root / "host-id",
      "--observation-db", root / "observations.sqlite3",
      # Capture is off by default (it costs more than the
      # measurement budget allows); this test reads what it records.
      "--measurement", "capture=on",
      "--estimate-db", root / "est.sqlite",
      "--cpu-milli", "16000",
      "--memory-pressure-source", "unavailable"]
    for arg in extra: args.add(arg)
    startProcess(daemonPath(), env = privateEnv(socket), args = args,
      options = {poStdErrToStdOut})

  proc awaitCapture(socket: string): bool =
    ## The endpoint is served before the store is verified, and a session
    ## registered before capture is on records nothing; wait for it.
    for _ in 0 ..< 600:
      let (code, text) = cli(privateEnv(socket), ["observations", "--json"])
      if code == 0 and "\"capture_enabled\":true" in text:
        return true
      sleep(50)

  proc acquire(env: StringTableRef; cpuMilli: int; key, script: string):
      tuple[code: int, output: string] =
    cli(env, ["acquire", "--cpu", $cpuMilli, "--stats-key", key, "--",
      "/bin/sh", "-c", script])

  proc stoppedStore(daemon: Process; root: string): ObservationStore =
    ## Stop the daemon (SIGTERM drains the writer) and open its store.
    stopOwned(daemon)
    openObservationStore(root / "observations.sqlite3")

  proc estimatesJson(socket: string): JsonNode =
    putEnv("RUNQUOTA_ENDPOINT_SCOPE", "private")
    putEnv("RUNQUOTA_SOCKET", socket)
    var client = connectDefault()
    defer: client.close()
    parseJson(client.inspectionJson("estimates"))

  proc within(actual, expected, fraction: float64): bool =
    abs(actual - expected) <= fraction * expected

  let self = getAppFilename()

  suite "finish totals from the launcher":
    test "a finish carries the CPU of grandchildren its root waited for":
      let root = scratchDir("rqtotals")
      defer: removeDir(root)
      let socket = root / "ep" / "d.sock"
      let daemon = startDaemon(root, socket,
        ["--ambient-sample-interval-millis", "0"])
      defer: stopOwned(daemon)
      prerequisite awaitSocket(daemon, socket),
        daemon.startupContext("the daemon did not bind " & socket)
      prerequisite awaitCapture(socket), "capture never came on"
      var env = privateEnv(socket)
      env["RUNQUOTA_MEASUREMENT"] = "tree-sampling=off"
      let script = quoteShell(self) & " --burn 1 " & quoteShell(root / "a") &
        " & " & quoteShell(self) & " --burn 1 " & quoteShell(root / "b") &
        " & " & quoteShell(self) & " --burn 1 " & quoteShell(root / "c") &
        " & wait"
      let (code, text) = acquire(env, 1000, "totals-fixture", script)
      checkpoint text
      check code == 0
      var burned = 0'i64
      for name in ["a", "b", "c"]:
        burned += readBurn(root / name).cpuMicros
      check burned >= 3_000_000
      let store = stoppedStore(daemon, root)
      let executions = store.readExecutions()
      check executions.len == 1
      if executions.len == 1:
        let row = executions[0]
        checkpoint "cpu user " & $row.cpuUserMillis & " sys " &
          $row.cpuSysMillis & " duration " & $row.durationMillis &
          " peak " & $row.peakRssBytes
        echo "totals: cpu user ", row.cpuUserMillis, " sys ", row.cpuSysMillis,
          " ms, duration ", row.durationMillis, " ms, peak ", row.peakRssBytes
        check row.cpuUserMillis.isSome and row.cpuSysMillis.isSome
        if row.cpuUserMillis.isSome and row.cpuSysMillis.isSome:
          check row.cpuUserMillis.get + row.cpuSysMillis.get >= 3000
        check row.durationMillis >= 1000
        # Tree sampling is off, yet the finish has a peak: `ru_maxrss`.
        check row.peakRssBytes > 0
      # `profiles` is off by default: totals only, no profile row.
      check store.readCpuProfiles().len == 0

    test "out-of-range totals from a client are stored saturated, not fatal":
      # A peer can put any u64 on the wire. Converting one above
      # `int64.high` to a store integer raised `RangeDefect` in the daemon,
      # so one malformed finish took down the host-wide daemon for every
      # user. Falsifying mutation: a plain `int64(...)` in place of the
      # daemon's saturating conversion -- the daemon dies on the finish and
      # the second session below cannot connect.
      let root = scratchDir("rqtotalsrange")
      defer: removeDir(root)
      let socket = root / "ep" / "d.sock"
      let daemon = startDaemon(root, socket,
        ["--ambient-sample-interval-millis", "0"])
      defer: stopOwned(daemon)
      prerequisite awaitSocket(daemon, socket),
        daemon.startupContext("the daemon did not bind " & socket)
      prerequisite awaitCapture(socket), "capture never came on"
      putEnv("RUNQUOTA_ENDPOINT_SCOPE", "private")
      putEnv("RUNQUOTA_SOCKET", socket)
      block:
        var client = connectDefault()
        defer: client.close()
        var session = client.registerSession("totals-range", "0.1.0")
        var request = resourceRequest("totals-range", milliCpu(1000),
          bytes(64'u64 * 1024'u64 * 1024'u64))
        request.commandStatsId = "totals-range"
        var lease = session.requestLease(request)
        check lease.active
        lease.markStarting()
        lease.markRunning(childProcessId = uint64(getCurrentProcessId()))
        lease.finish(outcome = succeeded(),
          totals = FinishTotals(known: true, cpuUserMicros: high(uint64),
            cpuSysMicros: 0'u64, maxRssBytes: high(uint64),
            majorPageFaults: high(uint64), durationMillis: high(uint64)))
        lease.release()
        session.closeSession()
      # The daemon still serves.
      block:
        var client = connectDefault()
        defer: client.close()
        var session = client.registerSession("totals-range-after", "0.1.0")
        session.closeSession()
      check daemon.running
      let store = stoppedStore(daemon, root)
      let executions = store.readExecutions()
      check executions.len == 1
      if executions.len == 1:
        let row = executions[0]
        check row.durationMillis == high(int64)
        check row.peakRssBytes == high(int64)
        check row.majorPageFaults == high(int64)
        # Divided to milliseconds first, so this one fits exactly.
        check row.cpuUserMillis == some(int64(high(uint64) div 1000'u64))

  template curveCase(measurement: string) =
      let root = scratchDir("rqprofile")
      defer: removeDir(root)
      let socket = root / "ep" / "d.sock"
      let daemon = startDaemon(root, socket,
        ["--ambient-sample-interval-millis", "250",
         "--profile-uncontended-pct", "100"])
      defer: stopOwned(daemon)
      prerequisite awaitSocket(daemon, socket),
        daemon.startupContext("the daemon did not bind " & socket)
      prerequisite awaitCapture(socket), "capture never came on"
      var env = privateEnv(socket)
      # BOTH WAYS: with profiles alone, and with tree sampling on as well.
      # The profile-only walk used to read second 10 low (1978 vs 2231
      # milli-CPU) because its interval boundaries drifted a few ms per
      # second behind the launch-relative grid, so the first phase's last
      # ms fell into sample 9; the boundaries are on the grid now and the
      # case must hold without tree sampling's extra readings.
      env["RUNQUOTA_MEASUREMENT"] = measurement
      var script = quoteShell(self) & " --mark " & quoteShell(root / "mark") &
        "; "
      for i in 0 ..< 8:
        script.add(quoteShell(self) & " --burn 10 " &
          quoteShell(root / ("p1-" & $i)) & " & ")
      script.add("wait; ")
      for i in 0 ..< 2:
        script.add(quoteShell(self) & " --burn 20 " &
          quoteShell(root / ("p2-" & $i)) & " & ")
      script.add("wait")
      let (code, text) = acquire(env, 8000, "profile-fixture", script)
      checkpoint text
      check code == 0

      let origin = parseBiggestInt(readFile(root / "mark").strip())
      var burns: seq[Burn] = @[]
      for i in 0 ..< 8: burns.add(readBurn(root / ("p1-" & $i)))
      for i in 0 ..< 2: burns.add(readBurn(root / ("p2-" & $i)))

      let estimates = estimatesJson(socket)
      let store = stoppedStore(daemon, root)
      let profiles = store.readCpuProfiles()
      let executions = store.readExecutions()
      check profiles.len == 1
      check executions.len == 1
      prerequisite profiles.len == 1 and executions.len == 1,
        "no profile or execution was stored"
      let profile = profiles[0]
      let samples = profile.samples
      checkpoint "interval " & $profile.intervalMillis & " samples " & $samples
      echo "profile interval ", profile.intervalMillis, " ms: ", samples
      check profile.intervalMillis == 1000
      check profile.source == "client-tree"

      # The tree's real CPU per second, from the burners' own clocks.
      proc truth(i: int): float64 =
        cpuMilliIn(burns, origin, float64(i) * 1000.0, float64(i + 1) * 1000.0)
      var phase1End = 0'i64
      for i in 0 ..< 8: phase1End = max(phase1End, burns[i].endNs - origin)
      checkpoint "first phase ended at " & $(phase1End div 1_000_000) & " ms"
      # DID THE BURNERS GET THEIR CPU? Each is bounded by CPU time, so one
      # that shared its core ran longer than the CPU it used. Within 5%,
      # every one of them had a core to itself and the nominal curve is
      # what ran; otherwise it is not, and comparing against it would test
      # the host's load rather than the sampler.
      var worstStretch = 0.0
      for b in burns:
        if b.cpuMicros > 0:
          worstStretch = max(worstStretch,
            float64(b.endNs - b.startNs) / 1000.0 / float64(b.cpuMicros))
      let gotTheirCpu = worstStretch <= 1.05
      let starvedReason = "a burner ran " &
        formatFloat(worstStretch, ffDecimal, 2) &
        "x longer than the CPU it used, so the host did not give the tree " &
        "8 then 2 idle CPUs; the per-second and shape comparisons against " &
        "the burners' own clocks above stand in for it"
      checkpoint "worst burner wall/CPU " & formatFloat(worstStretch, ffDecimal, 3)

      # Every full second but the boundary seconds: within 10% of the real
      # use. The last sample may be partial and the first includes launch.
      var mismatches: seq[string] = @[]
      for i in 1 ..< samples.len - 1:
        let expected = truth(i)
        if expected <= 0.0: continue
        if not within(float64(samples[i]), expected, 0.10):
          mismatches.add($i & ": " & $samples[i] & " vs " &
            formatFloat(expected, ffDecimal, 0))
      checkpoint "against the burners' own CPU: " & $mismatches
      check mismatches.len == 0

      # Against the nominal curve, the seconds wholly inside each phase --
      # when that is the curve that ran.
      var nominalMisses: seq[string] = @[]
      if not gotTheirCpu:
        echo "SKIPPED the nominal-curve comparison: ", starvedReason
      for i in (if gotTheirCpu: 1 else: samples.len) ..< samples.len - 1:
        let lo = int64(i) * 1_000_000_000'i64
        let hi = lo + 1_000_000_000'i64
        let nominal =
          if hi <= phase1End and i < 10: 8000.0
          elif lo >= phase1End: 2000.0
          else: -1.0
        if nominal < 0.0: continue
        if not within(float64(samples[i]), nominal, 0.10):
          nominalMisses.add($i & ": " & $samples[i] & " vs " & $nominal)
      checkpoint "against the nominal curve: " & $nominalMisses
      check nominalMisses.len == 0
      # And the curve spans the run: ~30 s, CPU-time totals ~120 s.
      check samples.len >= 29
      let row = executions[0]
      check row.cpuUserMillis.isSome
      if row.cpuUserMillis.isSome:
        check within(float64(row.cpuUserMillis.get +
          row.cpuSysMillis.get(0)), 120_000.0, 0.10)

      # The daemon folded it into the key's learned shape.
      checkpoint $estimates
      var found = false
      for entry in estimates["cpu_estimates"]:
        if not entry["key"].getStr.endsWith("profile-fixture"):
          continue
        found = true
        check entry["profiles_folded"].getInt == 1
        let shape = entry["shape_milli_cpu"]
        check shape.kind == JArray and shape.len == 20
        if shape.kind == JArray and shape.len == 20:
          # Each point against the burners' real CPU over its twentieth of
          # the run (the launcher's duration). Skipped: the first (it holds
          # the launch), the last (the profile's last sample is partial and
          # is stretched to the end), and any point within one profile
          # interval of the phase change, where the profile's one-second
          # resolution blurs a step the clocks see exactly.
          let duration = float64(row.durationMillis)
          let bin = duration / 20.0
          let change = float64(phase1End) / 1e6
          var shapeMisses: seq[string] = @[]
          for k in 1 .. 18:
            let lo = bin * float64(k)
            let hi = lo + bin
            if hi > change - 1000.0 and lo < change + 1000.0:
              continue
            let expected = cpuMilliIn(burns, origin, lo, hi)
            if not within(float64(shape[k].getInt), expected, 0.10):
              shapeMisses.add($k & ": " & $shape[k].getInt & " vs " &
                formatFloat(expected, ffDecimal, 0))
          checkpoint "shape against the burners' own CPU: " & $shapeMisses
          check shapeMisses.len == 0
          # And, when the nominal curve is what ran: points 1-5 lie in the
          # first phase (1.5 s each), 8-19 in the second.
          if gotTheirCpu:
            for k in 1 .. 5:
              check within(float64(shape[k].getInt), 8000.0, 0.10)
            for k in 8 .. 19:
              check within(float64(shape[k].getInt), 2000.0, 0.10)
          else:
            echo "SKIPPED the nominal-shape comparison: ", starvedReason
        let widths = entry["expected_duration_by_width"]
        check widths.len == 1
        if widths.len == 1:
          check widths[0]["cpu_milli"].getInt == 8000
          check widths[0]["expected_duration_millis"].getInt >= 29_000
      check found

  suite "CPU profiles":
    test "a tree burning 8 CPUs for 10 s then 2 for 20 s yields that curve (profiles alone)":
      curveCase("profiles=on,tree-sampling=off")

    test "a tree burning 8 CPUs for 10 s then 2 for 20 s yields that curve (with tree sampling)":
      curveCase("profiles=on,tree-sampling=on")
