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
    cgroupPath*: string
      ## The cgroup the tree ran in, or "" (`cgroupProblem` says why when a
      ## placement was asked for).
    cgroupProblem*: string
    memoryCapNote*: string
      ## "memory cap not enforced: <why>" when a cap applied and the
      ## platform layer did not enforce it (`memoryCapNotEnforced`), "" when
      ## it did or when no cap applied. The launcher shows it.
    memoryCapReport*: string
      ## The report of a tree that passed its memory cap
      ## (`memoryCapReport`), "" when it did not. The launcher shows it.
