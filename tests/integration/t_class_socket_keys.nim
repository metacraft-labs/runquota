## The host file's class-socket keys: read, refused, and written.
##
## RAN ON: Linux (x86_64). Every case runs on any POSIX host, and the
## reader cases read the file as each platform would (`HostConfigPlatform`),
## so the Windows keys' acceptance and the Linux and macOS keys' refusal on
## Windows are covered here too.
##
## WHAT IS GUARDED, and the change each case fails under.
##
## * `class_socket_keys_read_and_refused` -- the reader accepts
##   `socket-owner`, `socket-group` and `socket-mode` (and their owner-only
##   defaults) on Linux and macOS and `allowed-users` / `allowed-groups` on
##   Windows, and refuses a `socket-mode` outside `"0600"` / `"0660"` /
##   `"0666"`, an unknown user or group, and a key of the other platform,
##   each naming the file and line. A real daemon refuses such a file at
##   start (exit 2) and on reload, with the class sockets and reservations in
##   force unchanged. A decimal id above 4294967294 is refused too. Mutation: dropping the mode check accepts `"0644"`
##   (through which no group member could connect) and fails the refusal
##   case.
## * `runquota config set` writes the keys through the same reader, and
##   refuses what it refuses before anything is written.
##
## NO MOCKS: the daemon's own reader over real text, the shipped CLI, and a
## real `runquotad` on a private socket in a scratch directory
## (`tests/support/private_daemon_fixture`), which gives every declared class
## an owner-only socket.

import std/[os, strutils, tables, unittest]

import runquota_daemon/host_config

const Head = "schema = \"runquota.host-config.v1\"\n"

proc refusal(text: string; platform = currentHostConfigPlatform()): string =
  ## The reader's refusal of `text` (as file `host.toml`), or "".
  try:
    discard parseHostConfig(Head & text, "host.toml", platform)
    ""
  except HostConfigError as error:
    error.msg

suite "class_socket_keys":
  test "class_socket_keys_read_and_refused: the reader":
    # The defaults: owner-only, the daemon's user and group.
    let plain = parseHostConfig(Head & "[reservation.ci]\n", "host.toml",
      hcpPosix).reservations["ci"]
    check plain.socketMode == 0o600
    check plain.socketOwnerUid == -1
    check plain.socketGroupGid == -1
    # Every key, on Linux and macOS. `root` and gid 0 exist on every POSIX
    # host; a decimal id is taken as written. `root` is resolved by the
    # REAL HOST's user database (`resolveAccountId`), not simulated for
    # `hcpPosix`, so this positive lookup has no Windows form: there is no
    # `root` account to resolve there, whatever platform is requested.
    when defined(posix):
      let set = parseHostConfig(Head & "[reservation.ci]\n" &
        "socket-owner = \"root\"\nsocket-group = \"0\"\n" &
        "socket-mode = \"0660\"\n", "host.toml", hcpPosix).reservations["ci"]
      check set.socketOwner == "root"
      check set.socketOwnerUid == 0
      check set.socketGroupGid == 0
      check set.socketMode == 0o660
    # The largest id chown(2) can apply is accepted.
    check parseHostConfig(Head & "[reservation.ci]\n" &
      "socket-group = \"4294967294\"\n", "host.toml",
      hcpPosix).reservations["ci"].socketGroupGid == 4294967294'i64
    for mode, bits in {"0600": 0o600, "0660": 0o660, "0666": 0o666}.toTable:
      check parseHostConfig(Head & "[reservation.ci]\nsocket-mode = \"" &
        mode & "\"\n", "host.toml", hcpPosix).reservations["ci"].socketMode ==
        bits
    # The Windows keys, read for Windows.
    let windows = parseHostConfig(Head & "[reservation.ci]\n" &
      "allowed-users = [\"S-1-5-21-1-2-3-1001\"]\n" &
      "allowed-groups = [\"CI Runners\", \"Builders\"]\n", "host.toml",
      hcpWindows).reservations["ci"]
    check windows.allowedUsers == @["S-1-5-21-1-2-3-1001"]
    check windows.allowedGroups == @["CI Runners", "Builders"]
    # Refusals, each naming the file and the line.
    for (text, line, needle) in [
        ("[reservation.ci]\nsocket-mode = \"0644\"\n", 3, "socket-mode"),
        ("[reservation.ci]\nsocket-mode = \"0700\"\n", 3, "socket-mode"),
        ("[reservation.ci]\nsocket-mode = \"660\"\n", 3, "socket-mode"),
        ("[reservation.ci]\nsocket-mode = 0660\n", 3, ""),
        ("[reservation.ci]\nsocket-owner = \"rq-no-such-user-x\"\n", 3,
          "names no user"),
        ("[reservation.ci]\nsocket-group = \"rq-no-such-group-x\"\n", 3,
          "names no group"),
        ("[reservation.ci]\nsocket-owner = \"4294967295\"\n", 3,
          "out of range"),
        ("[reservation.ci]\nsocket-group = \"99999999999999999999\"\n", 3,
          "out of range"),
        ("[reservation.ci]\ncpu-milli = 1\nallowed-users = [\"alice\"]\n", 4,
          "Windows key"),
        ("[reservation.ci]\nallowed-groups = [\"ci\"]\n", 3, "Windows key")]:
      let message = refusal(text, hcpPosix)
      checkpoint text & " -> " & message
      check ("host.toml:" & $line & ":") in message
      check needle in message
    for (text, line) in [
        ("[reservation.ci]\nsocket-mode = \"0660\"\n", 3),
        ("[reservation.ci]\nsocket-group = \"ci\"\n", 3),
        ("[reservation.ci]\nsocket-owner = \"runquota\"\n", 3)]:
      let message = refusal(text, hcpWindows)
      checkpoint text & " (read for Windows) -> " & message
      check ("host.toml:" & $line & ":") in message
      check "Linux and macOS key" in message

  # `editHostConfig` has no platform parameter: it always reads and writes
  # for `currentHostConfigPlatform()`, the REAL host. Every key this test
  # sets (`socket-mode`, `socket-group`, `socket-owner`) is a Linux/macOS
  # key, so on a real Windows host every `editHostConfig` call below would
  # itself refuse the key it means to set, before the behaviour under test
  # (refuse-before-write) ever runs. There is no Windows form of this case;
  # the equivalent for Windows keys is the `hcpWindows` coverage above.
  when defined(posix):
    test "class_socket_keys_read_and_refused: runquota config set":
      let root = getTempDir() / "rq-class-keys-" & $getCurrentProcessId()
      createDir(root)
      defer: removeDir(root)
      let path = root / "runquotad.toml"
      var changed = false
      writeFile(path, editHostConfig(path, "reservation.ci.socket-mode",
        "0660", false, changed))
      check changed
      writeFile(path, editHostConfig(path, "reservation.ci.socket-group", "0",
        false, changed))
      writeFile(path, editHostConfig(path, "reservation.ci.socket-owner",
        "root", false, changed))
      let text = readFile(path)
      check "socket-mode = \"0660\"" in text
      check "socket-group = \"0\"" in text
      check "socket-owner = \"root\"" in text
      let read = parseHostConfig(text, path).reservations["ci"]
      check read.socketMode == 0o660
      check read.socketGroupGid == 0
      # `unset` removes one line.
      writeFile(path, editHostConfig(path, "reservation.ci.socket-owner", "",
        true, changed))
      check changed
      check "socket-owner" notin readFile(path)
      # Refused before anything is written: a bad mode, an unknown group, the
      # other platform's key (this host is Linux or macOS), a quote.
      let before = readFile(path)
      for (key, value) in [("reservation.ci.socket-mode", "0644"),
                           ("reservation.ci.socket-group", "rq-no-such-group-x"),
                           ("reservation.ci.allowed-groups", "CI Runners"),
                           ("reservation.ci.socket-owner", "a\"b"),
                           ("reservation.c.i.socket-mode", "0660")]:
        var refused = ""
        try:
          discard editHostConfig(path, key, value, false, changed)
        except HostConfigError as error:
          refused = error.msg
        checkpoint key & " " & value & " -> " & refused
        check refused.len > 0
      check readFile(path) == before

when defined(posix):
  import std/osproc

  import daemon_binary
  import private_daemon_fixture

  suite "class_socket_keys_daemon":
    test "class_socket_keys_read_and_refused: start and reload":
      # AT START: the daemon does not start (exit 2) and names the line.
      for (body, needle) in [
          ("[reservation.ci]\nsocket-mode = \"0644\"\n", "socket-mode"),
          ("[reservation.ci]\nsocket-group = \"rq-no-such-group-x\"\n",
            "names no group"),
          ("[reservation.ci]\nallowed-users = [\"alice\"]\n", "Windows key")]:
        let root = scratchDir("clskeystart")
        defer: removeDir(root)
        let socket = root / "rq.sock"
        writeFile(root / "host.toml", Head & body)
        let daemon = startProcess(daemonPath(), env = privateEnv(socket),
          args = daemonArgs(root, socket, @["--cpu-milli", "4000"]),
          options = {poStdErrToStdOut})
        let code = daemon.exitWithin(30_000)
        let text = daemon.output()
        daemon.close()
        checkpoint body & " -> " & text
        check code == 2
        check (root / "host.toml") & ":3:" in text
        check needle in text
        check not fileExists(socket) and not isSocket(socket)
      # ON RELOAD: refused, and the sockets and reservations in force stay.
      let root = scratchDir("clskeyreload")
      let socket = root / "rq.sock"
      let env = privateEnv(socket)
      let good = "[reservation.ci]\ncpu-milli = 1000\nsocket-mode = \"0660\"\n"
      writeFile(root / "host.toml", Head & good)
      var daemon = launchOwned(root, socket, env,
        daemonArgs(root, socket, @["--cpu-milli", "4000"]),
        what = "the private daemon")
      defer:
        stopOwned(daemon)
        removeDir(root)
      let classSocket = root / "class-ci.sock"
      check isSocket(classSocket)
      for (body, needle) in [
          ("[reservation.ci]\ncpu-milli = 2000\nsocket-mode = \"0644\"\n",
            "socket-mode"),
          ("[reservation.ci]\ncpu-milli = 2000\n[reservation.gpu]\n" &
            "socket-group = \"rq-no-such-group-x\"\n", "names no group"),
          ("[reservation.ci]\ncpu-milli = 2000\nallowed-groups = [\"x\"]\n",
            "Windows key")]:
        writeFile(root / "host.toml", Head & body)
        let (code, output) = cli(env, ["config", "reload"])
        checkpoint body & " -> " & output
        check code != 0
        check needle in output
        check "unchanged" in output
        # The class socket and the reservation in force are the old ones.
        check isSocket(classSocket)
        check not isSocket(root / "class-gpu.sock")
        let (statusCode, status) = cli(env, ["status", "--json"])
        check statusCode == 0
        check "\"reservation\":{\"cpu_milli\":1000" in status
