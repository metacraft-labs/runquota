## M13d: a `runquota` group that cannot be resolved must NOT silently
## switch the group check off.
##
## THE RULING, AND WHY IT IS NOT THE `host_id` RULING. The group IS the
## admission boundary: membership in it is what the kernel admits a client
## by. On a host with no such group there is no boundary, yet a daemon that
## merely skipped the group comparison would still start, still bind
## `0750`, and still look entirely healthy -- while the directory sat
## traversable by whatever group it happened to inherit, chosen by nobody
## and verified against nothing. That is this campaign's recurring failure
## shape.
##
## Refusing to start is the wrong repair, and for the same reason it was
## the RIGHT answer for `host_id` to disable capture: admission is the
## mission. A host that has not created the group yet must not lose its
## build-capacity governor over a missing group entry. But `host_id`'s
## answer -- carry on without the failed thing -- is not available here,
## because the thing that fails IS the boundary.
##
## So the degradation is VISIBLE AND SMALLER, not silent: with no group the
## endpoint becomes `0700`/`0600`, owner-only, and `runquotad` says so on
## the line an operator already reads. The host-wide daemon degrades
## visibly to a per-user one -- a boundary the kernel really enforces and
## this code really verifies -- instead of invisibly to no boundary.
##
## THE DECIDING CONTROL IS THAT THE TWO CASES ARE DISTINGUISHABLE BY
## SOMETHING ASSERTABLE. Not a comment: a scope on the policy, a report
## string, a directory mode, a socket mode, and a startup line -- all five
## compared between one daemon started with a resolvable group and one
## started without, in this file, against the real binary.
##
## No mocks: the real `runquotad`, real Unix sockets, real modes on disk.

import std/[os, osproc, posix, streams, strutils, unittest]

import runquota_ipc

proc scratchDir(name: string): string =
  # Short on purpose. Nim's `Sockaddr_un_path_length` is 92 on macOS and
  # `toSockAddr` refuses `path.len >= 92`, so 91 characters is the whole
  # budget. A plain macOS `TMPDIR` is 49 characters before anything is
  # appended; inside `nix develop` it is 21.
  #
  #   49 (TMPDIR) + 12 (this dir) + 3 (/ep) + 7 (/d.sock) = 71
  result = getTempDir() / ("rq" & $getCurrentProcessId() & name)
  removeDir(result)
  createDir(result)
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})

proc daemonPath(): string = getCurrentDir() / "build" / "bin" / "runquotad"

proc modeOf(path: string): int =
  var info: Stat
  if lstat(path.cstring, info) != 0: return -1
  int(info.st_mode) and 0o7777

proc groupOf(path: string): int64 =
  var info: Stat
  if lstat(path.cstring, info) != 0: return -1
  int64(info.st_gid)

proc socketExists(path: string): bool =
  var info: Stat
  lstat(path.cstring, info) == 0 and S_ISSOCK(info.st_mode)

type DaemonHandle = object
  process: Process
  listeningLine: string

proc startDaemon(socketPath, group: string): DaemonHandle =
  ## `group` is passed through the environment the daemon inherits. A
  ## numeric gid resolves; a name no host has does not, and that is the
  ## whole experiment.
  putEnv("RUNQUOTA_ENDPOINT_GROUP", group)
  let process = startProcess(daemonPath(), args = ["--socket", socketPath],
    options = {poStdErrToStdOut})
  for _ in 0 ..< 400:
    if socketExists(socketPath): break
    sleep(25)
  # The LISTENING line, which is always the first of the daemon's fixed
  # three. The degradation is APPENDED to it rather than printed on its own
  # line precisely so that this read stays a read of line one: the startup
  # output is consumed by count, and a reader that guessed wrong would
  # block or misread. (Before M13 there were three startup lines only when
  # a store path was given and one when it was not; capture is on without
  # any flag now, so there are always three and the first is still this.)
  let line = process.outputStream.readLine()
  delEnv("RUNQUOTA_ENDPOINT_GROUP")
  DaemonHandle(process: process, listeningLine: line)

proc stop(handle: var DaemonHandle) =
  if handle.process.running:
    handle.process.terminate()
    discard handle.process.waitForExit(5000)
  if handle.process.running:
    handle.process.kill()
    discard handle.process.waitForExit(5000)
  check not handle.process.running
  handle.process.close()

suite "rendezvous_degradation":
  test "a resolvable group gives a SHARED, group-gated endpoint and says nothing":
    let root = scratchDir("rdvS")
    defer: removeDir(root)
    let dir = root / "ep"
    let socketPath = dir / "d.sock"
    # A real gid this process carries, resolved numerically, so the shared
    # scope is reachable on any host including one with no `runquota`
    # group.
    var daemon = startDaemon(socketPath, $int64(getgid()))
    try:
      check socketExists(socketPath)
      check daemon.listeningLine.contains(socketPath)
      # SILENT IS CORRECT HERE, and it is the half that makes the other
      # test's noise meaningful.
      check "single-user" notin daemon.listeningLine
      check "owner-only" notin daemon.listeningLine
      check modeOf(dir) == 0o750
      check modeOf(socketPath) == 0o660
      check groupOf(dir) == int64(getgid())
      check groupOf(socketPath) == int64(getgid())
      # Group-traversable: that IS the admission boundary.
      check (modeOf(dir) and 0o050) == 0o050
      check (modeOf(socketPath) and 0o060) == 0o060
    finally:
      daemon.stop()

  test "an UNRESOLVABLE group degrades to owner-only, and SAYS so":
    let root = scratchDir("rdv1")
    defer: removeDir(root)
    let dir = root / "ep"
    let socketPath = dir / "d.sock"
    var daemon = startDaemon(socketPath, "runquota-no-such-group-m13d")
    try:
      check socketExists(socketPath)
      # STILL SERVING. Admission is the mission; a missing group entry must
      # not take out the host's build-capacity governor.
      check daemon.process.running
      check daemon.listeningLine.contains(socketPath)

      # ...and the smaller claim is stated on the line an operator reads.
      check "single-user" in daemon.listeningLine
      check "runquota-no-such-group-m13d" in daemon.listeningLine
      check "owner-only" in daemon.listeningLine
      check "0700" in daemon.listeningLine
      check "0600" in daemon.listeningLine

      # ...and the endpoint really is owner-only, rather than being left at
      # a group-traversable mode whose group nothing verified. THIS is the
      # assertion a "just skip the group check" implementation fails.
      check modeOf(dir) == 0o700
      check modeOf(socketPath) == 0o600
      check (modeOf(dir) and 0o077) == 0
      check (modeOf(socketPath) and 0o077) == 0
    finally:
      daemon.stop()

  test "the two daemons differ in every observable the ruling is about":
    ## Stated as a comparison rather than as two independent expectations,
    ## so an implementation that produced the same endpoint either way --
    ## which is exactly what "silently disable the group check" does --
    ## fails HERE, on the difference, and not only on a mode literal
    ## somebody could update.
    let sharedRoot = scratchDir("rdvA")
    defer: removeDir(sharedRoot)
    let degradedRoot = scratchDir("rdvB")
    defer: removeDir(degradedRoot)
    let sharedSocket = sharedRoot / "ep" / "d.sock"
    let degradedSocket = degradedRoot / "ep" / "d.sock"

    var sharedDaemon = startDaemon(sharedSocket, $int64(getgid()))
    var degradedDaemon = startDaemon(degradedSocket,
      "runquota-no-such-group-m13d")
    try:
      check modeOf(sharedRoot / "ep") != modeOf(degradedRoot / "ep")
      check modeOf(sharedSocket) != modeOf(degradedSocket)
      check sharedDaemon.listeningLine.len < degradedDaemon.listeningLine.len
      check ("single-user" in sharedDaemon.listeningLine) !=
        ("single-user" in degradedDaemon.listeningLine)
      # The shared one is group-reachable and the degraded one is not.
      check (modeOf(sharedRoot / "ep") and 0o070) != 0
      check (modeOf(degradedRoot / "ep") and 0o070) == 0
    finally:
      sharedDaemon.stop()
      degradedDaemon.stop()
