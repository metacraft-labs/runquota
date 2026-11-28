## `runquota nix-build-hook` against its own protocol, with this test as the
## nix-daemon worker: it starts the shipped hook, writes the settings
## preamble and `try` requests in Nix's wire format, holds the derivations'
## output locks itself, and reads the replies. A real private `runquotad`
## admits the leases.
##
## WHAT IS UNDER TEST, and why it needs no nix-daemon: the properties below
## are about what the hook does with its input, which a real worker cannot
## be made to send (an over-long setting, a list that cannot be followed) or
## cannot be made to send at a chosen moment (a `try` after a holder gave its
## grant back). `t_nix_daemon_builds_within_budget` covers a real daemon.
##
## * `secrets_never_leave_the_hook` -- the preamble carries credentials
##   (`access-tokens`, `netrc-file`) and the hook's own environment carries
##   a token, a `NIX_CONFIG` and a session group; none of them appears in
##   anything the hook writes, nor in a holder's command line or
##   environment, which holds only the RunQuota endpoint variables. The
##   lease is held while the worker (this test) holds the output lock and
##   given back when it lets go, and the holder then exits. Mutations that
##   fail it: a holder environment copied from the hook's (the holder then
##   carries `GITHUB_TOKEN` and `NIX_CONFIG`); a hook that never takes a
##   lease.
## * `every_try_is_answered_in_bound` -- an over-long derivation path, a
##   derivation that cannot be read, a worker with no build slot, and
##   finally a request that cannot be parsed are
##   each answered (`# decline`, `# postpone`, `# decline-permanently`) within
##   `ReplyBoundMillis`, and when the hook stops, the holder it had queued
##   stops with it. Mutation that fails it: a hook that stops without
##   answering a request it cannot parse.
## * `max_jobs_zero_is_declined_not_postponed` -- with `max-jobs = 0` no
##   local build will ever happen, so the hook declines at once and starts
##   no holder. Mutation that fails it: a hook that postpones (forever).
## * `a_grant_given_back_is_not_built_on` -- a holder whose grant was not
##   claimed in time gives it back and exits; the next `try` must not
##   `# decline` (the build would run on a lease nobody holds) but postpone,
##   and the one after gets a fresh lease. Mutation that fails it: claiming
##   without the holder's confirmation.
##
## NO MOCKS. The hook, its holders and the daemon are the shipped binaries;
## the worker is this process, writing exactly what Nix's `HookInstance` and
## `DerivationBuildingGoal::tryBuildHook` write.
##
## * `a_queued_holder_dies_with_a_killed_hook` -- the worker kills the hook
##   while one holder is claimed and one queued: the queued one dies and
##   its request leaves the daemon's queue, the claimed one stays until the
##   worker lets go. Mutations that fail it: no `PR_SET_PDEATHSIG` (Linux);
##   a darwin watcher that ignores its hook's pipe closing.
## * `a_stopped_queued_holder_is_still_ended_with_its_hook` -- a queued
##   lease holder its requester stopped (SIGSTOP) is still ended when the
##   hook stops, and its request leaves the queue. Mutation that fails it:
##   a darwin hook that kills the watcher but not its process group.
## * In `every_try_is_answered_in_bound` the queue is empty once the hook
##   has stopped; a darwin lease holder that does not notice its watcher
##   was killed stays queued, and fails it.
## * `a_lease_ends_within_half_a_second_of_its_build` -- once the worker
##   (this test) lets go of a claimed build's lock, the lease is gone within
##   `ReleaseBoundMillis`, and the holder has exited. Mutations that fail
##   it: a holder (Linux) or watcher (darwin) that never sees the lock go
##   free; ten times `ReleaseMisses`.
##
## ISOLATION. A private `runquotad` on a socket in a fresh 0700 scratch
## directory. Only the hook and the daemon this test started are signalled,
## by their `Process`; holders are the hook's children and are only
## observed (read-only: `/proc` on Linux, `libproc` and `KERN_PROCARGS2` on
## darwin, `tests/support/process_listing`), never signalled but for the
## one SIGSTOP of the stopped-holder case. The scratch
## directory is removed at the end.
##
## Linux and darwin, like the hook's requester lookup and release probe. On
## darwin a holder is two processes, the watcher the hook starts and the
## lease holder it forks; the secrets case checks both, and the cases that
## end with no holder left look for either.

when defined(linux) or defined(macosx):
  import std/[json, monotimes, os, osproc, posix, streams, strtabs, strutils,
    times,
    unittest]

  import daemon_binary
  import private_daemon_fixture
  import process_listing
  import runquota_cli_support/nix_hook

  const
    SettingSecret = "github.com=rqtest-setting-secret-4f1c"
    EnvSecret = "rqtest-env-secret-9b2e"
    ReplyBoundMillis = 1500
      ## The hook's own bound is under a second (`RequesterLookupMillis +
      ## ImmediateGrantMillis + ClaimConfirmMillis` plus a process start);
      ## the margin is for a loaded host.
    ReleaseBoundMillis = 600
      ## A lease outlives its build by `ReleaseMisses` probes `ProbeMillis`
      ## apart plus up to one probe (~400 ms); the rest is the release
      ## round trip and the status query that observes it.
    LockEx = cint(2)
    LockUn = cint(8)

  proc flockCall(fd: cint; operation: cint): cint {.
    importc: "flock", header: "<sys/file.h>".}

  type
    HookRun = object
      process: Process
      started: bool
      buffer: string
      transcript: seq[string]   ## Every line the hook wrote.

    Fixture = object
      root: string
      rqSocket: string
      rqDaemon: Process
      rqStarted: bool
      hook: HookRun
      hookEnv: StringTableRef   ## Exactly what the hook was started with.
      lockFds: seq[cint]

  proc startDaemon(fixture: var Fixture; cpus: int) =
    fixture.root = scratchDir("rqhook")
    fixture.rqSocket = fixture.root / "rq.sock"
    fixture.rqDaemon = startProcess(daemonPath(),
      env = privateEnv(fixture.rqSocket),
      args = daemonArgs(fixture.root, fixture.rqSocket,
        ["--cpu-milli", $(cpus * 1000),
         "--memory-bytes", $(64'u64 * 1024 * 1024 * 1024)]),
      options = {poStdErrToStdOut})
    fixture.rqStarted = true
    prerequisite awaitSocket(fixture.rqDaemon, fixture.rqSocket),
      startupContext(fixture.rqDaemon, "the private runquotad did not bind")
    createDir(fixture.root / "store")

  proc startHook(fixture: var Fixture) =
    ## The hook, with an environment that carries secrets and a session
    ## group of its own, as a daemon's might -- and nothing else of this
    ## process's, so that whatever a holder carries beyond the endpoint
    ## variables could only have come from the hook. (An inherited
    ## `LD_PRELOAD` tracer would otherwise re-inject itself into the
    ## holder's environment at exec time, whatever the hook passed.)
    var env = newStringTable(modeCaseSensitive)
    env["RUNQUOTA_ENDPOINT_SCOPE"] = "private"
    env["RUNQUOTA_SOCKET"] = fixture.rqSocket
    env["GITHUB_TOKEN"] = EnvSecret
    env["NIX_CONFIG"] = "access-tokens = github.com=" & EnvSecret
    env["RUNQUOTA_SESSION"] = "hook-env-group"
    fixture.hookEnv = env
    fixture.hook.process = startProcess(cliPath(), args = [HookVerb, "0"],
      env = env, options = {poStdErrToStdOut})
    fixture.hook.started = true

  proc stop(fixture: var Fixture) =
    ## Never raises: it runs from `defer`.
    for fd in fixture.lockFds:
      discard posix.close(fd)
    fixture.lockFds = @[]
    if fixture.hook.started:
      try:
        if fixture.hook.process.running:
          fixture.hook.process.kill()
          discard fixture.hook.process.waitForExit(10_000)
        fixture.hook.process.close()
      except CatchableError:
        discard
      fixture.hook.started = false
    if fixture.rqStarted: stopOwned(fixture.rqDaemon)
    fixture.rqStarted = false
    if fixture.root.len > 0: removeDir(fixture.root)

  proc send(fixture: var Fixture; data: string) =
    fixture.hook.process.inputStream.write(data)
    fixture.hook.process.inputStream.flush()

  proc preamble(store: string; cores, maxJobs: int): string =
    result = wireU64(1) & wireString("access-tokens") &
      wireString(SettingSecret) &
      wireU64(1) & wireString("netrc-file") &
      wireString("/run/secrets/" & EnvSecret) &
      wireU64(1) & wireString("extra-big") &
      wireString(repeat('z', 2 * 1024 * 1024)) &
      wireU64(1) & wireString("cores") & wireString($cores) &
      wireU64(1) & wireString("max-jobs") & wireString($maxJobs) &
      wireU64(1) & wireString("build-poll-interval") & wireString("1") &
      wireU64(1) & wireString("store") & wireString(store) &
      wireU64(0)

  proc tryRequest(drvPath: string; willing: bool): string =
    wireString("try") & wireU64(if willing: 1 else: 0) &
      wireString("x86_64-linux") & wireString(drvPath) & wireStrings([])

  proc nextReply(fixture: var Fixture; elapsed: var int): string =
    ## The hook's next `# ` reply, with how long it took; every other line
    ## goes to the transcript. "" when none came within twice the bound.
    let started = getMonoTime()
    let fd = cint(fixture.hook.process.outputHandle)
    while true:
      let nl = fixture.hook.buffer.find('\n')
      if nl >= 0:
        let line = fixture.hook.buffer[0 ..< nl]
        fixture.hook.buffer = fixture.hook.buffer[nl + 1 .. ^1]
        fixture.hook.transcript.add(line)
        if line.startsWith("# "):
          elapsed = int((getMonoTime() - started).inMilliseconds)
          return line[2 .. ^1]
        continue
      let left = 2 * ReplyBoundMillis -
        int((getMonoTime() - started).inMilliseconds)
      if left <= 0: return ""
      var fds = [TPollfd(fd: fd, events: POLLIN)]
      if poll(addr fds[0], Tnfds(1), cint(left)) <= 0: continue
      var chunk = newString(4096)
      let got = posix.read(fd, addr chunk[0], chunk.len)
      if got <= 0: return ""
      fixture.hook.buffer.add(chunk[0 ..< got])

  proc ask(fixture: var Fixture; drvPath: string; willing: bool): string =
    ## One `try`, answered within the bound.
    fixture.send(tryRequest(drvPath, willing))
    var elapsed = 0
    result = fixture.nextReply(elapsed)
    check result.len > 0
    check elapsed <= ReplyBoundMillis
    if elapsed > ReplyBoundMillis:
      checkpoint("reply '" & result & "' took " & $elapsed & " ms")

  proc writeDrv(fixture: var Fixture; tag: string): tuple[drv, lock: string] =
    ## A derivation in the hook's `real=` store, and its output's lock file
    ## (which Nix would create; this test, the worker, takes it).
    let drv = "/nix/store/" & repeat('d', 32) & "-" & tag & ".drv"
    let output = "/nix/store/" & repeat('o', 32) & "-" & tag
    writeFile(fixture.root / "store" / extractFilename(drv),
      "Derive([(\"out\",\"" & output & "\",\"\",\"\")],[],[]," &
      "\"x86_64-linux\",\"/bin/sh\",[],[])")
    let lock = fixture.root / "store" / extractFilename(output) & ".lock"
    writeFile(lock, "")
    (drv, lock)

  proc takeLock(fixture: var Fixture; path: string): cint =
    result = posix.open(path.cstring, O_RDWR or O_CLOEXEC)
    prerequisite result >= 0 and flockCall(result, LockEx) == 0,
      "cannot lock " & path
    fixture.lockFds.add(result)

  proc dropLock(fixture: var Fixture; fd: cint) =
    discard flockCall(fd, LockUn)
    discard posix.close(fd)
    var kept: seq[cint] = @[]
    for held in fixture.lockFds:
      if held != fd: kept.add(held)
    fixture.lockFds = kept

  proc granted(fixture: Fixture): int =
    let (code, text) = cli(privateEnv(fixture.rqSocket))
    prerequisite code == 0, "runquota status failed: " & text
    parseJson(text)["capacity"]["host"]["cpu_granted_milli"].getInt()

  proc grantedBecomes(fixture: Fixture; milli: int): bool =
    for _ in 0 ..< 50:
      if fixture.granted() == milli: return true
      sleep(100)
    false

  proc queued(fixture: Fixture): int =
    ## Lease requests the daemon holds in its queue.
    let (code, text) = cli(privateEnv(fixture.rqSocket), ["leases", "--json"])
    prerequisite code == 0, "runquota leases failed: " & text
    for lease in parseJson(text)["leases"]:
      if lease["state"].getStr() == "queued": inc result

  proc queuedBecomesZero(fixture: Fixture): bool =
    ## A queued request whose holder is gone leaves the queue when its
    ## connection closes; one that waits on for nothing does not.
    for _ in 0 ..< 20:
      if fixture.queued() == 0: return true
      sleep(100)
    false

  proc childrenGone(pid: int): bool =
    for _ in 0 ..< 50:
      if childrenOf(pid).len == 0: return true
      sleep(100)
    false

  proc injectedByExec(fixture: Fixture): seq[string] =
    ## The variables the host's exec layer added to the hook beyond the
    ## environment this test gave it (an `LD_PRELOAD` command tracer adds
    ## itself to every process it sees started, whatever its environment).
    ## The same layer adds them to the holder; they are not the hook's to
    ## remove, and the secret check still covers their values.
    for entry in processEnviron(fixture.hook.process.processID):
      let eq = entry.find('=')
      if eq > 0 and not fixture.hookEnv.hasKey(entry[0 ..< eq]):
        result.add(entry[0 ..< eq])

  proc holdsNoSecret(text: string): bool =
    SettingSecret notin text and EnvSecret notin text and
      "rqtest-setting-secret" notin text

  suite "the build hook's protocol":
    test "secrets_never_leave_the_hook":
      var fixture: Fixture
      defer: fixture.stop()
      fixture.startDaemon(cpus = 4)
      fixture.startHook()
      let store = "local?real=" & fixture.root / "store"
      fixture.send(preamble(store, cores = 2, maxJobs = 4))
      let (drv, lock) = fixture.writeDrv("s")
      let lockFd = fixture.takeLock(lock)
      var answer = ""
      for _ in 0 ..< 10:
        answer = fixture.ask(drv, willing = true)
        if answer != "postpone": break
        sleep(200)
      check answer == "decline"
      check fixture.granted() == 2000
      # The holder: one child of the hook, holding the lease. On darwin that
      # child is the watcher and the lease is held by ITS child; both are
      # checked.
      let holders = childrenOf(fixture.hook.process.processID)
      check holders.len == 1
      var holderProcesses = holders
      when defined(macosx):
        for pid in holders:
          let leaseHolders = childrenOf(pid)
          check leaseHolders.len == 1
          holderProcesses.add(leaseHolders)
      for pid in holderProcesses:
        let argv = processArgv(pid)
        check argv.len > 0
        check holdsNoSecret(argv.join("\0"))
        let environ = processEnviron(pid).join("\0")
        check holdsNoSecret(environ)
        let ambient = injectedByExec(fixture)
        for entry in processEnviron(pid):
          let key = entry[0 ..< max(0, entry.find('='))]
          let allowed = key in HolderEndpointVars or key in SessionVars or
            key in ambient
          check allowed
          if not allowed: checkpoint("the holder got " & key)
        # The daemon's own group is not the requester's.
        check "hook-env-group" notin environ
      # The worker lets go: the lease is given back and the holder exits.
      fixture.dropLock(lockFd)
      check fixture.grantedBecomes(0)
      check childrenGone(fixture.hook.process.processID)
      check noHoldersLeft(fixture.rqSocket)
      # End of the build operation: the hook exits on its own.
      fixture.hook.process.inputStream.close()
      check fixture.hook.process.waitForExit(5000) == 0
      var elapsed = 0
      discard fixture.nextReply(elapsed)   # drain what is left
      for line in fixture.hook.transcript:
        check holdsNoSecret(line)
        check line.startsWith("# ") or line.startsWith("@nix ")

    test "every_try_is_answered_in_bound":
      var fixture: Fixture
      defer: fixture.stop()
      fixture.startDaemon(cpus = 4)
      fixture.startHook()
      let store = "local?real=" & fixture.root / "store"
      fixture.send(preamble(store, cores = 4, maxJobs = 4))
      # A derivation path over the bound: declined, unread.
      check fixture.ask("/nix/store/" & repeat('p', 8192) & ".drv",
        willing = true) == "decline"
      # A derivation the hook cannot read: granted, then declined unadmitted.
      var answer = ""
      for _ in 0 ..< 10:
        answer = fixture.ask("/nix/store/" & repeat('m', 32) & "-gone.drv",
          willing = true)
        if answer != "postpone": break
        sleep(200)
      check answer == "decline"
      check fixture.grantedBecomes(0)
      # A worker with no free slot: postponed, no holder started.
      check fixture.ask("/nix/store/" & repeat('n', 32) & "-busy.drv",
        willing = false) == "postpone"
      # One build takes the whole budget; a second one queues.
      let (first, firstLock) = fixture.writeDrv("a")
      let firstFd = fixture.takeLock(firstLock)
      for _ in 0 ..< 10:
        answer = fixture.ask(first, willing = true)
        if answer != "postpone": break
        sleep(200)
      check answer == "decline"
      check fixture.granted() == 4000
      let (second, _) = fixture.writeDrv("b")
      check fixture.ask(second, willing = true) == "postpone"
      check childrenOf(fixture.hook.process.processID).len == 2
      # A request that cannot be followed: the hook stops being asked.
      fixture.send(wireString("try") & wireU64(1) & wireString("s") &
        wireString(second) & wireU64(1'u64 shl 40))
      var elapsed = 0
      check fixture.nextReply(elapsed) == "decline-permanently"
      check elapsed <= ReplyBoundMillis
      check fixture.hook.process.waitForExit(5000) == 0
      # Its queued holder stopped with it, and its request left the queue
      # (on darwin the hook killed the watcher, and the lease holder saw
      # its watcher gone); the claimed one holds on while the worker
      # builds, and lets go when the worker does.
      check fixture.queuedBecomesZero()
      check fixture.granted() == 4000
      fixture.dropLock(firstFd)
      check fixture.grantedBecomes(0)
      # Neither holder is left: the queued one stopped with the hook (on
      # darwin, its lease holder noticed its watcher was gone), the claimed
      # one when the worker let go.
      check noHoldersLeft(fixture.rqSocket)
      for line in fixture.hook.transcript:
        check holdsNoSecret(line)

    test "max_jobs_zero_is_declined_not_postponed":
      var fixture: Fixture
      defer: fixture.stop()
      fixture.startDaemon(cpus = 4)
      fixture.startHook()
      fixture.send(preamble("local?real=" & fixture.root / "store",
        cores = 1, maxJobs = 0))
      let (drv, _) = fixture.writeDrv("z")
      check fixture.ask(drv, willing = false) == "decline"
      check childrenOf(fixture.hook.process.processID).len == 0

    test "a_grant_given_back_is_not_built_on":
      var fixture: Fixture
      defer: fixture.stop()
      fixture.startDaemon(cpus = 2)
      fixture.startHook()
      let store = "local?real=" & fixture.root / "store"
      fixture.send(preamble(store, cores = 2, maxJobs = 4))
      # A takes the budget; B queues behind it.
      let (a, lockOfA) = fixture.writeDrv("a")
      let aFd = fixture.takeLock(lockOfA)
      var answer = ""
      for _ in 0 ..< 10:
        answer = fixture.ask(a, willing = true)
        if answer != "postpone": break
        sleep(200)
      check answer == "decline"
      let (b, lockOfB) = fixture.writeDrv("b")
      check fixture.ask(b, willing = true) == "postpone"
      # A ends: B's holder is granted, but the worker has no slot for it
      # until the holder's unclaimed time (2 x poll interval + 1 s) is over.
      fixture.dropLock(aFd)
      let deadline = getMonoTime() + initDuration(milliseconds = 4500)
      while getMonoTime() < deadline:
        check fixture.ask(b, willing = false) == "postpone"
        sleep(300)
      check fixture.grantedBecomes(0)
      # The grant is gone: B must not be declined (it would build on no
      # lease), and the next try leases afresh.
      let bFd = fixture.takeLock(lockOfB)
      check fixture.ask(b, willing = true) == "postpone"
      for _ in 0 ..< 10:
        answer = fixture.ask(b, willing = true)
        if answer != "postpone": break
        sleep(200)
      check answer == "decline"
      check fixture.granted() == 2000
      fixture.dropLock(bFd)
      check fixture.grantedBecomes(0)

    test "a_queued_holder_dies_with_a_killed_hook":
      var fixture: Fixture
      defer: fixture.stop()
      fixture.startDaemon(cpus = 2)
      fixture.startHook()
      fixture.send(preamble("local?real=" & fixture.root / "store",
        cores = 2, maxJobs = 4))
      # A is claimed and holds the budget; B's holder is queued behind it.
      let (a, lockOfA) = fixture.writeDrv("a")
      let aFd = fixture.takeLock(lockOfA)
      var answer = ""
      for _ in 0 ..< 10:
        answer = fixture.ask(a, willing = true)
        if answer != "postpone": break
        sleep(200)
      check answer == "decline"
      let (b, _) = fixture.writeDrv("b")
      check fixture.ask(b, willing = true) == "postpone"
      check fixture.queued() == 1
      let withB = holdersOf(fixture.rqSocket).len
      # The worker kills the hook (as it does when its build operation
      # ends); the hook cannot end its holders itself. B's holder dies with
      # it (Linux: PR_SET_PDEATHSIG; darwin: the watcher sees the hook's
      # pipe close and kills its lease holder), and B's request leaves the
      # queue. A's claimed holder outlives the hook.
      fixture.hook.process.kill()
      discard fixture.hook.process.waitForExit(5000)
      check fixture.queuedBecomesZero()
      check fixture.granted() == 2000
      var remaining = -1
      for _ in 0 ..< 20:
        remaining = holdersOf(fixture.rqSocket).len
        if remaining < withB: break
        sleep(100)
      # A's holder alone: one process on Linux, a watcher and its lease
      # holder on darwin.
      check remaining == (when defined(macosx): 2 else: 1)
      fixture.dropLock(aFd)
      check fixture.grantedBecomes(0)
      check noHoldersLeft(fixture.rqSocket)

    test "a_stopped_queued_holder_is_still_ended_with_its_hook":
      # The requester can stop its own lease holder (same uid). A stopped
      # holder notices nothing, so the hook itself must end it: on darwin
      # that holder is the watcher's child, and killing the watcher alone
      # would leave its request queued for good. THE ONE SIGNAL THIS FILE
      # SENDS TO A PROCESS IT DID NOT START: SIGSTOP to a holder of its own
      # hook, as the requester could; the hook then SIGKILLs it.
      var fixture: Fixture
      defer: fixture.stop()
      fixture.startDaemon(cpus = 2)
      fixture.startHook()
      fixture.send(preamble("local?real=" & fixture.root / "store",
        cores = 2, maxJobs = 4))
      let (a, lockOfA) = fixture.writeDrv("a")
      let aFd = fixture.takeLock(lockOfA)
      var answer = ""
      for _ in 0 ..< 10:
        answer = fixture.ask(a, willing = true)
        if answer != "postpone": break
        sleep(200)
      check answer == "decline"
      let before = childrenOf(fixture.hook.process.processID)
      let (b, _) = fixture.writeDrv("b")
      check fixture.ask(b, willing = true) == "postpone"
      check fixture.queued() == 1
      var queuedHolder = 0
      for pid in childrenOf(fixture.hook.process.processID):
        if pid notin before: queuedHolder = pid
      require queuedHolder > 0
      # The process holding B's request: the holder on Linux, the
      # watcher's child on darwin.
      var leaseHolder = queuedHolder
      when defined(macosx):
        for _ in 0 ..< 20:
          let kids = childrenOf(queuedHolder)
          if kids.len == 1:
            leaseHolder = kids[0]
            break
          sleep(50)
        require leaseHolder != queuedHolder
      require kill(Pid(leaseHolder), SIGSTOP) == 0
      # The hook stops being asked; it ends its queued holder on the way out.
      fixture.send(wireString("try") & wireU64(1) & wireString("s") &
        wireString(b) & wireU64(1'u64 shl 40))
      var elapsed = 0
      check fixture.nextReply(elapsed) == "decline-permanently"
      check fixture.hook.process.waitForExit(5000) == 0
      check fixture.queuedBecomesZero()
      fixture.dropLock(aFd)
      check fixture.grantedBecomes(0)
      check noHoldersLeft(fixture.rqSocket)

    test "a_lease_ends_within_half_a_second_of_its_build":
      var fixture: Fixture
      defer: fixture.stop()
      fixture.startDaemon(cpus = 2)
      fixture.startHook()
      fixture.send(preamble("local?real=" & fixture.root / "store",
        cores = 2, maxJobs = 4))
      let (drv, lock) = fixture.writeDrv("r")
      let fd = fixture.takeLock(lock)
      var answer = ""
      for _ in 0 ..< 10:
        answer = fixture.ask(drv, willing = true)
        if answer != "postpone": break
        sleep(200)
      check answer == "decline"
      check fixture.granted() == 2000
      # The build runs a while: the lease stays while the lock is held.
      sleep(1000)
      check fixture.granted() == 2000
      # The build ends (the worker lets go of the lock): the lease ends
      # within the bound, measured from the moment the lock went free to
      # the START of the first status query that shows it gone. Each query
      # starts the CLI (tens of ms; 50-150 ms on a loaded host), and the
      # release happened before that query's end: timing to the end
      # charges the holder with the observer's start-up (which is how
      # Linux reached 471 ms), timing to the start can undercount by at
      # most one query. What the bound then holds is the holder's ~400 ms
      # (three free probes 100 ms apart, plus one) and the release round
      # trip, with ~200 ms for scheduling on a loaded host. A holder late
      # by a probe cycle or more still fails it.
      let freed = getMonoTime()
      fixture.dropLock(fd)
      var gone = -1
      while int((getMonoTime() - freed).inMilliseconds) < 5000:
        let asked = getMonoTime()
        if fixture.granted() == 0:
          gone = int((asked - freed).inMilliseconds)
          break
        sleep(10)
      echo "lease ended ", gone, " ms after its build"
      check gone >= 0
      check gone <= ReleaseBoundMillis
      check noHoldersLeft(fixture.rqSocket)
