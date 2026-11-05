## Who may retire a daemon, and when a request leaves it running.
##
## WHY THIS EXISTS. A daemon from a replaced install kept serving the new one
## because nothing could ask it to make way
## (reprobuild-specs/RunQuota-Host-Configuration.md, "A daemon from another
## build makes way"). `RetireDaemon` is that request, and ending the process
## is what it does, so the decision table matters as much as the mechanism:
##
## * a peer that is not the daemon's own principal is REFUSED, and so is one
##   whose credentials the transport could not report -- on a host-wide
##   endpoint either would let anyone end the coordinator for everyone;
## * a request naming the image the daemon runs leaves it CURRENT;
## * any other image, or none (`runquota daemon stop`), RETIRES it -- and so
##   does a daemon that could not digest itself, which cannot show it is the
##   build the client would start.
##
## Remove the owner comparison from `retirementAnswer` and the refusal cases
## fail; drop the digest comparison and the "current" case does.
##
## NO MOCKS. The decision proc `handleRequest` calls, on a daemon value and
## on peer identities built the way the transport builds them from this
## process's real credentials. The mechanism -- draining, the refusal of new
## connections, the exit -- is driven against a real `runquotad` by
## `tests/integration/t_daemon_retirement.nim`.

import std/[options, os, unittest]

import runquota_daemon {.all.}
import runquota_ipc
import runquota_protocol

proc selfPeer(): PeerIdentity =
  ## This process as the transport would report it.
  let principal = currentProcessPrincipal()
  doAssert principal.isSome, "this process's own principal is unreadable"
  case principal.get.kind
  of opkSid:
    PeerIdentity(kind: peerIdentityUser, sid: principal.get.principal)
  of opkUid:
    PeerIdentity(kind: peerIdentityUser, userId: uint64(principal.get.ownerId))

proc otherPeer(): PeerIdentity =
  ## A different principal of the same kind.
  result = selfPeer()
  if result.sid.len > 0:
    result.sid = result.sid & "1"
  else:
    result.userId = result.userId + 1'u64

const
  RunningImage = "sha256:" &
    "1111111111111111111111111111111111111111111111111111111111111111"
  OtherImage = "sha256:" &
    "2222222222222222222222222222222222222222222222222222222222222222"

suite "RetireDaemon decision":

  test "a request naming the running image leaves the daemon current":
    let daemon = RunQuotaDaemon(imageDigest: RunningImage)
    let answer = daemon.retirementAnswer(selfPeer(),
      RetireDaemonMessage(expectedImageDigest: RunningImage))
    check answer.decision == retirementCurrent
    check answer.daemonImageDigest == RunningImage
    check answer.daemonProcessId == uint64(getCurrentProcessId())

  test "a request naming another image retires the daemon":
    let daemon = RunQuotaDaemon(imageDigest: RunningImage)
    let answer = daemon.retirementAnswer(selfPeer(),
      RetireDaemonMessage(expectedImageDigest: OtherImage))
    check answer.decision == retirementRetiring
    check answer.daemonImageDigest == RunningImage
    # No connection reached it over an endpoint here, so none is "other".
    check answer.otherConnections == 0'u32
    check answer.detail == "exits when this connection closes"

  test "an unconditional request retires the daemon whatever it runs":
    let daemon = RunQuotaDaemon(imageDigest: RunningImage)
    let answer = daemon.retirementAnswer(selfPeer(), RetireDaemonMessage())
    check answer.decision == retirementRetiring

  test "a daemon that could not digest itself retires":
    let daemon = RunQuotaDaemon(imageDigest: "")
    let answer = daemon.retirementAnswer(selfPeer(),
      RetireDaemonMessage(expectedImageDigest: OtherImage))
    check answer.decision == retirementRetiring
    check answer.daemonImageDigest == ""

  test "another principal is refused":
    let daemon = RunQuotaDaemon(imageDigest: RunningImage)
    let answer = daemon.retirementAnswer(otherPeer(),
      RetireDaemonMessage(expectedImageDigest: OtherImage))
    check answer.decision == retirementRefused
    check answer.detail ==
      "only the principal this runquotad runs as may retire it"

  test "a peer whose credentials are unavailable is refused":
    let daemon = RunQuotaDaemon(imageDigest: RunningImage)
    let answer = daemon.retirementAnswer(
      PeerIdentity(kind: peerIdentityUnavailable), RetireDaemonMessage())
    check answer.decision == retirementRefused
    check answer.detail ==
      "only the principal this runquotad runs as may retire it " &
        "(the peer's credentials are unavailable)"
