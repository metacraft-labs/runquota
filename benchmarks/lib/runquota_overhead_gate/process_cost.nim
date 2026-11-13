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
## time, in Mach absolute time units, scaled by `mach_timebase_info`). The macOS path has not been
## run yet; the Linux one has.

import std/[monotimes, os, posix, strutils, times]

proc wait4(pid: Pid; status: var cint; options: cint;
           usage: ptr Rusage): Pid {.importc, header: "<sys/wait.h>".}

type
  RunCost* = object
    exitStatus*: int     ## exit code, or -signal when killed by a signal
    wallSeconds*: float
    cpuSeconds*: float   ## user + system of the child and what it waited for
    daemonCpuSeconds*: float
      ## The part of `cpuSeconds` that a case attributed to a daemon serving
      ## the run, reported separately so a cost can be located; 0 where the
      ## case has no daemon.

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
else:
  proc processCpuSeconds*(pid: Pid): float =
    raise newException(OSError,
      "per-process CPU time is not implemented on this platform")

when not defined(linux):
  proc getloadavg(loadavg: ptr cdouble; nelem: cint): cint {.
    importc, header: "<stdlib.h>".}

proc loadAverage*(): string =
  ## The 1/5/15-minute load averages, as the kernel reports them, for the
  ## report. Empty where there is no `/proc/loadavg`.
  when defined(linux):
    try:
      let parts = readFile("/proc/loadavg").splitWhitespace()
      return parts[0] & " " & parts[1] & " " & parts[2]
    except CatchableError:
      return ""
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
