## A REAL `runquotad` ON A PRIVATE SCRATCH ENDPOINT FOR WINDOWS, the sibling
## of `private_daemon_fixture` for the Windows integration tests (the jobserver
## bridge and `runquota run --cap`).
##
## WHY A SEPARATE FIXTURE. `private_daemon_fixture` is POSIX only: it drives a
## Unix-domain socket, reads it with `S_ISSOCK`, and probes the lifetime lock
## with `flock(2)`. Windows has none of these, and the daemon refuses the
## `private` endpoint scope there ("private RunQuota endpoints require POSIX")
## -- the Windows transport is a named pipe under `host` scope. This fixture
## isolates each daemon the only way Windows offers: a named pipe whose name
## no other run collides with (this process's id and the monotonic clock),
## with every mutable file redirected into a fresh scratch directory and
## capture off. Every process it starts is one the caller owns and stops.
##
## No mocks: real processes and real named pipes.

when defined(windows):
  import std/[monotimes, os, osproc, strtabs, strutils, tempfiles]

  import daemon_binary
  from runquota_core/child_process import readToEnd

  type
    CliResult* = tuple[code: int, output: string]

    Daemon* = object
      root*, pipe*: string
      env*: StringTableRef
      process*: Process
      stopped*: bool

  const IsolationKeys* = ["RUNQUOTA_ENDPOINT_SCOPE", "RUNQUOTA_SOCKET",
    "RUNQUOTA_PARENT_LEASE", "RUNQUOTA_JOBSERVER_FIFO",
    "RUNQUOTA_JOBSERVER_SEMAPHORE", "MAKEFLAGS", "MFLAGS", "CARGO_MAKEFLAGS"]
    ## Removed from every child's environment before the fixture sets its own:
    ## an inherited value of any of them would redirect the daemon, hand a
    ## bridge a parent it should not have, or point a tool at an outer
    ## jobserver.

  proc prerequisite*(condition: bool; message = "fixture prerequisite failed") =
    ## Raises so the test's own `defer`s still stop what it started.
    if not condition: raise newException(IOError, message)

  proc scratchDir*(prefix: string): string =
    createTempDir(prefix, "")

  proc cleanEnvironment*(): StringTableRef =
    ## This process's environment, case-insensitive (Windows names are), with
    ## the isolation keys removed.
    result = newStringTable(modeCaseInsensitive)
    for key, value in envPairs():
      result[key] = value
    for key in IsolationKeys:
      result.del(key)

  proc uniquePipe*(): string =
    ## A named pipe no concurrent run collides with.
    r"\\.\pipe\runquota-test-" & $getCurrentProcessId() & "-" &
      $(getMonoTime().ticks and 0x7fffffff)

  proc hostEnv*(pipe: string): StringTableRef =
    ## The environment the daemon and every client share: the pipe, under the
    ## default `host` scope (Windows has no `private` scope).
    result = cleanEnvironment()
    result["RUNQUOTA_SOCKET"] = pipe

  proc withVars*(env: StringTableRef; pairs: openArray[(string, string)]):
      StringTableRef =
    result = newStringTable(modeCaseInsensitive)
    for key, value in env: result[key] = value
    for (key, value) in pairs: result[key] = value

  proc runq*(env: StringTableRef; args: openArray[string];
             workDir = ""): CliResult =
    ## The shipped CLI as a process, stderr merged into stdout. `readToEnd`,
    ## not `streams.readAll`: on Windows `readAll` stops at the first short
    ## pipe read and returns only what the child had written so far.
    var process = startProcess(cliPath(), workingDir = workDir, env = env,
      args = args, options = {poStdErrToStdOut})
    defer: process.close()
    let text = process.outputStream.readToEnd()
    (process.waitForExit(), text)

  proc daemonArgs*(root, pipe: string; extra: openArray[string] = []):
      seq[string] =
    ## Every mutable file the daemon would reach for on the host is redirected
    ## into `root`, and capture is off: these tests do not need the store, and
    ## no `sqlite3` is on the Windows job's PATH.
    result = @["--socket", pipe,
      "--host-config", root / "host.toml",
      "--host-identity-file", root / "host-id",
      "--no-write-stats",
      "--ambient-sample-interval-millis", "0",
      "--memory-pressure-source", "unavailable"]
    for arg in extra: result.add(arg)

  proc daemonReady(env: StringTableRef): bool =
    let r = runq(env, ["status", "--json"])
    r.code == 0 and "cpu_budget_milli" in r.output

  proc awaitDaemon*(daemon: Daemon; budgetMillis = 30_000): bool =
    ## Generous: a shared, often loaded host. A daemon that exits ends the
    ## wait at once.
    var waited = 0
    while waited < budgetMillis:
      if not daemon.process.running: return false
      if daemonReady(daemon.env): return true
      sleep(100)
      waited += 100

  proc stop*(daemon: var Daemon)

  proc launchOwned*(daemon: var Daemon; args: openArray[string];
                    what = "the daemon") =
    ## Starts `runquotad` for a `daemon` whose root, pipe and env are set,
    ## and waits until it serves. Every helper that starts and waits for a
    ## daemon should go through here. The daemon is not owned by any `defer`
    ## of the caller until the helper returns, so anything that leaves this
    ## proc early once it is running -- the readiness wait, the CLI binary
    ## refused by `daemon_binary` part-way through a session, or a Defect --
    ## stops it (and removes `root`) here while the exception propagates.
    ## Without this, leftover `runquotad.exe` processes accumulated on a
    ## Windows host (reprobuild-pm
    ## `issues/2026-11-16-daemon-binary-staleness-guard-quits-after-a-caller-already-spawned-a-daemon.md`).
    ##
    ## A `finally` guarded by a flag rather than `except CatchableError`, so
    ## the cleanup also runs for a Defect, which unittest reports and then
    ## carries on past.
    var launched = false
    try:
      daemon.process = startProcess(daemonPath(), env = daemon.env,
        args = args, options = {poStdErrToStdOut})
      prerequisite awaitDaemon(daemon),
        what & " did not serve " & daemon.pipe
      launched = true
    finally:
      if not launched:
        # No process to stop if the spawn itself raised; the scratch
        # directory is removed either way.
        if daemon.process == nil:
          daemon.stopped = true
        stop(daemon)

  proc startDaemon*(prefix: string; cpuMilli: int): Daemon =
    result.root = scratchDir(prefix)
    result.pipe = uniquePipe()
    result.env = hostEnv(result.pipe)
    launchOwned(result,
      daemonArgs(result.root, result.pipe, ["--cpu-milli", $cpuMilli]))

  proc stop*(daemon: var Daemon) =
    ## Ends a daemon THIS test started. Never raises: it runs from `defer`.
    if not daemon.stopped:
      try:
        if daemon.process.running:
          daemon.process.terminate()
          discard daemon.process.waitForExit(10_000)
        if daemon.process.running:
          daemon.process.kill()
          discard daemon.process.waitForExit(10_000)
        daemon.process.close()
      except CatchableError:
        discard
      daemon.stopped = true
    try: removeDir(daemon.root)
    except CatchableError: discard

  proc noLeases*(daemon: Daemon): bool =
    runq(daemon.env, ["leases", "--json"]).output.strip() == "{\"leases\":[]}"
