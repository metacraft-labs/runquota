## Two (and more) real accounts for the class-socket tests: one the class
## socket permits and one it refuses, with the daemon running as a third.
##
## THE TESTS NEED THE KERNEL TO DECIDE. Who may claim a class is the access
## check `connect(2)` makes on the class socket, so a test of it must run
## processes under DIFFERENT credentials -- a member of the socket's group
## and a non-member -- against a daemon whose account is neither. Nothing
## here simulates that check; this module only arranges the credentials.
##
## THE PLATFORM-SPECIFIC STEP IS THIS FILE, AND ONLY THIS FILE. The scenario
## (`tests/integration/t_class_sockets.nim`) calls `accountsUnavailable`,
## `enterAccountsHost`, `prepareAccounts` and `startAs`; a platform supplies
## them. The macOS and Windows variants (local test users created and
## removed by the test, or a VM guest) implement the same four procs.
##
## LINUX: A USER NAMESPACE WITH SUBORDINATE IDS. The test re-executes itself
## under `unshare --user --mount` with this user mapped to root and its
## `/etc/subuid` / `/etc/subgid` range mapped to ids 1 to 65535
## (`newuidmap(1)`). Inside, ids 1001-1003 are real, distinct kernel
## credentials (host ids in the subordinate range), the namespace's root may
## `chown` to them and switch to them (`setpriv(1)`), and the kernel's
## permission checks on a socket -- owner, group, supplementary groups, mode
## -- are exactly the ones a host with those accounts makes. `/etc/passwd`
## and `/etc/group` are bind-mounted over with the test's accounts inside the
## private mount namespace, so names (`ci`, `member`) resolve as on a real
## host; nothing outside the namespace sees them. No root and no persistent
## change on the host: the namespace ends with the test.
##
## Accounts, as the scenario expects them on every platform:
##
## | name       | uid  | groups                         |
## |------------|------|--------------------------------|
## | `rqd`      | 1001 | `rqd` (1001, primary), `rqgrp`, `ci` |
## | `member`   | 1002 | `member` (primary), `rqgrp`, `ci`, `gputeam` |
## | `outsider` | 1003 | `outsider` (primary), `rqgrp`  |
##
## `rqgrp` (1500) is the rendezvous group (everyone may reach the daemon),
## `ci` (2000) the class's group, `gputeam` (2001) a group the daemon's
## account is NOT in.

import std/[os, osproc, streams, strtabs, strutils]

when defined(linux):
  import std/posix

type
  Account* = object
    name*: string
    uid*: int
    gid*: int
    groups*: seq[int]
      ## Supplementary groups, primary included.

const
  RqdAccount* = Account(name: "rqd", uid: 1001, gid: 1001,
    groups: @[1001, 1500, 2000])
  MemberAccount* = Account(name: "member", uid: 1002, gid: 1002,
    groups: @[1002, 1500, 2000, 2001])
  OutsiderAccount* = Account(name: "outsider", uid: 1003, gid: 1003,
    groups: @[1003, 1500])
  RendezvousGroup* = (name: "rqgrp", gid: 1500)
  ClassGroup* = (name: "ci", gid: 2000)
  ForeignGroup* = (name: "gputeam", gid: 2001)
  InsideEnvVar* = "RUNQUOTA_TEST_ACCOUNTS_INSIDE"
    ## Set in the re-executed test: it is inside the accounts host.

proc accountsPlatform*(): string =
  ## What `prepareAccounts` arranges the accounts with, for the test's
  ## report of where it ran.
  when defined(linux): "linux (user namespace, subordinate ids)"
  else: "unsupported"

when defined(linux):
  proc subordinateRange(file, user: string; uid: int): tuple[start, count: int] =
    ## The first range `file` (`/etc/subuid`) grants `user` (or `uid`).
    result = (start: -1, count: 0)
    if not fileExists(file):
      return
    for line in readFile(file).splitLines():
      let fields = line.strip().split(':')
      if fields.len == 3 and (fields[0] == user or fields[0] == $uid):
        try:
          return (start: parseInt(fields[1]), count: parseInt(fields[2]))
        except ValueError:
          discard

  proc currentUserName(): string =
    let entry = getpwuid(getuid())
    if entry == nil: "" else: $entry.pw_name

  proc tool(name: string): string =
    ## A host tool, from PATH or its usual place. `newuidmap` must be the
    ## set-user-id one the distribution installs.
    result = findExe(name)
    if result.len == 0 and fileExists("/usr/bin/" & name):
      result = "/usr/bin/" & name

proc accountsUnavailable*(): string =
  ## Why the accounts cannot be arranged here (the test is then SKIPPED,
  ## saying so), or "".
  when defined(linux):
    for name in ["unshare", "setpriv", "newuidmap", "newgidmap"]:
      if tool(name).len == 0:
        return name & " is not installed"
    let user = currentUserName()
    let uids = subordinateRange("/etc/subuid", user, int(getuid()))
    let gids = subordinateRange("/etc/subgid", user, int(getgid()))
    if uids.count < 3000 or gids.count < 3000:
      return "this user has no subordinate id range of at least 3000 ids " &
        "in /etc/subuid and /etc/subgid"
    ""
  else:
    "no two-account helper for this platform yet"

proc enterAccountsHost*(scenario: string; extraEnv: openArray[(string,
                        string)] = []): tuple[code: int, output: string] =
  ## Run this test binary again, as the root of a host where the accounts
  ## can exist, with `InsideEnvVar` set to `scenario`. Returns its exit code
  ## and output.
  when defined(linux):
    let user = currentUserName()
    let uids = subordinateRange("/etc/subuid", user, int(getuid()))
    let gids = subordinateRange("/etc/subgid", user, int(getgid()))
    var env = newStringTable(modeCaseSensitive)
    for key, value in envPairs():
      env[key] = value
    env[InsideEnvVar] = scenario
    for (key, value) in extraEnv:
      env[key] = value
    let count = min(min(uids.count, gids.count), 65536) - 1
    let process = startProcess(tool("unshare"), args = [
        "--user", "--map-root-user",
        "--map-users=1:" & $uids.start & ":" & $count,
        "--map-groups=1:" & $gids.start & ":" & $count,
        "--setgroups=allow", "--mount", "--fork", "--",
        getAppFilename()],
      env = env, options = {poStdErrToStdOut})
    let output = process.outputStream.readAll()
    let code = process.waitForExit()
    process.close()
    (code: code, output: output)
  else:
    (code: 1, output: "no two-account helper for this platform")

when defined(linux):
  proc mountCall(source, target, fstype: cstring; flags: culong;
                 data: pointer): cint {.importc: "mount",
    header: "<sys/mount.h>".}
  const msBind = culong(4096)

proc prepareAccounts*(root: string) =
  ## Inside the accounts host: make the accounts and groups of the table
  ## above exist, by name. `root` holds the files that stand in for the
  ## account database.
  when defined(linux):
    let passwd = root / "passwd"
    let group = root / "group"
    var users = "root:x:0:0:root:/root:/bin/sh\n" &
      "nobody:x:65534:65534:nobody:/:/bin/sh\n"
    for account in [RqdAccount, MemberAccount, OutsiderAccount]:
      users.add(account.name & ":x:" & $account.uid & ":" & $account.gid &
        ":" & account.name & ":/:/bin/sh\n")
    writeFile(passwd, users)
    writeFile(group, "root:x:0:\nnobody:x:65534:\n" &
      "rqd:x:1001:\nmember:x:1002:\noutsider:x:1003:\n" &
      RendezvousGroup.name & ":x:" & $RendezvousGroup.gid &
        ":rqd,member,outsider\n" &
      ClassGroup.name & ":x:" & $ClassGroup.gid & ":rqd,member\n" &
      ForeignGroup.name & ":x:" & $ForeignGroup.gid & ":member\n")
    for path in [passwd, group]:
      setFilePermissions(path, {fpUserRead, fpUserWrite, fpGroupRead,
        fpOthersRead})
    for (source, target) in [(passwd, "/etc/passwd"), (group, "/etc/group")]:
      if mountCall(source.cstring, target.cstring, nil, msBind, nil) != 0:
        raise newException(OSError, "bind-mounting " & source & " over " &
          target & ": " & $strerror(errno))
  else:
    discard root

proc chownTo*(path: string; account: Account; gid = -1) =
  ## Give `path` to `account` (and group `gid`, else its primary group).
  when defined(linux):
    if posix.chown(path.cstring, Uid(account.uid),
        Gid(if gid >= 0: gid else: account.gid)) != 0:
      raise newException(OSError, "chown " & path & ": " & $strerror(errno))
  else:
    discard path
    discard account
    discard gid

proc startAs*(account: Account; exe: string; args: openArray[string];
              env: StringTableRef): Process =
  ## Start `exe` with `account`'s uid, gid and groups, and no capabilities.
  ## Stdin, stdout and stderr are pipes (stderr merged into stdout).
  when defined(linux):
    var groups: seq[string] = @[]
    for gid in account.groups: groups.add($gid)
    var full = @["--reuid=" & $account.uid, "--regid=" & $account.gid,
      "--groups=" & groups.join(","), "--inh-caps=-all", "--", exe]
    for arg in args: full.add(arg)
    startProcess(tool("setpriv"), args = full, env = env,
      options = {poStdErrToStdOut})
  else:
    raise newException(OSError, "no two-account helper for this platform")
