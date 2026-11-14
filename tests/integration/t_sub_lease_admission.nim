## Sub-leases against a real private `runquotad`: the admission rules of
## `RequestSubLease`, driven through the Nim client library.
##
## WHAT IS GUARDED, each with the mutation that breaks it:
##
## 1. A sub-lease takes nothing from the host ledger. With a host budget of
##    4 slots filled by two 2-slot host leases, a 2-slot sub-lease of one of
##    them is granted, and the daemon still counts two active leases.
##    Mutations: charge sub-leases to the host as well (drop the early
##    return in `applyLeaseResourceUsage`) and the count is three; admit
##    sub-leases against the host budget (`fitsNow`) instead of the parent
##    and the full host holds the sub-lease back until the wait times out.
## 2. The width range is fitted to what the parent's other sub-leases leave:
##    a 1..4 request beside a 3-slot sibling gets 1.
## 3. A sub-lease whose minimum does not fit yet is queued, and granted when
##    a sibling releases. Mutation: deny instead of queueing and the waiting
##    request fails.
## 4. A queued sub-lease is denied when its parent is released.
## 5. Refusals: unknown parent and an invalid range (`invalid argument`, the
##    code the client falls back on), a minimum or memory larger than the
##    parent (`denied`, final).
## 6. A sub-lease of a benchmark lease is granted while the benchmark holds
##    the host in isolation.
## 7. Memory: a non-zero sub-lease memory is held against the parent's.
## 8. A sub-lease is asked for only on the connection that registered the
##    session it names.
##
## NOT HERE, AND WHY: the refusal of another owner's parent needs a second
## uid, which this suite cannot become; the owner comparison is the same
## `ownerKeyOf` the daemon uses for fairness between owners.
##
## NO MOCKS: the built `runquotad`, a real socket, the real client library.

when defined(posix):
  import std/[os, osproc, strutils, unittest]

  import runquota_client
  import runquota_core
  import runquota_protocol
  import daemon_binary
  import private_daemon_fixture

  const
    GiB = 1024'u64 * 1024'u64 * 1024'u64
    BudgetMilli = 4000

  var
    root: string
    socket: string
    daemon: Process

  root = scratchDir("rqsub")
  socket = root / "d.sock"
  daemon = launch(root, socket, privateEnv(socket),
    ["--cpu-milli", $BudgetMilli, "--memory-bytes", $(16'u64 * GiB)])
  prerequisite awaitSocket(daemon, socket),
    daemon.startupContext("the daemon did not bind " & socket)
  putEnv("RUNQUOTA_ENDPOINT_SCOPE", "private")
  putEnv("RUNQUOTA_SOCKET", socket)
  delEnv("RUNQUOTA_SESSION")

  proc hostLease(session: var RunQuotaSession; cpuMilli: uint32;
                 memory = 4'u64 * GiB): RunQuotaLease =
    session.requestLease(resourceRequest("host",
      milliCpu(cpuMilli), bytes(memory)))

  proc subLease(session: var RunQuotaSession; parent: RunQuotaLease;
                minMilli, prefMilli: uint32; memory = 0'u64;
                maxPolls = 500): RunQuotaLease =
    ## Bounded by default (500 polls of 20 ms and a round trip each): a
    ## defect that queues a grant forever fails the case instead of hanging
    ## the file until the runner's bound.
    session.requestSubLeaseWaiting(parent.id, "sub", "",
      milliCpu(minMilli), milliCpu(prefMilli), bytes(memory),
      pollMillis = 20, maxPolls = maxPolls)

  proc refusal(session: var RunQuotaSession; client: var RunQuotaClient;
               parent: LeaseId; minMilli, prefMilli: uint32;
               memory = 0'u64): Diagnostic =
    try:
      discard session.requestSubLeaseWaiting(parent, "sub", "",
        milliCpu(minMilli), milliCpu(prefMilli), bytes(memory), maxPolls = 1)
      result = diagnostic(diagOk, "granted")
    except RunQuotaClientError:
      result = client.lastDiagnostic

  suite "sub-lease admission":
    test "the daemon announces sub-leases":
      var client = connectDefault()
      defer: client.close()
      check client.supportsSubLeases()

    test "a sub-lease takes nothing from the host ledger":
      var client = connectDefault()
      defer: client.close()
      var session = client.registerSession("sub-test", "1")
      var parent = session.hostLease(2000)
      var other = client.registerSession("host-test", "1")
      var second = other.hostLease(2000)
      # The host is full now. Bounded wait: a daemon that admitted
      # sub-leases against the host budget would hold this one back.
      var sub = session.subLease(parent, 2000, 2000, maxPolls = 100)
      check sub.active
      check sub.resources.cpu.value == 2000'u32
      # It took nothing more from the host: still exactly two host leases,
      # and nothing left to grant.
      check client.daemonStatus().activeLeases == 2'u32
      var refused = false
      try:
        discard other.hostLease(1000)
      except RunQuotaClientError:
        refused = true
      check refused
      sub.release()
      # Releasing it gives the host nothing either.
      refused = false
      try:
        discard other.hostLease(1000)
      except RunQuotaClientError:
        refused = true
      check refused
      second.release()
      parent.release()
      other.closeSession()
      session.closeSession()

    test "the width range is fitted to what siblings leave":
      var client = connectDefault()
      defer: client.close()
      var session = client.registerSession("sub-test", "1")
      var parent = session.hostLease(4000)
      var first = session.subLease(parent, 1000, 3000)
      check first.resources.cpu.value == 3000'u32
      var second = session.subLease(parent, 1000, 4000)
      check second.resources.cpu.value == 1000'u32
      second.release()
      first.release()
      parent.release()
      session.closeSession()

    test "a sub-lease that does not fit yet waits for a sibling":
      var client = connectDefault()
      defer: client.close()
      var session = client.registerSession("sub-test", "1")
      var parent = session.hostLease(2000)
      var holder = session.subLease(parent, 2000, 2000)
      # A second connection waits for two slots of the same parent while
      # the first holds them; it is granted once they are released.
      var waiterClient = connectDefault()
      defer: waiterClient.close()
      var waiterSession = waiterClient.registerSession("sub-waiter", "1")
      var queuedOnce = false
      try:
        discard waiterSession.subLease(parent, 2000, 2000, maxPolls = 3)
      except RunQuotaClientError:
        queuedOnce = "timed out" in waiterClient.lastDiagnostic.message
      check queuedOnce
      holder.release()
      # The first request is still queued in the daemon; a GrantNext now
      # delivers it.
      var delivered = false
      for _ in 0 ..< 100:
        for grant in waiterSession.pollNextGrant():
          if not grant.queued and grant.lease.active:
            delivered = true
            var lease = grant.lease
            check lease.resources.cpu.value == 2000'u32
            lease.release()
        if delivered: break
        sleep(20)
      check delivered
      parent.release()
      waiterSession.closeSession()
      session.closeSession()

    test "a queued sub-lease is denied when its parent is released":
      var client = connectDefault()
      defer: client.close()
      var session = client.registerSession("sub-test", "1")
      var parent = session.hostLease(1000)
      var holder = session.subLease(parent, 1000, 1000)
      var waiterClient = connectDefault()
      defer: waiterClient.close()
      var waiterSession = waiterClient.registerSession("sub-waiter", "1")
      try:
        discard waiterSession.subLease(parent, 1000, 1000, maxPolls = 2)
      except RunQuotaClientError:
        discard
      # The parent goes while the holder still holds it and the second
      # request is queued behind the holder: that request can never be
      # granted now.
      parent.release()
      holder.release()
      var denied = false
      for _ in 0 ..< 100:
        for grant in waiterSession.pollNextGrant():
          if not grant.lease.active:
            denied = "parent lease" in grant.diagnostic.message
          else:
            var lease = grant.lease
            lease.release()
        if denied: break
        sleep(20)
      check denied
      waiterSession.closeSession()
      session.closeSession()

    test "refusals say whether the parent or the request is at fault":
      var client = connectDefault()
      defer: client.close()
      var session = client.registerSession("sub-test", "1")
      check session.refusal(client, leaseId(999_999), 1000, 1000).code ==
        diagInvalidArgument
      var parent = session.hostLease(2000, 2'u64 * GiB)
      check session.refusal(client, parent.id, 0, 1000).code ==
        diagInvalidArgument
      check session.refusal(client, parent.id, 2000, 1000).code ==
        diagInvalidArgument
      let wide = session.refusal(client, parent.id, 3000, 3000)
      check wide.code == diagDenied
      check "exceeds its parent's CPU" in wide.message
      let heavy = session.refusal(client, parent.id, 1000, 1000, 3'u64 * GiB)
      check heavy.code == diagDenied
      check "exceeds its parent's memory" in heavy.message
      parent.release()
      # A released parent is unknown; a finished one "is not running".
      check session.refusal(client, parent.id, 1000, 1000).code ==
        diagInvalidArgument
      session.closeSession()

    test "a sub-lease is refused on a session of another connection":
      # The sub-lease is created in the session it names, under that
      # session's owner, so only the connection that registered the session
      # may ask in it. Mutation: drop the connection check in the
      # `rqRequestSubLease` handler and the forged request is granted.
      var client = connectDefault()
      defer: client.close()
      var session = client.registerSession("sub-test", "1")
      var parent = session.hostLease(2000)
      var otherClient = connectDefault()
      defer: otherClient.close()
      var otherSession = otherClient.registerSession("sub-other", "1")
      var forged = otherSession
      forged.id = session.id
      let refused = forged.refusal(otherClient, parent.id, 1000, 1000)
      check refused.code == diagInvalidArgument
      check "unknown session id" in refused.message
      parent.release()
      otherSession.closeSession()
      session.closeSession()

    test "sub-lease memory is held against the parent's memory":
      var client = connectDefault()
      defer: client.close()
      var session = client.registerSession("sub-test", "1")
      var parent = session.hostLease(4000, 4'u64 * GiB)
      var first = session.subLease(parent, 1000, 1000, 3'u64 * GiB)
      check first.active
      # Three slots are still free but only 1 GiB of memory: a 2 GiB
      # sub-lease does not fit now, a 1 GiB one does.
      var fits = session.subLease(parent, 1000, 1000, 1'u64 * GiB)
      check fits.active
      check fits.resources.cpu.value == 1000'u32
      var waiterClient = connectDefault()
      defer: waiterClient.close()
      var waiterSession = waiterClient.registerSession("sub-waiter", "1")
      var waited = false
      try:
        discard waiterSession.subLease(parent, 1000, 1000, 1'u64 * GiB,
          maxPolls = 2)
      except RunQuotaClientError:
        waited = "timed out" in waiterClient.lastDiagnostic.message
      check waited
      # Ending the parent denies the queued request, which lets its session
      # close.
      parent.release()
      fits.release()
      first.release()
      for _ in 0 ..< 50:
        if waiterSession.pollNextGrant().len > 0: break
        sleep(20)
      waiterSession.closeSession()
      session.closeSession()

    test "a sub-lease of a benchmark lease is granted while it holds " &
        "the host in isolation":
      var client = connectDefault()
      defer: client.close()
      var session = client.registerSession("sub-test", "1")
      var parent = session.requestLeaseWaiting(benchmarkRequest(
        resourceRequest("bench", milliCpu(2000), bytes(2'u64 * GiB))),
        pollMillis = 20, maxPolls = 500)
      var sub = session.subLease(parent, 1000, 2000, maxPolls = 50)
      check sub.active
      check sub.resources.cpu.value == 2000'u32
      sub.release()
      parent.release()
      session.closeSession()

    test "a sub-lease runs and finishes like any lease":
      var client = connectDefault()
      defer: client.close()
      var session = client.registerSession("sub-test", "1")
      var parent = session.hostLease(2000)
      var sub = session.subLease(parent, 1000, 2000)
      sub.markStarting()
      sub.markRunning(childProcessId = uint64(getCurrentProcessId()))
      sub.finish()
      sub.release()
      # And a sub-lease is itself a parent.
      var outer = session.subLease(parent, 2000, 2000)
      var inner = session.subLease(outer, 1000, 1000)
      check inner.active
      inner.release()
      outer.release()
      parent.release()
      session.closeSession()

  stopOwned(daemon)
  removeDir(root)
else:
  echo "t_sub_lease_admission: POSIX only"
