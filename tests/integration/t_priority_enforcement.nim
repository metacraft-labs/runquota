## Priority enforcement BELOW admission on Linux, end to end: real
## `runquota run` processes and real launches through `runquota_exec`, against
## a private `runquotad`, placing real process trees in real cgroup v2
## directories of a test-owned root, and the kernel's CPU controller deciding
## who runs.
##
## WHAT IS GUARDED, each with the change that makes it fail:
##
## 1. A low-priority tool that ignores its grant (width 1) and starts one
##    process per logical CPU of the host gets LESS CPU time than a
##    high-priority group's build (width 2, two processes) running beside
##    it over the same window. Each tree is in its group's cgroup
##    (`group-<name>/shared`, weights 25 and 400), so the split follows the
##    groups' weights, not the process counts (32 against 2). Mutation:
##    placing the trees in the launcher's own cgroup instead of the group's
##    (`treePlacement` returning no target) -- the 34 processes then share
##    one cgroup and the tool takes most of the CPU.
## 2. A reclaimed CPU burner (four processes) beside a granted build slows
##    the build by under 10% against the build alone. The burner runs in
##    `reclaimed/shared` at weight 1. Mutation: running reclaimed work at
##    normal weight (`targetFor` giving the reclaimed directory its group's
##    weight) -- the build then gets about half the CPUs and takes about
##    twice as long.
## 3. The enforcement gaps are reported: `runquota status` and `status
##    --json` carry the capability record (on this host every CPU mechanism
##    enforced, the memory cap admission-only; with placement off, each
##    CPU mechanism degraded or none, naming why), `run --cap` that cannot
##    be enforced says so on stderr, and the records for macOS and Windows
##    (built by the same builder; this host cannot be another OS) name the
##    enforcement each lacks. Mutation: the macOS record claiming its width
##    cap is enforced.
## 4. `runquota run --cap` holds the tree to its grant: a width-1 grant
##    running two spinners for 3 s uses at most one CPU's worth (plus the
##    enforcement slack derived below), while the same command without
##    `--cap` uses more.
##    Mutation: `cpuMaxFor` writing `max` (no quota).
## 5. The weight follows the group's priority IN FORCE: `runquota session
##    set --priority urgent` rewrites the weight of a group's directory while
##    a tree runs in it, and a tree started afterwards by a client whose
##    environment still says `low` keeps the in-force weight. Mutation:
##    the launch ignoring the priority source it reads under the root's lock
##    (`CommandSpec.cgroupPriority`), so the weight is the one placement
##    chose from the declared priority. (The interleavings of a launch and
##    `session set` are `t_group_weight_race`'s subject.)
## 6. The outermost launcher places: `runquota run` inside a `runquota run`
##    tree leaves its tree in its parent's cgroup.
## 7. Nothing is left behind: once the trees end, their group directories
##    are gone, and the test root is removed.
##
## A ROOT OF ITS OWN. Every client here gets `RUNQUOTA_CGROUP_ROOT` naming a
## fresh root below the user's delegated subtree (`cgroup_test_root`); the
## user's real `runquota.slice` is never written. On a host that gives the
## user no delegated cgroup v2 subtree with the cpu controller (a CI
## container), the cases are reported SKIPPED with the reason: they need the
## kernel's controller, which nothing can stand in for.
##
## ROBUSTNESS ON A SHARED, LOADED HOST, without weakening a bound.
## * ONE PHYSICAL CORE. After its daemon starts, the test pins itself, and
##   so every tree it launches, to the two logical CPUs of one core (or two
##   CPUs where there is no SMT). The comparisons are then between trees
##   that share the same two CPUs, so the result does not depend on how many
##   other CPUs the host has free, and the sibling hyperthread is never a
##   CPU only one side can use.
## * Case 1 compares CPU time over one common window measured by each
##   burner (`CLOCK_PROCESS_CPUTIME_ID` between a common start and end on
##   the monotonic clock); foreign load on the two CPUs takes from both sides
##   in proportion to their weights, so it cannot reverse the comparison
##   (weights 400 vs 25, expected split ~94% / ~6%).
## * Case 2's bound is a ratio of wall times, and foreign load on the two
##   CPUs can only LENGTHEN a run. Each arm is run three times, alternating,
##   and each arm's MINIMUM is compared: the minimum is the run least
##   inflated by foreign load, so noise can only push the measured slowdown
##   toward the arm that happened to be disturbed less, and alternating
##   gives both arms the same chances. No slack is added to the 10% bound.
## * Case 4's bound is derived from how the kernel enforces `cpu.max`, term
##   by term (`capBoundNs` below). The quota rule: at most `quota` µs of CPU
##   per 100 ms period, so over a window of W seconds the tree can use at
##   most width × W plus one period's quota, for a window that starts or
##   ends mid-period (cgroup-v2.rst, "cpu.max"). That is the IDEAL and the
##   measured value sits on it (3.00-3.10 CPU-s for a 3.10 s bound, by the
##   window's phase against the period), so the three ways the real
##   enforcement exceeds it are added, each quantified, never a blanket
##   margin: (a) runtime is handed to each CPU in slices of
##   `kernel.sched_cfs_bandwidth_slice_us` (5 ms by default) and a CPU keeps
##   an unused slice into the next period (slice expiry was removed in
##   Linux 5.4), so each CPU running the tree can run one slice beyond a
##   period's quota; (b) a CPU that has used its runtime is throttled at
##   the next accounting point, at worst the next scheduler tick, so each
##   CPU can overrun by one tick at the window's end, at most 10 ms (the
##   kernel's lowest HZ is 100); (c) each burner reads its CPU clock after
##   its last work chunk, which may end just after the window, so one chunk
##   per burner (timed by the test itself) can be counted. On two CPUs with
##   the defaults that is 3.10 + 0.01 + 0.02 + ~0.0001 s, about 3.13 s,
##   against about 6 s for the same spinners uncapped (a cap written as
##   `max` still fails).
##   Sources: https://docs.kernel.org/scheduler/sched-bwc.html ("Real-world
##   behavior": the unexpired slice per CPU) and
##   https://docs.kernel.org/admin-guide/cgroup-v2.html#cpu-interface-files
## The host's load is printed at the start of the run.
##
## FIXTURE: the test binary re-executes itself as the burners and as the
## over-spawning tool, so the workload depends on nothing outside this file.
## NO MOCKS: the built `runquotad` and `runquota`, real cgroups. Case 2's
## burner is launched through `runquota_exec` on a lease the daemon really
## granted, with the lease's `reclaimed` flag set by the test: whether the
## daemon GRANTS a reclaimed lease is the subject of
## `t_predictive_admission` (which also checks that such a tree runs in the
## reclaimed subtree); this case's subject is what the launcher does with
## one, and a reclaimed grant made by the daemon needs a learned shape and a
## training run per round, which would make the alternating comparison take
## minutes.

when defined(linux):
  import std/[json, monotimes, options, os, osproc, posix, strtabs,
              streams, strutils, unittest]

  import runquota_client
  import runquota_core
  import runquota_exec
  import runquota_process
  import runquota_protocol
  import cgroup_test_root
  import daemon_binary
  import private_daemon_fixture

  proc getpriority(which: cint; who: Id): cint {.importc, header: "<sys/resource.h>".}
  var PRIO_PROCESS {.importc, header: "<sys/resource.h>".}: cint
  proc schedSetaffinity(pid: Pid; size: csize_t; mask: pointer): cint {.
    importc: "sched_setaffinity", header: "<sched.h>".}

  proc monoNs(): int64 = getMonoTime().ticks

  proc cpuNs(): int64 =
    var ts: Timespec
    discard clock_gettime(CLOCK_PROCESS_CPUTIME_ID, ts)
    int64(ts.tv_sec) * 1_000_000_000'i64 + int64(ts.tv_nsec)

  proc waitUntil(ns: int64) =
    let now = monoNs()
    if ns > now:
      sleep(int((ns - now) div 1_000_000))
    while monoNs() < ns:
      discard

  proc ownCgroup(): string = cgroupOfPid(getCurrentProcessId())

  proc spinChunk(x: var uint64) =
    for i in 0 ..< 50_000:
      x = x * 6364136223846793005'u64 + 1442695040888963407'u64

  proc burnUntil(startNs, endNs: int64; output: string) =
    ## Spin from `startNs` to `endNs` (monotonic); record the CPU time used
    ## in that window, the cgroup and the nice value.
    waitUntil(startNs)
    let before = cpuNs()
    var x = 0'u64
    while monoNs() < endNs:
      spinChunk(x)
    let used = cpuNs() - before
    writeFile(output, $used & " " & ownCgroup() & " " &
      $getpriority(PRIO_PROCESS, Id(0)) & " " & $(x and 1) & "\n")

  proc burnWork(chunks: int; startNs: int64; output: string) =
    ## A fixed amount of work from `startNs`; record when it ended.
    waitUntil(startNs)
    var x = 0'u64
    for _ in 0 ..< chunks:
      spinChunk(x)
    writeFile(output, $monoNs() & " " & ownCgroup() & " " & $(x and 1) & "\n")

  proc runTool(count: int; mode: seq[string]; outputPrefix: string) =
    ## Start `count` copies of this binary in `mode`, wait for all of them.
    var children: seq[Process]
    for i in 0 ..< count:
      children.add(startProcess(getAppFilename(),
        args = mode & @[outputPrefix & "-" & $i], options = {poParentStreams}))
    var failed = 0
    for child in children:
      if child.waitForExit() != 0: inc failed
      child.close()
    quit(if failed == 0: 0 else: 1)

  # Child modes, before anything else runs.
  if paramCount() >= 4 and paramStr(1) == "--burn-until":
    burnUntil(parseBiggestInt(paramStr(2)), parseBiggestInt(paramStr(3)),
      paramStr(4))
    quit(0)
  if paramCount() >= 4 and paramStr(1) == "--burn-work":
    burnWork(parseInt(paramStr(2)), parseBiggestInt(paramStr(3)), paramStr(4))
    quit(0)
  if paramCount() >= 3 and paramStr(1) == "--tool":
    # --tool N OUTPREFIX MODE ARGS...: the mode's output argument is
    # OUTPREFIX-i, appended last.
    var mode: seq[string]
    for i in 4 .. paramCount():
      mode.add(paramStr(i))
    runTool(parseInt(paramStr(2)), mode, paramStr(3))
  if paramCount() >= 1 and paramStr(1) == "--print-cgroup":
    echo ownCgroup()
    quit(0)

  let self = getAppFilename()

  const
    WindowSeconds = 3.0
    StartDelaySeconds = 2.0
      ## Between launching the `runquota run` processes and the common
      ## start: enough for each to get its lease and start its tree on a
      ## loaded host; a burner that is not running by then fails the test
      ## (its window starts late and its file says so via the CPU check).
    SlowdownBound = 0.10
      ## The requirement's bound, unchanged.
    Rounds = 3
    CapPeriodMicros = 100_000

  proc seconds(ns: int64): float = float(ns) / 1e9

  proc cpuSetForTest(): seq[int] =
    ## The logical CPUs of the host's last core: its SMT siblings, or the
    ## last two CPUs where a core has one.
    let last = countProcessors() - 1
    let text = try:
        readFile("/sys/devices/system/cpu/cpu" & $last &
          "/topology/thread_siblings_list").strip()
      except IOError, OSError: $last
    for part in text.split(','):
      let bounds = part.split('-')
      if bounds.len == 2:
        for c in parseInt(bounds[0]) .. parseInt(bounds[1]): result.add(c)
      elif part.len > 0:
        result.add(parseInt(part))
    if result.len < 2 and last > 0:
      result = @[last - 1, last]

  proc pinSelf(cpus: seq[int]) =
    var mask: array[16, uint64]
    for c in cpus:
      mask[c div 64] = mask[c div 64] or (1'u64 shl (c mod 64))
    doAssert schedSetaffinity(Pid(0), csize_t(sizeof(mask)), addr mask) == 0,
      "sched_setaffinity: " & $strerror(errno)

  proc bandwidthSliceNs(): int64 =
    ## The per-CPU runtime slice of CFS bandwidth control, from
    ## `kernel.sched_cfs_bandwidth_slice_us`; the kernel's default (5 ms)
    ## where the file cannot be read.
    try:
      parseBiggestInt(readFile(
        "/proc/sys/kernel/sched_cfs_bandwidth_slice_us").strip()) * 1000
    except IOError, OSError, ValueError:
      5_000_000'i64

  proc chunkNs(): int64 =
    ## The CPU time of one burner work chunk, measured (the slowest of a few).
    var x = 0'u64
    for _ in 0 ..< 20:
      let before = cpuNs()
      spinChunk(x)
      result = max(result, cpuNs() - before)
    if (x and 1) == 2: echo x   # keep the work

  const
    MaxTickNs = 10_000_000'i64
      ## One scheduler tick at the kernel's lowest HZ (100).
    CapWidthMilli = 1000
    CapBurners = 2

  proc capBoundNs(cpuCount: int): int64 =
    ## The most CPU time a `cpu.max` of width 1 lets `CapBurners` spinners
    ## on `cpuCount` CPUs count over the window (derived in the header):
    ## the quota rule, plus a carried slice and a tick per CPU the tree runs
    ## on, plus one work chunk per burner.
    let runningCpus = int64(min(cpuCount, CapBurners))
    int64(WindowSeconds * 1e9) * CapWidthMilli div 1000 +
      int64(CapPeriodMicros) * 1000 * CapWidthMilli div 1000 +
      runningCpus * (bandwidthSliceNs() + MaxTickNs) +
      int64(CapBurners) * chunkNs()

  proc relativeCgroup(path: string): string =
    ## A cgroup directory as `/proc/<pid>/cgroup` names it.
    path[CgroupMountPoint.len .. ^1]

  type
    BurnerRecord = object
      value: int64        ## CPU ns (burn-until) or end ns (burn-work)
      cgroup: string
      nice: int

  proc records(dir, prefix: string): seq[BurnerRecord] =
    for kind, path in walkDir(dir):
      if kind == pcFile and path.extractFilename.startsWith(prefix & "-"):
        let parts = readFile(path).splitWhitespace()
        var record = BurnerRecord(value: parseBiggestInt(parts[0]),
          cgroup: parts[1])
        if parts.len >= 4: record.nice = parseInt(parts[2])
        result.add(record)

  proc sumOf(items: seq[BurnerRecord]): int64 =
    for item in items: result += item.value

  proc clientEnv(socket, root, group: string; priority = ""): StringTableRef =
    result = privateEnv(socket)
    result[CgroupRootEnvVar] = root
    result["RUNQUOTA_SESSION"] = group
    if priority.len > 0:
      result["RUNQUOTA_SESSION_PRIORITY"] = priority
    else:
      result.del("RUNQUOTA_SESSION_PRIORITY")
    result.del("RUNQUOTA_PARENT_LEASE")

  proc startRun(env: StringTableRef; args: openArray[string]): Process =
    startProcess(cliPath(), env = env, args = @["run"] & @args,
      options = {poStdErrToStdOut})

  proc finish(job: Process): (int, string) =
    let text = job.outputStream.readAll()
    let code = job.waitForExit()
    job.close()
    (code, text)

  var rootReason = ""
  let testRoot = delegatedTestRoot(rootReason)
  let scratch = scratchDir("rq-prio")
  let socket = scratch / "d.sock"
  let groupTag = $getCurrentProcessId()
  var daemon: Process
  var daemonStarted = false
  let cpus = cpuSetForTest()

  if testRoot.len > 0:
    echo "host load at start: " & readFile("/proc/loadavg").strip() &
      "; test CPUs " & $cpus & "; test root " & testRoot
    daemon = launch(scratch, socket, privateEnv(socket),
      ["--cpu-milli", "8000", "--memory-bytes", $(16'u64 shl 30)])
    prerequisite(daemon.awaitSocket(socket), "runquotad did not start")
    daemonStarted = true
    # Pinned AFTER the daemon started, so only this test and the trees it
    # launches share the two CPUs.
    pinSelf(cpus)
  else:
    echo "SKIPPED (every case): no delegated cgroup v2 subtree with the cpu " &
      "controller for this user: " & rootReason

  template needRoot(): bool =
    ## Inside a test: whether the cases can run here; reported SKIPPED with
    ## the reason when they cannot.
    if testRoot.len == 0:
      echo "SKIPPED: " & rootReason
      skip()
    testRoot.len > 0

  suite "priority enforcement below admission (Linux cgroups)":
    test "an over-spawning low-priority tool yields to a high-priority build":
      if needRoot():
        let dir = scratch / "overspawn"
        createDir(dir)
        let lowGroup = "rq-test-low-" & groupTag
        let highGroup = "rq-test-high-" & groupTag
        let spawned = countProcessors()
        let t0 = monoNs() + int64(StartDelaySeconds * 1e9)
        let t1 = t0 + int64(WindowSeconds * 1e9)
        let low = startRun(clientEnv(socket, testRoot, lowGroup, "low"),
          ["--width", "1", "--adapter", "none", "--", self, "--tool",
           $spawned, dir / "low", "--burn-until", $t0, $t1])
        let high = startRun(clientEnv(socket, testRoot, highGroup, "high"),
          ["--width", "2", "--adapter", "none", "--", self, "--tool", "2",
           dir / "high", "--burn-until", $t0, $t1])
        let (lowCode, lowText) = low.finish()
        let (highCode, highText) = high.finish()
        check lowCode == 0
        check highCode == 0
        let lows = records(dir, "low")
        let highs = records(dir, "high")
        check lows.len == spawned
        check highs.len == 2
        let lowCpu = sumOf(lows)
        let highCpu = sumOf(highs)
        echo "over " & $WindowSeconds & " s on CPUs " & $cpus & ": low tool (" &
          $spawned & " processes) " & formatFloat(seconds(lowCpu), ffDecimal, 2) &
          " CPU-s, high build (2 processes) " &
          formatFloat(seconds(highCpu), ffDecimal, 2) & " CPU-s"
        let lowLeaf = relativeCgroup(testRoot / groupDirName(lowGroup) /
          SharedLeafName)
        let highLeaf = relativeCgroup(testRoot / groupDirName(highGroup) /
          SharedLeafName)
        for record in lows:
          check record.cgroup == lowLeaf
        for record in highs:
          check record.cgroup == highLeaf
        check lowCpu < highCpu
        if lowCpu >= highCpu or lowCode != 0 or highCode != 0:
          echo lowText
          echo highText

    test "a reclaimed burner slows a granted build by under 10%":
      if needRoot():
        let dir = scratch / "reclaimed"
        createDir(dir)
        # The build: two processes doing fixed work, sized to ~1.5 s on one
        # of the test CPUs, measured here.
        var x = 0'u64
        let calStart = monoNs()
        var calChunks = 0
        while monoNs() - calStart < 300_000_000'i64:
          spinChunk(x)
          inc calChunks
        let chunksPerSecond = float(calChunks) /
          seconds(monoNs() - calStart)
        let chunks = max(1, int(chunksPerSecond * 1.5))
        let buildGroup = "rq-test-build-" & groupTag
        putEnv("RUNQUOTA_ENDPOINT_SCOPE", "private")
        putEnv("RUNQUOTA_SOCKET", socket)
        var client = connectDefault()
        defer: client.close()
        var burnerSession = client.registerSession("reclaimed burner", "test",
          SessionGroupDeclaration(name: "rq-test-burner-" & groupTag))
        var alone, beside: seq[float]

        proc runBuild(tag: string): float =
          let t0 = monoNs() + 500_000_000'i64
          let job = startRun(clientEnv(socket, testRoot, buildGroup),
            ["--width", "2", "--adapter", "none", "--", self, "--tool", "2",
             dir / tag, "--burn-work", $chunks, $t0])
          let (code, text) = job.finish()
          check code == 0
          if code != 0: echo text
          var endNs = 0'i64
          let ends = records(dir, tag)
          check ends.len == 2
          for record in ends:
            endNs = max(endNs, record.value)
            check record.cgroup == relativeCgroup(testRoot /
              groupDirName(buildGroup) / SharedLeafName)
          seconds(endNs - t0)

        for round in 1 .. Rounds:
          alone.add(runBuild("alone" & $round))
          # The burner: a real lease, reclaimed, launched as a launcher
          # launches a reclaimed grant's tree.
          var lease = burnerSession.requestLease(resourceRequest("burner",
            milliCpu(1000), bytes(64'u64 shl 20)))
          lease.reclaimed = true
          let b0 = monoNs() + 200_000_000'i64
          let b1 = b0 + int64((alone[^1] * 3.0 + 1.5) * 1e9)
          var spec = commandSpec(@[self, "--tool", "4", dir / ("rec" & $round),
            "--burn-until", $b0, $b1], stdio = inheritStdio)
          spec.niceIncrement = lease.reclaimedNice()
          spec.applyPlacement(burnerSession.treePlacement(lease,
            root = CgroupRoot(state: crsExplicit, path: testRoot),
            parent = none(LeaseId)))
          lease.markStarting()
          var burner = launchProcess(spec)
          check burner.info.cgroupPath == testRoot / ReclaimedDirName /
            SharedLeafName
          waitUntil(b0)
          beside.add(runBuild("beside" & $round))
          let completion = burner.waitForCompletion()
          burner.close()
          check completion.exited and completion.exitCode == 0
          lease.release()
          let burners = records(dir, "rec" & $round)
          check burners.len == 4
          for record in burners:
            check record.cgroup == relativeCgroup(testRoot / ReclaimedDirName /
              SharedLeafName)
            check record.nice == ReclaimedNiceIncrement
        let best = min(alone)
        let bestBeside = min(beside)
        let slowdown = bestBeside / best - 1.0
        echo "build alone " & $alone & " s, beside a reclaimed burner " &
          $beside & " s; slowdown of the minima " &
          formatFloat(slowdown * 100.0, ffDecimal, 1) & "%"
        check slowdown < SlowdownBound
        burnerSession.closeSession()

    test "the capability record names what is and is not enforced":
      if needRoot():
        let env = clientEnv(socket, testRoot, "rq-test-status-" & groupTag)
        let (code, text) = cli(env, ["status"])
        check code == 0
        check "enforcement_os: linux placement=on cgroup_root=" & testRoot in text
        check "enforcement: priority enforced" in text
        check "enforcement: reclaimed enforced" in text
        check "enforcement: width-cap enforced" in text
        check "enforcement: memory-cap admission-only" in text
        let (jsonCode, jsonText) = cli(env, ["status", "--json"])
        check jsonCode == 0
        let parsed = parseJson(jsonText)
        check parsed.hasKey("session_groups")   # the daemon's part is kept
        let record = parsed["enforcement"]
        check record["os"].getStr == "linux"
        check record["placement"].getStr == "on"
        check record["mechanisms"].len == 4
        # Placement off: every CPU mechanism says what is missing and why.
        let offEnv = clientEnv(socket, CgroupRootOff, "rq-test-status-" & groupTag)
        let (offCode, offText) = cli(offEnv, ["status"])
        check offCode == 0
        check "enforcement: priority admission-only" in offText
        check "enforcement: reclaimed degraded" in offText
        check "enforcement: width-cap none" in offText
        check "gap: cgroup placement off: turned off by RUNQUOTA_CGROUP_ROOT=off" in offText
        let (capCode, capText) = cli(offEnv, ["run", "--cap", "--", "true"])
        check capCode == 0
        check "runquota run: --cap not enforced: " in capText
      # The other operating systems, from the same builder.
      let mac = enforcementRecordFor("macos")
      var macGaps: seq[string]
      for gap in mac.gaps: macGaps.add($gap.mechanism)
      check "width-cap" in macGaps
      check "memory-cap" in macGaps
      check "priority" in macGaps
      check "reclaimed" in macGaps
      check "not enforced: " in mac.summaryLine
      check "width-cap: macOS has no hard CPU cap" in mac.summaryLine
      # Windows, job-priority OFF by default: the reclaimed tree's below-normal
      # class and the width cap are enforced; priority between groups is
      # admission-only until the switch is on.
      let win = enforcementRecordFor("windows")
      check win.gaps.len == 2
      check "width-cap=enforced" in win.summaryLine
      check "reclaimed=enforced" in win.summaryLine
      check "priority: job priority off:" in win.summaryLine
      # With the switch ON the lower priority tiers are enforced (a Job Object
      # priority class per group), but the urgent tier needs a privilege an
      # ordinary launcher lacks, so priority is degraded with that caveat as a
      # gap alongside the memory cap.
      let winOn = enforcementRecordFor("windows", jobPriorityOn = true)
      check winOn.gaps.len == 2
      check winOn.gaps[0].mechanism == emPriority
      check winOn.gaps[1].mechanism == emMemoryCap
      check "priority=degraded" in winOn.summaryLine
      check "urgent tier" in winOn.summaryLine
      for record in [mac, win]:
        let parsed = parseJson(record.toJson())
        check parsed["mechanisms"].len == 4
        for item in parsed["mechanisms"]:
          check item["gap"].getStr.len > 0 or item["level"].getStr == "enforced"

    test "run --cap holds the tree to its granted width":
      if needRoot():
        let dir = scratch / "cap"
        createDir(dir)
        var used: array[2, int64]
        for i, capped in [true, false]:
          let t0 = monoNs() + int64(StartDelaySeconds * 1e9)
          let t1 = t0 + int64(WindowSeconds * 1e9)
          var args = @["--width", "1", "--adapter", "none", "--verbose"]
          if capped: args.add("--cap")
          args.add(["--", self, "--tool", $CapBurners, dir / ("c" & $i),
            "--burn-until", $t0, $t1])
          let (code, text) = startRun(clientEnv(socket, testRoot,
            "rq-test-cap-" & groupTag), args).finish()
          check code == 0
          if capped:
            check "cgroup " & testRoot / groupDirName("rq-test-cap-" & groupTag) /
              CapLeafPrefix in text
            check "not enforced" notin text
          used[i] = sumOf(records(dir, "c" & $i))
        let bound = capBoundNs(cpus.len)
        echo "two spinners, width 1, " & $WindowSeconds & " s: capped " &
          formatFloat(seconds(used[0]), ffDecimal, 3) & " CPU-s, uncapped " &
          formatFloat(seconds(used[1]), ffDecimal, 3) & " CPU-s, bound " &
          formatFloat(seconds(bound), ffDecimal, 3)
        check used[0] <= bound
        check used[1] > bound

    test "the weight follows the group's priority in force":
      if needRoot():
        let group = "rq-test-set-" & groupTag
        let weightFile = testRoot / groupDirName(group) / "cpu.weight"
        let env = clientEnv(socket, testRoot, group, "low")
        # A tree holds the group's directory while the priority changes.
        let holder = startRun(env, ["--width", "1", "--", "sleep", "4"])
        var waited = 0
        while not fileExists(weightFile) and waited < 10_000:
          sleep(20)
          waited += 20
        check readFile(weightFile).strip() == "25"
        let (setCode, setText) = cli(env, ["session", "set", group,
          "--priority", "urgent"])
        check setCode == 0
        if setCode != 0: echo setText
        check readFile(weightFile).strip() == "1600"
        # A client whose environment still says `low` prepares the
        # directory with the weight in force.
        let (code, _) = startRun(env, ["--width", "1", "--", "true"]).finish()
        check code == 0
        check readFile(weightFile).strip() == "1600"
        let (holderCode, _) = holder.finish()
        check holderCode == 0

    test "a launcher inside a leased tree leaves its tree where its parent put it":
      if needRoot():
        let group = "rq-test-nest-" & groupTag
        let (code, text) = startRun(clientEnv(socket, testRoot, group),
          ["--width", "2", "--", cliPath(), "run", "--width", "1", "--verbose",
           "--", self, "--print-cgroup"]).finish()
        check code == 0
        check relativeCgroup(testRoot / groupDirName(group) / SharedLeafName) in
          text
        check "which its own launcher placed" in text

    test "nothing is left behind":
      if needRoot():
        # Every tree has ended, so every group directory is gone; only the
        # root remains, and it is removed.
        check cgroupDirsBelow(testRoot).len == 0
        if cgroupDirsBelow(testRoot).len != 0:
          echo "left behind: " & $cgroupDirsBelow(testRoot)

  if daemonStarted:
    daemon.stopOwned()
  if testRoot.len > 0:
    let problem = removeTestRoot(testRoot)
    if problem.len > 0:
      echo "TEST ROOT NOT REMOVED: " & problem
      quit(1)
    doAssert not dirExists(testRoot)
  try:
    removeDir(scratch)
  except OSError:
    discard
