## Leased children must not inherit descriptors from the process that launched
## them.
##
## This is the property `closeInheritedChildFds` has always been responsible
## for, and it was never asserted anywhere -- only its cost was felt. When that
## routine's `_SC_OPEN_MAX`-bounded loop was replaced with CLOEXEC-at-birth plus
## a cheap platform backstop, nothing in the suite would have noticed if the
## replacement had stopped closing anything at all. That absence is what this
## file fixes.
##
## Why it matters beyond tidiness: RunQuota exists to launch actions under
## reproducibility monitors. A descriptor that leaks into a monitored child is
## read by the monitor as opaque external content, because the producing
## endpoint sits outside the monitored action tree -- so a leak corrupts exactly
## the dependency capture the system is built to make trustworthy.
##
## The two halves of the mechanism are asserted separately:
##
##   * "closed by the backstop" -- the fixture descriptors are placed with
##     `F_DUPFD`, which produces duplicates *without* FD_CLOEXEC (asserted
##     below, so the fixture cannot silently stop testing anything). They are
##     therefore inheritable by the kernel's rules, and can only be absent from
##     the child because the between-fork-and-exec sweep closed them.
##
##   * "never inheritable in the first place" -- RunQuota's own control
##     descriptors (lease stdout/stderr pipes, daemon sockets) are asserted to
##     carry FD_CLOEXEC from creation, which is what removes the sweep from the
##     hot path rather than merely making it cheaper.
##
## No mocks: this runs the real `launchProcess` against the real kernel and
## inspects the real child's descriptor table via /dev/fd (or /proc/self/fd).

import std/[os, strutils, unittest]
from std/net import getFd

when defined(posix):
  import std/posix

import runquota_core
import runquota_ipc
import runquota_process

when defined(posix):
  const
    HighFdBase = 20'i32
      ## Fixture descriptors are parked well above anything a freshly exec'd
      ## `ls` allocates for itself, so "the child reported a descriptor >= this"
      ## is unambiguous evidence of a leak rather than a collision with the
      ## lister's own directory handle.

  proc parkHigh(fd: cint): cint =
    ## Duplicate `fd` to the lowest free descriptor at or above `HighFdBase`.
    ## `F_DUPFD` (unlike `F_DUPFD_CLOEXEC`) yields a duplicate with FD_CLOEXEC
    ## clear, which is precisely the kind of descriptor the backstop must close.
    result = fcntl(fd, F_DUPFD, HighFdBase)
    doAssert result >= HighFdBase, "F_DUPFD failed to park a fixture descriptor"

  proc childFdDirectory(): string =
    if dirExists("/dev/fd"): "/dev/fd"
    elif dirExists("/proc/self/fd"): "/proc/self/fd"
    else: ""

  proc reportedFds(text: string): seq[int] =
    for token in text.splitWhitespace():
      try:
        result.add(parseInt(token))
      except ValueError:
        discard

suite "inherited_fd_isolation":
  test "a leased child does not inherit the launcher's descriptors":
    when defined(posix):
      let fdDir = childFdDirectory()
      if fdDir.len == 0:
        skip()
      else:
        let sentinel = "runquota-inherited-fd-sentinel-9f13c2"
        let sentinelPath = getTempDir() / "runquota-fd-isolation.txt"
        writeFile(sentinelPath, sentinel)

        # A representative spread of descriptor kinds: a regular file, both
        # ends of a pipe, and a socket -- the same shapes RunQuota itself holds
        # while a lease runs.
        var fixtures: seq[cint] = @[]
        let fileFd = posix.open(cstring(sentinelPath), O_RDONLY)
        doAssert fileFd >= 0
        fixtures.add(parkHigh(fileFd))
        discard close(fileFd)

        var raw: array[0..1, cint]
        doAssert pipe(raw) == 0
        fixtures.add(parkHigh(raw[0]))
        fixtures.add(parkHigh(raw[1]))
        discard close(raw[0])
        discard close(raw[1])

        let sockHandle = posix.socket(posix.AF_UNIX, posix.SOCK_STREAM, cint(0))
        doAssert cint(sockHandle) >= 0
        fixtures.add(parkHigh(cint(sockHandle)))
        discard close(cint(sockHandle))

        # Fixture integrity: if these were CLOEXEC the test would pass for the
        # wrong reason -- the kernel, not RunQuota, would be doing the work.
        for fd in fixtures:
          check not isCloseOnExec(fd)

        # 1. The child's own view of its descriptor table.
        var lister = launchProcess(commandSpec(["/bin/ls", fdDir]))
        let listing = lister.waitForCompletion(10_000)
        lister.close()
        check listing.exited
        check listing.exitCode == 0
        let seenByChild = reportedFds(listing.stdout)
        # `ls` always reports at least stdin/stdout/stderr plus its own handle
        # on the directory, so an empty parse would mean the probe silently
        # measured nothing.
        check seenByChild.len >= 3
        for fd in seenByChild:
          check fd < int(HighFdBase)

        # 2. Identity, not just numbering: if the file descriptor had survived,
        # reading it back through the child's own /dev/fd would reproduce the
        # sentinel bytes.
        let fileFdPath = fdDir & "/" & $fixtures[0]
        var reader = launchProcess(commandSpec(
          ["/bin/sh", "-c", "cat " & fileFdPath]))
        let readBack = reader.waitForCompletion(10_000)
        reader.close()
        check not readBack.stdout.contains(sentinel)
        check readBack.exitCode != 0

        for fd in fixtures:
          discard close(fd)
        removeFile(sentinelPath)
    else:
      skip()

  test "isolation holds when the launcher holds hundreds of descriptors":
    when defined(posix):
      let fdDir = childFdDirectory()
      if fdDir.len == 0:
        skip()
      else:
        # The Darwin backstop reads /dev/fd through a fixed 8 KiB stack buffer,
        # which holds roughly 250 entries; anything past that needs a second
        # `getdirentries64` call. A launcher holding only a handful of
        # descriptors would never reach that continuation, so a bug in it would
        # sit undetected until a busy daemon hit it in production.
        var held: seq[cint] = @[]
        for _ in 0 ..< 600:
          let fd = posix.open(cstring("/dev/null"), O_RDONLY)
          if fd < 0:
            break
          held.add(fd)
        check held.len == 600
        # Park one deliberately above the base so the assertion below has a
        # descriptor it can name, whatever numbers the bulk allocation took.
        let marker = parkHigh(held[^1])
        check not isCloseOnExec(marker)

        var lister = launchProcess(commandSpec(["/bin/ls", fdDir]))
        let listing = lister.waitForCompletion(10_000)
        lister.close()
        check listing.exited
        let seenByChild = reportedFds(listing.stdout)
        check seenByChild.len >= 3
        # Every one of the 600 would show up here if the walk stopped after the
        # first buffer.
        check seenByChild.len <= 8
        for fd in seenByChild:
          check fd < int(HighFdBase)

        discard close(marker)
        for fd in held:
          discard close(fd)
    else:
      skip()

  test "lease output pipes are close-on-exec from birth":
    when defined(posix):
      # The stdout/stderr read ends live in the launching process for the whole
      # lease. Another lease starting concurrently must not pick them up, and
      # the guarantee has to come from the descriptor's own flags rather than
      # from the fork-time sweep -- otherwise the sweep could never be cheap.
      var child = launchProcess(commandSpec(["/bin/sh", "-c", "sleep 1"]))
      check child.stdoutFd >= 0
      check child.stderrFd >= 0
      check isCloseOnExec(cint(child.stdoutFd))
      check isCloseOnExec(cint(child.stderrFd))
      discard child.waitForCompletion(10_000)
      child.close()
    else:
      skip()

  test "daemon sockets are close-on-exec from birth":
    when defined(posix):
      # A RunQuotaSession keeps its daemon connection open across the fork+exec
      # of the leased command, so this socket is the single most likely thing
      # to leak into a monitored action tree.
      let socketPath = getTempDir() / "runquota-fd-isolation.sock"
      removeFile(socketPath)
      var listener = bindEndpoint(unixEndpoint(socketPath))
      check isCloseOnExec(cint(listener.socket.getFd()))
      var client = connectEndpoint(unixEndpoint(socketPath))
      check isCloseOnExec(cint(client.socket.getFd()))
      var server = acceptConnection(listener)
      check isCloseOnExec(cint(server.socket.getFd()))
      server.close()
      client.close()
      listener.close()
    else:
      skip()
