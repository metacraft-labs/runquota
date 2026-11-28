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
## * `a_non_member_keeps_no_group_and_cannot_connect` -- for `nobody`,
##   not a member, no group is kept (`Groups` empty) and the connect is
##   refused. Mutation that fails it: keeping the group for a non-member.
##
## HOW IT IS ROOT. The test re-executes itself under `unshare --map-auto
## --map-root-user` (RQE-M14's review ran the drop the same way): root of
## a user namespace whose ids 1..65535 map to the invoking user's
## subordinate ranges, with `setgroups` allowed. Account names and group
## memberships come from the host's `/etc/passwd` and `/etc/group`, read
## inside the namespace by the same numbers. Nothing outside the scratch
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
  import std/[os, osproc, posix, streams, strtabs, strutils, unittest]

  import daemon_binary
  import private_daemon_fixture
  import runquota_client
  import runquota_cli_support/nix_hook

  const
    RoleVar = "RUNQUOTA_TEST_HOLDER_GROUPS_ROLE"
    AccountVar = "RUNQUOTA_TEST_HOLDER_GROUPS_ACCOUNT"

  proc accountGroups(name: string; gid: int): seq[int] =
    var groups: seq[int] = @[]
    if systemGroupOps().groupsOf(name, gid, groups): groups else: @[]

  proc dropAndConnect(uid, gid, endpointGroup: int): tuple[status: string,
      dropped: string, connected: string] =
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
    let member = endpointGroupFor(systemGroupOps(), socket, false, uid, gid)
    let m = dropAndConnect(uid, gid, member.group)
    echo "case member group=", member.group, " gate=", gate, " diag=",
      member.diagnostic, " status=[", m.status, "] dropped=", m.dropped,
      " connected=", m.connected
    # Non-member.
    let nuid = int(nobody.pw_uid)
    let ngid = int(nobody.pw_gid)
    let other = endpointGroupFor(systemGroupOps(), socket, false, nuid, ngid)
    let o = dropAndConnect(nuid, ngid, other.group)
    echo "case nonmember group=", other.group, " diag=", other.diagnostic,
      " status=[", o.status, "] dropped=", o.dropped, " connected=",
      o.connected

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
    let root = scratchDir("rqgrp")
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
      check memberLine.field("connected") == "yes"

    test "a_non_member_keeps_no_group_and_cannot_connect":
      echo otherLine
      check otherLine.field("group") == "-1"
      check "not a member" in otherLine
      check " dropped=as uid " in otherLine
      check otherLine.field("status") == ""
      check otherLine.field("connected") == "no"
