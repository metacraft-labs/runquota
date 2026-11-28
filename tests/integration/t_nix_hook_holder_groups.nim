## The nix build hook's holder drop, FOR REAL, as root in a user namespace:
## the group list a dropped holder gets, and whether it can then reach a
## host endpoint that its group gates (Build-Engine § Nix daemon builds
## under leases, "The endpoint's group").
##
## WHAT IS UNDER TEST. A root hook's holder drops to the requester. The
## host endpoint's directory is mode 0750 and owned by a group (`runquota`
## on the fleet), so a holder keeps that group exactly when its requester
## is a member of it, and nothing else:
##
## * `a_member_keeps_the_endpoint_group_and_connects` -- for the invoking
##   user's account, `endpointGroupFor` names the group that owns the
##   endpoint's directory (one of the account's own supplementary groups),
##   the real drop (`setgroups`, `setgid`, `setuid`) leaves exactly that
##   group in `/proc/self/status`, and the dropped process registers a
##   session with a `runquotad` behind that 0750 directory. Mutation that
##   fails it: a drop that leaves the group out (the connect is refused).
## * `the_root_hook_passes_the_group_to_its_holder` -- the shipped hook, as
##   namespace root with this process as its worker and a client process
##   of the member's uid on the connection: the hook finds the requester,
##   computes the group from its own endpoint and policy, passes
##   `--endpoint-group`, and its holder keeps exactly that group and is
##   granted the lease. Mutation that fails it: a hook that does not pass
##   the group (its holder cannot connect; the build is declined
##   unadmitted, no lease).
## * `a_non_member_keeps_no_group_and_cannot_connect` -- for `nobody`,
##   not a member, no group is kept (`Groups` empty) and the connect is
##   refused. Mutation that fails it: keeping the group for a non-member.
##
## HOW IT IS ROOT. The test re-executes itself under `unshare --map-auto
## --map-root-user` (RQE-M14's review ran the drop the same way): root of
## a user namespace whose ids 1..65535 map to the invoking user's
## subordinate ranges, with `setgroups` allowed. Account names and group
## memberships come from the host's `/etc/passwd` and `/etc/group`, read
## inside the namespace by the same numbers. The scratch directory is made
## in `/tmp`, not under TMPDIR: the dropped ids are other uids, and a
## private TMPDIR (`nix develop` makes a 0700 one) would refuse them before
## the endpoint could. Nothing outside the scratch
## directory is touched, and nothing is signalled but the daemon this test
## started. NO MOCKS: the drop, the lookups, the daemon and the connect are
## the real ones.
##
## PREREQUISITES, which fail the test rather than skip it: `unshare` with
## `--map-auto` (util-linux >= 2.38, and subordinate id ranges for this
## user); an account `nobody`; a supplementary group of the invoking
## account below 65536 that is not its primary group.
##
## Linux only: darwin has no user namespaces; the same drop was run there
## as real root with `sudo` (see the RQE-M14 notes).

when defined(linux):
  import std/[os, osproc, posix, streams, strtabs, strutils, tempfiles,
    unittest]

  import std/json

  import daemon_binary
  import private_daemon_fixture
  import runquota_client
  import runquota_cli_support/nix_hook

  proc flockCall(fd: cint; operation: cint): cint {.
    importc: "flock", header: "<sys/file.h>".}
  proc prctlDumpable(option: cint; arg2: culong): cint {.
    varargs, importc: "prctl", header: "<sys/prctl.h>".}

  const
    RoleVar = "RUNQUOTA_TEST_HOLDER_GROUPS_ROLE"
    AccountVar = "RUNQUOTA_TEST_HOLDER_GROUPS_ACCOUNT"

  proc accountGroups(name: string; gid: int): seq[int] =
    var groups: seq[int] = @[]
    if systemGroupOps().groupsOf(name, gid, groups): groups else: @[]

  proc dropAndConnect(uid, gid, endpointGroup: int; root: string):
      tuple[status: string, dropped: string, connected: string,
            reach: string] =
    ## In a forked child: the real drop, then a session. The child writes
    ## its findings to a pipe; the parent (still root) reads them.
    var channel: array[2, cint]
    doAssert pipe(channel) == 0
    let child = fork()
    if child == 0:
      discard posix.close(channel[0])
      var report = ""
      try:
        report.add("dropped=" & dropPrivilegesWith(systemCredentialOps(),
          uid, gid, endpointGroup) & "\n")
      except CatchableError as e:
        report.add("dropped=REFUSED " & e.msg & "\n")
      for line in readFile("/proc/self/status").splitLines():
        if line.startsWith("Groups:"):
          report.add("groups=" & line["Groups:".len .. ^1].strip() & "\n")
      try:
        # The control for the refusal: the dropped process can reach the
        # scratch directory itself, so a refused connect is the endpoint
        # directory's group at work and not an unreachable ancestor.
        report.add("reach=" & (if access(root.cstring, X_OK) == 0: "ok"
                               else: "denied " & $strerror(errno)) & "\n")
        var client = connectDefault()
        var session = client.registerSession("holder-groups", "test")
        session.closeSession()
        client.close()
        report.add("connected=yes\n")
      except CatchableError as e:
        report.add("connected=no " & e.msg.replace('\n', ' ') & "\n")
      discard posix.write(channel[1], report.cstring, report.len)
      exitnow(0)
    discard posix.close(channel[1])
    var text = ""
    var chunk = newString(4096)
    while true:
      let n = posix.read(channel[0], addr chunk[0], chunk.len)
      if n <= 0: break
      text.add(chunk[0 ..< n])
    discard posix.close(channel[0])
    var status: cint
    discard waitpid(child, status, 0)
    for line in text.splitLines():
      if line.startsWith("groups="): result.status = line[7 .. ^1]
      elif line.startsWith("dropped="): result.dropped = line[8 .. ^1]
      elif line.startsWith("connected="): result.connected = line[10 .. ^1]
      elif line.startsWith("reach="): result.reach = line[6 .. ^1]

  proc hookCase(root: string; env: StringTableRef; uid, gid, gate: int) =
    ## The shipped hook, run as root of the namespace with this process as
    ## its worker: a client process of the requester's uid connects to a
    ## socket this process accepts (the shape of a nix-daemon connection),
    ## the hook finds the requester, computes the endpoint's group from its
    ## own endpoint (the environment it was started with) and passes it to
    ## its holder, which drops and takes the lease from the runquotad
    ## behind the 0750 directory. What is checked is the holder's own
    ## `Groups` and the lease the daemon granted.
    let listenPath = root / "daemon.sock"
    var address: Sockaddr_un
    address.sun_family = TSa_Family(AF_UNIX)
    for i, c in listenPath: address.sun_path[i] = c
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    doAssert bindSocket(listener, cast[ptr SockAddr](addr address),
      SockLen(sizeof(address))) == 0
    doAssert listen(listener, 1) == 0
    # The client runs as the requester: it needs write access to connect.
    doAssert chmod(listenPath.cstring, 0o666) == 0
    let client = fork()
    if client == 0:
      # The requester's client: its own uid, findable in /proc.
      discard setgid(Gid(gid))
      discard setuid(Uid(uid))
      discard prctlDumpable(cint(4), culong(1))
      let fd = socket(AF_UNIX, SOCK_STREAM, 0)
      if connect(fd, cast[ptr SockAddr](addr address),
          SockLen(sizeof(address))) != 0:
        exitnow(3)
      discard posix.sleep(60)
      exitnow(0)
    # Bounded: a client that could not connect must not hang the case.
    var ready = [TPollfd(fd: cint(listener), events: POLLIN)]
    if poll(addr ready[0], Tnfds(1), 10_000) <= 0:
      echo "case hook answer=NO-CLIENT groups=[] granted=none"
      discard kill(client, SIGKILL)
      return
    let accepted = accept(listener, nil, nil)
    doAssert cint(accepted) >= 0
    # A derivation in a `real=` store and its output lock, held by this
    # process as the worker would.
    let store = root / "store"
    createDir(store)
    doAssert chmod(store.cstring, 0o755) == 0
    let drv = "/nix/store/" & repeat('d', 32) & "-g.drv"
    let output = "/nix/store/" & repeat('o', 32) & "-g"
    writeFile(store / extractFilename(drv),
      "Derive([(\"out\",\"" & output & "\",\"\",\"\")],[],[]," &
      "\"x86_64-linux\",\"/bin/sh\",[],[])")
    let lock = store / extractFilename(output) & ".lock"
    writeFile(lock, "")
    doAssert chmod(lock.cstring, 0o644) == 0
    let lockFd = posix.open(lock.cstring, O_RDWR or O_CLOEXEC)
    doAssert lockFd >= 0 and flockCall(lockFd, cint(2)) == 0
    var hook = startProcess(cliPath(), args = [HookVerb, "0"], env = env,
      options = {poStdErrToStdOut})
    let preamble = wireU64(1) & wireString("cores") & wireString("1") &
      wireU64(1) & wireString("max-jobs") & wireString("2") &
      wireU64(1) & wireString("build-poll-interval") & wireString("1") &
      wireU64(1) & wireString("store") & wireString("local?real=" & store) &
      wireU64(0)
    hook.inputStream.write(preamble)
    var answer = ""
    var transcript = ""
    var holderGroups = "?"
    var granted = "?"
    for _ in 0 ..< 10:
      hook.inputStream.write(wireString("try") & wireU64(1) &
        wireString("x86_64-linux") & wireString(drv) & wireStrings([]))
      hook.inputStream.flush()
      answer = ""
      var line = ""
      # A hook that died ends the stream: readLine answers false, and the
      # case reports what it said instead of waiting forever.
      while hook.outputStream.readLine(line):
        transcript.add(line & " | ")
        if line.startsWith("# "):
          answer = line[2 .. ^1]
          break
      if answer != "postpone": break
      sleep(300)
    if answer == "decline":
      for kind, dir in walkDir("/proc"):
        let name = extractFilename(dir)
        if name.len == 0 or not name[0].isDigit: continue
        try:
          if "--hold" notin readFile(dir / "cmdline"): continue
          for line in readFile(dir / "status").splitLines():
            if line.startsWith("Groups:"):
              holderGroups = line["Groups:".len .. ^1].strip()
        except CatchableError:
          discard
      let (code, text) = cli(env)
      granted = if code == 0:
          $parseJson(text)["capacity"]["host"]["cpu_granted_milli"].getInt()
        else: "status failed: " & text.replace('\n', ' ')
    echo "case hook answer=", answer, " groups=[", holderGroups,
      "] granted=", granted, " transcript=", transcript
    discard flockCall(lockFd, cint(8))
    discard posix.close(lockFd)
    try:
      hook.inputStream.close()
      discard hook.waitForExit(5000)
      hook.close()
    except CatchableError:
      discard
    discard kill(client, SIGKILL)
    var status: cint
    discard waitpid(client, status, 0)
    discard posix.close(cint(accepted))
    discard posix.close(cint(listener))

  proc insideNamespace() =
    ## Root of the user namespace. Prints one `case <name> <verdict>` line
    ## per case for the outer test to check.
    let account = getEnv(AccountVar)
    let entry = getpwnam(account.cstring)
    doAssert entry != nil, "no account " & account
    let uid = int(entry.pw_uid)
    let gid = int(entry.pw_gid)
    var gate = -1
    for group in accountGroups(account, gid):
      if group != gid and group > 0 and group < 65536: gate = group
    doAssert gate > 0, account & " has no usable supplementary group"
    let nobody = getpwnam("nobody")
    doAssert nobody != nil, "no account nobody"
    doAssert gate notin accountGroups("nobody", int(nobody.pw_gid)),
      "nobody is a member of " & $gate
    let root = getEnv("RUNQUOTA_TEST_HOLDER_GROUPS_DIR")
    doAssert chmod(root.cstring, 0o755) == 0
    let endpointDir = root / "ep"
    createDir(endpointDir)
    doAssert chown(endpointDir.cstring, 0, Gid(gate)) == 0
    doAssert chmod(endpointDir.cstring, 0o750) == 0
    let socket = endpointDir / "rq.sock"
    var env = cleanEnvironment()
    env["RUNQUOTA_ENDPOINT_SCOPE"] = "host"
    env["RUNQUOTA_SOCKET"] = socket
    env["RUNQUOTA_ENDPOINT_GROUP"] = $gate
    env["RUNQUOTA_ENDPOINT_OWNER_UID"] = "0"
    for key, value in env: putEnv(key, value)
    var daemon = startProcess(daemonPath(), env = env,
      args = daemonArgs(root, socket), options = {poStdErrToStdOut})
    defer: stopOwned(daemon)
    if not awaitSocket(daemon, socket):
      echo "case daemon FAILED ", startupContext(daemon, "did not bind")
      return
    # Member.
    let member = endpointGroupFor(systemGroupOps(), socket, false, uid, gid,
      gate)
    let m = dropAndConnect(uid, gid, member.group, root)
    echo "case member group=", member.group, " gate=", gate, " diag=",
      member.diagnostic, " reach=[", m.reach, "] status=[", m.status,
      "] dropped=", m.dropped,
      " connected=", m.connected
    # Non-member.
    let nuid = int(nobody.pw_uid)
    let ngid = int(nobody.pw_gid)
    let other = endpointGroupFor(systemGroupOps(), socket, false, nuid, ngid,
      gate)
    let o = dropAndConnect(nuid, ngid, other.group, root)
    echo "case nonmember group=", other.group, " diag=", other.diagnostic,
      " reach=[", o.reach, "] status=[", o.status, "] dropped=", o.dropped,
      " connected=",
      o.connected
    hookCase(root, env, uid, gid, gate)

  if getEnv(RoleVar) == "inside":
    insideNamespace()
    quit(0)

  proc field(line, key: string): string =
    let at = line.find(key & "=")
    if at < 0: return ""
    let rest = line[at + key.len + 1 .. ^1]
    if rest.startsWith("["): rest[1 ..< rest.find(']')]
    else: rest.split(' ')[0]

  suite "the holder's groups, as root in a user namespace":
    let unshare = findExe("unshare")
    prerequisite unshare.len > 0, "unshare is not on PATH (a prerequisite)"
    discard cliPath()      # refuse a stale build before anything starts
    # The namespace itself is a prerequisite, said as such: `newuidmap`
    # refuses a process whose real gid is not its account's primary group
    # (a shell under `sg <group>` or `newgrp`), and a host without
    # subordinate ids refuses everyone.
    let probe = execCmdEx(quoteShell(unshare) &
      " --map-auto --map-root-user true")
    prerequisite probe.exitCode == 0,
      "cannot create a user namespace with mapped ids (a prerequisite; " &
      "run outside sg/newgrp): " & probe.output.strip()
    # THE SCRATCH DIRECTORY MUST BE REACHABLE BY THE DROPPED IDS: they are
    # other uids, and a private TMPDIR (`nix develop` sets a 0700
    # `/tmp/nix-shell.*`) would refuse them on its way to the endpoint,
    # for a reason that has nothing to do with the endpoint's group. So it
    # is made in `/tmp` itself, whatever TMPDIR says, and every ancestor is
    # checked to be searchable by others.
    let root = createTempDir("rqgrp", "", "/tmp")
    var ancestor = root
    while true:
      ancestor = parentDir(ancestor)
      if ancestor.len == 0: break
      var info: Stat
      prerequisite stat(ancestor.cstring, info) == 0 and
        (int(info.st_mode) and 0o001) != 0,
        ancestor & " is not searchable by other users (a prerequisite)"
      if ancestor == "/": break
    defer: removeDir(root)
    var env = newStringTable(modeCaseSensitive)
    for key, value in envPairs(): env[key] = value
    env[RoleVar] = "inside"
    env[AccountVar] = $getpwuid(getuid()).pw_name
    env["RUNQUOTA_TEST_HOLDER_GROUPS_DIR"] = root
    let inner = startProcess(unshare, workingDir = getCurrentDir(), env = env,
      args = ["--map-auto", "--map-root-user", getAppFilename()],
      options = {poStdErrToStdOut})
    let output = inner.outputStream.readAll()
    let code = inner.waitForExit()
    inner.close()
    var memberLine, otherLine = ""
    for line in output.splitLines():
      if line.startsWith("case member "): memberLine = line
      elif line.startsWith("case nonmember "): otherLine = line
    if memberLine.len == 0 or otherLine.len == 0 or code != 0:
      echo output

    test "a_member_keeps_the_endpoint_group_and_connects":
      echo memberLine
      let gate = memberLine.field("gate")
      check gate.len > 0
      check memberLine.field("group") == gate
      check " dropped=as uid " in memberLine
      check memberLine.field("status") == gate
      check memberLine.field("reach") == "ok"
      check memberLine.field("connected") == "yes"

    test "the_root_hook_passes_the_group_to_its_holder":
      # The whole chain: the hook's own endpoint, its policy, the requester
      # lookup, `--endpoint-group`, the holder's drop and its lease.
      var hookLine = ""
      for line in output.splitLines():
        if line.startsWith("case hook "): hookLine = line
      echo hookLine
      check hookLine.field("answer") == "decline"
      check hookLine.field("groups") == memberLine.field("gate")
      check hookLine.field("granted") == "1000"

    test "a_non_member_keeps_no_group_and_cannot_connect":
      echo otherLine
      check otherLine.field("group") == "-1"
      check "not a member" in otherLine
      check " dropped=as uid " in otherLine
      check otherLine.field("status") == ""
      check otherLine.field("reach") == "ok"
      check otherLine.field("connected") == "no"
