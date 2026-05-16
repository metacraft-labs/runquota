import std/[envvars, os, strutils, times]

when defined(posix):
  import std/posix

import runquota_core
import runquota_host_macos
import runquota_process/types as processTypes

export processTypes

const libraryName* = "runquota_process"
const DefaultOutputLimit* = 1_048_576

when defined(posix):
  proc childExit(status: cint) {.importc: "_exit", header: "<unistd.h>", noreturn.}

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
      info: LaunchResult(
        processId: uint64(pid),
        processGroupId: uint64(max(pgid, 0)),
        running: true,
        backend: backendProfile()
      )
    )
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
    var status: cint
    waitpid(Pid(child.pid), status, WNOHANG) == 0
  else:
    false

proc terminate*(child: var LaunchedProcess) =
  when defined(posix):
    child.cancelSent = true
    if child.processGroupId > 0:
      discard kill(Pid(-child.processGroupId), SIGTERM)
    elif child.pid > 0:
      discard kill(Pid(child.pid), SIGTERM)

proc killNow*(child: var LaunchedProcess) =
  when defined(posix):
    child.cancelSent = true
    if child.processGroupId > 0:
      discard kill(Pid(-child.processGroupId), SIGKILL)
    elif child.pid > 0:
      discard kill(Pid(child.pid), SIGKILL)

proc waitForCompletion*(child: var LaunchedProcess; timeout = -1): ProcessCompletion =
  when defined(posix):
    var status: cint = 0
    var done = false
    var timedOut = false
    var stdoutText = ""
    var stderrText = ""
    var stdoutBytes = 0'u64
    var stderrBytes = 0'u64
    var peakResidentMemoryBytes = 0'u64
    var processCount = 0'u32
    var telemetrySource = backendProfile().telemetry

    while true:
      child.stdoutFd.drainFd(stdoutText, stdoutBytes, child.stdoutLimit)
      child.stderrFd.drainFd(stderrText, stderrBytes, child.stderrLimit)

      if not done:
        let sample = sampleMacosProcessTreeTelemetry(uint64(child.pid))
        telemetrySource = sample.source
        if sample.diagnostic.code == diagOk:
          if sample.residentMemoryBytes > peakResidentMemoryBytes:
            peakResidentMemoryBytes = sample.residentMemoryBytes
          if sample.processCount > processCount:
            processCount = sample.processCount
        let waited = waitpid(Pid(child.pid), status, WNOHANG)
        if waited == Pid(child.pid):
          done = true
          child.runningFlag = false
        elif waited < 0:
          done = true
          child.runningFlag = false

      if done and child.stdoutFd < 0 and child.stderrFd < 0:
        break

      let elapsed = int((epochTime() - child.startedSeconds) * 1000.0)
      if timeout >= 0 and elapsed >= timeout:
        timedOut = true
        child.terminate()
        let killDeadline = epochTime() + 1.0
        while epochTime() < killDeadline:
          child.stdoutFd.drainFd(stdoutText, stdoutBytes, child.stdoutLimit)
          child.stderrFd.drainFd(stderrText, stderrBytes, child.stderrLimit)
          let waited = waitpid(Pid(child.pid), status, WNOHANG)
          if waited == Pid(child.pid):
            done = true
            child.runningFlag = false
            break
          sleep(10)
        if not done:
          child.killNow()
          discard waitpid(Pid(child.pid), status, 0)
          child.runningFlag = false
        child.stdoutFd.drainFd(stdoutText, stdoutBytes, child.stdoutLimit)
        child.stderrFd.drainFd(stderrText, stderrBytes, child.stderrLimit)
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

    let elapsedMillis = uint64(max(0, int((epochTime() - child.startedSeconds) * 1000.0)))
    result = buildCompletion(
      child,
      status,
      elapsedMillis,
      stdoutText,
      stderrText,
      stdoutBytes,
      stderrBytes,
      timedOut,
      peakResidentMemoryBytes,
      processCount,
      telemetrySource
    )
    if result.processCount == 0 and not result.timedOut:
      result.processCount = 1
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
