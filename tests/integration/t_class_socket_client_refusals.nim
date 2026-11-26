## With `RUNQUOTA_CLASS` set, no failure to reach the class ends with the
## command running unleased.
##
## RAN ON: Linux (x86_64); every case runs on any POSIX host.
##
## A launcher that cannot reach a daemon usually warns and runs its command
## without a lease. Work that names a class asked for a reservation, and
## running it outside every budget is what a class refusal exists to
## prevent, so once a class is named every failure stops the launcher
## (`runquota run` exits 1 and does not start the command), naming the class
## and its socket:
##
## * a class outside the class-name rule;
## * a class socket path too long for the platform;
## * a class socket nobody listens on (a crashed daemon's leftover);
## * a class socket whose daemon never answers the Hello;
## * a class socket whose daemon answers for another class;
## * no class socket and no daemon at all (a cleanly stopped daemon, which
##   unlinked both) -- not standalone mode;
##
## and, with the same daemon running, the class is served. Mutation:
## classifying any of these as an ordinary connect failure (the launcher's
## warn-and-run) makes the command run and fails its case.
##
## THE LISTENERS THAT NEVER ANSWER OR ANSWER WRONGLY ARE THE TEST'S OWN
## SOCKETS, standing in for a wedged daemon and for a daemon of another
## class: no real daemon can be made to do either on demand. Everything else
## is the shipped CLI and a real `runquotad` on a private socket in a
## scratch directory (`tests/support/private_daemon_fixture`).

when defined(posix):
  import std/[os, osproc, posix, strtabs, strutils, unittest]

  import runquota_client
  import daemon_binary
  import host_true_command
  import private_daemon_fixture

  const Head = "schema = \"runquota.host-config.v1\"\n"

  proc listenOn(path: string): cint =
    ## A listening Unix socket at `path`, owner-only, as a daemon's would be.
    result = cint(posix.socket(AF_UNIX, SOCK_STREAM, 0))
    var address: Sockaddr_un
    address.sun_family = TSa_Family(AF_UNIX)
    copyMem(addr address.sun_path[0], unsafeAddr path[0], path.len)
    prerequisite bindSocket(SocketHandle(result),
      cast[ptr SockAddr](addr address), SockLen(sizeof(address))) == 0,
      "bind " & path
    discard chmod(path.cstring, Mode(0o600))
    prerequisite listen(SocketHandle(result), 8) == 0

  proc runWithClass(env: StringTableRef; className: string):
      tuple[code: int, output: string] =
    ## `runquota run -- true` with `RUNQUOTA_CLASS` set.
    let local = newStringTable(modeCaseSensitive)
    for key, value in env: local[key] = value
    local["RUNQUOTA_CLASS"] = className
    local["RUNQUOTA_HANDSHAKE_TIMEOUT_MS"] = "1500"
    cli(local, ["run", "--", trueCommand()])

  proc refused(result: tuple[code: int, output: string]; className: string;
               socket: string) =
    checkpoint result.output
    check result.code == StrictRefusalExitCode
    check "not running the command" in result.output
    check ("class " & className) in result.output
    if socket.len > 0:
      check socket in result.output

  suite "class_socket_client_refusals":
    test "no class failure runs the command unleased":
      let root = scratchDir("clsrefuse")
      defer: removeDir(root)
      let socket = root / "rq.sock"
      let env = privateEnv(socket)
      # Nothing at all: no daemon, no class socket.
      refused(runWithClass(env, "ci"), "ci", root / "class-ci.sock")
      # An invalid class.
      refused(runWithClass(env, "c i"), "c i", "")
      # A class socket path too long for the platform.
      let deep = root / repeat('d', 60) / repeat('e', 40)
      createDir(deep)
      let deepEnv = privateEnv(deep / "rq.sock")
      refused(runWithClass(deepEnv, repeat('c', 40)), repeat('c', 40), "")
      # A leftover class socket nobody listens on.
      let leftover = listenOn(root / "class-ci.sock")
      discard posix.close(leftover)
      refused(runWithClass(env, "ci"), "ci", root / "class-ci.sock")
      discard posix.unlink((root / "class-ci.sock").cstring)
      # A class socket whose "daemon" never answers the Hello.
      let wedged = listenOn(root / "class-ci.sock")
      refused(runWithClass(env, "ci"), "ci", root / "class-ci.sock")
      discard posix.close(wedged)
      discard posix.unlink((root / "class-ci.sock").cstring)

    test "a class socket that answers for another class is refused":
      let root = scratchDir("clswrong")
      defer: removeDir(root)
      let socket = root / "rq.sock"
      let env = privateEnv(socket)
      # A real daemon declaring `gpu`, whose socket is linked where `ci`'s
      # would be: the HelloOk names gpu.
      writeFile(root / "host.toml", Head & "[reservation.gpu]\n")
      var daemon = launchOwned(root, socket, env,
        daemonArgs(root, socket, @["--cpu-milli", "4000"]),
        what = "the private daemon")
      var stopped = false
      defer:
        if not stopped: stopOwned(daemon)
      prerequisite symlinkExists(root / "class-ci.sock") == false
      createSymlink(root / "class-gpu.sock", root / "class-ci.sock")
      # A link is not a socket: refused before any connect.
      refused(runWithClass(env, "ci"), "ci", root / "class-ci.sock")
      discard posix.unlink((root / "class-ci.sock").cstring)
      prerequisite posix.link((root / "class-gpu.sock").cstring,
        (root / "class-ci.sock").cstring) == 0
      refused(runWithClass(env, "ci"), "ci", root / "class-ci.sock")
      check "answered for class gpu" in runWithClass(env, "ci").output
      discard posix.unlink((root / "class-ci.sock").cstring)
      # And the declared class is served, the command run under a lease.
      let served = runWithClass(env, "gpu")
      checkpoint served.output
      check served.code == 0
      # A stopped daemon (both sockets unlinked): refused, not standalone.
      stopOwned(daemon)
      stopped = true
      check not isSocket(root / "class-gpu.sock")
      refused(runWithClass(env, "gpu"), "gpu", root / "class-gpu.sock")
