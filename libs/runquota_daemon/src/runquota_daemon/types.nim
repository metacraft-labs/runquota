type
  LibraryInfo* = object
    name*: string
  DaemonState* = enum
    dsStarting
    dsServing
    dsStopping
