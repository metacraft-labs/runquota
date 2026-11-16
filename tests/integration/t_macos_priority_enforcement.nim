## Priority enforcement BELOW admission on macOS, end to end: real
## `runquota run` processes and real launches through `runquota_exec`
## against a private `runquotad`, applying real priority policies to real
## process trees (`runquota_process/qos_priority`), and the Mach scheduler
## deciding who runs. The macOS counterpart of `t_priority_enforcement.nim`
## (Linux cgroups) and `t_windows_priority_tiering.nim` (Job Objects).
##
## WHAT macOS CAN ENFORCE, and so what this file guards (see the module
## header of `qos_priority` for the measurements): a launcher that keeps
## `fork` + `execve` can put a tree under the BACKGROUND policy, which
## survives the `execve`, is inherited by everything the tree starts and is
## honoured by the scheduler. It cannot set a QoS class between the default
## and background, cannot raise a tree above the default, cannot cap its CPU,
## and nice does not change the CPU share of an exec'd tree (measured; so
## nothing here counts nice as enforcement). The cases are:
##
## 1. A low-priority tool that ignores its grant (width 1) and starts one
##    process per logical CPU gets LESS CPU time than a normal-priority
##    build of the same number of processes running beside it, over one
##    common window, with the switch on. Each burner also records the
##    kernel's OWN reading of itself (background policy, scheduling priority
##    via `proc_pidinfo`), so the case proves that the policy is what the
##    operating system reports, not only that a split happened. Mutation:
##    the child not applying the background policy: every burner reads
##    background 0 and the split follows the process counts.
## 2. A RECLAIMED burner (two processes per logical CPU, background policy)
##    beside a granted build slows the build by under 10% against the build
##    alone, and in one common window takes under 10% of the CPU an equal
##    unlowered tree takes. Mutation: the same.
## 3. The tier follows the group's priority IN FORCE: a client whose
##    environment declares `low` for a group whose priority was set to
##    `normal` while a tree of the group ran starts its tree unlowered, and
##    after the group is set to `low` again a tree is under the background
##    policy. Mutation: the tier following the declared priority instead of
##    the one in force. (The interleaving of a launch and `session set` is
##    the unit test's seam, `t_qos_priority`'s last-instant case.)
## 4. The switch: with `RUNQUOTA_QOS=off` the same `low` tool runs unlowered
##    and a reclaimed tree is at nice +10 only (no background policy).
## 5. The enforcement gaps are reported: `runquota status` and `status
##    --json` carry the macOS record in both states, `run --cap` says on
##    stderr that macOS has no hard CPU cap. Mutation: the on-record
##    claiming priority `enforced`.
##
## NO PINNING. macOS has no CPU affinity, so the contest is between trees
## sharing every CPU of a host that other work also uses. The comparisons
## are made over a common window by each burner's own `CLOCK_PROCESS_CPUTIME_ID`
## and foreign load takes from both sides, so it cannot reverse them in
## expectation, but it makes the figures noisy: the host load is printed at
## the start and at the end of the run. Case 2 compares the MINIMUM of three
## alternating rounds of each arm (foreign load can only lengthen a run), with
## no slack added to the 10% bound.
##
## FIXTURE: the test binary re-executes itself as the burners and as the
## over-spawning tool. NO MOCKS: the built `runquotad` and `runquota`, real
## processes. Case 2's burner is launched through `runquota_exec` on a lease
## the daemon granted, with the lease's `reclaimed` flag set by the test: the
## daemon's own reclaimed decision is `t_predictive_admission`'s subject,
## this case's is what the launcher does with one.

when defined(macosx):
  import std/[monotimes, options, os, osproc, posix, strtabs, streams,
              strutils, unittest]

  import runquota_client
  import runquota_core
  import runquota_exec
  import runquota_process
  import runquota_protocol
  import daemon_binary
  import private_daemon_fixture

  proc getpriority(which: cint; who: cuint): cint {.
    importc, header: "<sys/resource.h>".}
  var PRIO_PROCESS {.importc, header: "<sys/resource.h>".}: cint
  var PRIO_DARWIN_PROCESS {.importc, header: "<sys/resource.h>".}: cint

  type ProcTaskInfo {.importc: "struct proc_taskinfo",
      header: "<libproc.h>".} = object
    pti_priority: int32

  var PROC_PIDTASKINFO {.importc, header: "<libproc.h>".}: cint
  proc procPidinfo(pid: cint; flavor: cint; arg: uint64; buffer: pointer;
                   size: cint): cint {.importc: "proc_pidinfo",
                                       header: "<libproc.h>".}

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

  proc ownState(): string =
    ## "<nice> <background 0/1> <kernel scheduling priority>".
    var info: ProcTaskInfo
    discard procPidinfo(getpid(), PROC_PIDTASKINFO, 0'u64, addr info,
      cint(sizeof(info)))
    $getpriority(PRIO_PROCESS, 0) & " " &
      $getpriority(PRIO_DARWIN_PROCESS, 0) & " " & $info.pti_priority

  proc spinChunk(x: var uint64) =
    for i in 0 ..< 50_000:
      x = x * 6364136223846793005'u64 + 1442695040888963407'u64

  proc burnUntil(startNs, endNs: int64; output: string) =
    ## Spin from `startNs` to `endNs` (monotonic); record the CPU time used
    ## in that window and the kernel's reading of this process.
    waitUntil(startNs)
    let before = cpuNs()
    var x = 0'u64
    while monoNs() < endNs:
      spinChunk(x)
    let used = cpuNs() - before
    writeFile(output, $used & " " & ownState() & " " & $(x and 1) & "\n")

  proc burnWork(chunks: int; startNs: int64; output: string) =
    ## A fixed amount of work from `startNs`; record when it ended.
    waitUntil(startNs)
    var x = 0'u64
    for _ in 0 ..< chunks:
      spinChunk(x)
    writeFile(output, $monoNs() & " " & ownState() & " " & $(x and 1) & "\n")

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
  if paramCount() >= 2 and paramStr(1) == "--print-state":
    writeFile(paramStr(2), ownState() & "\n")
    quit(0)

  let self = getAppFilename()

  const
    WindowSeconds = 3.0
    StartDelaySeconds = 3.0
      ## Between launching the `runquota run` processes and the common
      ## start: enough for each to get its lease and start its tree on a
      ## loaded host.
    SlowdownBound = 0.10
      ## The requirement's bound, unchanged.
    Rounds = 3

  proc seconds(ns: int64): float = float(ns) / 1e9

  type
    BurnerRecord = object
      value: int64        ## CPU ns (burn-until) or end ns (burn-work)
      nice, background, schedulingPriority: int

  proc records(dir, prefix: string): seq[BurnerRecord] =
    for kind, path in walkDir(dir):
      if kind == pcFile and path.extractFilename.startsWith(prefix & "-"):
        let parts = readFile(path).splitWhitespace()
        result.add(BurnerRecord(value: parseBiggestInt(parts[0]),
          nice: parseInt(parts[1]), background: parseInt(parts[2]),
          schedulingPriority: parseInt(parts[3])))

  proc sumOf(items: seq[BurnerRecord]): int64 =
    for item in items: result += item.value

  proc clientEnv(socket, group: string; priority = "";
                 qos = "on"): StringTableRef =
    result = privateEnv(socket)
    result["RUNQUOTA_SESSION"] = group
    if qos.len > 0: result["RUNQUOTA_QOS"] = qos else: result.del("RUNQUOTA_QOS")
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

  proc loadNow(): string =
    let (text, code) = execCmdEx("uptime")
    if code == 0: text.strip() else: "unknown"

  let scratch = scratchDir("rq-qos")
  let socket = scratch / "d.sock"
  let groupTag = $getCurrentProcessId()
  let cpuCount = countProcessors()
  let baseNice = int(getpriority(PRIO_PROCESS, 0))
    ## What every child inherits from this test: the nice the tiers add to.
  echo "host load at start: " & loadNow() & "; " & $cpuCount & " logical CPUs"
  let daemon = launch(scratch, socket, privateEnv(socket),
    ["--cpu-milli", $(cpuCount * 4 * 1000), "--memory-bytes",
     $(16'u64 shl 30)])
  prerequisite(daemon.awaitSocket(socket), "runquotad did not start")

  suite "priority enforcement below admission (macOS)":
    test "an over-spawning low-priority tool yields to a normal-priority build":
      let dir = scratch / "overspawn"
      createDir(dir)
      let spawned = cpuCount
      let t0 = monoNs() + int64(StartDelaySeconds * 1e9)
      let t1 = t0 + int64(WindowSeconds * 1e9)
      let low = startRun(clientEnv(socket, "rq-test-low-" & groupTag, "low"),
        ["--width", "1", "--adapter", "none", "--", self, "--tool",
         $spawned, dir / "low", "--burn-until", $t0, $t1])
      let normal = startRun(clientEnv(socket, "rq-test-normal-" & groupTag,
        "normal"), ["--width", "2", "--adapter", "none", "--", self, "--tool",
         $spawned, dir / "normal", "--burn-until", $t0, $t1])
      let (lowCode, lowText) = low.finish()
      let (normalCode, normalText) = normal.finish()
      check lowCode == 0
      check normalCode == 0
      let lows = records(dir, "low")
      let normals = records(dir, "normal")
      check lows.len == spawned
      check normals.len == spawned
      let lowCpu = sumOf(lows)
      let normalCpu = sumOf(normals)
      echo "over " & $WindowSeconds & " s, host load " & loadNow() & ": low " &
        "tool (" & $spawned & " processes) " &
        formatFloat(seconds(lowCpu), ffDecimal, 2) & " CPU-s, normal build (" &
        $spawned & " processes) " &
        formatFloat(seconds(normalCpu), ffDecimal, 2) & " CPU-s, ratio " &
        formatFloat(float(lowCpu) / float(max(normalCpu, 1)), ffDecimal, 2)
      # The kernel's own reading of each burner, from inside it.
      let unlowered = normals[0]
      check unlowered.background == 0
      check unlowered.nice == baseNice
      for record in lows:
        check record.background == 1
      for record in normals:
        check record.background == 0
        check record.nice == baseNice
      check lowCpu < normalCpu
      if lowCpu >= normalCpu or lowCode != 0 or normalCode != 0:
        echo lowText
        echo normalText

    test "a reclaimed burner slows a granted build by under 10%":
      let dir = scratch / "reclaimed"
      createDir(dir)
      # The build: `cpuCount` processes doing fixed work, sized to ~1.5 s of
      # one CPU each, measured here.
      var x = 0'u64
      let calStart = monoNs()
      var calChunks = 0
      while monoNs() - calStart < 300_000_000'i64:
        spinChunk(x)
        inc calChunks
      let chunksPerSecond = float(calChunks) / seconds(monoNs() - calStart)
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
        let t0 = monoNs() + 1_000_000_000'i64
        let job = startRun(clientEnv(socket, buildGroup),
          ["--width", "2", "--adapter", "none", "--", self, "--tool",
           $cpuCount, dir / tag, "--burn-work", $chunks, $t0])
        let (code, text) = job.finish()
        check code == 0
        if code != 0: echo text
        var endNs = 0'i64
        let ends = records(dir, tag)
        check ends.len == cpuCount
        for record in ends:
          endNs = max(endNs, record.value)
          check record.background == 0
        seconds(endNs - t0)

      for round in 1 .. Rounds:
        alone.add(runBuild("alone" & $round))
        # The burner: a real lease, reclaimed, launched as a launcher
        # launches a reclaimed grant's tree.
        var lease = burnerSession.requestLease(resourceRequest("burner",
          milliCpu(1000), bytes(64'u64 shl 20)))
        lease.reclaimed = true
        let b0 = monoNs() + 200_000_000'i64
        let b1 = b0 + int64((alone[^1] * 3.0 + 3.0) * 1e9)
        var spec = commandSpec(@[self, "--tool", $(2 * cpuCount),
          dir / ("rec" & $round), "--burn-until", $b0, $b1],
          stdio = inheritStdio)
        spec.niceIncrement = lease.reclaimedNice()
        spec.applyPlacement(burnerSession.treePlacement(lease,
          parent = none(LeaseId), qosOn = true))
        lease.markStarting()
        var burner = launchProcess(spec)
        check burner.info.qosTier == QosTierBackground
        waitUntil(b0)
        beside.add(runBuild("beside" & $round))
        let completion = burner.waitForCompletion()
        burner.close()
        check completion.exited and completion.exitCode == 0
        lease.release()
        let burners = records(dir, "rec" & $round)
        check burners.len == 2 * cpuCount
        for record in burners:
          check record.background == 1
          check record.nice == baseNice + ReclaimedNiceIncrement
      let best = min(alone)
      let bestBeside = min(beside)
      let slowdown = bestBeside / best - 1.0
      echo "build alone " & $alone & " s, beside a reclaimed burner " &
        $beside & " s; slowdown of the minima " &
        formatFloat(slowdown * 100.0, ffDecimal, 1) & "%; host load " &
        loadNow()
      check slowdown < SlowdownBound
      burnerSession.closeSession()

    test "in one window a reclaimed burner takes under 10% of an equal tree":
      let dir = scratch / "reclaimed-share"
      createDir(dir)
      putEnv("RUNQUOTA_ENDPOINT_SCOPE", "private")
      putEnv("RUNQUOTA_SOCKET", socket)
      var client = connectDefault()
      defer: client.close()
      var session = client.registerSession("share burner", "test",
        SessionGroupDeclaration(name: "rq-test-share-" & groupTag))
      var lease = session.requestLease(resourceRequest("burner",
        milliCpu(1000), bytes(64'u64 shl 20)))
      lease.reclaimed = true
      let t0 = monoNs() + int64(StartDelaySeconds * 1e9)
      let t1 = t0 + int64(WindowSeconds * 1e9)
      var spec = commandSpec(@[self, "--tool", $cpuCount, dir / "rec",
        "--burn-until", $t0, $t1], stdio = inheritStdio)
      spec.niceIncrement = lease.reclaimedNice()
      spec.applyPlacement(session.treePlacement(lease,
        parent = none(LeaseId), qosOn = true))
      lease.markStarting()
      var burner = launchProcess(spec)
      let normal = startRun(clientEnv(socket, "rq-test-share-n-" & groupTag),
        ["--width", "2", "--adapter", "none", "--", self, "--tool",
         $cpuCount, dir / "normal", "--burn-until", $t0, $t1])
      let (normalCode, normalText) = normal.finish()
      let completion = burner.waitForCompletion()
      burner.close()
      check completion.exited and completion.exitCode == 0
      check normalCode == 0
      lease.release()
      session.closeSession()
      let recs = records(dir, "rec")
      let normals = records(dir, "normal")
      check recs.len == cpuCount
      check normals.len == cpuCount
      for record in recs:
        check record.background == 1
      let recCpu = sumOf(recs)
      let normalCpu = sumOf(normals)
      echo "over " & $WindowSeconds & " s, host load " & loadNow() &
        ": reclaimed burner (" & $cpuCount & " processes) " &
        formatFloat(seconds(recCpu), ffDecimal, 2) & " CPU-s, unlowered tree (" &
        $cpuCount & " processes) " &
        formatFloat(seconds(normalCpu), ffDecimal, 2) & " CPU-s"
      check recCpu * 10 < normalCpu
      if normalCode != 0: echo normalText

    test "the tier follows the group's priority in force":
      let dir = scratch / "inforce"
      createDir(dir)
      proc state(env: StringTableRef; tag: string): BurnerRecord =
        let (code, text) = startRun(env, ["--width", "1", "--adapter", "none",
          "--", self, "--print-state", dir / tag]).finish()
        check code == 0
        if code != 0: echo text
        let parts = readFile(dir / tag).splitWhitespace()
        BurnerRecord(nice: parseInt(parts[0]), background: parseInt(parts[1]),
          schedulingPriority: parseInt(parts[2]))
      let reference = state(clientEnv(socket, "rq-test-ref-" & groupTag,
        "normal"), "ref")
      # A group created `low`, a holder tree keeping it alive, then set to
      # `normal` and to `low` again.
      let group = "rq-test-set-" & groupTag
      let lowEnv = clientEnv(socket, group, "low")
      let holder = startRun(lowEnv, ["--width", "1", "--", "sleep", "120"])
      sleep(2500)
      let declaredLow = state(lowEnv, "declared-low")
      check declaredLow.background == 1
      let (setCode, setText) = cli(lowEnv, ["session", "set", group,
        "--priority", "normal"])
      check setCode == 0
      if setCode != 0: echo setText
      # The client still DECLARES low; the group's priority in force is
      # normal, and that is what the tier follows.
      let afterSet = state(lowEnv, "after-set")
      check afterSet.background == 0
      # And back: the group set to low again, a client declaring low.
      let (setLowCode, _) = cli(lowEnv, ["session", "set", group,
        "--priority", "low"])
      check setLowCode == 0
      let afterLow = state(lowEnv, "after-low")
      check afterLow.background == 1
      # The holder is a process this test started: ended by its own handle.
      holder.terminate()
      discard holder.waitForExit()
      holder.close()

    test "the switch: off leaves a low tree unlowered and a reclaimed tree at nice only":
      let dir = scratch / "switch"
      createDir(dir)
      let reference = clientEnv(socket, "rq-test-sw-ref-" & groupTag, "normal")
      let (refCode, _) = startRun(reference, ["--width", "1", "--adapter",
        "none", "--", self, "--print-state", dir / "ref"]).finish()
      check refCode == 0
      let refState = readFile(dir / "ref").splitWhitespace()
      let (offCode, _) = startRun(clientEnv(socket, "rq-test-sw-low-" &
        groupTag, "low", qos = "off"), ["--width", "1", "--adapter", "none",
        "--", self, "--print-state", dir / "off"]).finish()
      check offCode == 0
      check readFile(dir / "off").splitWhitespace() == refState
      check refState[1] == "0"
      # A reclaimed tree with the layer off: nice +10, no background policy.
      putEnv("RUNQUOTA_ENDPOINT_SCOPE", "private")
      putEnv("RUNQUOTA_SOCKET", socket)
      var client = connectDefault()
      defer: client.close()
      var session = client.registerSession("switch", "test",
        SessionGroupDeclaration(name: "rq-test-sw-rec-" & groupTag))
      var lease = session.requestLease(resourceRequest("burner",
        milliCpu(1000), bytes(64'u64 shl 20)))
      lease.reclaimed = true
      var spec = commandSpec(@[self, "--print-state", dir / "rec"],
        stdio = inheritStdio)
      spec.niceIncrement = lease.reclaimedNice()
      spec.applyPlacement(session.treePlacement(lease,
        parent = none(LeaseId), qosOn = false))
      lease.markStarting()
      var child = launchProcess(spec)
      check child.info.qosTier == QosTierNone
      discard child.waitForCompletion()
      child.close()
      lease.release()
      session.closeSession()
      let rec = readFile(dir / "rec").splitWhitespace()
      check parseInt(rec[0]) == parseInt(refState[0]) + ReclaimedNiceIncrement
      check rec[1] == "0"                      # no background policy

    test "the capability record names what is and is not enforced":
      for (qos, level) in [("on", "degraded"), ("off", "admission-only")]:
        let env = clientEnv(socket, "rq-test-status-" & groupTag, qos = qos)
        let (code, text) = cli(env, ["status"])
        check code == 0
        check "enforcement_os: macos placement=n/a" in text
        check "enforcement: priority " & level in text
        check "enforcement: width-cap none" in text
        check "enforcement: memory-cap none" in text
        if qos == "on":
          check "enforcement: reclaimed enforced" in text
          check "high and urgent cannot be raised above normal" in text
        else:
          check "enforcement: reclaimed degraded" in text
          check "gap: qos priority off: turned off by RUNQUOTA_QOS=off" in text
        let (jsonCode, jsonText) = cli(env, ["status", "--json"])
        check jsonCode == 0
        check "\"os\":\"macos\"" in jsonText
      let (capCode, capText) = cli(clientEnv(socket, "rq-test-cap-" &
        groupTag), ["run", "--cap", "--", "true"])
      check capCode == 0
      check "runquota run: --cap not enforced: " in capText
      check "macOS has no cgroups and no hard CPU cap" in capText

  daemon.stopOwned()
  echo "host load at end: " & loadNow()
  try:
    removeDir(scratch)
  except OSError:
    discard
