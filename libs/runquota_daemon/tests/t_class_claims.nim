## The class-socket rule and the class-socket path, as pure functions:
## `runquota_daemon/class_claims.classClaim` and
## `runquota_ipc.classSocketPathFor` / `classEndpointProblem`.
##
## Both are written once for every platform -- the macOS and Windows daemons
## use the same rule and the same derivation -- so their tables are checked
## here for every platform's endpoints, on whichever host runs the suite.
## `tests/integration/t_class_sockets` holds the rule to real sockets and
## real accounts.
##
## Each case names the change that makes it fail. NO MOCKS: pure functions.

import std/[options, strutils, unittest]

import runquota_daemon
import runquota_ipc

proc served(claim: ClassClaim; className: string): bool =
  ## Accepted, with the group getting `className`.
  claim.refusal.len == 0 and claim.className == className

let linuxEndpoint = Endpoint(kind: endpointUnixSocket,
  path: "/run/runquota/runquotad.sock",
  rendezvousPath: "/run/runquota/runquotad.sock")
let declaredClasses = @["ci", "gpu"]

suite "class claims":
  test "the shared socket serves no class and names the class's socket":
    # Fails when the shared socket accepts a class block (the rule before
    # class sockets).
    let declaredClaim = classClaim("", "ci", none(string), declaredClasses,
      linuxEndpoint)
    check "/run/runquota/class-ci.sock" in declaredClaim.refusal
    let undeclared = classClaim("", "build", none(string), declaredClasses,
      linuxEndpoint)
    check "declares no class build" in undeclared.refusal
    check "[reservation.build]" in undeclared.refusal
    check "unset RUNQUOTA_CLASS" in undeclared.refusal
    # No class: served, with no class, into a new group or an unclassed one.
    check classClaim("", "", none(string), declaredClasses, linuxEndpoint).served("")
    check classClaim("", "", some(""), declaredClasses, linuxEndpoint).served("")
    # Joining a classed group from the shared socket: refused, naming it.
    let join = classClaim("", "", some("ci"), declaredClasses, linuxEndpoint)
    check "class ci" in join.refusal
    check "/run/runquota/class-ci.sock" in join.refusal

  test "a class socket gives its class and refuses another":
    # Fails when a connection on a class socket is not held to its class.
    check classClaim("ci", "", none(string), declaredClasses, linuxEndpoint).served("ci")
    check classClaim("ci", "ci", none(string), declaredClasses, linuxEndpoint).served("ci")
    check classClaim("ci", "ci", some("ci"), declaredClasses, linuxEndpoint).served("ci")
    let other = classClaim("ci", "gpu", none(string), declaredClasses, linuxEndpoint)
    check "gpu" in other.refusal
    check "ci" in other.refusal
    # Joining a group of another class, or of none, from a class socket.
    check "class gpu" in classClaim("ci", "", some("gpu"), declaredClasses,
      linuxEndpoint).refusal
    check "has no class" in classClaim("ci", "", some(""), declaredClasses,
      linuxEndpoint).refusal

suite "class socket paths":
  test "replace the endpoint's last component, on every platform":
    # Fails when the derivation changes for one platform's endpoints: the
    # table of the design (provisioned Linux and macOS, Windows, per-user,
    # an explicit --socket).
    check classSocketPathFor("/run/runquota/runquotad.sock", "ci",
      endpointUnixSocket) == "/run/runquota/class-ci.sock"
    check classSocketPathFor("/var/run/runquota/runquotad.sock", "ci",
      endpointUnixSocket) == "/var/run/runquota/class-ci.sock"
    check classSocketPathFor(r"\\.\pipe\runquota\runquotad", "ci",
      endpointNamedPipe) == r"\\.\pipe\runquota\class-ci"
    check classSocketPathFor("/tmp/runquota-1000/runquotad.sock", "ci",
      endpointUnixSocket) == "/tmp/runquota-1000/class-ci.sock"
    check classSocketPathFor("rq.sock", "ci", endpointUnixSocket) ==
      "class-ci.sock"
    # The spelling of the directory is kept (an ancestor link and `..`).
    check classSocketPathFor("/a/link/../ep/d.sock", "ci",
      endpointUnixSocket) == "/a/link/../ep/class-ci.sock"
    # A Windows pipe mapped from a filesystem path: the class socket's path
    # in that directory, which `endpointForPath` maps onto a pipe of its own.
    check classSocketPathFor(r"\\.\pipe\runquota-0123", "ci",
      endpointNamedPipe, r"C:\work\rq.sock") == r"C:\work\class-ci.sock"

  test "a path that does not fit is refused, naming it and its length":
    # Fails when an overlong path is bound or dialled anyway (it would be
    # cut by the kernel to another path).
    let longest = "/var/run/runquota/" & classSocketName(repeat('c', 64))
    check longest.len == 93
    check classEndpointProblem(longest, endpointUnixSocket, 104) == ""
    let tooLong = "/" & repeat('d', 90) & "/" & classSocketName("ci")
    let problem = classEndpointProblem(tooLong, endpointUnixSocket, 104)
    check tooLong in problem
    check $tooLong.len in problem
    check classEndpointProblem(tooLong, endpointUnixSocket, 200) == ""
    check classEndpointProblem(r"\\.\pipe\" & repeat('p', 300),
      endpointNamedPipe) != ""
