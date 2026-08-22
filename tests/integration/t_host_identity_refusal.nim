## M13c-fix: a `host_id` that cannot be persisted is a REFUSAL, and the
## host-wide state directory it lives in is created by INSTALLATION.
##
## Normative: `reprobuild-specs/RunQuota-Observation-Store.md` §"The
## Execution Spine" — "**A `host_id` that cannot be persisted MUST be a
## refusal, never an ephemeral one.**" and "Because the file is host-wide
## and daemon-owned, its directory MUST be provisioned by the install step
## rather than created on demand by whichever process starts first."
##
## THE DECIDING CONTROL IN THIS FILE IS REPETITION, and it is the only
## check that can tell a real identity from a fresh one that looks fine.
## The defect this repairs was invisible to every other kind of assertion:
## `resolveHostIdentity()` returned a well-formed, correctly-prefixed,
## correctly-shaped opaque id, `hosts` got a row, `executions` got a
## `host_id`, and the aggregates still carried a hardware dimension. Every
## type in the system was satisfied. What was wrong was only visible ACROSS
## invocations — the id was different every time, so no two rows ever
## pooled. So: two consecutive resolutions, and they must agree. A run that
## produces two different ids fails regardless of what it reports.
##
## Nothing is mocked. The library assertions call the shipped
## `resolveHostIdentity`; the daemon assertions start the real `runquotad`
## binary and take a real lease through the real `runquota` CLI.
##
## THE REAL DEFAULT PATH IS EXERCISED HERE, with no argument passed. Every
## earlier experiment passed an explicit path under `/private/tmp`, so
## `defaultHostIdentityFile()` — the thing that actually ships — had never
## been resolved by a test at all.

import std/[os, osproc, streams, strutils, unittest]

import runquota_ipc
import runquota_observation_store

proc scratchDir(name: string): string =
  # Short on purpose. Nim's `Sockaddr_un_path_length` is 92 on macOS, and
  # `toSockAddr` refuses `path.len >= 92`, so 91 characters is the whole
  # budget. A plain macOS `TMPDIR` is 49 characters before anything is
  # appended; inside `nix develop` it is 21, which is why an over-long
  # fixture passes in the sanctioned shell and in CI and fails nowhere
  # anyone looks.
  result = getTempDir() / ("rq-hi-" & $getCurrentProcessId() & name)
  removeDir(result)
  createDir(result)
  # THE MODE THE SHIPPED POLICY REQUIRES, not a literal: some of these
  # fixtures ARE the rendezvous directory the daemon binds in, and the
  # rendezvous mode is 0750 where a `runquota` group exists and 0700
  # (owner-only, single-user mode) where it does not. Nothing in this file
  # asserts the fixture's own mode; the modes themselves are asserted in
  # `tests/unit/t_shared_endpoint_rules.nim`.
  setFilePermissions(result, endpointDirectoryPermissions())

proc contents(path: string): string =
  ## Deliberately not `readFile`. A missing artifact must fail its own
  ## `fileExists` clause and then let EVERY remaining clause report too --
  ## an IOError here would take the suite out at the first one and hide
  ## which of the install artifacts had actually gone missing.
  if fileExists(path): readFile(path) else: ""

proc childCount(dir: string): int =
  for _ in walkDir(dir):
    inc result

proc containsMintedHostId(text: string): bool =
  ## True when `text` carries something SHAPED like a `host_id`. The
  ## refusal must not, and this is the assertion that says so: the whole
  ## defect was a startup line that read as perfectly healthy because it
  ## named a well-formed id nothing had written down.
  ##
  ## `host-id` -- the file NAME, which the refusal does quote -- is not one
  ## of these. It is far short of the shape and fails `isOpaqueId`, which
  ## is why this is a shape test rather than a substring test.
  var start = 0
  while true:
    let at = text.find(hostIdPrefix, start)
    if at < 0:
      return false
    let stop = min(text.len, at + hostIdPrefix.len + 32)
    if isOpaqueId(text[at ..< stop], hostIdPrefix):
      return true
    start = at + 1

proc daemonPath(): string =
  getCurrentDir() / "build" / "bin" / "runquotad"

proc cliPath(): string =
  getCurrentDir() / "build" / "bin" / "runquota"

proc waitForSocket(socketPath: string) =
  for _ in 0 ..< 200:
    if fileExists(socketPath) or socketPath.startsWith("\\\\"):
      return
    sleep(25)

type DaemonHandle = object
  process: Process
  startupLines: seq[string]

proc startDaemon(socketPath, observationDb, identityFile: string):
    DaemonHandle =
  let process = startProcess(
    daemonPath(),
    args = ["--socket", socketPath, "--observation-db", observationDb,
            "--host-identity-file", identityFile],
    options = {poStdErrToStdOut}
  )
  waitForSocket(socketPath)
  # EXACTLY THREE LINES, and reading precisely three is itself an
  # assertion. `OSError.msg` on macOS is two lines -- the message and an
  # "Additional info:" line -- and the refusal report quotes it. An
  # unfolded message would make this a four-line startup and every reader
  # of the third line would misread or block.
  var lines: seq[string] = @[]
  for _ in 0 ..< 3:
    lines.add(process.outputStream.readLine())
  DaemonHandle(process: process, startupLines: lines)

proc stop(handle: var DaemonHandle) =
  if handle.process.running:
    handle.process.terminate()
    discard handle.process.waitForExit(5000)
  handle.process.close()

suite "host_identity_refusal":
  test "an unprovisioned directory yields a refusal, and the SAME one twice":
    ## THE DECIDING CONTROL. Against the pre-fix code the two ids below
    ## differ on every run, and every other assertion in this test passes.
    let dir = scratchDir("a")
    defer: removeDir(dir)

    # A state directory that does not exist and that nothing here creates.
    let absent = dir / "runquota"
    let file = absent / "host-id"
    check not dirExists(absent)

    let first = resolveHostIdentity(file)
    let second = resolveHostIdentity(file)

    # Refused, both times, and identically.
    check not first.persisted
    check not second.persisted
    check first.hostId.len == 0
    check second.hostId.len == 0
    check first.hostId == second.hostId
    check first.report == second.report
    check first.path == file
    check second.path == file

    # The invariant that makes "an id that is not on disk" unrepresentable
    # rather than merely discouraged.
    check (first.hostId.len > 0) == first.persisted
    check (second.hostId.len > 0) == second.persisted

    # The refusal is legible: it names the file, the directory, and the
    # command that fixes it. A refusal that says only "cannot persist"
    # leaves the operator to guess, and the guess is "mkdir it as me",
    # which is the failure this whole rule exists to prevent.
    check "cannot persist" in first.report
    check file in first.report
    check absent in first.report
    check "install step" in first.report
    check provisionHostStateDirCommand(absent) in first.report

    # ONE LINE. The daemon's startup output is a fixed number of lines.
    check first.report.splitLines.len == 1

    # AND NOTHING CREATED IT. "Provisioned by the install step, not on
    # demand by whichever process starts first" is a claim about what the
    # daemon does NOT do, so it is asserted as an absence.
    check not dirExists(absent)
    check not fileExists(file)
    check childCount(dir) == 0

  test "a provisioned directory yields ONE id, and the same one twice":
    ## The positive control. Without it the refusal above is satisfied by
    ## an implementation that refuses unconditionally, which would pass
    ## every clause of the negative and record nothing anywhere.
    let dir = scratchDir("b")
    defer: removeDir(dir)
    let file = dir / "host-id"

    let first = resolveHostIdentity(file)
    check first.persisted
    check isOpaqueId(first.hostId, "host-")
    check (first.hostId.len > 0) == first.persisted

    let second = resolveHostIdentity(file)
    check second.persisted
    check second.hostId == first.hostId
    check readFile(file).strip() == first.hostId
    check first.report.splitLines.len == 1

  test "the REAL default path resolves to one outcome, not one per call":
    ## M13c's same-`host_id` clause, re-run against what actually ships.
    ## Both earlier experiments passed an explicit path in `/private/tmp`,
    ## so `defaultHostIdentityFile()` had never been resolved by a test.
    ##
    ## Deliberately asserted in a form that holds in BOTH host states, so
    ## it is not a check that only fires on a machine somebody remembered
    ## to prepare:
    ##   * provisioned   -> the same persisted id twice;
    ##   * unprovisioned -> the same refusal twice, and no id at all.
    ## Either way, TWO DIFFERENT IDS IS A FAILURE. That is the clause.
    ##
    ## It is also uid-independent by construction -- `defaultHostIdentityFile`
    ## reads no environment -- so running this same binary under a second
    ## uid re-runs the two-uid clause directly. See the milestone report.
    let first = resolveHostIdentity()
    let second = resolveHostIdentity()

    check first.path == defaultHostIdentityFile()
    check first.path == second.path
    check first.hostId == second.hostId
    check first.persisted == second.persisted
    check first.report == second.report
    check (first.hostId.len > 0) == first.persisted
    check first.report.splitLines.len == 1

    echo "  default host identity: path=", first.path,
      " hostId=[", first.hostId, "] persisted=", first.persisted,
      " provisioned=", dirExists(first.path.parentDir)

    if dirExists(first.path.parentDir):
      # A provisioned host: this machine has ONE identity and it is on
      # disk. `hosts` gains no row per daemon start.
      check first.persisted
      check isOpaqueId(first.hostId, "host-")
      check readFile(first.path).strip() == first.hostId
    else:
      # An unprovisioned host: refused, and STILL not created.
      check not first.persisted
      check first.hostId.len == 0
      check "cannot persist" in first.report
      check hostWideStateDir in first.report
      check not dirExists(first.path.parentDir)

  test "the daemon starts, serves leases, and says capture is off":
    ## Refuse-vs-disable, decided and asserted. RunQuota's mission is
    ## ADMISSION: a daemon that cannot record history can still keep a
    ## machine from thrashing itself to death, and refusing to admit
    ## anything because a statistics directory is missing would let an
    ## advisory subsystem take out the host's build capacity. So the
    ## daemon starts and serves -- and says which path and why.
    let dir = scratchDir("c")
    defer: removeDir(dir)
    let socketPath = dir / "d.sock"
    let dbPath = dir / "obs.sqlite"
    let absent = dir / "state"
    let identityFile = absent / "host-id"
    check fileExists(daemonPath())
    check fileExists(cliPath())
    putEnv("RUNQUOTA_SOCKET", socketPath)

    var reportLine = ""
    var daemon = startDaemon(socketPath, dbPath, identityFile)
    try:
      # The store itself opened fine, so this is the identity refusal and
      # not the neighbouring corrupt-store one.
      check daemon.startupLines[1].contains("capture enabled")
      reportLine = daemon.startupLines[2]
      check reportLine.contains("capture disabled")
      check reportLine.contains("no host identity")
      check reportLine.contains(identityFile)
      check reportLine.contains(absent)
      check reportLine.contains("install step")
      # NOT an id. The whole defect was that this line looked healthy.
      check not containsMintedHostId(reportLine)

      # Still a lease authority: a real lease, through the real CLI.
      let acquired = execCmdEx(quoteShellCommand([
        cliPath(), "acquire", "--cpu", "1000", "--mem", "128MB",
        "--label", "host-identity-refusal", "--",
        "/bin/echo", "admission-still-works"
      ]))
      check acquired.exitCode == 0
      check "admission-still-works" in acquired.output
      check daemon.process.running

      # And nothing was recorded against an invented machine.
      let store = openObservationStore(dbPath)
      check store.captureEnabled
      check store.readHosts().len == 0
      check store.readExecutions().len == 0
      check not dirExists(absent)
    finally:
      daemon.stop()

    # REPETITION, against a real process rather than a library call. Two
    # daemon starts on an unprovisioned host must produce the same line.
    # Pre-fix, this line carried a freshly minted id and so differed on
    # every start while reading as perfectly healthy.
    let secondSocket = dir / "d2.sock"
    putEnv("RUNQUOTA_SOCKET", secondSocket)
    var restarted = startDaemon(secondSocket, dbPath, identityFile)
    try:
      check restarted.startupLines[2] == reportLine
      check restarted.process.running
    finally:
      restarted.stop()

suite "host_identity_provisioning":
  test "an install step provisions the directory the daemon looks in":
    ## "Provisioned by the install step" is a fact about what this repo
    ## SHIPS, so it is asserted against the shipped install artifacts. The
    ## behavioural half -- that the daemon does not create it -- is
    ## asserted in the suite above; this half is that something else does,
    ## and that it agrees about where.
    let root = getCurrentDir()
    let hostStateNix = root / "nix" / "host-state.nix"
    let nixosModule = root / "nix" / "modules" / "runquotad-nixos.nix"
    let darwinModule = root / "nix" / "modules" / "runquotad-darwin.nix"
    let flake = root / "flake.nix"
    let runbook = root / "docs" / "database.md"

    for path in [hostStateNix, nixosModule, darwinModule, flake, runbook]:
      check fileExists(path)

    let hostState = contents(hostStateNix)
    # THE CONSISTENCY CHECK. Two copies of a path is one chance for them to
    # disagree, and a state directory provisioned somewhere the daemon does
    # not look is an unprovisioned host with more moving parts. Every
    # platform's path is compared, not just this one's, because the two
    # that are not being run on are exactly the ones that drift.
    check "\"/var/db/runquota\"" in hostState
    check "\"/var/lib/runquota\"" in hostState
    check "C:\\ProgramData\\runquota" in hostState
    # ... and the branch actually compiled in here is one of them, read
    # from the daemon's own constant rather than repeated.
    check ("\"" & hostWideStateDir & "\"") in hostState or
      hostWideStateDir in hostState
    check defaultHostIdentityFile() == hostWideStateDir / "host-id"
    check "identityFileName = \"host-id\"" in hostState

    # M13d: THE RENDEZVOUS DIRECTORY IS THE SECOND HOST-WIDE PATH, and it
    # is duplicated the same way, so it can drift the same way. Its group
    # is checked too: the group is the admission list, and a rendezvous
    # provisioned without one is either unreachable or open to everybody.
    check "\"/var/run/runquota\"" in hostState
    check "\"/run/runquota\"" in hostState
    check ("\"" & hostWideEndpointDir & "\"") in hostState
    check ("endpointSocketName = \"" & endpointSocketName & "\"") in hostState
    check ("endpointDirectoryMode = \"" & modeText(endpointDirectoryMode) &
      "\"") in hostState
    check ("endpointSocketMode = \"" & modeText(endpointSocketMode) &
      "\"") in hostState
    check ("group = \"" & defaultRendezvousGroup & "\"") in hostState

    # The modules provision it rather than merely mentioning it.
    let nixos = contents(nixosModule)
    check "systemd.tmpfiles.rules" in nixos
    check "StateDirectory" in nixos
    check "host-state.nix" in nixos
    check "endpointDirectories.linux" in nixos
    check "RuntimeDirectory" in nixos
    # The RULE, not just the reference: a module that mentioned the path
    # in a `let` and never provisioned it would satisfy the line above.
    check "\"d ${endpointDir} ${hostState.endpointDirectoryMode}" in nixos

    let darwin = contents(darwinModule)
    check "system.activationScripts" in darwin
    check "install -d" in darwin
    check "host-state.nix" in darwin
    check "endpointDirectories.darwin" in darwin
    # The INSTALL, not just the reference.
    check "rendezvous directory" in darwin
    check "-m ${hostState.endpointDirectoryMode}" in darwin


    # The flake exposes them, so `imports = [ ... ]` can reach them.
    let flakeText = contents(flake)
    check "nixosModules.runquotad" in flakeText
    check "darwinModules.runquotad" in flakeText
    # BOTH modules are EVALUATED, not merely parsed. The darwin one used
    # to be described exactly as the NixOS one while only the NixOS one
    # had been through a module system, which left an operator unable to
    # tell the verified module from the unverified one.
    check "module-eval" in flakeText
    check "darwinSystem" in flakeText
    check "nixosSystem" in flakeText
    check "inputs.nixos-modules.inputs.nix-darwin" in flakeText

    # And a host not managed by Nix has a runbook that says the directory
    # must pre-exist -- the omission that let this defect ship.
    let runbookText = contents(runbook)
    check "Provisioning the host-wide state directory" in runbookText
    check "must already exist" in runbookText
    check hostWideStateDir in runbookText
    check "sudo mkdir -p " & hostWideStateDir in runbookText
    check hostWideEndpointDir in runbookText
    check "sudo mkdir -p " & hostWideEndpointDir in runbookText
    check defaultRendezvousGroup in runbookText
