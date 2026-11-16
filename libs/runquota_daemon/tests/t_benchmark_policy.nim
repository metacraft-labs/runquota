## Who may take a benchmark lease, and the `[benchmark]` host-file table.
##
## Decisions pinned: the daemon's own user and root are always allowed; every
## other uid needs a listing (by uid or name) or a listed group; a peer with
## no credentials is refused (0 would read as root); the table's durations
## must be positive and its keys known. Each case names the change that fails
## it. NO MOCKS: pure functions over a real `PeerIdentity` value and the
## daemon's own reader.

import std/[options, unittest]

import runquota_daemon/benchmark_policy
import runquota_daemon/host_config
import runquota_ipc

proc peer(uid: uint64; gid = 65000'u64): PeerIdentity =
  PeerIdentity(kind: peerIdentityUser, userId: uid, groupId: gid)

suite "benchmark authorisation":
  test "a stranger is refused (mutation: allow everyone)":
    check not benchmarkAllowed(peer(54321), 1000, @[], @[])
  test "the daemon's own user and root are allowed":
    check benchmarkAllowed(peer(1000), 1000, @[], @[])
    check benchmarkAllowed(peer(0), 1000, @[], @[])
  test "a listed uid is allowed, an unlisted one is not":
    check benchmarkAllowed(peer(54321), 1000, @["54321"], @[])
    check not benchmarkAllowed(peer(54322), 1000, @["54321"], @[])
  test "an unknown group names nobody":
    check not benchmarkAllowed(peer(54321), 1000, @[], @["no-such-group-rq"])
  test "a peer without credentials is refused even as uid 0":
    var p = peer(0)
    p.kind = peerIdentityUnavailable
    check not benchmarkAllowed(p, 0, @["0"], @[])

suite "[benchmark] table":
  const Head = "schema = \"runquota.host-config.v1\"\n[benchmark]\n"
  test "keys parse":
    let host = parseHostConfig(Head & "allowed-users = [\"alice\", \"7\"]\n" &
      "allowed-groups = [\"bench\"]\nmax-queue-wait = \"90s\"\n" &
      "max-hold = \"2m\"\n", "t.toml")
    check host.benchmarkAllowedUsers == @["alice", "7"]
    check host.benchmarkAllowedGroups == @["bench"]
    check host.benchmarkMaxQueueWaitMillis == some(90_000'i64)
    check host.benchmarkMaxHoldMillis == some(120_000'i64)
  test "a zero or malformed bound is refused (a zero bound would disable it)":
    expect HostConfigError: discard parseHostConfig(Head & "max-hold = \"0s\"\n", "t")
    expect HostConfigError: discard parseHostConfig(Head & "max-hold = 5\n", "t")
  test "an unknown key is refused":
    expect HostConfigError: discard parseHostConfig(Head & "x = \"1s\"\n", "t")
  test "absent keys leave the defaults to the daemon":
    let host = parseHostConfig(Head, "t")
    check host.benchmarkMaxHoldMillis.isNone
