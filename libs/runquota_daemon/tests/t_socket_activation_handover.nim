## The `sd_listen_fds(3)` decision table of `socketActivationFrom`.
##
## `tests/integration/t_socket_activation.nim` hands a real daemon a real
## socket; this covers the cases a process cannot be started under without
## forging its own pid: variables addressed to ANOTHER process are ignored
## (they were inherited, not handed over), and a hand-over the daemon cannot
## read -- no descriptor, several without names, two shared ones -- is a
## refusal rather than a silent bind of a second socket
## (reprobuild-pm `spec/RunQuota-Host-Configuration.md`, "Socket activation
## (systemd)"). Pure function, no fakes.

import std/[strutils, unittest]

import runquota_daemon

const ownPid = 4242

suite "socket activation hand-over":
  test "no LISTEN_PID, or one naming another process, is an ordinary start":
    for (pid, has) in [("", false), ("4243", true), ("garbage", true),
                       ("", true)]:
      let decision = socketActivationFrom(pid, "1", has, ownPid)
      check not decision.requested
      check decision.refusal.len == 0

  test "LISTEN_FDS=1 addressed to this process serves descriptor 3":
    let decision = socketActivationFrom("4242", "1", true, ownPid)
    check decision.requested
    check decision.refusal.len == 0
    check decision.fd == sdListenFdsStart
    check sdListenFdsStart == 3

  test "any other LISTEN_FDS addressed to this process is refused":
    for count in ["0", "2", "-1", "", "one"]:
      let decision = socketActivationFrom("4242", count, true, ownPid)
      checkpoint "LISTEN_FDS=" & count & ": " & decision.refusal
      check decision.requested
      check "LISTEN_FDS" in decision.refusal

  test "several descriptors are named: the shared one and class-<class>":
    # Fails when a class socket systemd hands over is taken for the shared
    # one, or the names are ignored.
    let decision = socketActivationFrom("4242", "3", true, ownPid,
      "class-ci:runquotad:class-gpu")
    check decision.requested
    check decision.refusal.len == 0
    check decision.fd == sdListenFdsStart + 1
    check decision.classFds == @[(className: "ci", fd: 3),
      (className: "gpu", fd: 5)]

  test "unnamed, twice-shared, class-only and badly named hand-overs are refused":
    for (count, names) in [("2", ""), ("2", "runquotad"),
                           ("2", "runquotad:other"),
                           ("1", "class-ci"), ("2", "class-ci:class-gpu"),
                           ("2", "runquotad:class-c.i"),
                           ("3", "runquotad:class-ci:class-ci")]:
      let decision = socketActivationFrom("4242", count, true, ownPid, names)
      checkpoint "LISTEN_FDS=" & count & " LISTEN_FDNAMES=" & names & ": " &
        decision.refusal
      check decision.requested
      check decision.refusal.len > 0
