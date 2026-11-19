## Build-wait pressure end to end against a private `runquotad` ON WINDOWS:
## reports sent by real clients over a real named pipe, and the figures read
## back the ways the daemon publishes them (`QueryPressure`, `runquota
## pressure`, `runquota status --json` and the metrics text file).
##
## THE WINDOWS ARM of `tests/integration/t_build_wait_pressure.nim`. That file
## is `when defined(linux):` and drives `private_daemon_fixture`, a Unix-socket
## daemon under the `private` endpoint scope -- neither exists here. Windows
## has no `private` scope (the daemon refuses it) and no Unix socket; the
## transport is a named pipe under `host` scope, which `windows_daemon_fixture`
## isolates with a pipe name no concurrent run collides with. The aggregation,
## the clamps, the switch and the wire form are the same code on every
## platform; this file proves the MECHANISM runs over the Windows transport.
##
## WHAT IS GUARDED, and the mutation each check fails under.
##
## * A report is counted for its session, its group and the host; a report
##   naming that session from ANOTHER connection is refused and counted, and
##   changes nothing. Mutation: drop the ownership check in the daemon's
##   `rqPressureReport` branch, and the group's totals grow by the second
##   report.
## * `runquota run` reports its queue wait, with `queue_only`. A one-CPU
##   daemon whose long-wait threshold is 2 s; the test holds the CPU for 2.5 s
##   while a `runquota run` with `pressure-reports=on` waits for it. The run's
##   group shows one queue wait, counted as long, *some* and *full* of at
##   least 2.4 s, and so does the host, and `runquota pressure`, `runquota
##   pressure --json` and `status --json` read them back. With the switch off
##   (the default) the same run reports nothing. Mutation: report the wait
##   before the grant (zero length), or ignore the switch.
## * The text file carries the pressure series, and `runquota pressure --group`
##   filters to one group; `promtool check metrics` validates the file when it
##   is on PATH (as the Linux file does, it tolerates its absence).
##
## Long waits of 310 s and the arithmetic of the averages are covered with an
## injected clock in `libs/runquota_daemon/tests/t_pressure_metrics` (which the
## Windows gate runs); here the threshold is lowered with the daemon's own flag
## so a real wait can cross it. The expected-uncontended-duration case (Linux
## behaviour 4) needs capture on, hence an `sqlite3` observation store, which
## this host's PATH does not provide, so it is left to the Linux/macOS legs.
##
## NO MOCKS: the built `runquotad` and `runquota`, real sessions, a real named
## pipe. The leased command is THIS BINARY re-invoked in a no-op mode (as the
## other Windows integration tests re-invoke themselves), so there is no shell.

when defined(windows):
  import std/[json, os, osproc, strtabs, strutils, unittest]

  import runquota_client
  import runquota_core
  import runquota_protocol
  import daemon_binary
  import windows_daemon_fixture
  from runquota_core/child_process import readToEnd

  # -------------------------------------------------------------------
  # The no-op leased command (runs before any test)
  # -------------------------------------------------------------------

  proc maybeRunAsNoop() =
    ## `runquota run -- <self> --rqpress-noop` launches this binary as the
    ## leased command; it exits at once. A normal test run has no such
    ## argument.
    let params = commandLineParams()
    if params.len >= 1 and params[0] == "--rqpress-noop":
      quit(0)

  maybeRunAsNoop()

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  proc startPressureDaemon(prefix: string; extra: openArray[string]): Daemon =
    ## Like the fixture's `startDaemon`, but with the daemon flags this suite
    ## needs (a one-CPU budget and a lowered long-wait threshold, or a metrics
    ## text file) rather than a fixed `--cpu-milli`.
    result.root = scratchDir(prefix)
    result.pipe = uniquePipe()
    result.env = hostEnv(result.pipe)
    launchOwned(result, daemonArgs(result.root, result.pipe, extra))

  proc useDaemon(daemon: Daemon) =
    ## Point THIS process's in-process client at the daemon's pipe. The CLI
    ## subprocesses get `daemon.env` directly; `connectDefault` reads the
    ## process environment.
    putEnv("RUNQUOTA_SOCKET", daemon.pipe)

  proc groupOf(answer: JsonNode; name: string): JsonNode =
    for group in answer{"groups"}:
      if group{"name"}.getStr == name:
        return group
    newJNull()

  proc someTotal(scope: JsonNode): int64 =
    scope["some"]["total_micros"].getBiggestInt

  # -------------------------------------------------------------------
  # Reports over the pipe, and their owner
  # -------------------------------------------------------------------

  suite "reports and their owner (windows)":
    test "a report counts for its session, group and host, not from another connection":
      var daemon = startPressureDaemon("rqpressw", ["--cpu-milli", "4000"])
      defer: daemon.stop()
      useDaemon(daemon)
      var client = connectDefault()
      defer: client.close()
      prerequisite client.supportsPressure(), "the daemon predates pressure"
      var session = client.registerSession("pressure", "0.1.0",
        SessionGroupDeclaration(name: "press-a"))
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

  # -------------------------------------------------------------------
  # A real queued `runquota run`
  # -------------------------------------------------------------------

  proc runQueuedBehindHolder(daemon: var Daemon; measurement: string): JsonNode =
    ## Hold the one CPU for 2.5 s while `runquota run` waits for it, then read
    ## the run's group from the daemon.
    useDaemon(daemon)
    var client = connectDefault()
    defer: client.close()
    var session = client.registerSession("holder", "0.1.0")
    var held = session.requestLease(resourceRequest("held", milliCpu(1000),
      bytes(64'u64 * 1024'u64 * 1024'u64)))
    prerequisite held.active, "the holder was not granted"
    var env = daemon.env.withVars({"RUNQUOTA_SESSION": "press-run"})
    if measurement.len > 0:
      env["RUNQUOTA_MEASUREMENT"] = measurement
    else:
      env.del("RUNQUOTA_MEASUREMENT")
    let self = getAppFilename()
    var run = startProcess(cliPath(), env = env,
      args = ["run", "--width", "1", "--", self, "--rqpress-noop"],
      options = {poStdErrToStdOut})
    defer: run.close()
    sleep(2500)
    held.release()
    let code = run.waitForExit(30_000)
    checkpoint run.outputStream.readToEnd()
    check code == 0
    session.closeSession()
    result = parseJson(client.queryPressure())

  suite "runquota run (windows)":
    test "it reports its queue wait, counted as long past the threshold, read back by the CLI":
      var daemon = startPressureDaemon("rqpressrunw",
        ["--cpu-milli", "1000", "--pressure-long-wait-millis", "2000"])
      defer: daemon.stop()
      let answer = runQueuedBehindHolder(daemon, "pressure-reports=on")
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

      # The same figures, read back the ways the daemon publishes them.
      let plain = runq(daemon.env, ["pressure"])
      checkpoint plain.output
      check plain.code == 0
      check "group press-run" in plain.output
      check "some  avg10=" in plain.output

      let asJson = runq(daemon.env, ["pressure", "--json"])
      check asJson.code == 0
      check parseJson(asJson.output).groupOf("press-run").kind == JObject

      let status = runq(daemon.env, ["status", "--json"])
      check status.code == 0
      check parseJson(status.output)["pressure"]["host"]["reports"].getInt >= 1

      let filtered = runq(daemon.env,
        ["pressure", "--group", "press-run", "--json"])
      check filtered.code == 0
      let filteredJson = parseJson(filtered.output)
      check filteredJson["groups"].len == 1
      check filteredJson["groups"][0]["name"].getStr == "press-run"
      # The sessions are filtered the same way (none open now, so just zero).
      check filteredJson["sessions"].len == 0

      let bad = runq(daemon.env, ["pressure", "--bogus"])
      check bad.code == 2

    test "with the switch off (the default) it reports nothing":
      var daemon = startPressureDaemon("rqpressoffw",
        ["--cpu-milli", "1000", "--pressure-long-wait-millis", "2000"])
      defer: daemon.stop()
      let answer = runQueuedBehindHolder(daemon, "")
      checkpoint $answer
      check answer.groupOf("press-run").kind == JNull
      check answer["host"]["reports"].getInt == 0

  # -------------------------------------------------------------------
  # Where the figures are published
  # -------------------------------------------------------------------

  suite "where the figures are published (windows)":
    test "the text file and status --json carry them; promtool checks when present":
      # The text file lives in its own scratch dir, independent of the
      # daemon's root, so naming it does not depend on the daemon starting.
      let textRoot = scratchDir("rqpresstextw")
      defer: removeDir(textRoot)
      let textPath = textRoot / "runquota.prom"
      var daemon = startPressureDaemon("rqpresspubw",
        ["--cpu-milli", "4000", "--metrics-textfile", textPath,
         "--metrics-interval-millis", "100"])
      defer: daemon.stop()
      useDaemon(daemon)
      var client = connectDefault()
      defer: client.close()
      prerequisite client.supportsPressure(), "the daemon predates pressure"
      var sessions: seq[RunQuotaSession]
      for name in ["press-pub", "press-other"]:
        sessions.add(client.registerSession("pressure", "0.1.0",
          SessionGroupDeclaration(name: name)))
      for i in 0 ..< sessions.len:
        check sessions[i].reportPressure(PressureReportMessage(
          wallMicros: 150_000, someMicros: 100_000, fullMicros: 10_000,
          waits: @[PressureWait(startedAtUnixMillis: 1, lengthMillis: 1_100,
            kind: pwkQueue)]))
      discard client.queryPressure()
      let needle = "runquota_group_pressure_some_seconds_total{owner_uid=\""
      var text = ""
      for _ in 0 ..< 600:
        if fileExists(textPath):
          text = readFile(textPath)
          if needle in text and "group=\"press-other\"" in text:
            break
        sleep(50)
      checkpoint text
      check needle in text
      check "runquota_host_pressure_some_seconds_total 0.200000" in text
      check "runquota_host_pressure_long_waits_total{kind=\"queue\"} 0" in text
      check "runquota_host_pressure_wait_seconds_bucket{kind=\"queue\",le=\"2\"} 2" in text

      let status = runq(daemon.env, ["status", "--json"])
      check status.code == 0
      check parseJson(status.output)["pressure"]["host"]["reports"].getInt == 2

      let filtered = runq(daemon.env,
        ["pressure", "--group", "press-pub", "--json"])
      check filtered.code == 0
      let filteredJson = parseJson(filtered.output)
      check filteredJson["groups"].len == 1
      check filteredJson["groups"][0]["name"].getStr == "press-pub"
      check filteredJson["sessions"].len == 1
      check filteredJson["sessions"][0]["group"].getStr == "press-pub"

      let promtool = findExe("promtool")
      if promtool.len > 0:
        let (output, code) = execCmdEx(quoteShell(promtool) &
          " check metrics < " & quoteShell(textPath))
        checkpoint output
        check code == 0
        check output.strip().len == 0
      else:
        checkpoint "promtool is not on PATH; the text file's syntax is " &
          "validated on the Linux/macOS legs"

      for i in 0 ..< sessions.len:
        sessions[i].closeSession()
else:
  echo "t_build_wait_pressure_windows: Windows only"
