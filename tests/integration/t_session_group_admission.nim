## Session groups and the order in which a host-wide `runquotad` serves them.
##
## Every RunQuota session belongs to a SESSION GROUP: the agent session (or the
## user's terminal) that started it. When several groups want the host's CPU
## at once, the daemon serves them first come first served, each up to what it
## asks for -- one build may take the whole machine -- except that a group of
## higher priority goes first, among equal priorities the group whose prompt
## cache expires sooner goes first, and no request waits longer than the
## starvation bound. Group attributes belong to the group's owner (the uid the
## kernel reports for the connection), and a client that names no group is
## placed in its user's `interactive` group at `high` priority.
##
## Each case below names the change to the daemon that makes it fail:
##
## * `default_order_whole_machine` -- dividing the host equally between
##   busy groups (round-robin between them) grants each half; ordering by
##   each request's own arrival instead of its group's hands the second
##   group the slots the first group asked for in its second installment.
## * `starvation_holds_slots` -- granting a request behind a
##   starved one that does not fit yet (backfill past the bound) hands every
##   freed slot to the stream, and the starved request never fits.
## * `priority_goes_first` -- ignoring the group priority serves
##   arrival order, and the low-priority group that queued first wins.
## * `cache_deadline_breaks_ties` -- sorting deadlines descending
##   serves the later deadline first.
## * `starvation_bound` -- removing the bound starves the
##   low-priority request behind a stream of high-priority ones, and the case
##   times out.
## * `update_refused_for_other_uid` -- skipping the owner check
##   lets the second uid change the attributes.
## * `missing_session_group_is_interactive` -- giving the
##   interactive group `normal` priority serves the named group that queued
##   first.
## * `fair_share_order` -- with the host file's order `[starvation,
##   fair-share, arrival]`, three busy groups each wanting the whole host
##   hold equal shares; hard-coding the default order (ignoring the file)
##   hands the first group everything, and ignoring the reload that puts the
##   default back hands freed slots back to the group that released them.
## * `max_wait_flag_over_host_file` -- letting the host file's
##   `admission.max-wait` override `--admission-max-wait-millis` (on start or
##   on reload) reports the file's bound.
## * `fair_share_unequal_sizes` -- a group asking two slots at a time and
##   one asking one: after a reload to fair-share they converge on equal
##   CPU; hard-coding the default order (ignoring the reload) leaves the
##   wide group with three quarters of the host. (That a fixed charge per grant, not
##   one by width, favours the wide group is shown over an hour of
##   simulated turnover in `libs/runquota_admission/tests/t_admission_order`.)
## * `invalid_order_refused` -- accepting an order with a repeated or
##   unknown key starts the daemon, or changes the policy in force on reload
##   (status and the order admission actually uses both show it).
##
## NO MOCKS. Every case runs the built `runquotad` on a private socket in a
## scratch `0700` directory (`RUNQUOTA_ENDPOINT_SCOPE=private`, through
## `tests/support/private_daemon_fixture`), with its own state files; nothing
## here reaches the host's daemon or any daemon this file did not start. The
## clients are the real client library and the shipped `runquota` CLI.
##
## THE SECOND UID IS REAL, NOT SIMULATED. `update_refused_for_other_uid`
## needs a connection whose peer credentials name another user. This file
## starts that daemon inside a USER NAMESPACE (`unshare --user`) that maps this
## user's uid to itself and maps namespace uid 0 to a subordinate uid from
## `/etc/subuid` (through the setuid-capable `newuidmap`). The "intruder" is
## this same test binary, re-executed with `nsenter --user` into that
## namespace, where it runs as namespace uid 0 -- a different kernel uid. The
## daemon reads both connections' credentials with `SO_PEERCRED` and sees two
## different uids; nothing in the daemon knows a test is running. A host
## without user namespaces or a subordinate uid range FAILS that case (it
## never passes vacuously) and says what is missing.
##
## THE INTRUDER SPEAKS THE PROTOCOL WITHOUT THE CLIENT'S ENDPOINT CHECK. The
## client library refuses to connect to a private socket its own uid does not
## own -- a protection for the client, not the daemon's authorisation. The
## daemon's owner check is what is under test, so the intruder opens the
## socket itself (namespace root may traverse the owner-only directory) and
## then drives the real client library's `updateSessionGroup` over that
## connection.
##
## POSIX only: the private endpoint, `unshare` and `nsenter` are POSIX.

when defined(posix):
  import std/[json, monotimes, net, os, osproc, posix, streams, strtabs, strutils,
    times, unittest]

  import runquota_client
  import runquota_codec
  import runquota_core
  import runquota_ipc
  import runquota_protocol
  import daemon_binary
  import private_daemon_fixture

  const
    IntruderSocketEnv = "RUNQUOTA_TEST_INTRUDER_SOCKET"
    IntruderGroupEnv = "RUNQUOTA_TEST_INTRUDER_GROUP"
      ## Set only on the re-executed intruder; see `runIntruder`.
    MiB = 1024'u64 * 1024'u64
    SlotMilli = 1000
    HostSlots = 4
    GroupEnvKeys = [SessionGroupEnvVar, SessionPriorityEnvVar,
      SessionCacheTtlEnvVar]

  # -------------------------------------------------------------------------
  # The intruder: this binary, re-executed inside the daemon's user namespace
  # -------------------------------------------------------------------------

  proc runIntruder(): int =
    ## Connects as namespace uid 0, registers a session of its own and changes
    ## its own group (so the daemon has demonstrably SERVED this uid, and read
    ## it as uid 0), then asks to change a group the outer uid owns. Prints one `key=value` line per fact and exits 0
    ## when the update was refused, 3 when it was accepted, 4 on any other
    ## failure.
    try:
      let path = getEnv(IntruderSocketEnv)
      var socket = newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_NONE)
      socket.connectUnix(path)
      var client = RunQuotaClient(
        connection: LocalConnection(kind: endpointUnixSocket, socket: socket,
          endpoint: unixEndpoint(path)),
        state: csConnected,
        flow: defaultFlowControlLimits(),
        lastDiagnostic: okDiagnostic())
      # The Hello the library sends, with the uid this process really has.
      let hello = HelloMessage(clientName: "sga-intruder",
        clientVersion: "0", minProtocolMajor: RqspProtocolMajor,
        maxProtocolMajor: RqspProtocolMajor,
        processId: uint64(getCurrentProcessId()), userId: uint64(getuid()),
        desiredCapabilities: "")
      client.connection.sendFrame(encodeFrame(rqHello, FrameFlagRequest, 1'u64,
        encodeHello(hello)))
      var frame: RqspFrame
      if not client.connection.receiveFrame(frame) or
          frame.header.messageKind != rqHelloOk:
        echo "hello=refused"
        return 4
      var helloOk: HelloOkMessage
      doAssert decodeHelloOk(frame.payload, helloOk)
      client.capabilities = helloOk.capabilities
      client.nextRequestId = 1'u64
      echo "uid=" & $getuid()
      var own = client.registerSession("sga-intruder", "0",
        SessionGroupDeclaration(name: "sga-intruder-group",
          priority: sessionPriorityNormal))
      echo "own_session=" & $own.id.value
      # The positive control: this uid may change ITS OWN group, and the
      # answer names the owner the daemon read from this connection.
      let mine = client.updateSessionGroup(UpdateSessionGroupMessage(
        group: "sga-intruder-group", priorityPresent: true,
        priority: sessionPriorityLow))
      echo "own_group_owner_uid=" & $mine.ownerUid
      echo "own_group_priority=" & sessionPriorityName(mine.priority)
      try:
        discard client.updateSessionGroup(UpdateSessionGroupMessage(
          group: getEnv(IntruderGroupEnv), priorityPresent: true,
          priority: sessionPriorityUrgent,
          cacheDeadlineChange: cacheDeadlineClear))
        echo "update=accepted"
        return 3
      except RunQuotaClientError as error:
        echo "update=refused"
        echo "code=" & $client.lastDiagnostic.code
        echo "message=" & error.msg
      own.closeSession()
      client.close()
      0
    except CatchableError as error:
      echo "intruder_error=" & error.msg.replace("\n", " ")
      4

  if existsEnv(IntruderSocketEnv):
    quit(runIntruder())

  # -------------------------------------------------------------------------
  # Fixture
  # -------------------------------------------------------------------------

  type
    Party = ref object
      ## One client connection with one session, in one group. A ref so the
      ## session's pointer to its client stays valid.
      client: RunQuotaClient
      session: RunQuotaSession
      held: seq[RunQuotaLease]
        ## Leases granted to this party and not yet released.
      nextCandidate: uint64

    Fixture = object
      root: string
      socket: string
      daemon: Process
      env: StringTableRef
      saved: seq[tuple[key: string, had: bool, value: string]]

  proc saveAndSet(fixture: var Fixture; key, value: string) =
    fixture.saved.add((key, existsEnv(key), getEnv(key)))
    if value.len > 0: putEnv(key, value) else: delEnv(key)

  proc restoreEnv(fixture: var Fixture) =
    for i in countdown(fixture.saved.high, 0):
      let entry = fixture.saved[i]
      if entry.had: putEnv(entry.key, entry.value) else: delEnv(entry.key)
    fixture.saved.setLen(0)

  proc cleanGroupEnv(env: StringTableRef) =
    ## This suite may itself run under a launcher that exported a session
    ## group; nothing it starts may inherit that.
    for key in GroupEnvKeys:
      if env.hasKey(key): env.del(key)

  const HostConfigHead = "schema = \"runquota.host-config.v1\"\n"

  proc writeHostConfig(root, admission: string) =
    ## The private daemon's host file (`--host-config root/host.toml`, from
    ## `daemonArgs`): the schema line and, when given, an `[admission]` table.
    writeFile(root / "host.toml", HostConfigHead &
      (if admission.len > 0: "[admission]\n" & admission else: ""))

  proc startFixture(tag: string; extra: openArray[string] = [];
                    launcher: seq[string] = @[]; slots = HostSlots;
                    admission = ""): Fixture =
    ## A private daemon with a `slots`-slot CPU budget (4 by default).
    ## `launcher`, when given, is the command the daemon is started under
    ## (`unshare ...`); `admission`, when given, is the body of the host
    ## file's `[admission]` table, read at start.
    result.root = scratchDir(tag)
    result.socket = result.root / "rq.sock"
    result.env = privateEnv(result.socket)
    cleanGroupEnv(result.env)
    if admission.len > 0:
      writeHostConfig(result.root, admission)
    var args = daemonArgs(result.root, result.socket,
      @["--cpu-milli", $(slots * SlotMilli),
        "--memory-bytes", $(4096'u64 * MiB)] & @extra)
    if launcher.len == 0:
      result.daemon = startProcess(daemonPath(), env = result.env, args = args,
        options = {poStdErrToStdOut})
    else:
      result.daemon = startProcess(launcher[0], env = result.env,
        args = launcher[1 .. ^1] & @[daemonPath()] & args,
        options = {poStdErrToStdOut})
    prerequisite awaitSocket(result.daemon, result.socket),
      startupContext(result.daemon, "the private daemon did not bind")
    # The in-process clients read their endpoint from the environment, as
    # every RunQuota client does.
    result.saveAndSet("RUNQUOTA_ENDPOINT_SCOPE", "private")
    result.saveAndSet("RUNQUOTA_SOCKET", result.socket)
    for key in GroupEnvKeys:
      result.saveAndSet(key, "")

  proc stopFixture(fixture: var Fixture) =
    fixture.restoreEnv()
    stopOwned(fixture.daemon)

  proc party(fixture: Fixture; name: string;
             group: SessionGroupDeclaration): Party =
    result = Party(nextCandidate: 1'u64)
    result.client = connect(unixEndpoint(fixture.socket), name)
    result.session = result.client.registerSession(name, "0", group)

  proc partyFromEnvironment(fixture: Fixture; name: string): Party =
    ## A session registered through the library's default path, which reads
    ## `RUNQUOTA_SESSION` and its attributes from the environment.
    result = Party(nextCandidate: 1'u64)
    result.client = connect(unixEndpoint(fixture.socket), name)
    result.session = result.client.registerSession(name, "0")

  proc group(name: string; priority = sessionPriorityNormal;
             deadline = 0'u64): SessionGroupDeclaration =
    SessionGroupDeclaration(name: name, priorityPresent: true,
      priority: priority, cacheDeadlinePresent: deadline != 0'u64,
      cacheDeadlineUnixMillis: deadline)

  proc offer(p: Party; slots = 1): bool =
    ## Offer one request of `slots` CPU slots. True when it was granted at
    ## once; a queued one is collected later by `collect`.
    let id = p.nextCandidate
    inc p.nextCandidate
    let request = resourceRequest("sga-" & $id,
      milliCpu(slots * SlotMilli), bytes(64'u64 * MiB))
    let decisions = p.session.offerCandidates([toCandidate(id, request)])
    doAssert decisions.len == 1
    doAssert decisions[0].lease.active,
      "the daemon refused a request outright: " & decisions[0].diagnostic.message
    if not decisions[0].queued:
      p.held.add(decisions[0].lease)
      return true
    false

  proc collect(p: Party): int =
    ## Take every grant the daemon has made to this party and not delivered.
    ## `GrantNext` delivers at most one per call, so ask until it has none.
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

  proc releaseAll(p: Party) =
    while p.held.len > 0:
      p.releaseOne()

  proc close(p: Party) =
    try:
      p.releaseAll()
      p.session.closeSession()
    except CatchableError:
      discard
    p.client.close()

  proc statusJson(fixture: Fixture): JsonNode =
    ## `runquota status --json`, through the shipped CLI.
    let (code, output) = cli(fixture.env, ["status", "--json"])
    doAssert code == 0, "runquota status --json failed: " & output
    parseJson(output.strip().splitLines()[^1])

  proc groupNamed(status: JsonNode; name: string): JsonNode =
    for entry in status["session_groups"]:
      if entry["name"].getStr() == name:
        return entry
    nil

  proc unixMillisNow(): uint64 = uint64(epochTime() * 1000.0)

  # -------------------------------------------------------------------------
  # The second uid
  # -------------------------------------------------------------------------

  proc subordinateUidStart(): int64 =
    ## The first subordinate uid `/etc/subuid` grants this user, or -1.
    let pw = getpwuid(getuid())
    let name = if pw != nil: $pw.pw_name else: ""
    if not fileExists("/etc/subuid"):
      return -1
    for line in readFile("/etc/subuid").splitLines():
      let fields = line.strip().split(':')
      if fields.len == 3 and (fields[0] == name or fields[0] == $getuid()):
        try:
          if parseBiggestInt(fields[2]) >= 1:
            return parseBiggestInt(fields[1])
        except ValueError:
          discard
    -1

  proc subordinateGidStart(): int64 =
    let pw = getpwuid(getuid())
    let name = if pw != nil: $pw.pw_name else: ""
    if not fileExists("/etc/subgid"):
      return -1
    for line in readFile("/etc/subgid").splitLines():
      let fields = line.strip().split(':')
      if fields.len == 3 and (fields[0] == name or fields[0] == $getuid()):
        try:
          if parseBiggestInt(fields[2]) >= 1:
            return parseBiggestInt(fields[1])
        except ValueError:
          discard
    -1

  # -------------------------------------------------------------------------
  # Cases
  # -------------------------------------------------------------------------

  suite "session_group_admission":
    test "default_order_whole_machine":
      # Two groups of equal priority each want the whole host. The one that
      # arrived first gets all of it; the other waits until slots free.
      var fixture = startFixture("sgafcfs")
      defer: stopFixture(fixture)
      let blocker = fixture.party("blocker", group("sga-blocker"))
      let first = fixture.party("first", group("sga-first"))
      let second = fixture.party("second", group("sga-second"))
      defer:
        blocker.close()
        first.close()
        second.close()
      for _ in 0 ..< HostSlots:
        check blocker.offer()
      # Both groups queue the whole machine while the blocker holds it. The
      # first offers its work in two installments, the second group's whole
      # request arriving between them, as a build that offers a few
      # candidates at a time does: the first group keeps the place it took
      # with its first request.
      for _ in 0 ..< HostSlots div 2:
        check not first.offer()
      for _ in 0 ..< HostSlots:
        check not second.offer()
      for _ in HostSlots div 2 ..< HostSlots:
        check not first.offer()
      blocker.releaseAll()
      check first.collect() == HostSlots
      check second.collect() == 0
      let busy = fixture.statusJson()
      let firstRow = busy.groupNamed("sga-first")
      let secondRow = busy.groupNamed("sga-second")
      check firstRow != nil and secondRow != nil
      if firstRow != nil and secondRow != nil:
        check firstRow["held_cpu_milli"].getInt() == HostSlots * SlotMilli
        check firstRow["grants_total"].getInt() == HostSlots
        check secondRow["held_cpu_milli"].getInt() == 0
        check secondRow["queued_leases"].getInt() == HostSlots
        check secondRow["oldest_queued_wait_millis"].getInt() >= 0
      # As the first group's slots free, the second group gets them.
      first.releaseOne()
      check second.collect() == 1
      first.releaseAll()
      check second.collect() == HostSlots - 1
      let after = fixture.statusJson().groupNamed("sga-second")
      check after != nil
      if after != nil:
        check after["grants_total"].getInt() == HostSlots
        check after["held_cpu_milli"].getInt() == HostSlots * SlotMilli
        check after["wait_max_millis"].getInt() >= 0

    test "priority_goes_first":
      # A low-priority group queues first; a high-priority group queues
      # later and is granted the next free slots. The priorities arrive the
      # way a launcher sets them: RUNQUOTA_SESSION and
      # RUNQUOTA_SESSION_PRIORITY in the environment of the client.
      var fixture = startFixture("sgaprio")
      defer: stopFixture(fixture)
      let blocker = fixture.party("blocker", group("sga-blocker"))
      putEnv(SessionGroupEnvVar, "sga-low")
      putEnv(SessionPriorityEnvVar, "low")
      let low = fixture.partyFromEnvironment("low")
      putEnv(SessionGroupEnvVar, "sga-high")
      putEnv(SessionPriorityEnvVar, "high")
      let high = fixture.partyFromEnvironment("high")
      delEnv(SessionGroupEnvVar)
      delEnv(SessionPriorityEnvVar)
      defer:
        blocker.close()
        low.close()
        high.close()
      let declared = fixture.statusJson()
      check declared.groupNamed("sga-low") != nil and
        declared.groupNamed("sga-low")["priority"].getStr() == "low"
      check declared.groupNamed("sga-high") != nil and
        declared.groupNamed("sga-high")["priority"].getStr() == "high"
      for _ in 0 ..< HostSlots:
        check blocker.offer()
      for _ in 0 ..< HostSlots:
        check not low.offer()
      for _ in 0 ..< HostSlots:
        check not high.offer()
      blocker.releaseOne()
      check high.collect() == 1
      check low.collect() == 0
      blocker.releaseAll()
      check high.collect() == HostSlots - 1
      check low.collect() == 0

    test "cache_deadline_breaks_ties":
      # Three groups of equal priority, each wanting the whole machine,
      # queue in the order: no deadline, the later deadline, the earlier
      # deadline. They are served earliest deadline first, and the group
      # with no deadline last. The deadlines arrive as a launcher sets them:
      # RUNQUOTA_SESSION_CACHE_TTL.
      var fixture = startFixture("sgattl")
      defer: stopFixture(fixture)
      let blocker = fixture.party("blocker", group("sga-blocker"))
      putEnv(SessionGroupEnvVar, "sga-none")
      let cold = fixture.partyFromEnvironment("none")
      putEnv(SessionGroupEnvVar, "sga-late")
      putEnv(SessionCacheTtlEnvVar, "600")
      let late = fixture.partyFromEnvironment("late")
      putEnv(SessionGroupEnvVar, "sga-early")
      putEnv(SessionCacheTtlEnvVar, "300")
      let early = fixture.partyFromEnvironment("early")
      delEnv(SessionGroupEnvVar)
      delEnv(SessionCacheTtlEnvVar)
      defer:
        blocker.close()
        cold.close()
        late.close()
        early.close()
      let declared = fixture.statusJson()
      let now = unixMillisNow()
      check declared.groupNamed("sga-none")["cache_deadline_unix_millis"].kind == JNull
      let lateDeadline = declared.groupNamed("sga-late")["cache_deadline_unix_millis"].getBiggestInt()
      let earlyDeadline = declared.groupNamed("sga-early")["cache_deadline_unix_millis"].getBiggestInt()
      check earlyDeadline < lateDeadline
      check uint64(earlyDeadline) > now + 200_000'u64
      check blocker.offer(HostSlots)
      check not cold.offer(HostSlots)
      check not late.offer(HostSlots)
      check not early.offer(HostSlots)
      blocker.releaseAll()
      check early.collect() == 1
      check late.collect() == 0
      check cold.collect() == 0
      early.releaseAll()
      check late.collect() == 1
      check cold.collect() == 0
      late.releaseAll()
      check cold.collect() == 1

    test "starvation_bound":
      # A low-priority request queues behind a high-priority group that
      # keeps the host full and always has more queued. Without a bound it
      # would never run; with one it receives its slot within the bound plus
      # one admission cycle (here, one release of the stream).
      const
        MaxWaitMillis = 1500
        CycleMillis = 100
        BudgetMillis = 10_000
        SlackMillis = 300
          ## Scheduling jitter of a shared host, on top of the one cycle.
      var fixture = startFixture("sgastarve",
        ["--admission-max-wait-millis", $MaxWaitMillis])
      defer: stopFixture(fixture)
      let stream = fixture.party("stream", group("sga-stream",
        sessionPriorityHigh))
      let starved = fixture.party("starved", group("sga-starved",
        sessionPriorityLow))
      defer:
        stream.close()
        starved.close()
      for _ in 0 ..< HostSlots:
        check stream.offer()
      check not stream.offer()
      check not stream.offer()
      let queuedAt = getMonoTime()
      check not starved.offer()
      var waited = -1'i64
      while waited < 0 and
          (getMonoTime() - queuedAt).inMilliseconds < BudgetMillis:
        sleep(CycleMillis)
        # One turn of the stream: release the oldest lease (the daemon
        # grants the freed slot at once), keep two requests queued.
        discard stream.collect()
        if stream.held.len > 0:
          stream.releaseOne()
        discard stream.offer()
        if starved.collect() > 0:
          waited = (getMonoTime() - queuedAt).inMilliseconds
      echo "  low-priority request granted after " & $waited & " ms (bound " &
        $MaxWaitMillis & " ms)"
      check waited >= 0
      # Granted by the bound, not by a lull in the stream: not before it.
      check waited >= MaxWaitMillis - CycleMillis
      check waited <= MaxWaitMillis + CycleMillis + SlackMillis
      let status = fixture.statusJson()
      check status["admission_max_wait_millis"].getInt() == MaxWaitMillis

    test "starvation_holds_slots":
      # Backfill never delays a request held under the bound. A low-priority
      # request for TWO slots waits behind a high-priority stream of
      # one-slot requests that keeps the host full and keeps two young
      # requests queued. Once the two-slot request has waited out the bound,
      # a freed slot is not handed to the stream: it is held until a second
      # one frees, and the starved request gets both.
      const
        MaxWaitMillis = 1000
        MarginMillis = 250
        QuietMillis = 300
        CycleMillis = 100
        BudgetMillis = 10_000
      var fixture = startFixture("sgahold",
        ["--admission-max-wait-millis", $MaxWaitMillis])
      defer: stopFixture(fixture)
      let stream = fixture.party("stream", group("sga-stream",
        sessionPriorityHigh))
      let starved = fixture.party("starved", group("sga-starved",
        sessionPriorityLow))
      defer:
        stream.close()
        starved.close()
      for _ in 0 ..< HostSlots:
        check stream.offer()
      check not stream.offer()
      check not stream.offer()
      let queuedAt = getMonoTime()
      check not starved.offer(2)
      # Until shortly before the bound, the stream turns over: each freed
      # slot goes to its oldest queued request (the two-slot request does not
      # fit in one -- backfill), and a new request takes that one's place.
      # Its queued requests therefore stay younger than the bound and are
      # never starved themselves when the checks below run.
      var turned = 0
      while (getMonoTime() - queuedAt).inMilliseconds <
          MaxWaitMillis - QuietMillis:
        sleep(CycleMillis)
        stream.releaseOne()
        turned += stream.collect()
        discard stream.offer()
      check turned > 0
      check starved.collect() == 0
      check stream.held.len == HostSlots
      # Then quiet until the bound has passed. `queuedAt` is read before the
      # request is sent, so the daemon's own clock for it starts a little
      # later; the margin keeps this side from acting before the daemon
      # counts it as starved.
      while (getMonoTime() - queuedAt).inMilliseconds <=
          MaxWaitMillis + MarginMillis:
        sleep(CycleMillis div 2)
      # Past the bound: the first freed slot is held, not granted to the
      # stream's queued requests ...
      stream.releaseOne()
      check stream.collect() == 0
      check starved.collect() == 0
      let held = fixture.statusJson().groupNamed("sga-stream")
      check held != nil
      if held != nil:
        check held["held_cpu_milli"].getInt() == (HostSlots - 1) * SlotMilli
        check held["queued_leases"].getInt() == 2
      # ... and when the second one frees, the starved request gets both.
      stream.releaseOne()
      check starved.collect() == 1
      check stream.collect() == 0
      check (getMonoTime() - queuedAt).inMilliseconds < BudgetMillis
      let after = fixture.statusJson().groupNamed("sga-starved")
      check after != nil
      if after != nil:
        check after["held_cpu_milli"].getInt() == 2 * SlotMilli

    test "update_refused_for_other_uid":
      # The owner's group cannot be changed from a connection whose peer
      # credentials name another uid, and its attributes are unchanged.
      let unshareExe = findExe("unshare")
      let nsenterExe = findExe("nsenter")
      let subUid = subordinateUidStart()
      let subGid = subordinateGidStart()
      let uid = int64(getuid())
      let gid = int64(getgid())
      if unshareExe.len == 0 or nsenterExe.len == 0 or subUid < 0 or
          subGid < 0 or findExe("newuidmap").len == 0:
        echo "  NOT RUN: a second uid needs unshare, nsenter, newuidmap and " &
          "a subordinate uid and gid range for this user (found unshare=" &
          unshareExe & " nsenter=" & nsenterExe & " subuid=" & $subUid &
          " subgid=" & $subGid & ")"
        check false
      else:
        var fixture = startFixture("sgauid", launcher = @[unshareExe,
          "--user",
          "--map-users=" & $uid & ":" & $uid & ":1",
          "--map-users=0:" & $subUid & ":1",
          "--map-groups=" & $gid & ":" & $gid & ":1",
          "--map-groups=0:" & $subGid & ":1",
          "--"])
        defer: stopFixture(fixture)
        let deadline = unixMillisNow() + 600_000'u64
        let owner = fixture.party("owner", group("sga-owned",
          sessionPriorityNormal, deadline))
        defer: owner.close()
        let before = fixture.statusJson().groupNamed("sga-owned")
        check before != nil
        check before["owner_uid"].getBiggestInt() == uid
        check before["priority"].getStr() == "normal"
        check before["cache_deadline_unix_millis"].getBiggestInt() ==
          int64(deadline)

        var intruderEnv = newStringTable(modeCaseSensitive)
        for key, value in fixture.env:
          intruderEnv[key] = value
        intruderEnv[IntruderSocketEnv] = fixture.socket
        intruderEnv[IntruderGroupEnv] = "sga-owned"
        let intruder = startProcess(nsenterExe, env = intruderEnv,
          args = ["--user", "--target", $fixture.daemon.processID, "--",
            getAppFilename()],
          options = {poStdErrToStdOut})
        let report = intruder.outputStream.readAll()
        let code = intruder.waitForExit(60_000)
        intruder.close()
        echo report.strip().indent(2)
        check code == 0
        check "update=refused" in report
        check "code=diagDenied" in report
        check "belongs to another user" in report
        # A DIFFERENT UID WAS SERVED, not refused at the door: its own
        # session registered, and the daemon recorded its group under an
        # owner other than this uid.
        check "own_session=" in report
        check "uid=0" in report
        check "own_group_owner_uid=0" in report
        check "own_group_priority=low" in report

        let after = fixture.statusJson()
        let owned = after.groupNamed("sga-owned")
        check owned != nil
        check owned["priority"].getStr() == "normal"
        check owned["cache_deadline_unix_millis"].getBiggestInt() ==
          int64(deadline)

        # The owner may: the same change through the shipped CLI succeeds.
        let (setCode, setOutput) = cli(fixture.env, ["session", "set",
          "sga-owned", "--priority", "urgent", "--cache-deadline", "none"])
        check setCode == 0
        check "priority=urgent" in setOutput
        let changed = fixture.statusJson().groupNamed("sga-owned")
        check changed["priority"].getStr() == "urgent"
        check changed["cache_deadline_unix_millis"].kind == JNull

    test "missing_session_group_is_interactive":
      # A client from before session groups sends a RegisterSession with no
      # group block at all. It is admitted in its user's interactive group,
      # at high priority: ahead of a normal-priority group that queued first.
      var fixture = startFixture("sgaold")
      defer: stopFixture(fixture)
      let blocker = fixture.party("blocker", group("sga-blocker"))
      let agent = fixture.party("agent", group("sga-agent"))
      defer:
        blocker.close()
        agent.close()
      # The old client: a real connection, and the RegisterSession payload
      # written field by field the way a client before groups wrote it.
      let old = Party(nextCandidate: 1'u64)
      old.client = connect(unixEndpoint(fixture.socket), "old-client")
      defer: old.close()
      var payload = writer()
      payload.writeString("old-client")
      payload.writeString("0")
      payload.writeMetadata(metadataNone())
      old.client.connection.sendFrame(encodeFrame(rqRegisterSession,
        FrameFlagRequest, 900'u64, payload.data))
      var frame: RqspFrame
      check old.client.connection.receiveFrame(frame)
      check frame.header.messageKind == rqSessionRegistered
      var registered: SessionRegisteredMessage
      check decodeSessionRegistered(frame.payload, registered)
      old.session = RunQuotaSession(client: addr old.client,
        id: registered.sessionId, active: true)

      let interactive = fixture.statusJson().groupNamed(InteractiveSessionGroup)
      check interactive != nil
      check interactive["owner_uid"].getBiggestInt() == int64(getuid())
      check interactive["priority"].getStr() == "high"
      check interactive["sessions"].getInt() == 1

      for _ in 0 ..< HostSlots:
        check blocker.offer()
      for _ in 0 ..< HostSlots:
        check not agent.offer()
      for _ in 0 ..< HostSlots:
        check not old.offer()
      blocker.releaseAll()
      check old.collect() == HostSlots
      check agent.collect() == 0

    test "fair_share_order":
      # The host file asks for equal shares: order = [starvation, fair-share,
      # arrival]. Three groups of equal priority each want the whole host
      # (six slots) and keep wanting it. They hold equal shares, within 10%,
      # while their leases turn over. Then the file goes back to the default
      # order and the daemon is only asked to reload: from the next freed
      # slot on, the group that became busy first is served first again.
      const
        Slots = 6
        Rounds = 12
        FairOrder = "order = [\"starvation\", \"fair-share\", \"arrival\"]\n"
      var fixture = startFixture("sgafair", slots = Slots,
        admission = FairOrder)
      defer: stopFixture(fixture)
      let configured = fixture.statusJson()
      check configured["admission_order"] == %["starvation", "fair-share",
        "arrival"]
      let blocker = fixture.party("blocker", group("sga-blocker"))
      let parties = [fixture.party("a", group("sga-fair-a")),
        fixture.party("b", group("sga-fair-b")),
        fixture.party("c", group("sga-fair-c"))]
      let names = ["sga-fair-a", "sga-fair-b", "sga-fair-c"]
      defer:
        blocker.close()
        for p in parties:
          p.close()
      for _ in 0 ..< Slots:
        check blocker.offer()
      for p in parties:
        for _ in 0 ..< Slots:
          check not p.offer()
      # The whole host frees at once: ONE admission pass spreads it.
      blocker.releaseAll()
      var held: array[3, int]
      for i, p in parties:
        held[i] = p.collect()
      echo "  after the blocker: held " & $held
      check held == [2, 2, 2]

      # Turnover: in each round every group releases its oldest lease and
      # offers another, so each keeps wanting the whole host. The held CPU
      # each group's status row reports is sampled after every release, and
      # summed: the share each group held over the run.
      var heldSum: array[3, int]
      var grants: array[3, int]
      for i in 0 ..< 3:
        grants[i] = held[i]
      for round in 0 ..< Rounds:
        for turn in 0 ..< 3:
          # Rotate who releases first, so no group is always first to ask.
          let i = (round + turn) mod 3
          parties[i].releaseOne()
          discard parties[i].offer()
          for j, p in parties:
            grants[j] += p.collect()
          let status = fixture.statusJson()
          for j, name in names:
            let row = status.groupNamed(name)
            check row != nil
            if row != nil:
              heldSum[j] += row["held_cpu_milli"].getInt()
      echo "  fair-share turnover: grants " & $grants & ", held-cpu samples " &
        $heldSum
      let meanHeld = (heldSum[0] + heldSum[1] + heldSum[2]) / 3
      let meanGrants = (grants[0] + grants[1] + grants[2]) / 3
      check meanHeld > 0
      for j in 0 ..< 3:
        check abs(float(heldSum[j]) - meanHeld) <= 0.10 * meanHeld
        check abs(float(grants[j]) - meanGrants) <= 0.10 * meanGrants
      let busy = fixture.statusJson()
      for name in names:
        let row = busy.groupNamed(name)
        check row != nil and row["held_cpu_milli"].getInt() == 2 * SlotMilli
        # The decayed figure the order uses is reported, and grows with use.
        check row != nil and row["recent_cpu_milli_seconds"].getInt() >= 0

      # Back to the default order: the file loses its [admission] table, and
      # the running daemon is asked to reload it. Nothing else changes.
      writeHostConfig(fixture.root, "")
      let (reloadCode, reloadOutput) = cli(fixture.env, ["config", "reload"])
      check reloadCode == 0
      check "runquotad reloaded its host configuration" in reloadOutput
      let reloaded = fixture.statusJson()
      check reloaded["admission_order"] == %["starvation", "priority",
        "cache-deadline", "arrival"]
      # Default order: group a became busy first and still wants the whole
      # host, so every slot b and c free goes to a. (Under fair-share each
      # freed slot went back to the group that freed it.)
      for _ in 0 ..< 2:
        for i in 1 .. 2:
          parties[i].releaseOne()
          discard parties[i].offer()
          check parties[i].collect() == 0
          check parties[0].collect() == 1
      let after = fixture.statusJson()
      check after.groupNamed("sga-fair-a")["held_cpu_milli"].getInt() ==
        Slots * SlotMilli
      check after.groupNamed("sga-fair-b")["held_cpu_milli"].getInt() == 0
      check after.groupNamed("sga-fair-c")["held_cpu_milli"].getInt() == 0

    test "max_wait_flag_over_host_file":
      # The host file says 45 s; the flag says 1.5 s. The flag wins, on start
      # and after a reload that changes the file, and the reload says it
      # pinned the key. Without the flag the file's bound is in force.
      var pinned = startFixture("sgawaitflag",
        ["--admission-max-wait-millis", "1500"],
        admission = "max-wait = \"45s\"\n")
      defer: stopFixture(pinned)
      check pinned.statusJson()["admission_max_wait_millis"].getInt() == 1500
      writeHostConfig(pinned.root, "max-wait = \"10s\"\n")
      let (code, output) = cli(pinned.env, ["config", "reload"])
      check code == 0
      check "admission.max-wait" in output
      check pinned.statusJson()["admission_max_wait_millis"].getInt() == 1500
      let (topoCode, topoOutput) = cli(pinned.env, ["topology", "--json"])
      check topoCode == 0
      check "\"admission.max-wait\"" in topoOutput

      var fromFile = startFixture("sgawaitfile",
        admission = "max-wait = \"45s\"\n")
      defer: stopFixture(fromFile)
      check fromFile.statusJson()["admission_max_wait_millis"].getInt() ==
        45_000
      writeHostConfig(fromFile.root, "max-wait = \"10s\"\n")
      check cli(fromFile.env, ["config", "reload"]).code == 0
      check fromFile.statusJson()["admission_max_wait_millis"].getInt() ==
        10_000

    test "invalid_order_refused":
      # A repeated key stops the daemon at start, with the file and line.
      let root = scratchDir("sgabadorder")
      let socket = root / "rq.sock"
      writeHostConfig(root, "order = [\"priority\", \"priority\"]\n")
      var env = privateEnv(socket)
      cleanGroupEnv(env)
      let refused = launch(root, socket, env)
      let code = refused.exitWithin(30_000)
      let said = refused.output
      refused.close()
      check code == 2
      check "host.toml:3: admission order lists `priority` twice" in said

      # Under a running daemon, an unknown key is refused by the reload and
      # the order in force is unchanged.
      var fixture = startFixture("sgabadreload",
        admission = "order = [\"fair-share\", \"arrival\"]\n")
      defer: stopFixture(fixture)
      # The refused file also changes the bound and the division; neither
      # may take effect, because the file as a whole did not parse.
      writeHostConfig(fixture.root, "order = [\"fairshare\"]\n" &
        "max-wait = \"10s\"\nshare-between-users = \"none\"\n")
      let (reloadCode, reloadOutput) = cli(fixture.env, ["config", "reload"])
      check reloadCode == 1
      check "unknown admission order key `fairshare`" in reloadOutput
      let kept = fixture.statusJson()
      check kept["admission_order"] == %["fair-share", "arrival"]
      check kept["admission_max_wait_millis"].getInt() == 120_000
      check kept["admission_share_between_users"].getStr() == "drf"
      # An empty order is refused the same way.
      writeHostConfig(fixture.root, "order = []\n")
      let (emptyCode, emptyOutput) = cli(fixture.env, ["config", "reload"])
      check emptyCode == 1
      check "admission order is empty" in emptyOutput
      check fixture.statusJson()["admission_order"] == %["fair-share",
        "arrival"]
      # And the order still in force is the one ADMISSION uses, not only the
      # one status prints: two busy groups wanting the whole host split it
      # (fair-share). Had the refused reload put the default in force, the
      # group that queued first would take all of it.
      let blocker = fixture.party("blocker", group("sga-blocker"))
      let first = fixture.party("first", group("sga-kept-a"))
      let second = fixture.party("second", group("sga-kept-b"))
      defer:
        blocker.close()
        first.close()
        second.close()
      for _ in 0 ..< HostSlots:
        check blocker.offer()
      for _ in 0 ..< HostSlots:
        check not first.offer()
      for _ in 0 ..< HostSlots:
        check not second.offer()
      blocker.releaseAll()
      check first.collect() == HostSlots div 2
      check second.collect() == HostSlots div 2

    test "fair_share_unequal_sizes":
      # Two busy groups whose requests differ in width: "wide" asks for two
      # slots at a time, "narrow" for one. Under the default order wide,
      # which became busy first, takes the whole host. A reload to
      # [starvation, fair-share, arrival] -- nothing else -- moves the host
      # to equal CPU as wide's leases end, and keeps it there while both
      # turn their leases over. Ignoring the reload leaves wide with three
      # quarters (six slots to narrow's two).
      const Slots = 8
      var fixture = startFixture("sgafairsize", slots = Slots)
      defer: stopFixture(fixture)
      let wide = fixture.party("wide", group("sga-size-wide"))
      let narrow = fixture.party("narrow", group("sga-size-narrow"))
      defer:
        wide.close()
        narrow.close()
      for _ in 0 ..< Slots div 2:
        check wide.offer(2)
      for _ in 0 ..< Slots:
        check not narrow.offer()
      check narrow.collect() == 0
      writeHostConfig(fixture.root,
        "order = [\"starvation\", \"fair-share\", \"arrival\"]\n")
      let (reloadCode, reloadOutput) = cli(fixture.env, ["config", "reload"])
      if reloadCode != 0: echo reloadOutput
      check reloadCode == 0
      proc heldBy(name: string): int =
        let row = fixture.statusJson().groupNamed(name)
        if row == nil: -1 else: row["held_cpu_milli"].getInt()
      # Wide keeps wanting the host: every lease it ends is offered again.
      var wideGrants = 0
      var narrowGrants = 0
      var wideSum = 0
      var narrowSum = 0
      for round in 0 ..< 12:
        if round mod 2 == 0:
          wide.releaseOne()
          if not wide.offer(2):
            discard
          else:
            inc wideGrants
        else:
          narrow.releaseOne()
          if narrow.offer():
            inc narrowGrants
        wideGrants += wide.collect()
        narrowGrants += narrow.collect()
        if round >= 4:
          wideSum += heldBy("sga-size-wide")
          narrowSum += heldBy("sga-size-narrow")
      echo "  unequal sizes: held-cpu samples wide " & $wideSum & ", narrow " &
        $narrowSum & "; grants wide " & $wideGrants & ", narrow " &
        $narrowGrants
      check heldBy("sga-size-wide") == (Slots div 2) * SlotMilli
      check heldBy("sga-size-narrow") == (Slots div 2) * SlotMilli
      let mean = (wideSum + narrowSum) / 2
      check mean > 0
      check abs(float(wideSum) - mean) <= 0.10 * mean
      check abs(float(narrowSum) - mean) <= 0.10 * mean
