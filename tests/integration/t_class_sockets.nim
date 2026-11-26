## One daemon socket per reservation class, with real accounts: who may claim
## a class is decided by the kernel's access check on the class's socket.
##
## RAN ON: Linux (x86_64), accounts in a user namespace with subordinate ids
## (`tests/support/class_socket_accounts`). The same scenarios run on macOS
## and Windows once that module has their variant; each scenario prints the
## platform it ran on.
##
## WHAT IS GUARDED, and the change to the daemon each case fails under.
##
## * `class_socket_refuses_unpermitted_user` -- with `[reservation.ci]`
##   declaring `socket-group = "ci"`, `socket-mode = "0660"`, a user outside
##   `ci` (but in the rendezvous group) who exports `RUNQUOTA_CLASS=ci` cannot
##   connect to `class-ci.sock`: the client fails naming the socket and the
##   class, opens no session, and `status --json` shows no group of class
##   `ci` for that user. Mutation: creating the class socket with mode `0666`
##   lets the refused user's session register in class `ci`. (A client that
##   fell back to the shared socket is refused there:
##   `shared_socket_refuses_class_claim`.)
## * `class_socket_permitted_claim` -- a member of `ci` connects on
##   `class-ci.sock`, `HelloOk` there names `ci`, its session's group carries
##   class `ci` and its owner is the member's uid, and it is granted within
##   the class's reservation ahead of queued unclassed work. Mutation: the
##   daemon ignoring which socket a connection arrived on gives the session
##   no class, so its request waits behind the unclassed queue.
## * `shared_socket_refuses_class_claim` -- a class block over the shared
##   socket (the bytes a minor-12 client sends), from a member of `ci` and
##   from a non-member alike, is refused naming `class-ci.sock`, and no
##   session is registered; a session over the shared socket that would join
##   an existing group of class `ci` is refused naming the class; a
##   registration with no class over the shared socket still succeeds.
##   Mutation: accepting the class block on the shared socket, as before
##   class sockets, registers the session in class `ci`.
## * `class_sockets_created_as_declared` -- for `ci` (`socket-group = "ci"`,
##   `0660`) and `gpu` (the defaults) the daemon creates `class-ci.sock` and
##   `class-gpu.sock` beside its endpoint with exactly the declared owner,
##   group and mode (`lstat`), and no socket for an undeclared class; a
##   process reading the socket's mode and group in a loop while the daemon
##   starts and while reloads add and drop a class never sees a bit the
##   declaration lacks nor another group; a reload that drops `gpu` unlinks
##   its socket and keeps a session already connected on it in class `gpu`;
##   a declared group the daemon's account is not in refuses the start
##   (exit 2) naming it. Mutations: binding the socket in place with the
##   process's umask and only then changing the mode lets the reader see a
##   wider mode and the default group; skipping the group change leaves the
##   default group and fails the `lstat` assertion.
##
## HOW IT RUNS. The suite (this process, the invoking user) re-executes this
## binary as the root of a user namespace (`enterAccountsHost`), which
## creates the accounts and runs one scenario: a real `runquotad` as `rqd`,
## real clients -- this binary again, in its client role, through the real
## client library -- as `member` and `outsider`, and the shipped `runquota`
## CLI for `status` and `config reload`. The scenario's verdict is its exit
## status; its output is printed. A host without the namespace tools or a
## subordinate id range reports every case SKIPPED, with the reason.
##
## NO MOCKS: the kernel's own checks on real sockets under real, distinct
## credentials. The daemon never runs as the invoking user, so nothing here
## can touch the host's daemon or its endpoint.

when defined(linux):
  import std/[json, os, osproc, posix, sets, streams, strtabs,
    strutils, tables, tempfiles, times, unittest]

  import runquota_client
  import runquota_core
  import runquota_ipc
  import runquota_protocol
  import class_socket_accounts
  import daemon_binary

  const
    Head = "schema = \"runquota.host-config.v1\"\n"
    ClientRoleEnvVar = "RUNQUOTA_TEST_CLASS_SOCKET_CLIENT"
    PollRoleEnvVar = "RUNQUOTA_TEST_CLASS_SOCKET_POLL"
    BinariesEnvVar = "RUNQUOTA_TEST_CLASS_SOCKET_BIN"
    MiB = 1024'u64 * 1024'u64

  proc oneLine(text: string): string =
    text.replace('\n', ' ').replace('\r', ' ').strip()

  # -------------------------------------------------------------------------
  # The client role: one RunQuota client, as whichever account started it.
  # Configured by the environment, it prints one line per step and holds its
  # session until its standard input closes.
  # -------------------------------------------------------------------------

  proc clientRole(): int =
    let action = getEnv(ClientRoleEnvVar)
    let className = getEnv("RQCS_CLASS")
    let group = getEnv("RQCS_GROUP")
    let cpu = parseInt(getEnv("RQCS_CPU", "1000"))
    let count = parseInt(getEnv("RQCS_COUNT", "0"))
    let waitMillis = parseInt(getEnv("RQCS_WAIT_MS", "0"))
    var client: RunQuotaClient
    try:
      # `shared`: the shared socket whatever the class, the way a client
      # that predates class sockets (or one that fell back) reaches it.
      client =
        if action == "shared": connect(defaultEndpoint(), "rqcs")
        else: connectForClass(className, defaultEndpoint(), "rqcs")
    except CatchableError as error:
      echo "connect-failed " & oneLine(error.msg)
      return 3
    echo "connected socket_class=" &
      (if client.socketClass.len > 0: client.socketClass else: "-")
    flushFile(stdout)
    var session: RunQuotaSession
    try:
      session = client.registerSession("rqcs", "0", SessionGroupDeclaration(
        name: group, priority: sessionPriorityNormal, className: className))
    except CatchableError as error:
      echo "register-refused " & oneLine(error.msg)
      return 4
    echo "registered session=" & $session.id.value
    flushFile(stdout)
    var held: seq[RunQuotaLease] = @[]
    var queued = 0
    for i in 1 .. count:
      let decisions = session.offerCandidates([toCandidate(uint64(i),
        resourceRequest("rqcs-" & $i, milliCpu(cpu), bytes(64'u64 * MiB)))])
      if decisions.len != 1 or not decisions[0].lease.active:
        echo "denied " & (if decisions.len == 1:
          oneLine(decisions[0].diagnostic.message) else: "no decision")
      elif decisions[0].queued:
        inc queued
      else:
        held.add(decisions[0].lease)
    echo "offers granted=" & $held.len & " queued=" & $queued
    flushFile(stdout)
    if waitMillis > 0 and queued > 0:
      let deadline = epochTime() + float(waitMillis) / 1000.0
      while queued > 0 and epochTime() < deadline:
        for decision in session.pollNextGrant():
          if not decision.queued and decision.lease.active:
            held.add(decision.lease)
            dec queued
        sleep(50)
      echo "after-wait granted=" & $held.len & " queued=" & $queued
      flushFile(stdout)
    var line = ""
    discard stdin.readLine(line)
    if line.strip() == "offer":
      # One more request after whatever happened meanwhile (a reload).
      let decisions = session.offerCandidates([toCandidate(9999'u64,
        resourceRequest("rqcs-late", milliCpu(cpu), bytes(64'u64 * MiB)))])
      echo "late-offer active=" & $(decisions.len == 1 and
        decisions[0].lease.active)
      flushFile(stdout)
      discard stdin.readLine(line)
    for lease in held.mitems:
      try: lease.release()
      except CatchableError: discard
    try: session.closeSession()
    except CatchableError: discard
    client.close()
    echo "closed"
    0

  # -------------------------------------------------------------------------
  # The poll role: read the mode, owner and group of each path in a tight
  # loop until standard input closes, and print every distinct state seen.
  # -------------------------------------------------------------------------

  proc pollRole(): int =
    ## The last path is the STOP FILE: the loop ends once it exists. (Not
    ## standard input: the daemon started after this process inherits the
    ## write end of its pipe, so closing ours would never reach it.)
    let all = getEnv(PollRoleEnvVar).split(',')
    let stopFile = all[^1]
    let paths = all[0 ..< all.high]
    var seen = initHashSet[string]()
    var reads = 0
    var round = 0
    # Per path: how many reads found it, and how many times it APPEARED
    # (absent, then present) -- each appearance is a creation the reader
    # watched, which is what the never-wider check needs to have seen.
    var found = newSeq[int](paths.len)
    var appeared = newSeq[int](paths.len)
    var present = newSeq[bool](paths.len)
    while true:
      inc round
      if round mod 256 == 0 and fileExists(stopFile):
        break
      for i, path in paths:
        var info: Stat
        if lstat(path.cstring, info) == 0:
          inc reads
          inc found[i]
          if not present[i]:
            inc appeared[i]
          present[i] = true
          seen.incl(path.extractFilename & " " &
            toOct(int(info.st_mode) and 0o7777, 4) & " " & $info.st_uid & " " &
            $info.st_gid)
        else:
          present[i] = false
    for state in seen:
      echo "seen " & state
    for i, path in paths:
      echo "found " & path.extractFilename & " " & $found[i] & " " &
        $appeared[i]
    echo "reads " & $reads
    0

  # -------------------------------------------------------------------------
  # The scenarios, run inside the accounts host as its root.
  # -------------------------------------------------------------------------

  type
    Host = object
      daemonAccount: Account
        ## Whom the daemon runs as: `rqd`, or root for the cases about a
        ## root daemon.
      root, bin, run, state, socket, hostFile: string
      daemon: Process
      daemonOutput: string
      clientEnv: StringTableRef
    Client = object
      process: Process
      lines: seq[string]

  var failures: seq[string] = @[]

  template expect(condition: bool; what: string) =
    if not condition:
      let at = instantiationInfo()
      failures.add(what & " (line " & $at.line & ")")
      echo "  FAILED: " & what

  proc baseEnv(host: Host): StringTableRef =
    result = newStringTable(modeCaseSensitive)
    result["PATH"] = getEnv("PATH")
    result["HOME"] = host.state
    result["RUNQUOTA_ENDPOINT_SCOPE"] = "host"
    result["RUNQUOTA_ENDPOINT_GROUP"] = RendezvousGroup.name
    result["RUNQUOTA_ENDPOINT_OWNER_UID"] = $host.daemonAccount.uid
    result["RUNQUOTA_SOCKET"] = host.socket
    result["RUNQUOTA_CGROUP_ROOT"] = "off"

  proc newHost(tag: string; daemonAccount = RqdAccount): Host =
    ## A scratch host: binaries every account can run, a state directory
    ## for the daemon, and the rendezvous directory provisioned as the
    ## install step would (owner the daemon's account, group the rendezvous
    ## group, `0750`).
    result.daemonAccount = daemonAccount
    result.root = createTempDir("rqcs-" & tag & "-", "", "/tmp")
    setFilePermissions(result.root, {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
    result.bin = result.root / "bin"
    createDir(result.bin)
    let sources = getEnv(BinariesEnvVar).split(',')
    for source in sources:
      let target = result.bin / source.extractFilename
      copyFile(source, target)
      setFilePermissions(target, {fpUserRead, fpUserWrite, fpUserExec,
        fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
    setFilePermissions(result.bin, {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
    result.state = result.root / "state"
    createDir(result.state)
    chownTo(result.state, daemonAccount)
    setFilePermissions(result.state, {fpUserRead, fpUserWrite, fpUserExec})
    result.run = result.root / "run"
    createDir(result.run)
    chownTo(result.run, daemonAccount, RendezvousGroup.gid)
    setFilePermissions(result.run, {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec})
    result.socket = result.run / "runquotad.sock"
    result.hostFile = result.root / "host.toml"
    result.clientEnv = result.baseEnv()

  proc writeHostFile(host: Host; body: string) =
    writeFile(host.hostFile, Head & body)
    setFilePermissions(host.hostFile, {fpUserRead, fpUserWrite, fpGroupRead,
      fpOthersRead})

  proc daemonArguments(host: Host; cpuMilli: int): seq[string] =
    @["--socket", host.socket, "--host-config", host.hostFile,
      "--host-identity-file", host.state / "host-id",
      "--estimate-db", host.state / "est.sqlite", "--no-write-stats",
      "--ambient-sample-interval-millis", "0",
      "--memory-pressure-source", "unavailable",
      "--cpu-pressure-file", host.state / "cpu-pressure",
      "--cpu-milli", $cpuMilli, "--memory-bytes", $(8'u64 * 1024'u64 * MiB)]

  proc startDaemon(host: var Host; cpuMilli = 2000;
                   waitFor: openArray[string] = []): bool =
    ## Start `runquotad` as the daemon's account; true once its endpoint and
    ## every path in `waitFor` exist, false when it exited first (its output
    ## is then in `daemonOutput`).
    host.daemon = startAs(host.daemonAccount, host.bin / "runquotad",
      host.daemonArguments(cpuMilli), host.baseEnv())
    let deadline = epochTime() + 30.0
    while epochTime() < deadline:
      if not host.daemon.running:
        host.daemonOutput = host.daemon.outputStream.readAll()
        return false
      var info: Stat
      var ready = lstat(host.socket.cstring, info) == 0
      for path in waitFor:
        if lstat(path.cstring, info) != 0:
          ready = false
      if ready:
        return true
      sleep(20)
    false

  proc stopDaemon(host: var Host) =
    if host.daemon != nil:
      if host.daemon.running:
        host.daemon.terminate()
      discard host.daemon.waitForExit(30_000)
      host.daemon.close()
      host.daemon = nil

  proc cliAs(host: Host; account: Account; args: openArray[string]):
      tuple[code: int, output: string] =
    let process = startAs(account, host.bin / "runquota", args, host.clientEnv)
    process.inputStream.close()
    let output = process.outputStream.readAll()
    let code = process.waitForExit()
    process.close()
    (code: code, output: output)

  proc status(host: Host): JsonNode =
    let (code, output) = host.cliAs(RqdAccount, ["status", "--json"])
    if code != 0:
      echo "  status failed: " & output
      return newJObject()
    parseJson(output.strip().splitLines()[^1])

  proc reload(host: Host; body: string): tuple[code: int, output: string] =
    host.writeHostFile(body)
    host.cliAs(RqdAccount, ["config", "reload"])

  proc groupsOf(status: JsonNode; uid: int): seq[JsonNode] =
    if status.hasKey("session_groups"):
      for group in status["session_groups"]:
        if group["owner_uid"].kind == JInt and group["owner_uid"].getInt() == uid:
          result.add(group)

  proc startClient(host: Host; account: Account; action, className: string;
                   group = ""; count = 0; cpu = 1000; waitMillis = 0): Client =
    let env = newStringTable(modeCaseSensitive)
    for key, value in host.clientEnv: env[key] = value
    env[ClientRoleEnvVar] = action
    env["RQCS_CLASS"] = className
    env["RQCS_GROUP"] = group
    env["RQCS_COUNT"] = $count
    env["RQCS_CPU"] = $cpu
    env["RQCS_WAIT_MS"] = $waitMillis
    # `RUNQUOTA_CLASS` as a launcher exports it; the role passes it on.
    if className.len > 0: env[ClassEnvVar] = className
    result.process = startAs(account, host.bin / getAppFilename().extractFilename,
      [], env)

  proc readUntil(client: var Client; prefixes: openArray[string]): string =
    ## The first line starting with one of `prefixes`, or "" at end of output.
    var line = ""
    while client.process.outputStream.readLine(line):
      client.lines.add(line)
      for prefix in prefixes:
        if line.startsWith(prefix):
          return line
    ""

  proc finish(client: var Client; say = "") =
    if client.process == nil:
      return
    try:
      if say.len > 0:
        client.process.inputStream.writeLine(say)
        client.process.inputStream.flush()
      client.process.inputStream.close()
    except CatchableError:
      discard
    var line = ""
    while client.process.outputStream.readLine(line):
      client.lines.add(line)
    discard client.process.waitForExit(30_000)
    client.process.close()
    client.process = nil

  proc socketState(path: string): ClassSocketState = inspectClassSocket(path)

  proc ciTable(mode = "0660"): string =
    "[reservation.ci]\ncpu-milli = 1000\nlend = false\n" &
      "socket-group = \"ci\"\nsocket-mode = \"" & mode & "\"\n"

  proc scenarioRefusesUnpermittedUser() =
    var host = newHost("refuse")
    defer:
      host.stopDaemon()
      removeDir(host.root)
    host.writeHostFile(ciTable())
    let ciSocket = host.run / "class-ci.sock"
    expect host.startDaemon(waitFor = [ciSocket]),
      "the daemon starts: " & host.daemonOutput
    var outsider = host.startClient(OutsiderAccount, "claim", "ci", count = 1)
    let first = outsider.readUntil(["connect-failed", "connected"])
    outsider.finish()
    echo "  outsider: " & first
    expect first.startsWith("connect-failed"),
      "the outsider cannot connect on the class socket"
    expect ciSocket in first, "the refusal names the socket"
    expect "class ci" in first, "the refusal names the class"
    expect "fall back" in first, "the refusal says there is no fallback"
    let status = host.status()
    var classed = 0
    for group in status.groupsOf(OutsiderAccount.uid):
      if group["class"].kind == JString and group["class"].getStr() == "ci":
        inc classed
    expect classed == 0, "no session group of class ci for the outsider"
    expect status{"active_sessions"}.getInt(-1) == 0,
      "no session at all was opened"

  proc scenarioPermittedClaim() =
    var host = newHost("permit")
    defer:
      host.stopDaemon()
      removeDir(host.root)
    host.writeHostFile(ciTable())
    let ciSocket = host.run / "class-ci.sock"
    expect host.startDaemon(cpuMilli = 2000, waitFor = [ciSocket]),
      "the daemon starts: " & host.daemonOutput
    # UNCLASSED WORK FIRST: it takes the one CPU the reservation leaves and
    # queues for more. The reserved CPU is not lent (`lend = false`).
    var outsider = host.startClient(OutsiderAccount, "claim", "", count = 2)
    let outsiderOffers = outsider.readUntil(["offers", "connect-failed",
      "register-refused"])
    echo "  outsider: " & outsiderOffers
    expect outsiderOffers == "offers granted=1 queued=1",
      "unclassed work holds one CPU and queues for another"
    var member = host.startClient(MemberAccount, "claim", "ci", count = 1)
    let connected = member.readUntil(["connected", "connect-failed"])
    echo "  member: " & connected
    expect connected == "connected socket_class=ci",
      "HelloOk on the class socket names ci"
    let offers = member.readUntil(["offers", "register-refused"])
    echo "  member: " & offers
    expect offers == "offers granted=1 queued=0",
      "the member is granted within the reservation, ahead of the queue"
    let status = host.status()
    var found = false
    for group in status.groupsOf(MemberAccount.uid):
      if group["class"].kind == JString and group["class"].getStr() == "ci":
        found = true
        expect group["held_cpu_milli"].getInt() == 1000,
          "the class group holds the granted CPU"
    expect found, "the member's session group carries class ci, owned by " &
      "the member's uid"
    var queuedOther = 0
    for group in status.groupsOf(OutsiderAccount.uid):
      queuedOther += group["queued_leases"].getInt()
    expect queuedOther == 1, "the unclassed request is still queued"
    member.finish()
    outsider.finish()

  proc scenarioSharedSocketRefuses() =
    var host = newHost("shared")
    defer:
      host.stopDaemon()
      removeDir(host.root)
    host.writeHostFile(ciTable())
    let ciSocket = host.run / "class-ci.sock"
    expect host.startDaemon(waitFor = [ciSocket]),
      "the daemon starts: " & host.daemonOutput
    for account in [MemberAccount, OutsiderAccount]:
      var client = host.startClient(account, "shared", "ci")
      let line = client.readUntil(["register-refused", "registered",
        "connect-failed"])
      client.finish()
      echo "  " & account.name & " (class block on the shared socket): " & line
      expect line.startsWith("register-refused"),
        account.name & ": a class block on the shared socket is refused"
      expect ciSocket in line, account.name & ": the refusal names " & ciSocket
    expect host.status(){"active_sessions"}.getInt(-1) == 0,
      "no session was registered by either"
    # A group of class ci, created on the class socket ...
    var holder = host.startClient(MemberAccount, "claim", "ci",
      group = "build-x")
    let held = holder.readUntil(["registered", "register-refused",
      "connect-failed"])
    expect held.startsWith("registered"), "the member opens a group of class ci"
    # ... is not joined from the shared socket, even with no class block.
    var joiner = host.startClient(MemberAccount, "shared", "",
      group = "build-x")
    let joined = joiner.readUntil(["register-refused", "registered",
      "connect-failed"])
    joiner.finish()
    echo "  member (join the ci group on the shared socket): " & joined
    expect joined.startsWith("register-refused"),
      "joining a group of class ci on the shared socket is refused"
    expect "class ci" in joined, "the refusal names the group's class"
    # And a registration without a class on the shared socket is served.
    var plain = host.startClient(OutsiderAccount, "shared", "")
    let served = plain.readUntil(["registered", "register-refused",
      "connect-failed"])
    plain.finish()
    echo "  outsider (no class on the shared socket): " & served
    expect served.startsWith("registered"),
      "a registration with no class on the shared socket succeeds"
    holder.finish()

  proc scenarioCreatedAsDeclared() =
    var host = newHost("declared")
    defer:
      host.stopDaemon()
      removeDir(host.root)
    let ciSocket = host.run / "class-ci.sock"
    let gpuSocket = host.run / "class-gpu.sock"
    let cycleSocket = host.run / "class-cycle.sock"
    let cycleTable = "[reservation.cycle]\nsocket-group = \"ci\"\n" &
      "socket-mode = \"0660\"\n"
    let both = ciTable() & "[reservation.gpu]\n"
    host.writeHostFile(both & cycleTable)
    # THE READER STARTS FIRST, so it watches every socket from before the
    # daemon creates it.
    let pollEnv = newStringTable(modeCaseSensitive)
    let stopFile = host.root / "stop-polling"
    pollEnv[PollRoleEnvVar] = [ciSocket, gpuSocket, cycleSocket,
      stopFile].join(",")
    let poller = startProcess(getAppFilename(), env = pollEnv,
      options = {poStdErrToStdOut})
    sleep(200)
    expect host.startDaemon(waitFor = [ciSocket, gpuSocket, cycleSocket]),
      "the daemon starts: " & host.daemonOutput
    # Reloads that drop and re-add a class: each re-creation is another
    # moment a socket could appear wider than declared.
    for i in 0 ..< 40:
      let dropped = host.reload(both)
      let added = host.reload(both & cycleTable)
      if dropped.code != 0 or added.code != 0:
        expect false, "a cycling reload succeeds: " & dropped.output &
          added.output
        break
    writeFile(stopFile, "")
    let pollOutput = poller.outputStream.readAll()
    discard poller.waitForExit(30_000)
    poller.close()
    var observed: seq[string] = @[]
    var appearances = initTable[string, int]()
    var reads = initTable[string, int]()
    for line in pollOutput.splitLines():
      if line.startsWith("seen "):
        observed.add(line[5 .. ^1])
      elif line.startsWith("found "):
        let fields = line.split(' ')
        reads[fields[1]] = parseInt(fields[2])
        appearances[fields[1]] = parseInt(fields[3])
        echo "  reader: " & line
    # THE READER MUST HAVE WATCHED, or "never saw a wider mode" is vacuous:
    # every socket read many times, and the cycling class seen appearing in
    # most of its 41 creations (the initial one and 40 re-adds).
    for name in ["class-ci.sock", "class-gpu.sock", "class-cycle.sock"]:
      expect reads.getOrDefault(name) >= 1000, "the reader read " & name &
        " at least 1000 times (" & $reads.getOrDefault(name) & ")"
    expect appearances.getOrDefault("class-cycle.sock") >= 30,
      "the reader saw class-cycle.sock appear at least 30 times (" &
      $appearances.getOrDefault("class-cycle.sock") & ")"
    echo "  states seen: " & observed.join("; ")
    let rqd = $RqdAccount.uid
    for state in observed:
      let name = state.split(' ')[0]
      let expected =
        if name == "class-gpu.sock": "class-gpu.sock 0600 " & rqd & " " &
          $RqdAccount.gid
        else: name & " 0660 " & rqd & " " & $ClassGroup.gid
      expect state == expected, "a reader saw " & state & ", never wider " &
        "than declared (" & expected & ")"
    # The sockets as declared, and nothing for an undeclared class.
    let ci = socketState(ciSocket)
    expect ci.isSocket and ci.mode == 0o660 and ci.groupGid == ClassGroup.gid and
      ci.ownerUid == RqdAccount.uid, "class-ci.sock is 0660, group ci, owner rqd"
    let gpu = socketState(gpuSocket)
    expect gpu.isSocket and gpu.mode == 0o600 and
      gpu.groupGid == RqdAccount.gid and gpu.ownerUid == RqdAccount.uid,
      "class-gpu.sock has the defaults: 0600, the daemon's user and group"
    var classSockets: seq[string] = @[]
    for kind, path in walkDir(host.run):
      let name = path.extractFilename
      if name.startsWith("class-") and name.endsWith(".sock"):
        classSockets.add(name)
    expect classSockets.len == 3, "a socket for each declared class and no " &
      "other: " & classSockets.join(", ")
    # A session on gpu's socket (only the daemon's account may claim it) ...
    var onGpu = host.startClient(RqdAccount, "claim", "gpu", count = 1)
    let gpuOffers = onGpu.readUntil(["offers", "connect-failed",
      "register-refused"])
    expect gpuOffers == "offers granted=1 queued=0",
      "a session on the gpu socket is served: " & gpuOffers
    # ... survives the reload that drops gpu, which unlinks the socket.
    let dropGpu = host.reload(ciTable())
    expect dropGpu.code == 0, "the reload dropping gpu succeeds: " &
      dropGpu.output
    expect not socketState(gpuSocket).found, "class-gpu.sock is unlinked"
    var gpuGroups = 0
    for group in host.status().groupsOf(RqdAccount.uid):
      if group["class"].kind == JString and group["class"].getStr() == "gpu":
        inc gpuGroups
        expect group["active_leases"].getInt() == 1,
          "its lease is still held"
    expect gpuGroups == 1, "the session connected on it keeps class gpu"
    onGpu.process.inputStream.writeLine("offer")
    onGpu.process.inputStream.flush()
    let late = onGpu.readUntil(["late-offer"])
    expect late == "late-offer active=true",
      "the connection still serves requests after the reload"
    onGpu.finish()
    host.stopDaemon()
    # A declared group the daemon's account is not in refuses the start.
    host.writeHostFile("[reservation.ci]\nsocket-group = \"" &
      ForeignGroup.name & "\"\nsocket-mode = \"0660\"\n")
    let started = host.startDaemon(waitFor = [ciSocket])
    expect not started, "a daemon outside the declared group does not start"
    if not started:
      let code = host.daemon.waitForExit(1000)
      echo "  refused start (exit " & $code & "): " &
        oneLine(host.daemonOutput)
      expect code == 2, "it exits 2"
      expect ForeignGroup.name in host.daemonOutput, "naming the group"
      expect "class ci" in host.daemonOutput, "naming the class"
      expect ciSocket in host.daemonOutput, "naming the socket"
      expect not fileExists(host.socket) and
        not socketState(host.socket).found, "and leaves no endpoint behind"

  proc scenarioRootDaemonRestarts() =
    ## A ROOT daemon gives class ci's socket to `member` (`socket-owner`).
    ## Killed with SIGKILL it leaves that socket behind, owned by `member`;
    ## the next start must take it for its own stale socket, as it does for
    ## the shared endpoint, not refuse it as another user's.
    var host = newHost("rootrestart", RootAccount)
    defer:
      host.stopDaemon()
      removeDir(host.root)
    host.writeHostFile("[reservation.ci]\nsocket-owner = \"member\"\n" &
      "socket-group = \"ci\"\nsocket-mode = \"0660\"\n")
    let ciSocket = host.run / "class-ci.sock"
    expect host.startDaemon(waitFor = [ciSocket]),
      "the root daemon starts: " & host.daemonOutput
    let first = socketState(ciSocket)
    expect first.ownerUid == MemberAccount.uid and
      first.groupGid == ClassGroup.gid and first.mode == 0o660,
      "class-ci.sock belongs to member, group ci, 0660"
    discard posix.kill(Pid(host.daemon.processID), SIGKILL)
    discard host.daemon.waitForExit(30_000)
    host.daemon.close()
    host.daemon = nil
    expect socketState(ciSocket).found, "SIGKILL left the class socket"
    expect host.startDaemon(waitFor = []),
      "the root daemon starts again over its stale class socket: " &
      host.daemonOutput
    sleep(500)
    expect host.daemon != nil and host.daemon.running,
      "and keeps running"
    let again = socketState(ciSocket)
    expect again.ownerUid == MemberAccount.uid and again.mode == 0o660,
      "the new class-ci.sock is member's again"
    var member = host.startClient(MemberAccount, "claim", "ci")
    let line = member.readUntil(["registered", "register-refused",
      "connect-failed"])
    member.finish()
    echo "  member after the restart: " & line
    expect line.startsWith("registered"), "member claims ci after the restart"

  proc scenarioRefusedReloadChangesNothing() =
    ## A reload that re-applies two classes' keys, the second of which the
    ## kernel refuses (a gid the host has no such id for), changes neither:
    ## the first class's socket keeps its owner, group and mode.
    var host = newHost("reloadundo", RootAccount)
    defer:
      host.stopDaemon()
      removeDir(host.root)
    let before = "[reservation.ci]\nsocket-group = \"ci\"\n" &
      "socket-mode = \"0600\"\n[reservation.gpu]\n"
    host.writeHostFile(before)
    let ciSocket = host.run / "class-ci.sock"
    let gpuSocket = host.run / "class-gpu.sock"
    expect host.startDaemon(waitFor = [ciSocket, gpuSocket]),
      "the root daemon starts: " & host.daemonOutput
    let ciBefore = socketState(ciSocket)
    let gpuBefore = socketState(gpuSocket)
    # gid 70000 is outside the ids this host maps, so chown(2) fails.
    let refused = host.reload("[reservation.ci]\nsocket-group = \"ci\"\n" &
      "socket-mode = \"0660\"\n[reservation.gpu]\n" &
      "socket-group = \"70000\"\n")
    echo "  refused reload: " & oneLine(refused.output)
    expect refused.code != 0, "the reload is refused"
    expect "unchanged" in refused.output, "saying nothing changed"
    let ciAfter = socketState(ciSocket)
    let gpuAfter = socketState(gpuSocket)
    expect ciAfter.mode == ciBefore.mode and
      ciAfter.groupGid == ciBefore.groupGid and
      ciAfter.ownerUid == ciBefore.ownerUid,
      "class-ci.sock is unchanged (mode " & toOct(ciAfter.mode, 4) &
      ", gid " & $ciAfter.groupGid & ")"
    expect gpuAfter.mode == gpuBefore.mode and
      gpuAfter.groupGid == gpuBefore.groupGid, "class-gpu.sock is unchanged"

  proc insideMain(scenario: string): int =
    ## The accounts host's root: arrange the accounts, run one scenario.
    echo "RAN ON: " & accountsPlatform()
    let made = createTempDir("rqcs-accounts-", "", "/tmp")
    try:
      prepareAccounts(made)
      case scenario
      of "refuses_unpermitted_user": scenarioRefusesUnpermittedUser()
      of "permitted_claim": scenarioPermittedClaim()
      of "shared_socket_refuses": scenarioSharedSocketRefuses()
      of "created_as_declared": scenarioCreatedAsDeclared()
      of "root_daemon_restarts": scenarioRootDaemonRestarts()
      of "refused_reload_changes_nothing": scenarioRefusedReloadChangesNothing()
      else: failures.add("unknown scenario " & scenario)
    except CatchableError as error:
      failures.add("the scenario raised: " & error.msg)
    finally:
      removeDir(made)
    if failures.len == 0:
      echo "SCENARIO PASSED"
      0
    else:
      echo "SCENARIO FAILED: " & failures.join(" | ")
      1

  if existsEnv(ClientRoleEnvVar):
    quit(clientRole())
  if existsEnv(PollRoleEnvVar):
    quit(pollRole())
  if existsEnv(InsideEnvVar):
    quit(insideMain(getEnv(InsideEnvVar)))

  template runScenario(name: string) =
    ## Inside a test: run scenario `name` as the accounts host's root, or
    ## skip, saying why, where the accounts cannot be arranged.
    let unavailable = accountsUnavailable()
    if unavailable.len > 0:
      echo "SKIPPED: two accounts cannot be arranged here: " & unavailable
      skip()
    else:
      let binaries = [daemonPath(), cliPath(), getAppFilename()].join(",")
      let (code, output) = enterAccountsHost(name,
        [(BinariesEnvVar, binaries)])
      echo output
      check code == 0

  suite "class_sockets":
    test "class_socket_refuses_unpermitted_user":
      runScenario("refuses_unpermitted_user")
    test "class_socket_permitted_claim":
      runScenario("permitted_claim")
    test "shared_socket_refuses_class_claim":
      runScenario("shared_socket_refuses")
    test "class_sockets_created_as_declared":
      runScenario("created_as_declared")
    test "a root daemon restarts over a class socket it gave away":
      runScenario("root_daemon_restarts")
    test "a refused reload changes no class socket":
      runScenario("refused_reload_changes_nothing")
else:
  import std/unittest

  suite "class_sockets":
    for name in ["class_socket_refuses_unpermitted_user",
                 "class_socket_permitted_claim",
                 "shared_socket_refuses_class_claim",
                 "class_sockets_created_as_declared",
                 "a root daemon restarts over a class socket it gave away",
                 "a refused reload changes no class socket"]:
      test name:
        # No two-account helper for this platform yet
        # (`tests/support/class_socket_accounts`).
        skip()
