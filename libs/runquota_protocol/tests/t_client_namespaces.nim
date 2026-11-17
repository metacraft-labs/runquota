## The namespace tokens a client's `Hello` carries
## (`runquota_protocol/client_namespaces`): how they are written, how a daemon
## reads them, and when a client counts as being in other namespaces.
##
## No mocks: pure functions, plus this process's own `/proc/self/ns` links
## where the host has them.

import std/[os, unittest]
import runquota_protocol

when defined(linux):
  import std/posix

suite "client namespaces in Hello":
  test "tokens are appended to the capabilities and read back":
    let ns = ClientNamespaces(pidNamespace: 4026532001'u64,
                              userNamespace: 4026532002'u64)
    let caps = withNamespaceTokens("m1-lease", ns)
    check caps == "m1-lease pidns=4026532001 userns=4026532002"
    check parseClientNamespaces(caps) == ns

  test "a client in the initial namespaces sends the Hello it always did":
    # Wire compatibility: every client on the host is in the kernel's
    # initial pid and user namespaces, and its capabilities stay the
    # bytes a daemon has always received.
    let host = ClientNamespaces(pidNamespace: InitialPidNamespace,
                                userNamespace: InitialUserNamespace)
    check withNamespaceTokens("m1-lease", host) == "m1-lease"
    check withNamespaceTokens("m1-lease", ClientNamespaces(
      pidNamespace: InitialPidNamespace, userNamespace: 4026532002'u64)) ==
      "m1-lease userns=4026532002"
    # The values a host's own `readlink /proc/self/ns/{pid,user}` prints.
    check InitialPidNamespace == 4026531836'u64
    check InitialUserNamespace == 4026531837'u64

  test "a Hello with tokens and one without both cross the codec":
    # The codec carries the capabilities as one opaque string, so a daemon
    # that predates the tokens decodes a new client's Hello unchanged, and
    # this daemon decodes an old client's Hello to no namespaces.
    for caps in ["m1-lease", "m1-lease pidns=4026532001 userns=4026532002"]:
      let hello = HelloMessage(clientName: "c", clientVersion: "0",
        minProtocolMajor: RqspProtocolMajor,
        maxProtocolMajor: RqspProtocolMajor, processId: 7, userId: 1000,
        desiredCapabilities: caps)
      var decoded: HelloMessage
      check decodeHello(encodeHello(hello), decoded)
      check decoded.desiredCapabilities == caps
      check decoded.userId == 1000'u64
      let own = ClientNamespaces(pidNamespace: InitialPidNamespace,
                                 userNamespace: InitialUserNamespace)
      let difference = parseClientNamespaces(decoded.desiredCapabilities)
        .differenceFrom(own)
      check difference == (if caps == "m1-lease": NamespaceDifference()
                           else: NamespaceDifference(pid: true, user: true))

  test "unknown namespaces add no token and read as unknown":
    check withNamespaceTokens("m1-lease", ClientNamespaces()) == "m1-lease"
    check withNamespaceTokens("", ClientNamespaces(pidNamespace: 7)) ==
      "pidns=7"
    check parseClientNamespaces("m1-lease") == ClientNamespaces()
    check parseClientNamespaces("") == ClientNamespaces()

  test "a malformed token reports nothing, and the first good one wins":
    check parseClientNamespaces("pidns= userns=x pidns=-3") ==
      ClientNamespaces()
    check parseClientNamespaces("pidns=12abc userns=99999999999999999999999") ==
      ClientNamespaces()
    check parseClientNamespaces("pidns=0 pidns=5 pidns=6 userns=8") ==
      ClientNamespaces(pidNamespace: 5, userNamespace: 8)
    check parseClientNamespaces("xpidns=5 pidnsx=6") == ClientNamespaces()

  test "a namespace differs only when both sides know it":
    let daemon = ClientNamespaces(pidNamespace: 1, userNamespace: 2)
    check differenceFrom(ClientNamespaces(pidNamespace: 1, userNamespace: 2),
      daemon) == NamespaceDifference(pid: false, user: false)
    check differenceFrom(ClientNamespaces(pidNamespace: 3, userNamespace: 2),
      daemon) == NamespaceDifference(pid: true, user: false)
    check differenceFrom(ClientNamespaces(pidNamespace: 1, userNamespace: 4),
      daemon) == NamespaceDifference(pid: false, user: true)
    # An old client (no tokens) is read exactly as before.
    check differenceFrom(ClientNamespaces(), daemon) == NamespaceDifference()
    # A daemon that cannot read its own namespaces compares nothing.
    check differenceFrom(ClientNamespaces(pidNamespace: 3, userNamespace: 4),
      ClientNamespaces()) == NamespaceDifference()

  test "this process reports the namespaces /proc/self/ns names":
    let own = currentNamespaces()
    when defined(linux):
      if dirExists("/proc/self/ns"):
        var info: Stat
        check stat("/proc/self/ns/pid", info) == 0
        check own.pidNamespace == uint64(info.st_ino)
        check stat("/proc/self/ns/user", info) == 0
        check own.userNamespace == uint64(info.st_ino)
        check expandSymlink("/proc/self/ns/pid") ==
          "pid:[" & $own.pidNamespace & "]"
      else:
        check own == ClientNamespaces()
    else:
      check own == ClientNamespaces()
