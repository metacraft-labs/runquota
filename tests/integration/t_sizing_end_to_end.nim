## Sizing data end to end: what a launcher measures and declares reaches the
## store, and `runquota profile`, `runquota sizing` and `runquota
## observations export --format sizing` answer from it through a real
## private `runquotad`.
##
## WHAT IS GUARDED, AND THE MUTATION EACH CASE IS KNOWN TO FAIL UNDER.
##
## * job_peak_is_tree_sum. `runquota acquire -- sh` starts four
##   processes that each touch 1 GiB and hold it for four seconds. With
##   `sizing-data` on (and `tree-sampling` off) the execution's peak and its
##   memory profile read the tree's SUM, about 4 GiB. Falsifying mutation:
##   the Linux tree reader taking the maximum over processes instead of the
##   sum (`runquota_host_linux` `sampleLinuxProcessTreeTelemetry`) reports
##   about 1 GiB and fails. The control run with `sizing-data` off reads
##   `ru_maxrss`, about 1 GiB, and has no memory profile: the switch is what
##   turns the measurement on.
##   SHARED-HOST LIMITS: the case refuses to start unless 6 GiB are
##   available, runs one 4-GiB tree at a time, and every holder exits by
##   itself after four seconds, so nothing outlives a failed assertion.
## * Write bytes: a tree that writes and fsyncs 32 MiB on a disk-backed
##   directory reports at least 32 MiB written. On Linux the figure is the
##   reaping `wait4`'s `ru_oublock` times 512 (the root and the children it
##   waited for). Mutation: not taking it leaves the column NULL; so does
##   reading the exited root's `/proc/<pid>/io` instead for an unprivileged
##   launcher on Linux 6.18, which refuses that read
##   (`libs/runquota_process/tests/t_exit_io_totals.nim` pins this one).
##   On macOS the figure is `proc_pid_rusage`'s `ri_diskio_byteswritten` of
##   the root, which has no reaped-children share: the root `exec`s the
##   writer there, and a second case records, as a capability, that a
##   root whose child wrote reads below 32 MiB. Mutation: not reading it
##   leaves the column NULL.
## * macOS memory: the libproc tree reader (`runquota_host_macos`
##   `sampleMacosProcessTreeTelemetryNative`) sums `pti_resident_size`;
##   taking the maximum instead fails job_peak_is_tree_sum.
## * `after` over the wire: a finish naming an earlier lease of its session
##   records that lease's execution id; one naming another session's lease
##   records nothing for it. Mutation: storing the lease ids verbatim.
## * quantile_and_baseline_reported and
##   offline_replay_matches_daemon: see the cases.
## * Capture off: `sizing` and `profile` answer `capture-off` with exit 4,
##   never an empty "ok".
##
## THE SYNTHETIC STORE, AND WHY IT IS JUSTIFIED. The two replay cases need a
## hundred runs whose peaks are known exactly (so the 0.9 quantile has one
## right answer) plus runs with incomplete capture and ambient samples in
## known windows. Producing that by running real builds would take hours and
## still not give exact figures. The rows are written into the private
## daemon's own store, with the host and hardware profile that daemon
## recorded, through the store library's batch writer (the same insert the
## daemon's writer uses); the daemon then reads and replays them exactly as
## it would its own rows. Everything else here is real: the built
## `runquotad` and `runquota`, real processes, a real SQLite store, and the
## reference script run by the real `node`.

when defined(linux) or defined(macosx):
  import std/[json, options, os, osproc, posix, sequtils, streams, strtabs, strutils,
    tables, times, unittest]

  import runquota_client
  import runquota_core
  import runquota_observation_store
  import runquota_protocol
  import daemon_binary
  import private_daemon_fixture

  const
    GiB = 1024'i64 * 1024 * 1024
    MiB = 1024'i64 * 1024

  proc hold(mib: int; seconds: float) =
    ## Touch `mib` MiB, page by page, hold it, then exit.
    var buffer = newSeq[byte](mib * 1024 * 1024)
    var i = 0
    while i < buffer.len:
      buffer[i] = 1
      i += 4096
    sleep(int(seconds * 1000))
    if buffer[0] != 1: quit(3)

  proc writeSynced(path: string; mib: int) =
    let fd = posix.open(path.cstring, O_WRONLY or O_CREAT or O_TRUNC, 0o600)
    if fd < 0: quit(4)
    var chunk = newString(1024 * 1024)
    for i in 0 ..< mib:
      if posix.write(fd, addr chunk[0], chunk.len) != chunk.len: quit(5)
    if fsync(fd) != 0: quit(6)
    discard posix.close(fd)

  if paramCount() >= 3 and paramStr(1) == "--hold":
    hold(parseInt(paramStr(2)), parseFloat(paramStr(3)))
    quit(0)
  if paramCount() >= 3 and paramStr(1) == "--write":
    writeSynced(paramStr(2), parseInt(paramStr(3)))
    quit(0)

  let self = getAppFilename()

  proc memAvailableBytes(): int64 =
    ## What a new 4-GiB tree could take without pushing the host into
    ## reclaim. Linux: `MemAvailable`. macOS: free + inactive + speculative
    ## + purgeable pages from `vm_stat` (the pages the kernel hands out
    ## without compressing or swapping anything).
    when defined(linux):
      for line in readFile("/proc/meminfo").splitLines():
        if line.startsWith("MemAvailable:"):
          return parseBiggestInt(line.splitWhitespace()[1]) * 1024
      0
    else:
      let (text, code) = execCmdEx("/usr/bin/vm_stat")
      if code != 0: return 0
      var pageSize = 16384'i64
      var pages = 0'i64
      for line in text.splitLines():
        if line.startsWith("Mach Virtual Memory Statistics"):
          let at = line.find("page size of ")
          if at >= 0:
            pageSize = parseBiggestInt(line[at + 13 .. ^1].splitWhitespace()[0])
        for name in ["Pages free:", "Pages inactive:", "Pages speculative:",
                     "Pages purgeable:"]:
          if line.startsWith(name):
            pages += parseBiggestInt(line.split(':')[1].strip().strip(chars = {'.'}))
      pages * pageSize

  proc startDaemon(root, socket: string; capture = true;
                   extra: openArray[string] = []): Process =
    var args = @["--socket", socket,
      "--host-config", root / "host.toml",
      "--host-identity-file", root / "host-id",
      "--observation-db", root / "observations.sqlite3",
      "--estimate-db", root / "est.sqlite",
      "--cpu-milli", "16000",
      "--memory-bytes", $(16 * GiB),
      "--memory-pressure-source", "unavailable"]
    if capture:
      args.add(["--measurement", "capture=on"])
    for arg in extra: args.add(arg)
    startProcess(daemonPath(), env = privateEnv(socket), args = args,
      options = {poStdErrToStdOut})

  proc awaitCapture(socket: string): bool =
    for _ in 0 ..< 600:
      let (code, text) = cli(privateEnv(socket), ["observations", "--json"])
      if code == 0 and "\"capture_enabled\":true" in text:
        return true
      sleep(50)

  proc stoppedStore(daemon: Process; root: string): ObservationStore =
    stopOwned(daemon)
    openObservationStore(root / "observations.sqlite3")

  when defined(linux):
    proc statfs(path: cstring; buf: pointer): cint {.importc,
      header: "<sys/vfs.h>".}

  proc diskBackedDir(): string =
    ## A directory on a real disk: the kernel's IO counters count bytes sent
    ## to storage, and tmpfs sends none. The working directory (the
    ## checkout) first, then the home cache. macOS has no tmpfs on these
    ## paths (APFS), so the first existing candidate is disk-backed.
    const tmpfsMagic = 0x01021994'u64
    for candidate in [getEnv("RUNQUOTA_TEST_DISK_DIR"), getCurrentDir(),
                      getHomeDir() / ".cache"]:
      if candidate.len == 0 or not dirExists(candidate):
        continue
      when defined(linux):
        # `struct statfs` starts with `f_type` (a long) on Linux.
        var fs: array[128, int64]
        if statfs(candidate.cstring, addr fs[0]) == 0 and
            uint64(fs[0]) != tmpfsMagic:
          return candidate
      else:
        return candidate
    ""

  suite "sizing data from the launcher":
    test "job_peak_is_tree_sum":
      # 4 GiB held at once plus headroom for the host: below this the case
      # fails its prerequisite (named, never skipped) rather than pushing a
      # shared host into reclaim.
      prerequisite memAvailableBytes() >= 6 * GiB,
        "fewer than 6 GiB available; this case holds 4 GiB at once"
      let root = scratchDir("rqszpeak")
      defer: removeDir(root)
      let socket = root / "ep" / "d.sock"
      let daemon = startDaemon(root, socket, extra =
        ["--ambient-sample-interval-millis", "0"])
      defer: stopOwned(daemon)
      prerequisite awaitSocket(daemon, socket),
        daemon.startupContext("the daemon did not bind " & socket)
      prerequisite awaitCapture(socket), "capture never came on"
      let script = "for i in 1 2 3 4; do " & quoteShell(self) &
        " --hold 1024 4 & done; wait"
      var env = privateEnv(socket)
      env["RUNQUOTA_MEASUREMENT"] = "sizing-data=on,tree-sampling=off"
      env["RUNQUOTA_PROJECT"] = "sizing-peak"
      let (code, text) = cli(env, ["acquire", "--cpu", "4000", "--mem",
        "64MiB", "--stats-key", "peak-on", "--entry-point", "build", "--",
        "/bin/sh", "-c", script])
      checkpoint text
      check code == 0
      # The control: the same tree with the switch at its default (off).
      var offEnv = privateEnv(socket)
      offEnv["RUNQUOTA_MEASUREMENT"] = "tree-sampling=off"
      let (offCode, offText) = cli(offEnv, ["acquire", "--cpu", "4000",
        "--mem", "64MiB", "--stats-key", "peak-off", "--", "/bin/sh", "-c",
        script])
      checkpoint offText
      check offCode == 0
      let store = stoppedStore(daemon, root)
      var on, off: ExecutionRow
      for row in store.readExecutions():
        if row.commandStatsId == "peak-on": on = row
        if row.commandStatsId == "peak-off": off = row
      echo "peak with sizing-data on: ", on.peakRssBytes div MiB,
        " MiB; off: ", off.peakRssBytes div MiB, " MiB"
      check on.peakRssBytes >= 3900 * MiB
      check off.peakRssBytes < 2 * GiB
      check off.peakRssBytes >= 1000 * MiB
      var profileMax = 0'i64
      var onProfiles, offProfiles = 0
      for p in store.readMemoryProfiles():
        if p.executionId == on.executionId:
          inc onProfiles
          for s in p.samples:
            profileMax = max(profileMax, int64(s))
        if p.executionId == off.executionId:
          inc offProfiles
      echo "memory profile max: ", profileMax, " MiB"
      check onProfiles == 1
      check offProfiles == 0
      check profileMax >= 3900
      # The daemon's own sizing columns, and the declarations.
      check on.requestedAtUnixMillis.isSome
      check on.cpuGrantedMilli == some(4000'i64)
      check on.afterExecutionIds.isNone
      check on.ioWriteBytes.isSome
      check off.ioWriteBytes.isNone
      var found = false
      for run in store.readRuns():
        if run.runId == on.runId:
          found = true
          check run.project == some("sizing-peak")
          check run.entryPoint == some("build")
      check found

    test "write bytes are measured at the root's exit":
      let dir = diskBackedDir()
      prerequisite dir.len > 0, "no disk-backed directory to write in"
      let target = dir / ("rqsz-io-" & $getCurrentProcessId())
      defer: removeFile(target)
      let root = scratchDir("rqszio")
      defer: removeDir(root)
      let socket = root / "ep" / "d.sock"
      let daemon = startDaemon(root, socket, extra =
        ["--ambient-sample-interval-millis", "0"])
      defer: stopOwned(daemon)
      prerequisite awaitSocket(daemon, socket),
        daemon.startupContext("the daemon did not bind " & socket)
      prerequisite awaitCapture(socket), "capture never came on"
      var env = privateEnv(socket)
      env["RUNQUOTA_MEASUREMENT"] = "sizing-data=on"
      # Linux: the writer is a child of the root `sh`, and the kernel folds
      # a reaped child's IO into its parent, so the root's figure includes
      # it. macOS keeps no such share (`proc_pid_rusage` has no child IO
      # fields), so the root must BE the writer: `exec` replaces the shell.
      let writer = quoteShell(self) & " --write " & quoteShell(target) & " 32"
      let script = when defined(linux): "(" & writer & ")" else: "exec " & writer
      let (code, text) = cli(env, ["acquire", "--cpu", "1000", "--mem",
        "64MiB", "--stats-key", "io", "--", "/bin/sh", "-c", script])
      checkpoint text
      check code == 0
      let store = stoppedStore(daemon, root)
      let rows = store.readExecutions()
      check rows.len == 1
      if rows.len == 1:
        echo "io write ", rows[0].ioWriteBytes, " read ", rows[0].ioReadBytes
        check rows[0].ioWriteBytes.isSome
        check rows[0].ioWriteBytes.get(0) >= 32 * MiB

    when defined(macosx):
      test "macos capability record: a reaped child's writes are not the root's":
        # CAPABILITY RECORD (macOS): `proc_pid_rusage` reports a process's
        # OWN storage bytes and has no reaped-children share, so a root that
        # only forks a writer reads low. This measures that on this host and
        # fails if it changes, so the spec's statement (Observation Store §
        # Sizing data and replay) is re-examined when it does.
        let dir = diskBackedDir()
        prerequisite dir.len > 0, "no disk-backed directory to write in"
        let target = dir / ("rqsz-io-child-" & $getCurrentProcessId())
        defer: removeFile(target)
        let root = scratchDir("rqszioc")
        defer: removeDir(root)
        let socket = root / "ep" / "d.sock"
        let daemon = startDaemon(root, socket, extra =
          ["--ambient-sample-interval-millis", "0"])
        defer: stopOwned(daemon)
        prerequisite awaitSocket(daemon, socket),
          daemon.startupContext("the daemon did not bind " & socket)
        prerequisite awaitCapture(socket), "capture never came on"
        var env = privateEnv(socket)
        env["RUNQUOTA_MEASUREMENT"] = "sizing-data=on"
        let (code, text) = cli(env, ["acquire", "--cpu", "1000", "--mem",
          "64MiB", "--stats-key", "iochild", "--", "/bin/sh", "-c",
          "(" & quoteShell(self) & " --write " & quoteShell(target) & " 32)"])
        checkpoint text
        check code == 0
        let store = stoppedStore(daemon, root)
        let rows = store.readExecutions()
        check rows.len == 1
        if rows.len == 1:
          echo "capability: macOS io_write_bytes of a root whose child wrote ",
            "32 MiB: ", rows[0].ioWriteBytes
          check rows[0].ioWriteBytes.isSome
          check rows[0].ioWriteBytes.get(0) < 32 * MiB

    test "after names executions of the same run only":
      let root = scratchDir("rqszafter")
      defer: removeDir(root)
      let socket = root / "ep" / "d.sock"
      let daemon = startDaemon(root, socket, extra =
        ["--ambient-sample-interval-millis", "0"])
      defer: stopOwned(daemon)
      prerequisite awaitSocket(daemon, socket),
        daemon.startupContext("the daemon did not bind " & socket)
      prerequisite awaitCapture(socket), "capture never came on"
      putEnv("RUNQUOTA_ENDPOINT_SCOPE", "private")
      putEnv("RUNQUOTA_SOCKET", socket)
      var client = connectDefault()
      var other = connectDefault()
      var session = client.registerSession("after", "0.1.0", "sizing-after", "build")
      var foreign = other.registerSession("after-other", "0.1.0")
      proc runOne(s: var RunQuotaSession; key: string;
                  sizing = noFinishSizing()): uint64 =
        var request = resourceRequest(key, milliCpu(1000), bytes(64 * MiB))
        request.commandStatsId = key
        var lease = s.requestLease(request)
        lease.markStarting()
        lease.markRunning(childProcessId = uint64(getCurrentProcessId()))
        lease.finish(outcome = succeeded(), sizing = sizing)
        lease.release()
        lease.id.value
      let first = session.runOne("first")
      let foreignLease = foreign.runOne("foreign")
      discard session.runOne("second", FinishSizing(afterKnown: true,
        afterLeases: @[first, foreignLease, 999_999'u64]))
      discard session.runOne("root", FinishSizing(afterKnown: true))
      session.closeSession()
      foreign.closeSession()
      client.close()
      other.close()
      let store = stoppedStore(daemon, root)
      var ids = initTable[string, ExecutionRow]()
      for row in store.readExecutions():
        ids[row.commandStatsId] = row
      check ids["first"].afterExecutionIds.isNone
      check ids["second"].afterExecutionIds == some(@[ids["first"].executionId])
      check ids["root"].afterExecutionIds == some(newSeq[string]())
      for run in store.readRuns():
        if run.runId == ids["first"].runId:
          check run.project == some("sizing-after")

  # ------------------------------------------------------------------------
  # The synthetic store for the replay cases.
  # ------------------------------------------------------------------------

  type Synthetic = object
    hostId, profileId: string

  proc identityOf(store: ObservationStore): Synthetic =
    for profile in store.readHostProfiles():
      if profile.validToUnixMillis.isNone:
        return Synthetic(hostId: profile.hostId, profileId: profile.profileId)

  proc execRow(s: Synthetic; runId, id: string; lease: int64; requested,
               duration, peak: int64; width = 1000'i64;
               complete = true): ExecutionRow =
    ExecutionRow(executionId: id, hostId: s.hostId,
      hostProfileId: some(s.profileId), runId: runId,
      commandStatsId: "key-" & id, leaseId: some(lease),
      startedAtUnixMillis: requested, finishedAtUnixMillis: requested + duration,
      durationMillis: duration, exitStatus: 0, termination: tExited,
      attempt: 1, peakRssBytes: peak,
      cpuUserMillis: some(duration * width div 1000), cpuSysMillis: some(0'i64),
      maxProcesses: 1, majorPageFaults: 0,
      captureCompleteness: if complete: ccComplete else: ccSampled,
      requestedAtUnixMillis: some(requested), cpuGrantedMilli: some(width))

  proc runRow(s: Synthetic; runId, project, entry: string; started: int64;
              complete = true): RunRow =
    RunRow(runId: runId, hostId: s.hostId, tool: "synthetic",
      toolVersion: "1", invocationKind: "build",
      startedAtUnixMillis: started,
      captureCompleteness: if complete: ccComplete else: ccSampled,
      project: some(project), entryPoint: some(entry))

  proc writeSynthetic(store: ObservationStore; s: Synthetic; base: int64) =
    ## Project "synth": 100 complete runs, run k with two 1-CPU, 10-s jobs
    ## requested together: (k+1) * 10 MiB and 5 MiB; one ambient sample per
    ## run inside its window, foreign (k+1) MiB. Five more runs with
    ## incomplete capture and a 50-GiB job each, which would be the maximum
    ## if they were not excluded.
    ##
    ## Project "mix": the shapes the offline replay must agree on --
    ## memory and CPU profiles, a width above N, an `after` chain, a row
    ## from before schema 8 (no request time, no width), write bytes.
    var runs: seq[RunRow] = @[]
    var execs: seq[ExecutionRow] = @[]
    for k in 0 ..< 100:
      let started = base + int64(k) * 60_000
      let runId = "synth-" & $k
      runs.add(s.runRow(runId, "synth", "test", started))
      execs.add(s.execRow(runId, runId & "-a", 1, started, 10_000,
        int64(k + 1) * 10 * MiB))
      execs.add(s.execRow(runId, runId & "-b", 2, started, 10_000, 5 * MiB))
      doAssert store.insertAmbientSample(AmbientSampleRow(hostId: s.hostId,
        sampledAtUnixMillis: started + 5_000, cpuBusyPct: 10.0,
        memAvailableBytes: GiB, foreignRssBytes: int64(k + 1) * MiB))
    for k in 0 ..< 5:
      let started = base + 7_000_000 + int64(k) * 60_000
      let runId = "synth-incomplete-" & $k
      runs.add(s.runRow(runId, "synth", "test", started, complete = false))
      execs.add(s.execRow(runId, runId & "-a", 1, started, 10_000, 50 * GiB,
        complete = false))
    for k in 0 ..< 6:
      let started = base + 9_000_000 + int64(k) * 600_000
      let runId = "mix-" & $k
      runs.add(s.runRow(runId, "mix", "ci/" & $k & "/job",
        started))
      var wide = s.execRow(runId, runId & "-wide", 1, started, 8_000,
        2 * GiB, width = 4000)
      wide.cpuProfileIntervalMillis = 1000
      wide.cpuProfileSamples = @[4000'u16, 4000, 3000, 1000, 1000, 500, 500, 500]
      wide.memoryProfileIntervalMillis = 1000
      wide.memoryProfileSamples = @[100'u16, 900, 1700, 2000, 1200, 300, 300,
        uint16(100 + k * 50)]
      wide.ioWriteBytes = some(int64(k + 1) * 64 * MiB)
      execs.add(wide)
      var previous = runId & "-wide"
      for j in 0 ..< 4:
        var link = s.execRow(runId, runId & "-c" & $j, int64(2 + j),
          started + 100, int64(1_000 + 333 * j + 17 * k), int64(300 + j) * MiB)
        link.afterExecutionIds = some(@[previous])
        previous = link.executionId
        execs.add(link)
      var legacy = s.execRow(runId, runId & "-legacy", 10, started + 2_500,
        2_000, 700 * MiB)
      legacy.requestedAtUnixMillis = none(int64)
      legacy.cpuGrantedMilli = none(int64)
      legacy.cpuUserMillis = none(int64)
      legacy.cpuSysMillis = none(int64)
      execs.add(legacy)
      doAssert store.insertAmbientSample(AmbientSampleRow(hostId: s.hostId,
        sampledAtUnixMillis: started + 1_000, cpuBusyPct: 10.0,
        memAvailableBytes: GiB, foreignRssBytes: int64(200 + k) * MiB))
    doAssert store.appendBatch(runs, execs), store.lastError

  proc sizingJson(socket: string; args: openArray[string]):
      tuple[code: int, json: JsonNode, text: string] =
    let (code, text) = cli(privateEnv(socket), args)
    var node: JsonNode = nil
    try:
      node = parseJson(text)
    except CatchableError:
      discard
    (code, node, text)

  proc exportLines(socket: string; args: openArray[string]): string =
    ## stdout only: the export's status line goes to stderr.
    var process = startProcess(cliPath(), env = privateEnv(socket),
      args = args, options = {})
    defer: process.close()
    result = process.outputStream.readAll()
    discard process.waitForExit()

  proc replayOffline(ndjson: string; args: openArray[string]): JsonNode =
    let node = findExe("node")
    prerequisite node.len > 0, "node is not on PATH (it is in the dev shell)"
    let script = getCurrentDir() / "scripts" / "sizing-replay.mjs"
    prerequisite fileExists(script), "missing " & script
    let input = getTempDir() / ("rqsz-export-" & $getCurrentProcessId() &
      ".ndjson")
    writeFile(input, ndjson)
    defer: removeFile(input)
    let (output, code) = execCmdEx(quoteShell(node) & " " & quoteShell(script) &
      " " & args.mapIt(quoteShell(it)).join(" ") & " " & quoteShell(input))
    checkpoint output
    doAssert code == 0, output
    parseJson(output)

  suite "sizing replay through the daemon":
    let root = scratchDir("rqszreplay")
    let socket = root / "ep" / "d.sock"
    var daemon = startDaemon(root, socket, extra =
      ["--ambient-sample-interval-millis", "0"])
    prerequisite awaitSocket(daemon, socket),
      daemon.startupContext("the daemon did not bind " & socket)
    prerequisite awaitCapture(socket), "capture never came on"
    let store = stoppedStore(daemon, root)
    let identity = store.identityOf()
    prerequisite identity.hostId.len > 0, "the daemon recorded no host profile"
    let base = (getTime().toUnix - 2 * 86_400) * 1000
    store.writeSynthetic(identity, base)
    daemon = startDaemon(root, socket, extra =
      ["--ambient-sample-interval-millis", "0"])
    prerequisite awaitSocket(daemon, socket),
      daemon.startupContext("the daemon did not restart on " & socket)
    prerequisite awaitCapture(socket), "capture never came on again"

    test "quantile_and_baseline_reported":
      let (code, answer, text) = sizingJson(socket, ["sizing", "--project",
        "synth", "--cpus", "1,2", "--quantile", "0.9", "--since", "7d",
        "--all-users", "--json"])
      checkpoint text
      check code == 0
      check answer{"status"}.getStr() == "ok"
      check answer{"runs"}{"replayed"}.getInt() == 100
      check answer{"runs"}{"incomplete"}.getInt() == 5
      check answer{"host_profiles"}.getElems().len == 1
      let one = answer{"sizes"}[0]
      check one{"cpus"}.getInt() == 1
      check one{"memory_quantile_bytes"}.getBiggestInt() == 900 * MiB
      check one{"memory_max_bytes"}.getBiggestInt() == 1000 * MiB
      let two = answer{"sizes"}[1]
      check two{"memory_quantile_bytes"}.getBiggestInt() == 905 * MiB
      check two{"memory_max_bytes"}.getBiggestInt() == 1005 * MiB
      check one{"makespan_quantile_millis"}.getBiggestInt() == 20_000
      check two{"makespan_quantile_millis"}.getBiggestInt() == 10_000
      check answer{"baseline"}{"known"}.getBool()
      check answer{"baseline"}{"samples"}.getInt() == 100
      check answer{"baseline"}{"quantile_bytes"}.getBiggestInt() == 90 * MiB
      check answer{"baseline"}{"max_bytes"}.getBiggestInt() == 100 * MiB
      check two{"total_bytes"}.getBiggestInt() == 995 * MiB
      var mentionsIncomplete = false
      for caveat in answer{"caveats"}.getElems():
        if "incomplete capture" in caveat.getStr(): mentionsIncomplete = true
      check mentionsIncomplete
      # The text form carries the same figures.
      let (textCode, plain) = cli(privateEnv(socket), ["sizing", "--project",
        "synth", "--cpus", "1", "--quantile", "0.9", "--since", "7d",
        "--all-users"])
      check textCode == 0
      check "100 replayed" in plain

    test "offline_replay_matches_daemon":
      # EXACT AGREEMENT, NOT A TOLERANCE. The requirement is that the
      # reference script agree with the daemon within 1%; no tolerance is
      # needed because the replay is defined over integers (ms, bytes,
      # milli-CPUs) with every rounding written out, and the only
      # floating-point value, the quantile, is used the same way by both
      # (IEEE-754 doubles in Nim and JavaScript). Equality is stricter than
      # the 1% bound, so it meets it.
      for project in ["synth", "mix"]:
        for policy in ["default", "strict"]:
          for hostProfile in ["current", "all"]:
            let (code, daemonAnswer, text) = sizingJson(socket, ["sizing",
              "--project", project, "--cpus", "1,2,3,8", "--quantile", "0.95",
              "--since", "7d", "--host-profile", hostProfile, "--all-users",
              "--json"])
            checkpoint text
            check code == 0
            let ndjson = exportLines(socket, ["observations", "export",
              "--format", "sizing", "--project", project, "--since", "7d",
              "--all-users", "--redact", policy])
            let header = parseJson(ndjson.splitLines()[0])
            check header{"redaction"}{"policy"}.getStr() == policy
            let offline = replayOffline(ndjson, ["--cpus", "1,2,3,8",
              "--quantile", "0.95", "--host-profile", hostProfile])
            for field in ["runs", "executions", "baseline", "sizes"]:
              checkpoint project & " " & policy & " " & hostProfile & " " &
                field & ": daemon " & $daemonAnswer{field} & " offline " &
                $offline{field}
            check offline{"runs"} == daemonAnswer{"runs"}
            check offline{"executions"} == daemonAnswer{"executions"}
            check offline{"baseline"} == daemonAnswer{"baseline"}
            check offline{"sizes"} == daemonAnswer{"sizes"}
            # Both policies replace the command shape and the project and
            # entry point names whole: a project name is a directory or
            # repository name, which the safe default may not let through.
            for line in ndjson.splitLines():
              if "\"type\":\"execution\"" in line:
                check "[redacted:command:" in
                  parseJson(line){"command_stats_id"}.getStr()
                break
            for line in ndjson.splitLines():
              if "\"type\":\"run\"" in line:
                let run = parseJson(line)
                check "[redacted:project:" in run{"project"}.getStr()
                check "[redacted:project:" in run{"entry_point"}.getStr()
                break
            check "[redacted:project:" in
              header{"query"}{"project"}.getStr()

    test "measurement capability record is visible in every output":
      # Where a figure is a floor on this OS, the output says so.
      # The record is the host's, computed at query time, not a row field.
      when defined(macosx):
        const
          os = "macos"
          coverage = "partial"
          writeGap = "children's writes are not counted"
          memoryGap = "pages the memory compressor holds are excluded"
      else:
        const
          os = "linux"
          coverage = "full"
          writeGap = ""
          memoryGap = ""
      proc checkRecord(record: JsonNode) =
        check record{"os"}.getStr() == os
        check "daemon runs on" in record{"describes"}.getStr()
        check record{"measurements"}.getElems().len == 2
        for item in record{"measurements"}.getElems():
          check item{"coverage"}.getStr() == coverage
        check record{"measurements"}[0]{"quantity"}.getStr() == "write-bytes"
        for (at, expected) in [(0, writeGap), (1, memoryGap)]:
          let gap = record{"measurements"}[at]{"gap"}.getStr()
          if expected.len > 0: check expected in gap
          else: check gap == ""
      proc checkText(text: string) =
        # Judge the measurement record's own lines, not the whole text:
        # `status` also prints the enforcement record, whose lines carry a
        # ` gap: ` of their own whenever a mechanism is not enforced (always
        # so in this suite, which runs with cgroup placement off). A check
        # over the whole text would read those as a measurement gap.
        check "measurement_os: " & os in text
        var lines: seq[string]
        for line in text.splitLines():
          if line.startsWith("measurement: "):
            lines.add(line)
        checkpoint "measurement lines: " & $lines
        # `check`, not `require`: `require` quits the process and skips the
        # teardown that stops this suite's private daemon.
        check lines.len == 2
        if lines.len != 2: return
        for (at, quantity, expected) in [(0, "write-bytes", writeGap),
            (1, "memory", memoryGap)]:
          check lines[at].startsWith("measurement: " & quantity & " " &
            coverage & " (")
          if expected.len > 0: check " gap: " & expected in lines[at]
          else: check "gap:" notin lines[at]
      let sizingJ = sizingJson(socket, ["sizing", "--project", "synth",
        "--cpus", "1", "--since", "7d", "--all-users", "--json"])
      check sizingJ.code == 0
      checkRecord(sizingJ.json{"measurement"})
      let profileJ = sizingJson(socket, ["profile", "--project", "mix",
        "--since", "7d", "--all-users", "--json"])
      check profileJ.code == 0
      checkRecord(profileJ.json{"measurement"})
      let (_, sizingText) = cli(privateEnv(socket), ["sizing", "--project",
        "synth", "--cpus", "1", "--since", "7d", "--all-users"])
      checkText(sizingText)
      let (_, profileText) = cli(privateEnv(socket), ["profile", "--project",
        "mix", "--since", "7d", "--all-users"])
      checkText(profileText)
      let (statusCode, statusText) = cli(privateEnv(socket), ["status"])
      check statusCode == 0
      checkText(statusText)
      let (jsonCode, statusJsonText) = cli(privateEnv(socket),
        ["status", "--json"])
      check jsonCode == 0
      checkRecord(parseJson(statusJsonText){"measurement"})
      # The export header carries it too; the replay reads past it.
      let ndjson = exportLines(socket, ["observations", "export", "--format",
        "sizing", "--project", "synth", "--since", "7d", "--all-users"])
      checkRecord(parseJson(ndjson.splitLines()[0]){"measurement"})

    test "profile reports per project and entry point":
      let (code, answer, text) = sizingJson(socket, ["profile", "--project",
        "mix", "--since", "7d", "--all-users", "--json"])
      checkpoint text
      check code == 0
      check answer{"profiles"}.getElems().len == 6
      let first = answer{"profiles"}[0]
      check first{"executions"}.getInt() == 6
      check first{"write_bytes_per_sec"}{"count"}.getInt() == 1

    test "a replay asks for a project and counts; a project nobody ran is no-runs":
      let (missing, _) = cli(privateEnv(socket), ["sizing", "--cpus", "2"])
      check missing == 2
      let (noCpus, _) = cli(privateEnv(socket), ["sizing", "--project", "synth"])
      check noCpus == 2
      let (code, answer, text) = sizingJson(socket, ["sizing", "--project",
        "nobody", "--cpus", "2", "--all-users", "--json"])
      checkpoint text
      check code == 3
      check answer{"status"}.getStr() == "no-runs"

    test "rows are the caller's own unless every user is asked for":
      # The synthetic rows carry no owner, so the caller's scope holds none.
      let (code, answer, text) = sizingJson(socket, ["sizing", "--project",
        "synth", "--cpus", "2", "--since", "7d", "--json"])
      checkpoint text
      check code == 3
      check answer{"runs"}{"replayed"}.getInt() == 0

    stopOwned(daemon)
    removeDir(root)

  suite "sizing with capture off":
    test "sizing and profile say capture-off, exit 4":
      let root = scratchDir("rqszoff")
      defer: removeDir(root)
      let socket = root / "ep" / "d.sock"
      let daemon = startDaemon(root, socket, capture = false)
      defer: stopOwned(daemon)
      prerequisite awaitSocket(daemon, socket),
        daemon.startupContext("the daemon did not bind " & socket)
      let (code, answer, text) = sizingJson(socket, ["sizing", "--project",
        "any", "--cpus", "4", "--json"])
      checkpoint text
      check code == 4
      check answer{"status"}.getStr() == "capture-off"
      check answer{"caveats"}.getElems().len >= 1
      let (profileCode, profile, profileText) = sizingJson(socket,
        ["profile", "--json"])
      checkpoint profileText
      check profileCode == 4
      check profile{"status"}.getStr() == "capture-off"
