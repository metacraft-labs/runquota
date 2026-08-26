import runquota_client
import runquota_core
import runquota_exec/types as execTypes
import runquota_process
import runquota_protocol

export execTypes

const libraryName* = "runquota_exec"

proc libraryInfo*(): execTypes.LibraryInfo =
  execTypes.LibraryInfo(name: libraryName)

proc finishOutcome(completion: ProcessCompletion): LeaseFinish =
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

proc runWithLease*(session: var RunQuotaSession; request: ResourceRequest;
                   command: CommandSpec; releaseAfterFinish = true;
                   waitForQueued = false): LeaseExecutionResult =
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
    var child = launchProcess(command)
    result.backend = child.info.backend
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
      processCount = completion.processCount
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
                   waitForQueued = false): LeaseExecutionResult =
  session.runWithLease(
    request,
    commandSpec(
      argv,
      cwd = cwd,
      env = env,
      stdoutLimit = stdoutLimit,
      stderrLimit = stderrLimit
    ),
    waitForQueued = waitForQueued
  )
