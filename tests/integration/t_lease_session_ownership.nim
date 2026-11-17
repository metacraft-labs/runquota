## A connection may act only in the sessions it registered, against a real
## private `runquotad`.
##
## WHAT IS GUARDED: `ReleaseLease`, `LeaseStarting`, `LeaseRunning`,
## `LeaseFinished`, `GrantNext`, `RequestLease`, `OfferCandidates` and
## `CloseSession` are each refused ("unknown session id") when they name a
## session another connection registered, and the victim's lease and session
## are left as they were. Session and lease ids are small sequential
## integers, and one host-wide daemon holds every user's sessions, so a
## frame-only check ("the lease belongs to the session the frame names")
## would let any participant end, finish or drain another user's work
## (RunQuota-Observation-Store.md §"Per-user records, host-wide capacity";
## RunQuota-Protocol-And-Client-Libraries.md §"Lease Messages",
## "Ownership"). Recorded as reprobuild-pm
## `issues/2026-11-16-a-connection-can-release-or-finish-a-lease-of-a-session-it-does-not-own.md`.
##
## MUTATION: make `registeredHere` in `runquota_daemon.nim` return true for
## any session, and the first forged frame (`LeaseStarting`) is accepted: the
## first `check refused` fails, and the victim's own `markStarting` then
## raises because its lease has been moved on without it.
##
## A finished lease stays releasable by its own connection after its session
## is closed (`CloseSession` leaves finished leases behind).
##
## NOT HERE, AND WHY: a second uid. This suite cannot become one, and the
## check is per connection, so two connections of one uid are the stronger
## case of the two: they share an owner, and are still refused.
##
## NO MOCKS: the built `runquotad`, a real socket, the real client library.
## The forged session and lease are the client library's own objects with the
## victim's ids written into them, which is all a hostile peer needs.

when defined(posix):
  import std/[os, osproc, strutils, unittest]

  import runquota_client
  import runquota_core
  import runquota_protocol
  import private_daemon_fixture

  const GiB = 1024'u64 * 1024'u64 * 1024'u64

  var
    root: string
    socket: string
    daemon: Process

  root = scratchDir("rqown")
  socket = root / "d.sock"
  daemon = launch(root, socket, privateEnv(socket),
    ["--cpu-milli", "4000", "--memory-bytes", $(16'u64 * GiB)])
  prerequisite awaitSocket(daemon, socket),
    daemon.startupContext("the daemon did not bind " & socket)
  putEnv("RUNQUOTA_ENDPOINT_SCOPE", "private")
  putEnv("RUNQUOTA_SOCKET", socket)
  delEnv("RUNQUOTA_SESSION")

  proc hostRequest(cpuMilli: uint32): ResourceRequest =
    resourceRequest("host", milliCpu(cpuMilli), bytes(1'u64 * GiB))

  template refusedAsUnknownSession(client: var RunQuotaClient;
                                   body: untyped) =
    var refused = false
    try:
      body
    except RunQuotaClientError:
      refused = true
    check refused
    check "unknown session id" in client.lastDiagnostic.message

  suite "a connection acts only in the sessions it registered":
    test "a finished lease is released after its session is closed":
      var client = connectDefault()
      defer: client.close()
      var session = client.registerSession("closer", "1")
      var lease = session.requestLease(hostRequest(1000))
      lease.markStarting()
      lease.markRunning()
      lease.finish(succeeded())
      session.closeSession()
      lease.release()
      check not lease.active

    test "another connection cannot touch a session's leases or close it":
      var client = connectDefault()
      defer: client.close()
      var session = client.registerSession("victim", "1")
      var lease = session.requestLease(hostRequest(1000))
      check lease.active

      var otherClient = connectDefault()
      defer: otherClient.close()
      var otherSession = otherClient.registerSession("peer", "1")
      var forged = otherSession
      forged.id = session.id
      var forgedLease = lease
      forgedLease.session = addr forged

      otherClient.refusedAsUnknownSession:
        forgedLease.markStarting()
      otherClient.refusedAsUnknownSession:
        forgedLease.markRunning()

      # The victim's own lifecycle still works, and the forged finish and
      # release below are tried against a running lease.
      lease.markStarting()
      lease.markRunning()

      var forgedRunning = lease
      forgedRunning.session = addr forged
      otherClient.refusedAsUnknownSession:
        forgedRunning.finish(succeeded())
      otherClient.refusedAsUnknownSession:
        forgedRunning.release()
      otherClient.refusedAsUnknownSession:
        discard forged.pollNextGrant()
      otherClient.refusedAsUnknownSession:
        discard forged.requestLease(hostRequest(1000))
      otherClient.refusedAsUnknownSession:
        discard forged.offerCandidates(@[toCandidate(1, hostRequest(1000))])
      otherClient.refusedAsUnknownSession:
        forged.closeSession()

      # Nothing moved: still exactly the victim's one lease, which its own
      # connection can finish and release, and its session close.
      check client.daemonStatus().activeLeases == 1'u32
      lease.finish(succeeded())
      lease.release()
      session.closeSession()
      otherSession.closeSession()

    test "a lease of another session of the same connection is still refused":
      # The frame-level check stays: a connection naming its own session
      # cannot act on a lease of a different session.
      var client = connectDefault()
      defer: client.close()
      var first = client.registerSession("first", "1")
      var second = client.registerSession("second", "1")
      var lease = first.requestLease(hostRequest(1000))
      var crossed = lease
      crossed.session = addr second
      var refused = false
      try:
        crossed.release()
      except RunQuotaClientError:
        refused = true
      check refused
      check "unknown lease id" in client.lastDiagnostic.message
      lease.release()
      first.closeSession()
      second.closeSession()

  stopOwned(daemon)
  removeDir(root)
else:
  echo "t_lease_session_ownership: POSIX only"
