## `runquota nix-build-hook` end to end: a real `nix-daemon`, a real private
## `runquotad`, and real `nix-build` clients.
##
## WHAT IS UNDER TEST. Two `nix-build`s from two different session groups
## (`RUNQUOTA_SESSION`) each ask a `nix-daemon` for four derivations. Each
## derivation runs `NIX_BUILD_CORES` "compile processes" (the daemon's
## `cores = 2`), and each connection may run eight builds at once
## (`max-jobs = 8`), so without RunQuota sixteen processes would run
## together. The daemon's build hook is the shipped `runquota
## nix-build-hook`, and the private `runquotad` has a budget of four CPUs.
## The cases:
##
## * `builds_within_budget` -- at no moment do more than four compile
##   processes run, every derivation build is one lease in its requester's
##   group (four distinct derivations in each), each lease is as wide as the build's
##   `NIX_BUILD_CORES`, nothing lands in the group the nix-daemon's own
##   environment names, and the leases are all given back when the builds
##   end. Mutations that fail it: a hook that never takes a lease (always
##   `# decline`) runs up to sixteen at once with no grants; leasing one CPU
##   per build whatever its cores runs eight; reading the session group from
##   the hook's own environment instead of the requester's puts every lease
##   in `nix-daemon-env`; a holder that ignores its build's end (the locks
##   going free) keeps the first leases, and the later builds never start.
## * `released_when_the_client_is_killed` -- a build's lease is given back
##   once its client is killed (the daemon then kills the build, drops its
##   locks and its worker exits). A holder that never gives its lease back
##   fails it.
## * `no_daemon_builds_unadmitted` -- with no `runquotad` at the hook's
##   endpoint the builds still succeed, and the client is told they ran
##   unadmitted. A hook that fails the build, or postpones forever, fails it.
##
## THE COUNT IS EXACT, SO THERE IS NO SLACK. Every compile process adds one
## to a shared counter when it starts and takes one away when it ends, under
## `flock(1)`, and logs the value it left. The maximum logged value is the
## largest number that ran at once. A lease is given back up to ~400 ms after
## its build ends (`ProbeMillis * ReleaseMisses` plus a probe), which can only
## lower the count, never raise it; the bound is the budget itself.
##
## A POSITIVE CONTROL. The same builds with the hook disabled (`build-hook =`
## empty, no lease) must exceed the budget; otherwise the test could not tell
## a bounded daemon from an idle one.
##
## NO MOCKS. One deliberate impurity, justified: the private store is not
## sandboxed and its builder is the host's `/bin/sh`, with `sleep`, `cat` and
## `flock` from the host. An unprivileged `nix-daemon` cannot sandbox into
## `/nix/store`, and a private store directory holds none of Nix's own
## packages unless the test downloads them, which it must not. The builds
## exercise nothing that depends on the builder.
##
## ISOLATION. The `nix-daemon` runs as this user, on a socket and store under
## a fresh 0700 scratch directory, with a `nix.conf` of its own
## (`NIX_CONF_DIR`); the `runquotad` is private (`RUNQUOTA_ENDPOINT_SCOPE=
## private`). Only processes this file started are signalled, by their
## `Process`: the clients first (a failing case leaves none running; the
## daemon's worker for a client ends with it and kills its builds), then the
## two daemons. The scratch directory, store included, is removed at the
## end, whether the case passed or not. Each case also checks that no lease
## holder of its private `runquotad` is left running (found by the endpoint
## in its environment, read-only; nothing is signalled).
##
## THE TOOLS ARE PREREQUISITES. `nix-daemon` and `nix-build` must be on
## `PATH`; their absence fails the test rather than skipping it.
##
## Linux only: the hook's requester lookup reads `sock_diag` and `/proc`.

when defined(linux):
  import std/[json, os, osproc, posix, streams, strtabs, strutils, times,
    unittest]

  import daemon_binary
  import private_daemon_fixture

  const
    BudgetCpus = 4
    Cores = 2
    MaxJobs = 8
    Derivations = 4
    WorkerScript = """
export PATH="$toolPath"
step() {
  "$flock" "$ledger/lock" /bin/sh -c '
    n=$(cat "$1/count" 2>/dev/null || echo 0)
    n=$((n + $2))
    echo "$n" > "$1/count"
    echo "$3 $n $4" >> "$1/log"' step "$ledger" "$1" "$2" "$name"
}
i=0
while [ "$i" -lt "$NIX_BUILD_CORES" ]; do
  ( step 1 start; sleep "$seconds"; step -1 end ) &
  i=$((i + 1))
done
wait
echo "$NIX_BUILD_CORES" > "$out"
"""
    WorkExpression = """
{ tag, count, ledger, flock, script, toolPath, seconds }:
builtins.genList (i: builtins.derivation {
  name = "w-${tag}-${toString i}";
  system = builtins.currentSystem;
  builder = "/bin/sh";
  args = [ script ];
  inherit ledger flock seconds toolPath;
}) (builtins.fromJSON count)
"""

  type
    NixFixture = object
      root: string
      rqSocket: string
      rqDaemon: Process
      rqStarted: bool
      nixSocket: string
      nixDaemon: Process
      nixStarted: bool
      storeUri: string
      clientEnv: StringTableRef
      clients: seq[Process]   ## Every nix-build this case started.

  proc tool(name: string): string =
    # Not resolved through symlinks: `nix-daemon` and `nix-build` are links
    # to `nix`, which dispatches on the name it was run as.
    result = findExe(name, followSymlinks = false)
    prerequisite result.len > 0, name & " is not on PATH (a prerequisite)"

  proc toolDir(): string =
    ## Where the builder finds `sleep` and `cat`.
    parentDir(tool("sleep"))

  proc writeNixConf(root: string; hook: bool) =
    createDir(root / "conf")
    writeFile(root / "conf" / "nix.conf",
      "build-users-group =\n" &
      "sandbox = false\n" &
      "substituters =\n" &
      "max-jobs = " & $MaxJobs & "\n" &
      "cores = " & $Cores & "\n" &
      "build-poll-interval = 1\n" &
      "build-hook = " & (if hook: cliPath() & " nix-build-hook" else: "") &
      "\n")

  proc startNix(fixture: var NixFixture; root: string; rqSocket: string;
                hook = true) =
    ## A private runquotad (unless `rqSocket` is given: then the hook points
    ## at it whether or not anything listens) and a private nix-daemon whose
    ## build hook is the shipped CLI. Fills `fixture` as it goes, so a caller
    ## that registered `stopNix` first stops whatever started before a
    ## failure.
    fixture.root = root
    if rqSocket.len == 0:
      fixture.rqSocket = root / "rq.sock"
      let env = privateEnv(fixture.rqSocket)
      fixture.rqDaemon = startProcess(daemonPath(), env = env,
        args = daemonArgs(root, fixture.rqSocket,
          ["--cpu-milli", $(BudgetCpus * 1000),
           "--memory-bytes", $(64'u64 * 1024 * 1024 * 1024)]),
        options = {poStdErrToStdOut})
      fixture.rqStarted = true
      prerequisite awaitSocket(fixture.rqDaemon, fixture.rqSocket),
        startupContext(fixture.rqDaemon, "the private runquotad did not bind")
    else:
      fixture.rqSocket = rqSocket
    writeNixConf(root, hook)
    fixture.nixSocket = root / "nix.sock"
    let store = root / "store"
    fixture.storeUri = "unix://" & fixture.nixSocket & "?store=" & store
    var env = privateEnv(fixture.rqSocket)
    env["NIX_CONF_DIR"] = root / "conf"
    env["NIX_DAEMON_SOCKET_PATH"] = fixture.nixSocket
    # The daemon's OWN environment names a group. The leases must not land
    # in it: they belong to the requesters.
    env["RUNQUOTA_SESSION"] = "nix-daemon-env"
    fixture.nixDaemon = startProcess(tool("nix-daemon"), env = env,
      args = ["--store", "local?store=" & store & "&state=" & root / "state" &
        "&log=" & root / "log"], options = {poStdErrToStdOut})
    fixture.nixStarted = true
    prerequisite awaitSocket(fixture.nixDaemon, fixture.nixSocket),
      startupContext(fixture.nixDaemon, "the private nix-daemon did not bind")
    fixture.clientEnv = cleanEnvironment()
    fixture.clientEnv["NIX_CONF_DIR"] = root / "conf"
    createDir(root / "ledger")
    writeFile(root / "worker.sh", WorkerScript)
    writeFile(root / "work.nix", WorkExpression)

  proc stopNix(fixture: var NixFixture) =
    ## Never raises: it runs from `defer`.
    for client in fixture.clients:
      try:
        if client.running:
          client.kill()
          discard client.waitForExit(30_000)
        client.close()
      except CatchableError:
        discard
    fixture.clients = @[]
    if fixture.nixStarted: stopOwned(fixture.nixDaemon)
    if fixture.rqStarted: stopOwned(fixture.rqDaemon)
    fixture.nixStarted = false
    fixture.rqStarted = false

  proc rqEnv(fixture: NixFixture): StringTableRef =
    privateEnv(fixture.rqSocket)

  proc statusJson(fixture: NixFixture): JsonNode =
    let (code, text) = cli(fixture.rqEnv)
    prerequisite code == 0, "runquota status failed: " & text
    parseJson(text)

  proc leasesJson(fixture: NixFixture): JsonNode =
    let (code, text) = cli(fixture.rqEnv, ["leases", "--json"])
    prerequisite code == 0, "runquota leases failed: " & text
    parseJson(text)

  proc group(status: JsonNode; name: string): JsonNode =
    for row in status["session_groups"]:
      if row["name"].getStr() == name: return row
    for row in status["capacity"]["groups"]:
      if row["name"].getStr() == name: return row
    nil

  type SeenLease = object
    id: int
    group: string
    label: string
    cpuMilli: int

  proc sampleLeases(fixture: NixFixture; seen: var seq[SeenLease]) =
    ## Every live lease, with the session group of the session that holds
    ## it (`leases --json` names the session, `sessions --json` its group).
    ## A build holds its lease for at least its 1.5 s, so a 250 ms sample
    ## sees every one.
    var groups: seq[(int, string)] = @[]
    let (code, text) = cli(fixture.rqEnv, ["sessions", "--json"])
    prerequisite code == 0, "runquota sessions failed: " & text
    for session in parseJson(text)["sessions"]:
      groups.add((session["id"].getInt(), session["session_group"].getStr()))
    for lease in fixture.leasesJson()["leases"]:
      if lease["state"].getStr() notin ["granted", "starting", "running"]:
        continue
      let id = lease["id"].getInt()
      var known = false
      for entry in seen:
        if entry.id == id: known = true
      if known: continue
      var group = "?"
      for (sessionId, name) in groups:
        if sessionId == lease["session_id"].getInt(): group = name
      seen.add(SeenLease(id: id, group: group,
        label: lease["label"].getStr(),
        cpuMilli: lease["resources"]["cpu_milli"].getInt()))

  proc startBuild(fixture: var NixFixture; tag, group: string; count: int;
                  seconds: string): Process =
    var env = newStringTable(modeCaseSensitive)
    for key, value in fixture.clientEnv: env[key] = value
    if group.len > 0: env["RUNQUOTA_SESSION"] = group
    result = startProcess(tool("nix-build"), workingDir = fixture.root, env = env,
      args = ["--store", fixture.storeUri, fixture.root / "work.nix",
        "--argstr", "tag", tag, "--argstr", "count", $count,
        "--argstr", "ledger", fixture.root / "ledger",
        "--argstr", "flock", tool("flock"),
        "--argstr", "script", fixture.root / "worker.sh",
        "--argstr", "toolPath", toolDir(),
        "--argstr", "seconds", seconds, "--no-out-link",
        # Talkative: the hook says whose leases they are and how it knows.
        "-v"],
      options = {poStdErrToStdOut})
    fixture.clients.add(result)

  proc finish(build: Process; seconds: int): tuple[code: int, output: string] =
    ## Waits for a client; `stopNix` closes it (and kills it first if it is
    ## still running when the case ends).
    let code = build.waitForExit(seconds * 1000)
    if build.running:
      return (-1, "still running after " & $seconds & " s")
    (code, build.outputStream.readAll())

  proc holdersOf(rqSocket: string): seq[int] =
    ## Lease holders still running for this case's private `runquotad`: the
    ## processes whose environment names its socket and whose command line
    ## is a holder's. Read-only.
    let marker = "RUNQUOTA_SOCKET=" & rqSocket & "\0"
    for kind, dir in walkDir("/proc"):
      let name = extractFilename(dir)
      if name.len == 0 or not name[0].isDigit: continue
      try:
        if "--hold" notin readFile(dir / "cmdline"): continue
        if marker in readFile(dir / "environ"): result.add(parseInt(name))
      except CatchableError:
        discard

  proc noHoldersLeft(rqSocket: string): bool =
    ## A holder exits at most ~400 ms after its build's locks go free.
    for _ in 0 ..< 40:
      if holdersOf(rqSocket).len == 0: return true
      sleep(100)
    false

  type Ledger = object
    peak: int
    starts: int
    ends: int

  proc readLedger(root: string): Ledger =
    if not fileExists(root / "ledger" / "log"): return
    for line in readFile(root / "ledger" / "log").splitLines():
      let fields = line.splitWhitespace()
      if fields.len < 2: continue
      if fields[0] == "start": inc result.starts
      elif fields[0] == "end": inc result.ends
      result.peak = max(result.peak, parseInt(fields[1]))

  proc removeScratch(root: string) =
    ## The store's files are read-only, as Nix leaves them.
    if root.len == 0 or not dirExists(root): return
    discard execCmd("chmod -R u+w " & quoteShell(root))
    removeDir(root)

  proc twoSessions(fixture: var NixFixture; tag: string): seq[tuple[code: int,
      output: string]] =
    let a = fixture.startBuild(tag & "a", "nixs-a", Derivations, "1.5")
    let b = fixture.startBuild(tag & "b", "nixs-b", Derivations, "1.5")
    @[a.finish(300), b.finish(300)]

  suite "nix-daemon builds take RunQuota leases":
    test "positive_control_without_the_hook_exceeds_the_budget":
      let root = scratchDir("rqnix")
      var fixture: NixFixture
      defer:
        fixture.stopNix()
        removeScratch(root)
      fixture.startNix(root, "", hook = false)
      for result in fixture.twoSessions("c"):
        check result.code == 0
        if result.code != 0: echo result.output
      let ledger = readLedger(root)
      check ledger.starts == 2 * Derivations * Cores
      # Sixteen could run at once; anything above the budget shows the
      # unbounded daemon this test exists to bound.
      check ledger.peak > BudgetCpus
      echo "without the hook: peak ", ledger.peak, " compile processes"

    test "builds_within_budget":
      let root = scratchDir("rqnix")
      var fixture: NixFixture
      defer:
        fixture.stopNix()
        removeScratch(root)
      fixture.startNix(root, "")
      let a = fixture.startBuild("a", "nixs-a", Derivations, "1.5")
      let b = fixture.startBuild("b", "nixs-b", Derivations, "1.5")
      # While they run, every lease the daemon holds is a build's: as wide as
      # its cores, labelled with its derivation, and in its requester's group.
      # Bounds: the eight builds take about 4 rounds of 1.5 s plus up to a
      # poll interval (1 s) each to be admitted, ~10 s on a quiet host; 60 s
      # leaves room for a loaded one while a hook that never gives a lease
      # back (the later builds then wait forever) fails here, not at the
      # runner's timeout.
      var seen: seq[SeenLease] = @[]
      for _ in 0 ..< 240:
        fixture.sampleLeases(seen)
        if not a.running and not b.running: break
        sleep(250)
      let ra = a.finish(30)
      let rb = b.finish(30)
      check ra.code == 0
      check rb.code == 0
      for line in (ra.output & "\n" & rb.output).splitLines():
        if line.startsWith("runquota:"): echo line
      if ra.code != 0: echo ra.output
      if rb.code != 0: echo rb.output
      let ledger = readLedger(root)
      check ledger.starts == 2 * Derivations * Cores
      check ledger.ends == ledger.starts
      check ledger.peak <= BudgetCpus
      # The budget was used, not merely respected by builds that ran alone.
      check ledger.peak == BudgetCpus
      echo "with the hook: peak ", ledger.peak, " compile processes"
      # Each derivation build was one lease in its requester's group: four
      # distinct derivations in each, none anywhere else.
      var drvsA, drvsB: seq[string] = @[]
      for lease in seen:
        check lease.cpuMilli == Cores * 1000
        check lease.label.startsWith("nix ") and lease.label.endsWith(".drv")
        if lease.label.contains("-w-a-"):
          check lease.group == "nixs-a"
          if lease.label notin drvsA: drvsA.add(lease.label)
        elif lease.label.contains("-w-b-"):
          check lease.group == "nixs-b"
          if lease.label notin drvsB: drvsB.add(lease.label)
        else:
          checkpoint("unexpected lease " & lease.label)
          fail()
      check seen.len == 2 * Derivations
      check drvsA.len == Derivations
      check drvsB.len == Derivations
      var status = fixture.statusJson()
      check status.group("nix-daemon-env") == nil
      # And every lease was given back.
      var heldAfter = -1
      for _ in 0 ..< 40:
        status = fixture.statusJson()
        heldAfter = status["capacity"]["host"]["cpu_granted_milli"].getInt()
        if heldAfter == 0: break
        sleep(250)
      check heldAfter == 0
      check noHoldersLeft(fixture.rqSocket)

    test "released_when_the_client_is_killed":
      let root = scratchDir("rqnix")
      var fixture: NixFixture
      defer:
        fixture.stopNix()
        removeScratch(root)
      fixture.startNix(root, "")
      var build = fixture.startBuild("k", "nixs-k", 1, "60")
      var held = 0
      for _ in 0 ..< 120:
        sleep(250)
        held = fixture.statusJson()["capacity"]["host"][
          "cpu_granted_milli"].getInt()
        if held > 0 or not build.running: break
      check held == Cores * 1000
      # The client this test started, by its own Process.
      build.kill()
      discard build.waitForExit(30_000)
      var after = -1
      let deadline = epochTime() + 15.0
      while epochTime() < deadline:
        after = fixture.statusJson()["capacity"]["host"][
          "cpu_granted_milli"].getInt()
        if after == 0: break
        sleep(250)
      check after == 0
      check noHoldersLeft(fixture.rqSocket)

    test "no_daemon_builds_unadmitted":
      let root = scratchDir("rqnix")
      var fixture: NixFixture
      defer:
        fixture.stopNix()
        removeScratch(root)
      fixture.startNix(root, root / "nothing-listens.sock")
      let (code, output) = fixture.startBuild("n", "nixs-n", 2, "0.2").finish(120)
      check code == 0
      check "unadmitted" in output
      if code != 0 or "unadmitted" notin output: echo output
      check readLedger(root).starts == 2 * Cores
