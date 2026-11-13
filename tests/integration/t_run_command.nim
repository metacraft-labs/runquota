## `runquota run` end to end: the built CLI, a real private `runquotad` on a
## scratch socket, and real child processes.
##
## NO MOCKS, EXCEPT ONE, JUSTIFIED. The Nim compile tests run the real `nim`
## and the real C compiler; the only thing standing in for anything is a
## small `--cc` wrapper script that sleeps a fraction of a second and logs
## when each compile step starts and ends, then runs the real compiler. It
## exists to MEASURE concurrency (a compile of ten tiny modules is otherwise
## over before a sampler could see two of them overlap), and it does not
## change what the compiler does.
##
## The nix test uses a STUB `nix` executable earlier on PATH that records its
## argv. A real `nix build` under a test would depend on the store, the
## daemon and the network, and the contract under test is the command line
## `runquota run` hands to nix, which the stub records exactly.
##
## ISOLATION. Every daemon is started on its own socket inside a fresh 0700
## directory with `RUNQUOTA_ENDPOINT_SCOPE=private`, every CLI call gets that
## endpoint in its environment, and only processes this file started are
## stopped (the daemon, through its `Process`). Nothing touches the host
## endpoint.
##
## WHAT IS DELIBERATELY NOT HERE: `--cap` enforcement and the learned width.
## Both wait on work outside this file; the learned-width case is written as
## a visible pending test so it cannot be mistaken for a pass.

when defined(posix):
  import std/[algorithm, os, osproc, streams, strtabs, strutils, unittest]

  import daemon_binary
  import private_daemon_fixture

  const BudgetMilli = 4000

  type RunResult = tuple[code: int, output: string]

  var
    root: string
    socket: string
    daemon: Process
    baseEnv: StringTableRef

  proc runq(env: StringTableRef; args: openArray[string];
            workDir = ""): RunResult =
    ## The shipped CLI as a process, stderr merged into stdout.
    var process = startProcess(cliPath(), workingDir = workDir, env = env,
      args = args, options = {poStdErrToStdOut})
    defer: process.close()
    let text = process.outputStream.readAll()
    (process.waitForExit(), text)

  proc withVars(env: StringTableRef; pairs: openArray[(string, string)]):
      StringTableRef =
    result = newStringTable(modeCaseSensitive)
    for key, value in env: result[key] = value
    for (key, value) in pairs: result[key] = value

  proc writeScript(path, body: string) =
    writeFile(path, "#!/bin/sh\n" & body)
    setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})

  # One daemon for the whole file, started before the suite and stopped
  # after it (this Nim's unittest has no suite-level setup).
  root = scratchDir("rqrun")
  socket = root / "d.sock"
  baseEnv = privateEnv(socket)
  daemon = launch(root, socket, baseEnv, ["--cpu-milli", $BudgetMilli])
  prerequisite awaitSocket(daemon, socket),
    daemon.startupContext("the daemon did not bind " & socket)

  suite "runquota run":
    # -----------------------------------------------------------------
    # nim_parallel_build_bounded
    # -----------------------------------------------------------------

    proc peakConcurrency(logPath: string): tuple[peak, compiles: int] =
      ## The wrapper logs `+ <ns>` at the start of each C compile and
      ## `- <ns>` at its end; the peak is the deepest overlap.
      var events: seq[(int64, int)] = @[]
      for line in readFile(logPath).splitLines():
        let parts = line.splitWhitespace()
        if parts.len != 2: continue
        let stamp = parseBiggestInt(parts[1])
        if parts[0] == "+":
          events.add((stamp, 1))
          inc result.compiles
        else:
          events.add((stamp, -1))
      # Ends sort before starts on a tie, so back-to-back compiles do not
      # count as overlapping.
      events.sort(proc (a, b: (int64, int)): int =
        if a[0] != b[0]: cmp(a[0], b[0]) else: cmp(a[1], b[1]))
      var depth = 0
      for (_, delta) in events:
        depth += delta
        result.peak = max(result.peak, depth)

    proc compileProject(name: string; runArgs: seq[string];
                        nimExtra: seq[string]): tuple[run: RunResult,
        peak, compiles: int, work: string] =
      ## Ten tiny modules, compiled through the logging `--cc` wrapper.
      let work = root / name
      createDir(work)
      var imports: seq[string] = @[]
      var sum: seq[string] = @[]
      for k in 0 ..< 10:
        writeFile(work / ("m" & $k & ".nim"),
          "proc f" & $k & "*(x: int): int = x * " & $(k + 2) & " + 1\n")
        imports.add "m" & $k
        sum.add "f" & $k & "(1)"
      writeFile(work / "main.nim",
        "import " & imports.join(", ") & "\necho " & sum.join(" + ") & "\n")
      let log = work / "cc.log"
      let realCc = findExe("gcc")
      prerequisite realCc.len > 0, "no gcc on PATH"
      let wrapper = work / "cc-wrapper.sh"
      writeScript(wrapper,
        "case \" $* \" in\n" &
        "  *\" -c \"*)\n" &
        "    echo \"+ $(date +%s%N)\" >> '" & log & "'\n" &
        "    sleep 0.3\n" &
        "    '" & realCc & "' \"$@\"; rc=$?\n" &
        "    echo \"- $(date +%s%N)\" >> '" & log & "'\n" &
        "    exit $rc ;;\n" &
        "  *) exec '" & realCc & "' \"$@\" ;;\n" &
        "esac\n")
      var args = runArgs
      args.add ["nim", "c", "--hints:off", "--verbosity:0",
        "--nimcache:" & work / "nc", "--out:" & work / "main",
        "--cc:gcc", "--gcc.exe:" & wrapper, "--gcc.linkerexe:" & wrapper]
      args.add nimExtra
      args.add work / "main.nim"
      let run = runq(baseEnv, args, workDir = work)
      let measured = peakConcurrency(log)
      (run, measured.peak, measured.compiles, work)

    test "nim_parallel_build_bounded: nim c under a 3-slot " &
        "grant never runs more than 3 C compiles at once":
      let bounded = compileProject("bounded", @["run", "--width", "3", "--"],
        @[])
      checkpoint bounded.run.output
      check bounded.run.code == 0
      check bounded.compiles >= 8
      check bounded.peak <= 3
      # Not vacuous: the fan-out really reached the bound.
      check bounded.peak >= 2
      # The build produced a working program: sum over k of (k+2)+1 = 75.
      let ran = execCmdEx(quoteShell(bounded.work / "main"))
      check ran.exitCode == 0
      check ran.output.strip() == "75"

    test "nim_parallel_build_bounded (control): without the " &
        "adapter the same build exceeds 3":
      let control = compileProject("control",
        @["run", "--width", "3", "--adapter", "none", "--"],
        @["--parallelBuild:8"])
      checkpoint control.run.output
      check control.run.code == 0
      check control.peak > 3

    test "a --parallelBuild the user set too wide is capped to the grant":
      let capped = compileProject("capped", @["run", "--width", "3", "--"],
        @["--parallelBuild:8"])
      checkpoint capped.run.output
      check capped.run.code == 0
      check capped.peak <= 3

    # -----------------------------------------------------------------
    # nix_build_gets_granted_cores
    # -----------------------------------------------------------------

    proc nixStub(name: string): tuple[env: StringTableRef, record: string] =
      ## A directory with a `nix` that writes its argv, one word per line,
      ## to a file and exits with $STUB_EXIT (default 0).
      let bin = root / name
      createDir(bin)
      let record = bin / "argv.txt"
      writeScript(bin / "nix",
        "printf '%s\\n' \"$@\" > '" & record & "'\n" &
        "exit \"${STUB_EXIT:-0}\"\n")
      (baseEnv.withVars({"PATH": bin & ":" & getEnv("PATH")}), record)

    proc recorded(path: string): string =
      readFile(path).strip().splitLines().join(" ")

    test "nix_build_gets_granted_cores: nix build is invoked " &
        "with --max-jobs 1 --cores equal to the grant":
      let stub = nixStub("nixstub1")
      let result = runq(stub.env, ["run", "--width", "4", "--", "nix",
        "build", ".#x"])
      checkpoint result.output
      check result.code == 0
      check recorded(stub.record) == "build --max-jobs 1 --cores 4 .#x"

    test "a --cores the user set is capped, not replaced; nix-build too":
      let stub = nixStub("nixstub2")
      check runq(stub.env, ["run", "--width", "4", "--", "nix", "build",
        "--cores", "64", ".#x"]).code == 0
      check recorded(stub.record) == "build --max-jobs 1 --cores 4 .#x"
      check runq(stub.env, ["run", "--width", "4", "--", "nix", "build",
        "--cores", "2", ".#x"]).code == 0
      check recorded(stub.record) == "build --max-jobs 1 --cores 2 .#x"

    test "no daemon is not an error: the command runs unchanged":
      let stub = nixStub("nixstub3")
      let env = stub.env.withVars({
        "RUNQUOTA_SOCKET": root / "nobody-listens.sock"})
      let result = runq(env, ["run", "--width", "4", "--", "nix", "build",
        ".#x"])
      checkpoint result.output
      check result.code == 0
      check recorded(stub.record) == "build .#x"

    # -----------------------------------------------------------------
    # Lease lifecycle, exit codes, arguments
    # -----------------------------------------------------------------

    test "the child sees its lease; afterwards the daemon holds none":
      let rq = quoteShell(cliPath())
      let during = runq(baseEnv,
        ["run", "--width", "3", "--stats-key", "test/lease-visible", "--",
         "sh", "-c", rq & " leases --json; echo width=$RUNQUOTA_RUN_WIDTH"])
      checkpoint during.output
      check during.code == 0
      check "\"cpu_milli\":3000" in during.output
      check "\"state\":\"running\"" in during.output
      check "\"command_stats_id\":\"test/lease-visible\"" in during.output
      check "width=3" in during.output
      let after = runq(baseEnv, ["leases", "--json"])
      check after.output.strip() == "{\"leases\":[]}"

    test "the lease is released when the command fails too":
      check runq(baseEnv, ["run", "--", "sh", "-c", "exit 5"]).code == 5
      check runq(baseEnv, ["leases", "--json"]).output.strip() ==
        "{\"leases\":[]}"

    test "the child's exit status is the exit status, signals as 128+N":
      check runq(baseEnv, ["run", "--", "sh", "-c", "exit 7"]).code == 7
      check runq(baseEnv, ["run", "--", "sh", "-c", "exit 200"]).code == 200
      check runq(baseEnv, ["run", "--", "sh", "-c", "kill -TERM $$"]).code ==
        143
      check runq(baseEnv, ["run", "--", "sh", "-c", "kill -KILL $$"]).code ==
        137
      let missing = runq(baseEnv, ["run", "--", "no-such-command-runq"])
      check missing.code == 127

    test "SIGTERM sent to the wrapper reaches the command, and its " &
        "status comes back":
      # The wrapper pid is the one THIS test started; nothing else is
      # signalled. The command traps TERM, says so, and exits 42.
      var wrapper = startProcess(cliPath(), env = baseEnv,
        args = ["run", "--width", "1", "--", "sh", "-c",
          "trap 'echo got-term; exit 42' TERM; " &
          "while :; do sleep 0.1; done"],
        options = {poStdErrToStdOut})
      defer: wrapper.close()
      # Wait until the lease is running, so the command exists and has
      # installed its trap (the trap is the first thing the script does,
      # and the daemon is told "running" after the launch).
      var seen = false
      for _ in 0 ..< 300:
        if "\"state\":\"running\"" in runq(baseEnv,
            ["leases", "--json"]).output:
          seen = true
          break
        sleep(50)
      check seen
      sleep(300)
      wrapper.terminate()
      let text = wrapper.outputStream.readAll()
      let code = wrapper.waitForExit(30_000)
      checkpoint text
      check code == 42
      check "got-term" in text
      check runq(baseEnv, ["leases", "--json"]).output.strip() ==
        "{\"leases\":[]}"

    test "the session group from the environment is joined":
      let rq = quoteShell(cliPath())
      let result = runq(baseEnv.withVars({
          "RUNQUOTA_SESSION": "runq-test:1",
          "RUNQUOTA_SESSION_PRIORITY": "high"}),
        ["run", "--width", "1", "--", "sh", "-c", rq & " status --json"])
      checkpoint result.output
      check result.code == 0
      check "\"name\":\"runq-test:1\"" in result.output
      check "\"priority\":\"high\"" in result.output

    test "a width range is negotiated down to what the budget grants":
      let result = runq(baseEnv, ["run", "--width", "1:16", "--", "sh", "-c",
        "echo width=$RUNQUOTA_RUN_WIDTH"])
      checkpoint result.output
      check result.code == 0
      check "width=" & $(BudgetMilli div 1000) in result.output

    test "a fixed width the budget cannot grant fails and runs nothing":
      let marker = root / "must-not-exist"
      let result = runq(baseEnv, ["run", "--width", "16", "--", "sh", "-c",
        "touch '" & marker & "'"])
      checkpoint result.output
      check result.code == 1
      check "exceeds machine CPU budget" in result.output
      check not fileExists(marker)

    test "--cap is refused with exit 2 and runs nothing":
      let marker = root / "cap-must-not-exist"
      let result = runq(baseEnv, ["run", "--cap", "--", "sh", "-c",
        "touch '" & marker & "'"])
      check result.code == 2
      check "--cap is not available yet" in result.output
      check not fileExists(marker)

    test "bad arguments exit 2":
      check runq(baseEnv, ["run", "--width", "0", "--", "true"]).code == 2
      check runq(baseEnv, ["run", "--width", "6:2", "--", "true"]).code == 2
      check runq(baseEnv, ["run", "--adapter", "nosuch", "--", "true"]).code ==
        2
      check runq(baseEnv, ["run", "--width", "2"]).code == 2
      check runq(baseEnv, ["run", "--bogus", "--", "true"]).code == 2

    test "--adapter list names every adapter":
      let result = runq(baseEnv, ["run", "--adapter", "list"])
      check result.code == 0
      for name in ["nim", "go", "nextest", "nix", "pnpm", "yarn",
          "playwright", "npm"]:
        check name in result.output

    test "PENDING learned_width_used: three runs peaking at 6 " &
        "slots make `run` without --width request 6":
      # NOT IMPLEMENTED, NOT FAKED. The width a command used is a CPU
      # profile total the daemon has to record and serve (per-lease peak
      # slots under the stats key); the client has nothing to read until
      # then, and `learnedWidth` in run_command.nim answers none. The test
      # is written when that lands: run a command three times that holds six
      # busy processes, then assert the next `run` (no --width) holds a
      # 6000 milli-CPU lease.
      skip()
  stopOwned(daemon)
  removeDir(root)
else:
  echo "t_run_command: POSIX only"
