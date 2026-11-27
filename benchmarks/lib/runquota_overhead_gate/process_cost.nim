## What one run costs: wall time, and the CPU time of everything it ran.
##
## CPU TIME IS COUNTED WHERE IT IS SPENT. A measurement's cost can land in
## three places: the build tool's own process, the processes it launched,
## and `runquotad`. The first two are the run's child and the children that
## child waited for, which the kernel totals for us in the `rusage` that
## `wait4(2)` returns. The daemon is not a child of the run (it serves every
## run), so its CPU -- its own and that of the children it has reaped, such
## as the `sqlite3` processes its observation store runs -- is read before
## the run and, once the daemon has gone quiet, after it (the gate's
## `settledDaemonCpuSeconds`), from the kernel's per-process counters, and
## the difference is added. A measurement whose
## cost lands in the daemon (the observation store's writer) would be
## invisible to the run's own rusage; this is what keeps it visible.
##
## Linux reads `/proc/<pid>/stat` (utime + stime + cutime + cstime, in clock
## ticks:
## https://man7.org/linux/man-pages/man5/proc_pid_stat.5.html). macOS reads
## `proc_pid_rusage(2)` (`RUSAGE_INFO_V1`: own and child user and system
## time, in Mach absolute time units, scaled by `mach_timebase_info`). Both
## paths have been run: the daemon's counter is non-zero and grows with its work.
##
## WINDOWS has no `wait4`-style aggregation of a reaped child's own
## descendants: `GetProcessTimes` answers only for the one process named.
## `spawnChild`/`runMeasured` therefore place the child in its own Job
## Object (CPU accounting only here -- no limits, no watcher; this module
## is a measurement instrument and must not itself be the thing a gate run
## measures), the same mechanism `runquota_process`'s Windows launcher uses
## for production leases, and read `TotalUserTime`/`TotalKernelTime` from
## it (`JobObjectBasicAndIoAccountingInformation`), which already sums
## every process the job ever held. Deliberately NOT a dependency on
## `runquota_process` itself: duplicated here, minimal, exactly as the
## POSIX arm above duplicates `fork`+`execve` rather than reusing it.

import std/[monotimes, os, strutils, times]

when defined(posix):
  import std/posix

  proc wait4(pid: Pid; status: var cint; options: cint;
             usage: ptr Rusage): Pid {.importc, header: "<sys/wait.h>".}

when defined(windows):
  import std/winlean

  type
    JobBasicLimitW {.final, pure.} = object
      PerProcessUserTimeLimit: int64
      PerJobUserTimeLimit: int64
      LimitFlags: int32
      MinimumWorkingSetSize: uint
      MaximumWorkingSetSize: uint
      ActiveProcessLimit: int32
      Affinity: uint
      PriorityClass: int32
      SchedulingClass: int32

    IoCountersW {.final, pure.} = object
      ReadOperationCount, WriteOperationCount, OtherOperationCount: uint64
      ReadTransferCount, WriteTransferCount, OtherTransferCount: uint64

    JobBasicAccountingW {.final, pure.} = object
      TotalUserTime, TotalKernelTime: int64
      ThisPeriodTotalUserTime, ThisPeriodTotalKernelTime: int64
      TotalPageFaultCount, TotalProcesses, ActiveProcesses,
        TotalTerminatedProcesses: int32

    JobBasicAndIoAccountingW {.final, pure.} = object
      BasicInfo: JobBasicAccountingW
      IoInfo: IoCountersW

    JobExtendedLimitW {.final, pure.} = object
      ## `JOBOBJECT_EXTENDED_LIMIT_INFORMATION`: the basic limits PLUS the
      ## fields `SetInformationJobObject`/`QueryInformationJobObject`
      ## require for info class 9 -- `JobBasicLimitW` alone is undersized
      ## for that class (it is only `JOBOBJECT_BASIC_LIMIT_INFORMATION`,
      ## class 2's shape); passing it with class 9's `sizeof` would ask the
      ## kernel to fill in fields this struct does not have room for.
      BasicLimitInformation: JobBasicLimitW
      IoInfo: IoCountersW
      ProcessMemoryLimit: uint
      JobMemoryLimit: uint
      PeakProcessMemoryUsed: uint
      PeakJobMemoryUsed: uint

    StartupInfoExW {.final, pure.} = object
      StartupInfo: STARTUPINFO
      lpAttributeList: pointer

  const
    JobObjectExtendedLimitInformationClass = 9'i32
    JobObjectBasicAndIoAccountingInformation = 8'i32
    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000'i32
    PROC_THREAD_ATTRIBUTE_JOB_LIST = 0x0002000D'u
    EXTENDED_STARTUPINFO_PRESENT = 0x00080000'i32

  proc createJobObjectW(a: pointer; n: WideCString): Handle {.
    stdcall, dynlib: "kernel32.dll", importc: "CreateJobObjectW".}
  proc setInformationJobObject(h: Handle; cls: int32; info: pointer;
    sz: int32): WINBOOL {.stdcall, dynlib: "kernel32.dll",
    importc: "SetInformationJobObject".}
  proc queryInformationJobObject(h: Handle; cls: int32; info: pointer;
    sz: int32; ret: ptr int32): WINBOOL {.stdcall, dynlib: "kernel32.dll",
    importc: "QueryInformationJobObject".}
  proc initializeProcThreadAttributeList(lpAttributeList: pointer;
    dwAttributeCount, dwFlags: int32; lpSize: ptr csize_t): WINBOOL {.
    stdcall, dynlib: "kernel32.dll",
    importc: "InitializeProcThreadAttributeList".}
  proc updateProcThreadAttribute(lpAttributeList: pointer; dwFlags: int32;
    attribute: uint; lpValue: pointer; cbSize: csize_t;
    lpPreviousValue: pointer; lpReturnSize: ptr csize_t): WINBOOL {.
    stdcall, dynlib: "kernel32.dll", importc: "UpdateProcThreadAttribute".}
  proc deleteProcThreadAttributeList(lpAttributeList: pointer) {.
    stdcall, dynlib: "kernel32.dll",
    importc: "DeleteProcThreadAttributeList".}
  proc createProcessExW(lpApplicationName, lpCommandLine: WideCString;
    lpProcessAttributes, lpThreadAttributes: pointer;
    bInheritHandles: WINBOOL; dwCreationFlags: int32;
    lpEnvironment: WideCString; lpCurrentDirectory: WideCString;
    lpStartupInfo: pointer; lpProcessInformation: var PROCESS_INFORMATION):
    WINBOOL {.stdcall, dynlib: "kernel32.dll", importc: "CreateProcessW".}
  proc getProcessTimes(hProcess: Handle; lpCreationTime, lpExitTime,
    lpKernelTime, lpUserTime: ptr FILETIME): WINBOOL {.
    stdcall, dynlib: "kernel32.dll", importc: "GetProcessTimes".}

  proc fileTimeToSeconds(t: FILETIME): float =
    ## FILETIME is 100ns ticks, split into two 32-bit words -- but
    ## `std/winlean.DWORD` is `int32`, not `uint32`, so a plain `uint64(x)`
    ## on either word SIGN-EXTENDS once its top bit is set (observed:
    ## `dwLowDateTime` alone passes 2^31 ticks, 214.7 s of accumulated CPU,
    ## well within one gate run against a long-lived daemon), corrupting
    ## the result to within a few seconds of `uint64.high / 1e7` (~58.5
    ## years). `cast[uint32]` reinterprets the bits first, the way
    ## `std/winlean`'s own internal FILETIME-to-`int64` helper does it.
    let ticks = (uint64(cast[uint32](t.dwHighDateTime)) shl 32) or
      uint64(cast[uint32](t.dwLowDateTime))
    float(ticks) / 1e7

  proc winOpenNulForRead(): Handle =
    var sa: SECURITY_ATTRIBUTES
    sa.nLength = int32(sizeof(SECURITY_ATTRIBUTES))
    sa.bInheritHandle = 1
    const
      GenericRead = cast[int32](0x80000000'u32)
      FileShareReadWrite = 0x00000003'i32
      OpenExisting = 3'i32
      FileAttributeNormal = 0x00000080'i32
    result = createFileW(newWideCString("NUL"), GenericRead,
      FileShareReadWrite, addr sa, OpenExisting, FileAttributeNormal, 0)
    if result == INVALID_HANDLE_VALUE:
      raiseOSError(osLastError(), "CreateFileW(NUL)")

  proc winOpenLogForWrite(logPath: string): Handle =
    var sa: SECURITY_ATTRIBUTES
    sa.nLength = int32(sizeof(SECURITY_ATTRIBUTES))
    sa.bInheritHandle = 1
    const
      GenericWrite = cast[int32](0x40000000'u32)
      FileShareRead = 0x00000001'i32
      CreateAlways = 2'i32
      FileAttributeNormal = 0x00000080'i32
    result = createFileW(newWideCString(logPath), GenericWrite,
      FileShareRead, addr sa, CreateAlways, FileAttributeNormal, 0)
    if result == INVALID_HANDLE_VALUE:
      raiseOSError(osLastError(), "CreateFileW(" & logPath & ")")

  proc buildWinCommandLine(argv: openArray[string]): string =
    result = quoteShell(argv[0])
    for i in 1 ..< argv.len:
      result.add(' ')
      result.add(quoteShell(argv[i]))

  proc buildWinEnvBlock(env: openArray[string]): tuple[data: cstring; len: int] =
    ## The double-NUL-terminated block `CreateProcessW` expects.
    ## `newWideCString(data, len)` (called on the result) appends its own
    ## terminating wide NUL after `len` content bytes; with at least one
    ## entry, that entry's own embedded `\0` (already inside `len`) supplies
    ## the OTHER half of the required double-NUL. With ZERO entries there is
    ## no such embedded `\0` to borrow, so `len` must still be at least 1 --
    ## one zeroed content byte, making the terminator newWideCString appends
    ## the second null -- or `CreateProcessW` sees a single-NUL block (an
    ## unterminated empty environment) and refuses with
    ## ERROR_INVALID_PARAMETER. `env = @[]` (an isolated launch with no
    ## inherited and no declared variables) is this exact case.
    var total = 0
    for entry in env:
      total += entry.len + 1
    var buf = cast[cstring](alloc0(max(total, 1)))
    var pos = 0
    for entry in env:
      copyMem(addr buf[pos], cstring(entry), entry.len + 1)
      pos += entry.len + 1
    (buf, max(total, 1))

when defined(windows):
  type Pid* = int32
    ## Windows has no `pid_t`; this module's own stand-in, the same width
    ## `GetProcessId` returns. Exported so a caller ported alongside this
    ## module can use one `Pid` name on every platform instead of reaching
    ## into `std/posix` (which, imported on Windows, defines none).

type
  RunCost* = object
    exitStatus*: int     ## exit code, or -signal when killed by a signal
    wallSeconds*: float
    cpuSeconds*: float   ## user + system of the child and what it waited for
    daemonCpuSeconds*: float
      ## The part of `cpuSeconds` that a case attributed to a daemon serving
      ## the run, reported separately so a cost can be located; 0 where the
      ## case has no daemon.

when defined(posix):
  proc timevalSeconds(tv: Timeval): float =
    float(tv.tv_sec) + float(tv.tv_usec) / 1_000_000.0

  proc spawnChild*(argv: openArray[string]; env: openArray[string];
                   cwd, logPath: string): Pid =
    ## fork + execve with stdout and stderr written to `logPath` (truncated:
    ## it holds the latest run, which is the one a failure report quotes) and
    ## stdin from /dev/null. Everything the child touches is composed before the
    ## fork, so the child only calls async-signal-safe functions.
    if argv.len == 0:
      raise newException(ValueError, "spawnChild: empty argv")
    let cargv = allocCStringArray(argv)
    let cenv = allocCStringArray(env)
    let cpath = argv[0].cstring
    let ccwd = cwd.cstring
    let clog = logPath.cstring
    let devNull = "/dev/null".cstring
    let pid = fork()
    if pid < 0:
      deallocCStringArray(cargv)
      deallocCStringArray(cenv)
      raiseOSError(osLastError(), "fork")
    if pid == 0:
      if ccwd.len > 0 and chdir(ccwd) != 0:
        exitnow(126)
      let logFd = posix.open(clog, O_WRONLY or O_CREAT or O_TRUNC, 0o644)
      let nullFd = posix.open(devNull, O_RDONLY)
      if logFd < 0 or nullFd < 0:
        exitnow(126)
      discard dup2(nullFd, 0)
      discard dup2(logFd, 1)
      discard dup2(logFd, 2)
      discard execve(cpath, cargv, cenv)
      exitnow(127)
    deallocCStringArray(cargv)
    deallocCStringArray(cenv)
    pid

  proc runMeasured*(argv: openArray[string]; env: openArray[string];
                    cwd, logPath: string): RunCost =
    ## Run `argv` to completion and return its exit status, wall time and CPU
    ## time (module header).
    let started = getMonoTime()
    let pid = spawnChild(argv, env, cwd, logPath)
    var status: cint = 0
    var usage: Rusage
    while true:
      let waited = wait4(pid, status, 0, addr usage)
      if waited == pid:
        break
      if waited < 0 and errno != EINTR:
        raiseOSError(osLastError(), "wait4")
    let finished = getMonoTime()
    result.wallSeconds = float((finished - started).inNanoseconds) / 1e9
    result.cpuSeconds = timevalSeconds(usage.ru_utime) +
      timevalSeconds(usage.ru_stime)
    if WIFEXITED(status):
      result.exitStatus = int(WEXITSTATUS(status))
    elif WIFSIGNALED(status):
      result.exitStatus = -int(WTERMSIG(status))
    else:
      result.exitStatus = -1

  proc daemonTerminate*(pid: Pid) =
    discard kill(pid, SIGTERM)

  proc daemonKillNow*(pid: Pid) =
    discard kill(pid, SIGKILL)

  proc daemonTryReap*(pid: Pid): bool =
    var status: cint
    waitpid(pid, status, WNOHANG) == pid

  proc daemonReapBlocking*(pid: Pid) =
    var status: cint
    discard waitpid(pid, status, 0)

elif defined(windows):
  proc spawnChildInJob*(argv: openArray[string]; env: openArray[string];
                        cwd, logPath: string; killOnClose = true):
      tuple[pid: Pid; processHandle: Handle; job: Handle] =
    ## `CreateProcessW`, placed in a fresh Job Object at creation
    ## (`PROC_THREAD_ATTRIBUTE_JOB_LIST`, the same mechanism
    ## `runquota_process`'s launcher uses for production leases) so
    ## `runMeasured` can read the WHOLE tree's CPU, not only this one
    ## process's -- Windows has no `wait4`-style aggregation of a reaped
    ## child's own descendants. stdout and stderr go to `logPath`
    ## (truncated), stdin from `NUL`.
    ##
    ## `killOnClose` (default true, `runMeasured`'s short-lived children):
    ## `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, so a crash of THIS process
    ## before the run finishes still reaps whatever it started. `false`
    ## (`spawnChild`'s long-lived daemon): the job is created for CPU
    ## accounting alone, with no limit flags at all -- `spawnChild` closes
    ## the job handle right after spawning, on purpose, because the
    ## daemon must outlive that call; a job the caller means to outlive
    ## must not carry kill-on-close, or dropping the only handle to it
    ## (the very next statement there) kills the daemon it was meant to
    ## leave running.
    if argv.len == 0:
      raise newException(ValueError, "spawnChildInJob: empty argv")
    let cmdLine = buildWinCommandLine(argv)
    let envBlock = buildWinEnvBlock(env)
    let workDir = if cwd.len > 0: cwd else: getCurrentDir()
    var si: STARTUPINFO
    si.cb = int32(sizeof(STARTUPINFO))
    si.dwFlags = STARTF_USESTDHANDLES
    si.hStdInput = winOpenNulForRead()
    si.hStdOutput = winOpenLogForWrite(logPath)
    si.hStdError = si.hStdOutput
    let job = createJobObjectW(nil, nil)
    if job != 0 and killOnClose:
      var info: JobExtendedLimitW
      info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
      discard setInformationJobObject(job, JobObjectExtendedLimitInformationClass,
        addr info, int32(sizeof(info)))
    var procInfo: PROCESS_INFORMATION
    var ok = false
    if job != 0:
      var attrListSize: csize_t = 0
      discard initializeProcThreadAttributeList(nil, 1, 0, addr attrListSize)
      if attrListSize > 0:
        let attrListBuf = alloc(int(attrListSize))
        if initializeProcThreadAttributeList(attrListBuf, 1, 0,
            addr attrListSize) != 0:
          var jobList = [job]
          if updateProcThreadAttribute(attrListBuf, 0,
              PROC_THREAD_ATTRIBUTE_JOB_LIST, addr jobList[0],
              csize_t(sizeof(Handle)), nil, nil) != 0:
            var siEx: StartupInfoExW
            siEx.StartupInfo = si
            siEx.StartupInfo.cb = int32(sizeof(StartupInfoExW))
            siEx.lpAttributeList = attrListBuf
            let flags = NORMAL_PRIORITY_CLASS or CREATE_UNICODE_ENVIRONMENT or
              EXTENDED_STARTUPINFO_PRESENT
            ok = createProcessExW(nil, newWideCString(cmdLine), nil, nil, 1,
              flags, newWideCString(envBlock.data, envBlock.len),
              newWideCString(workDir), addr siEx, procInfo) != 0
        deleteProcThreadAttributeList(attrListBuf)
        dealloc(attrListBuf)
    if not ok:
      if job != 0:
        discard closeHandle(job)
      let flags = NORMAL_PRIORITY_CLASS or CREATE_UNICODE_ENVIRONMENT
      ok = createProcessExW(nil, newWideCString(cmdLine), nil, nil, 1, flags,
        newWideCString(envBlock.data, envBlock.len), newWideCString(workDir),
        addr si, procInfo) != 0
      if not ok:
        let err = osLastError()
        discard closeHandle(si.hStdInput)
        discard closeHandle(si.hStdOutput)
        dealloc(envBlock.data)
        raiseOSError(err, "CreateProcessW")
      result.job = 0
    else:
      result.job = job
    discard closeHandle(si.hStdInput)
    discard closeHandle(si.hStdOutput)
    dealloc(envBlock.data)
    discard closeHandle(procInfo.hThread)
    result.pid = Pid(procInfo.dwProcessId)
    result.processHandle = procInfo.hProcess

  proc runMeasured*(argv: openArray[string]; env: openArray[string];
                    cwd, logPath: string): RunCost =
    ## Run `argv` to completion and return its exit status, wall time and
    ## CPU time (module header): the job's `TotalUserTime` +
    ## `TotalKernelTime` when the job was created, the leader process's own
    ## `GetProcessTimes` otherwise (the limitless-job fallback above).
    let started = getMonoTime()
    let spawned = spawnChildInJob(argv, env, cwd, logPath)
    discard waitForSingleObject(spawned.processHandle, INFINITE)
    let finished = getMonoTime()
    var exitCode: int32 = 0
    discard getExitCodeProcess(spawned.processHandle, exitCode)
    result.exitStatus = int(exitCode)
    result.wallSeconds = float((finished - started).inNanoseconds) / 1e9
    if spawned.job != 0:
      var info: JobBasicAndIoAccountingW
      var ret: int32 = 0
      if queryInformationJobObject(spawned.job,
          JobObjectBasicAndIoAccountingInformation, addr info,
          int32(sizeof(info)), addr ret) != 0:
        result.cpuSeconds = float(info.BasicInfo.TotalUserTime +
          info.BasicInfo.TotalKernelTime) / 1e7
      discard closeHandle(spawned.job)
    else:
      var creation, exit, kernel, user: FILETIME
      if getProcessTimes(spawned.processHandle, addr creation, addr exit,
          addr kernel, addr user) != 0:
        result.cpuSeconds = fileTimeToSeconds(kernel) + fileTimeToSeconds(user)
    discard closeHandle(spawned.processHandle)

  proc runMeasuredFanOut*(argvs: openArray[seq[string]];
                          env: openArray[string]; cwd, logDir: string):
      RunCost =
    ## Like `runMeasured`, but every argv is STARTED CONCURRENTLY, with no
    ## wait between them, and joined together once all are running --
    ## `run64Case`'s Windows driver, the closest equivalent of the shell
    ## `CMD & ...; wait` fan-out `run64Script` uses on POSIX, without
    ## depending on a POSIX shell being on PATH. Each argv's own log goes to
    ## `logDir / "fan-<i>.log"`. `result.exitStatus` is the COUNT of argvs
    ## that exited non-zero (0 means every one succeeded) -- unlike every
    ## other `RunCost` in this module, it is not one process's own exit
    ## code, because there isn't a single one; `result.cpuSeconds` sums
    ## every argv's own job accounting. `WaitForMultipleObjects`'s hard
    ## limit (`MAXIMUM_WAIT_OBJECTS`, 64) bounds `argvs.len`.
    if argvs.len == 0:
      return
    if argvs.len > MAXIMUM_WAIT_OBJECTS:
      raise newException(ValueError, "runMeasuredFanOut: " & $argvs.len &
        " argvs exceeds WaitForMultipleObjects's limit of " &
        $MAXIMUM_WAIT_OBJECTS)
    let started = getMonoTime()
    var spawned: seq[tuple[pid: Pid; processHandle: Handle; job: Handle]]
    for i, argv in argvs:
      spawned.add spawnChildInJob(argv, env, cwd,
        logDir / ("fan-" & $i & ".log"))
    var handles: WOHandleArray
    for i, s in spawned: handles[i] = s.processHandle
    discard waitForMultipleObjects(DWORD(spawned.len), addr handles, 1,
      INFINITE)
    let finished = getMonoTime()
    result.wallSeconds = float((finished - started).inNanoseconds) / 1e9
    for s in spawned:
      var exitCode: int32 = 0
      discard getExitCodeProcess(s.processHandle, exitCode)
      if exitCode != 0:
        inc result.exitStatus
      if s.job != 0:
        var info: JobBasicAndIoAccountingW
        var ret: int32 = 0
        if queryInformationJobObject(s.job,
            JobObjectBasicAndIoAccountingInformation, addr info,
            int32(sizeof(info)), addr ret) != 0:
          result.cpuSeconds += float(info.BasicInfo.TotalUserTime +
            info.BasicInfo.TotalKernelTime) / 1e7
        discard closeHandle(s.job)
      discard closeHandle(s.processHandle)

  # -------------------------------------------------------------------
  # The gate's own long-lived daemon, by pid alone (module header: a
  # daemon's CPU is read separately from `runMeasured`'s workloads, by
  # `processCpuSeconds`). These four give the gate's daemon-lifecycle code
  # (`stopDaemon`, `startDaemon`) one small cross-platform surface instead
  # of POSIX's kill/waitpid directly: a plain handle re-opened by pid each
  # time is simpler than keeping the creation-time handle alive for a
  # process whose whole point is to outlive this call.
  # -------------------------------------------------------------------

  proc spawnChild*(argv: openArray[string]; env: openArray[string];
                   cwd, logPath: string): Pid =
    ## Like `spawnChildInJob`, but for a long-lived process (the gate's own
    ## daemon) this module never waits on directly: the job and process
    ## handle are closed immediately, so only the pid survives. The
    ## daemon's own CPU is read by `processCpuSeconds`, not through this
    ## job -- a subprocess IT spawns (the observation store's `sqlite3`)
    ## would need a job kept alive to be counted, which this does not do;
    ## the module header's "cutime/cstime" aggregation that covers this on
    ## POSIX has no Windows equivalent here. `killOnClose = false`: this
    ## proc closes the job handle on the very next line, and the daemon
    ## must survive that (module doc on `spawnChildInJob`'s `killOnClose`).
    let spawned = spawnChildInJob(argv, env, cwd, logPath, killOnClose = false)
    if spawned.job != 0:
      discard closeHandle(spawned.job)
    discard closeHandle(spawned.processHandle)
    spawned.pid

  proc daemonTerminate*(pid: Pid) =
    ## The gate's first attempt to end its own daemon. Windows has no
    ## SIGTERM-equivalent soft signal; `TerminateProcess` is unconditional
    ## there, so this and `daemonKillNow` below do the same thing on
    ## Windows and differ only on POSIX (SIGTERM vs SIGKILL).
    const ProcessTerminate = 0x0001'i32
    let h = openProcess(ProcessTerminate, 0'i32, int32(pid))
    if h != 0:
      discard terminateProcess(h, 1)
      discard closeHandle(h)

  proc daemonKillNow*(pid: Pid) =
    daemonTerminate(pid)

  proc daemonTryReap*(pid: Pid): bool =
    ## Non-blocking: true once the process has exited. Unlike POSIX's
    ## `waitpid(WNOHANG)`, this consumes nothing -- Windows has no zombie
    ## to reap -- so calling it repeatedly is exactly as cheap as POSIX's
    ## own poll loop already assumes.
    const ProcessQueryLimitedInformation = 0x1000'i32
    let h = openProcess(ProcessQueryLimitedInformation, 0'i32, int32(pid))
    if h == 0:
      return true # cannot even open it: treat as already gone
    var code: int32 = 0
    let ok = getExitCodeProcess(h, code)
    discard closeHandle(h)
    ok != 0 and code != STILL_ACTIVE

  proc daemonReapBlocking*(pid: Pid) =
    const Synchronize = 0x00100000'i32
    let h = openProcess(Synchronize, 0'i32, int32(pid))
    if h != 0:
      discard waitForSingleObject(h, INFINITE)
      discard closeHandle(h)

when defined(linux):
  proc processCpuSeconds*(pid: Pid): float =
    ## utime + stime of a live process and of the children it has reaped
    ## (cutime + cstime), from `/proc/<pid>/stat`. Fields are
    ## counted after the parenthesised command name, which may itself hold
    ## spaces or parentheses, so parsing starts at the LAST ')'.
    let text = readFile("/proc/" & $pid & "/stat")
    let close = text.rfind(')')
    if close < 0:
      raise newException(ValueError, "unparsable /proc/" & $pid & "/stat")
    let fields = text[close + 2 .. ^1].splitWhitespace()
    # fields[0] is field 3 (state); utime is field 14, stime 15, and the
    # CPU of the children it has waited for, cutime 16 and cstime 17. The
    # children count: `runquotad`'s observation store runs `sqlite3` as a
    # child process, and its CPU is the store's cost.
    var ticks = 0'i64
    for index in 11 .. 14:
      ticks += parseBiggestInt(fields[index])
    float(ticks) / float(sysconf(SC_CLK_TCK))
elif defined(macosx):
  type
    RusageInfoV1 {.importc: "struct rusage_info_v1",
                   header: "<libproc.h>".} = object
      ri_user_time: uint64
      ri_system_time: uint64
      ri_child_user_time: uint64
      ri_child_system_time: uint64
    MachTimebaseInfo {.importc: "mach_timebase_info_data_t",
                       header: "<mach/mach_time.h>".} = object
      numer: uint32
      denom: uint32

  proc proc_pid_rusage(pid: cint; flavor: cint; buffer: pointer): cint {.
    importc, header: "<libproc.h>".}
  proc mach_timebase_info(info: var MachTimebaseInfo): cint {.
    importc, header: "<mach/mach_time.h>".}

  proc processCpuSeconds*(pid: Pid): float =
    ## The process's own and its reaped children's user + system time
    ## (`RUSAGE_INFO_V1`, Mach absolute time units).
    var info: RusageInfoV1
    if proc_pid_rusage(cint(pid), 1, addr info) != 0:
      raiseOSError(osLastError(), "proc_pid_rusage")
    var base: MachTimebaseInfo
    discard mach_timebase_info(base)
    let units = float(info.ri_user_time + info.ri_system_time +
      info.ri_child_user_time + info.ri_child_system_time)
    units * float(base.numer) / float(base.denom) / 1e9
elif defined(windows):
  proc processCpuSeconds*(pid: Pid): float =
    ## `GetProcessTimes` on a handle opened by pid: this process's OWN user
    ## + kernel time. Unlike `wait4`'s rusage, Windows gives no built-in way
    ## to add a reaped child's time to its parent's total -- there is none
    ## to add here anyway, since this overload is only ever called with the
    ## daemon's own pid, a process this module never waits for.
    const ProcessQueryInformation = 0x0400'i32
    let handle = openProcess(ProcessQueryInformation, 0'i32, int32(pid))
    if handle == 0:
      raiseOSError(osLastError(), "OpenProcess")
    var creation, exit, kernel, user: FILETIME
    let ok = getProcessTimes(handle, addr creation, addr exit, addr kernel,
      addr user)
    discard closeHandle(handle)
    if ok == 0:
      raiseOSError(osLastError(), "GetProcessTimes")
    fileTimeToSeconds(kernel) + fileTimeToSeconds(user)
else:
  proc processCpuSeconds*(pid: Pid): float =
    raise newException(OSError,
      "per-process CPU time is not implemented on this platform")

when not defined(linux) and not defined(windows):
  proc getloadavg(loadavg: ptr cdouble; nelem: cint): cint {.
    importc, header: "<stdlib.h>".}

proc loadAverage*(): string =
  ## The 1/5/15-minute load averages, as the kernel reports them, for the
  ## report. Empty where there is no `/proc/loadavg`, and on Windows, which
  ## has no equivalent concept.
  when defined(linux):
    try:
      let parts = readFile("/proc/loadavg").splitWhitespace()
      return parts[0] & " " & parts[1] & " " & parts[2]
    except CatchableError:
      return ""
  elif defined(windows):
    ""
  else:
    var loads: array[3, cdouble]
    if getloadavg(addr loads[0], 3) == 3:
      return formatFloat(loads[0], ffDecimal, 2) & " " &
        formatFloat(loads[1], ffDecimal, 2) & " " &
        formatFloat(loads[2], ffDecimal, 2)
    ""

proc cpuPressureSomeAvg10*(): string =
  ## Linux CPU pressure (`/proc/pressure/cpu`, "some avg10"): the share of
  ## the last ten seconds in which at least one runnable task waited for a
  ## CPU. Empty where PSI is unavailable.
  ## https://docs.kernel.org/accounting/psi.html
  when defined(linux):
    try:
      for line in readFile("/proc/pressure/cpu").splitLines():
        if line.startsWith("some "):
          for field in line.splitWhitespace():
            if field.startsWith("avg10="):
              return field[len("avg10=") .. ^1]
    except CatchableError:
      discard
  ""

proc unixNow*(): string =
  $getTime().toUnix()
