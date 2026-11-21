## Class reservations and the oversubscription target, end to end: a real
## `runquotad` reading its host file, real clients whose sessions name a
## class the way a launcher's `RUNQUOTA_CLASS` does, and the figures read
## back through the shipped `runquota` CLI.
##
## WHAT IS GUARDED, and the change to the daemon each case fails under.
##
## * `reserved_memory_untouched` -- work outside a class never takes the
##   class's reserved memory, idle or not; the class gets it at once; and
##   the class never holds more than its reservation plus what it borrowed,
##   with `status --json` saying how much was borrowed. Mutations: lending
##   reserved memory like CPU (protecting it only while the class waits)
##   grants the unclassed request; protecting nothing grants it too; letting
##   a class borrow another class's reservation shows a class above
##   reservation + free.
## * `reservation_holds_under_load` -- two other groups request the whole
##   host, and queued earlier; the reserved class gets each CPU a finishing
##   lease frees, up to its reservation, in the admission pass that release
##   runs, and with `lend = false` in its own request's pass. Mutation:
##   admitting the class only from leftovers (no reserved pass, no
##   protection) hands the freed CPU to the earlier groups and the class
##   waits.
## * `oversubscription_bounded` -- under churn from three groups, the CPU
##   the daemon has granted never exceeds budget x (1 + target) and reaches
##   it; memory never exceeds the memory budget. Mutations: scaling the
##   memory budget too, or doubling the target.
## * `reload_applies_and_revokes_nothing` -- a reload puts a reservation and
##   a target in force without revoking a running lease, and a reload back
##   to none does the same.
## * `invalid_reservations_refused` -- a file whose reservations exceed the
##   budget stops the daemon at start (exit 2, the file named), a reload of
##   one is refused and changes nothing, and `runquota config set` refuses
##   a bad class key or value before writing.
## * `class_queue_waits_published` -- a pool's reporting session
##   (`runquota pressure report`) reports a job's wait for a slot as a
##   `class-queue` wait, which `runquota pressure --json` publishes under
##   the class; a wait longer than the reporting session has existed is
##   clamped. The 90 s pool case is gosti's `t_pool_class_queue_wait`.
##
## NO MOCKS. Every case runs the built `runquotad` on a private socket in a
## scratch `0700` directory (`RUNQUOTA_ENDPOINT_SCOPE=private`, through
## `tests/support/private_daemon_fixture`), with its own state files and host
## file; nothing here reaches the host's daemon or a daemon this file did not
## start. The clients are the real client library and the shipped CLI.

when defined(posix):
  import std/[json, os, osproc, streams, strtabs, strutils, times, unittest]

  import runquota_client
  import runquota_core
  import runquota_ipc
  import runquota_protocol
  import daemon_binary
  import private_daemon_fixture

  const
    MiB = 1024'u64 * 1024'u64
    GiB = 1024'u64 * MiB
    Slot = 1000
    Head = "schema = \"runquota.host-config.v1\"\n"
    GroupEnvKeys = [SessionGroupEnvVar, SessionPriorityEnvVar,
      SessionCacheTtlEnvVar, ClassEnvVar]

  type
    Party = ref object
      client: RunQuotaClient
      session: RunQuotaSession
      held: seq[RunQuotaLease]
      nextCandidate: uint64

    Fixture = object
      root: string
      socket: string
      daemon: Process
      env: StringTableRef
      saved: seq[tuple[key: string, had: bool, value: string]]

  proc epochTimeMillis(): int64 = int64(epochTime() * 1000.0)

  proc saveAndSet(fixture: var Fixture; key, value: string) =
    fixture.saved.add((key, existsEnv(key), getEnv(key)))
    if value.len > 0: putEnv(key, value) else: delEnv(key)

  proc startFixture(tag, hostFile: string; cpuSlots = 4;
                    memory = 4'u64 * GiB): Fixture =
    result.root = scratchDir(tag)
    result.socket = result.root / "rq.sock"
    result.env = privateEnv(result.socket)
    for key in GroupEnvKeys:
      if result.env.hasKey(key): result.env.del(key)
    writeFile(result.root / "host.toml", Head & hostFile)
    result.daemon = launchOwned(result.root, result.socket, result.env,
      daemonArgs(result.root, result.socket,
        @["--cpu-milli", $(cpuSlots * Slot), "--memory-bytes", $memory]),
      what = "the private daemon")
    result.saveAndSet("RUNQUOTA_ENDPOINT_SCOPE", "private")
    result.saveAndSet("RUNQUOTA_SOCKET", result.socket)
    for key in GroupEnvKeys:
      result.saveAndSet(key, "")

  proc stopFixture(fixture: var Fixture) =
    for i in countdown(fixture.saved.high, 0):
      let entry = fixture.saved[i]
      if entry.had: putEnv(entry.key, entry.value) else: delEnv(entry.key)
    stopOwned(fixture.daemon)

  proc party(fixture: Fixture; name: string; group: string;
             class = ""): Party =
    result = Party(nextCandidate: 1'u64)
    result.client = connect(unixEndpoint(fixture.socket), name)
    result.session = result.client.registerSession(name, "0",
      SessionGroupDeclaration(name: group, priority: sessionPriorityNormal,
        className: class))

  proc partyFromEnvironment(fixture: Fixture; name, class: string): Party =
    ## A session registered through the library's default path, with the
    ## class exported the way a launcher exports it.
    putEnv(ClassEnvVar, class)
    defer: delEnv(ClassEnvVar)
    result = Party(nextCandidate: 1'u64)
    result.client = connect(unixEndpoint(fixture.socket), name)
    result.session = result.client.registerSession(name, "0")

  proc offer(p: Party; slots = 1; memory = 64'u64 * MiB): bool =
    let id = p.nextCandidate
    inc p.nextCandidate
    let request = resourceRequest("cls-" & $id, milliCpu(slots * Slot),
      bytes(memory))
    let decisions = p.session.offerCandidates([toCandidate(id, request)])
    doAssert decisions.len == 1
    doAssert decisions[0].lease.active,
      "the daemon refused a request outright: " &
        decisions[0].diagnostic.message
    if not decisions[0].queued:
      p.held.add(decisions[0].lease)
      return true
    false

  proc offerRefusal(p: Party; slots = 1; memory = 64'u64 * MiB): string =
    ## The daemon's refusal of a request it can never grant, or "".
    let id = p.nextCandidate
    inc p.nextCandidate
    let decisions = p.session.offerCandidates([toCandidate(id,
      resourceRequest("cls-" & $id, milliCpu(slots * Slot), bytes(memory)))])
    if decisions.len == 1 and not decisions[0].lease.active:
      return decisions[0].diagnostic.message
    ""

  proc collect(p: Party): int =
    while true:
      let decisions = p.session.pollNextGrant()
      var got = false
      for decision in decisions:
        if not decision.queued and decision.lease.active:
          p.held.add(decision.lease)
          inc result
          got = true
      if not got:
        return

  proc releaseOne(p: Party) =
    var lease = p.held[0]
    p.held.delete(0)
    lease.release()

  proc close(p: Party) =
    try:
      while p.held.len > 0:
        p.releaseOne()
      p.session.closeSession()
    except CatchableError:
      discard
    p.client.close()

  proc statusJson(fixture: Fixture): JsonNode =
    let (code, output) = cli(fixture.env, ["status", "--json"])
    doAssert code == 0, "runquota status --json failed: " & output
    parseJson(output.strip().splitLines()[^1])

  proc classRow(status: JsonNode; name: string): JsonNode =
    for entry in status["classes"]:
      if entry["name"].getStr() == name:
        return entry
    nil

  proc groupsHeld(status: JsonNode): tuple[cpu, memory: int64] =
    for group in status["session_groups"]:
      result.cpu += group["held_cpu_milli"].getBiggestInt()
      result.memory += group["held_memory_bytes"].getBiggestInt()

  proc reload(fixture: Fixture; hostFile: string): tuple[code: int,
      output: string] =
    writeFile(fixture.root / "host.toml", Head & hostFile)
    cli(fixture.env, ["config", "reload"])

  suite "class_reservations":
    test "reserved_memory_untouched":
      var fixture = startFixture("clsmem",
        "[reservation.ci]\ncpu-milli = 1000\nmemory-bytes = 2147483648\n" &
        "[reservation.gpu]\nmemory-bytes = 536870912\nlend = false\n",
        memory = 4'u64 * GiB)
      defer: stopFixture(fixture)
      let other = fixture.party("other", "cls-other")
      let ci = fixture.partyFromEnvironment("ci", "ci")
      defer:
        other.close()
        ci.close()
      # The budget is 4 GiB, of which 2 GiB are reserved for `ci` and
      # 512 MiB for `gpu`: other work can hold 1.5 GiB and no more, whether
      # or not the classes are busy. It holds 1 GiB; another 1 GiB waits.
      check other.offer(1, 1'u64 * GiB)
      check not other.offer(1, 1'u64 * GiB)
      check other.offerRefusal(1, 2'u64 * GiB).contains(
        "reserved for other classes")
      var status = fixture.statusJson()
      check status.groupsHeld().memory == int64(1'u64 * GiB)
      let ciRow = status.classRow("ci")
      check ciRow != nil
      if ciRow != nil:
        check ciRow["protected_memory_bytes"].getBiggestInt() ==
          int64(2'u64 * GiB)
        check ciRow["held_memory_bytes"].getBiggestInt() == 0
      # The class gets its reservation at once, whatever else is queued.
      check ci.offer(1, 2'u64 * GiB)
      # Beyond it, the class borrows only what nothing protects: with the
      # other group's 1 GiB, ci's 2 GiB and gpu's 512 MiB, 512 MiB is free
      # (the other group's waiting 1 GiB does not fit it; the class's 512
      # MiB, behind it in the order, does).
      check ci.offer(1, 512'u64 * MiB)
      check not ci.offer(1, 256'u64 * MiB)
      check other.collect() == 0
      status = fixture.statusJson()
      let after = status.classRow("ci")
      check after != nil
      if after != nil:
        let held = after["held_memory_bytes"].getBiggestInt()
        let reserved = after["reservation"]["memory_bytes"].getBiggestInt()
        let borrowed = after["borrowed_memory_bytes"].getBiggestInt()
        check held == int64(2'u64 * GiB + 512'u64 * MiB)
        check borrowed == int64(512'u64 * MiB)
        # Never more than its reservation plus what it borrowed, and what it
        # borrowed was never another class's: gpu's reservation is intact.
        check held == reserved + borrowed
        check held + int64(1'u64 * GiB) + int64(512'u64 * MiB) <=
          int64(4'u64 * GiB)
      check status.classRow("gpu")["protected_memory_bytes"].getBiggestInt() ==
        int64(512'u64 * MiB)
      check status.groupsHeld().memory <= int64(4'u64 * GiB)
      # The session group row names its class.
      for group in status["session_groups"]:
        if group["name"].getStr() == "ci":
          check group["class"].getStr() == "ci"

    test "reservation_holds_under_load":
      var fixture = startFixture("clsload",
        "[reservation.ci]\ncpu-milli = 2000\n")
      defer: stopFixture(fixture)
      let first = fixture.party("first", "cls-first")
      let second = fixture.party("second", "cls-second")
      let ci = fixture.party("ci", "cls-ci", "ci")
      defer:
        first.close()
        second.close()
        ci.close()
      # The class is idle, so its two reserved CPUs are lent: the first
      # group takes the whole host.
      for _ in 0 ..< 4:
        check first.offer()
      # Both groups want the whole host again, queued before the class.
      for _ in 0 ..< 4:
        check not second.offer()
      for _ in 0 ..< 4:
        check not first.offer()
      check not ci.offer()
      check not ci.offer()
      # Each CPU a finishing lease frees goes to the class, up to its
      # reservation, in the pass the release runs: the class's grant is
      # waiting on its next GrantNext.
      first.releaseOne()
      check ci.collect() == 1
      check second.collect() == 0
      check first.collect() == 0
      first.releaseOne()
      check ci.collect() == 1
      check second.collect() == 0
      # Beyond the reservation the queue is served in its own order: the
      # first group became busy first, so it keeps its place.
      first.releaseOne()
      check ci.collect() == 0
      check first.collect() == 1
      check second.collect() == 0
      let row = fixture.statusJson().classRow("ci")
      check row != nil
      if row != nil:
        check row["held_cpu_milli"].getInt() == 2000
        check row["borrowed_cpu_milli"].getInt() == 0
        check row["grants_total"].getInt() == 2

    test "reservation_holds_under_load_without_lending":
      var fixture = startFixture("clsnolend",
        "[reservation.ci]\ncpu-milli = 2000\nlend = false\n")
      defer: stopFixture(fixture)
      let first = fixture.party("first", "cls-first")
      let second = fixture.party("second", "cls-second")
      let ci = fixture.party("ci", "cls-ci", "ci")
      defer:
        first.close()
        second.close()
        ci.close()
      var firstGranted = 0
      for _ in 0 ..< 4:
        if first.offer(): inc firstGranted
      var secondGranted = 0
      for _ in 0 ..< 4:
        if second.offer(): inc secondGranted
      # Other work gets what is not reserved, and no more.
      check firstGranted == 2
      check secondGranted == 0
      # The class gets its reserved cores in its own request's pass.
      check ci.offer()
      check ci.offer()
      check not ci.offer()

    test "oversubscription_bounded":
      var fixture = startFixture("clsover",
        "[admission]\noversubscription = \"0.5\"\n", memory = 4'u64 * GiB)
      defer: stopFixture(fixture)
      var parties: seq[Party]
      for i in 0 ..< 3:
        parties.add(fixture.party("p" & $i, "cls-p" & $i))
      defer:
        for p in parties: p.close()
      const Limit = 6000'i64
      var peakCpu = 0'i64
      var peakMemory = 0'i64
      for round in 0 ..< 6:
        for p in parties:
          for _ in 0 ..< 3:
            discard p.offer(1, 384'u64 * MiB)
          discard p.collect()
        let roundStatus = fixture.statusJson()
        let held = roundStatus.groupsHeld()
        check roundStatus["capacity"]["host"]["cpu_granted_milli"].
          getBiggestInt() <= Limit
        check roundStatus["capacity"]["host"]["memory_reserved_bytes"].
          getBiggestInt() <= int64(4'u64 * GiB)
        peakCpu = max(peakCpu, held.cpu)
        peakMemory = max(peakMemory, held.memory)
        check held.cpu <= Limit
        check held.memory <= int64(4'u64 * GiB)
        # Churn: each party gives one lease back.
        for p in parties:
          if p.held.len > 0:
            p.releaseOne()
            discard p.collect()
      # The bound is reached, not only respected: grants overlap by the
      # target.
      check peakCpu == Limit
      check peakMemory <= int64(4'u64 * GiB)
      let status = fixture.statusJson()
      check status["admission_oversubscription"].getStr() == "0.5"
      check status["cpu_grant_limit_milli"].getInt() == Limit
      # Memory is never oversubscribed: with the CPU target leaving room
      # for six one-CPU leases, five of 1 GiB do not all fit a 4 GiB budget.
      for p in parties: p.close()
      parties.setLen(0)
      # A closed connection's leases are released when the daemon cleans the
      # connection up, after the close returns: wait for that, so the phase
      # below starts from an empty ledger.
      var waitedMillis = 0
      proc ledgerBusy(status: JsonNode): bool =
        let host = status["capacity"]["host"]
        host["cpu_granted_milli"].getBiggestInt() > 0 or
          host["pending_requests"].getBiggestInt() > 0
      while fixture.statusJson().ledgerBusy() and waitedMillis < 20_000:
        sleep(100)
        waitedMillis += 100
      check not fixture.statusJson().ledgerBusy()
      let memory = fixture.party("mem", "cls-mem")
      parties.add(memory)
      var memoryGranted = 0
      for _ in 0 ..< 5:
        if memory.offer(1, 1'u64 * GiB): inc memoryGranted
      check memoryGranted == 4
      check fixture.statusJson().groupsHeld().memory == int64(4'u64 * GiB)

    test "reload_applies_and_revokes_nothing":
      var fixture = startFixture("clsreload", "")
      defer: stopFixture(fixture)
      let other = fixture.party("other", "cls-other")
      let ci = fixture.party("ci", "cls-ci", "ci")
      defer:
        other.close()
        ci.close()
      for _ in 0 ..< 4:
        check other.offer()
      check not other.offer()
      # Reserve two CPUs for ci without lending, and allow a quarter more.
      let (code, output) = fixture.reload(
        "[admission]\noversubscription = \"0.25\"\n" &
        "[reservation.ci]\ncpu-milli = 2000\nlend = false\n")
      check code == 0
      if code != 0: echo output
      # Nothing revoked: the four leases still run. The fifth CPU the
      # target adds is the class's (its reservation protects it), so the
      # queued request of other work still waits.
      check other.held.len == 4
      check other.collect() == 0
      check ci.offer()
      check not ci.offer()
      other.releaseOne()
      check ci.collect() == 1
      check other.collect() == 0
      var status = fixture.statusJson()
      check status["admission_oversubscription"].getStr() == "0.25"
      check status.classRow("ci")["held_cpu_milli"].getInt() == 2000
      check status.groupsHeld().cpu == 5000
      # Back to none: nothing revoked, and the limit is the budget again.
      let (code2, output2) = fixture.reload("")
      check code2 == 0
      if code2 != 0: echo output2
      status = fixture.statusJson()
      check status["admission_oversubscription"].getStr() == "0"
      check status.groupsHeld().cpu == 5000
      check other.collect() == 0

    test "invalid_reservations_refused":
      # At start: the daemon does not start, and says why.
      let root = scratchDir("clsbad")
      let socket = root / "rq.sock"
      writeFile(root / "host.toml", Head & "[reservation.ci]\n" &
        "cpu-milli = 3000\n[reservation.gpu]\ncpu-milli = 2000\n")
      let bad = startProcess(daemonPath(), env = privateEnv(socket),
        args = daemonArgs(root, socket, @["--cpu-milli", "4000",
          "--memory-bytes", $(4'u64 * GiB)]),
        options = {poStdErrToStdOut})
      let exitCode = bad.exitWithin(30_000)
      let text = bad.output()
      bad.close()
      check exitCode == 2
      check "5000m CPU in all" in text
      check "host.toml" in text
      # On reload: refused, and the budget in force is unchanged.
      var fixture = startFixture("clsbadreload",
        "[reservation.ci]\ncpu-milli = 1000\n")
      defer: stopFixture(fixture)
      let (code, output) = fixture.reload(
        "[reservation.ci]\ncpu-milli = 9000\n")
      check code != 0
      check "above the CPU budget" in output
      let row = fixture.statusJson().classRow("ci")
      check row != nil and row["reservation"]["cpu_milli"].getInt() == 1000
      # `config set` refuses before writing.
      let before = readFile(fixture.root / "host.toml")
      let (setCode, setOutput) = cli(fixture.env, ["config", "set",
        "reservation.ci.lend", "maybe"])
      check setCode != 0
      check "true or false" in setOutput
      check readFile(fixture.root / "host.toml") == before

    test "class_queue_waits_published":
      var fixture = startFixture("clsqueue",
        "[reservation.ci]\ncpu-milli = 1000\n")
      defer: stopFixture(fixture)
      # A pool's reporting session, as a pool starts it: kept for its life.
      var reporter = startProcess(cliPath(), env = fixture.env,
        args = ["pressure", "report", "--class", "ci"],
        options = {})
      defer:
        if reporter.running:
          reporter.inputStream.close()
          discard reporter.waitForExit(10_000)
        reporter.close()
      let ready = reporter.outputStream.readLine()
      check ready.startsWith("ready ")
      # A job accepted now waits 2.5 s for a slot.
      let accepted = epochTimeMillis()
      sleep(2500)
      let waited = epochTimeMillis() - accepted
      reporter.inputStream.writeLine("class-queue " & $accepted & " " &
        $waited)
      reporter.inputStream.flush()
      check reporter.outputStream.readLine() == "reported " & $waited
      # Too short, and unreadable: answered, and the session stays.
      reporter.inputStream.writeLine("class-queue " & $accepted & " 200")
      reporter.inputStream.writeLine("queue 1 2")
      reporter.inputStream.flush()
      check reporter.outputStream.readLine().startsWith("skipped")
      check reporter.outputStream.readLine().startsWith("refused")
      # A wait longer than the session has existed is cut to its age: the
      # daemon trusts no client-sent length beyond it.
      reporter.inputStream.writeLine("class-queue " & $accepted & " 90000")
      reporter.inputStream.flush()
      check reporter.outputStream.readLine() == "reported 90000"
      reporter.inputStream.close()
      check reporter.waitForExit(10_000) == 0
      let (code, output) = cli(fixture.env, ["pressure", "--json"])
      check code == 0
      let answer = parseJson(output.strip().splitLines()[^1])
      var found = false
      for class in answer["classes"]:
        if class["name"].getStr() == "ci":
          found = true
          check class["configured"].getBool()
          let waits = class["waits"]["class-queue"]
          check waits["count"].getInt() == 2
          # The 2.5 s wait whole; the 90 s one cut to about the session's
          # age (under ten seconds here).
          check waits["sum_millis"].getBiggestInt() >= waited
          check waits["sum_millis"].getBiggestInt() < waited + 10_000
          check class["waits"]["queue"]["count"].getInt() == 0
      check found
      # The text form names the class.
      let (textCode, text) = cli(fixture.env, ["pressure"])
      check textCode == 0
      check "class ci" in text and "class-queue 2" in text
      # An unknown class is refused before connecting.
      let (badCode, _) = cli(fixture.env, ["pressure", "report", "--class",
        "c i"])
      check badCode == 2
