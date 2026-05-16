from runquota_process import ProcessBackendProfile, ProcessCompletion

type
  LibraryInfo* = object
    name*: string

  ExecutionState* = enum
    esWaitingForLease
    esStarting
    esRunning
    esFinished
    esReleased

  LeaseExecutionResult* = object
    state*: ExecutionState
    leaseId*: uint64
    process*: ProcessCompletion
    backend*: ProcessBackendProfile
    leaseFinishedSent*: bool
    leaseReleased*: bool
    stdoutBytes*: uint64
    stderrBytes*: uint64
