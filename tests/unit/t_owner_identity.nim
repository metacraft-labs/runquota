## The owner id: what `executions.owner_uid` holds on each platform, and
## that the daemon and the client derive it the same way.
##
## On Windows the id is the SHA-256 of the SID string, first eight bytes
## big-endian, top two bits replaced by `01` (`runquota_core/owner_id`). The
## vectors below were computed OUTSIDE this code base, with `sha256sum`:
##
##     printf '%s' "$SID" | sha256sum | cut -c1-16
##
## then `(x & (2^62 - 1)) | 2^62`. A derivation only ever compared with
## itself would agree with itself while being wrong -- and this one is
## persisted and merged across hosts, so being wrong once is permanent.
##
## The Windows-only arm then checks THIS process's id against the SID
## `whoami /user` reports: a second reader of the same token, in a different
## program, so "the client's Hello and the daemon's peer read agree" is
## tested against an account source RunQuota did not write.

import std/[options, unittest]

import runquota_core/owner_id
import runquota_ipc

when defined(posix):
  import std/posix
when defined(windows):
  import std/[os, osproc, strutils]

const vectors = [
  ("S-1-5-18", 6427559974503301031'i64),
  ("S-1-5-21-3623811015-3361044348-30300820-1013", 8271043905947806243'i64),
  ("S-1-5-21-1004336348-1177238915-682003330-512", 8051579314423586722'i64)]

suite "owner_identity":
  test "a SID's owner id matches an independent SHA-256":
    for (sid, expected) in vectors:
      check ownerIdFromSid(sid) == expected

  test "Windows ids are positive, never 0, and above every POSIX uid":
    for (sid, _) in vectors:
      let id = ownerIdFromSid(sid)
      check id > 0
      check id >= sidOwnerIdFloor
      check id > maxUidOwnerId
      check isSidOwnerId(id)
      check not isUidOwnerId(id)
    # The ranges are disjoint by construction, not by luck.
    check maxUidOwnerId < sidOwnerIdFloor
    check isUidOwnerId(0)
    check isUidOwnerId(maxUidOwnerId)
    check not isSidOwnerId(maxUidOwnerId)

  test "the id depends on the account, not on how its prefix was spelled":
    check ownerIdFromSid("s-1-5-18") == ownerIdFromSid("S-1-5-18")
    check ownerIdFromSid("S-1-5-21-1-2-3-1001") !=
      ownerIdFromSid("S-1-5-21-1-2-3-1002")

  test "a peer's owner comes from its credentials, and none means none":
    let windowsPeer = PeerIdentity(kind: peerIdentityProcess, processId: 7,
      userId: uint64(ownerIdFromSid("S-1-5-18")), groupId: 0,
      sid: "S-1-5-18")
    check ownerIdOf(windowsPeer) == some(ownerIdFromSid("S-1-5-18"))
    check ownerPrincipalOf(windowsPeer).get.kind == opkSid
    check ownerPrincipalOf(windowsPeer).get.principal == "S-1-5-18"

    let posixPeer = PeerIdentity(kind: peerIdentityUser, processId: 0,
      userId: 1000, groupId: 1000, sid: "")
    check ownerIdOf(posixPeer) == some(1000'i64)
    check ownerPrincipalOf(posixPeer).get.kind == opkUid
    check ownerPrincipalOf(posixPeer).get.principal == "1000"

    # NO CREDENTIAL IS NO OWNER -- not uid 0, which is root. A pid alone
    # (what a named pipe reports before its token is read) is not one.
    let pidOnly = PeerIdentity(kind: peerIdentityUnavailable, processId: 7,
      userId: 0, groupId: 0, sid: "")
    check ownerIdOf(pidOnly).isNone
    check ownerPrincipalOf(pidOnly).isNone

  test "this process's owner id is what the platform says this account is":
    let mine = currentProcessOwnerId()
    check mine.isSome
    when defined(posix):
      check mine == some(int64(getuid()))
      check currentProcessPrincipal().get.principal == $getuid()
    elif defined(windows):
      # `whoami /user /fo csv /nh` prints `"domain\user","S-1-5-..."`.
      let whoami = getEnv("SystemRoot", "C:\\Windows") / "System32" /
        "whoami.exe"
      let (output, code) = execCmdEx(quoteShell(whoami) &
        " /user /fo csv /nh")
      check code == 0
      let fields = output.strip().split(',')
      check fields.len == 2
      if fields.len == 2:
        let sid = fields[1].strip(chars = {'"', ' '})
        check sid.startsWith("S-1-")
        check currentProcessPrincipal().get.principal == sid.toUpperAscii
        check mine == some(ownerIdFromSid(sid))
        check mine.get >= sidOwnerIdFloor
      # THE NAME resolves for the account this process runs as, which is
      # the account `whoami` names -- compared case-insensitively, because
      # `whoami` lower-cases it and `LookupAccountSidW` does not.
      let name = resolveOwnerName(currentProcessPrincipal().get)
      check name.isSome
      if name.isSome and fields.len == 2:
        check name.get.toLowerAscii ==
          fields[0].strip(chars = {'"', ' '}).toLowerAscii
