## Negotiated widths against a real private `runquotad`: CPU ranges on host
## leases, and the resize exchange of resizable leases, driven through the
## Nim client library.
##
## WHAT IS GUARDED, each with the mutation that breaks it:
##
## 1. A range is granted the widest width that is free: with 6 of 8 slots
##    free a 2..16 request gets 6; with 1 free it waits; the grant is never
##    below the minimum nor above the preferred width. Mutation: grant the
##    preferred width or nothing (`rangedWidth` answering 0 below
##    `preferred`) and the first request waits instead of getting 6.
## 2. Widening uses free slots within one admission cycle: when a neighbour
##    releases, the resizable lease's target is raised by the release's own
##    admission pass, before its holder has said anything. Mutation: never
##    widen (`widenIntoFreeSlots` returning at once) and the target stays at
##    the grant.
## 3. Widening goes through the configured admission order: of two
##    resizable leases below their preferred width, the one whose session
##    group has the higher priority is widened first, although it was
##    granted last. Mutation: widen in lease-id order instead of through
##    `planAdmission` and the other lease takes the free slots.
## 4. Narrowing is charged as tokens come back: a waiter makes the daemon
##    lower a widened lease's target back to its grant, and the waiter is
##    granted only once the holder REPORTS a width that leaves room. The
##    ledger charges max(target, current) until then. Mutation: charge the
##    target at once (`resizeCharge` returning the target) and the waiter is
##    granted before any token came back.
## 5. A lease is never narrowed below its grant.
## 6. A bad client cannot raise its own charge or move another session's
##    lease: a reported width above the charge is clamped, a resize from a
##    connection that did not register the session is refused, and a
##    non-resizable lease cannot be resized. Malformed ranges are refused
##    with `invalid argument`, a minimum above the budget is denied, and a
##    preferred width of 2^32 - 1 is simply capped by what is free.
## 7. A lease's charge never falls below what its own sub-leases hold: a
##    sub-lease carved from a narrowing lease's charge keeps that CPU on the
##    host ledger after the holder reports a smaller width. Mutation: charge
##    max(target, current) only (`resizeCharge` ignoring `subHeldCpuMilli`)
##    and the reported 2 frees slots the sub-lease runs on.
##
## NO MOCKS: the built `runquotad`, a real socket, the real client library.

when defined(posix):
  import std/[json, os, osproc, strutils, unittest]

  import runquota_client
  import runquota_core
  import runquota_protocol
  import daemon_binary
  import private_daemon_fixture

  const
    GiB = 1024'u64 * 1024'u64 * 1024'u64
    BudgetMilli = 8000

  var
    root: string
    socket: string
    daemon: Process

  root = scratchDir("rqwidth")
  socket = root / "d.sock"
  daemon = launch(root, socket, privateEnv(socket),
    ["--cpu-milli", $BudgetMilli, "--memory-bytes", $(64'u64 * GiB)])
  prerequisite awaitSocket(daemon, socket),
    daemon.startupContext("the daemon did not bind " & socket)
  putEnv("RUNQUOTA_ENDPOINT_SCOPE", "private")
  putEnv("RUNQUOTA_SOCKET", socket)
  delEnv("RUNQUOTA_SESSION")
  delEnv("RUNQUOTA_SESSION_PRIORITY")

  proc fixed(session: var RunQuotaSession; cpuMilli: uint32): RunQuotaLease =
    session.requestLease(resourceRequest("fixed", milliCpu(cpuMilli),
      bytes(GiB)))

  proc ranged(minMilli, prefMilli: uint32;
              resizable = false): ResourceRequest =
    resourceRequest("ranged", milliCpu(prefMilli), bytes(GiB)).withWidthRange(
      milliCpu(minMilli), milliCpu(prefMilli), resizable)

  proc offerOne(session: var RunQuotaSession;
                request: ResourceRequest): OfferedLease =
    let offered = session.offerCandidates([toCandidate(1'u64, request)])
    doAssert offered.len == 1
    offered[0]

  proc awaitGrant(session: var RunQuotaSession; polls = 200): RunQuotaLease =
    for _ in 0 ..< polls:
      for grant in session.pollNextGrant():
        if not grant.queued and grant.lease.active:
          return grant.lease
      sleep(10)
    raise newException(RunQuotaClientError, "no grant arrived")

  proc widthOf(client: var RunQuotaClient; lease: RunQuotaLease): JsonNode =
    for row in parseJson(client.inspectionJson("leases"))["leases"]:
      if row["id"].getBiggestInt() == BiggestInt(lease.id.value):
        return row["width"]
    raise newException(KeyError, "lease " & $lease.id.value & " not listed")

  proc chargeOf(client: var RunQuotaClient; lease: RunQuotaLease): int =
    for row in parseJson(client.inspectionJson("leases"))["leases"]:
      if row["id"].getBiggestInt() == BiggestInt(lease.id.value):
        return row["resources"]["cpu_milli"].getInt()
    -1

  proc denialOf(session: var RunQuotaSession; client: var RunQuotaClient;
                request: ResourceRequest): Diagnostic =
    try:
      var lease = session.requestLease(request)
      lease.release()
      diagnostic(diagOk, "granted")
    except RunQuotaClientError:
      client.lastDiagnostic

  suite "negotiated widths":
    test "the daemon announces negotiated widths":
      var client = connectDefault()
      defer: client.close()
      check client.supportsNegotiatedWidths()
      check client.capabilities.protocolMinor >= NegotiatedWidthsMinor

    test "a range is granted the widest free width, and waits below min":
      var client = connectDefault()
      defer: client.close()
      var neighbourSession = client.registerSession("neighbour", "1")
      var session = client.registerSession("ranged", "1")
      var neighbour = neighbourSession.fixed(2000)
      # 6 of 8 slots free: 2..16 gets 6, neither the 16 asked for nor 2.
      let six = session.offerOne(ranged(2000, 16000))
      check not six.queued
      check six.lease.active
      check six.lease.resources.cpu.value == 6000'u32
      var sixLease = six.lease
      # Never above the preferred width: 1..3 with 6 free gets 3.
      sixLease.release()
      var three = session.requestLease(ranged(1000, 3000))
      check three.resources.cpu.value == 3000'u32
      # 1 slot free now (2 + 3 + a 2-slot filler = 7 of 8): 2..16 waits.
      var filler = neighbourSession.fixed(2000)
      let waits = session.offerOne(ranged(2000, 16000))
      check waits.queued
      # It was not granted the 1 slot that was free (below its minimum).
      # Once 3 are free it gets all 3.
      filler.release()
      var waited = session.awaitGrant()
      check waited.resources.cpu.value == 3000'u32
      waited.release()
      three.release()
      neighbour.release()
      neighbourSession.closeSession()
      session.closeSession()

    test "a fixed request is unchanged: it gets exactly its CPU or waits":
      var client = connectDefault()
      defer: client.close()
      var session = client.registerSession("fixed", "1")
      var a = session.fixed(5000)
      check a.resources.cpu.value == 5000'u32
      let b = session.offerOne(resourceRequest("fixed", milliCpu(4000),
        bytes(GiB)))
      check b.queued
      a.release()
      var granted = session.awaitGrant()
      check granted.resources.cpu.value == 4000'u32
      granted.release()
      session.closeSession()

    test "malformed and impossible ranges are refused; a huge preferred is capped":
      var client = connectDefault()
      defer: client.close()
      var session = client.registerSession("refusals", "1")
      var raw = resourceRequest("bad", milliCpu(2000), bytes(GiB))
      raw.width = WidthRange(present: true, minMilli: 3000,
        preferredMilli: 2000)
      check session.denialOf(client, raw).code == diagInvalidArgument
      raw.width = WidthRange(present: true, minMilli: 0, preferredMilli: 2000)
      check session.denialOf(client, raw).code == diagInvalidArgument
      # A minimum above the budget can never be granted.
      check session.denialOf(client,
        ranged(9000, 16000)).code == diagDenied
      # A preferred width of 2^32 - 1 is not an error: the grant is capped
      # by what is free, and nothing wraps.
      var huge = session.requestLease(ranged(1000, high(uint32)))
      check huge.resources.cpu.value == uint32(BudgetMilli)
      huge.release()
      session.closeSession()

    test "widening uses free slots within one admission cycle":
      var client = connectDefault()
      defer: client.close()
      var neighbourSession = client.registerSession("neighbour", "1")
      var session = client.registerSession("jobserver", "1")
      var neighbour = neighbourSession.fixed(6000)
      var lease = session.requestLease(ranged(2000, 8000, resizable = true))
      check lease.resources.cpu.value == 2000'u32
      check client.widthOf(lease)["target_milli"].getInt() == 2000
      neighbour.release()
      # THE RELEASE'S OWN PASS widened it: the holder has not reported.
      let width = client.widthOf(lease)
      check width["target_milli"].getInt() == 8000
      check width["granted_milli"].getInt() == 2000
      check client.chargeOf(lease) == 8000
      # And the holder learns it in the answer to its next report.
      let answer = lease.reportResized(milliCpu(2000))
      check answer.cpuTargetMilli == 8000'u32
      check answer.cpuChargedMilli == 8000'u32
      lease.release()
      neighbourSession.closeSession()
      session.closeSession()

    test "narrowing is charged as tokens come back, never below the grant":
      var client = connectDefault()
      defer: client.close()
      var neighbourSession = client.registerSession("neighbour", "1")
      var session = client.registerSession("jobserver", "1")
      var neighbour = neighbourSession.fixed(6000)
      var lease = session.requestLease(ranged(2000, 8000, resizable = true))
      neighbour.release()
      discard lease.reportResized(milliCpu(8000))
      check client.chargeOf(lease) == 8000
      # A waiter for 6 slots: the target goes back to the grant (2), but
      # the charge stays at what the holder holds.
      let waiter = neighbourSession.offerOne(resourceRequest("waiter",
        milliCpu(6000), bytes(GiB)))
      check waiter.queued
      check client.widthOf(lease)["target_milli"].getInt() == 2000
      check client.chargeOf(lease) == 8000
      check neighbourSession.pollNextGrant().len == 0
      # Three tokens came back: charged 5, 3 free, the waiter still waits.
      var answer = lease.reportResized(milliCpu(5000))
      check answer.cpuTargetMilli == 2000'u32
      check answer.cpuChargedMilli == 5000'u32
      check neighbourSession.pollNextGrant().len == 0
      # Down to the target: the waiter is granted.
      answer = lease.reportResized(milliCpu(2000))
      check answer.cpuChargedMilli == 2000'u32
      var granted = neighbourSession.awaitGrant(polls = 5)
      check granted.resources.cpu.value == 6000'u32
      # Never below the grant, however long the waiter... a second waiter
      # that needs more than is left does not narrow the lease further.
      let second = neighbourSession.offerOne(resourceRequest("second",
        milliCpu(2000), bytes(GiB)))
      check second.queued
      check client.widthOf(lease)["target_milli"].getInt() == 2000
      granted.release()
      var secondLease = neighbourSession.awaitGrant()
      secondLease.release()
      lease.release()
      neighbourSession.closeSession()
      session.closeSession()

    test "a lease's charge never falls below what its sub-leases hold":
      var client = connectDefault()
      defer: client.close()
      var neighbourSession = client.registerSession("neighbour", "1")
      var session = client.registerSession("jobserver", "1")
      var neighbour = neighbourSession.fixed(6000)
      var lease = session.requestLease(ranged(2000, 8000, resizable = true))
      neighbour.release()
      discard lease.reportResized(milliCpu(8000))
      # A waiter for 6 narrows the target to the grant (2); the charge stays
      # at the 8 the holder holds.
      let waiter = neighbourSession.offerOne(resourceRequest("waiter",
        milliCpu(6000), bytes(GiB)))
      check waiter.queued
      check client.widthOf(lease)["target_milli"].getInt() == 2000
      # Before any token comes back, a sub-lease of 6 is carved from the 8
      # the lease is still charged.
      var sub = session.requestSubLeaseWaiting(lease.id, "sub", "",
        milliCpu(6000), milliCpu(6000), bytes(GiB div 4), maxPolls = 1)
      check sub.resources.cpu.value == 6000'u32
      # The holder then reports 2. The 6 its sub-lease runs on are still
      # on the host ledger: the charge stays 6 and the waiter still waits.
      let answer = lease.reportResized(milliCpu(2000))
      check answer.cpuChargedMilli == 6000'u32
      check client.chargeOf(lease) == 6000
      check neighbourSession.pollNextGrant().len == 0
      # Once the sub-lease ends, the reported 2 is the charge and the waiter
      # is granted.
      sub.release()
      discard lease.reportResized(milliCpu(2000))
      check client.chargeOf(lease) == 2000
      var granted = neighbourSession.awaitGrant(polls = 20)
      check granted.resources.cpu.value == 6000'u32
      granted.release()
      lease.release()
      neighbourSession.closeSession()
      session.closeSession()

    test "widening follows the configured admission order":
      var client = connectDefault()
      defer: client.close()
      var neighbourSession = client.registerSession("neighbour", "1")
      var neighbour = neighbourSession.fixed(4000)
      var filler = neighbourSession.fixed(2000)
      putEnv("RUNQUOTA_SESSION", "width-low")
      putEnv("RUNQUOTA_SESSION_PRIORITY", "low")
      var lowSession = client.registerSession("low", "1")
      putEnv("RUNQUOTA_SESSION", "width-high")
      putEnv("RUNQUOTA_SESSION_PRIORITY", "high")
      var highSession = client.registerSession("high", "1")
      delEnv("RUNQUOTA_SESSION")
      delEnv("RUNQUOTA_SESSION_PRIORITY")
      # The low-priority lease is granted FIRST, at its minimum (2 free),
      # and for now asks to grow no further than that.
      var low = lowSession.requestLease(ranged(2000, 6000, resizable = true))
      check low.resources.cpu.value == 2000'u32
      discard low.requestGrow(milliCpu(2000))
      filler.release()
      check client.widthOf(low)["target_milli"].getInt() == 2000
      # Then the high-priority one, at its minimum too (2 free).
      var high = highSession.requestLease(ranged(2000, 6000, resizable = true))
      check high.resources.cpu.value == 2000'u32
      # Both now want 6. 4 slots come free: the higher-priority group grows
      # first and takes them all, although its lease arrived last and its
      # group became busy last.
      discard low.requestGrow(milliCpu(6000))
      discard high.requestGrow(milliCpu(6000))
      neighbour.release()
      check client.widthOf(high)["target_milli"].getInt() == 6000
      check client.widthOf(low)["target_milli"].getInt() == 2000
      high.release()
      low.release()
      neighbourSession.closeSession()
      lowSession.closeSession()
      highSession.closeSession()

    test "a client cannot raise its own charge or move another's lease":
      var client = connectDefault()
      defer: client.close()
      var session = client.registerSession("owner", "1")
      var neighbour = session.fixed(6000)
      var lease = session.requestLease(ranged(2000, 8000, resizable = true))
      # Claiming to hold 1000 slots is clamped to the 2 charged.
      let answer = lease.reportResized(milliCpu(high(uint32)))
      check answer.cpuChargedMilli == 2000'u32
      check client.chargeOf(lease) == 2000
      # A grow request above the range is clamped to the preferred width.
      discard lease.requestGrow(milliCpu(high(uint32)))
      check client.widthOf(lease)["wanted_milli"].getInt() == 8000
      # Another connection cannot report for this session's lease.
      var other = connectDefault()
      defer: other.close()
      var otherSession = other.registerSession("intruder", "1")
      var refusedForged = false
      try:
        # Reported with the OWNER's session id over the other connection.
        var stolen = RunQuotaSession(client: addr other, id: session.id,
          active: true)
        var stolenLease = lease
        stolenLease.session = addr stolen
        discard stolenLease.reportResized(milliCpu(0))
      except RunQuotaClientError:
        refusedForged = true
        check other.lastDiagnostic.code == diagInvalidArgument
      check refusedForged
      check client.chargeOf(lease) == 2000
      # A lease that did not declare itself resizable cannot be resized.
      var refusedFixed = false
      try:
        discard neighbour.reportResized(milliCpu(1000))
      except RunQuotaClientError:
        refusedFixed = true
        check client.lastDiagnostic.code == diagInvalidArgument
      check refusedFixed
      check client.chargeOf(neighbour) == 6000
      lease.release()
      neighbour.release()
      otherSession.closeSession()
      session.closeSession()

    test "the daemon survives":
      check daemon.running

  stopOwned(daemon)
