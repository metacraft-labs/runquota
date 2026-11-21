## A group's `cpu.weight` ends at the priority the daemon holds, whatever
## order a launcher and `runquota session set --priority` interleave in.
##
## THE RACE. A launcher reads the group's priority in force from the daemon
## and later writes the matching weight to the group's directory; `session
## set --priority` changes the priority in the daemon and then rewrites the
## weight. A `session set` that lands between the launcher's read and its
## write used to be overwritten by the older value, which then held until the
## next launch or `session set`.
##
## WHAT IS GUARDED, each with the change that makes it fail:
##
## 1. "a priority set after the launcher's placement read is not
##    overwritten": the launcher's placement is computed (`treePlacement`,
##    where the priority used to be read), `session set` raises the
##    priority and rewrites the weight of the directory a holder tree keeps,
##    and only then is the tree launched. The weight must be the new
##    priority's. This is the race exactly as it was recorded, driven
##    through the public API in that order, so no timing decides it.
##    Mutation: the launch ignoring the priority source and writing the
##    weight its placement chose -- 25 instead of 1600 (the unfixed tree
##    fails the same way).
## 2. "... reaches a group created by the launch": the same, with no tree
##    holding the directory, so the set has nothing to rewrite and the
##    launch creates it; the child reports the weight it starts under.
##    Same mutation.
## 3. "a priority set between the launcher's in-lock read and its weight
##    write is not overwritten": the read the launcher makes while it holds
##    the root's shared lock is wrapped (below), and the wrapper starts a
##    real `runquota session set --priority urgent` after the production
##    read has answered `low`, and returns only once the DAEMON holds
##    `urgent` and the set has either ended or is waiting for the root's
##    lock (its `->` line in /proc/locks), so it has done everything it does
##    before its weight write. The launcher then writes the older weight.
##    The set's write must still land last. Mutation: `session set`
##    rewriting the weight without the root's exclusive lock -- it writes
##    1600 before the wrapper returns and the launcher's 25 lands on top.
## 4. "a set writes the priority the daemon holds when it writes, not its
##    own": with the root's lock held by the test, a `session set
##    --priority high` is accepted and parks on the lock; a later change to
##    `urgent` is then made in the daemon; once the lock is released the
##    set must write `urgent`'s weight. (Of two concurrent sets, the one
##    that reaches the lock second may carry the older answer; this drives
##    that order deterministically, with the later change made through the
##    daemon directly.) Mutation: writing the answer of its own update
##    instead of re-reading under the lock -- 400.
##
## THE SEAM, for case 3. The launcher's priority read is a source on the
## launch spec (`CommandSpec.cgroupPriority`), installed by `treePlacement`.
## The test wraps the production source; it calls it unchanged and only adds
## the injected `session set` after it. Nothing in the library exists for the
## test. It is not a mock: the daemon, the CLI, the cgroups and the lock are
## all real.
##
## A ROOT OF ITS OWN (`cgroup_test_root`), never the user's real
## `runquota.slice`; on a host without a delegated cgroup v2 subtree with the
## cpu controller the cases are reported SKIPPED with the reason. The holder
## process that keeps each group's directory alive ends by itself when the
## test creates its stop file; nothing is killed.

when defined(linux):
  import std/[os, osproc, streams, strtabs, strutils, unittest]

  import runquota_client
  import runquota_core
  import runquota_exec
  import runquota_process
  import runquota_protocol
  import cgroup_test_root
  import daemon_binary
  import private_daemon_fixture

  var rootReason = ""
  let testRoot = delegatedTestRoot(rootReason)
  let scratch = scratchDir("rq-wrace")
  let socket = scratch / "d.sock"
  let tag = $getCurrentProcessId()
  var daemon: Process
  var daemonStarted = false

  if testRoot.len > 0:
    daemon = launchOwned(scratch, socket, privateEnv(socket),
      daemonArgs(scratch, socket,
        ["--cpu-milli", "8000", "--memory-bytes", $(16'u64 shl 30)]),
      what = "runquotad")
    daemonStarted = true
    putEnv("RUNQUOTA_ENDPOINT_SCOPE", "private")
    putEnv("RUNQUOTA_SOCKET", socket)
    delEnv("RUNQUOTA_PARENT_LEASE")
  else:
    echo "SKIPPED (every case): no delegated cgroup v2 subtree with the cpu " &
      "controller for this user: " & rootReason

  let root = CgroupRoot(state: crsExplicit, path: testRoot)

  proc cliEnv(): StringTableRef =
    result = privateEnv(socket)
    result[CgroupRootEnvVar] = testRoot
    result.del("RUNQUOTA_PARENT_LEASE")

  proc weightOf(group: string): string =
    try: readFile(testRoot / groupDirName(group) / "cpu.weight").strip()
    except IOError, OSError: "<absent>"

  type Holder = object
    child: LaunchedProcess
    stopFile: string

  proc startHolder(group: string; priority: SessionPriority): Holder =
    ## A tree in `group`'s shared leaf that keeps the group's directory
    ## alive until `stopHolder`; it ends on its own by then, or after 60 s.
    result.stopFile = scratch / ("stop-" & group)
    var spec = commandSpec(["/bin/sh", "-c",
      "i=0; while [ ! -e \"$1\" ] && [ $i -lt 1200 ]; do sleep 0.05; " &
      "i=$((i+1)); done", "holder", result.stopFile])
    spec.cgroup = targetFor(root, group, priority, reclaimed = false)
    result.child = launchProcess(spec)
    doAssert result.child.info.cgroupPath.len > 0,
      "holder not placed: " & result.child.info.cgroupProblem

  proc stopHolder(holder: var Holder) =
    writeFile(holder.stopFile, "")
    discard holder.child.waitForCompletion()
    holder.child.close()

  proc sessionIn(client: var RunQuotaClient; group: string;
                 priority: SessionPriority): RunQuotaSession =
    client.registerSession("weight race", "test", SessionGroupDeclaration(
      name: group, priorityPresent: true, priority: priority))

  proc launchTrue(spec: var CommandSpec): string =
    ## Launch `spec` (running `true`), wait for it, and return where it ran.
    var child = launchProcess(spec)
    let placedAt = child.info.cgroupPath
    discard child.waitForCompletion()
    child.close()
    placedAt

  proc launchReportingWeight(spec: var CommandSpec): string =
    ## Launch `spec` running a shell that prints the `cpu.weight` of its
    ## own cgroup's parent (the group directory) as it starts; the
    ## directory goes once it ends, so the child is the one to read it.
    spec.argv = @["/bin/sh", "-c", "cat \"/sys/fs/cgroup$(sed -n " &
      "'s/^0:://p' /proc/self/cgroup)/../cpu.weight\""]
    var child = launchProcess(spec)
    let placedAt = child.info.cgroupPath
    let completion = child.waitForCompletion()
    child.close()
    if placedAt.len == 0: "<unplaced>" else: completion.stdout.strip()

  proc blockedOnFlock(pid: int): bool =
    ## Whether `pid` waits for a `flock(2)` (a `->` line of /proc/locks,
    ## https://man7.org/linux/man-pages/man5/proc_locks.5.html).
    try:
      for line in readFile("/proc/locks").splitLines():
        let fields = line.splitWhitespace()
        if fields.len >= 6 and fields[1] == "->" and fields[2] == "FLOCK" and
            fields[5] == $pid:
          return true
    except IOError, OSError:
      discard
    false

  proc daemonHolds(group: string; wanted: SessionPriority): bool =
    var probe = connectDefault()
    defer: probe.close()
    var now = sessionPriorityNormal
    probe.currentGroupPriority(group, now) and now == wanted

  proc startSet(group, priority: string): Process =
    startProcess(cliPath(), env = cliEnv(), args = ["session", "set", group,
      "--priority", priority], options = {poStdErrToStdOut})

  proc awaitAcceptedAndParked(setter: Process; group: string;
                              wanted: SessionPriority): string =
    ## Wait until the daemon holds `wanted` (the set's update was accepted)
    ## AND the set has either ended or is waiting for the root's lock: it
    ## has then done everything it does before its weight write. "" when so,
    ## else what did not happen within 20 s.
    for _ in 0 ..< 800:
      if daemonHolds(group, wanted) and
          (not setter.running or blockedOnFlock(setter.processID)):
        return ""
      sleep(25)
    "the set was not accepted and parked within 20 s (running=" &
      $setter.running & ")"

  type Injection = object
    inner: GroupPrioritySource
    group: string
    setter: Process
    injected: bool
    problem: string

  var injection: Injection

  proc injectingRead(context: pointer; priority: var SessionPriority): bool {.
      nimcall, gcsafe, raises: [].} =
    ## The production read, then (once) a real `session set --priority
    ## urgent` that is let run up to its weight write before the launcher
    ## goes on to write the weight of the priority it read.
    let state = cast[ptr Injection](context)
    result = state[].inner.readNow(priority)
    if state[].injected:
      return
    state[].injected = true
    # GC-SAFE BY CONSTRUCTION, NOT BY INFERENCE. A read source must be
    # `gcsafe` (the launcher is called from GC-safe code), and the injection
    # starts a process through test helpers the compiler cannot prove
    # GC-safe. This read runs on the launching thread of a single-threaded
    # test, touching only the `Injection` it was handed, so no heap is
    # shared across threads.
    {.cast(gcsafe).}:
      try:
        state[].setter = startSet(state[].group, "urgent")
        state[].problem = awaitAcceptedAndParked(state[].setter,
          state[].group, sessionPriorityUrgent)
      except Exception as error:
        # `Exception`, not only `CatchableError`: osproc's effects say
        # `Exception`, and a read source must not raise at all.
        state[].problem = "injection failed: " & error.msg

  template needRoot(): bool =
    if testRoot.len == 0:
      echo "SKIPPED: " & rootReason
      skip()
    testRoot.len > 0

  suite "a group's cpu.weight follows its latest priority (Linux cgroups)":
    test "a priority set after the launcher's placement read is not overwritten":
      if needRoot():
        let group = "rq-race-a-" & tag
        var client = connectDefault()
        defer: client.close()
        var session = client.sessionIn(group, sessionPriorityLow)
        var holder = startHolder(group, sessionPriorityLow)
        check weightOf(group) == "25"
        var lease = session.requestLease(resourceRequest("race-a",
          milliCpu(1000), bytes(64'u64 shl 20)))
        # The launcher's half before its weight write ...
        let placement = session.treePlacement(lease, root = root)
        # ... the operator's change ...
        let (setCode, setText) = cli(cliEnv(), ["session", "set", group,
          "--priority", "urgent"])
        check setCode == 0
        if setCode != 0: echo setText
        check weightOf(group) == "1600"
        # ... and the launcher's weight write.
        var spec = commandSpec(["true"])
        spec.applyPlacement(placement)
        check launchTrue(spec).len > 0
        check weightOf(group) == "1600"
        lease.release()
        holder.stopHolder()
        session.closeSession()

    test "a priority set after the placement read reaches a group created by the launch":
      if needRoot():
        # No tree holds the directory: the set finds none to rewrite, and
        # the launch creates it.
        let group = "rq-race-b-" & tag
        var client = connectDefault()
        defer: client.close()
        var session = client.sessionIn(group, sessionPriorityLow)
        var lease = session.requestLease(resourceRequest("race-b",
          milliCpu(1000), bytes(64'u64 shl 20)))
        let placement = session.treePlacement(lease, root = root)
        let (setCode, setText) = cli(cliEnv(), ["session", "set", group,
          "--priority", "urgent"])
        check setCode == 0
        if setCode != 0: echo setText
        check weightOf(group) == "<absent>"
        var spec = commandSpec(["true"])
        spec.applyPlacement(placement)
        check launchReportingWeight(spec) == "1600"
        lease.release()
        session.closeSession()

    test "a priority set between the launcher's in-lock read and its weight write is not overwritten":
      if needRoot():
        let group = "rq-race-c-" & tag
        var client = connectDefault()
        defer: client.close()
        var session = client.sessionIn(group, sessionPriorityLow)
        var holder = startHolder(group, sessionPriorityLow)
        var lease = session.requestLease(resourceRequest("race-c",
          milliCpu(1000), bytes(64'u64 shl 20)))
        let placement = session.treePlacement(lease, root = root)
        check placement.prioritySource.available
        injection = Injection(inner: placement.prioritySource, group: group)
        var spec = commandSpec(["true"])
        spec.applyPlacement(placement)
        spec.cgroupPriority = GroupPrioritySource(read: injectingRead,
          context: addr injection)
        check launchTrue(spec).len > 0
        check injection.injected
        check injection.problem == ""
        if injection.problem.len > 0: echo injection.problem
        if injection.setter != nil:
          # The set finishes its weight write once the launch has let go
          # of the lock.
          let setText = injection.setter.outputStream.readAll()
          let setCode = injection.setter.waitForExit()
          injection.setter.close()
          check setCode == 0
          if setCode != 0: echo setText
        check weightOf(group) == "1600"
        lease.release()
        holder.stopHolder()
        session.closeSession()

    test "a set writes the priority the daemon holds when it writes, not its own":
      if needRoot():
        # A set reaches the lock after a later change is already in the
        # daemon (the later set, here made through the daemon alone, has
        # not written yet): it must write the later priority.
        let group = "rq-race-d-" & tag
        var client = connectDefault()
        defer: client.close()
        var session = client.sessionIn(group, sessionPriorityLow)
        var holder = startHolder(group, sessionPriorityLow)
        let lock = lockCgroupRoot(testRoot, exclusive = true, create = false)
        check lock >= 0
        let setter = startSet(group, "high")
        let parked = awaitAcceptedAndParked(setter, group, sessionPriorityHigh)
        check parked == ""
        if parked.len > 0: echo parked
        discard client.updateSessionGroup(UpdateSessionGroupMessage(
          group: group, priorityPresent: true, priority: sessionPriorityUrgent,
          cacheDeadlineChange: cacheDeadlineKeep))
        unlockCgroupRoot(lock)
        let setText = setter.outputStream.readAll()
        let setCode = setter.waitForExit()
        setter.close()
        check setCode == 0
        if setCode != 0: echo setText
        check weightOf(group) == "1600"
        holder.stopHolder()
        session.closeSession()

    test "nothing is left behind":
      if needRoot():
        check cgroupDirsBelow(testRoot).len == 0
        if cgroupDirsBelow(testRoot).len != 0:
          echo "left behind: " & $cgroupDirsBelow(testRoot)

  if daemonStarted:
    daemon.stopOwned()
  if testRoot.len > 0:
    let problem = removeTestRoot(testRoot)
    if problem.len > 0:
      echo "TEST ROOT NOT REMOVED: " & problem
      quit(1)
    doAssert not dirExists(testRoot)
  try:
    removeDir(scratch)
  except OSError:
    discard
