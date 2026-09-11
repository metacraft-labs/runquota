## The Windows Service Control Manager protocol, as a host `runquotad`
## can adopt without becoming a different program.
##
## ## Why this file exists
##
## `runquotad` is a host-wide lease authority: ONE PER HOST, serving
## every user. On Linux that is a systemd SYSTEM unit; on Windows the
## only mechanism with the same lifetime, the same single instance and
## the same "starts before anybody logs in" property is a Windows
## SERVICE. The packaging layer renders both from one `ServiceDef`
## (`scope: ssSystem`), so the MSI carries a `ServiceInstall` row and
## `sc start runquotad` is what an operator runs.
##
## Registration is not the same claim as starting. A plain console
## program registered as a service is launched by the SCM and then
## killed::
##
##   [SC] StartService FAILED 1053: The service did not respond to the
##   start or control request in a timely fashion.
##
## 1053 is the SCM saying "I launched your image and it never called
## `StartServiceCtrlDispatcher`". Within roughly 30 seconds of launch
## the image must connect to the SCM's dispatcher, register a control
## handler and report `SERVICE_RUNNING` through `SetServiceStatus`, and
## it must keep answering `SERVICE_CONTROL_STOP`. Reprobuild's
## `repro-binary-cache` met exactly this failure with a package whose
## service rows were correct in every other respect
## (Distribution-And-Packaging M1), and the answer it arrived at --
## teach the binary the protocol rather than ship a wrapper process --
## is the one adopted here. It adds no artifact to any package and it
## leaves the console behaviour byte-identical.
##
## The Win32 surface below is deliberately the same shape as
## `reprobuild/libs/repro_daemon_core/src/repro_daemon_core/windows_service.nim`.
## It is NOT imported from there: runquota does not depend on reprobuild
## (the dependency runs the other way -- reprobuild's integration tests
## spawn `runquotad`), and a daemon's ability to be a service must not
## be contingent on a sibling checkout.
##
## ## The shape, and why the payload does NOT run on the SCM's thread
##
## `StartServiceCtrlDispatcherW` blocks until every service in the table
## has returned, and it calls `ServiceMain` on a thread the SCM created
## -- a thread Nim did not start and whose GC and thread-local state Nim
## never initialised. `serve` allocates, spawns a worker pool, opens a
## store and takes Nim locks; running it on such a thread is the one
## arrangement here that could fail in ways nothing would explain.
##
## So the roles are swapped. The DISPATCHER runs on a helper thread; the
## PAYLOAD stays on the process's original Nim main thread:
##
## * the main thread calls `beginWindowsServiceHost`, which starts the
##   helper thread and waits on `gStartedEvent`;
## * the helper thread calls `StartServiceCtrlDispatcherW`. If that
##   fails with `ERROR_FAILED_SERVICE_CONTROLLER_CONNECT` (1063) the
##   process was NOT launched by the SCM -- an ordinary console run --
##   so it records "not a service" and signals `gStartedEvent`;
## * otherwise the SCM calls `serviceMain` on its own thread. That
##   proc does nothing but raw Win32: register the control handler,
##   report `SERVICE_START_PENDING`, signal `gStartedEvent`, then block
##   on `gStoppedEvent` until the payload says it is finished, and
##   report `SERVICE_STOPPED`. It allocates nothing and touches no Nim
##   heap object;
## * the control handler is the same: on STOP/SHUTDOWN it sets an
##   integer flag, reports `SERVICE_STOP_PENDING` and returns. Nothing
##   else.
##
## Every Nim-heap operation therefore still happens on the Nim main
## thread. The foreign threads only touch process globals of primitive
## type and call Win32.
##
## ## Auto-detection rather than a `--service` flag
##
## The SCM's own launch adds no arguments, so a flag would have to be
## baked into `BINARY_PATH_NAME` -- one more thing the MSI can get wrong
## and one more way for a hand-run to diverge from the service. 1063 is
## the documented, unambiguous signal that nobody is listening, so the
## binary asks instead of being told. It also means `runquotad`'s
## argument parser is untouched: every flag means the same thing under
## the SCM as it does at a prompt.
##
## ## stdout/stderr under the SCM
##
## A service has no console and no inherited standard handles, and
## `serve` prints THREE FIXED STARTUP LINES that readers consume by
## count. Nim's `File` write raises `IOError` when the underlying write
## does not complete, so those lines would be a crash rather than a log
## entry. `redirectStdioToFile` re-points both streams at a file before
## the payload runs, which turns the daemon's existing startup report
## into the service's log without the daemon knowing it happened.

when defined(windows):
  import std/os

  type
    ServiceStatus = object
      dwServiceType: uint32
      dwCurrentState: uint32
      dwControlsAccepted: uint32
      dwWin32ExitCode: uint32
      dwServiceSpecificExitCode: uint32
      dwCheckPoint: uint32
      dwWaitHint: uint32

    ServiceTableEntry = object
      lpServiceName: ptr uint16
      lpServiceProc: pointer

    ServiceCtrlHandler = proc (control: uint32) {.stdcall.}
    ServiceMainProc = proc (argc: uint32;
                            argv: ptr UncheckedArray[ptr uint16]) {.stdcall.}
    ThreadStartProc = proc (param: pointer): uint32 {.stdcall.}

  const
    SERVICE_WIN32_OWN_PROCESS = 0x00000010'u32
    SERVICE_STOPPED = 0x00000001'u32
    SERVICE_START_PENDING = 0x00000002'u32
    SERVICE_STOP_PENDING = 0x00000003'u32
    SERVICE_RUNNING = 0x00000004'u32
    SERVICE_ACCEPT_STOP = 0x00000001'u32
    SERVICE_ACCEPT_SHUTDOWN = 0x00000004'u32
    SERVICE_CONTROL_STOP = 0x00000001'u32
    SERVICE_CONTROL_INTERROGATE = 0x00000004'u32
    SERVICE_CONTROL_SHUTDOWN = 0x00000005'u32
    WaitInfinite = 0xFFFFFFFF'u32

  proc startServiceCtrlDispatcherW(table: ptr ServiceTableEntry): int32 {.
    stdcall, dynlib: "advapi32", importc: "StartServiceCtrlDispatcherW".}
  proc registerServiceCtrlHandlerW(name: ptr uint16;
                                   handler: ServiceCtrlHandler): pointer {.
    stdcall, dynlib: "advapi32", importc: "RegisterServiceCtrlHandlerW".}
  proc setServiceStatusW(handle: pointer; status: ptr ServiceStatus): int32 {.
    stdcall, dynlib: "advapi32", importc: "SetServiceStatus".}
  proc createEventW(attrs: pointer; manualReset, initialState: int32;
                    name: ptr uint16): pointer {.
    stdcall, dynlib: "kernel32", importc: "CreateEventW".}
  proc setEventW(handle: pointer): int32 {.
    stdcall, dynlib: "kernel32", importc: "SetEvent".}
  proc waitForSingleObjectW(handle: pointer; ms: uint32): uint32 {.
    stdcall, dynlib: "kernel32", importc: "WaitForSingleObject".}
  proc closeHandleW(handle: pointer): int32 {.
    stdcall, dynlib: "kernel32", importc: "CloseHandle".}
  proc createThreadW(attrs: pointer; stackSize: uint; start: ThreadStartProc;
                     param: pointer; flags: uint32;
                     threadId: ptr uint32): pointer {.
    stdcall, dynlib: "kernel32", importc: "CreateThread".}
  proc getLastErrorW(): uint32 {.
    stdcall, dynlib: "kernel32", importc: "GetLastError".}

  proc c_freopen(filename, mode: cstring; stream: File): File {.
    importc: "freopen", header: "<stdio.h>", discardable.}

  var
    gServiceName: ptr UncheckedArray[uint16] = nil
    gStatusHandle: pointer = nil
    gStatus: ServiceStatus
    gStartedEvent: pointer = nil
      ## Signalled once the run mode is known: by `serviceMain` when the
      ## SCM adopted us, by the helper thread when it did not.
    gStoppedEvent: pointer = nil
      ## Signalled by the PAYLOAD when it has finished. `serviceMain`
      ## waits on it and only then reports `SERVICE_STOPPED`.
    gDispatcherThread: pointer = nil
    gIsService: int32 = 0
    gStopRequested: int32 = 0
    gDispatcherError: int32 = 0
    gExitCode: int32 = 0

  proc allocWide(s: string): ptr UncheckedArray[uint16] =
    ## UTF-16 copy on the SHARED heap, so the foreign threads read a
    ## buffer the Nim collector has no opinion about. Service names are
    ## ASCII by construction (the packaging layer's `ServiceDef.name` is
    ## a unit/SCM identifier); a non-ASCII one is refused here rather
    ## than silently mangled.
    result = cast[ptr UncheckedArray[uint16]](allocShared0((s.len + 1) * 2))
    for i, c in s:
      doAssert ord(c) < 128,
        "windows service name must be ASCII, got: " & s
      result[i] = uint16(ord(c))

  proc reportStatus(state: uint32; exitCode: uint32; waitHint: uint32;
                    checkPoint: uint32) =
    if gStatusHandle == nil:
      return
    gStatus.dwServiceType = SERVICE_WIN32_OWN_PROCESS
    gStatus.dwCurrentState = state
    gStatus.dwWin32ExitCode = exitCode
    gStatus.dwServiceSpecificExitCode = 0
    gStatus.dwWaitHint = waitHint
    gStatus.dwCheckPoint = checkPoint
    gStatus.dwControlsAccepted =
      if state == SERVICE_START_PENDING or state == SERVICE_STOPPED: 0'u32
      else: SERVICE_ACCEPT_STOP or SERVICE_ACCEPT_SHUTDOWN
    discard setServiceStatusW(gStatusHandle, addr gStatus)

  proc serviceCtrlHandler(control: uint32) {.stdcall.} =
    ## Runs on an SCM thread. Integers and Win32 only.
    case control
    of SERVICE_CONTROL_STOP, SERVICE_CONTROL_SHUTDOWN:
      gStopRequested = 1
      # 20 s of grace, re-armed by the payload's own progress reports.
      # The SCM kills a service that stops answering; it waits for one
      # that keeps saying "still stopping". `serve`'s shutdown joins a
      # worker pool and flushes an observation store, so the grace has
      # to be re-armable rather than generous.
      reportStatus(SERVICE_STOP_PENDING, 0, 20000, 1)
    of SERVICE_CONTROL_INTERROGATE:
      reportStatus(gStatus.dwCurrentState, 0, 0, gStatus.dwCheckPoint)
    else:
      discard

  proc serviceMain(argc: uint32;
                   argv: ptr UncheckedArray[ptr uint16]) {.stdcall.} =
    ## Runs on a thread the SCM created. Deliberately does no Nim-heap
    ## work at all: register, report, hand off, wait, report, return.
    gStatusHandle = registerServiceCtrlHandlerW(
      cast[ptr uint16](gServiceName), serviceCtrlHandler)
    if gStatusHandle == nil:
      # Cannot talk to the SCM. Fall back to console semantics rather
      # than leaving the main thread blocked forever.
      gDispatcherError = int32(getLastErrorW())
      gIsService = 0
      discard setEventW(gStartedEvent)
      return
    gIsService = 1
    reportStatus(SERVICE_START_PENDING, 0, 30000, 1)
    discard setEventW(gStartedEvent)
    discard waitForSingleObjectW(gStoppedEvent, WaitInfinite)
    reportStatus(SERVICE_STOPPED, uint32(gExitCode), 0, 0)

  proc dispatcherThreadProc(param: pointer): uint32 {.stdcall.} =
    var table: array[2, ServiceTableEntry]
    table[0].lpServiceName = cast[ptr uint16](gServiceName)
    table[0].lpServiceProc = cast[pointer](cast[ServiceMainProc](serviceMain))
    table[1].lpServiceName = nil
    table[1].lpServiceProc = nil
    if startServiceCtrlDispatcherW(addr table[0]) == 0:
      gDispatcherError = int32(getLastErrorW())
      gIsService = 0
      discard setEventW(gStartedEvent)
    result = 0

  proc beginWindowsServiceHost*(serviceName: string): bool =
    ## Connect to the SCM and return whether this process is running AS
    ## a service.
    ##
    ## `false` means an ordinary console run and the caller proceeds
    ## exactly as it did before this file existed -- no status
    ## reporting, no stop handler, no redirection. `true` means the SCM
    ## is waiting: the caller must call `reportWindowsServiceRunning`
    ## once it is actually serving, poll `windowsServiceStopRequested`,
    ## and finish with `endWindowsServiceHost`.
    if gServiceName != nil:
      return gIsService != 0
    gServiceName = allocWide(serviceName)
    gStartedEvent = createEventW(nil, 1, 0, nil)
    gStoppedEvent = createEventW(nil, 1, 0, nil)
    if gStartedEvent == nil or gStoppedEvent == nil:
      gDispatcherError = int32(getLastErrorW())
      return false
    var tid: uint32 = 0
    gDispatcherThread = createThreadW(nil, 0, dispatcherThreadProc, nil, 0,
      addr tid)
    if gDispatcherThread == nil:
      gDispatcherError = int32(getLastErrorW())
      return false
    discard waitForSingleObjectW(gStartedEvent, WaitInfinite)
    gIsService != 0

  proc runningAsWindowsService*(): bool =
    ## Whether `beginWindowsServiceHost` found an SCM. Answers `false`
    ## before it has been called, which is the right answer for every
    ## caller that never calls it (the test suites, `runquota daemon
    ## start`).
    gIsService != 0

  proc windowsServiceStopRequested*(): bool =
    ## Has the SCM asked this service to stop? Always `false` in a
    ## console run.
    gStopRequested != 0

  proc windowsServiceDispatcherError*(): int =
    ## `GetLastError` from the dispatcher connection.
    ##
    ## 1063 is `ERROR_FAILED_SERVICE_CONTROLLER_CONNECT`, the ordinary
    ## "this process was not launched by the SCM" answer and the signal
    ## that makes a `--service` flag unnecessary. Anything else is a real
    ## fault worth logging: the dispatcher was there and the connection
    ## still failed.
    int(gDispatcherError)

  proc reportWindowsServiceRunning*() =
    ## Report `SERVICE_RUNNING`. Called by the payload AFTER it is bound
    ## and serving, not before: reporting RUNNING from `serviceMain`
    ## would make `sc start` succeed for a daemon that then refused its
    ## rendezvous endpoint, which is precisely the failure this whole
    ## file exists to stop hiding.
    if gIsService != 0:
      reportStatus(SERVICE_RUNNING, 0, 0, 0)

  proc reportWindowsServiceStopping*(waitHintMs: uint32 = 20000) =
    ## Re-arm the stop grace period from a long shutdown path.
    if gIsService != 0:
      gStatus.dwCheckPoint = gStatus.dwCheckPoint + 1
      reportStatus(SERVICE_STOP_PENDING, 0, waitHintMs, gStatus.dwCheckPoint)

  proc endWindowsServiceHost*(exitCode: int = 0) =
    ## The payload has finished. Release `serviceMain` so it reports
    ## `SERVICE_STOPPED`, and wait for it -- a process that exits before
    ## that report leaves the SCM to infer the stop from process death,
    ## which it logs as an error.
    if gIsService == 0:
      return
    gExitCode = int32(exitCode)
    discard setEventW(gStoppedEvent)
    if gDispatcherThread != nil:
      discard waitForSingleObjectW(gDispatcherThread, 10000)
      discard closeHandleW(gDispatcherThread)
      gDispatcherThread = nil

  proc redirectStdioToFile*(path: string): bool {.discardable.} =
    ## Point `stdout` and `stderr` at `path`.
    ##
    ## Mandatory under the SCM, not cosmetic: a service inherits no
    ## standard handles, and Nim's `File` write RAISES when the write
    ## does not complete, so `serve`'s three startup lines would abort
    ## the process instead of being logged.
    try:
      let dir = parentDir(path)
      if dir.len > 0:
        createDir(dir)
    except CatchableError:
      discard
    let c = path.cstring
    result = c_freopen(c, "a".cstring, stdout) != nil
    if c_freopen(c, "a".cstring, stderr) == nil:
      result = false

else:
  ## POSIX has no Service Control Manager. The module still compiles so
  ## `serve` and `runquotad` can be written without a `when` around
  ## every call, and so the cross-platform suites can pin the contract;
  ## every entry point answers "not a service".
  proc beginWindowsServiceHost*(serviceName: string): bool = false
  proc runningAsWindowsService*(): bool = false
  proc windowsServiceStopRequested*(): bool = false
  proc windowsServiceDispatcherError*(): int = 0
  proc reportWindowsServiceRunning*() = discard
  proc reportWindowsServiceStopping*(waitHintMs: uint32 = 20000) = discard
  proc endWindowsServiceHost*(exitCode: int = 0) = discard
  proc redirectStdioToFile*(path: string): bool {.discardable.} = false
