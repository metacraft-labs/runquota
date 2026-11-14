## `runquota jobserver` end to end: the built CLI, a real private `runquotad`
## on a scratch socket, and the real jobserver clients -- cargo and rustc,
## GNU make 4.4 and ninja 1.13 -- building real projects.
##
## NO MOCKS, EXCEPT ONE, JUSTIFIED. Concurrency is measured through small
## logging wrappers: a `RUSTC_WRAPPER` for cargo, and recipe commands for
## make and ninja, that write `+ <ns>` when a job starts and `- <ns>` when it
## ends, and sleep long enough for jobs to overlap. A build of tiny crates is
## otherwise over before two compiles could be seen running together. The
## wrapper runs the real rustc with the real arguments; it holds the job's
## token while it sleeps exactly as a slow compile would.
##
## ISOLATION. Every daemon is started on its own socket inside a fresh 0700
## directory with `RUNQUOTA_ENDPOINT_SCOPE=private`, every CLI call gets that
## endpoint in its environment, and cargo gets a `CARGO_HOME` of its own and
## `--offline` (the fixture crates have no dependencies). Only processes this
## file started are signalled: the daemons, through their `Process`, and in
## the crash test the one command the bridge it started launched, by the pid
## the daemon reports for that lease.
##
## THE TOOLS ARE PREREQUISITES, NOT OPTIONS. cargo, rustc, make and ninja are
## in the development shell (`flake.nix`); a test that cannot find one fails
## rather than skips, since a skip here would read as a bridge that works.

when defined(posix):
  import std/[algorithm, json, monotimes, os, osproc, posix, streams,
    strtabs, strutils, times, unittest]

  import runquota_client
  import daemon_binary
  import private_daemon_fixture

  type CliResult = tuple[code: int, output: string]

  proc withVars(env: StringTableRef; pairs: openArray[(string, string)]):
      StringTableRef =
    result = newStringTable(modeCaseSensitive)
    for key, value in env: result[key] = value
    for (key, value) in pairs: result[key] = value

  proc runq(env: StringTableRef; args: openArray[string];
            workDir = ""): CliResult =
    ## The shipped CLI as a process, stderr merged into stdout.
    var process = startProcess(cliPath(), workingDir = workDir, env = env,
      args = args, options = {poStdErrToStdOut})
    defer: process.close()
    let text = process.outputStream.readAll()
    (process.waitForExit(), text)

  type Daemon = object
    root, socket: string
    env: StringTableRef
    process: Process
    stopped: bool

  proc runqWithin(env: StringTableRef; args: openArray[string];
                  seconds: int; daemon: var Daemon): CliResult =
    ## As `runq`, but a run still going after `seconds` is ended by
    ## stopping `daemon` -- the daemon THIS test started, which every
    ## waiting client then loses -- and reads as exit -1. Used where the
    ## defect under test is a client waiting forever on the daemon.
    var process = startProcess(cliPath(), env = env, args = args,
      options = {poStdErrToStdOut})
    defer: process.close()
    let deadline = getMonoTime() + initDuration(seconds = seconds)
    while process.running and getMonoTime() < deadline:
      sleep(50)
    let timedOut = process.running
    if timedOut:
      stopOwned(daemon.process)
      daemon.stopped = true
    let text = process.outputStream.readAll()
    let code = process.waitForExit(30_000)
    ((if timedOut: -1 else: code), text)

  proc writeScript(path, body: string) =
    writeFile(path, "#!/bin/sh\n" & body)
    setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})

  proc peakConcurrency(logPath: string): tuple[peak, jobs: int] =
    ## The deepest overlap of `+ ns` / `- ns` intervals. Ends sort before
    ## starts on a tie, so back-to-back jobs do not count as overlapping.
    if not fileExists(logPath): return
    var events: seq[(int64, int)] = @[]
    for line in readFile(logPath).splitLines():
      let parts = line.splitWhitespace()
      if parts.len != 2: continue
      let stamp = parseBiggestInt(parts[1])
      if parts[0] == "+":
        events.add((stamp, 1))
        inc result.jobs
      else:
        events.add((stamp, -1))
    events.sort(proc (a, b: (int64, int)): int =
      if a[0] != b[0]: cmp(a[0], b[0]) else: cmp(a[1], b[1]))
    var depth = 0
    for (_, delta) in events:
      depth += delta
      result.peak = max(result.peak, depth)

  proc requireTool(name: string): string =
    result = findExe(name)
    prerequisite result.len > 0, name & " is not on PATH (it is in the " &
      "development shell; run the suite from `nix develop`)"

  proc startDaemon(prefix: string; cpuMilli: int): Daemon =
    result.root = scratchDir(prefix)
    result.socket = result.root / "d.sock"
    result.env = privateEnv(result.socket)
    # The bridge's own environment must not carry a parent from whoever
    # runs the suite, nor a jobserver from an enclosing make.
    for key in ["RUNQUOTA_PARENT_LEASE", "RUNQUOTA_JOBSERVER_FIFO",
        "MAKEFLAGS", "MFLAGS", "CARGO_MAKEFLAGS"]:
      result.env.del(key)
    result.process = launch(result.root, result.socket, result.env,
      ["--cpu-milli", $cpuMilli])
    prerequisite awaitSocket(result.process, result.socket),
      result.process.startupContext("the daemon did not bind " &
        result.socket)

  proc stop(daemon: var Daemon) =
    if not daemon.stopped:
      stopOwned(daemon.process)
      daemon.stopped = true
    removeDir(daemon.root)

  proc noLeases(daemon: Daemon): bool =
    runq(daemon.env, ["leases", "--json"]).output.strip() == "{\"leases\":[]}"

  # -------------------------------------------------------------------
  # The cargo fixture
  # -------------------------------------------------------------------

  proc cargoWorkspace(dir: string; crates: int; log: string): string =
    ## A workspace of `crates` independent library crates and a
    ## `RUSTC_WRAPPER` that logs each real compile (not cargo's `-vV` and
    ## target-info probes) and sleeps one second inside it. Returns the
    ## wrapper's path.
    createDir(dir)
    var members: seq[string] = @[]
    for k in 0 ..< crates:
      let name = "c" & $k
      members.add "\"" & name & "\""
      createDir(dir / name / "src")
      writeFile(dir / name / "Cargo.toml",
        "[package]\nname = \"" & name & "\"\nversion = \"0.1.0\"\n" &
        "edition = \"2021\"\n\n[lib]\npath = \"src/lib.rs\"\n")
      writeFile(dir / name / "src" / "lib.rs",
        "pub fn f" & $k & "() -> u32 { " & $(k + 1) & " }\n")
    writeFile(dir / "Cargo.toml", "[workspace]\nresolver = \"2\"\n" &
      "members = [" & members.join(", ") & "]\n")
    result = dir / "rustc-wrapper.sh"
    writeScript(result,
      "case \" $* \" in\n" &
      "  *\" --crate-name ___ \"*) exec \"$@\" ;;\n" &
      "  *\" --crate-name \"*)\n" &
      "    echo \"+ $(date +%s%N)\" >> '" & log & "'\n" &
      "    sleep 1\n" &
      "    \"$@\"; rc=$?\n" &
      "    echo \"- $(date +%s%N)\" >> '" & log & "'\n" &
      "    exit $rc ;;\n" &
      "  *) exec \"$@\" ;;\n" &
      "esac\n")

  proc cargoEnv(base: StringTableRef; dir, wrapper: string):
      StringTableRef =
    base.withVars({"RUSTC_WRAPPER": wrapper,
      "CARGO_HOME": dir / "cargo-home",
      "CARGO_TARGET_DIR": dir / "target",
      "CARGO_TERM_COLOR": "never",
      "CARGO_INCREMENTAL": "0"})

  suite "runquota jobserver":
    discard requireTool("cargo")
    discard requireTool("rustc")
    discard requireTool("make")
    discard requireTool("ninja")

    # -----------------------------------------------------------------
    # cargo_peak_equals_lease_slots
    # -----------------------------------------------------------------

    test "cargo_peak_equals_lease_slots: 16 independent crates under a " &
        "4-slot lease never run more than 4 rustc at once, and reach 4":
      var daemon = startDaemon("rqjsc", 8000)
      defer: daemon.stop()
      let work = daemon.root / "ws"
      let log = daemon.root / "rustc.log"
      let wrapper = cargoWorkspace(work, 16, log)
      let run = runq(cargoEnv(daemon.env, work, wrapper),
        ["jobserver", "--width", "4", "--verbose", "--",
         "cargo", "build", "--offline", "--workspace"], workDir = work)
      checkpoint run.output
      check run.code == 0
      let measured = peakConcurrency(log)
      check measured.jobs == 16
      # EXACTLY the lease: three tokens plus cargo's implicit one. Serving
      # N tokens for N slots would let a fifth rustc in.
      check measured.peak == 4
      check "lease 1 width 4, 3 tokens" in run.output
      # cargo gave every token back.
      check "returned 3 of 3 tokens" in run.output
      check daemon.noLeases()

    # -----------------------------------------------------------------
    # nested_bridge_does_not_wait_on_host
    # -----------------------------------------------------------------

    test "nested_bridge_does_not_wait_on_host: with a host budget of 4, " &
        "four 1-slot parents each running a bridged cargo build all finish":
      # The four parents fill the host budget. A bridge that asked the host
      # ledger for its own lease would wait for capacity only the parents
      # can release, and the parents wait for their bridges: a deadlock,
      # which this test turns into a failure by its bounded wait.
      var daemon = startDaemon("rqjsn", 4000)
      defer: daemon.stop()
      let log = daemon.root / "rustc.log"
      var parents: seq[Process] = @[]
      for p in 0 ..< 4:
        let work = daemon.root / ("ws" & $p)
        let wrapper = cargoWorkspace(work, 3, log)
        parents.add startProcess(cliPath(), workingDir = work,
          env = cargoEnv(daemon.env, work, wrapper),
          args = ["acquire", "--cpu", "1000", "--mem", "1GiB", "--",
            cliPath(), "jobserver", "--verbose", "--", "cargo", "build",
            "--offline", "--workspace"],
          options = {poStdErrToStdOut})
      # Bounded: the four builds take about 3-4 s each when they run side
      # by side; 120 s is far beyond that on a loaded host and far below
      # the suite's per-binary bound.
      let deadline = getMonoTime() + initDuration(seconds = 120)
      var finished = true
      for parent in parents:
        while parent.running and getMonoTime() < deadline:
          sleep(100)
        if parent.running: finished = false
      if not finished:
        # Ending the daemon THIS TEST started is what ends every client
        # waiting on it; nothing else is signalled.
        stopOwned(daemon.process)
        daemon.stopped = true
      var outputs = ""
      for parent in parents:
        let code = parent.waitForExit(30_000)
        let text = parent.outputStream.readAll()
        outputs.add "--- exit " & $code & "\n" & text
        check code == 0
        parent.close()
      checkpoint outputs
      check finished
      # Each bridge took a sub-lease of its own parent, one slot wide, so
      # each cargo ran one rustc at a time and the host never ran more than
      # its budget.
      check outputs.count("of parent lease") == 4
      check outputs.count("width 1, 0 tokens") == 4
      let measured = peakConcurrency(log)
      check measured.jobs == 12
      check measured.peak <= 4
      if finished:
        check daemon.noLeases()

    # -----------------------------------------------------------------
    # make_and_ninja_bounded
    # -----------------------------------------------------------------

    proc makeProject(dir, log: string; jobs: int) =
      createDir(dir)
      var targets: seq[string] = @[]
      for k in 1 .. jobs: targets.add "t" & $k
      writeFile(dir / "Makefile",
        "T := " & targets.join(" ") & "\n" &
        "all: $(T)\n" &
        "$(T):\n" &
        "\t@echo \"+ $$(date +%s%N)\" >> '" & log & "'; sleep 0.5; " &
        "echo \"- $$(date +%s%N)\" >> '" & log & "'\n" &
        ".PHONY: all $(T)\n")

    proc ninjaProject(dir, log: string; jobs: int) =
      createDir(dir)
      var text = "rule s\n  command = echo \"+ $$(date +%s%N)\" >> '" &
        log & "'; sleep 0.5; echo \"- $$(date +%s%N)\" >> '" & log &
        "'; touch $out\n"
      for k in 1 .. jobs:
        text.add "build o" & $k & ": s\n"
      writeFile(dir / "build.ninja", text)

    test "make_and_ninja_bounded: make -j, make -j8 and ninja under a " &
        "3-slot lease stay at 3 jobs":
      var daemon = startDaemon("rqjsm", 8000)
      defer: daemon.stop()
      for (name, argv) in [("make-j", @["make", "-j"]),
          ("make-j8", @["make", "-j8"]),
          ("make", @["make"]),
          ("ninja", @["ninja"]),
          ("ninja-j8", @["ninja", "-j", "8"])]:
        let dir = daemon.root / name
        let log = dir & ".log"
        if argv[0] == "make": makeProject(dir, log, 8)
        else: ninjaProject(dir, log, 8)
        var args = @["jobserver", "--width", "3", "--verbose", "--"]
        args.add argv
        let run = runq(daemon.env, args, workDir = dir)
        checkpoint name & ":\n" & run.output
        check run.code == 0
        let measured = peakConcurrency(log)
        check measured.jobs == 8
        check measured.peak == 3
        check "returned 2 of 2 tokens" in run.output
      check daemon.noLeases()

    test "make_and_ninja_bounded (control): the same make -j8 with no " &
        "bridge runs 8 at once, so the fixture can exceed 3":
      let dir = getTempDir() / ("rqjs-ctl-" & $getCurrentProcessId())
      let log = dir & ".log"
      makeProject(dir, log, 8)
      defer:
        removeDir(dir)
        removeFile(log)
      let env = cleanEnvironment()
      for key in ["MAKEFLAGS", "MFLAGS"]: env.del(key)
      var process = startProcess(requireTool("make"), workingDir = dir,
        env = env, args = ["-j8"], options = {poStdErrToStdOut})
      let code = process.waitForExit()
      process.close()
      check code == 0
      check peakConcurrency(log).peak > 3

    # -----------------------------------------------------------------
    # tokens_returned_on_child_crash
    # -----------------------------------------------------------------

    test "tokens_returned_on_child_crash: killing the command ends what " &
        "it left, removes the jobserver and releases the lease":
      var daemon = startDaemon("rqjsk", 4000)
      defer: daemon.stop()
      let dir = daemon.root / "crash"
      createDir(dir)
      let pids = dir / "pids"
      # Eight recipes that record their pid and then sit on their token;
      # make holds the other tokens for them. Killing make with SIGKILL
      # leaves the recipes orphaned and still running.
      writeFile(dir / "Makefile",
        "T := t1 t2 t3 t4 t5 t6 t7 t8\nall: $(T)\n$(T):\n" &
        "\t@echo $$$$ >> '" & pids & "'; " &
        "exec sleep 300 </dev/null >/dev/null 2>&1\n.PHONY: all $(T)\n")
      var bridge = startProcess(cliPath(), workingDir = dir, env = daemon.env,
        args = ["jobserver", "--width", "4", "--verbose", "--", "make"],
        options = {poStdErrToStdOut})
      defer: bridge.close()
      # The command's pid, as the daemon recorded it for the lease.
      var child = 0
      var fifoDir = ""
      let until = getMonoTime() + initDuration(seconds = 60)
      while child == 0 and getMonoTime() < until:
        let leases = parseJson(runq(daemon.env, ["leases", "--json"]).output)
        for lease in leases["leases"]:
          if lease["state"].getStr() == "running":
            child = lease["child_process_id"].getInt()
        sleep(50)
      prerequisite child > 0, "the bridge's lease never reported a child"
      # Four recipes start (four slots); wait until all have.
      while getMonoTime() < until and
          (not fileExists(pids) or readFile(pids).splitLines().len < 5):
        sleep(50)
      let recipePids = readFile(pids).strip().splitLines()
      check recipePids.len == 4
      # The one process signalled: the command the bridge THIS test started
      # launched, by the pid the daemon holds for that lease.
      check kill(Pid(child), SIGKILL) == 0
      let code = bridge.waitForExit(60_000)
      let text = bridge.outputStream.readAll()
      checkpoint text
      check code == 137
      for line in text.splitLines():
        if " tokens at " in line:
          fifoDir = line.split(" tokens at ")[1].split(": ")[0].parentDir
      check fifoDir.len > 0
      check not dirExists(fifoDir)
      check "ended what the command left in its group" in text
      # What make left behind is gone with it. (The recipes write nothing to
      # the bridge's output, so a bridge that left them running still exits
      # and this check, not the read of its output, is what fails.)
      for pid in recipePids:
        let recipe = Pid(parseInt(pid.strip()))
        let alive = kill(recipe, 0) == 0
        check not alive
        when defined(linux):
          if alive and readFile("/proc/" & $recipe & "/cmdline").startsWith(
              "sleep\x00300"):
            # Only under a defect: the recipe THIS test's make started and
            # recorded, still running; not left for the host.
            discard kill(recipe, SIGKILL)
      # And every slot is back: the whole budget is grantable at once
      # (`acquire` without --benchmark does not wait).
      check daemon.noLeases()
      let full = runq(daemon.env, ["acquire", "--cpu", "4000", "--mem",
        "1GiB", "--", "true"])
      checkpoint full.output
      check full.code == 0

    test "a nested bridge's slots go back to its parent when its " &
        "command is killed":
      var daemon = startDaemon("rqjsp", 4000)
      defer: daemon.stop()
      let rq = quoteShell(cliPath())
      # Inside one 4-slot parent: a bridge whose command kills itself, then
      # a second bridge that must get all four slots of the parent again.
      # Bounded: a bridge that asked the host instead of the parent would
      # wait forever behind its own parent.
      let run = runqWithin(daemon.env, ["acquire", "--cpu", "4000", "--mem",
        "1GiB", "--", "sh", "-c",
        rq & " jobserver --width 4 --verbose -- sh -c 'kill -KILL $$'; " &
        "echo first=$?; " &
        rq & " jobserver --width 4 --verbose -- true; echo second=$?"], 60,
        daemon)
      checkpoint run.output
      check run.code == 0
      check "first=137" in run.output
      check "second=0" in run.output
      check run.output.count("width 4, 3 tokens") == 2
      check run.output.count("of parent lease 1") == 2
      check daemon.noLeases()

    # -----------------------------------------------------------------
    # Environment, joining, fallbacks
    # -----------------------------------------------------------------

    test "the command gets MAKEFLAGS, CARGO_MAKEFLAGS and no parent lease":
      var daemon = startDaemon("rqjse", 4000)
      defer: daemon.stop()
      let run = runq(daemon.env.withVars({
          "MAKEFLAGS": " -k -j9 --jobserver-auth=fifo:/nonexistent"}),
        ["jobserver", "--width", "2", "--", "sh", "-c",
         "echo \"MF=[$MAKEFLAGS]\"; echo \"CMF=[$CARGO_MAKEFLAGS]\"; " &
         "echo \"PL=[${RUNQUOTA_PARENT_LEASE-unset}]\"; " &
         "echo \"W=[$RUNQUOTA_RUN_WIDTH]\"; " &
         "test -p \"$RUNQUOTA_JOBSERVER_FIFO\" && echo fifo-ok"])
      checkpoint run.output
      check run.code == 0
      check "fifo-ok" in run.output
      check "PL=[unset]" in run.output
      check "W=[2]" in run.output
      var fifo = ""
      for line in run.output.splitLines():
        if line.startsWith("MF=["):
          check line.startsWith("MF=[ -k -j2 --jobserver-auth=fifo:")
          check "/nonexistent" notin line
          fifo = line[line.find("fifo:") + 5 .. ^2]
        if line.startsWith("CMF=["):
          check line.startsWith("CMF=[ -k -j2 --jobserver-auth=fifo:")
      check fifo.len > 0
      check not fileExists(fifo)

    test "a bridge inside a bridge joins its jobserver and takes no lease":
      var daemon = startDaemon("rqjsj", 4000)
      defer: daemon.stop()
      let rq = quoteShell(cliPath())
      let run = runq(daemon.env, ["jobserver", "--width", "3", "--verbose",
        "--", "sh", "-c",
        rq & " jobserver --verbose -- sh -c " &
        "'echo inner=$RUNQUOTA_RUN_WIDTH; " & rq & " leases --json'"])
      checkpoint run.output
      check run.code == 0
      check "joining the jobserver at" in run.output
      check "inner=3" in run.output
      check run.output.count("\"id\":") == 1

    test "a stale RUNQUOTA_PARENT_LEASE falls back to a host lease":
      var daemon = startDaemon("rqjss", 4000)
      defer: daemon.stop()
      let run = runq(daemon.env.withVars({"RUNQUOTA_PARENT_LEASE": "999"}),
        ["jobserver", "--width", "2", "--verbose", "--", "true"])
      checkpoint run.output
      check run.code == 0
      check "cannot be used" in run.output
      check "parent lease 999 is unknown" in run.output
      check "width 2, 1 tokens" in run.output

    test "a sub-lease wider than its parent is refused, not fallen back":
      var daemon = startDaemon("rqjsw", 4000)
      defer: daemon.stop()
      let rq = quoteShell(cliPath())
      let marker = daemon.root / "must-not-exist"
      let run = runqWithin(daemon.env, ["acquire", "--cpu", "1000", "--mem",
        "1GiB", "--", "sh", "-c", rq & " jobserver --width 3 -- touch '" &
        marker & "'; echo inner=$?"], 60, daemon)
      checkpoint run.output
      check "inner=1" in run.output
      check "exceeds its parent's CPU" in run.output
      check not fileExists(marker)

    test "no daemon: the command runs unchanged, with no jobserver":
      let root = scratchDir("rqjs0")
      defer: removeDir(root)
      let env = privateEnv(root / "nobody.sock")
      env.del("MAKEFLAGS")
      let run = runq(env, ["jobserver", "--", "sh", "-c",
        "echo \"MF=[${MAKEFLAGS-unset}]\"; exit 3"])
      checkpoint run.output
      check run.code == 3
      check "MF=[unset]" in run.output

    test "the finish carries the command's CPU totals":
      # The same launcher totals every other finish carries (the wait for
      # the command's root), read back from the daemon's learned CPU
      # estimate for the stats key. Mutation: finish without `totals` and
      # the estimate has seen none.
      var daemon = startDaemon("rqjst", 4000)
      defer: daemon.stop()
      let run = runq(daemon.env, ["jobserver", "--stats-key",
        "test/jobserver-totals", "--", "sh", "-c",
        "i=0; while [ $i -lt 400000 ]; do i=$((i+1)); done"])
      checkpoint run.output
      check run.code == 0
      putEnv("RUNQUOTA_ENDPOINT_SCOPE", "private")
      putEnv("RUNQUOTA_SOCKET", daemon.socket)
      var client = connectDefault()
      defer: client.close()
      let estimates = parseJson(client.inspectionJson("estimates"))
      var found = false
      for entry in estimates["cpu_estimates"]:
        if entry["key"].getStr().endsWith("test/jobserver-totals"):
          found = true
          check entry["totals_seen"].getInt() == 1
          check entry["conservative_cpu_millis"].getInt() > 0
      check found

    test "exit statuses and bad arguments":
      var daemon = startDaemon("rqjsx", 4000)
      defer: daemon.stop()
      check runq(daemon.env, ["jobserver", "--", "sh", "-c", "exit 7"]).code ==
        7
      check runq(daemon.env, ["jobserver", "--", "sh", "-c",
        "kill -TERM $$"]).code == 143
      check runq(daemon.env, ["jobserver", "--", "no-such-command-rqjs"]).code ==
        127
      check runq(daemon.env, ["jobserver", "--width", "0", "--",
        "true"]).code == 2
      check runq(daemon.env, ["jobserver", "--mem", "0", "--", "true"]).code ==
        2
      check runq(daemon.env, ["jobserver", "--bogus", "--", "true"]).code == 2
      check runq(daemon.env, ["jobserver"]).code == 2
      check daemon.noLeases()
else:
  echo "t_jobserver_command: POSIX only"
