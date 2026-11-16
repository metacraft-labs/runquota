## The pure parts and the semaphore mechanics of the Windows `runquota
## jobserver` bridge: the `MAKEFLAGS` the command receives, joining an
## inherited bridge, and the named-semaphore token bookkeeping (widening by
## issuing tokens, narrowing by withholding only RETURNED ones).
##
## The Windows sibling of `tests/unit/t_jobserver_bridge.nim`, which is POSIX
## (it drives the FIFO). NO MOCKS: the semaphore case is a real named semaphore
## with real `WaitForSingleObject` / `ReleaseSemaphore`, the Windows analogue of
## the POSIX file's FIFO reader/writer.

when defined(windows):
  import std/[strutils, unittest]
  import std/winlean

  import runquota_cli_support/jobserver_command

  proc releaseSemaphore(h: Handle; c: int32; p: ptr int32): WINBOOL {.
    stdcall, dynlib: "kernel32", importc: "ReleaseSemaphore".}

  suite "windows token arithmetic and MAKEFLAGS":
    test "an N-slot grant serves N - 1 tokens":
      check tokensForSlots(1) == 0
      check tokensForSlots(4) == 3
      check tokensForSlots(16) == 15

    test "the bridge's MAKEFLAGS: bare -j, both flag spellings, bare name":
      # No `fifo:` prefix, no numeric -j (a numeric cap would make the
      # jobserver redundant on Windows); the same raw name in both flags, as
      # cargo's `jobserver` crate emits.
      check bridgeMakeflagsWindows("", 4, "runquota-sem-1") ==
        " -j --jobserver-fds=runquota-sem-1 --jobserver-auth=runquota-sem-1"
      check bridgeMakeflagsWindows(" -k -j9 --jobserver-auth=old", 2, "s") ==
        " -k -j --jobserver-fds=s --jobserver-auth=s"
      check bridgeMakeflagsWindows("ks --jobserver-fds=3 -j --jobs=3", 3, "s") ==
        " ks -j --jobserver-fds=s --jobserver-auth=s"

    test "the semaphore a MAKEFLAGS names, and joining an inherited bridge":
      check semaphoreNamedByMakeflags(
        " -j --jobserver-auth=runquota-sem-9") == "runquota-sem-9"
      # A POSIX `fifo:` value is not a Windows semaphore name and is rejected.
      check semaphoreNamedByMakeflags(" -j --jobserver-auth=fifo:/a/b") == ""
      check semaphoreNamedByMakeflags("") == ""
      check joinsInheritedBridgeWindows(
        " -j --jobserver-auth=sem-A", "sem-A")
      check not joinsInheritedBridgeWindows(
        " -j --jobserver-auth=sem-X", "sem-A")
      check not joinsInheritedBridgeWindows(" -j --jobserver-auth=sem-A", "")
      check not joinsInheritedBridgeWindows("", "sem-A")

    test "a target is whole slots, never more than it allows, never below 1":
      check slotsForTarget(8000) == 8
      check slotsForTarget(2500) == 2
      check slotsForTarget(999) == 1
      check slotsForTarget(0) == 1

  suite "windows semaphore widening and narrowing":
    test "widening issues tokens; narrowing takes only RETURNED ones":
      var sem = openJobserverSemaphore(1)
      defer: sem.closeJobserverSemaphore()
      check sem.served == 1
      check sem.issueTokens(6) == 6
      check sem.served == 7
      # A client takes five tokens, as five running jobs would: five
      # non-blocking acquires on the same named semaphore.
      for _ in 0 ..< 5:
        check waitForSingleObject(sem.handle, 0) == 0'i32
      # Narrowing to 2 slots (1 token) owes 6, but only the 2 tokens still in
      # the semaphore can be taken: the five held are not the bridge's to take.
      check sem.withholdTokens(6) == 2
      check sem.served == 5
      # Nothing more is there; a bounded wait returns empty-handed.
      check sem.withholdTokens(4, waitMillis = 20) == 0
      # Three jobs finish and hand their tokens back: the bridge keeps them.
      check releaseSemaphore(sem.handle, 3, nil) != 0
      check sem.withholdTokens(4, waitMillis = 20) == 3
      check sem.served == 2
else:
  echo "t_jobserver_bridge_windows: Windows only"
