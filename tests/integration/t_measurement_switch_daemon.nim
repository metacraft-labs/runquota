## `runquotad --measurement NAME=on|off[,...]`: the daemon takes the
## measurements it is told to, reports them, and refuses what it cannot do.
##
## WHY FROM OUTSIDE. The measurement overhead gate turns the daemon's
## measurements off through this flag and then asks the daemon, over its
## socket, which measurements it is taking (`runquota observations --json`,
## the `measurements` object). The gate refuses to measure when the answer
## is not what it configured. So the answer has to be the daemon's real
## state, and this test reads it the way the gate does:
##
## * a daemon started with capture on and `--measurement ambient-sampling=off`
##   reports capture `on`, ambient sampling `off`, `tree-sampling` as
##   `client` (switched in the client, not here) and the measurements not
##   implemented yet as `not-implemented`; its ambient sampler is inactive;
## * a misspelt name, a value other than on/off, and an explicit `=on`
##   against the older off flag (`--no-write-stats`) each stop the daemon
##   with exit 2 and the reason, before it serves anything.
##
## Falsifying mutation: drop the `--measurement` case from `runquotad.nim`
## (or stop applying the switches) and the first case reports ambient
## sampling `on` and fails, the refusals become `unknown runquotad argument`
## or a running daemon.
##
## A PRIVATE DAEMON on a scratch socket (`tests/support/private_daemon_fixture`).
## NO MOCKS: the built `runquotad` and `runquota`.

when defined(posix):
  import std/[json, os, osproc, strutils, unittest]

  import daemon_binary
  import private_daemon_fixture

  proc captureOnArgs(root, socket: string; extra: openArray[string]):
      seq[string] =
    ## Like the fixture's `daemonArgs`, but with capture ON into a scratch
    ## store, which the fixture turns off.
    result = @["--socket", socket,
      "--host-config", root / "host.toml",
      "--host-identity-file", root / "host-id",
      "--observation-db", root / "observations.sqlite3",
      "--estimate-db", root / "est.sqlite",
      "--memory-pressure-source", "unavailable"]
    for arg in extra: result.add(arg)

  suite "runquotad --measurement":
    test "the daemon takes and reports what the switch says":
      let root = scratchDir("rqmeas")
      defer: removeDir(root)
      let socket = root / "ep" / "d.sock"
      let env = privateEnv(socket)
      let daemon = startProcess(daemonPath(), env = env,
        args = captureOnArgs(root, socket,
          ["--measurement", "ambient-sampling=off,tree-sampling=off"]),
        options = {poStdErrToStdOut})
      defer: stopOwned(daemon)
      prerequisite awaitSocket(daemon, socket),
        daemon.startupContext("the daemon did not bind " & socket)
      let (code, text) = cli(env, ["observations", "--json"])
      checkpoint text
      check code == 0
      let observations = parseJson(text)["observations"]
      let measurements = observations["measurements"]
      check measurements["capture"].getStr == "on"
      check measurements["ambient-sampling"].getStr == "off"
      check measurements["tree-sampling"].getStr == "client"
      for name in ["profiles", "pressure-reports", "sizing-data",
                   "metrics-export"]:
        check measurements[name].getStr == "not-implemented"
      check observations["ambient_sampling"]["interval_millis"].getInt == 0
      check not observations["ambient_sampling"]["active"].getBool
      check not observations["write_stats_disabled"].getBool

    test "unparsable or contradictory switches stop the daemon with exit 2":
      for (extra, expected) in [
          (@["--measurement", "captur=off"], "unknown measurement 'captur'"),
          (@["--measurement", "capture=maybe"], "the value must be on or off"),
          (@["--measurement"], "--measurement needs NAME=on|off"),
          (@["--no-write-stats", "--measurement", "capture=on"],
            "contradicts --no-write-stats")]:
        let root = scratchDir("rqmeasbad")
        defer: removeDir(root)
        let socket = root / "ep" / "d.sock"
        let daemon = startProcess(daemonPath(), env = privateEnv(socket),
          args = captureOnArgs(root, socket, extra),
          options = {poStdErrToStdOut})
        defer: stopOwned(daemon)
        let code = daemon.exitWithin(30_000)
        let output = daemon.output
        checkpoint $extra & " -> exit " & $code & ": " & output
        check code == 2
        check expected in output
        check not fileExists(socket)
