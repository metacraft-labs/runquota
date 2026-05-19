type
  LibraryInfo* = object
    name*: string
  WindowsCapability* = enum
    wcJobObjects
    wcNamedPipes
    # Windows: GlobalMemoryStatusEx-derived pressure is always available since
    # Windows XP, so we advertise it whenever the host backend is wired in.
    wcMemoryPressure
    # Windows: process-tree telemetry uses Toolhelp32 + K32GetProcessMemoryInfo
    # to walk a parent/child PID chain and sum WorkingSetSize across the tree.
    wcProcessTreeTelemetry
