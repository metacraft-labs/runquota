## A BENCHMARK HELPER THAT STARTS A DAEMON OWNS IT UNTIL IT RETURNS.
##
## Every benchmark harness under `benchmarks/lib/` starts a private
## `runquotad` and then waits for it to answer before handing it back. When
## that wait ran out while the daemon was still starting, the helper raised
## and its caller -- which had not yet received the pid or the `Process` --
## could not stop it: the daemon was left running for the rest of the
## harness's life, or past it (reprobuild-pm
## `issues/2026-11-21-runquota-benchmark-harnesses-leak-a-running-daemon-when-start-up-fails.md`).
## The same held one level up: an overhead-gate case starts one daemon per
## arm, and a failure in the second arm's set-up left the first arm's daemon
## running, because `main` stops a case only once `makeCase` has returned it.
## The rule these cases hold is reprobuild-pm
## `spec/Benchmark-Designs/Shared-Benchmark-Design-Guidelines.md`,
## "Processes A Harness Starts"; `t_daemon_fixture_owns_until_bound` holds
## the same rule for the integration-test fixtures.
##
## HOW A LEAK IS SEEN. The pid of a daemon whose helper raised is exactly
## what the caller never learns, so the test does not ask the helper for it:
## it lists every child process of this test process from `/proc` (any
## state, a zombie included, matched by parent pid rather than by name,
## because right after `fork` the child still carries this test's name). A
## fixed helper has stopped and reaped its daemon before the exception
## reaches the test, so the list must be empty. Whatever a regression leaves
## behind is killed and reaped by the test, so it cannot outlive the case.
##
## HOW THE DEADLINE IS MISSED. Each helper takes its readiness budget as a
## parameter (the production value is the default). The cases pass 0, so the
## deadline has passed while the REAL daemon, just spawned, is still
## starting -- the condition the issue describes, made certain instead of
## left to a loaded host.
##
## NO MOCKS. The daemon is the real `build/bin/runquotad` (resolved and
## freshness-checked through `daemon_binary`) on a private scratch endpoint.
## The multi-arm cases make the SECOND arm's set-up fail through the real
## filesystem: a regular file is put where that arm's directory must be
## created, so the gate's own `createDir` raises after the first arm's daemon
## is up and answering. One stand-in, and it is never run: the
## `reprobuild-64` case refuses to start without an engine binary, and the
## test points it at its own executable. With `--measure=capture`, a
## daemon-side measurement, the case only checks that the file exists, and
## the failure under test comes before any build would run.
##
## Linux only: the child listing reads `/proc`. The helpers' code paths are
## the same on macOS, where this file compiles to nothing.

when defined(linux):
  import std/[os, osproc, posix, strutils, tempfiles, unittest]

  from runquota_ipc import endpointDirectoryPermissions
  import daemon_binary
  import private_broker_owner

  import ../../benchmarks/lib/runquota_overhead_gate as gate
  import ../../benchmarks/lib/runquota_m5_bench as m5
  import ../../benchmarks/lib/runquota_m13_bench as m13
  import ../../benchmarks/lib/runquota_m1_bench as m1

  const NoBudget = 0
    ## The readiness budget the failure cases pass: the deadline has passed
    ## before the first probe, whatever the host's load.

  type ChildProcess = object
    pid: Pid
    state: string
    command: string

  proc children(): seq[ChildProcess] =
    ## Every process whose parent is this test process, from `/proc`.
    let me = getpid()
    for kind, path in walkDir("/proc"):
      let name = path.extractFilename
      if name.len == 0 or not name.allCharsInSet(Digits):
        continue
      var stat = ""
      try:
        stat = readFile(path / "stat")
      except IOError, OSError:
        continue # exited between the listing and the read
      # `pid (comm) state ppid ...`; `comm` may itself hold spaces and
      # parentheses, so the fields are counted from the LAST ')'.
      let close = stat.rfind(')')
      let open = stat.find('(')
      if open < 0 or close < open:
        continue
      let fields = stat[close + 1 .. ^1].splitWhitespace()
      if fields.len < 2 or fields[1] != $me:
        continue
      var command = stat[open + 1 ..< close]
      try:
        let cmdline = readFile(path / "cmdline").replace('\0', ' ').strip()
        if cmdline.len > 0: command = cmdline
      except IOError, OSError:
        discard
      result.add(ChildProcess(pid: Pid(parseInt(name)), state: fields[0],
        command: command))

  proc reap(leaked: seq[ChildProcess]) =
    ## A regression must not leave its daemon running past the case.
    for child in leaked:
      discard kill(child.pid, SIGKILL)
      var status: cint
      discard waitpid(child.pid, status, 0)

  template checkNoChildren(what: string) =
    ## The assertion every case ends with. A template, not a proc: unittest's
    ## `check` marks the enclosing TEST failed only when it is expanded
    ## inside it, and from a proc it would only set the exit code.
    let leaked = children()
    for child in leaked:
      checkpoint what & " left child pid " & $child.pid & " (state " &
        child.state & "): " & child.command
    check leaked.len == 0
    reap(leaked)

  proc gateConfig(caseName, cliBin, engineBin, fixtureDir: string):
      GateConfig =
    ## A case configuration as `parseGateArgs` builds it, for a daemon-side
    ## measurement so the `reprobuild-64` case never consults the engine.
    result = parseGateArgs(["--case=" & caseName, "--measure=capture"])
    result.daemonBin = daemonPath()
    result.cliBin = cliBin
    result.engineBin = engineBin
    result.fixtureDir = fixtureDir
    result.cpuMilli = 4000
    result.memoryBytes = 8'u64 shl 30

  suite "a benchmark helper owns the daemon it starts until it returns":
    setup:
      # A child left by an earlier case would read as this case's leak.
      reap(children())

    test "overhead gate: a daemon still starting at the deadline is stopped":
      let scratch = createTempDir("rqbgs", "")
      defer: removeDir(scratch)
      let cfg = gateConfig("run-64", cliPath(), "", "")
      var raised = ""
      try:
        let daemon = gate.startDaemon(cfg, scratch, armOff,
          armSwitchText(cfg, armOff), readyBudgetMillis = NoBudget)
        gate.stopDaemon(daemon)
        checkpoint "the daemon answered within a budget of 0 ms"
        fail()
      except OSError as failure:
        raised = failure.msg
      checkpoint "startDaemon raised: " & raised
      check "did not answer" in raised
      checkNoChildren("runquota_overhead_gate.startDaemon")
      # The arm's directory was the helper's, and only its daemon used it.
      check not dirExists(scratch / $armOff)

    test "overhead gate run-64: the first arm's daemon is stopped when the second arm cannot start":
      let scratch = createTempDir("rqbgr", "")
      defer: removeDir(scratch)
      # The ON arm's directory cannot be created: `createDir` raises after
      # the OFF arm's daemon is up and answering.
      writeFile(scratch / $armOn, "")
      let cfg = gateConfig("run-64", cliPath(), "", "")
      var raised = ""
      try:
        let gateCase = makeCase(cfg, scratch)
        gateCase.stop()
        checkpoint "the case was built although its ON arm cannot start"
        fail()
      except CatchableError as failure:
        raised = failure.msg
      checkpoint "makeCase raised: " & raised
      check ("Failed to create '" & scratch / $armOn & "'") in raised
      # The OFF arm did start: its directory exists, so the failure is the
      # one under test and not an earlier refusal.
      check dirExists(scratch / $armOff)
      checkNoChildren("the run-64 case")

    test "overhead gate reprobuild-64: the first arm's daemon is stopped when the second arm cannot start":
      let scratch = createTempDir("rqbgb", "")
      defer: removeDir(scratch)
      writeFile(scratch / $armOn, "")
      let fixture = getCurrentDir() / "benchmarks" / "fixtures" /
        "reprobuild-64-actions"
      require fileExists(fixture / "repro.nim")
      let cfg = gateConfig("reprobuild-64", "", getAppFilename(), fixture)
      var raised = ""
      try:
        let gateCase = makeCase(cfg, scratch)
        gateCase.stop()
        checkpoint "the case was built although its ON arm cannot start"
        fail()
      except CatchableError as failure:
        raised = failure.msg
      checkpoint "makeCase raised: " & raised
      check ("Failed to create '" & scratch / $armOn & "'") in raised
      # The OFF arm got as far as its fixture copy, after its daemon had
      # reported the arm's measurements.
      check fileExists(scratch / $armOff / "project" / "repro.nim")
      checkNoChildren("the reprobuild-64 case")

    test "m5: a daemon still starting at the deadline is stopped":
      discard daemonPath() # refuse a stale binary before anything starts
      let socketDir = createTempDir("rqbm5", "")
      defer: removeDir(socketDir)
      let policy = bindPrivateBrokerPolicyToCaller(
        privateEndpointGroup(socketDir))
      defer: restorePrivateBrokerPolicy(policy)
      setFilePermissions(socketDir, endpointDirectoryPermissions())
      var raised = ""
      try:
        var daemon = m5.startDaemon(socketDir / "d.sock",
          readyBudgetMillis = NoBudget)
        m5.stopDaemon(daemon)
        checkpoint "the daemon answered within a budget of 0 ms"
        fail()
      except OSError as failure:
        raised = failure.msg
      checkpoint "startDaemon raised: " & raised
      check "did not become ready" in raised
      checkNoChildren("runquota_m5_bench.startDaemon")

    test "m5: a daemon that answers is handed back running":
      discard daemonPath()
      let socketDir = createTempDir("rqbm5ok", "")
      defer: removeDir(socketDir)
      let policy = bindPrivateBrokerPolicyToCaller(
        privateEndpointGroup(socketDir))
      defer: restorePrivateBrokerPolicy(policy)
      setFilePermissions(socketDir, endpointDirectoryPermissions())
      var daemon = m5.startDaemon(socketDir / "d.sock")
      check daemon.running
      m5.stopDaemon(daemon)
      checkNoChildren("runquota_m5_bench.stopDaemon")

    test "m13: a daemon still starting at the deadline is stopped":
      discard daemonPath()
      let root = createTempDir("rqbm13", "")
      defer: removeDir(root)
      setFilePermissions(root, endpointDirectoryPermissions())
      var raised = ""
      try:
        var daemon = m13.startArmDaemon(root / "d.sock", root / "host-id",
          captureOn = false, readyBudgetMillis = NoBudget)
        m13.stopDaemon(daemon)
        checkpoint "the daemon answered within a budget of 0 ms"
        fail()
      except OSError as failure:
        raised = failure.msg
      checkpoint "startArmDaemon raised: " & raised
      check "did not become ready" in raised
      checkNoChildren("runquota_m13_bench.startArmDaemon")

    test "m13: a daemon that answers is handed back running":
      discard daemonPath()
      let root = createTempDir("rqbm13ok", "")
      defer: removeDir(root)
      setFilePermissions(root, endpointDirectoryPermissions())
      var daemon = m13.startArmDaemon(root / "d.sock", root / "host-id",
        captureOn = false)
      check daemon.running
      m13.stopDaemon(daemon)
      checkNoChildren("runquota_m13_bench.stopDaemon")

    test "m1: a daemon still starting at the deadline is stopped":
      let root = createTempDir("rqbm1", "")
      defer: removeDir(root)
      var s = Study(cfg: Config(daemonBin: daemonPath(), cpuMilli: 4000,
        memoryBytes: 8'u64 shl 30), root: root)
      var raised = ""
      try:
        m1.startDaemon(s, readyBudgetMillis = NoBudget)
        checkpoint "the daemon answered within a budget of 0 ms"
        fail()
      except OSError as failure:
        raised = failure.msg
      checkpoint "startDaemon raised: " & raised
      check "did not become reachable" in raised
      checkNoChildren("runquota_m1_bench.startDaemon")
      check s.daemon == nil
      check not dirExists(root / "daemon")
      check not dirExists(root / "state")

    test "m1: a daemon that answers is handed back running":
      let root = createTempDir("rqbm1ok", "")
      defer: removeDir(root)
      var s = Study(cfg: Config(daemonBin: daemonPath(), cpuMilli: 4000,
        memoryBytes: 8'u64 shl 30), root: root)
      try:
        m1.startDaemon(s)
        check s.daemon != nil and s.daemon.running
      finally:
        m1.stopDaemon(s)
      checkNoChildren("runquota_m1_bench.stopDaemon")
