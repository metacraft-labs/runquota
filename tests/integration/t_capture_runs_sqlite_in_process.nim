## With capture on, a build through `runquotad` writes its rows, its learned
## estimates and its published aggregates WITHOUT starting a `sqlite3`
## process.
##
## WHY. The daemon used to run the `sqlite3` command-line tool for every
## batch of observations, every learned-estimate write and every aggregate
## publication: about 170 processes for a 64-action build, most of the cost
## of capture. SQLite now runs in the daemon (`runquota_core/sqlite_inproc`),
## and a single spawn put back on any of those paths is that cost coming
## back. Only a count of the spawns can see it: a store written through the
## tool and one written in process hold the same rows.
##
## HOW A SPAWN IS SEEN. The daemon runs with a `sqlite3` SHIM first on its
## PATH, which appends a line to a log and then runs the real tool with the
## same arguments and input. It is a wrapper, not a fake: a daemon that
## still spawned the tool would get the real tool's answers, write a correct
## store, and be caught only by the log. The positive control runs the shim
## through the daemon's own PATH and sees its line, so an empty log means
## "not spawned", never "the shim was not reached".
##
## THE BUILD. Twenty leases under four stats keys, each a real
## `runquota acquire -- <command>` whose child holds some memory, so the
## daemon writes execution rows, learned estimates and per-key aggregates;
## then a `runquota stats` read (the daemon is the only reader of the
## store). Then the daemon is stopped and the store and the estimate store
## are read back.
##
## Falsifying mutation: restore one `sqlite3` spawn on the daemon's path
## (`runSqlite` in `runquota_observation_store/sqlite_cli` running the tool
## again for SQL text, as it did); the log then holds the daemon's spawns and
## the test fails.
##
## NO MOCKS beyond the wrapper above: the built `runquotad` and `runquota`,
## a real store, real processes.

when defined(linux):
  import std/[json, os, osproc, strtabs, strutils, unittest]

  import runquota_observation_store
  import daemon_binary
  import private_daemon_fixture

  const keys = ["inproc-a", "inproc-b", "inproc-c", "inproc-d"]

  suite "capture runs SQLite in process":
    test "a build with capture on starts no sqlite3 process":
      let realTool = findExe("sqlite3")
      prerequisite realTool.len > 0, "the sqlite3 tool is needed for the shim"
      let root = scratchDir("rqinproc")
      defer: removeDir(root)
      let tools = root / "tools"
      createDir(tools)
      let log = root / "sqlite3-spawns.log"
      let shim = tools / "sqlite3"
      writeFile(shim, "#!/bin/sh\n" &
        "echo \"$$ $*\" >> " & quoteShell(log) & "\n" &
        "exec " & quoteShell(realTool) & " \"$@\"\n")
      setFilePermissions(shim, {fpUserRead, fpUserWrite, fpUserExec})

      let socket = root / "ep" / "d.sock"
      var env = privateEnv(socket)
      env["PATH"] = tools & ":" & env.getOrDefault("PATH")

      # POSITIVE CONTROL: the daemon's PATH resolves `sqlite3` to the shim,
      # and the shim records a run.
      let control = execCmdEx("sqlite3 -version", env = env)
      check control.exitCode == 0
      check fileExists(log)
      check readFile(log).strip().len > 0
      removeFile(log)

      let store = root / "observations.sqlite3"
      let estimates = root / "est.sqlite"
      let daemon = startProcess(daemonPath(), env = env, args = [
        "--socket", socket,
        "--host-config", root / "host.toml",
        "--host-identity-file", root / "host-id",
        "--observation-db", store,
        "--measurement", "capture=on",
        "--estimate-db", estimates,
        "--ambient-sample-interval-millis", "100",
        "--cpu-milli", "8000",
        "--memory-pressure-source", "unavailable"],
        options = {poStdErrToStdOut})
      defer: stopOwned(daemon)
      prerequisite awaitSocket(daemon, socket),
        daemon.startupContext("the daemon did not bind " & socket)
      var captureOn = false
      for _ in 0 ..< 600:
        let (code, text) = cli(env, ["observations", "--json"])
        if code == 0 and "\"capture_enabled\":true" in text:
          captureOn = true
          break
        sleep(50)
      prerequisite captureOn, "capture never came on"

      for i in 0 ..< 20:
        let key = keys[i mod keys.len]
        let (code, text) = cli(env, ["acquire", "--cpu", "500",
          "--stats-key", key, "--", "/bin/sh", "-c",
          "head -c 4000000 /dev/zero | tail -c 1 > /dev/null; sleep 0.15"])
        checkpoint text
        check code == 0

      # The publisher is asynchronous: wait until it has published.
      var published = 0
      for _ in 0 ..< 400:
        let (code, text) = cli(env, ["observations", "--json"])
        if code == 0:
          try:
            published = parseJson(text)["observations"][
              "aggregate_publication"]["published"].getInt()
          except CatchableError:
            discard
        if published >= 1:
          break
        sleep(50)
      check published >= 1

      # A read through the daemon, the store's only reader.
      let stats = cli(env, ["stats", "top", "--json"])
      checkpoint stats.output
      check stats.code == 0

      stopOwned(daemon)

      let spawns = if fileExists(log): readFile(log).strip() else: ""
      checkpoint "sqlite3 runs by the daemon:\n" & spawns
      check spawns.len == 0

      # The rows are there.
      let opened = openObservationStore(store)
      check opened.captureEnabled
      let rows = opened.readExecutions()
      check rows.len == 20
      var seen: seq[string] = @[]
      for row in rows:
        if row.commandStatsId notin seen:
          seen.add(row.commandStatsId)
      check seen.len == keys.len
      let learned = runSqlite(estimates,
        "select count(*) from learned_estimates;")
      check learned.ok
      check learned.output.strip() == $keys.len
