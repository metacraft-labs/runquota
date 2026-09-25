## The `owner_uid` a daemon should record for THIS process's connections.
##
## On POSIX that is `getuid()`: runquotad takes it from the peer credentials
## of the connection, and the kernel's answer is the caller's real uid.
##
## On Windows it is the owner id of this process's token user SID -- the
## SHA-256 of the SID string with bit 62 set (`runquota_core/owner_id`) --
## because that is what runquotad derives from a named-pipe peer: the
## client's pid, that process's token, the token's user SID, the hash.
##
## Both come from `currentProcessOwnerId`, the helper the client itself uses
## for its Hello. That is not the tests grading the library against itself:
## the integration tests below compare it with what a REAL `runquotad`
## recorded from the peer credentials of a real connection -- a different
## process reading the other end's token -- and `tests/unit/t_owner_identity`
## pins the derivation against `whoami /user` and against owner ids computed
## by an independent SHA-256.

import std/options

import runquota_ipc

type OwnerUidUndefined* = object of CatchableError

proc callerOwnerUid*(): int64 =
  let owner = currentProcessOwnerId()
  if owner.isNone:
    raise newException(OwnerUidUndefined,
      "this process's owner id could not be read (no uid on this platform, " &
      "or the process token's user SID was unreadable)")
  owner.get

proc callerOwnerPrincipal*(): OwnerPrincipal =
  ## The principal `callerOwnerUid` is derived from: the uid, or the SID.
  let principal = currentProcessPrincipal()
  if principal.isNone:
    raise newException(OwnerUidUndefined,
      "this process's owner principal could not be read")
  principal.get
