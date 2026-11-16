## `UpdateSessionGroup` changes a group's attributes only for the owner of the
## group, and a refusal changes nothing (RunQuota protocol, "Session Groups").
##
## WHY THIS IS A UNIT TEST AS WELL AS AN INTEGRATION CASE. The integration case
## `update_refused_for_other_uid` in `tests/integration/t_session_group_admission`
## connects as a second kernel uid through a Linux user namespace. macOS has no
## user namespaces, and a second uid there needs root, which a test must not
## assume. This file therefore pins the daemon's owner decision on every host
## and is the whole of that decision's coverage where the integration case
## cannot run (the integration case prints a capability record there).
##
## NO MOCKS. A real `RunQuotaDaemon` object and the production
## `joinSessionGroup` / `updateSessionGroup` procs. The only hand-built thing is
## each caller's `PeerIdentity`, which in the daemon comes from `SO_PEERCRED`
## (Linux) or `getpeereid` (macOS): a test process cannot connect as two
## different uids without root.
##
## Each case names the change that makes it fail.

import std/[os, strutils, tables, unittest]

import runquota_core
import runquota_ipc
import runquota_daemon {.all.}
import runquota_daemon/host_config
import runquota_protocol

const GiB = 1024'u64 * 1024'u64 * 1024'u64

const
  alice = 1001'u64
  bob = 1002'u64

var scratchRoots: seq[string] = @[]

proc userPeer(uid: uint64): PeerIdentity =
  PeerIdentity(kind: peerIdentityUser, processId: 4242'u64, userId: uid,
    groupId: uid)

proc testDaemon(): RunQuotaDaemon =
  let root = getTempDir() / ("runquota-group-owner-" &
    $getCurrentProcessId())
  removeDir(root)
  createDir(root)
  scratchRoots.add(root)
  var config = DaemonConfig(
    daemonId: 1'u64,
    cpuSlots: milliCpu(4000),
    memoryBytes: bytes(2'u64 * GiB),
    builtinCpuSlots: milliCpu(4000),
    builtinMemoryBytes: bytes(2'u64 * GiB),
    ioSlots: 8'u32,
    machines: initTable[string, MachineCapacity](),
    cpuShareGroups: initTable[string, CpuShareGroup](),
    namedPoolCaps: initTable[string, uint32](),
    version: "test",
    pressureSource: pressureSourceUnavailable,
    estimateDbPath: root / "estimates.db",
    estimateQueueCapacity: 8,
    observationDbPath: root / "observations.db",
    hostConfigPath: root / "runquotad.toml")
  let host = readHostConfig(config.hostConfigPath)
  config.resolveBudget(host)
  config.hostConfigSource = host.sourcePath
  result = initDaemon(config)

proc groupDecl(name: string; priority: SessionPriority;
              deadline: uint64): SessionGroupDeclaration =
  SessionGroupDeclaration(name: name, priorityPresent: true,
    priority: priority, cacheDeadlinePresent: true,
    cacheDeadlineUnixMillis: deadline)

proc updateGroup(daemon: var RunQuotaDaemon; peer: PeerIdentity; group: string;
            priority: SessionPriority): (bool, Diagnostic,
                                         SessionGroupUpdatedMessage) =
  var answer: SessionGroupUpdatedMessage
  var refusal: Diagnostic
  let message = UpdateSessionGroupMessage(group: group,
    priorityPresent: true, priority: priority,
    cacheDeadlineChange: cacheDeadlineClear)
  let ok = daemon.updateSessionGroup(peer, message, answer, refusal)
  (ok, refusal, answer)

suite "update_session_group_owner":
  test "another uid is refused and the attributes are unchanged":
    # Fails if the owner check is dropped (the second user would then be
    # answered as the owner, or would create a group under its own key).
    var daemon = testDaemon()
    let key = daemon.joinSessionGroup(userPeer(alice),
      groupDecl("shared-name", sessionPriorityNormal, 600_000'u64))
    let (ok, refusal, _) = daemon.updateGroup(userPeer(bob), "shared-name",
      sessionPriorityUrgent)
    check not ok
    check "belongs to another user" in refusal.message
    check daemon.sessionGroups[key].priority == sessionPriorityNormal
    check daemon.sessionGroups[key].cacheDeadlinePresent
    check daemon.sessionGroups[key].cacheDeadlineUnixMillis == 600_000'u64

  test "the owner may change its own group":
    # Fails if the owner is refused too (a check that always refuses).
    var daemon = testDaemon()
    let key = daemon.joinSessionGroup(userPeer(alice),
      groupDecl("mine", sessionPriorityNormal, 600_000'u64))
    let (ok, _, answer) = daemon.updateGroup(userPeer(alice), "mine",
      sessionPriorityUrgent)
    check ok
    check answer.ownerUid == alice
    check daemon.sessionGroups[key].priority == sessionPriorityUrgent
    check not daemon.sessionGroups[key].cacheDeadlinePresent

  test "two owners may hold the same group name independently":
    # Fails if a group is keyed by name alone: bob's update would then reach
    # alice's group, or alice's would be refused as bob's.
    var daemon = testDaemon()
    let aliceKey = daemon.joinSessionGroup(userPeer(alice),
      groupDecl("same", sessionPriorityLow, 0'u64))
    let bobKey = daemon.joinSessionGroup(userPeer(bob),
      groupDecl("same", sessionPriorityLow, 0'u64))
    check aliceKey != bobKey
    let (ok, _, _) = daemon.updateGroup(userPeer(bob), "same", sessionPriorityHigh)
    check ok
    check daemon.sessionGroups[bobKey].priority == sessionPriorityHigh
    check daemon.sessionGroups[aliceKey].priority == sessionPriorityLow

  test "a connection without credentials owns nothing":
    var daemon = testDaemon()
    let key = daemon.joinSessionGroup(userPeer(alice),
      groupDecl("mine", sessionPriorityNormal, 0'u64))
    let (ok, refusal, _) = daemon.updateGroup(PeerIdentity(), "mine",
      sessionPriorityUrgent)
    check not ok
    check "no peer credentials" in refusal.message
    check daemon.sessionGroups[key].priority == sessionPriorityNormal

for root in scratchRoots:
  removeDir(root)
