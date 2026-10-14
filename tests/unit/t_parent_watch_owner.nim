## PID 1 is a valid caller identity in a container. The kernel reports it
## identically to init after orphaning, so only an explicitly supplied owner
## can distinguish those startup cases. These tests exercise the actual pure
## ownership boundary used by the watcher; they mock no syscall or daemon.
## Real parent death and shutdown remain covered by t_exits_when_its_parent_dies.

import std/unittest
import runquota_daemon/parent_watch

suite "parent watch owner identity":
  test "explicit owner PID 1 remains alive while the observed parent matches":
    let owner = resolveParentWatchOwner(1, "1", true)
    check owner == 1
    check not parentHasExited(owner, 1)
    check parentHasExited(owner, 2)

  test "fallback init means the original caller is already gone":
    let owner = resolveParentWatchOwner(1, "", false)
    check parentHasExited(owner, 1)
    check parentHasExited(owner, 42)

  test "invalid explicit ownership fails closed even under a live parent":
    for value in ["", "0", "-1", "not-a-pid", "999999999999999999999999"]:
      let owner = resolveParentWatchOwner(42, value, true)
      check parentHasExited(owner, 42)

  test "ordinary explicit and fallback owners stop only after reparenting":
    for owner in [resolveParentWatchOwner(42, "42", true),
                  resolveParentWatchOwner(42, "", false)]:
      check owner == 42
      check not parentHasExited(owner, 42)
      check parentHasExited(owner, 1)
