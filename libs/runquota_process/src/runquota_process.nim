import std/[envvars, os, strutils, times]

when defined(posix):
  import std/posix

when defined(windows):
  # Windows: spawn child processes via std/osproc and assign them to a Job
  # Object so the whole tree can be tracked and (optionally) killed atomically.
  # The Job Object also gives us cheap accounting (CPU/IO/process count).
  import std/[osproc, streams, strtabs]
  import std/winlean

import runquota_core
when defined(linux):
  import runquota_host_linux
import runquota_host_macos
when defined(windows):
  # Windows: per-lease RSS telemetry comes from the Windows host backend so
  # waitForCompletion can record peakResidentMemoryBytes on the ProcessCompletion.
  import runquota_host_windows
import runquota_process/types as processTypes

export processTypes

const libraryName* = "runquota_process"
const DefaultOutputLimit* = 1_048_576

when defined(posix):
  proc childExit(status: cint) {.importc: "_exit", header: "<unistd.h>", noreturn.}

when defined(windows):
  # Windows: lightweight Job Object accounting wrappers. We pull in only the
  # symbols we use rather than depend on a Job Objects helper module that does
  # not exist in stdlib.
  type
    JobBasicLimitW = object
      PerProcessUserTimeLimit: int64
      PerJobUserTimeLimit: int64
      LimitFlags: int32
      MinimumWorkingSetSize: uint
      MaximumWorkingSetSize: uint
      ActiveProcessLimit: int32
      Affinity: uint
      PriorityClass: int32
      SchedulingClass: int32

    IoCountersW = object
      ReadOperationCount: uint64
      WriteOperationCount: uint64
      OtherOperationCount: uint64
      ReadTransferCount: uint64
      WriteTransferCount: uint64
      OtherTransferCount: uint64

    JobExtendedLimitW = object
      BasicLimitInformation: JobBasicLimitW
      IoInfo: IoCountersW
      ProcessMemoryLimit: uint
      JobMemoryLimit: uint
      PeakProcessMemoryUsed: uint
      PeakJobMemoryUsed: uint

    JobBasicAccountingW = object
      TotalUserTime: int64
      TotalKernelTime: int64
      ThisPeriodTotalUserTime: int64
      ThisPeriodTotalKernelTime: int64
      TotalPageFaultCount: int32
      TotalProcesses: int32
      ActiveProcesses: int32
      TotalTerminatedProcesses: int32

    JobBasicAndIoAccountingW = object
      BasicInfo: JobBasicAccountingW
      IoInfo: IoCountersW

  const
    # Windows: JobObjectExtendedLimitInformation = 9,
    # JobObjectBasicAndIoAccountingInformation = 8.
    JobObjectExtendedLimitInformation = 9'i32
    JobObjectBasicAndIoAccountingInformation = 8'i32
    # Windows: JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000 so when the daemon
    # drops its handle the child tree is reaped automatically. We don't set
    # JOB_OBJECT_LIMIT_BREAKAWAY_OK; child processes inherit job membership.
    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000'i32

  proc createJobObjectW(
    lpJobAttributes: pointer, lpName: WideCString
  ): Handle {.stdcall, dynlib: "kernel32.dll", importc: "CreateJobObjectW".}

  proc assignProcessToJobObject(
    hJob: Handle, hProcess: Handle
  ): WINBOOL {.stdcall, dynlib: "kernel32.dll", importc: "AssignProcessToJobObject".}

  proc setInformationJobObject(
    hJob: Handle, JobObjectInformationClass: int32,
    lpJobObjectInformation: pointer, cbJobObjectInformationLength: int32
  ): WINBOOL {.stdcall, dynlib: "kernel32.dll", importc: "SetInformationJobObject".}

  proc queryInformationJobObject(
    hJob: Handle, JobObjectInformationClass: int32,
    lpJobObjectInformation: pointer, cbJobObjectInformationLength: int32,
    lpReturnLength: ptr int32
  ): WINBOOL {.stdcall, dynlib: "kernel32.dll", importc: "QueryInformationJobObject".}

  proc terminateJobObject(
    hJob: Handle, uExitCode: uint32
  ): WINBOOL {.stdcall, dynlib: "kernel32.dll", importc: "TerminateJobObject".}

  # Windows: stdlib's std/osproc exposes Process.fProcessHandle and .id but on
  # different versions/branches the field names move. Pull them out via a tiny
  # accessor module so the only place that names them is here.
  proc winProcessHandle(p: Process): Handle =
    # Windows: std/osproc stores the handle in `p.fProcessHandle` on Windows.
    when compiles(p.fProcessHandle):
      Handle(p.fProcessHandle)
    else:
      Handle(0)

  proc applyKillOnJobClose(job: Handle) =
    var info: JobExtendedLimitW
    info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    discard setInformationJobObject(
      job,
      JobObjectExtendedLimitInformation,
      addr info,
      int32(sizeof(JobExtendedLimitW))
    )

  proc readJobAccounting(job: Handle; cpuMicros: var uint64;
                         processCount: var uint32) =
    var info: JobBasicAndIoAccountingW
    var ret: int32 = 0
    if queryInformationJobObject(
      job,
      JobObjectBasicAndIoAccountingInformation,
      addr info,
      int32(sizeof(JobBasicAndIoAccountingW)),
      addr ret) != 0:
      # Windows: TotalUserTime + TotalKernelTime are 100ns ticks. Divide by 10
      # to get microseconds.
      let totalTicks = info.BasicInfo.TotalUserTime + info.BasicInfo.TotalKernelTime
      if totalTicks > 0:
        cpuMicros = uint64(totalTicks div 10)
      processCount = uint32(max(int32(0), info.BasicInfo.TotalProcesses))

proc libraryInfo*(): processTypes.LibraryInfo =
  processTypes.LibraryInfo(name: libraryName)

proc backendProfile*(): ProcessBackendProfile =
  when defined(posix):
    ProcessBackendProfile(
      name: "posix-fork-exec-poll",
      launchPrimitive: "fork+execvp",
      outputCapture: "nonblocking-pipes-poll-bounded",
      completionWait: "waitpid-wnohang",
      cancellation: "process-group-sigterm",
      telemetry: "macos-ps-when-available",
      directArgv: true,
      implicitShell: false
    )
  elif defined(windows):
    # Windows: each lease's child tree runs in a Job Object so cancellation
    # and accounting are scoped to the tree, not the leader process alone.
    ProcessBackendProfile(
      name: "windows-osproc-jobobject",
      launchPrimitive: "CreateProcess+AssignProcessToJobObject",
      outputCapture: "osproc-pipes",
      completionWait: "waitForExit",
      cancellation: "TerminateJobObject",
      telemetry: "job-object-accounting",
      directArgv: true,
      implicitShell: false
    )
  else:
    ProcessBackendProfile(
      name: "unsupported",
      launchPrimitive: "none",
      outputCapture: "none",
      completionWait: "none",
      cancellation: "none",
      telemetry: "none",
      directArgv: false,
      implicitShell: false
    )

proc commandSpec*(argv: openArray[string]; cwd = ""; env: openArray[string] = [];
                  stdoutLimit = DefaultOutputLimit; stderrLimit = DefaultOutputLimit;
                  createProcessGroup = true): CommandSpec =
  for item in argv:
    result.argv.add(item)
  result.cwd = cwd
  for item in env:
    result.env.add(item)
  result.stdoutLimit = stdoutLimit
  result.stderrLimit = stderrLimit
  result.createProcessGroup = createProcessGroup

proc launchResult*(processId: uint64; running: bool): LaunchResult =
  LaunchResult(
    processId: processId,
    processGroupId: processId,
    running: running,
    backend: backendProfile()
  )

when defined(posix):
  proc closeFd(fd: var int) =
    if fd >= 0:
      discard close(cint(fd))
      fd = -1

  proc setNonblock(fd: int) =
    let flags = fcntl(cint(fd), F_GETFL)
    if flags >= 0:
      discard fcntl(cint(fd), F_SETFL, flags or O_NONBLOCK)

  proc appendBounded(target: var string; total: var uint64; data: pointer;
                     count, limit: int) =
    if count <= 0:
      return
    total += uint64(count)
    if limit <= 0 or target.len >= limit:
      return
    let take = min(count, limit - target.len)
    let oldLen = target.len
    target.setLen(oldLen + take)
    copyMem(addr target[oldLen], data, take)

  proc drainFd(fd: var int; target: var string; total: var uint64; limit: int) =
    if fd < 0:
      return
    var buffer: array[8192, char]
    while true:
      let readCount = read(cint(fd), addr buffer[0], buffer.len)
      if readCount > 0:
        appendBounded(target, total, addr buffer[0], readCount, limit)
      elif readCount == 0:
        closeFd(fd)
        break
      else:
        if errno == EAGAIN or errno == EINTR:
          break
        closeFd(fd)
        break

  proc applyChildEnv(values: openArray[string]) =
    for item in values:
      let split = item.find('=')
      if split > 0:
        putEnv(item[0 ..< split], item[split + 1 .. ^1])

  proc buildCompletion(child: LaunchedProcess; status: cint; elapsedMillis: uint64;
                       stdoutText, stderrText: string; stdoutBytes, stderrBytes: uint64;
                       timedOut: bool; peakResidentMemoryBytes: uint64;
                       processCount: uint32; telemetrySource: string): ProcessCompletion =
    result = ProcessCompletion(
      processId: uint64(child.pid),
      processGroupId: uint64(child.processGroupId),
      exitCode: -1,
      signal: 0,
      exited: false,
      signaled: false,
      cancelled: child.cancelSent,
      timedOut: timedOut,
      stdout: stdoutText,
      stderr: stderrText,
      stdoutBytes: stdoutBytes,
      stderrBytes: stderrBytes,
      elapsedMillis: elapsedMillis,
      peakResidentMemoryBytes: peakResidentMemoryBytes,
      processCount: processCount,
      telemetrySource: telemetrySource
    )
    if not timedOut:
      if WIFEXITED(status):
        result.exited = true
        result.exitCode = int(WEXITSTATUS(status))
      elif WIFSIGNALED(status):
        result.signaled = true
        result.signal = int(WTERMSIG(status))

when defined(windows):
  # Windows: build a flat KEY=VALUE list from inherited + override env so
  # std/osproc can apply it via the `env` table parameter.
  proc windowsChildEnv(spec: CommandSpec): StringTableRef =
    # Windows: start from the current process env, then layer overrides.
    when compiles(newStringTable()):
      result = newStringTable()
    for k, v in envPairs():
      result[k] = v
    for entry in spec.env:
      let eq = entry.find('=')
      if eq <= 0:
        continue
      result[entry[0 ..< eq]] = entry[eq + 1 .. ^1]

  proc launchWindowsProcess(spec: CommandSpec): LaunchedProcess =
    if spec.argv.len == 0:
      raise newException(ValueError, "empty argv")
    let cwd = if spec.cwd.len > 0: spec.cwd else: getCurrentDir()
    let args =
      if spec.argv.len > 1: spec.argv[1 .. ^1]
      else: @[]
    # Windows: poEvalCommand + poUsePath were tried in earlier prototypes but
    # cause quoting headaches; pass argv directly and let osproc CreateProcess
    # for us.
    var process = startProcess(
      spec.argv[0],
      workingDir = cwd,
      args = args,
      env = windowsChildEnv(spec),
      options = {poStdErrToStdOut, poUsePath}
    )
    let processHandle = winProcessHandle(process)
    let job = createJobObjectW(nil, nil)
    if job != 0:
      # Windows: best-effort assignment. The child has already started; if it
      # was launched without CREATE_SUSPENDED it may have spawned a grandchild
      # before we get here. We accept this race for now.
      discard assignProcessToJobObject(job, processHandle)
      applyKillOnJobClose(job)
    let processId = uint64(process.processID)
    result = LaunchedProcess(
      pid: int(processId),
      processGroupId: int(processId),
      stdoutFd: -1,
      stderrFd: -1,
      stdoutLimit: spec.stdoutLimit,
      stderrLimit: spec.stderrLimit,
      startedSeconds: epochTime(),
      runningFlag: true,
      cancelSent: false,
      info: LaunchResult(
        processId: processId,
        processGroupId: processId,
        running: true,
        backend: backendProfile()
      ),
      winProcessPtr: cast[pointer](process),
      winJobHandle: uint64(job)
    )

proc launchProcess*(spec: CommandSpec): LaunchedProcess =
  when defined(posix):
    if spec.argv.len == 0:
      raise newException(ValueError, "empty argv")
    var stdoutPipe: array[0..1, cint]
    var stderrPipe: array[0..1, cint]
    if pipe(stdoutPipe) != 0:
      raise newException(OSError, "stdout pipe failed")
    if pipe(stderrPipe) != 0:
      discard close(stdoutPipe[0])
      discard close(stdoutPipe[1])
      raise newException(OSError, "stderr pipe failed")

    let argv = allocCStringArray(spec.argv)
    defer: deallocCStringArray(argv)
    let pid = fork()
    if pid == 0:
      discard close(stdoutPipe[0])
      discard close(stderrPipe[0])
      if spec.createProcessGroup:
        discard setpgid(0, 0)
      if spec.cwd.len > 0 and chdir(cstring(spec.cwd)) != 0:
        childExit(126)
      applyChildEnv(spec.env)
      discard dup2(stdoutPipe[1], STDOUT_FILENO)
      discard dup2(stderrPipe[1], STDERR_FILENO)
      discard close(stdoutPipe[1])
      discard close(stderrPipe[1])
      discard execvp(cstring(spec.argv[0]), argv)
      childExit(127)
    if pid < 0:
      discard close(stdoutPipe[0])
      discard close(stdoutPipe[1])
      discard close(stderrPipe[0])
      discard close(stderrPipe[1])
      raise newException(OSError, "fork failed")

    discard close(stdoutPipe[1])
    discard close(stderrPipe[1])
    setNonblock(int(stdoutPipe[0]))
    setNonblock(int(stderrPipe[0]))
    if spec.createProcessGroup:
      discard setpgid(pid, pid)
    let pgid = if spec.createProcessGroup: int(pid) else: int(getpgid(pid))
    LaunchedProcess(
      pid: int(pid),
      processGroupId: pgid,
      stdoutFd: int(stdoutPipe[0]),
      stderrFd: int(stderrPipe[0]),
      stdoutLimit: spec.stdoutLimit,
      stderrLimit: spec.stderrLimit,
      startedSeconds: epochTime(),
      runningFlag: true,
      cancelSent: false,
      doneFlag: false,
      waitStatus: 0,
      stdoutBytes: 0'u64,
      stderrBytes: 0'u64,
      peakResidentMemoryBytes: 0'u64,
      processCount: 0'u32,
      telemetrySource: backendProfile().telemetry,
      lastTelemetrySampleSeconds: 0.0,
      info: LaunchResult(
        processId: uint64(pid),
        processGroupId: uint64(max(pgid, 0)),
        running: true,
        backend: backendProfile()
      )
    )
  elif defined(windows):
    # Windows: delegate to the Job-Object-aware launcher above.
    launchWindowsProcess(spec)
  else:
    raise newException(OSError, "runquota_process is only implemented on POSIX")

proc launchProcess*(program: string; args: openArray[string] = []): LaunchedProcess =
  var argv: seq[string] = @[program]
  for arg in args:
    argv.add(arg)
  launchProcess(commandSpec(argv))

proc running*(child: LaunchedProcess): bool =
  when defined(posix):
    if not child.runningFlag:
      return false
    if child.completion.exited or child.completion.signaled or
        child.completion.timedOut:
      return false
    # This predicate must not reap the child. Completion status is consumed by
    # pollCompletion/waitForCompletion so callers can still observe the real
    # exit code after asking whether the process is probably still alive.
    if child.pid <= 0:
      return false
    kill(Pid(child.pid), 0) == 0 or errno == EPERM
  elif defined(windows):
    if not child.runningFlag or child.winProcessPtr.isNil:
      return false
    let process = cast[Process](child.winProcessPtr)
    process.running()
  else:
    false

proc buildCompletion(child: LaunchedProcess; timedOut: bool): ProcessCompletion =
  when defined(posix):
    buildCompletion(
      child,
      cint(child.waitStatus),
      uint64(max(0, int((epochTime() - child.startedSeconds) * 1000.0))),
      child.stdoutText,
      child.stderrText,
      child.stdoutBytes,
      child.stderrBytes,
      timedOut,
      child.peakResidentMemoryBytes,
      child.processCount,
      child.telemetrySource)
  else:
    raise newException(OSError, "runquota_process is only implemented on POSIX")

proc pollCompletion*(child: var LaunchedProcess): bool =
  ## Nonblocking completion check. This drains any currently available output
  ## and performs a WNOHANG wait without reaping status behind the caller's
  ## back. When it returns true, ``child.completion`` is populated.
  when defined(posix):
    if child.completion.exited or child.completion.signaled or
        child.completion.timedOut:
      return true

    child.stdoutFd.drainFd(child.stdoutText, child.stdoutBytes,
                           child.stdoutLimit)
    child.stderrFd.drainFd(child.stderrText, child.stderrBytes,
                           child.stderrLimit)

    if not child.doneFlag:
      let now = epochTime()
      if child.lastTelemetrySampleSeconds == 0.0 or
          now - child.lastTelemetrySampleSeconds >= 0.1:
        let sample =
          when defined(linux):
            sampleLinuxProcessTreeTelemetry(uint64(child.pid))
          else:
            sampleMacosProcessTreeTelemetry(uint64(child.pid))
        child.lastTelemetrySampleSeconds = now
        child.telemetrySource = sample.source
        if sample.diagnostic.code == diagOk:
          if sample.residentMemoryBytes > child.peakResidentMemoryBytes:
            child.peakResidentMemoryBytes = sample.residentMemoryBytes
          if sample.processCount > child.processCount:
            child.processCount = sample.processCount
      var status: cint = 0
      let waited = waitpid(Pid(child.pid), status, WNOHANG)
      if waited == Pid(child.pid):
        child.doneFlag = true
        child.runningFlag = false
        child.waitStatus = int(status)
      elif waited < 0:
        if errno != EINTR:
          child.doneFlag = true
          child.runningFlag = false
          child.waitStatus = 1 shl 8

    if child.doneFlag:
      child.stdoutFd.drainFd(child.stdoutText, child.stdoutBytes,
                             child.stdoutLimit)
      child.stderrFd.drainFd(child.stderrText, child.stderrBytes,
                             child.stderrLimit)
      if child.stdoutFd < 0 and child.stderrFd < 0:
        child.completion = child.buildCompletion(timedOut = false)
        if child.completion.processCount == 0:
          child.completion.processCount = 1
        return true
    false
  else:
    raise newException(OSError, "runquota_process is only implemented on POSIX")

proc terminate*(child: var LaunchedProcess) =
  when defined(posix):
    child.cancelSent = true
    if child.processGroupId > 0:
      discard kill(Pid(-child.processGroupId), SIGTERM)
    elif child.pid > 0:
      discard kill(Pid(child.pid), SIGTERM)
  elif defined(windows):
    # Windows: terminate the whole tree by terminating its Job Object. If the
    # job handle is missing (assignment failed), fall back to terminating the
    # primary process via osproc.
    child.cancelSent = true
    if child.winJobHandle != 0:
      discard terminateJobObject(Handle(child.winJobHandle), 1'u32)
    elif not child.winProcessPtr.isNil:
      let process = cast[Process](child.winProcessPtr)
      try: process.terminate() except CatchableError: discard

proc killNow*(child: var LaunchedProcess) =
  when defined(posix):
    child.cancelSent = true
    if child.processGroupId > 0:
      discard kill(Pid(-child.processGroupId), SIGKILL)
    elif child.pid > 0:
      discard kill(Pid(child.pid), SIGKILL)
  elif defined(windows):
    # Windows: hard-kill via Job Object termination (same effect as terminate
    # since TerminateJobObject is unconditional).
    child.cancelSent = true
    if child.winJobHandle != 0:
      discard terminateJobObject(Handle(child.winJobHandle), 1'u32)
    elif not child.winProcessPtr.isNil:
      let process = cast[Process](child.winProcessPtr)
      try: process.kill() except CatchableError: discard

proc waitForCompletion*(child: var LaunchedProcess; timeout = -1): ProcessCompletion =
  when defined(posix):
    var timedOut = false

    while true:
      if child.pollCompletion():
        break

      let elapsed = int((epochTime() - child.startedSeconds) * 1000.0)
      if timeout >= 0 and elapsed >= timeout:
        timedOut = true
        child.terminate()
        let killDeadline = epochTime() + 1.0
        while epochTime() < killDeadline:
          child.stdoutFd.drainFd(child.stdoutText, child.stdoutBytes,
                                 child.stdoutLimit)
          child.stderrFd.drainFd(child.stderrText, child.stderrBytes,
                                 child.stderrLimit)
          var status: cint = 0
          let waited = waitpid(Pid(child.pid), status, WNOHANG)
          if waited == Pid(child.pid):
            child.doneFlag = true
            child.runningFlag = false
            child.waitStatus = int(status)
            break
          sleep(10)
        if not child.doneFlag:
          child.killNow()
          var status: cint = 0
          discard waitpid(Pid(child.pid), status, 0)
          child.waitStatus = int(status)
          child.doneFlag = true
          child.runningFlag = false
        child.stdoutFd.drainFd(child.stdoutText, child.stdoutBytes,
                               child.stdoutLimit)
        child.stderrFd.drainFd(child.stderrText, child.stderrBytes,
                               child.stderrLimit)
        closeFd(child.stdoutFd)
        closeFd(child.stderrFd)
        break

      if child.stdoutFd >= 0 or child.stderrFd >= 0:
        var fds: array[0..1, TPollfd]
        var count = 0
        if child.stdoutFd >= 0:
          fds[count] = TPollfd(fd: cint(child.stdoutFd), events: POLLIN, revents: 0)
          inc count
        if child.stderrFd >= 0:
          fds[count] = TPollfd(fd: cint(child.stderrFd), events: POLLIN, revents: 0)
          inc count
        discard poll(addr fds[0], Tnfds(count), 10)
      else:
        sleep(10)

    if timedOut:
      child.completion = child.buildCompletion(timedOut = true)
    result = child.completion
    if result.processCount == 0 and not result.timedOut:
      result.processCount = 1
    child.completion = result
  elif defined(windows):
    # Windows: stream stdout (merged stderr via poStdErrToStdOut) into a
    # bounded buffer while polling for exit, then collect Job Object
    # accounting. We re-use osproc's Process.outputStream for capture.
    if child.winProcessPtr.isNil:
      raise newException(OSError, "runquota_process: missing Windows process handle")
    let process = cast[Process](child.winProcessPtr)
    var stdoutText = ""
    var stdoutBytes = 0'u64
    var timedOut = false
    var exitCode = -1
    let outputStream = process.outputStream
    var buffer = newString(8192)
    # Windows: track the peak RSS observed over the lifetime of the tree by
    # sampling Toolhelp32 each poll iteration. We can't read RSS post-exit so
    # the running loop must record it before the process drops out. We avoid
    # blocking on outputStream.readData (which would stall RSS polling while
    # the child is silent) and instead peek the pipe each iteration.
    var peakResidentBytes = 0'u64
    var observedProcessCount = 0'u32
    var telemetrySource = backendProfile().telemetry
    while true:
      # Windows: sample the live tree first so even very short-lived children
      # get at least one snapshot before they exit.
      let sample = sampleWindowsProcessTreeTelemetry(uint64(child.pid))
      telemetrySource = sample.source
      if sample.diagnostic.code == diagOk:
        if sample.residentMemoryBytes > peakResidentBytes:
          peakResidentBytes = sample.residentMemoryBytes
        if sample.processCount > observedProcessCount:
          observedProcessCount = sample.processCount
      # Windows: drain stdout only when there's data ready (PeekNamedPipe),
      # so an idle child doesn't stall the RSS poller.
      var pulled = false
      if outputStream != nil and process.hasData():
        let n = outputStream.readData(addr buffer[0], buffer.len)
        if n > 0:
          pulled = true
          stdoutBytes += uint64(n)
          if child.stdoutLimit <= 0 or stdoutText.len < child.stdoutLimit:
            let take =
              if child.stdoutLimit <= 0: n
              else: min(n, child.stdoutLimit - stdoutText.len)
            if take > 0:
              let oldLen = stdoutText.len
              stdoutText.setLen(oldLen + take)
              copyMem(addr stdoutText[oldLen], addr buffer[0], take)
      if not process.running():
        # Windows: process has exited; drain anything still buffered in the
        # pipe before breaking out.
        while outputStream != nil and process.hasData():
          let n = outputStream.readData(addr buffer[0], buffer.len)
          if n <= 0: break
          stdoutBytes += uint64(n)
          if child.stdoutLimit <= 0 or stdoutText.len < child.stdoutLimit:
            let take =
              if child.stdoutLimit <= 0: n
              else: min(n, child.stdoutLimit - stdoutText.len)
            if take > 0:
              let oldLen = stdoutText.len
              stdoutText.setLen(oldLen + take)
              copyMem(addr stdoutText[oldLen], addr buffer[0], take)
        try:
          exitCode = process.peekExitCode()
        except CatchableError:
          exitCode = -1
        break
      let elapsed = int((epochTime() - child.startedSeconds) * 1000.0)
      if timeout >= 0 and elapsed >= timeout:
        timedOut = true
        child.terminate()
        try: discard process.waitForExit(timeout = 0)
        except CatchableError: discard
        break
      if not pulled:
        # Windows: short sleep so we don't burn a core polling.
        sleep(10)
    let elapsedMillis = uint64(max(0, int((epochTime() - child.startedSeconds) * 1000.0)))
    var cpuMicros = 0'u64
    var jobProcessCount = 0'u32
    if child.winJobHandle != 0:
      readJobAccounting(Handle(child.winJobHandle), cpuMicros, jobProcessCount)
    # Windows: prefer the Job Object's TotalProcesses (counts every process the
    # tree ever spawned, even short-lived ones) over the live toolhelp32 count.
    var processCount = max(jobProcessCount, observedProcessCount)
    if processCount == 0 and not timedOut:
      processCount = 1
    child.runningFlag = false
    result = ProcessCompletion(
      processId: uint64(child.pid),
      processGroupId: uint64(child.processGroupId),
      exitCode: exitCode,
      signal: 0,
      exited: exitCode >= 0 and not timedOut,
      signaled: false,
      cancelled: child.cancelSent,
      timedOut: timedOut,
      stdout: stdoutText,
      stderr: "",
      stdoutBytes: stdoutBytes,
      stderrBytes: 0'u64,
      elapsedMillis: elapsedMillis,
      peakResidentMemoryBytes: peakResidentBytes,
      processCount: processCount,
      telemetrySource: telemetrySource
    )
    child.completion = result
  else:
    raise newException(OSError, "runquota_process is only implemented on POSIX")

proc waitForExit*(child: var LaunchedProcess; timeout = -1): int =
  let completion = child.waitForCompletion(timeout)
  if completion.exited:
    completion.exitCode
  elif completion.signaled:
    128 + completion.signal
  else:
    -1

proc cancelAndWait*(child: var LaunchedProcess; timeout = 3000): ProcessCompletion =
  child.terminate()
  child.waitForCompletion(timeout)

proc close*(child: var LaunchedProcess) =
  when defined(posix):
    closeFd(child.stdoutFd)
    closeFd(child.stderrFd)
  elif defined(windows):
    # Windows: release osproc resources and let the Job Object close. With
    # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE set, closing the last handle reaps
    # any straggler processes in the tree.
    if not child.winProcessPtr.isNil:
      let process = cast[Process](child.winProcessPtr)
      try: process.close() except CatchableError: discard
      child.winProcessPtr = nil
    if child.winJobHandle != 0:
      discard closeHandle(Handle(child.winJobHandle))
      child.winJobHandle = 0
