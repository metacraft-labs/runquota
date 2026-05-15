type
  LibraryInfo* = object
    name*: string
  ExecutionState* = enum
    esWaitingForLease
    esRunning
    esFinished
