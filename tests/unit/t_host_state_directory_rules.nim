## The host-state-directory trust RULE, row by row, below the daemon.
##
## `tests/integration/t_host_state_directory_trust.nim` asserts the refusal
## end to end against a real `runquotad`, one representative fixture per
## clause. This file is the table in `docs/database.md` §"Provisioning the
## host-wide state directory and the rendezvous" taken one row at a time,
## against the predicate itself, so a row that stops being enforced fails
## here by name.
##
## EVERY REFUSAL IS PAIRED WITH THE ACCEPTANCE ONE ACE AWAY FROM IT. A
## predicate that refused everything would pass every refusal below; the
## acceptances are what stop it.
##
## No mocks: real directories on the real filesystem, their DACLs written by
## `icacls` -- the tool an operator uses -- and never by RunQuota.

when defined(windows):
  import std/[os, strutils, unittest]

  import runquota_ipc
  import windows_acl_fixture

  const label = "host state directory"

  proc scratchDir(name: string): string =
    result = getTempDir() / ("rq-hsr-" & $getCurrentProcessId() & "-" & name)
    removeDir(result)
    createDir(result)
    # The baseline every row starts from: owned by this user, inheritance
    # removed, full control for this user, SYSTEM and Administrators only.
    restrictToOwnerAndSystem(result)

  proc judge(path: string): PathTrust =
    inspectDirectoryAcl(path, currentUserSid(), label)

  suite "host_state_directory_acl_rules":
    test "owned by this account and writable only by it, SYSTEM and Administrators: ACCEPTED":
      let dir = scratchDir("ok")
      defer: removeDir(dir)
      let trust = judge(dir)
      check trust.reason == trustOk
      check trust.message == ""
      # The owner the predicate read is the one .NET reads -- this user, or
      # Administrators where an elevated token made the directory.
      check trust.ownerSid == ownerSidOf(dir)
      check trust.ownerSid in [currentUserSid(), "S-1-5-32-544"]

    test "readable and traversable by every user -- the 0755 -- is ACCEPTED":
      let dir = scratchDir("read")
      defer: removeDir(dir)
      icacls(dir, ["/grant", "*S-1-5-32-545:(OI)(CI)RX"])
      check judge(dir).reason == trustOk

    test "BUILTIN\\Users may create entries -- the C:\\ProgramData default -- is REFUSED":
      let dir = scratchDir("users")
      defer: removeDir(dir)
      grantUsersCreate(dir)
      let trust = judge(dir)
      check trust.reason == trustBadAcl
      check dir in trust.message
      check "S-1-5-32-545" in trust.message
      check "(CI)" in trust.message
      check "(WD,AD,WEA,WA)" in trust.message

    test "an INHERIT-ONLY write grant is REFUSED: it is what the daemon's own files would inherit":
      ## Grants nothing on the directory itself -- and hands Everyone the
      ## `host-id` the daemon is about to create in it.
      let dir = scratchDir("inherit")
      defer: removeDir(dir)
      icacls(dir, ["/grant", "*S-1-1-0:(OI)(IO)(M)"])
      let trust = judge(dir)
      check trust.reason == trustBadAcl
      check "S-1-1-0" in trust.message
      check "(OI)(IO)" in trust.message

    test "CREATOR OWNER inheritable full control is ACCEPTED":
      ## It resolves, on each child, to that child's creator -- and who may
      ## create a child is exactly what the other rows restrict.
      let dir = scratchDir("co")
      defer: removeDir(dir)
      icacls(dir, ["/grant", "*S-1-3-0:(OI)(CI)(IO)F"])
      check judge(dir).reason == trustOk

    test "CREATOR GROUP inheritable full control is REFUSED":
      ## It resolves to the creator's primary GROUP, whose members nothing
      ## here has vetted.
      let dir = scratchDir("cg")
      defer: removeDir(dir)
      icacls(dir, ["/grant", "*S-1-3-1:(OI)(CI)(IO)F"])
      let trust = judge(dir)
      check trust.reason == trustBadAcl
      check "S-1-3-1" in trust.message

    test "a DENY ACE is not a grant: ACCEPTED":
      let dir = scratchDir("deny")
      defer: removeDir(dir)
      icacls(dir, ["/deny", "*S-1-5-32-546:(OI)(CI)F"])
      check judge(dir).reason == trustOk

    test "a NULL DACL -- Everyone: full control -- is REFUSED":
      let dir = scratchDir("null")
      defer: removeDir(dir)
      setNullDacl(dir)
      let facts = readDirectorySecurity(dir)
      check facts.errorCode == 0
      check not facts.daclPresent
      let trust = judge(dir)
      check trust.reason == trustBadAcl
      check "no DACL" in trust.message

    test "a JUNCTION to an acceptable directory is REFUSED, not followed":
      let root = scratchDir("junction")
      defer: removeDir(root)
      let target = root / "target"
      createDir(target)
      restrictToOwnerAndSystem(target)
      check judge(target).reason == trustOk
      let link = root / "link"
      let (code, output) = runCmdLine("mklink /J \"" & link & "\" \"" &
        target & "\"")
      checkpoint(output)
      check code == 0
      let trust = judge(link)
      check trust.reason == trustWrongType
      check "reparse point" in trust.message
      # Removing the junction must not remove what it points at.
      removeDir(link)
      check dirExists(target)

    test "a regular FILE is REFUSED as the wrong type":
      let root = scratchDir("file")
      defer: removeDir(root)
      let file = root / "not-a-dir"
      writeFile(file, "")
      check judge(file).reason == trustWrongType

    test "a path that is not there is reported MISSING, not refused":
      let root = scratchDir("missing")
      defer: removeDir(root)
      check judge(root / "absent").reason == trustMissing
      check judge(root / "absent" / "deeper").reason == trustMissing

    test "an owner this process could not identify matches NOTHING":
      ## `processUserSid()` answers "" when the token cannot be read. That
      ## must refuse, never compare equal to some owner by accident.
      let dir = scratchDir("unknown")
      defer: removeDir(dir)
      check inspectDirectoryAcl(dir, "", label).reason == trustForeignOwner

    test "a directory owned by another account is REFUSED for its OWNER":
      let windows = getEnv("SystemRoot", r"C:\Windows")
      let owner = ownerSidOf(windows)
      check owner notin [currentUserSid(), "S-1-5-18", "S-1-5-32-544"]
      let trust = judge(windows)
      check trust.reason == trustForeignOwner
      check owner in trust.message
      check currentUserSid() in trust.message

    test "processUserSid is this process's own account":
      check processUserSid() == currentUserSid()
else:
  import std/[os, posix, strutils, unittest]

  import runquota_ipc

  ## THE SAME ROWS ON POSIX, where the rule is on a uid and a mode. The
  ## state directory is judged by `inspectPath` with the daemon's uid and,
  ## for a directory an operator named, no exact mode -- only the invariant.

  const label = "host state directory"

  proc scratchDir(name: string): string =
    result = getTempDir() / ("rq-hsr-" & $getCurrentProcessId() & "-" & name)
    removeDir(result)
    createDir(result)
    doAssert chmod(result.cstring, Mode(0o700)) == 0

  proc judge(path: string): PathTrust =
    inspectPath(path, wantDirectory = true, requiredMode = -1,
      expectedOwnerUid = int64(getuid()), label = label)

  suite "host_state_directory_acl_rules":
    test "owned by this account and writable only by it: ACCEPTED":
      let dir = scratchDir("ok")
      defer: removeDir(dir)
      check judge(dir).reason == trustOk

    test "readable and traversable by every user -- the 0755 -- is ACCEPTED":
      let dir = scratchDir("read")
      defer: removeDir(dir)
      check chmod(dir.cstring, Mode(0o755)) == 0
      check judge(dir).reason == trustOk

    test "a group-writable directory is REFUSED":
      let dir = scratchDir("group")
      defer: removeDir(dir)
      check chmod(dir.cstring, Mode(0o775)) == 0
      let trust = judge(dir)
      check trust.reason == trustBadMode
      check "0775" in trust.message

    test "a world-writable directory is REFUSED":
      let dir = scratchDir("world")
      defer: removeDir(dir)
      check chmod(dir.cstring, Mode(0o757)) == 0
      check judge(dir).reason == trustBadMode

    test "a SYMLINK to an acceptable directory is REFUSED, not followed":
      let root = scratchDir("link")
      defer: removeDir(root)
      let target = root / "target"
      createDir(target)
      check chmod(target.cstring, Mode(0o700)) == 0
      check judge(target).reason == trustOk
      let link = root / "link"
      createSymlink(target, link)
      check judge(link).reason == trustWrongType

    test "a regular FILE is REFUSED as the wrong type":
      let root = scratchDir("file")
      defer: removeDir(root)
      writeFile(root / "not-a-dir", "")
      check judge(root / "not-a-dir").reason == trustWrongType

    test "a path that is not there is reported MISSING, not refused":
      let root = scratchDir("missing")
      defer: removeDir(root)
      check judge(root / "absent").reason == trustMissing
