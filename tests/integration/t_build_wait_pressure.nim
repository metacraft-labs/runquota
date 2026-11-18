## Build-wait pressure end to end against a private `runquotad`: reports
## sent by real clients over real sockets, and the figures read back the
## ways the daemon publishes them (`QueryPressure`, `runquota pressure`,
## `runquota status --json` and the metrics text file).
##
## WHAT IS GUARDED, and the mutation each check fails under.
##
## 1. A report is counted for its session, its group and the host; a
##    report naming that session from ANOTHER connection is refused and
##    counted, and changes nothing. Mutation: drop the ownership check in
##    the daemon's `rqPressureReport` branch, and the group's totals grow by
##    the second report.
## 2. Reports cannot claim more wall time than their session has existed:
##    fifty reports of 10^12 µs each from a fresh session are credited about
##    a second IN ALL. Mutations: drop the wall clamp (`clampReport`'s first
##    `min`), and the total is 5 * 10^13; grant the one-second slack per
##    report instead of per session, and it is about fifty seconds.
## 3. `runquota run` reports its queue wait, with `queue_only`. A one-CPU
##    daemon whose long-wait threshold is 2 s; the test holds the CPU for
##    2.5 s while a `runquota run` with `pressure-reports=on` waits for it.
##    The run's group shows one queue wait, counted as long, *some* and
##    *full* of at least 2.4 s, and so does the host. With the switch off
##    (the default) the same run reports nothing. Mutations: report the
##    wait before the grant (zero length), or ignore the switch.
## 4. The finish answers the expected uncontended duration when asked, and
##    reads it BEFORE folding the finish in: the first finish of a key
##    learns 0, the second the first run's 1000 ms. Mutation: fold before
##    reading, and the first finish learns its own duration. A sampler that
##    took no reading in a run's judged window is refused as a precondition
##    (the host's load), not failed as a learned 0. A first lease granted
##    before the store is installed is covered by
##    `libs/runquota_daemon/tests/t_lease_live_before_capture_is_sampled`.
## 5. The text file carries the pressure series and still passes
##    `promtool check metrics`; `status --json` carries `pressure`; and
##    `runquota pressure --group` filters to one group.
##
## Long waits of 310 s are covered with an injected clock in
## `libs/runquota_daemon/tests/t_pressure_metrics`; here the threshold is
## lowered with the daemon's own flag so a real wait can cross it.
##
## NO MOCKS: the built `runquotad` and `runquota`, real sessions, the real
## `promtool`.

when defined(linux) or defined(macosx):
  import std/[json, monotimes, os, osproc, streams, strtabs, strutils, times,
    unittest]

  import runquota_client
  import runquota_core
  import runquota_protocol
  import daemon_binary
  import private_daemon_fixture

  proc startDaemon(root, socket: string; extra: openArray[string];
                   capture = false): Process =
    var args = @["--socket", socket,
      "--host-config", root / "host.toml",
      "--host-identity-file", root / "host-id",
      "--estimate-db", root / "est.sqlite",
      "--memory-pressure-source", "unavailable"]
    if capture:
      args.add(["--observation-db", root / "observations.sqlite3",
        "--measurement", "capture=on"])
    else:
      args.add(["--no-write-stats", "--ambient-sample-interval-millis", "0"])
    for arg in extra: args.add(arg)
    startProcess(daemonPath(), env = privateEnv(socket), args = args,
      options = {poStdErrToStdOut})

  proc useDaemon(socket: string) =
    putEnv("RUNQUOTA_ENDPOINT_SCOPE", "private")
    putEnv("RUNQUOTA_SOCKET", socket)

  proc awaitStatus(socket, what: string; ready: proc (status: JsonNode): bool):
      bool =
    ## Poll `runquota status --json` until `ready` holds (30 s bound).
    ## The tests below time their windows from an observed event, not from
    ## a process start: on a loaded host a freshly started `runquota run`
    ## or daemon sampler can need seconds before it does anything, and a
    ## window timed from the start would then measure the host's load.
    let deadline = getMonoTime() + initDuration(seconds = 30)
    while getMonoTime() < deadline:
      let (code, text) = cli(privateEnv(socket), ["status", "--json"])
      if code == 0 and ready(parseJson(text)):
        return true
      sleep(20)
    checkpoint "never observed: " & what
    false

  proc hasPendingRequest(status: JsonNode): bool =
    status["capacity"]["host"]["pending_requests"].getInt > 0

  proc hasAmbientReading(status: JsonNode): bool =
    status["capacity"]["host"]["ambient_reading_unix_millis"].kind == JInt

  proc groupOf(answer: JsonNode; name: string): JsonNode =
    for group in answer["groups"]:
      if group["name"].getStr == name:
        return group
    newJNull()

  proc someTotal(scope: JsonNode): int64 =
    scope["some"]["total_micros"].getBiggestInt

  suite "reports and their owner":
    test "a report counts for its session, group and host, and not from another connection":
      let root = scratchDir("rqpress")
      defer: removeDir(root)
      let socket = root / "ep" / "d.sock"
      let daemon = startDaemon(root, socket, ["--cpu-milli", "4000"])
      defer: stopOwned(daemon)
      prerequisite awaitSocket(daemon, socket),
        daemon.startupContext("the daemon did not bind " & socket)
      useDaemon(socket)
      var client = connectDefault()
      defer: client.close()
      prerequisite client.supportsPressure(), "the daemon predates pressure"
      var session = client.registerSession("pressure", "0.1.0",
        SessionGroupDeclaration(name: "press-a"))
      sleep(300)
      check session.reportPressure(PressureReportMessage(wallMicros: 250_000,
        someMicros: 200_000, fullMicros: 50_000, waits: @[PressureWait(
          startedAtUnixMillis: 1, lengthMillis: 1_200, kind: pwkQueue)]))
      # The query travels on the same connection, after the one-way report.
      var answer = parseJson(client.queryPressure())
      checkpoint $answer
      let group = answer.groupOf("press-a")
      check group.kind == JObject
      check group.someTotal == 200_000
      check group["full"]["total_micros"].getBiggestInt == 50_000
      check group["wall_micros"].getBiggestInt == 250_000
      check group["waits"]["queue"]["count"].getInt == 1
      check answer["host"].someTotal == 200_000
      check answer["sessions"].len == 1
      check answer["sessions"][0]["group"].getStr == "press-a"
      check answer["reports_refused"].getInt == 0
      # Another connection names that session: refused, counted, ignored.
      var other = connectDefault()
      defer: other.close()
      var otherSession = other.registerSession("intruder", "0.1.0")
      var forged = RunQuotaSession(client: addr other, id: session.id,
        active: true)
      check forged.reportPressure(PressureReportMessage(wallMicros: 100_000,
        someMicros: 100_000, fullMicros: 100_000))
      answer = parseJson(other.queryPressure())
      checkpoint $answer
      check answer["reports_refused"].getInt == 1
      check answer.groupOf("press-a").someTotal == 200_000
      check answer["host"].someTotal == 200_000
      otherSession.closeSession()
      session.closeSession()

    test "a report cannot claim more wall time than its session has existed":
      let root = scratchDir("rqpressclamp")
      defer: removeDir(root)
      let socket = root / "ep" / "d.sock"
      let daemon = startDaemon(root, socket, ["--cpu-milli", "4000"])
      defer: stopOwned(daemon)
      prerequisite awaitSocket(daemon, socket),
        daemon.startupContext("the daemon did not bind " & socket)
      useDaemon(socket)
      var client = connectDefault()
      defer: client.close()
      # Taken before the registration: the daemon's allowance runs from it.
      let started = getMonoTime()
      var session = client.registerSession("pressure", "0.1.0",
        SessionGroupDeclaration(name: "press-clamp"))
      # Many reports, each claiming far more than the session has lived:
      # the session's credited wall time is bounded in total, not per
      # report.
      for i in 0 ..< 50:
        check session.reportPressure(PressureReportMessage(
          wallMicros: 1_000_000_000_000'u64, someMicros: high(uint64),
          fullMicros: high(uint64)))
      let answer = parseJson(client.queryPressure(psGroups, "press-clamp"))
      let elapsedMicros = (getMonoTime() - started).inMicroseconds
      checkpoint $answer
      let group = answer.groupOf("press-clamp")
      # The daemon's clock counts whole milliseconds, so the session's age
      # as it sees it can exceed this test's measurement by up to one.
      check group["wall_micros"].getBiggestInt <=
        1_000_000 + elapsedMicros + 1_000
      check group.someTotal == group["wall_micros"].getBiggestInt
      check not answer.hasKey("host")
      session.closeSession()

  suite "runquota run":
    proc runQueuedBehindHolder(root: string; measurement: string): JsonNode =
      ## A one-CPU daemon; the test holds the CPU for 2.5 s while
      ## `runquota run` waits for it, then reads the run's group.
      let socket = root / "ep" / "d.sock"
      let daemon = startDaemon(root, socket, ["--cpu-milli", "1000",
        "--pressure-long-wait-millis", "2000"])
      defer: stopOwned(daemon)
      prerequisite awaitSocket(daemon, socket),
        daemon.startupContext("the daemon did not bind " & socket)
      useDaemon(socket)
      var client = connectDefault()
      defer: client.close()
      var session = client.registerSession("holder", "0.1.0")
      var held = session.requestLease(resourceRequest("held", milliCpu(1000),
        bytes(64'u64 * 1024'u64 * 1024'u64)))
      prerequisite held.active, "the holder was not granted"
      var env = privateEnv(socket)
      env["RUNQUOTA_SESSION"] = "press-run"
      if measurement.len > 0:
        env["RUNQUOTA_MEASUREMENT"] = measurement
      else:
        env.del("RUNQUOTA_MEASUREMENT")
      var run = startProcess(cliPath(), env = env,
        args = ["run", "--width", "1", "--", "true"],
        options = {poStdErrToStdOut})
      defer: run.close()
      # Time the hold from the moment the run's request is queued, so the
      # run's wait is at least the hold however long its start-up took.
      prerequisite awaitStatus(socket, "the run's request queued",
        hasPendingRequest), "the run never queued behind the holder"
      sleep(2500)
      held.release()
      let code = run.waitForExit(30_000)
      checkpoint run.outputStream.readAll()
      check code == 0
      session.closeSession()
      result = parseJson(client.queryPressure())

    test "it reports its queue wait, counted as long past the threshold":
      let root = scratchDir("rqpressrun")
      defer: removeDir(root)
      let answer = runQueuedBehindHolder(root, "pressure-reports=on")
      checkpoint $answer
      let group = answer.groupOf("press-run")
      check group.kind == JObject
      if group.kind == JObject:
        check group["waits"]["queue"]["count"].getInt == 1
        check group["waits"]["queue"]["long_waits"].getInt == 1
        check group["queue_only_reports"].getInt >= 1
        check group.someTotal >= 2_400_000
        check group["full"]["total_micros"].getBiggestInt >= 2_400_000
        check group["waits"]["queue"]["sum_millis"].getInt >= 2_400
      check answer["host"]["waits"]["queue"]["long_waits"].getInt == 1

    test "with the switch off (the default) it reports nothing":
      let root = scratchDir("rqpressoff")
      defer: removeDir(root)
      let answer = runQueuedBehindHolder(root, "")
      checkpoint $answer
      check answer.groupOf("press-run").kind == JNull
      check answer["host"]["reports"].getInt == 0

  suite "the expected uncontended duration":
    test "the finish answers it, read before the finish is folded in":
      let root = scratchDir("rqpressexp")
      defer: removeDir(root)
      let socket = root / "ep" / "d.sock"
      let daemon = startDaemon(root, socket, ["--cpu-milli", "4000",
        "--ambient-sample-interval-millis", "100",
        "--profile-uncontended-pct", "100"], capture = true)
      defer: stopOwned(daemon)
      prerequisite awaitSocket(daemon, socket),
        daemon.startupContext("the daemon did not bind " & socket)
      useDaemon(socket)
      var client = connectDefault()
      defer: client.close()
      # The first finish is judged against the ambient samples of its run's
      # window; none yet (the sampler's first readings still pending) makes
      # it unjudged and it would learn nothing.
      prerequisite awaitStatus(socket, "an ambient reading",
        hasAmbientReading), "the ambient sampler took no reading"
      var session = client.registerSession("pressure", "0.1.0")
      var learned: seq[uint64]
      for i in 0 ..< 2:
        var request = resourceRequest("expect", milliCpu(1000),
          bytes(64'u64 * 1024'u64 * 1024'u64))
        request.commandStatsId = "pressure-expected-key"
        var lease = session.requestLease(request)
        prerequisite lease.active, "the lease was not granted"
        lease.markStarting()
        lease.markRunning(childProcessId = uint64(getCurrentProcessId()))
        # Ambient samples must cover the run for the daemon to judge it.
        sleep(1300)
        # A sampler starved through the whole judged window (the run's last
        # 1000 ms) leaves the run unjudged. That is the host's load, not a
        # regression, so it is refused as a named precondition rather than
        # failed as a learned 0. One read, not a poll: waiting here would
        # move the finish, and its window, past the reading.
        let windowStart = (getTime() - initDuration(milliseconds = 1000))
          .toUnixFloat * 1000.0
        let (statusCode, statusText) =
          cli(privateEnv(socket), ["status", "--json"])
        prerequisite statusCode == 0, "runquota status failed: " & statusText
        let readAt = parseJson(statusText)["capacity"]["host"][
          "ambient_reading_unix_millis"]
        prerequisite readAt.kind == JInt and
          float64(readAt.getBiggestInt) > windowStart,
          "the ambient sampler took no reading in the run's judged window"
        lease.finish(outcome = succeeded(), totals = FinishTotals(known: true,
          cpuUserMicros: 1000, durationMillis: 1000),
          askExpectedDuration = true)
        learned.add(lease.expectedUncontendedMillis)
        lease.release()
      checkpoint $learned
      check learned == @[0'u64, 1000'u64]
      session.closeSession()

  suite "where the figures are published":
    test "the text file, status --json and runquota pressure carry them":
      let promtool = findExe("promtool")
      check promtool.len > 0
      let root = scratchDir("rqpresspub")
      defer: removeDir(root)
      let socket = root / "ep" / "d.sock"
      let textfile = root / "runquota.prom"
      let daemon = startDaemon(root, socket, ["--cpu-milli", "4000",
        "--metrics-textfile", textfile, "--metrics-interval-millis", "100"])
      defer: stopOwned(daemon)
      prerequisite awaitSocket(daemon, socket),
        daemon.startupContext("the daemon did not bind " & socket)
      useDaemon(socket)
      var client = connectDefault()
      defer: client.close()
      var sessions: seq[RunQuotaSession]
      for name in ["press-pub", "press-other"]:
        sessions.add(client.registerSession("pressure", "0.1.0",
          SessionGroupDeclaration(name: name)))
      sleep(200)
      for i in 0 ..< sessions.len:
        check sessions[i].reportPressure(PressureReportMessage(
          wallMicros: 150_000, someMicros: 100_000, fullMicros: 10_000,
          waits: @[PressureWait(startedAtUnixMillis: 1, lengthMillis: 1_100,
            kind: pwkQueue)]))
      discard client.queryPressure()
      let needle = "runquota_group_pressure_some_seconds_total{owner_uid=\""
      var text = ""
      let deadline = getMonoTime() + initDuration(seconds = 30)
      while getMonoTime() < deadline:
        if fileExists(textfile):
          text = readFile(textfile)
          if needle in text and "group=\"press-other\"" in text:
            break
        sleep(50)
      checkpoint text
      check needle in text
      check "runquota_host_pressure_some_seconds_total 0.200000" in text
      check "runquota_host_pressure_long_waits_total{kind=\"queue\"} 0" in text
      check "runquota_host_pressure_wait_seconds_bucket{kind=\"queue\",le=\"2\"} 2" in text
      if promtool.len > 0:
        let (output, code) = execCmdEx(quoteShell(promtool) &
          " check metrics < " & quoteShell(textfile))
        checkpoint output
        check code == 0
        check output.strip().len == 0
      let (statusCode, statusText) = cli(privateEnv(socket), ["status", "--json"])
      check statusCode == 0
      let status = parseJson(statusText)
      check status["pressure"]["host"]["reports"].getInt == 2
      let (jsonCode, jsonText) = cli(privateEnv(socket),
        ["pressure", "--group", "press-pub", "--json"])
      check jsonCode == 0
      let filtered = parseJson(jsonText)
      check filtered["groups"].len == 1
      check filtered["groups"][0]["name"].getStr == "press-pub"
      # The sessions are filtered the same way.
      check filtered["sessions"].len == 1
      check filtered["sessions"][0]["group"].getStr == "press-pub"
      let (textCode, plain) = cli(privateEnv(socket), ["pressure"])
      checkpoint plain
      check textCode == 0
      check "group press-pub" in plain
      check "some  avg10=" in plain
      let (badCode, _) = cli(privateEnv(socket), ["pressure", "--bogus"])
      check badCode == 2
      for i in 0 ..< sessions.len:
        sessions[i].closeSession()
