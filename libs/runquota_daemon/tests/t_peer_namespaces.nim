## How the daemon reconciles a client's namespace claim with what the kernel
## shows of the connection's peer (`runquota_daemon/peer_namespaces`).
##
## No mocks: pure functions over procfs text, plus this process's own
## `/proc/self` files where the host has them. The end-to-end refusal of a
## lying client by a real daemon is in
## `tests/integration/t_foreign_namespace_client.nim`.

import std/[os, unittest]
import runquota_ipc
import runquota_protocol
import runquota_daemon/peer_namespaces

const
  HostMap = "         0          0 4294967295\n"
  ContainerMap = "         0    1000000 1000000000\n"

suite "peer namespace evidence":
  test "NSpid with one pid is the reader's pid namespace, more is nested":
    check pidEvidenceOfStatus("Name:\tsh\nNSpid:\t4242\nNSpgid:\t1\n") == neSame
    check pidEvidenceOfStatus("NSpid:\t4242\t1\n") == neForeign
    check pidEvidenceOfStatus("NSpid:\t4242\t17\t1\n") == neForeign
    # No line (a kernel before 4.1) or nothing read: no evidence.
    check pidEvidenceOfStatus("Name:\tsh\nPid:\t4242\n") == neUnknown
    check pidEvidenceOfStatus("") == neUnknown

  test "a uid_map like the daemon's own is its user namespace":
    check userEvidenceOfMaps(HostMap, "0 0 4294967295") == neSame
    check userEvidenceOfMaps(ContainerMap, HostMap) == neForeign
    check userEvidenceOfMaps("", HostMap) == neUnknown
    check userEvidenceOfMaps(HostMap, "") == neUnknown

  test "this process reads itself as in its own namespaces":
    when defined(linux):
      if fileExists("/proc/self/status"):
        let own = observePeerNamespaces(PeerIdentity(
          kind: peerIdentityProcess, processId: uint64(getCurrentProcessId())))
        check own.pid == neSame
        check own.user == neSame
    # A peer the transport named no process for gives no evidence.
    check observePeerNamespaces(PeerIdentity(kind: peerIdentityUser,
      userId: 1000)) == PeerNamespaces()

suite "judging a namespace claim":
  let both = NamespaceDifference(pid: true, user: true)
  let none = NamespaceDifference()
  let hostPeer = PeerNamespaces(pid: neSame, user: neSame)

  test "a host client that is its own peer cannot claim a pid namespace":
    let v = judgeNamespaces(NamespaceDifference(pid: true), hostPeer,
                            peerIsClient = true)
    check v.refusal.len > 0
    check judgeNamespaces(both, hostPeer, peerIsClient = true).refusal.len > 0

  test "a host client that is its own peer cannot claim a user namespace":
    let v = judgeNamespaces(NamespaceDifference(user: true), hostPeer,
                            peerIsClient = true)
    check v.refusal.len > 0

  test "an honest host client is read exactly as before":
    for isClient in [true, false]:
      let v = judgeNamespaces(none, hostPeer, peerIsClient = isClient)
      check v.refusal.len == 0
      check v.difference == none

  test "behind a forwarder the kernel cannot contradict the claim":
    # An incus proxy device's forwarder runs on the host: its namespaces
    # are the daemon's, and its pid is not the one the client reports.
    let v = judgeNamespaces(both, hostPeer, peerIsClient = false)
    check v.refusal.len == 0
    check v.difference == both

  test "kernel evidence of a foreign namespace stands without a claim":
    # A client that predates the tokens, connecting directly from a
    # container (a mounted socket).
    let v = judgeNamespaces(none, PeerNamespaces(pid: neForeign,
      user: neForeign), peerIsClient = false)
    check v.refusal.len == 0
    check v.difference == both

  test "a claim matching a foreign user namespace is accepted":
    # `unshare --user` alone: the peer is the client, in the daemon's pid
    # namespace but a child user namespace.
    let v = judgeNamespaces(NamespaceDifference(user: true),
      PeerNamespaces(pid: neSame, user: neForeign), peerIsClient = true)
    check v.refusal.len == 0
    check v.difference == NamespaceDifference(user: true)

  test "without evidence the claim is read as before":
    let v = judgeNamespaces(both, PeerNamespaces(), peerIsClient = true)
    check v.refusal.len == 0
    check v.difference == both
