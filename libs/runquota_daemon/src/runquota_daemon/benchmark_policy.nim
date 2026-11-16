## Who may take a `purpose = benchmark` lease on a host-wide daemon.
##
## A benchmark lease stops every other grant while it is queued or held (see
## `RunQuota-Protocol-And-Client-Libraries.md`, "Benchmark Isolation And
## Topology"). With one daemon serving every user of the host, that power is
## not free: any user could halt everyone else's builds. So the daemon
## authorises it from the peer credentials of the requesting connection,
## never from anything the client states:
##
## * the daemon's own user and root are always allowed (a workstation's
##   single user keeps working with no configuration);
## * anybody else must be named in the host file's `[benchmark]
##   allowed-users` or be in one of its `allowed-groups`.
##
## Standard library plus `runquota_ipc` only, so it can be unit-tested
## without a daemon.

import std/strutils

when defined(posix):
  import std/posix

import runquota_ipc

proc peerIsDaemonOwnerOrRoot(peer: PeerIdentity; daemonOwnerId: int64): bool =
  if peer.kind == peerIdentityUnavailable:
    return false
  when defined(posix):
    peer.userId == 0'u64 or int64(peer.userId) == daemonOwnerId
  else:
    int64(peer.userId) == daemonOwnerId

when defined(posix):
  proc posixUserName(uid: uint64): string =
    let entry = getpwuid(Uid(uid))
    if entry == nil: "" else: $entry.pw_name

  proc posixInGroup(peer: PeerIdentity; groupName, userName: string): bool =
    let group = getgrnam(groupName.cstring)
    if group == nil:
      return false
    if uint64(group.gr_gid) == peer.groupId:
      return true
    let user = getpwuid(Uid(peer.userId))
    if user != nil and uint64(user.pw_gid) == uint64(group.gr_gid):
      return true
    if userName.len == 0 or group.gr_mem == nil:
      return false
    var i = 0
    while group.gr_mem[i] != nil:
      if $group.gr_mem[i] == userName:
        return true
      inc i
    false

proc benchmarkAllowed*(peer: PeerIdentity; daemonOwnerId: int64;
                       allowedUsers, allowedGroups: seq[string]): bool =
  ## True when `peer` may request `purpose = benchmark`. A peer whose
  ## credentials the transport could not report is refused: 0 is root, and
  ## privilege must never be granted to an unknown caller.
  if peer.kind == peerIdentityUnavailable:
    return false
  if peer.peerIsDaemonOwnerOrRoot(daemonOwnerId):
    return true
  when defined(posix):
    let userName = posixUserName(peer.userId)
    for entry in allowedUsers:
      if entry == $peer.userId or (userName.len > 0 and entry == userName):
        return true
    for group in allowedGroups:
      if peer.posixInGroup(group, userName):
        return true
    false
  else:
    for entry in allowedUsers:
      if peer.sid.len > 0 and cmpIgnoreCase(entry, peer.sid) == 0:
        return true
    false
