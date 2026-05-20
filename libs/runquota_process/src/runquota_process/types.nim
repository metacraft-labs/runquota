type
  LibraryInfo* = object
    name*: string

  ProcessBackendProfile* = object
    name*: string
    launchPrimitive*: string
    outputCapture*: string
    completionWait*: string
    cancellation*: string
    telemetry*: string
    directArgv*: bool
    implicitShell*: bool

  CommandSpec* = object
    argv*: seq[string]
    cwd*: string
    env*: seq[string]
    stdoutLimit*: int
    stderrLimit*: int
    createProcessGroup*: bool

  LaunchResult* = object
    processId*: uint64
    processGroupId*: uint64
    running*: bool
    backend*: ProcessBackendProfile

  ProcessCompletion* = object
    processId*: uint64
    processGroupId*: uint64
    exitCode*: int
    signal*: int
    exited*: bool
    signaled*: bool
    cancelled*: bool
    timedOut*: bool
    stdout*: string
    stderr*: string
    stdoutBytes*: uint64
    stderrBytes*: uint64
    elapsedMillis*: uint64
    peakResidentMemoryBytes*: uint64
    processCount*: uint32
    telemetrySource*: string

  LaunchedProcess* = object
    pid*: int
    processGroupId*: int
    stdoutFd*: int
    stderrFd*: int
    stdoutLimit*: int
    stderrLimit*: int
    startedSeconds*: float
    runningFlag*: bool
    cancelSent*: bool
    doneFlag*: bool
    waitStatus*: int
    stdoutText*: string
    stderrText*: string
    stdoutBytes*: uint64
    stderrBytes*: uint64
    peakResidentMemoryBytes*: uint64
    processCount*: uint32
    telemetrySource*: string
    lastTelemetrySampleSeconds*: float
    info*: LaunchResult
    completion*: ProcessCompletion
    # Windows: extra slots store the osproc Process pointer and the Job Object
    # handle so the rest of the lifecycle (wait/terminate/close) can find them.
    # The fields are present on all platforms (kept simple to avoid case-object
    # constructor noise) but only populated on Windows.
    winProcessPtr*: pointer
    winJobHandle*: uint64
