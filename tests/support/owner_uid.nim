## The `owner_uid` a daemon should record for THIS process's connections.
##
## On POSIX that is `getuid()`: runquotad takes it from the peer credentials
## of the connection, and the kernel's answer is the caller's real uid.
##
## ON WINDOWS IT IS NOT DEFINED YET, and this says so rather than guessing.
## The named-pipe peer identity carries a SID, and nothing maps a SID onto
## the integer `owner_uid` column -- today every Windows client is recorded
## as 0. That is an open defect with a design decision in front of it:
## `reprobuild-specs/issues/2026-09-24-runquota-windows-owner-uid-is-zero-for-every-user.md`.
## A test that needs this value raises there, so the uid-scoping assertions
## FAIL on Windows, naming the reason, instead of either not compiling (which
## hid every other assertion in the file) or passing by comparing 0 with 0.

when defined(posix):
  import std/posix

type OwnerUidUndefined* = object of CatchableError

proc callerOwnerUid*(): int64 =
  when defined(posix):
    int64(getuid())
  else:
    raise newException(OwnerUidUndefined,
      "owner_uid has no Windows definition yet: the named-pipe peer is a " &
      "SID and nothing maps it to the owner_uid column (see reprobuild-specs/" &
      "issues/2026-09-24-runquota-windows-owner-uid-is-zero-for-every-user.md)")
