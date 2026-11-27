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
      ## Why the tree ran without a memory cap (`MemoryCapResolution.reason`),
      ## or "" when one was applied or measured.
    memoryCapReport*: string
      ## The report of a tree that passed its memory cap
      ## (`memoryCapReport`), "" when it did not. The launcher shows it.
