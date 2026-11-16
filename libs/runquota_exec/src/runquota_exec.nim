import std/[options, os]

import runquota_client
import runquota_core
import runquota_exec/types as execTypes
import runquota_process
import runquota_protocol

export execTypes

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
    rootProblem*: string
      ## Why there is no target: placement off or unavailable on this host.

proc treePlacement*(session: var RunQuotaSession; lease: RunQuotaLease;
                    capMilli = 0'u64;
                    root = currentCgroupRoot();
                    parent = parentLeaseFromEnvironment()): TreePlacement =
  ## The placement of a tree started under `lease`: its session group's
  ## cgroup with the weight of the group's priority in force, or the
  ## reclaimed subtree for a reclaimed grant; with `capMilli > 0` a leaf of
  ## its own whose `cpu.max` is that width (named after this process and
  ## the lease, which the daemon numbers uniquely). Asks the daemon for the
  ## group's priority the first time (`groupPriorityInForce`); the nice
  ## fallback needs it too.
  ##
  ## THE OUTERMOST LAUNCHER PLACES. A launcher that itself runs inside a
  ## leased tree (`RUNQUOTA_PARENT_LEASE` set: a `runquota jobserver` under
  ## `runquota run`, say) leaves its tree where its parent put it. Moving
  ## it to a group cgroup would take it out of the parent's, and out of a
  ## parent's cap with it.
  if parent.isSome:
    result.rootProblem = "inside the tree of lease " & $parent.get.value &
      ", which its own launcher placed"
    return
  if root.state == crsOff:
    # Placement off: nothing below admission changes (a reclaimed tree
    # keeps its nice +10 through `reclaimedNice`), and the daemon is not
    # asked for the group's priority.
    result.rootProblem = root.reason
    return
  let priority = session.groupPriorityInForce()
  result.fallbackNice = fallbackNice(priority, lease.reclaimed)
  if not root.usable:
    result.rootProblem = root.reason
    return
  result.target = targetFor(root, session.groupName, priority,
    lease.reclaimed, capMilli, launcherPid = getCurrentProcessId(),
    capSequence = int(lease.id.value))

proc applyPlacement*(spec: var CommandSpec; placement: TreePlacement) =
  ## Put `placement` on a launch: the cgroup, and the nice to take instead
  ## when the child cannot be placed. A capped launch first removes the
  ## empty cap leaves of launchers that are gone.
  spec.cgroup = placement.target
  spec.placementFallbackNice = placement.fallbackNice
  if placement.target.isCapLeaf:
    sweepStaleCapLeaves(placement.target)

proc placementNote*(placement: TreePlacement; launch: LaunchResult): string =
  ## One phrase for a launcher's verbose output: the cgroup the tree runs
  ## in, or why it runs without one and at which nice.
  if launch.cgroupPath.len > 0:
    "cgroup " & launch.cgroupPath
  else:
    let why =
      if launch.cgroupProblem.len > 0: launch.cgroupProblem
      elif placement.rootProblem.len > 0: placement.rootProblem
      else: "no cgroup"
    "not in a cgroup (" & why & "), nice +" & $placement.fallbackNice

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
  let signal =
    if completion.signaled: uint32(max(completion.signal, 0)) else: 0'u32
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

proc runWithLease*(session: var RunQuotaSession; request: ResourceRequest;
                   command: CommandSpec; releaseAfterFinish = true;
                   waitForQueued = false;
                   exportParentLease = true;
                   placeTree = true;
                   cgroupRoot = currentCgroupRoot()): LeaseExecutionResult =
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
    result.state = esStarting
    lease.markStarting()
    var spec = command
    # A reclaimed grant runs at the lower weight, whatever the caller asked.
    spec.niceIncrement = max(spec.niceIncrement, lease.reclaimedNice())
    if placeTree:
      spec.applyPlacement(session.treePlacement(lease, root = cgroupRoot))
    if exportParentLease:
      spec.env.add(lease.parentLeaseEnvEntry())
    var child = launchProcess(spec)
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
    lease.finish(
      outcome = finishOutcome(completion),
      peakMemoryBytes = completion.peakResidentMemoryBytes,
      processCount = completion.processCount,
      totals = completion.totals,
      cpuProfile = completion.cpuProfile
    )
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
                   cgroupRoot = currentCgroupRoot()): LeaseExecutionResult =
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
    cgroupRoot = cgroupRoot
  )
