## The integer that says whose execution a row records: ``owner_uid``.
##
## One host-wide ``runquotad`` holds every user's executions in one store, so
## every row carries an owner, taken from the connection's PEER CREDENTIALS
## and never from anything the client declares. This module is the one
## place that says what that integer IS on each platform, so the daemon (from
## a peer's credentials) and the client (from its own, for the Hello
## ``userId``) cannot compute it two different ways.
##
## * **POSIX: the uid.** The kernel reports it for the peer and ``getuid()``
##   reports it for this process. A ``uid_t`` is 32 bits, so every POSIX
##   owner id lies in ``0 .. 2^32 - 1``.
## * **Windows: a hash of the SID string.** A named pipe reports the
##   client's pid, the daemon opens that process's token, and the token's
##   user SID is the principal. A SID is not an integer, so the id is the
##   SHA-256 of its canonical string form (``S-1-5-21-...``, as
##   ``ConvertSidToStringSidW`` renders it), first eight bytes read
##   big-endian, with the top two bits replaced by ``01``:
##
##   ``ownerId = (be64(sha256(sid)[0 ..< 8]) and (2^62 - 1)) or 2^62``
##
##   An operator can reproduce it with nothing but ``sha256sum``: take the
##   first 16 hex digits of ``printf '%s' "$SID" | sha256sum``, clear the top
##   two bits and set bit 62.
##
## WHY A HASH AND NOT A MAPPING. The Cygwin/MSYS scheme (``0x30000 + RID``
## and friends) needs to know which domain a SID belongs to and is only
## unambiguous within one machine and its primary domain. A hash needs no
## lookup, no domain rules and no state: both ends compute it from the SID
## alone, and it is the same on every host for the same account.
##
## WHY BIT 62. Every Windows id is ``>= 2^62`` and every POSIX id is
## ``< 2^32``, so the two ranges can never meet: a store merged from a Linux
## host and a Windows host cannot mistake one platform's owner for the
## other's, and the ``users`` table's check constraint enforces the split.
## The result is a POSITIVE signed 64-bit integer (bit 63 is clear), so it
## survives SQLite's ``integer`` and every ``int64`` on the path, and it is
## NEVER 0: ``0`` is root, and a Windows owner that read as root is the
## defect this module exists to end.
##
## A COLLISION IS POSSIBLE AND IS REFUSED, NOT MERGED. 62 bits make it
## vanishingly unlikely -- the birthday bound for a thousand accounts is
## about one in 10^13 -- but two principals sharing an id would share a scope,
## so the ``users`` table records the SID each id was derived from and every
## writer that finds a different principal under an existing id refuses
## loudly (see ``runquota_observation_store`` and ``docs/database.md``).
##
## SHA-256 because it is the stable cryptographic hash RunQuota already
## carries (``runquota_core/sha256``, FIPS 180-4, tested against the
## published vectors): the id is persisted and merged across hosts, so the
## function must never change, and a non-cryptographic hash would make a
## deliberately colliding account name cheap to find.

import std/strutils

import ./sha256

const
  sidOwnerIdFloor* = 1'i64 shl 62
    ## The smallest Windows owner id. Every id derived from a SID is
    ## ``>= sidOwnerIdFloor``; no POSIX uid ever is.
  maxUidOwnerId* = 4_294_967_295'i64
    ## The largest POSIX owner id: ``uid_t`` is 32 bits.

proc ownerIdFromSid*(sid: string): int64 =
  ## The owner id of the Windows principal ``sid``, as the module header
  ## defines it. ``sid`` is the string form ``ConvertSidToStringSidW``
  ## returns; it is upper-cased first so a caller that spelled the prefix
  ## ``s-1-...`` does not mint a second id for the same account.
  let digest = sha256Hex(sid.toUpperAscii)
  var prefix = 0'u64
  for i in 0 ..< 16:
    prefix = (prefix shl 4) or uint64(parseHexInt($digest[i]))
  let bounded = (prefix and (uint64(sidOwnerIdFloor) - 1'u64)) or
    uint64(sidOwnerIdFloor)
  int64(bounded)

proc isSidOwnerId*(ownerId: int64): bool =
  ## True for an id in the Windows range.
  ownerId >= sidOwnerIdFloor

proc isUidOwnerId*(ownerId: int64): bool =
  ## True for an id in the POSIX range.
  ownerId >= 0'i64 and ownerId <= maxUidOwnerId
