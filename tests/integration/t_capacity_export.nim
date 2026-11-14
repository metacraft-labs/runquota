## The capacity figures a private `runquotad` keeps for capacity tools,
## read back the two ways it publishes them: `runquota status --json`
## (`capacity`) and the Prometheus text file `--metrics-textfile` writes.
##
## WHAT IS GUARDED.
##
## 1. The used-CPU counter comes from what finishes REPORT. Two leases of a
##    session group finish reporting 10 s and 20 s of CPU in their totals;
##    the group's counter (and the host's) rises by exactly 30 s, and the
##    CPU granted to the group is back to zero once both have finished.
##    The leases are granted 4 CPUs each and held for well under a second,
##    so counting granted width x held time instead of the reported CPU
##    (the falsifying mutation) yields a few CPU-seconds at most and fails.
##    A third finish without totals adds no CPU and is counted as a finish
##    without totals, never as zero CPU.
## 2. The counter saturates. A finish reporting `high(uint64)` user and
##    system time leaves the group's counter at `high(uint64)` and a later
##    finish does not move it; the daemon keeps serving. Falsifying
##    mutation: plain `+` in `saturatingAdd` wraps the counter to a small
##    number.
## 3. The text file is valid: Prometheus's own `promtool check metrics`
##    parses and lints it without a complaint, with group names that need
##    escaping (a double quote, a backslash) and one that is not UTF-8.
##    `promtool` comes from the dev shell; a missing one fails the test.
##    Falsifying mutation: drop the label escaping, and promtool refuses
##    the file.
## 4. A file that cannot be written (its directory is missing) is counted
##    and its reason reported in `runquota status --json`, and the daemon
##    goes on serving leases. Falsifying mutation: do not count a failed
##    write, and the failure count stays at zero.
## 5. The writer is off the admission path. Two daemons hold the same
##    thousand idle session groups with long names, so one rendering of the
##    file is a couple of megabytes; one writes it every 10 ms, the other
##    writes nothing. Lease round trips (request, grant, release) are timed
##    against both in interleaved blocks, and the writer's daemon must be as
##    fast as the other within noise: the median over the paired blocks of
##    the ratio of the two arms' mean round trip is at most 1.3. Falsifying
##    mutation: hold the daemon lock while rendering and writing the file
##    (as an admission-path writer would) -- the lock is then held for most
##    of every interval and the round trips behind it wait.
##
## NO MOCKS: the built `runquotad` and `runquota`, real sessions over real
## sockets, and the real `promtool`.

when defined(linux):
  import std/[algorithm, json, monotimes, os, osproc, streams,
    strutils, times, unittest]

  import runquota_client
  import runquota_core
  import runquota_protocol
  import daemon_binary
  import private_daemon_fixture

  proc startDaemon(root, socket: string; extra: openArray[string];
                   capture = false): Process =
    ## A private daemon whose files are all in `root`. Capture is off unless
    ## asked for: the ambient sampler, whose reading the file carries, runs
    ## only beside a store.
    var args = @["--socket", socket,
      "--host-config", root / "host.toml",
      "--host-identity-file", root / "host-id",
      "--estimate-db", root / "est.sqlite",
      "--cpu-milli", "16000",
      "--memory-pressure-source", "unavailable"]
    if capture:
      args.add(["--observation-db", root / "observations.sqlite3"])
    else:
      args.add("--no-write-stats")
    for arg in extra: args.add(arg)
    startProcess(daemonPath(), env = privateEnv(socket), args = args,
      options = {poStdErrToStdOut})

  proc useDaemon(socket: string) =
    ## Point this process's client library at the private daemon.
    putEnv("RUNQUOTA_ENDPOINT_SCOPE", "private")
    putEnv("RUNQUOTA_SOCKET", socket)

  proc cpuTotals(micros: uint64): FinishTotals =
    FinishTotals(known: true, cpuUserMicros: micros div 4 * 3,
      cpuSysMicros: micros - micros div 4 * 3, durationMillis: 500)

  proc runLease(session: var RunQuotaSession; cpuMilli: uint32;
                totals: FinishTotals) =
    ## One lease, granted, run and finished with `totals`, then released.
    var request = resourceRequest("capacity", milliCpu(cpuMilli),
      bytes(64'u64 * 1024'u64 * 1024'u64))
    var lease = session.requestLease(request)
    prerequisite lease.active, "the lease was not granted"
    lease.markStarting()
    lease.markRunning(childProcessId = uint64(getCurrentProcessId()))
    lease.finish(outcome = succeeded(), totals = totals)
    lease.release()

  proc u64(node: JsonNode): uint64 =
    ## A JSON integer that may exceed `int64`: std/json keeps those as the
    ## number's text.
    if node.kind == JInt: uint64(node.getBiggestInt)
    else: parseBiggestUInt(node.getStr)

  proc parseRaw(text: string): JsonNode =
    ## `parseJson` with big integers kept as text.
    parseJson(newStringStream(text), "", rawIntegers = true)

  proc rawCapacity(socket: string): JsonNode =
    let (code, text) = cli(privateEnv(socket), ["status", "--json"])
    prerequisite code == 0, "runquota status --json exit " & $code
    parseRaw(text)["capacity"]

  proc rawGroup(cap: JsonNode; name: string): JsonNode =
    for group in cap["groups"]:
      if group["name"].getStr == name:
        return group
    newJNull()

  suite "the used-CPU counter":
    test "two finishes reporting 10 s and 20 s raise the group's counter by 30 s":
      let root = scratchDir("rqcap")
      defer: removeDir(root)
      let socket = root / "ep" / "d.sock"
      let daemon = startDaemon(root, socket, ["--ambient-sample-interval-millis", "0"])
      defer: stopOwned(daemon)
      prerequisite awaitSocket(daemon, socket),
        daemon.startupContext("the daemon did not bind " & socket)
      useDaemon(socket)
      var client = connectDefault()
      defer: client.close()
      var session = client.registerSession("capacity", "0.1.0",
        SessionGroupDeclaration(name: "cap-build"))
      # A lease that holds capacity while the figures are read, so
      # "granted" is seen to be live before it is seen to drop.
      var held = session.requestLease(resourceRequest("held",
        milliCpu(2000), bytes(256'u64 * 1024'u64 * 1024'u64)))
      prerequisite held.active, "the held lease was not granted"
      let before = rawCapacity(socket)
      let groupBefore = before.rawGroup("cap-build")
      check groupBefore.kind == JObject
      check groupBefore["cpu_granted_milli"].u64 == 2000
      check groupBefore["memory_reserved_bytes"].u64 == 256'u64 * 1024 * 1024
      check groupBefore["cpu_used_micros"].u64 == 0
      session.runLease(4000, cpuTotals(10_000_000))
      session.runLease(4000, cpuTotals(20_000_000))
      held.release()
      let after = rawCapacity(socket)
      let group = after.rawGroup("cap-build")
      checkpoint $after
      check group["cpu_used_micros"].u64 == 30_000_000'u64
      check after["host"]["cpu_used_micros"].u64 == 30_000_000'u64
      check group["finished_with_totals"].u64 == 2
      check group["cpu_granted_milli"].u64 == 0
      check group["memory_reserved_bytes"].u64 == 0
      check after["host"]["cpu_granted_milli"].u64 == 0
      # Three grants: the held lease and the two that finished.
      check group["grants"].u64 == 3
      # A finish without totals is a finish the counter does not cover.
      session.runLease(4000, FinishTotals(known: false))
      let missing = rawCapacity(socket).rawGroup("cap-build")
      check missing["cpu_used_micros"].u64 == 30_000_000'u64
      check missing["finished_with_totals"].u64 == 2
      check missing["finished_without_totals"].u64 == 1
      session.closeSession()
      # The group outlives its last session: its counter stays readable.
      let closed = rawCapacity(socket).rawGroup("cap-build")
      check closed.kind == JObject
      check closed["cpu_used_micros"].u64 == 30_000_000'u64

    test "a client's out-of-range CPU saturates the counter instead of wrapping":
      let root = scratchDir("rqcapsat")
      defer: removeDir(root)
      let socket = root / "ep" / "d.sock"
      let daemon = startDaemon(root, socket, ["--ambient-sample-interval-millis", "0"])
      defer: stopOwned(daemon)
      prerequisite awaitSocket(daemon, socket),
        daemon.startupContext("the daemon did not bind " & socket)
      useDaemon(socket)
      var client = connectDefault()
      defer: client.close()
      var session = client.registerSession("capacity", "0.1.0",
        SessionGroupDeclaration(name: "cap-saturate"))
      session.runLease(1000, cpuTotals(5_000_000))
      session.runLease(1000, FinishTotals(known: true,
        cpuUserMicros: high(uint64), cpuSysMicros: high(uint64)))
      session.runLease(1000, cpuTotals(5_000_000))
      session.closeSession()
      check daemon.running
      let cap = rawCapacity(socket)
      check cap.rawGroup("cap-saturate")["cpu_used_micros"].u64 == high(uint64)
      check cap["host"]["cpu_used_micros"].u64 == high(uint64)
      check cap.rawGroup("cap-saturate")["finished_with_totals"].u64 == 3

  proc awaitFileWith(path, needle: string; budgetMillis = 30_000): string =
    let deadline = getMonoTime() + initDuration(milliseconds = budgetMillis)
    while getMonoTime() < deadline:
      if fileExists(path):
        let text = readFile(path)
        if needle in text:
          return text
      sleep(20)
    ""

  suite "the metrics text file":
    test "promtool parses and lints it, with names that need escaping":
      let promtool = findExe("promtool")
      check promtool.len > 0
      if promtool.len == 0:
        echo "promtool is not on PATH; run inside the dev shell"
      else:
        let root = scratchDir("rqcaptext")
        defer: removeDir(root)
        let socket = root / "ep" / "d.sock"
        let textfile = root / "runquota.prom"
        let daemon = startDaemon(root, socket,
          ["--ambient-sample-interval-millis", "100",
           "--metrics-textfile", textfile,
           "--metrics-interval-millis", "100"], capture = true)
        defer: stopOwned(daemon)
        prerequisite awaitSocket(daemon, socket),
          daemon.startupContext("the daemon did not bind " & socket)
        useDaemon(socket)
        var client = connectDefault()
        defer: client.close()
        let names = ["plain", "quote\"d", "back\\slash", "not-utf8-\xff\xfe"]
        for name in names:
          var session = client.registerSession("capacity", "0.1.0",
            SessionGroupDeclaration(name: name))
          session.runLease(1000, cpuTotals(1_500_000))
          session.runLease(1000, FinishTotals(known: false))
          session.closeSession()
        # Every finish is in the file once the host's count of finishes
        # without totals reaches four; the ambient reading once the sampler
        # has had a lease live over a pair of its readings.
        var text = awaitFileWith(textfile,
          "runquota_host_finished_leases_total{totals=\"missing\"} 4")
        check text.len > 0
        block:
          var held = connectDefault()
          defer: held.close()
          var session = held.registerSession("capacity", "0.1.0",
            SessionGroupDeclaration(name: "plain"))
          var lease = session.requestLease(resourceRequest("held",
            milliCpu(1000), bytes(64'u64 * 1024'u64 * 1024'u64)))
          text = awaitFileWith(textfile, "runquota_host_cpu_busy_ratio ")
          lease.release()
          session.closeSession()
        check text.len > 0
        checkpoint text
        let (output, code) = execCmdEx(quoteShell(promtool) &
          " check metrics < " & quoteShell(textfile))
        checkpoint output
        check code == 0
        check output.strip().len == 0
        check "runquota_group_cpu_used_seconds_total{owner_uid=\"" in text
        check "group=\"quote\\\"d\"" in text
        check "group=\"back\\\\slash\"" in text
        check "group_hex=\"" & toHex("not-utf8-\xff\xfe").toLowerAscii() &
          "\"" in text
        check "runquota_host_cpu_used_seconds_total 6.000000" in text
        check "runquota_host_finished_leases_total{totals=\"missing\"} 4" in text
        let status = rawCapacity(socket)
        check status["textfile"]["writes"].u64 > 0
        check status["textfile"]["failures"].u64 == 0

    test "a file that cannot be written is reported, and leases still served":
      let root = scratchDir("rqcapfail")
      defer: removeDir(root)
      let socket = root / "ep" / "d.sock"
      let textfile = root / "missing-dir" / "runquota.prom"
      let daemon = startDaemon(root, socket,
        ["--ambient-sample-interval-millis", "0",
         "--metrics-textfile", textfile,
         "--metrics-interval-millis", "50"])
      defer: stopOwned(daemon)
      prerequisite awaitSocket(daemon, socket),
        daemon.startupContext("the daemon did not bind " & socket)
      useDaemon(socket)
      var client = connectDefault()
      defer: client.close()
      var session = client.registerSession("capacity", "0.1.0",
        SessionGroupDeclaration(name: "cap-fail"))
      session.runLease(1000, cpuTotals(1_000_000))
      session.closeSession()
      var status = rawCapacity(socket)
      let deadline = getMonoTime() + initDuration(seconds = 30)
      while status["textfile"]["failures"].u64 == 0 and
          getMonoTime() < deadline:
        sleep(50)
        status = rawCapacity(socket)
      checkpoint $status["textfile"]
      check status["textfile"]["failures"].u64 > 0
      check status["textfile"]["writes"].u64 == 0
      check "missing-dir" in status["textfile"]["last_error"].getStr
      check status.rawGroup("cap-fail")["cpu_used_micros"].u64 == 1_000_000
      check daemon.running

  proc percentile(sorted: seq[float64]; q: float64): float64 =
    sorted[min(sorted.high, int(q * float64(sorted.len)))]

  proc mean(values: seq[float64]): float64 =
    for v in values: result += v
    result / float64(values.len)

  proc timeRoundTrips(socket: string; count: int; into: var seq[float64]) =
    ## `count` lease round trips (request until granted, then release) on
    ## one session, each timed in microseconds.
    useDaemon(socket)
    var client = connectDefault()
    defer: client.close()
    var session = client.registerSession("latency", "0.1.0",
      SessionGroupDeclaration(name: "latency"))
    defer: session.closeSession()
    for _ in 0 ..< count:
      let started = getMonoTime()
      var lease = session.requestLease(resourceRequest("probe",
        milliCpu(1000), bytes(16'u64 * 1024'u64 * 1024'u64)))
      prerequisite lease.active, "a probe lease was not granted"
      lease.release()
      into.add(float64((getMonoTime() - started).inNanoseconds) / 1000.0)

  proc fillGroups(socket: string; groups: int) =
    ## `groups` idle session groups with 128-byte names, each with one
    ## finished lease, so the figures (and the file) are large.
    useDaemon(socket)
    var client = connectDefault()
    defer: client.close()
    for i in 0 ..< groups:
      let name = align($i, 6, '0') & "-" & repeat('g', MaxSessionGroupBytes - 7)
      var session = client.registerSession("filler", "0.1.0",
        SessionGroupDeclaration(name: name))
      session.runLease(1000, cpuTotals(1_000_000))
      session.closeSession()

  suite "the writer is off the admission path":
    test "lease round trips are as fast with the writer on as with it off":
      let root = scratchDir("rqcaplat")
      defer: removeDir(root)
      let onSocket = root / "on" / "ep" / "d.sock"
      let offSocket = root / "off" / "ep" / "d.sock"
      for arm in ["on", "off"]:
        createDir(root / arm)
        setFilePermissions(root / arm, {fpUserRead, fpUserWrite, fpUserExec})
      let textfile = root / "runquota.prom"
      let onDaemon = startDaemon(root / "on", onSocket,
        ["--ambient-sample-interval-millis", "0",
         "--metrics-textfile", textfile,
         "--metrics-interval-millis", "10"])
      defer: stopOwned(onDaemon)
      let offDaemon = startDaemon(root / "off", offSocket,
        ["--ambient-sample-interval-millis", "0"])
      defer: stopOwned(offDaemon)
      prerequisite awaitSocket(onDaemon, onSocket),
        onDaemon.startupContext("the daemon did not bind " & onSocket)
      prerequisite awaitSocket(offDaemon, offSocket),
        offDaemon.startupContext("the daemon did not bind " & offSocket)
      const
        Groups = 1000
        Rounds = 20
        BlockTrips = 1000
        MaxRatio = 1.3
      fillGroups(onSocket, Groups)
      fillGroups(offSocket, Groups)
      # The writer must really be rendering the large file.
      let last = align($(Groups - 1), 6, '0') & "-"
      prerequisite awaitFileWith(textfile, last).len > 1_000_000,
        "the writer never wrote the thousand groups"
      let writesBefore = rawCapacity(onSocket)["textfile"]["writes"].u64
      let fileBytes = getFileSize(textfile)
      let measureStarted = getMonoTime()
      var onTimes, offTimes, ratios: seq[float64]
      # Warm-up, discarded.
      var discarded: seq[float64]
      timeRoundTrips(onSocket, 200, discarded)
      timeRoundTrips(offSocket, 200, discarded)
      for round in 0 ..< Rounds:
        # Alternate which goes first, so drift lands on both.
        var onBlock, offBlock: seq[float64]
        if round mod 2 == 0:
          timeRoundTrips(onSocket, BlockTrips, onBlock)
          timeRoundTrips(offSocket, BlockTrips, offBlock)
        else:
          timeRoundTrips(offSocket, BlockTrips, offBlock)
          timeRoundTrips(onSocket, BlockTrips, onBlock)
        ratios.add(mean(onBlock) / mean(offBlock))
        onTimes.add(onBlock)
        offTimes.add(offBlock)
      let measuredMillis = (getMonoTime() - measureStarted).inMilliseconds
      let status = rawCapacity(onSocket)
      let writes = status["textfile"]["writes"].u64 - writesBefore
      onTimes.sort()
      offTimes.sort()
      ratios.sort()
      let ratio = percentile(ratios, 0.5)
      proc figures(times: seq[float64]): string =
        "mean " & formatFloat(mean(times), ffDecimal, 1) & " p50 " &
          formatFloat(percentile(times, 0.5), ffDecimal, 1) & " p95 " &
          formatFloat(percentile(times, 0.95), ffDecimal, 1) & " p99 " &
          formatFloat(percentile(times, 0.99), ffDecimal, 1)
      let line = "round trip us: writer on " & figures(onTimes) &
        "; writer off " & figures(offTimes) & "; median per-round ratio " &
        "of means " & formatFloat(ratio, ffDecimal, 3) & "; " & $writes &
        " files of " & $fileBytes & " bytes written in " & $measuredMillis &
        " ms"
      echo line
      checkpoint line
      # The writer ran throughout: at least one file per 200 ms.
      check writes >= uint64(measuredMillis div 200)
      check status["textfile"]["failures"].u64 == 0
      # WITHIN NOISE: the median over the paired rounds of the ratio of the
      # two arms' mean round trip. A median of paired ratios shrugs off the
      # rounds a busy host spoils in one arm, which a pooled mean does not;
      # the mean is the statistic because a lock held by the writer shows
      # as a minority of long waits, which a percentile can step over.
      check ratio <= MaxRatio
