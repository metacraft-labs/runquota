import std/[options, os, strutils]

import runquota_client
import runquota_core
import runquota_exec/types as execTypes
import runquota_exec/memory_cap_launch
import runquota_process
import runquota_protocol

export execTypes, memory_cap_launch

const libraryName* = "runquota_exec"

proc reclaimedNice*(lease: RunQuotaLease): int =
  ## The nice increment a tree launched under `lease` must run with,
  ## whether or not it is placed in a cgroup: a RECLAIMED grant was admitted
  ## into CPU the daemon predicts the running leases' tails leave free, so
  ## when a tail turns out wider than predicted the job that was granted
  ## first must keep priority (`ReclaimedNiceIncrement`, nice +10). In its
  ## cgroup (`runquota.slice/reclaimed`, weight 1) the nice also ranks it
  ## inside its leaf; without one, the nice is the whole of the lower weight.
  if lease.reclaimed: ReclaimedNiceIncrement else: 0

type
  TreePlacement* = object
    ## Where a tree launched under one lease runs below admission
    ## (`runquota_process/cgroup_placement`).
    target*: CgroupTarget
      ## The cgroup to create the tree in; empty when there is none.
    fallbackNice*: int
      ## The nice the tree takes if it is not placed after all.
    jobPriorityClass*: uint32
      ## Windows: the Win32 priority class to force on the tree's Job Object
      ## below admission (`runquota_process/job_priority`), when job-priority
      ## enforcement is on. 0 = off (the switchable layer does nothing; the
      ## tree keeps its unconditional class). Independent of `target`: Windows
      ## has no cgroups, so `target` is always empty there.
    qosTier*: uint8
      ## macOS: the priority tier to apply to the tree below admission
      ## (`runquota_process/qos_priority`), when qos enforcement is on. 0 =
      ## off (the switchable layer does nothing; a reclaimed tree keeps its
      ## unconditional nice +10). Independent of `target`: macOS has no
      ## cgroups, so `target` is always empty there.
    rootProblem*: string
      ## Why there is no target: placement off or unavailable on this host.
    prioritySource*: GroupPrioritySource
      ## For a group target: where the launch reads the group's priority in
      ## force, under the cgroup root's lock, for the weight it writes and
      ## the fallback nice (`CommandSpec.cgroupPriority`). It points at the
      ## session `treePlacement` was called on, which must outlive the
      ## launch.

proc readSessionGroupPriority(context: pointer;
                              priority: var SessionPriority): bool {.
    nimcall, gcsafe, raises: [].} =
  ## `GroupPrioritySource.read` over a `RunQuotaSession` (the context): the
  ## group's priority asked from the daemon now. Never raises: a daemon that
  ## cannot answer leaves the launch with the weight it already chose
  ## (nothing here may fail a launch).
  if context.isNil:
    return false
  try:
    priority = cast[ptr RunQuotaSession](context)[].groupPriorityNow()
    true
  except CatchableError:
    false

proc groupPrioritySource*(session: var RunQuotaSession): GroupPrioritySource =
  ## The source of the priority in force of `session`'s group, for a launch
  ## (or a weight rewrite) to read at the moment it writes the weight. Valid
  ## for as long as `session` is.
  GroupPrioritySource(read: readSessionGroupPriority,
    context: cast[pointer](addr session))

type
  GroupPriorityQuery* = object
    ## A group named without a session (`runquota session set` holds none):
    ## the client to ask through and the group's name.
    client*: ptr RunQuotaClient
    group*: string

proc readQueriedGroupPriority(context: pointer;
                              priority: var SessionPriority): bool {.
    nimcall, gcsafe, raises: [].} =
  if context.isNil:
    return false
  let query = cast[ptr GroupPriorityQuery](context)
  if query[].client.isNil:
    return false
  try:
    query[].client[].currentGroupPriority(query[].group, priority)
  except CatchableError:
    false

proc groupPrioritySource*(query: var GroupPriorityQuery): GroupPrioritySource =
  ## The source of the priority in force of `query.group`. Valid for as long
  ## as `query` and its client are.
  GroupPrioritySource(read: readQueriedGroupPriority,
    context: cast[pointer](addr query))

proc treePlacement*(session: var RunQuotaSession; lease: RunQuotaLease;
                    capMilli = 0'u64;
                    root = currentCgroupRoot();
                    parent = parentLeaseFromEnvironment();
                    jobPriorityOn = false;
                    qosOn = false): TreePlacement =
  ## The placement of a tree started under `lease`: its session group's
  ## cgroup with the weight of the group's priority in force, or the
  ## reclaimed subtree for a reclaimed grant; with `capMilli > 0` a leaf of
  ## its own whose `cpu.max` is that width (named after this process and
  ## the lease, which the daemon numbers uniquely).
  ##
  ## THE PRIORITY IS READ BY THE LAUNCH, NOT HERE. For a group target the
  ## placement carries a source of the group's priority (`prioritySource`,
  ## over `session`), and the launch reads it while it holds the cgroup
  ## root's shared lock, right before it writes the weight; the weight and
  ## fallback nice set here (from the priority last known, else the declared
  ## one) are what the launch keeps only if the daemon cannot answer then.
  ## Read here, a `session set --priority` landing between this call and the
  ## launch's weight write would be overwritten by the older value. A
  ## reclaimed target needs no priority (weight 1, nice +10) and asks
  ## nothing. Where placement is unavailable the daemon is asked here once
  ## per session (`groupPriorityInForce`) for the fallback nice.
  ##
  ## WINDOWS (`jobPriorityOn`) is the same late-binding read on the other
  ## layer: a non-reclaimed tree carries the SAME `prioritySource`, and the
  ## launch reads it right before it sets the Job Object priority-class limit
  ## (`SetInformationJobObject`), mapping the priority in force onto the class
  ## (`jobPriorityClassFor`). The class set here, from the priority last known
  ## (else declared), is the fallback the launch keeps only if the daemon
  ## cannot answer then; a reclaimed grant is idle whatever its group and asks
  ## nothing. No lock: a single `SetInformationJobObject` call has no critical
  ## section a concurrent set can land inside.
  ##
  ## MACOS (`qosOn`) is the same late-binding read on a third layer: a
  ## non-reclaimed tree carries the SAME `prioritySource`, and the launch
  ## reads it right before the fork, mapping the priority in force onto the
  ## tier (`qosTierFor`); the tier set here, from the priority last known
  ## (else declared), is the fallback the launch keeps only if the daemon
  ## cannot answer then. A reclaimed grant is background whatever its group
  ## and asks nothing.
  ##
  ## THE OUTERMOST LAUNCHER PLACES. A launcher that itself runs inside a
  ## leased tree (`RUNQUOTA_PARENT_LEASE` set: a `runquota jobserver` under
  ## `runquota run`, say) leaves its tree where its parent put it -- for both
  ## layers. Moving it to a group cgroup would take it out of the parent's,
  ## and out of a parent's cap with it; forcing its priority class would do
  ## the same below admission.
  if parent.isSome:
    result.rootProblem = "inside the tree of lease " & $parent.get.value &
      ", which its own launcher placed"
    return
  let cgroupOff = root.state == crsOff
  if cgroupOff and not jobPriorityOn and not qosOn:
    # Both layers off: nothing below admission changes (a reclaimed tree
    # keeps its nice +10 / unconditional below-normal class through
    # `reclaimedNice`), and the daemon is not asked for the group's priority.
    result.rootProblem = root.reason
    return
  if jobPriorityOn:
    # Windows: the switchable layer forces the tree's Job Object to the class
    # of the group's priority. Like the Linux weight, the class is read AT THE
    # LAST INSTANT by the launch through `prioritySource`
    # (`CommandSpec.cgroupPriority`), right before the `SetInformationJobObject`
    # call; the class set here, from the priority last known (else declared),
    # is the fallback the launch keeps only if the daemon cannot answer then.
    # A reclaimed grant is idle whatever its group and asks nothing.
    let known =
      if session.groupPriorityKnown: session.groupPriority
      else: session.declaredGroupPriority
    result.jobPriorityClass = jobPriorityClassFor(known, lease.reclaimed)
    if not lease.reclaimed:
      result.prioritySource = session.groupPrioritySource()
  if qosOn:
    let known =
      if session.groupPriorityKnown: session.groupPriority
      else: session.declaredGroupPriority
    result.qosTier = qosTierFor(known, lease.reclaimed)
    if not lease.reclaimed:
      result.prioritySource = session.groupPrioritySource()
  if cgroupOff:
    result.rootProblem = root.reason
    return
  if not root.usable:
    result.fallbackNice = fallbackNice(session.groupPriorityInForce(),
      lease.reclaimed)
    result.rootProblem = root.reason
    return
  let known =
    if session.groupPriorityKnown: session.groupPriority
    else: session.declaredGroupPriority
  result.fallbackNice = fallbackNice(known, lease.reclaimed)
  result.target = targetFor(root, session.groupName, known,
    lease.reclaimed, capMilli, launcherPid = getCurrentProcessId(),
    capSequence = int(lease.id.value))
  if not lease.reclaimed:
    result.prioritySource = session.groupPrioritySource()

proc applyPlacement*(spec: var CommandSpec; placement: TreePlacement) =
  ## Put `placement` on a launch: the cgroup, and the nice to take instead
  ## when the child cannot be placed. A capped launch first removes the
  ## empty cap leaves of launchers that are gone.
  spec.cgroup = placement.target
  spec.placementFallbackNice = placement.fallbackNice
  spec.cgroupPriority = placement.prioritySource
  spec.jobPriorityClass = placement.jobPriorityClass
  spec.qosTier = placement.qosTier
  if placement.target.isCapLeaf:
    sweepStaleCapLeaves(placement.target)

proc placementNote*(placement: TreePlacement; launch: LaunchResult): string =
  ## One phrase for a launcher's verbose output: the cgroup the tree runs
  ## in, or why it runs without one and at which nice; on macOS it also
  ## says that there are no cgroups and no hard CPU cap (what a `--cap` that
  ## is not enforced reports) and which priority policy the tree took.
  if launch.cgroupPath.len > 0:
    result = "cgroup " & launch.cgroupPath
  else:
    let why =
      if launch.cgroupProblem.len > 0: launch.cgroupProblem
      elif placement.rootProblem.len > 0: placement.rootProblem
      else: "no cgroup"
    result = "not in a cgroup (" & why & "), nice +" & $launch.fallbackNice
    when defined(macosx):
      result.add("; macOS has no cgroups and no hard CPU cap for a process " &
        "tree; priority policy: " & qosTierName(launch.qosTier))

proc libraryInfo*(): execTypes.LibraryInfo =
  execTypes.LibraryInfo(name: libraryName)

proc finishOutcome*(completion: ProcessCompletion): LeaseFinish =
  ## What this supervisor saw, said in the vocabulary the spine records.
  ##
  ## THE SIGNAL IS TESTED BEFORE THE CANCEL, WHICH REVERSES THE OLD ORDER
  ## AND PRESERVES THE OLD ANSWER. ``terminate()`` sets ``cancelSent``, so
  ## a child killed by SIGTERM arrives here with BOTH ``cancelled`` and
  ## ``signaled`` set; the old code reported ``leaseFinishCancelled`` and
  ## put the signal in its own independent field, and the daemon's
  ## mapping -- which tested that field before it read the outcome --
  ## recorded ``signalled``. Now that the finish carries its evidence
  ## instead of trailing it, ``cancelled()`` has no signal to hand over,
  ## so the same execution must be named ``crashed`` here to land on the
  ## same word there.
  ##
  ## AND A CANCEL THE CHILD HONOURED IS STILL ``cancelled``: it exits of
  ## its own accord, no signal is recorded, and this falls through.
  ##
  ## A KILL FOR MEMORY IS NAMED BEFORE ANYTHING ELSE, because the same
  ## signal or status reads as a crash or a failure otherwise. The launcher
  ## that applied the cap knows which killed the tree
  ## (`completion.capKilled` / `oomKilledOutsideCap`, classified by the
  ## platform's mechanism), and each conclusion needs kill evidence: a
  ## signal, or the non-zero status a parent that reported its child's kill
  ## returned. Without evidence the conclusion is not stated. A cap kill is
  ## named only with the measurement that goes with it
  ## (`memoryCapMeasured`), because a cap-exceeded finish without the
  ## memory-cap block is refused by the daemon and would strand the lease.
  let signal =
    if completion.signaled: uint32(max(completion.signal, 0)) else: 0'u32
  let status =
    if completion.exited and completion.exitCode > 0:
      uint32(completion.exitCode)
    else: 0'u32
  var kill: KillEvidence
  if (completion.capKilled or completion.oomKilledOutsideCap) and
      killEvidence(status, signal, kill):
    if completion.capKilled and completion.memoryCapMeasured:
      return capExceeded(kill)
    return oomKilled(kill)
  if signal != 0'u32:
    crashed(signal)
  elif completion.cancelled or completion.timedOut:
    cancelled()
  elif completion.exited and completion.exitCode > 0:
    failed(uint32(completion.exitCode))
  elif completion.exited:
    succeeded()
  else:
    # NEITHER EXITED NOR SIGNALLED NOR CANCELLED: the wait returned
    # without a verdict. Nothing here evidences an exit status, so the
    # honest statement is that the supervisor stopped without one. The
    # old code called this ``leaseFinishFailed`` with exit status 0 --
    # a clean exit reported as a failure, which is the same shape of
    # untruth this type exists to prevent.
    cancelled()

proc parentLeaseEnvEntry*(lease: RunQuotaLease): string =
  ## `RUNQUOTA_PARENT_LEASE=<id>` for the tree launched under `lease`: a
  ## client in that tree asks for a sub-lease of it instead of queueing on
  ## the host behind its own parent.
  ParentLeaseEnvVar & "=" & $lease.id.value

proc memoryCapFromEnvironment*(): string =
  ## `RUNQUOTA_MEMORY_CAP` as this process inherited it, "" when unset.
  getEnv(MemoryCapEnvVar)

proc runWithLease*(session: var RunQuotaSession; request: ResourceRequest;
                   command: CommandSpec; releaseAfterFinish = true;
                   waitForQueued = false;
                   exportParentLease = true;
                   placeTree = true;
                   cgroupRoot = currentCgroupRoot();
                   jobPriorityOn = currentJobPriorityOn();
                   qosOn = currentQosOn();
                   memoryCapMode = mcmOff;
                   memoryCapEnv = memoryCapFromEnvironment()):
    LeaseExecutionResult =
  ## `exportParentLease` gives the child `RUNQUOTA_PARENT_LEASE` naming the
  ## lease it runs under. It is layered over `command.env`, so it also
  ## replaces a value the launcher itself inherited: the nearest supervisor
  ## is the one whose capacity the tree runs in.
  ##
  ## `placeTree` creates the tree in its session group's cgroup (or the
  ## reclaimed subtree) under `cgroupRoot` when placement is on there
  ## (`treePlacement`); a caller that placed `command` itself passes false.
  ## The default root reads only the environment, so placement is on only
  ## when `RUNQUOTA_CGROUP_ROOT` names a root; a launcher that honours the
  ## host file's switch passes the root it resolved with it.
  ##
  ## `memoryCapMode` is the host file's `[enforcement] memoryCap`, read by
  ## the caller (this library reads no host file), and `memoryCapEnv` the
  ## per-run override: together with the grant they decide the tree's memory
  ## cap (`resolveMemoryCap`). A value of the variable that is not one raises
  ## before anything is launched, and the lease is released.
  result = LeaseExecutionResult(
    state: esWaitingForLease
  )
  var lease =
    if waitForQueued:
      session.requestLeaseWaiting(request)
    else:
      session.requestLease(request)
  result.leaseId = lease.id.value
  try:
    # Resolved before the lease is marked starting, so a refused variable
    # releases a lease that never started anything (the `finally` below).
    let cap = resolveMemoryCap(lease.memoryCap, memoryCapMode, memoryCapEnv,
      nested = parentLeaseFromEnvironment().isSome)
    if cap.error.len > 0:
      raise newException(ValueError, cap.error)
    result.state = esStarting
    lease.markStarting()
    var spec = command
    # A reclaimed grant runs at the lower weight, whatever the caller asked.
    spec.niceIncrement = max(spec.niceIncrement, lease.reclaimedNice())
    spec.applyMemoryCap(cap)
    if placeTree:
      spec.applyPlacement(session.treePlacement(lease, root = cgroupRoot,
        jobPriorityOn = jobPriorityOn, qosOn = qosOn))
    if exportParentLease:
      spec.env.add(lease.parentLeaseEnvEntry())
    var child = launchProcess(spec)
    result.memoryCapNote = cap.memoryCapNotEnforced(child.info)
    result.backend = child.info.backend
    result.cgroupPath = child.info.cgroupPath
    result.cgroupProblem = child.info.cgroupProblem
    result.state = esRunning
    lease.markRunning(
      childProcessId = child.info.processId,
      processGroupId = child.info.processGroupId,
      cleanupRegistered = true
    )
    let completion = child.waitForCompletion()
    child.close()
    let outcome = finishOutcome(completion)
    let capBlock = completion.finishMemoryCap(cap)
    lease.finish(
      outcome = outcome,
      peakMemoryBytes = completion.peakResidentMemoryBytes,
      processCount = completion.processCount,
      totals = completion.totals,
      cpuProfile = completion.cpuProfile,
      sizing = completion.finishSizing(),
      memoryCap = capBlock
    )
    result.memoryCapReport = memoryCapReport(command.argv.join(" "),
      request.commandStatsId, lease.memoryCap, capBlock,
      killed = outcome.kind == lfCapExceeded)
    result.process = completion
    result.stdoutBytes = completion.stdoutBytes
    result.stderrBytes = completion.stderrBytes
    result.leaseFinishedSent = true
    result.state = esFinished
  except CatchableError:
    if lease.active and lease.state == leaseClientStarting:
      lease.finish(outcome = launchFailed())
      result.leaseFinishedSent = true
      result.state = esFinished
    raise
  finally:
    if releaseAfterFinish and lease.active:
      lease.release()
      result.leaseReleased = true
      result.state = esReleased

proc runWithLease*(session: var RunQuotaSession; request: ResourceRequest;
                   argv: openArray[string]; cwd = ""; env: openArray[string] = [];
                   stdoutLimit = DefaultOutputLimit;
                   stderrLimit = DefaultOutputLimit;
                   waitForQueued = false;
                   cgroupRoot = currentCgroupRoot();
                   jobPriorityOn = currentJobPriorityOn();
                   qosOn = currentQosOn();
                   memoryCapMode = mcmOff;
                   memoryCapEnv = memoryCapFromEnvironment()):
    LeaseExecutionResult =
  session.runWithLease(
    request,
    commandSpec(
      argv,
      cwd = cwd,
      env = env,
      stdoutLimit = stdoutLimit,
      stderrLimit = stderrLimit
    ),
    waitForQueued = waitForQueued,
    cgroupRoot = cgroupRoot,
    jobPriorityOn = jobPriorityOn,
    qosOn = qosOn,
    memoryCapMode = memoryCapMode,
    memoryCapEnv = memoryCapEnv
  )
