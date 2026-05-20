import runquota_client
import runquota_core
import runquota_exec/types as execTypes
import runquota_process
import runquota_protocol

export execTypes

const libraryName* = "runquota_exec"

proc libraryInfo*(): execTypes.LibraryInfo =
  execTypes.LibraryInfo(name: libraryName)

proc finishOutcome(completion: ProcessCompletion): LeaseFinishOutcome =
  if completion.cancelled or completion.timedOut:
    leaseFinishCancelled
  elif completion.signaled:
    leaseFinishCrashed
  elif completion.exited and completion.exitCode == 0:
    leaseFinishSucceeded
  else:
    leaseFinishFailed

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
      exitCode = if completion.exited: uint32(max(completion.exitCode,
          0)) else: 0'u32,
      signal = if completion.signaled: uint32(max(completion.signal,
          0)) else: 0'u32,
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
      lease.finish(outcome = leaseFinishLaunchFailed)
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
