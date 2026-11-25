## A launcher whose endpoint EXISTS and refuses it says so, and
## `RUNQUOTA_STRICT` refuses instead of running the command unleased.
##
## THE DEFECT. A process started before its user joined the rendezvous group
## does not carry that group, so the host socket's mode refuses its
## `connect(2)` with `EACCES`. `runquota run`, `acquire` and `jobserver` then
## ran the command with no lease and said nothing: the command competed for
## the host outside every budget and nobody could tell. The same silence
## followed a socket nothing listens on (`ECONNREFUSED`).
##
## WHAT IS ASSERTED, for each of the three launchers:
##
## * refused, not strict: the command runs (a marker file appears), the exit
##   status is the command's, and the output carries EXACTLY ONE warning line
##   that names the socket, `EACCES (Permission denied)` and the remedy;
## * refused, strict: exit 1, the marker does NOT exist (the command was
##   never started), and the line names the socket and `RUNQUOTA_STRICT`;
## * a reachable daemon: no warning, and the command ran under a lease (the
##   lease id `run`/`acquire` export, or the jobserver `jobserver` serves).
##
## And around them: a socket nothing listens on is warned about with
## `ECONNREFUSED`; an absent socket is standalone mode (no warning) unless
## strict, which refuses it too.
##
## THE REFUSING SOCKET IS REAL, AND REFUSES WITH A REAL `EACCES`. This test
## binds and listens on a Unix socket itself, then `chmod 0`s the socket
## file: on Linux and macOS `connect(2)` needs write permission on the socket
## file, so a non-root caller gets `EACCES` while the listener is alive.
## Measured on Linux 2026-11-24 before writing this file: a listening socket
## at mode 0000 answers `EACCES`, a closed one at 0600 `ECONNREFUSED`. The
## test refuses to run as root, which bypasses the mode.
##
## WHY THE HOST POLICY, AND THE TWO OVERRIDES. Under the private policy the
## client refuses a socket whose mode is not exactly 0600 in its own trust
## check, before `connect(2)` -- a different failure from the one observed.
## The host policy checks only the directory, against the configured owner
## and group, which the documented `RUNQUOTA_ENDPOINT_OWNER_UID` and
## `RUNQUOTA_ENDPOINT_GROUP` point at this test's own uid and gid, so the
## scratch directory (0750, this uid and gid) passes and `connect(2)` is what
## refuses. Both are set only in the children's environment.
##
## NO MOCKS: the shipped `runquota` binary, a real `runquotad` on a private
## scratch socket for the reachable case, real sockets and real children.
## Only processes this file started are stopped.
##
## FALSIFYING MUTATIONS, each applied once, rebuilt (apps and test), run
## and reverted, measured on Linux 2026-11-24 against origin/agents `f766cf2`
## plus this change (12/12 pass unmutated):
##
## * `unleasedFallback` returns an empty message outside strict mode (the
##   warning dropped): 5 of 12 fail -- the three non-strict refused cases,
##   the `ECONNREFUSED` case and `RUNQUOTA_STRICT=0 and empty are off`.
## * `unleasedFallback` ignores `strict` (`RUNQUOTA_STRICT` ignored): 4 of
##   12 fail -- the three strict refused cases and the strict-on-absent
##   case.

when defined(posix):
  import std/[os, osproc, posix, streams, strtabs, strutils, unittest]

  import daemon_binary
  import private_daemon_fixture

  type RunResult = tuple[code: int, output: string]

  const
    WarningNeedle = ": warning: cannot use the RunQuota daemon at "
    LeakKeys = ["RUNQUOTA_STRICT", "RUNQUOTA_PARENT_LEASE",
      "RUNQUOTA_JOBSERVER_FIFO", "MAKEFLAGS", "MFLAGS",
      "RUNQUOTA_REPORT_STANDALONE", "RUNQUOTA_SESSION"]
      ## Inherited from whatever runs the suite, any of these would change
      ## the path under test: strict mode, a sub-lease or a joined
      ## jobserver instead of a host lease, an opted-in standalone report.

  proc runq(env: StringTableRef; args: openArray[string]): RunResult =
    ## The shipped CLI as a process, stderr merged into stdout.
    var process = startProcess(cliPath(), env = env, args = args,
      options = {poStdErrToStdOut})
    defer: process.close()
    let text = process.outputStream.readAll()
    (process.waitForExit(), text)

  proc copyEnv(env: StringTableRef;
               pairs: openArray[(string, string)] = []): StringTableRef =
    result = newStringTable(modeCaseSensitive)
    for key, value in env:
      if key notin LeakKeys: result[key] = value
    for (key, value) in pairs: result[key] = value

  proc warningCount(output: string): int =
    for line in output.splitLines():
      if WarningNeedle in line: inc result

  proc launcherArgs(launcher, marker: string): seq[string] =
    ## The launcher's command line for a command that records, in `marker`,
    ## the lease it ran under (empty when it ran unleased): `run` and
    ## `acquire` export the lease id, `jobserver` the jobserver it serves.
    let record =
      if launcher == "jobserver": "printf '%s' \"$MAKEFLAGS\" > '" & marker & "'"
      else: "printf '%s' \"$RUNQUOTA_PARENT_LEASE\" > '" & marker & "'"
    case launcher
    of "run": @["run", "--width", "1", "--", "/bin/sh", "-c", record]
    of "acquire": @["acquire", "--cpu", "1000", "--mem", "64MB", "--",
      "/bin/sh", "-c", record]
    else: @["jobserver", "--width", "1", "--", "/bin/sh", "-c", record]

  prerequisite geteuid() != 0,
    "root bypasses the socket's mode, so no EACCES can be produced"

  let root = scratchDir("rqref")
  # The refusing endpoint: a 0750 directory of this uid and gid, and a
  # listening socket in it at mode 0000.
  let refusedDir = root / "host"
  createDir(refusedDir)
  prerequisite chown(refusedDir.cstring, Uid(high(uint32)), getegid()) == 0,
    "cannot set the scratch directory's group"
  prerequisite chmod(refusedDir.cstring, Mode(0o750)) == 0
  let refusedSocket = refusedDir / "d.sock"
  let listener = posix.socket(AF_UNIX, SOCK_STREAM, 0)
  prerequisite cint(listener) >= 0, "cannot create a socket"
  var address: Sockaddr_un
  address.sun_family = TSa_Family(AF_UNIX)
  prerequisite refusedSocket.len < address.sun_path.len,
    "scratch socket path too long: " & refusedSocket
  copyMem(addr address.sun_path[0], refusedSocket.cstring, refusedSocket.len)
  prerequisite bindSocket(listener, cast[ptr SockAddr](addr address),
    SockLen(sizeof(address))) == 0, "cannot bind " & refusedSocket
  prerequisite listen(listener, 16) == 0
  prerequisite chmod(refusedSocket.cstring, Mode(0)) == 0
  # A socket file nothing listens on: bound, then closed.
  let staleSocket = refusedDir / "stale.sock"
  block:
    let s = posix.socket(AF_UNIX, SOCK_STREAM, 0)
    var a: Sockaddr_un
    a.sun_family = TSa_Family(AF_UNIX)
    copyMem(addr a.sun_path[0], staleSocket.cstring, staleSocket.len)
    prerequisite bindSocket(s, cast[ptr SockAddr](addr a),
      SockLen(sizeof(a))) == 0, "cannot bind " & staleSocket
    discard posix.close(s)

  let hostEnv = copyEnv(cleanEnvironment(), {
    "RUNQUOTA_SOCKET": refusedSocket,
    "RUNQUOTA_ENDPOINT_OWNER_UID": $geteuid(),
    "RUNQUOTA_ENDPOINT_GROUP": $getegid()})

  # The reachable control: a private daemon of this test's own.
  let daemonRoot = scratchDir("rqrefd")
  let daemonSocket = daemonRoot / "d.sock"
  let daemonEnv = copyEnv(privateEnv(daemonSocket))
  let daemon = launchOwned(daemonRoot, daemonSocket, daemonEnv,
    daemonArgs(daemonRoot, daemonSocket, ["--cpu-milli", "4000"]))

  suite "a refused endpoint is warned about; RUNQUOTA_STRICT refuses":
    for launcher in ["run", "acquire", "jobserver"]:
      test launcher & ": refused (EACCES), not strict: runs, one warning":
        let marker = root / (launcher & "-refused-ran")
        let result = runq(hostEnv, launcherArgs(launcher, marker))
        checkpoint result.output
        check result.code == 0
        check fileExists(marker)
        check readFile(marker).len == 0          # it ran unleased
        check warningCount(result.output) == 1
        check refusedSocket in result.output
        check "EACCES (Permission denied)" in result.output
        check "start a new login session" in result.output
        check "RUNQUOTA_STRICT=1" in result.output

      test launcher & ": refused (EACCES), strict: exits 1, does not run":
        let marker = root / (launcher & "-strict-ran")
        let result = runq(copyEnv(hostEnv, {"RUNQUOTA_STRICT": "1"}),
          launcherArgs(launcher, marker))
        checkpoint result.output
        check result.code == 1
        check not fileExists(marker)
        check refusedSocket in result.output
        check "EACCES" in result.output
        check "RUNQUOTA_STRICT is set" in result.output
        check "not running the command" in result.output

      test launcher & ": a reachable daemon: no warning, leased":
        let marker = root / (launcher & "-leased-ran")
        let result = runq(copyEnv(daemonEnv, {"RUNQUOTA_STRICT": "1"}),
          launcherArgs(launcher, marker))
        checkpoint result.output
        check result.code == 0
        check fileExists(marker)
        if fileExists(marker):
          let recorded = readFile(marker)
          if launcher == "jobserver":
            check "--jobserver-auth=" in recorded
          else:
            check recorded.len > 0 and recorded.allCharsInSet(Digits)
        check warningCount(result.output) == 0
        check "RUNQUOTA_STRICT" notin result.output

    test "a socket nothing listens on (ECONNREFUSED) is warned about":
      let marker = root / "stale-ran"
      let result = runq(copyEnv(hostEnv, {"RUNQUOTA_SOCKET": staleSocket}),
        launcherArgs("run", marker))
      checkpoint result.output
      check result.code == 0
      check fileExists(marker)
      check warningCount(result.output) == 1
      check staleSocket in result.output
      check "ECONNREFUSED" in result.output

    test "an absent socket is standalone: no warning; strict refuses it":
      let absent = refusedDir / "absent.sock"
      let marker = root / "absent-ran"
      let quiet = runq(copyEnv(hostEnv, {"RUNQUOTA_SOCKET": absent}),
        launcherArgs("run", marker))
      checkpoint quiet.output
      check quiet.code == 0
      check fileExists(marker)
      check warningCount(quiet.output) == 0
      check quiet.output.strip().len == 0
      let strictMarker = root / "absent-strict-ran"
      let strict = runq(copyEnv(hostEnv, {"RUNQUOTA_SOCKET": absent,
        "RUNQUOTA_STRICT": "1"}), launcherArgs("run", strictMarker))
      checkpoint strict.output
      check strict.code == 1
      check not fileExists(strictMarker)
      check absent in strict.output
      check "ENOENT" in strict.output

    test "RUNQUOTA_STRICT=0 and empty are off":
      for value in ["0", ""]:
        let marker = root / ("strict-off-" & $value.len & "-ran")
        let result = runq(copyEnv(hostEnv, {"RUNQUOTA_STRICT": value}),
          launcherArgs("run", marker))
        checkpoint result.output
        check result.code == 0
        check fileExists(marker)
        check warningCount(result.output) == 1

  stopOwned(daemon)
  discard posix.close(listener)
  removeDir(daemonRoot)
  removeDir(root)
else:
  echo "t_refused_endpoint_warns_or_refuses: POSIX only"
