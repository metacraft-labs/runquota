import std/osproc

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
    inheritEnv*: bool
      ## When true (`commandSpec`'s default) the child starts from the
      ## launcher's environment and `env` is layered over it. When false the
      ## child's environment is EXACTLY `env`: nothing is inherited, so a
      ## caller that must control what a process can observe (a build that
      ## keys an action on the variables it reads) can do so. There is no
      ## other removal channel — layering can replace a variable, never
      ## unset one.
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
    # Wall-clock time (epochTime seconds) at which the leased child itself was
    # reaped. Used to bound the final output drain: once the direct child has
    # exited we must declare completion even if forked descendants keep the
    # inherited pipe write-ends open (so the pipes never reach EOF). 0.0 means
    # "not yet reaped".
    doneSeconds*: float
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
    # Windows: extra slots store the osproc Process ref and the Job Object
    # handle so the rest of the lifecycle (wait/terminate/close) can find
    # them. The fields are present on all platforms (kept simple to avoid
    # case-object constructor noise) but only populated on Windows.
    #
    # `winProcess` MUST be a typed `Process` ref (not a raw `pointer`):
    # Nim's Process is a ref ProcessObj, and storing only an untyped
    # pointer cast hides the reference from the GC. At higher concurrency
    # the GC can collect the underlying ProcessObj before the LaunchedProcess
    # is finished with it; the next pollCompletion then dereferences freed
    # memory, occasionally tripping the
    # `poParentStreams notin p.options` assert inside osproc.outputStream
    # when the freed memory happens to alias a Process with those options.
    winProcess*: Process
    winJobHandle*: uint64
    # Windows: end of input seen on the child's stdout / stderr pipe.
    winStdoutClosed*: bool
    winStderrClosed*: bool
    temporaryLaunchFiles*: seq[string]
