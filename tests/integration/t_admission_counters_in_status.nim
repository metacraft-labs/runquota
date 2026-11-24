## The admission counters, the budget and the host identity that
## `runquota status --json` carries for capacity tools (reprobuild-pm issue
## `2026-11-23-runquotad-publishes-no-rejection-or-lease-wait-counters-and-ci-jobs-cannot-name-its-host-identity.md`;
## Build-Engine-And-Scheduler.md §"Admission counters, budget and host
## identity in `status --json`").
##
## WHAT IS GUARDED, each with the mutation that breaks it:
##
## 1. A refused lease request is counted once, under its reason, and the
##    reasons add up to `total_rejected`: a request larger than the host
##    (`budget`), a sub-lease larger than its parent (`budget`), a malformed
##    CPU range (`invalid`), a request in a session another connection
##    registered (`refused`), a queued benchmark denied after
##    `[benchmark] max-queue-wait` (`wait_limit`), a `RequestLease` on a
##    full host, which does not wait (`wait_limit`). Mutation: drop the
##    counting call at any one refusal site and that reason stays at 0.
## 2. A lease that was queued and then granted adds its wait to
##    `total_wait_micros` (in microseconds: a 150 ms wait reads at least
##    100 000), and `lease_wait_histogram` holds the same waits: `count`
##    equals `total_granted` (sub-leases included), `sum_micros` equals
##    `total_wait_micros`, the buckets are cumulative. Mutation: count the
##    wait only for host leases, and `count` falls behind `total_granted`.
## 3. `budget` is what the daemon enforces (the flags given here) and
##    `reserved` is what a held lease holds, CPU, memory, I/O slots and
##    pool units. Mutation: report the oversubscribed grant limit as the
##    budget, or count a sub-lease in `reserved`, and the figures differ.
## 4. `host_id` is the daemon's observation host id when capture is on (the
##    id in its identity file) and `null` when capture is off. Mutation:
##    print `observationHostId` without checking that capture runs, or
##    invent one, and the off case is not `null`.
## 5. The text `runquota status` prints `host_id:`, `total_rejected:` and
##    `total_wait_micros:` right after `total_finished:`.
##
## NO MOCKS: the built `runquotad` and `runquota`, real sessions over real
## sockets, the real client library. The forged session is the client
## library's own object with another connection's session id written into
## it, which is all a hostile peer needs.

when defined(linux) or defined(macosx):
  import std/[json, os, osproc, streams, strutils, times, unittest]

  import runquota_client
  import runquota_core
  import private_daemon_fixture

  const
    GiB = 1024'u64 * 1024'u64 * 1024'u64
    BudgetMilli = 4000'u32
    BudgetMemory = 16'u64 * GiB
    WaitBounds = [1000'u64, 10_000, 100_000, 1_000_000, 10_000_000,
      60_000_000, 600_000_000]

  proc u64(node: JsonNode): uint64 =
    if node.kind == JInt: uint64(node.getBiggestInt)
    else: parseBiggestUInt(node.getStr)

  proc statusOf(socket: string): JsonNode =
    let (code, text) = cli(privateEnv(socket), ["status", "--json"])
    prerequisite code == 0, "runquota status --json exit " & $code & ": " &
      text
    parseJson(newStringStream(text), "", rawIntegers = true)

  proc rejectedSum(status: JsonNode): uint64 =
    for reason in ["budget", "wait_limit", "refused", "invalid"]:
      result += status["rejected"][reason].u64

  proc checkHistogram(status: JsonNode) =
    ## The histogram agrees with the two counters and is cumulative.
    let histogram = status["lease_wait_histogram"]
    var bounds: seq[uint64] = @[]
    for bound in histogram["le_micros"]: bounds.add(bound.u64)
    check bounds == @WaitBounds
    check histogram["count"].u64 == status["total_granted"].u64
    check histogram["sum_micros"].u64 == status["total_wait_micros"].u64
    var previous = 0'u64
    check histogram["buckets"].len == WaitBounds.len
    for bucket in histogram["buckets"]:
      check bucket.u64 >= previous
      previous = bucket.u64
    check previous <= histogram["count"].u64

  proc refusedRequest(session: var RunQuotaSession;
                      request: ResourceRequest): bool =
    try:
      var lease = session.requestLease(request)
      lease.release()
      false
    except RunQuotaClientError:
      true

  proc work(milli: uint32; memory = 1'u64 * GiB): ResourceRequest =
    resourceRequest("work", milliCpu(milli), bytes(memory))

  suite "admission counters and budget (capture off)":
    let root = scratchDir("rqadm")
    let socket = root / "d.sock"
    writeFile(root / "host.toml",
      "schema = \"runquota.host-config.v1\"\n[benchmark]\n" &
      "max-queue-wait = \"1s\"\n")
    var daemon = launchOwned(root, socket, privateEnv(socket),
      daemonArgs(root, socket,
        ["--cpu-milli", $BudgetMilli, "--memory-bytes", $BudgetMemory,
         "--io-slots", "4", "--pool", "compile=3"]))
    putEnv("RUNQUOTA_ENDPOINT_SCOPE", "private")
    putEnv("RUNQUOTA_SOCKET", socket)
    delEnv("RUNQUOTA_SESSION")

    test "a fresh daemon reports zero counters, its budget and no host id":
      let status = statusOf(socket)
      checkpoint $status
      check status["host_id"].kind == JNull
      check status["total_rejected"].u64 == 0
      check status.rejectedSum == 0
      check status["total_wait_micros"].u64 == 0
      check status["budget"]["cpu_milli"].u64 == uint64(BudgetMilli)
      check status["budget"]["memory_bytes"].u64 == BudgetMemory
      check status["budget"]["io_slots"].u64 == 4
      check status["budget"]["pools"]["compile"].u64 == 3
      check status["reserved"]["cpu_milli"].u64 == 0
      check status["reserved"]["pools"]["compile"].u64 == 0
      status.checkHistogram()

    test "a held lease is reserved; a sub-lease is not added again":
      var client = connectDefault()
      defer: client.close()
      var session = client.registerSession("held", "1")
      var request = work(1500, 2'u64 * GiB)
      request.resources = request.resources.withNamedPool("compile", 2)
      request.resources.ioClass = ioHeavy
      var held = session.requestLease(request)
      prerequisite held.active, "the held lease was not granted"
      var sub = session.requestSubLeaseWaiting(held.id, "sub", "",
        milliCpu(500), milliCpu(500), bytes(GiB), pollMillis = 20,
        maxPolls = 100)
      prerequisite sub.active, "the sub-lease was not granted"
      let status = statusOf(socket)
      checkpoint $status
      check status["reserved"]["cpu_milli"].u64 == 1500
      check status["reserved"]["memory_bytes"].u64 == 2'u64 * GiB
      check status["reserved"]["io_slots"].u64 == 1
      check status["reserved"]["pools"]["compile"].u64 == 2
      check status["budget"]["cpu_milli"].u64 == uint64(BudgetMilli)
      sub.release()
      held.release()
      session.closeSession()
      let after = statusOf(socket)
      check after["reserved"]["cpu_milli"].u64 == 0
      check after["reserved"]["memory_bytes"].u64 == 0
      check after["reserved"]["io_slots"].u64 == 0
      check after["reserved"]["pools"]["compile"].u64 == 0
      after.checkHistogram()

    test "each refusal is counted once under its reason":
      var client = connectDefault()
      defer: client.close()
      var session = client.registerSession("refusals", "1")
      let before = statusOf(socket)
      # Larger than the host: can never fit.
      check session.refusedRequest(work(BudgetMilli * 2))
      var status = statusOf(socket)
      check status["total_rejected"].u64 == before["total_rejected"].u64 + 1
      check status["rejected"]["budget"].u64 ==
        before["rejected"]["budget"].u64 + 1
      # A malformed CPU range: minimum above preferred.
      check session.refusedRequest(work(1000).withWidthRange(milliCpu(2000),
        milliCpu(1000)))
      status = statusOf(socket)
      check status["rejected"]["invalid"].u64 ==
        before["rejected"]["invalid"].u64 + 1
      # A session another connection registered.
      var thief = connectDefault()
      defer: thief.close()
      var forged = thief.registerSession("thief", "1")
      forged.id = session.id
      check forged.refusedRequest(work(1000))
      status = statusOf(socket)
      check status["rejected"]["refused"].u64 ==
        before["rejected"]["refused"].u64 + 1
      # A sub-lease larger than its parent.
      var parent = session.requestLease(work(1000))
      prerequisite parent.active, "the parent lease was not granted"
      var subRefused = false
      try:
        discard session.requestSubLeaseWaiting(parent.id, "sub", "",
          milliCpu(2000), milliCpu(2000), bytes(0), maxPolls = 1)
      except RunQuotaClientError:
        subRefused = true
      check subRefused
      parent.release()
      status = statusOf(socket)
      checkpoint $status
      check status["rejected"]["budget"].u64 ==
        before["rejected"]["budget"].u64 + 2
      check status["total_rejected"].u64 == before["total_rejected"].u64 + 4
      check status.rejectedSum == status["total_rejected"].u64
      session.closeSession()

    test "a queued benchmark denied after max-queue-wait is a wait_limit":
      var client = connectDefault()
      defer: client.close()
      var holder = client.registerSession("holder", "1")
      var running = holder.requestLease(work(1000))
      prerequisite running.active, "the running lease was not granted"
      var bencher = client.registerSession("bencher", "1")
      let before = statusOf(socket)
      let offer = bencher.sendCandidateOffer([toCandidate(900'u64,
        benchmarkRequest(work(2000)))])
      let decisions = bencher.receiveCandidateDecisions(offer)
      prerequisite decisions.len == 1 and decisions[0].queued,
        "the benchmark was not queued"
      var denied = false
      let deadline = epochTime() + 20.0
      while not denied and epochTime() < deadline:
        for grant in bencher.pollNextGrant():
          if grant.clientCandidateId == 900'u64 and not grant.lease.active:
            denied = true
        if not denied: sleep(50)
      check denied
      let status = statusOf(socket)
      checkpoint $status
      check status["rejected"]["wait_limit"].u64 ==
        before["rejected"]["wait_limit"].u64 + 1
      check status["total_rejected"].u64 == before["total_rejected"].u64 + 1
      check status.rejectedSum == status["total_rejected"].u64
      running.release()
      bencher.closeSession()
      holder.closeSession()

    test "a queued-then-granted lease adds its wait in microseconds":
      var client = connectDefault()
      defer: client.close()
      var holder = client.registerSession("full", "1")
      var full = holder.requestLease(work(BudgetMilli))
      prerequisite full.active, "the full-host lease was not granted"
      var waiter = client.registerSession("waiter", "1")
      # `RequestLease` does not wait: on a full host a request that fits the
      # budget is queued and dropped at once, a `wait_limit`.
      let beforeSync = statusOf(socket)
      check waiter.refusedRequest(work(2000))
      let afterSync = statusOf(socket)
      check afterSync["rejected"]["wait_limit"].u64 ==
        beforeSync["rejected"]["wait_limit"].u64 + 1
      check afterSync.rejectedSum == afterSync["total_rejected"].u64
      let before = statusOf(socket)
      let offer = waiter.sendCandidateOffer([toCandidate(901'u64,
        work(2000))])
      let decisions = waiter.receiveCandidateDecisions(offer)
      prerequisite decisions.len == 1 and decisions[0].queued,
        "the waiting lease was not queued"
      sleep(150)
      full.release()
      var granted: RunQuotaLease
      var got = false
      let deadline = epochTime() + 20.0
      while not got and epochTime() < deadline:
        for grant in waiter.pollNextGrant():
          if grant.clientCandidateId == 901'u64 and grant.lease.active:
            granted = grant.lease
            got = true
        if not got: sleep(20)
      prerequisite got, "the queued lease was never granted"
      let status = statusOf(socket)
      checkpoint $status
      let waited = status["total_wait_micros"].u64 -
        before["total_wait_micros"].u64
      check waited >= 100_000'u64
      check waited < 60_000_000'u64
      check status["total_granted"].u64 == before["total_granted"].u64 + 1
      status.checkHistogram()
      # The 150 ms wait lies above the 100 ms bound and within the 1 s one.
      let buckets = status["lease_wait_histogram"]["buckets"]
      let beforeBuckets = before["lease_wait_histogram"]["buckets"]
      check buckets[2].u64 == beforeBuckets[2].u64
      check buckets[3].u64 == beforeBuckets[3].u64 + 1
      granted.release()
      waiter.closeSession()
      holder.closeSession()

    test "the text status prints the new lines after total_finished":
      let (code, text) = cli(privateEnv(socket), ["status"])
      check code == 0
      checkpoint text
      let lines = text.splitLines()
      var at = -1
      for i, line in lines:
        if line.startsWith("total_finished: "): at = i
      check at >= 0
      check at + 3 < lines.len
      if at >= 0 and at + 3 < lines.len:
        check lines[at + 1].startsWith("host_id: ")
        check lines[at + 2].startsWith("total_rejected: ")
        check lines[at + 3].startsWith("total_wait_micros: ")
        let status = statusOf(socket)
        check lines[at + 2] == "total_rejected: " &
          $status["total_rejected"].u64

    stopOwned(daemon)
    removeDir(root)

  suite "host identity (capture on)":
    test "host_id is the identity file's id once the store is verified":
      let root = scratchDir("rqhid")
      defer: removeDir(root)
      let socket = root / "d.sock"
      # `daemonArgs` turns capture off (`--no-write-stats`); this case needs
      # it on, so the store and the identity file are named here.
      var args: seq[string] = @[]
      for arg in daemonArgs(root, socket,
          ["--cpu-milli", $BudgetMilli, "--memory-bytes", $BudgetMemory,
           "--observation-db", root / "observations.sqlite3",
           "--measurement", "capture=on"]):
        if arg != "--no-write-stats": args.add(arg)
      var daemon = launchOwned(root, socket, privateEnv(socket), args)
      defer: stopOwned(daemon)
      # The store is verified after the endpoint binds; until then the
      # daemon has no host id and says `null`.
      var status = statusOf(socket)
      let deadline = epochTime() + 60.0
      while status["host_id"].kind == JNull and epochTime() < deadline:
        sleep(100)
        status = statusOf(socket)
      checkpoint $status
      check status["host_id"].kind == JString
      prerequisite fileExists(root / "host-id"), "no identity file was minted"
      check status["host_id"].getStr == readFile(root / "host-id").strip()
      let (code, text) = cli(privateEnv(socket), ["status"])
      check code == 0
      check ("host_id: " & status["host_id"].getStr) in text
else:
  echo "t_admission_counters_in_status: POSIX only"
