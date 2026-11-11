## The per-user endpoint: where it is, and what may live there.
##
## WHY THIS EXISTS. On a host with no provisioned RunQuota service, every
## process of one user must compute THE SAME socket path, from the filesystem
## and the effective uid only -- two processes that saw different
## environments and computed two paths would start two daemons, which is the
## defect `defaultEndpoint` removed in `093f520`. And the directory, often
## under a world-writable `/tmp`, must be refused rather than used when
## another user got there first (reprobuild-pm
## `spec/RunQuota-Host-Configuration.md`, "The shared per-user daemon
## (POSIX)"). Covered here:
##
## * the three-step rule: `RUNQUOTA_USER_ENDPOINT_DIR` (absolute, no NUL; a
##   malformed value is an error), then on Linux `/run/user/<euid>/runquota`
##   when `/run/user/<euid>` is a real directory owned by the euid with no
##   group or other write, else `/tmp/runquota-<euid>`; the socket is
##   `runquotad.sock`, the locks `<socket>.lock` and `<socket>.start`;
## * the directory rule: created `0700`; the user's own directory with another
##   mode repaired to `0700`; a symbolic link, a non-directory, or a directory
##   owned by another uid refused, the last with both remedies named;
## * the lock files: the lifetime lock is exclusive and its probe sees it;
##   a symbolic link at a lock path is refused.
##
## The `/run/user` step is driven through `resolveUserEndpointDir` with a
## scratch directory standing in for `/run/user`, because only root can create
## the real one; the real host's answer is checked against the same rule
## written out as literals. Expected paths and modes are literals throughout.
##
## No mocks: real directories, real modes, real `flock(2)`. Nothing here
## creates or touches the real per-user endpoint directory.

when defined(posix):
  import std/[os, posix, strutils, tempfiles, unittest]

  import runquota_ipc

  proc flockCall(fd: cint; operation: cint): cint {.
    importc: "flock", header: "<sys/file.h>".}

  proc modeOf(path: string): int =
    var info: Stat
    if lstat(path.cstring, info) != 0: return -1
    int(info.st_mode) and 0o7777

  proc scratch(): string =
    result = createTempDir("rqu", "")
    setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})

  proc withOverride(value: string; body: proc ()) =
    let had = existsEnv(userEndpointDirEnvVar)
    let saved = getEnv(userEndpointDirEnvVar)
    putEnv(userEndpointDirEnvVar, value)
    try: body()
    finally:
      if had: putEnv(userEndpointDirEnvVar, saved)
      else: delEnv(userEndpointDirEnvVar)

  let euid = int64(geteuid())

  suite "per-user endpoint location":
    test "the override names the directory, and a malformed one is an error":
      withOverride("/srv/rq-test/me", proc () =
        doAssert userEndpointDir() == "/srv/rq-test/me"
        let endpoint = userEndpoint()
        doAssert endpoint.kind == endpointUnixSocket
        doAssert endpoint.path == "/srv/rq-test/me/runquotad.sock")
      withOverride("relative/dir", proc () =
        var raised = false
        try: discard userEndpointDir()
        except EndpointTrustError as error:
          raised = true
          doAssert userEndpointDirEnvVar in error.msg
        doAssert raised, "accepted a relative directory")
      # An environment variable cannot carry a NUL byte (the C string ends
      # there), so that half of the rule is asked of the resolver directly.
      expect EndpointTrustError:
        discard resolveUserEndpointDir(euid, "/with\0nul", "", "/tmp")

    test "the /run/user step: a real, owned, not group- or other-writable directory":
      let root = scratch()
      defer: removeDir(root)
      let runUser = root / "run-user"
      let tmp = root / "tmp"
      createDir(runUser)
      let mine = runUser / $euid
      let fallback = tmp & "/runquota-" & $euid
      # Missing: the fallback.
      check resolveUserEndpointDir(euid, "", runUser, tmp) == fallback
      createDir(mine)
      for mode in [0o700, 0o750, 0o755]:
        doAssert chmod(mine.cstring, Mode(mode)) == 0
        check resolveUserEndpointDir(euid, "", runUser, tmp) ==
          mine & "/runquota"
      # Group- or other-writable: another user could occupy the path.
      for mode in [0o770, 0o702, 0o777]:
        doAssert chmod(mine.cstring, Mode(mode)) == 0
        check resolveUserEndpointDir(euid, "", runUser, tmp) == fallback
      doAssert chmod(mine.cstring, Mode(0o700)) == 0
      # Owned by another uid (this directory is ours, so ask for euid + 1).
      let other = runUser / $(euid + 1)
      createDir(other)
      setFilePermissions(other, {fpUserRead, fpUserWrite, fpUserExec})
      check resolveUserEndpointDir(euid + 1, "", runUser, tmp) ==
        tmp & "/runquota-" & $(euid + 1)
      # A symbolic link is not a real directory, even to one we own.
      removeDir(mine)
      createDir(root / "elsewhere")
      createSymlink(root / "elsewhere", mine)
      check resolveUserEndpointDir(euid, "", runUser, tmp) == fallback
      # No `/run/user` step at all (macOS): the fallback.
      check resolveUserEndpointDir(euid, "", "", tmp) == fallback
      # The override wins over everything.
      check resolveUserEndpointDir(euid, "/x/y", runUser, tmp) == "/x/y"

    test "this host's answer follows the same rule, written out":
      withOverride("", proc () =
        var expected = "/tmp/runquota-" & $euid
        when defined(linux):
          let runUser = "/run/user/" & $euid
          var info: Stat
          if lstat(runUser.cstring, info) == 0 and S_ISDIR(info.st_mode) and
              int64(info.st_uid) == euid and
              (int(info.st_mode) and 0o022) == 0:
            expected = runUser & "/runquota"
        doAssert userEndpointDir() == expected,
          userEndpointDir() & " != " & expected
        doAssert userEndpoint().path == expected & "/runquotad.sock")

    test "the lock files sit beside the socket":
      check lifetimeLockPath("/a/b/runquotad.sock") == "/a/b/runquotad.sock.lock"
      check startLockPath("/a/b/runquotad.sock") == "/a/b/runquotad.sock.start"

  suite "per-user endpoint directory":
    test "a missing directory is created 0700":
      let root = scratch()
      defer: removeDir(root)
      let dir = root / "ep"
      ensureUserEndpointDir(dir)
      check dirExists(dir)
      check modeOf(dir) == 0o700

    test "the user's own directory with another mode is repaired to 0700":
      let root = scratch()
      defer: removeDir(root)
      let dir = root / "ep"
      createDir(dir)
      for mode in [0o755, 0o777, 0o500]:
        doAssert chmod(dir.cstring, Mode(mode)) == 0
        ensureUserEndpointDir(dir)
        check modeOf(dir) == 0o700

    test "a symbolic link, a file and a missing parent are refused":
      let root = scratch()
      defer: removeDir(root)
      createDir(root / "target")
      setFilePermissions(root / "target", {fpUserRead, fpUserWrite, fpUserExec})
      createSymlink(root / "target", root / "link")
      writeFile(root / "file", "")
      for (path, words) in [(root / "link", "symbolic link"),
                            (root / "file", "not a directory"),
                            (root / "absent" / "ep", "cannot create")]:
        var raised = false
        try: ensureUserEndpointDir(path)
        except OSError as error:
          raised = true
          checkpoint error.msg
          check path in error.msg
          check words in error.msg
        check raised
      # Nothing was repaired through the link.
      check modeOf(root / "target") == 0o700

    test "a directory owned by another uid is refused with both remedies":
      if euid == 0:
        skip()
      else:
        # `/` is owned by root on every POSIX host: a foreign directory this
        # test can name without creating one. Its mode must be left alone,
        # and the ownership refusal comes first.
        var raised = false
        try: ensureUserEndpointDir("/")
        except EndpointTrustError as error:
          raised = true
          checkpoint error.msg
          check "owned by uid 0" in error.msg
          check "remove it" in error.msg
          check userEndpointDirEnvVar in error.msg
        check raised

    test "a relative or NUL-carrying directory is refused":
      for bad in ["relative", "/a\0b"]:
        expect EndpointTrustError:
          ensureUserEndpointDir(bad)

  suite "endpoint lock files":
    test "the lifetime lock is exclusive and the probe sees it":
      let root = scratch()
      defer: removeDir(root)
      let socket = root / "runquotad.sock"
      check not lifetimeLockHeld(socket)       # no file: nobody holds it
      let held = acquireLifetimeLock(socket)
      check modeOf(lifetimeLockPath(socket)) == 0o600
      check lifetimeLockHeld(socket)
      # The probe released what it took: the holder's lock is intact.
      let probe = posix.open(lifetimeLockPath(socket).cstring, O_RDONLY)
      doAssert probe >= 0
      check flockCall(probe, 1 or 4) != 0      # LOCK_SH | LOCK_NB
      discard posix.close(probe)
      var refused = false
      try: discard acquireLifetimeLock(socket)
      except EndpointTrustError as error:
        refused = true
        check lifetimeLockPath(socket) in error.msg
      check refused
      releaseEndpointLock(held)
      check not lifetimeLockHeld(socket)
      let again = acquireLifetimeLock(socket)
      releaseEndpointLock(again)

    test "a lock file with a wider mode is narrowed to 0600":
      let root = scratch()
      defer: removeDir(root)
      let socket = root / "runquotad.sock"
      writeFile(lifetimeLockPath(socket), "")
      doAssert chmod(lifetimeLockPath(socket).cstring, Mode(0o644)) == 0
      let held = acquireLifetimeLock(socket)
      check modeOf(lifetimeLockPath(socket)) == 0o600
      releaseEndpointLock(held)

    test "a symbolic link at a lock path is refused, not followed":
      let root = scratch()
      defer: removeDir(root)
      let socket = root / "runquotad.sock"
      writeFile(root / "target", "")
      createSymlink(root / "target", lifetimeLockPath(socket))
      createSymlink(root / "target", startLockPath(socket))
      expect EndpointTrustError:
        discard acquireLifetimeLock(socket)
      expect EndpointTrustError:
        discard lifetimeLockHeld(socket)
      expect EndpointTrustError:
        discard acquireStartLock(socket)

    test "the start lock is exclusive":
      let root = scratch()
      defer: removeDir(root)
      let socket = root / "runquotad.sock"
      let held = acquireStartLock(socket)
      let other = posix.open(startLockPath(socket).cstring, O_RDONLY)
      doAssert other >= 0
      check flockCall(other, 2 or 4) != 0      # LOCK_EX | LOCK_NB
      discard posix.close(other)
      releaseEndpointLock(held)
      check modeOf(startLockPath(socket)) == 0o600
else:
  echo "t_user_endpoint_rules: POSIX only (the per-user daemon is the POSIX row)"
