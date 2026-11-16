## `runquota jobserver` end to end on WINDOWS: the built CLI, a real private
## `runquotad` on a scratch named pipe, and the real jobserver clients -- cargo
## and rustc -- building a real workspace, with the token bound carried by the
## named semaphore the Windows bridge serves.
##
## THE POSIX SIBLING is `tests/integration/t_jobserver_command.nim`; this file
## is its Windows arm. It cannot share that file's fixture: that one drives a
## Unix socket and writes `/bin/sh` wrappers, neither of which exists here.
##
## NO MOCKS, EXCEPT ONE, JUSTIFIED -- the same one the POSIX file justifies.
## Concurrency is measured through a `RUSTC_WRAPPER` that logs `+ <ns>` when a
## compile starts and `- <ns>` when it ends and sleeps long enough for compiles
## to overlap (tiny crates are otherwise over before two could be seen running
## together). The wrapper is THIS TEST BINARY re-invoked: cargo runs
## `RUSTC_WRAPPER <rustc> <args>`, so when this binary is started with a first
## argument that names rustc it acts as the wrapper -- it runs the real rustc
## with the real arguments and holds the job's token while it sleeps, exactly
## as a slow compile would. That dispatch happens below before any test runs.
##
## THE TOOLS ARE PREREQUISITES, NOT OPTIONS. cargo and rustc are expected on
## PATH; a run that cannot find one fails rather than skips, since a skip here
## would read as a bridge that works.

when defined(windows):
  import std/[algorithm, monotimes, os, osproc, strtabs, strutils, unittest]

  import windows_daemon_fixture

  # -------------------------------------------------------------------
  # The RUSTC_WRAPPER arm of this binary (runs before any test)
  # -------------------------------------------------------------------

  proc stampFile(logDir: string): string =
    ## This wrapper's OWN event file in the shared log directory. A file per
    ## wrapper process, never a shared one: `fopen("a")` is NOT an atomic
    ## cross-process append on Windows (there is no `O_APPEND` at the kernel
    ## offset the way `>>` gives on POSIX), so concurrent wrappers appending
    ## to one file would interleave and corrupt the record. One file each, and
    ## the test merges them, sidesteps that entirely.
    logDir / ($getCurrentProcessId() & "-" & $getMonoTime().ticks & ".log")

  proc appendStamp(path, mark: string) =
    ## One `<mark> <ns>` line. Written only by this process (its own file), so
    ## there is no cross-process contention. The monotonic clock is
    ## QueryPerformanceCounter, system-wide, so stamps from the separate
    ## wrapper processes are comparable.
    try:
      let f = open(path, fmAppend)
      defer: f.close()
      f.writeLine(mark & " " & $getMonoTime().ticks)
    except CatchableError:
      discard

  proc runRealRustc(rustc: string; args: seq[string]): int =
    ## The real rustc with the real arguments, output inherited.
    try:
      var child = startProcess(rustc, args = args,
        options = {poParentStreams, poUsePath})
      result = child.waitForExit()
      child.close()
    except CatchableError:
      result = 127

  proc looksLikeRustc(arg: string): bool =
    let name = extractFilename(arg).toLowerAscii()
    name == "rustc" or name == "rustc.exe"

  proc maybeRunAsRustcWrapper() =
    ## When cargo invokes this binary as `RUSTC_WRAPPER <rustc> <args>`, the
    ## first argument names rustc; act as the wrapper and never reach the
    ## suite. A normal test run has no such argument.
    let params = commandLineParams()
    if params.len < 1 or not looksLikeRustc(params[0]):
      return
    let rustc = params[0]
    let rest = params[1 .. ^1]
    var crate = ""
    for i in 0 ..< rest.len - 1:
      if rest[i] == "--crate-name":
        crate = rest[i + 1]
    # Only real crate compiles are logged and slowed; cargo's own `-vV` and
    # `--crate-name ___` probes run at full speed.
    if crate.len > 0 and crate != "___":
      let path = stampFile(getEnv("RQ_WRAP_LOG"))
      appendStamp(path, "+")
      sleep(1000)
      let code = runRealRustc(rustc, rest)
      appendStamp(path, "-")
      quit(code)
    else:
      quit(runRealRustc(rustc, rest))

  maybeRunAsRustcWrapper()

  # -------------------------------------------------------------------
  # Measurement
  # -------------------------------------------------------------------

  proc peakConcurrency(logDir: string): tuple[peak, jobs: int] =
    ## The deepest overlap of `+ ns` / `- ns` intervals across every wrapper's
    ## own event file in `logDir`. Ends sort before starts on a tie, so
    ## back-to-back jobs do not count as overlapping.
    if not dirExists(logDir): return
    var events: seq[(int64, int)] = @[]
    for kind, path in walkDir(logDir):
      if kind != pcFile: continue
      for line in readFile(path).splitLines():
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
    prerequisite result.len > 0, name & " is not on PATH"

  # -------------------------------------------------------------------
  # The cargo fixture
  # -------------------------------------------------------------------

  proc cargoWorkspace(dir: string; crates: int): string =
    ## A workspace of `crates` independent library crates. Returns the
    ## workspace directory.
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
    dir

  proc cargoEnv(base: StringTableRef; dir, log: string): StringTableRef =
    base.withVars({"RUSTC_WRAPPER": getAppFilename(),
      "RQ_WRAP_LOG": log,
      "CARGO_HOME": dir / "cargo-home",
      "CARGO_TARGET_DIR": dir / "target",
      "CARGO_TERM_COLOR": "never",
      "CARGO_INCREMENTAL": "0"})

  suite "runquota jobserver (windows)":
    discard requireTool("cargo")
    discard requireTool("rustc")

    test "cargo_peak_equals_lease_slots: 16 independent crates under a " &
        "4-slot lease never run more than 4 rustc at once, and reach 4":
      var daemon = startDaemon("rqjscw", 8000)
      defer: daemon.stop()
      let work = daemon.root / "ws"
      let log = daemon.root / "rustclog"
      createDir(log)
      discard cargoWorkspace(work, 16)
      let run = runq(cargoEnv(daemon.env, work, log),
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
else:
  echo "t_jobserver_command_windows: Windows only"
