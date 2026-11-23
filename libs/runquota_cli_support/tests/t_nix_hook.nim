## The pieces of `runquota nix-build-hook` that do not need a nix-daemon:
## the worker's wire format, the settings it reads, the lease width, the
## derivation's output locks, `/proc/locks`, and finding the requester of a
## connection. The daemon end to end is
## `tests/integration/t_nix_daemon_builds_within_budget`.
##
## NO MOCKS. The lock and requester cases use real processes: a real
## `flock(1)` holding a real lock, and a real client process (this binary,
## re-executed) connected to a real listening socket that this process
## accepts, exactly the shape of a nix-daemon worker and its client.
##
## The privilege drop is tested through `CredentialOps`, the injectable
## layer of its four system calls and its status read: a real drop needs
## root, which a test must not take. THE ONE FAKE, JUSTIFIED: the fake ops
## record the order of the calls and fail on demand, which no unprivileged
## process can make the kernel do; `credentialProblem`, the check that
## runs on the real `/proc/self/status`, is also tested on this process's
## own real status.
##
## Mutations that fail a case here: reading `cores` from the wrong setting or
## treating `cores = 0` as one CPU, or not capping it at the host (`width`);
## dropping the `.lock` suffix or the `<drv>.<output>` form (`lock paths`);
## counting a blocked waiter's `->` line as a holder (`proc locks`); taking
## the session group from this process's environment instead of the
## client's (`requester`); keeping a setting other than the four, or
## allocating an over-long string instead of skipping it (`wire format`);
## passing a holder any variable of the hook's environment but the
## endpoint's (`holder environment`); changing the gid after the uid, not
## clearing the supplementary groups, carrying on after a failed step, or
## not checking the result (`privilege drop`).
##
## WITHOUT POSIX (Windows) the hook is not built: what is tested there is
## that the verb refuses, naming the platform, with a non-zero exit; the
## cases above are reported skipped.

when not defined(posix):
  import std/[strutils, unittest]

  import runquota_cli_support/nix_hook

  suite "platform":
    test "the verb refuses with a non-zero exit, naming the platform":
      check runNixBuildHook(@["1"], "test") != 0
      check runNixBuildHook(@[HoldFlag], "test") != 0
      when defined(windows):
        check "not supported on Windows" in unsupportedPlatformMessage()

  suite "the hook on POSIX":
    test "wire format, widths, locks, requester, privilege drop":
      skip()
else:
  import std/[os, osproc, posix, streams, strtabs, strutils, tables, tempfiles,
    unittest]

  import runquota_cli_support/nix_hook

  const
    ClientRole = "RUNQUOTA_TEST_NIX_HOOK_CLIENT"
    LockEx = cint(2)

  proc flockCall(fd: cint; operation: cint): cint {.
    importc: "flock", header: "<sys/file.h>".}

  proc runClient(path: string) =
    ## The re-executed client: connect, then wait to be killed.
    var address: Sockaddr_un
    address.sun_family = TSa_Family(AF_UNIX)
    for i, c in path: address.sun_path[i] = c
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if connect(fd, cast[ptr SockAddr](addr address),
        SockLen(sizeof(address))) != 0:
      quit(3)
    sleep(60_000)
    quit(0)

  if getEnv(ClientRole).len > 0:
    runClient(getEnv(ClientRole))

  suite "the worker's wire format":
    test "settings are read and credentials are not kept":
      let wire = wireU64(1) & wireString("access-tokens") &
        wireString("github.com=secret") &
        wireU64(1) & wireString("cores") & wireString("3") &
        wireU64(1) & wireString("max-jobs") & wireString("12") &
        wireU64(1) & wireString("build-poll-interval") & wireString("2") &
        wireU64(1) & wireString("store") & wireString("local?root=/r") &
        wireU64(0) &
        wireString("try") & wireU64(1) & wireString("x86_64-linux") &
        wireString("/nix/store/abc-x.drv") & wireStrings(["kvm", "big"])
      let input = newStringStream(wire)
      let settings = readHookSettings(input)
      check settings.cores == 3
      check settings.maxJobs == 12
      check settings.pollIntervalSecs == 2
      check settings.store == "local?root=/r"
      # Nothing but the four is kept: the object has no other field, and its
      # rendering carries no part of the credential.
      check "secret" notin $settings
      var request: TryRequest
      check readTry(input, request)
      check request.amWilling
      check request.drvPath == "/nix/store/abc-x.drv"
      check not readTry(input, request)

    test "strings are padded to eight bytes":
      check wireString("abc").len == 8 + 8
      check wireString("abcdefgh").len == 8 + 8
      check wireString("").len == 8
      var value = ""
      check readWireString(newStringStream(wireString("abcdefghi")), value, 16)
      check value == "abcdefghi"

    test "an over-long string is skipped and the stream stays in step":
      let huge = repeat('x', 3 * 1024 * 1024 + 5)
      let wire = wireU64(1) & wireString(huge) & wireString("v") &
        wireU64(1) & wireString("access-tokens") & wireString(huge) &
        wireU64(1) & wireString("cores") & wireString(huge) &
        wireU64(1) & wireString("max-jobs") & wireString("3") &
        wireU64(0) &
        wireString("try") & wireU64(0) & wireString(huge) &
        wireString("/nix/store/" & huge & ".drv") &
        wireStrings([huge, "kvm"]) &
        wireString("try") & wireU64(1) & wireString("s") &
        wireString("/nix/store/z-y.drv") & wireStrings([])
      let input = newStringStream(wire)
      let settings = readHookSettings(input)
      check settings.cores == 0      # over its bound: the default
      check settings.maxJobs == 3    # and the next setting is still read
      var request: TryRequest
      check readTry(input, request)
      check request.drvPath == ""    # over its bound: declined, not allocated
      check not request.amWilling
      check readTry(input, request)
      check request.drvPath == "/nix/store/z-y.drv"
      check request.amWilling

    test "out-of-range numbers are clamped, not overflowed":
      let wire = wireU64(1) & wireString("cores") &
        wireString("999999999999999999") &
        wireU64(1) & wireString("max-jobs") & wireString("-4") &
        wireU64(1) & wireString("build-poll-interval") &
        wireString("99999999999999999999999") & wireU64(0)
      let settings = readHookSettings(newStringStream(wire))
      check settings.cores == 1 shl 20
      check settings.maxJobs == 0
      check settings.pollIntervalSecs == 5   # does not parse: the default

    test "a feature list that cannot be followed is an error, not a loop":
      let wire = wireString("try") & wireU64(1) & wireString("s") &
        wireString("/nix/store/a.drv") & wireU64(1'u64 shl 40)
      var request: TryRequest
      expect ValueError:
        discard readTry(newStringStream(wire), request)

    test "a truncated preamble is an error, not a hang":
      expect EOFError:
        discard readHookSettings(newStringStream(wireU64(1) & wireString("x")))

  suite "width":
    test "the lease is as wide as NIX_BUILD_CORES":
      check leaseCpusFor(2, 32) == 2
      check leaseCpusFor(0, 32) == 32   # cores = 0: every CPU
      check leaseCpusFor(0, 0) == 1
      check leaseCpusFor(64, 32) == 32  # never wider than the host

  suite "lock paths":
    const drvText = "Derive([(\"dev\",\"/nix/store/aaa-x-dev\",\"\",\"\")," &
      "(\"out\",\"/nix/store/bbb-x\",\"\",\"\")],[(\"/nix/store/c.drv\"," &
      "[\"out\"])],[],\"x86_64-linux\",\"/bin/sh\",[\"-c\",\"echo \\\"hi\\\"\"]," &
      "[(\"out\",\"/nix/store/bbb-x\")])"

    test "outputs are parsed from the ATerm":
      let outputs = parseDrvOutputs(drvText)
      check outputs.len == 2
      check outputs[0].name == "dev" and outputs[0].path == "/nix/store/aaa-x-dev"
      check outputs[1].name == "out" and outputs[1].path == "/nix/store/bbb-x"

    test "an output with no known path locks <drv>.<output>.lock":
      let outputs = parseDrvOutputs(
        "Derive([(\"out\",\"\",\"r:sha256\",\"\")],[],[],\"s\",\"b\",[],[])")
      check outputLockPaths("/nix/store/d-x.drv", outputs, "") ==
        @["/nix/store/d-x.drv.out.lock"]

    test "known outputs lock <real path>.lock":
      let outputs = parseDrvOutputs(drvText)
      check outputLockPaths("/nix/store/d-x.drv", outputs, "daemon") ==
        @["/nix/store/aaa-x-dev.lock", "/nix/store/bbb-x.lock"]
      check outputLockPaths("/nix/store/d-x.drv", outputs,
        "local?root=/chroot") ==
        @["/chroot/nix/store/aaa-x-dev.lock", "/chroot/nix/store/bbb-x.lock"]
      check outputLockPaths("/nix/store/d-x.drv", outputs,
        "local?real=/elsewhere%2Fstore") ==
        @["/elsewhere/store/aaa-x-dev.lock", "/elsewhere/store/bbb-x.lock"]

    test "the versioned form and garbage":
      check parseDrvOutputs("DrvWithVersion(\"xp-dyn-drv\",[(\"out\"," &
        "\"/nix/store/e-y\",\"\",\"\")],[],[],\"s\",\"b\",[],[])")[0].path ==
        "/nix/store/e-y"
      expect ValueError:
        discard parseDrvOutputs("not a derivation")

  suite "proc locks":
    test "a blocked waiter is not a holder":
      let locks = parseProcLocks(
        "1: FLOCK  ADVISORY  WRITE 4242 00:2c:859165123 0 EOF\n" &
        "1: -> FLOCK  ADVISORY  WRITE 4343 00:2c:859165123 0 EOF\n" &
        "2: POSIX  ADVISORY  READ 77 fd:01:12 128 128\n")
      check locks.len == 2
      check locks[0].pid == 4242 and locks[0].inode == 859165123'u64
      check locks[0].major == 0 and locks[0].minor == 0x2c
      check locks[1].major == 0xfd and locks[1].minor == 1

    test "a real flock is seen while it is held and not after":
      let dir = getTempDir() / "rqnixlk" & $getCurrentProcessId()
      createDir(dir)
      defer: removeDir(dir)
      let path = dir / "out.lock"
      writeFile(path, "")
      # The holder is a child forked here that takes `flock(2)` itself, so
      # the pid in /proc/locks is the process this test kills (a `flock(1)`
      # command forks its command, which would keep the lock alive).
      let holder = fork()
      if holder == 0:
        let fd = posix.open(path.cstring, O_RDWR)
        if fd < 0 or flockCall(fd, LockEx) != 0: exitnow(1)
        discard posix.sleep(30)
        exitnow(0)
      require holder > 0
      var seen = false
      for _ in 0 ..< 100:
        if anyLockHeldBy([path], int(holder)): seen = true; break
        sleep(50)
      check seen
      check not anyLockHeldBy([path], int(holder) + 1_000_000)
      discard kill(holder, SIGKILL)
      var status: cint
      discard waitpid(holder, status, 0)
      check not anyLockHeldBy([path], int(holder))
      check not anyLockHeldBy([dir / "missing.lock"], int(holder))

  suite "requester":
    test "environment and ids":
      let env = parseEnviron("A=1\0RUNQUOTA_SESSION=host:w1\0EMPTY=\0")
      check env["RUNQUOTA_SESSION"] == "host:w1"
      check env["EMPTY"] == ""
      var uid, gid = -1
      check parseStatusIds("Name:\tx\nUid:\t1000\t1000\t1000\t1000\n" &
        "Gid:\t100\t100\t100\t100\n", uid, gid)
      check uid == 1000 and gid == 100
      check socketInode("socket:[123]") == 123'u64
      check socketInode("pipe:[123]") == 0'u64

    when defined(linux):
      test "the client of an accepted connection, and its group":
        # This process plays the worker: it listens on a named socket and
        # accepts one client, a re-executed copy of this binary whose
        # environment names a group this process's own environment does not.
        putEnv("RUNQUOTA_SESSION", "the-worker-own-group")
        let dir = getTempDir() / "rqnixrq" & $getCurrentProcessId()
        createDir(dir)
        defer: removeDir(dir)
        let path = dir / "d.sock"
        var address: Sockaddr_un
        address.sun_family = TSa_Family(AF_UNIX)
        for i, c in path: address.sun_path[i] = c
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        require bindSocket(listener, cast[ptr SockAddr](addr address),
          SockLen(sizeof(address))) == 0
        require listen(listener, 1) == 0
        var env = newStringTable(modeCaseSensitive)
        for key, value in envPairs(): env[key] = value
        env[ClientRole] = path
        env["RUNQUOTA_SESSION"] = "the-client-group"
        env["RUNQUOTA_SESSION_PRIORITY"] = "low"
        var client = startProcess(getAppFilename(), env = env)
        let accepted = accept(listener, nil, nil)
        require cint(accepted) >= 0
        # The listening socket carries the same name but has no peer; it must
        # not count as a second connection.
        let found = findRequester(getCurrentProcessId())
        check found.pid == client.processID
        check found.group == "the-client-group"
        check found.priority == "low"
        check found.uid == int(getuid())
        check found.gid == int(getgid())
        client.terminate()
        discard client.waitForExit()
        client.close()
        discard posix.close(cint(accepted))
        discard posix.close(cint(listener))

  suite "messages":
    test "a structured warning for the client":
      check nixLogLine("x \"y\"") ==
        "@nix {\"action\":\"msg\",\"level\":1,\"msg\":\"x \\\"y\\\"\"}"

  suite "requester session":
    test "an invalid group is dropped with its priority, a valid one kept":
      var kept = Requester(uid: 1, gid: 1)
      kept.sessionFromEnviron("RUNQUOTA_SESSION=h:w1\0" &
        "RUNQUOTA_SESSION_PRIORITY=low\0RUNQUOTA_SESSION_CACHE_TTL=60\0")
      check kept.group == "h:w1"
      check kept.priority == "low" and kept.cacheTtl == "60"
      var dropped = Requester(uid: 1, gid: 1)
      dropped.sessionFromEnviron("RUNQUOTA_SESSION=bad\x01name\0" &
        "RUNQUOTA_SESSION_PRIORITY=low\0")
      check dropped.group == "" and dropped.priority == ""
      check "ignored" in dropped.how
      var long = Requester(uid: 1, gid: 1)
      long.sessionFromEnviron("RUNQUOTA_SESSION=g\0" &
        "RUNQUOTA_SESSION_PRIORITY=" & repeat('p', 4096) & "\0")
      check long.group == "g" and long.priority == ""

  suite "holder environment":
    test "only the endpoint variables and the requester's session":
      putEnv("RUNQUOTA_SOCKET", "/run/x/d.sock")
      putEnv("RUNQUOTA_ENDPOINT_SCOPE", "private")
      putEnv("GITHUB_TOKEN", "ghp_must_not_pass")
      putEnv("NIX_CONFIG", "access-tokens = github.com=must_not_pass")
      putEnv("RUNQUOTA_PARENT_LEASE", "must-not-pass")
      putEnv("RUNQUOTA_SESSION", "the-daemon-own-group")
      let env = holderEnv(Requester(uid: 1, gid: 1, group: "req-group",
        priority: "high"))
      var keys: seq[string] = @[]
      for key, value in env:
        keys.add(key)
        check "must_not_pass" notin value and "must-not-pass" notin value
      for key in keys:
        check key in HolderEndpointVars or key in SessionVars
      check env["RUNQUOTA_SOCKET"] == "/run/x/d.sock"
      check env["RUNQUOTA_ENDPOINT_SCOPE"] == "private"
      check env["RUNQUOTA_SESSION"] == "req-group"
      check env["RUNQUOTA_SESSION_PRIORITY"] == "high"
      # No group: the requester's interactive group, never the daemon's.
      check not holderEnv(Requester(uid: 1, gid: 1)).hasKey("RUNQUOTA_SESSION")
      for key in ["GITHUB_TOKEN", "NIX_CONFIG", "RUNQUOTA_PARENT_LEASE",
                  "RUNQUOTA_SESSION", "RUNQUOTA_ENDPOINT_SCOPE"]:
        delEnv(key)

  suite "privilege drop":
    const goodStatus = "Name:\tx\nUid:\t1000\t1000\t1000\t1000\n" &
      "Gid:\t100\t100\t100\t100\nGroups:\t\nCapPrm:\t0000000000000000\n" &
      "CapEff:\t0000000000000000\nCapAmb:\t0000000000000000\n"

    proc fakeOps(calls: ref seq[string]; root = true; failAt = "";
                 regain = false; status = goodStatus): CredentialOps =
      ## Records each call; `failAt` names the one that fails.
      CredentialOps(
        euid: proc (): int = (if root: 0 else: 1000),
        clearGroups: proc (): cint =
          calls[].add("setgroups")
          cint(if failAt == "setgroups": -1 else: 0),
        setGid: proc (gid: int): cint =
          calls[].add("setgid " & $gid)
          cint(if failAt == "setgid": -1 else: 0),
        setUid: proc (uid: int): cint =
          calls[].add("setuid " & $uid)
          cint(if failAt == "setuid" or (uid == 0 and not regain): -1 else: 0),
        status: proc (): string = status)

    test "groups, then gid, then uid, then the checks":
      let calls = new(seq[string])
      check dropPrivilegesWith(fakeOps(calls), 1000, 100) ==
        "as uid 1000 gid 100"
      check calls[] == @["setgroups", "setgid 100", "setuid 1000", "setuid 0"]

    test "a failed step stops the drop before the next one":
      for step in ["setgroups", "setgid", "setuid"]:
        let calls = new(seq[string])
        expect PrivilegeDropError:
          discard dropPrivilegesWith(fakeOps(calls, failAt = step), 1000, 100)
        check calls[][^1].startsWith(step)

    test "a drop that leaves anything behind is refused":
      let calls = new(seq[string])
      expect PrivilegeDropError:
        discard dropPrivilegesWith(fakeOps(calls, regain = true), 1000, 100)
      for bad in [goodStatus.replace("Groups:\t", "Groups:\t0 10"),
                  goodStatus.replace("Uid:\t1000\t1000\t1000\t1000",
                    "Uid:\t1000\t0\t1000\t1000"),
                  goodStatus.replace("Gid:\t100\t100\t100\t100",
                    "Gid:\t100\t100\t0\t100"),
                  goodStatus.replace("CapEff:\t0000000000000000",
                    "CapEff:\t000001ffffffffff"),
                  goodStatus.replace("CapAmb:\t0000000000000000\n", "")]:
        expect PrivilegeDropError:
          discard dropPrivilegesWith(fakeOps(new(seq[string]), status = bad),
            1000, 100)

    test "an unknown group is refused, never kept":
      let calls = new(seq[string])
      expect PrivilegeDropError:
        discard dropPrivilegesWith(fakeOps(calls), 1000, -1)
      check calls[].len == 0

    test "nothing to drop: not root, root's own client, unknown requester":
      for (root, uid) in [(false, 1000), (true, 0), (true, -1)]:
        let calls = new(seq[string])
        check dropPrivilegesWith(fakeOps(calls, root = root), uid, 100) == ""
        check calls[].len == 0

    test "the check reads this process's real status":
      let own = readFile("/proc/self/status")
      # An unprivileged test process has no capabilities and its own ids.
      let problem = credentialProblem(own, int(getuid()), int(getgid()))
      check problem.len == 0 or problem.startsWith("supplementary groups")
      check credentialProblem(own, int(getuid()) + 1, int(getgid())).len > 0

  suite "holder arguments":
    test "out-of-range values are refused, not converted":
      var options: HoldOptions
      check parseHoldArgs(["--label", "x", "--cpu-milli", "2000"], options)
      check options.cpuMilli == 2000
      check not parseHoldArgs(["--cpu-milli", "99999999999"], options)
      check not parseHoldArgs(["--cpu-milli", "0"], options)
      check not parseHoldArgs(["--cpu-milli"], options)
      check not parseHoldArgs(["--bogus", "1"], options)

  suite "derivation file":
    test "only a bounded regular file is read":
      let dir = createTempDir("rqnixdrv", "")
      defer: removeDir(dir)
      writeFile(dir / "a.drv", "Derive([])")
      check readRegularFile(dir / "a.drv", 1024) == "Derive([])"
      expect IOError:
        discard readRegularFile(dir / "a.drv", 4)
      # A FIFO would block a plain open; it is refused at once.
      check mkfifo((dir / "f.drv").cstring, 0o600) == 0
      expect IOError:
        discard readRegularFile(dir / "f.drv", 1024)
      expect IOError:
        discard readRegularFile(dir / "missing.drv", 1024)
