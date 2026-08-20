import std/[os, strutils, times]

when defined(posix):
  import std/posix

when defined(windows):
  # Windows: spawn child processes via std/osproc and assign them to a Job
  # Object so the whole tree can be tracked and (optionally) killed atomically.
  # The Job Object also gives us cheap accounting (CPU/IO/process count).
  import std/[osproc, streams, strtabs, tempfiles]
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

  # ---------------------------------------------------------------------------
  # Descriptor hygiene
  # ---------------------------------------------------------------------------
  #
  # Leased commands must not observe runquota's own control descriptors:
  # reproducibility monitors classify reads from inherited pipes/sockets as
  # opaque external content, because the producing endpoint is outside the
  # monitored action tree.
  #
  # The primary mechanism is CLOEXEC at birth (see `runquota_core/fd_hygiene`
  # and the pipe creation in `launchProcess` below): descriptors runquota opens
  # are created close-on-exec, so the kernel drops them at `execve` for free.
  #
  # `closeInheritedChildFds` is only the backstop for descriptors runquota did
  # NOT open -- whatever the process that invoked runquota happened to be
  # holding. It runs between fork and exec, so it may only use
  # async-signal-safe calls: no allocation, no locks, no `opendir`/`readdir`.
  #
  # That restriction is not stylistic. runquota is built `--threads:on`, and
  # `fork()` in a threaded process gives the child a single thread plus a copy
  # of every lock the other threads held at the instant of the fork. A child
  # that then touches the allocator can block forever on a mutex whose owner
  # does not exist in it, never reaching `execve`. For a lease coordinator that
  # is worse than a crash: the lease is never finished, its capacity is never
  # returned, and nothing reports an error. Everything the child needs is
  # therefore built in the parent (see `childEnvEntries` / `resolveProgram`
  # below) and handed over as memory the child only reads.
  #
  # It must never again be bounded by `sysconf(_SC_OPEN_MAX)`. That is the
  # limit on descriptor *numbers*, not a count of open ones; on hosts where it
  # is raised to 1048576 (this is the default `RLIMIT_NOFILE` on several
  # configurations, macOS included) the old numeric loop issued 1048573
  # `close()` calls and ~90ms of syscalls before *every* leased exec. Bounding
  # by `RLIMIT_NOFILE.rlim_cur` instead fixes nothing, because that is the very
  # same number. Enumerating what is actually open -- or handing the whole
  # range to the kernel in one call -- is the only approach whose cost tracks
  # reality, so the numeric scan survives solely as a hard-capped last resort.

  const MaxNumericFdScan = 4096
    ## Hard cap on the last-resort numeric scan. It is reached only when the
    ## host offers neither a range-close primitive nor a way to enumerate the
    ## descriptor table (on Linux: a pre-5.9 kernel with no `/proc` mounted).
    ## A launcher holding descriptors above this number on such a host would
    ## leak them into the child, so enumeration is preferred wherever it is
    ## possible -- the cap exists to bound a scan that cannot be made correct,
    ## not to stand in for one that can.

  when defined(linux) or defined(macosx):
    let O_DIRECTORY_C {.importc: "O_DIRECTORY", header: "<fcntl.h>".}: cint

  when defined(linux):
    # `close_range(2)` (Linux 5.9) closes the whole range in one syscall, but
    # glibc only wraps it from 2.34. Issue the syscall directly so the build
    # does not depend on the libc version.
    const SYS_close_range = clong(436)

    proc rawSyscall(number: clong): clong {.
      importc: "syscall", header: "<sys/syscall.h>", varargs, discardable.}

    proc linuxPipe2(fds: array[0..1, cint]; flags: cint): cint {.
      importc: "pipe2", header: "<unistd.h>".}

    proc closeInheritedRange(): bool =
      ## One syscall for every descriptor from 3 upwards. Fails with ENOSYS on
      ## kernels older than 5.9, in which case the caller falls back.
      rawSyscall(SYS_close_range, cuint(3), cuint(0xFFFF_FFFF'u32), cint(0)) == 0

    # Pre-5.9 kernels need the descriptors enumerated instead, and the numeric
    # scan cannot do that: it is capped, so a launcher holding a descriptor
    # above the cap would leak it into the monitored child silently. Linux
    # publishes the real table as `/proc/self/fd`, so read that with the same
    # discipline the Darwin path uses -- raw directory syscall into a stack
    # buffer, digits parsed by hand, nothing allocated.
    #
    # `getdents64`'s syscall number is architecture-specific (217 on x86-64, 61
    # on aarch64) and glibc only wraps the function from 2.30, so take the
    # number from `<sys/syscall.h>` rather than hard-coding either.
    let SYS_getdents64_C {.importc: "SYS_getdents64",
                           header: "<sys/syscall.h>".}: clong

    type
      LinuxDirent64 {.final, pure.} = object
        ## `struct linux_dirent64` exactly as the kernel writes it. Declared
        ## here rather than imported because glibc only exposes an equivalent
        ## `struct dirent64` under `_LARGEFILE64_SOURCE`.
        inode: uint64
        offset: int64
        recordLen: uint16
        kind: uint8
        name: array[256, char]

    const LinuxDirentNameOffset = 19
      ## Byte offset of `d_name` within the record: 8 + 8 + 2 + 1. The name is
      ## not length-prefixed, so this offset is the only thing bounding the
      ## digit scan below -- get it wrong and the walk reads past the record.

    static:
      # Pinned to the layout the compiler actually produces, on whatever
      # architecture this is being built for, rather than assumed.
      doAssert offsetOf(LinuxDirent64, name) == LinuxDirentNameOffset

    proc closeInheritedByEnumeration(): bool =
      ## Close every descriptor `/proc/self/fd` reports except 0, 1, 2 and the
      ## directory handle used to do the reading. Returns false when `/proc` is
      ## not mounted, so the caller can fall back to the capped numeric scan.
      let dirFd = posix.open(cstring("/proc/self/fd"),
                             O_RDONLY or O_DIRECTORY_C or O_CLOEXEC)
      if dirFd < 0:
        return false
      # Stack buffer: no allocation between fork and exec. One `getdents64`
      # rarely fills it, but a launcher holding hundreds of descriptors needs
      # the loop below to keep asking until the kernel reports 0 -- stopping
      # after the first buffer is exactly the truncation this routine exists to
      # avoid. Entries come back in descriptor order, so closing an
      # already-visited descriptor cannot perturb the walk.
      var buffer {.align: 8.}: array[8192, char]
      while true:
        let readBytes = int(rawSyscall(SYS_getdents64_C, dirFd, addr buffer[0],
                                       cuint(buffer.len)))
        if readBytes <= 0:
          break
        var offset = 0
        while offset < readBytes:
          let entry = cast[ptr LinuxDirent64](addr buffer[offset])
          let recordLen = int(entry.recordLen)
          if recordLen <= LinuxDirentNameOffset or
              offset + recordLen > readBytes:
            # Malformed record: stop rather than spin forever on offset 0.
            offset = readBytes
            break
          # Entry names under `/proc/self/fd` are decimal descriptor numbers.
          # Parse by hand; `parseInt` and friends allocate. Unlike the Darwin
          # dirent there is no name length, so the name is NUL-terminated
          # inside the record: the terminator ends the number, it does not
          # invalidate it.
          var value = 0
          var digits = 0
          var index = 0
          let nameLen = min(recordLen - LinuxDirentNameOffset, entry.name.len)
          while index < nameLen:
            let ch = entry.name[index]
            if ch == '\0':
              break
            if ch < '0' or ch > '9':
              digits = 0
              break
            value = value * 10 + (ord(ch) - ord('0'))
            inc digits
            inc index
          if digits > 0 and value > STDERR_FILENO and cint(value) != dirFd:
            discard close(cint(value))
          offset += recordLen
      discard close(dirFd)
      true

  elif defined(macosx):
    # Darwin has neither `close_range` nor `closefrom`, so the open descriptors
    # have to be enumerated from `/dev/fd`. `opendir`/`readdir` are not an
    # option here: they allocate, and this code runs between fork and exec.
    # `__getdirentries64` is libSystem's raw directory-read stub -- one syscall,
    # no allocation, no locking -- reading into a caller-supplied buffer, which
    # for us is the forked child's stack.
    proc getdirentries64(fd: cint; buf: pointer; bufSize: csize_t;
                         basep: ptr Off): int {.importc: "__getdirentries64".}

    type
      DarwinDirent {.importc: "struct dirent", header: "<dirent.h>",
                     final, pure.} = object
        d_reclen {.importc: "d_reclen".}: uint16
        d_namlen {.importc: "d_namlen".}: uint16
        d_name {.importc: "d_name".}: array[1024, char]

    proc closeInheritedByEnumeration(): bool =
      ## Close every descriptor `/dev/fd` reports except 0, 1, 2 and the
      ## directory handle used to do the reading. Returns false if `/dev/fd`
      ## could not be opened at all, so the caller can fall back.
      let dirFd = posix.open(cstring("/dev/fd"),
                             O_RDONLY or O_DIRECTORY_C or O_CLOEXEC)
      if dirFd < 0:
        return false
      # Stack buffer: no allocation between fork and exec. 8 KiB holds ~250
      # entries per syscall, and `/dev/fd` entries are read in fd order, so
      # closing an already-visited descriptor cannot perturb the walk.
      var buffer: array[8192, char]
      var base: Off = 0
      while true:
        let readBytes = getdirentries64(dirFd, addr buffer[0],
                                        csize_t(buffer.len), addr base)
        if readBytes <= 0:
          break
        var offset = 0
        while offset < readBytes:
          let entry = cast[ptr DarwinDirent](addr buffer[offset])
          let recordLen = int(entry.d_reclen)
          if recordLen <= 0:
            # Malformed record: stop rather than spin forever on offset 0.
            offset = readBytes
            break
          # Entry names under `/dev/fd` are decimal descriptor numbers. Parse
          # by hand; `parseInt` and friends allocate.
          var value = 0
          var digits = 0
          var index = 0
          let nameLen = min(int(entry.d_namlen), entry.d_name.len)
          while index < nameLen:
            let ch = entry.d_name[index]
            if ch < '0' or ch > '9':
              digits = 0
              break
            value = value * 10 + (ord(ch) - ord('0'))
            inc digits
            inc index
          if digits > 0 and value > STDERR_FILENO and cint(value) != dirFd:
            discard close(cint(value))
          offset += recordLen
      discard close(dirFd)
      true

  elif defined(freebsd) or defined(netbsd) or defined(openbsd) or
       defined(dragonfly) or defined(solaris):
    # `closefrom(2)` is the BSD/Solaris equivalent of `close_range`. It returns
    # void on FreeBSD and int elsewhere; declared with a header so the platform
    # prototype is the one that is used, and treated as total either way.
    proc closefrom(lowfd: cint) {.importc: "closefrom", header: "<unistd.h>".}

    proc closeInheritedRange(): bool =
      closefrom(cint(3))
      true

  proc closeInheritedByNumber() =
    ## Last resort when no enumeration primitive is available. Bounded by
    ## `RLIMIT_NOFILE.rlim_cur` AND by a hard cap, never by `_SC_OPEN_MAX`.
    var maxFd = 1024
    var limit: RLimit
    if getrlimit(RLIMIT_NOFILE, limit) == 0 and limit.rlim_cur > 0:
      maxFd = int(limit.rlim_cur)
    if maxFd > MaxNumericFdScan:
      maxFd = MaxNumericFdScan
    for fd in 3 ..< maxFd:
      discard close(cint(fd))

  proc closeInheritedChildFds() =
    ## Backstop, between fork and exec: async-signal-safe calls only.
    when defined(linux):
      # One syscall on 5.9 and newer; `/proc/self/fd` on anything older. The
      # capped numeric scan below is reached only when neither is available --
      # a pre-5.9 kernel with no `/proc` mounted -- because it is the only one
      # of the three that can silently miss a descriptor.
      if closeInheritedRange():
        return
      if closeInheritedByEnumeration():
        return
    elif defined(freebsd) or defined(netbsd) or defined(openbsd) or
         defined(dragonfly) or defined(solaris):
      if closeInheritedRange():
        return
    elif defined(macosx):
      if closeInheritedByEnumeration():
        return
    closeInheritedByNumber()

  proc createControlPipe(fds: var array[0..1, cint]): bool =
    ## Create a pipe whose ends are close-on-exec from birth, so neither end
    ## can leak into an unrelated lease's child. The write end is `dup2`'d onto
    ## the child's stdout/stderr, and `dup2` clears CLOEXEC on the new
    ## descriptor, so the child still gets a working stream.
    when defined(linux):
      # `pipe2` sets the flag atomically, which matters because runquota is
      # built with threads and another thread may fork between the two calls.
      if linuxPipe2(fds, O_CLOEXEC) == 0:
        return true
    if pipe(fds) != 0:
      return false
    # Darwin has no `pipe2`; this two-step is the best available there and
    # leaves a narrow window that the backstop above still covers.
    setCloseOnExec(fds[0])
    setCloseOnExec(fds[1])
    true

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
      launchPrimitive: "fork+execve",
      outputCapture: "nonblocking-pipes-poll-bounded",
      completionWait: "waitpid-wnohang",
      cancellation: "process-group-sigterm",
      telemetry: "macos-libproc-when-available",
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

  # ---------------------------------------------------------------------------
  # Child environment and program resolution -- all of it in the parent
  # ---------------------------------------------------------------------------
  #
  # The child used to reach `putEnv` for every entry in `spec.env`, i.e. two
  # string slices, a `deallocShared` and a `setenv` between fork and exec (that
  # is what the generated C showed, not what the Nim reads like). None of that
  # is async-signal-safe. Composing the environment in the parent and handing
  # the child a finished `char *[]` for `execve` removes the whole class of
  # problem rather than narrowing it: the child's path from fork to exec now
  # only reads memory the parent already populated.

  when defined(macosx) or defined(ios):
    # Darwin's loader only links `environ` into complete programs; everything
    # else has to go through `_NSGetEnviron()`. `runquota_process` ships as a
    # static helper that other binaries link, so use the supported accessor.
    proc nsGetEnviron(): ptr cstringArray {.
      importc: "_NSGetEnviron", header: "<crt_externs.h>".}

    proc currentEnviron(): cstringArray =
      nsGetEnviron()[]
  else:
    var globalEnviron {.importc: "environ", header: "<unistd.h>".}: cstringArray

    proc currentEnviron(): cstringArray =
      globalEnviron

  const
    DefaultExecSearchPath = "/usr/bin:/bin"
      ## What `execvp` falls back to when PATH is unset (`_PATH_DEFPATH`).
    ExecShellPath = "/bin/sh"
      ## Interpreter `execvp` retries with when the kernel rejects a file as
      ## ENOEXEC -- a script with no shebang.

  proc envEntryHasKey(entry, key: string): bool =
    ## `entry` is a `NAME=VALUE` string; does its NAME equal `key`? Compared in
    ## place so no slice is materialised per comparison.
    entry.len > key.len and entry[key.len] == '=' and entry.startsWith(key)

  proc childEnvEntries(overrides: openArray[string]): seq[string] =
    ## The environment the child should exec with: the launcher's own
    ## environment with `overrides` layered on top. This reproduces what the
    ## in-child `putEnv` loop produced -- including that an entry with no name
    ## (`=value`) or no separator at all is not an assignment and is ignored --
    ## except that it is computed before the fork.
    let inherited = currentEnviron()
    if inherited != nil:
      var index = 0
      while inherited[index] != nil:
        result.add($inherited[index])
        inc index
    for item in overrides:
      let split = item.find('=')
      if split <= 0:
        continue
      let key = item[0 ..< split]
      var replaced = false
      for existing in result.mitems:
        if existing.envEntryHasKey(key):
          existing = item
          replaced = true
          break
      if not replaced:
        result.add(item)

  proc execSearchPath(entries: openArray[string]): string =
    ## The PATH `execvp` would have searched, distinguishing "PATH is unset"
    ## (fall back to `_PATH_DEFPATH`) from "PATH is set to the empty string"
    ## (a single empty element, i.e. the current directory).
    for entry in entries:
      if entry.envEntryHasKey("PATH"):
        return entry["PATH".len + 1 .. ^1]
    DefaultExecSearchPath

  proc isExecutableFile(path: string): bool =
    var info: Stat
    if stat(cstring(path), info) != 0:
      return false
    S_ISREG(info.st_mode) and access(cstring(path), X_OK) == 0

  proc resolveProgram(program: string; searchPath: string): string =
    ## `execvp`'s PATH search, performed in the parent because `execve` does not
    ## perform one and the search cannot move into the child: building candidate
    ## paths allocates. `execvpe` would have kept it in libc, but Darwin does not
    ## have it, and this repo builds for Darwin and Linux alike.
    ##
    ## `searchPath` is the PATH the *child* will see, so a caller that overrides
    ## PATH in `spec.env` still resolves against the value it asked for -- which
    ## is what `execvp` did once the old in-child `putEnv` had run.
    if program.len == 0 or program.contains('/'):
      return program
    for directory in searchPath.split(':'):
      # An empty PATH element means the current directory, as in `execvp`.
      let candidate =
        if directory.len == 0: program
        else: directory & "/" & program
      if isExecutableFile(candidate):
        return candidate
    # Nothing matched. Hand the bare name to `execve` anyway so an unresolvable
    # program still fails the way it always did (child exits 127) rather than
    # acquiring a new, differently-shaped error path in the parent.
    program

  proc shellFallbackArgv(program: string;
                         argv: openArray[string]): seq[string] =
    ## `execvp` re-executes a file the kernel rejects with ENOEXEC through
    ## `/bin/sh`; `execve` reports the error instead. Build the replacement argv
    ## here so the child can still do it without allocating.
    result = @[ExecShellPath, program]
    for index in 1 ..< argv.len:
      result.add(argv[index])

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

  proc winAppendBounded(target: var string; total: var uint64; data: pointer;
                        count, limit: int) =
    # Windows: mirrors the POSIX `appendBounded` — always accumulate the true
    # byte count, but only keep up to `limit` bytes of text.
    if count <= 0:
      return
    total += uint64(count)
    if limit <= 0:
      let oldLen = target.len
      target.setLen(oldLen + count)
      copyMem(addr target[oldLen], data, count)
      return
    if target.len >= limit:
      return
    let take = min(count, limit - target.len)
    let oldLen = target.len
    target.setLen(oldLen + take)
    copyMem(addr target[oldLen], data, take)

  proc winDrainOutput(child: var LaunchedProcess; process: Process;
                      blocking: bool) =
    # Windows: drain whatever the osproc output pipe currently holds into
    # `child.stdoutText`. stderr is merged into stdout via poStdErrToStdOut at
    # launch, so there is no separate stderr stream to drain. When `blocking`
    # is false we only read while PeekNamedPipe reports data ready, so an idle
    # child cannot stall the caller.
    let outputStream = process.outputStream
    if outputStream == nil:
      return
    var buffer: array[8192, char]
    while true:
      if not blocking and not process.hasData():
        break
      let n = outputStream.readData(addr buffer[0], buffer.len)
      if n <= 0:
        break
      winAppendBounded(child.stdoutText, child.stdoutBytes,
                       addr buffer[0], n, child.stdoutLimit)
      if not blocking and not process.hasData():
        break

  proc winSampleTelemetry(child: var LaunchedProcess; force = false) =
    # Windows: sample the live process tree's RSS / process count via the
    # Windows host backend, throttled to ~10Hz like the POSIX path. Peak RSS
    # cannot be read after the tree exits, so callers must sample while it is
    # still alive.
    let now = epochTime()
    if not force and child.lastTelemetrySampleSeconds != 0.0 and
        now - child.lastTelemetrySampleSeconds < 0.1:
      return
    child.lastTelemetrySampleSeconds = now
    let sample = sampleWindowsProcessTreeTelemetry(uint64(child.pid))
    child.telemetrySource = sample.source
    if sample.diagnostic.code == diagOk:
      if sample.residentMemoryBytes > child.peakResidentMemoryBytes:
        child.peakResidentMemoryBytes = sample.residentMemoryBytes
      if sample.processCount > child.processCount:
        child.processCount = sample.processCount

  proc isWindowsShellCommandAt(argv: openArray[string]; start: int): bool =
    if start < 0 or start + 2 >= argv.len or argv[start + 1] != "-c":
      return false
    var executable = argv[start].extractFilename.toLowerAscii()
    if executable.endsWith(".exe"):
      executable.setLen(executable.len - 4)
    executable in ["sh", "bash", "dash", "ksh", "zsh"]

  proc windowsShellCommandStart(argv: openArray[string]): int =
    if isWindowsShellCommandAt(argv, 0):
      return 0
    for i in countdown(argv.len - 4, 0):
      if argv[i] == "--" and isWindowsShellCommandAt(argv, i + 1):
        return i + 1
    -1

  proc prepareWindowsArgv(argv: openArray[string]):
      tuple[argv: seq[string]; temporaryFiles: seq[string]] =
    ## MSYS2/Cygwin shells do not reliably round-trip long, nested ``-c``
    ## programs through a Windows command-line string. Stage only that payload
    ## and source it through a short wrapper while preserving ``$0`` and the
    ## caller's positional arguments.
    result.argv = @argv
    let shellStart = windowsShellCommandStart(argv)
    if shellStart < 0:
      return

    let (scriptFile, scriptPath) = createTempFile(
      "runquota-shell-", ".sh", getTempDir())
    var scriptOpen = true
    try:
      scriptFile.write(argv[shellStart + 2])
      scriptFile.close()
      scriptOpen = false
    except CatchableError:
      if scriptOpen:
        try:
          scriptFile.close()
        except CatchableError:
          discard
      try:
        removeFile(scriptPath)
      except CatchableError:
        discard
      raise

    let commandName =
      if argv.len > shellStart + 3: argv[shellStart + 3]
      else: argv[shellStart]
    result.argv = @argv[0 .. shellStart + 1]
    result.argv.add(@[
      "script_path=$1; shift; . \"$script_path\"",
      commandName,
      scriptPath.replace('\\', '/'),
    ])
    if argv.len > shellStart + 4:
      result.argv.add(argv[shellStart + 4 .. ^1])
    result.temporaryFiles = @[scriptPath]

  proc launchWindowsProcess(spec: CommandSpec): LaunchedProcess =
    if spec.argv.len == 0:
      raise newException(ValueError, "empty argv")
    let cwd = if spec.cwd.len > 0: spec.cwd else: getCurrentDir()
    let prepared = prepareWindowsArgv(spec.argv)
    let args =
      if prepared.argv.len > 1: prepared.argv[1 .. ^1]
      else: @[]
    # Windows: poEvalCommand + poUsePath were tried in earlier prototypes but
    # cause quoting headaches; pass argv directly and let osproc CreateProcess
    # for us.
    var process: Process
    try:
      process = startProcess(
        prepared.argv[0],
        workingDir = cwd,
        args = args,
        env = windowsChildEnv(spec),
        options = {poStdErrToStdOut, poUsePath}
      )
    except CatchableError:
      for path in prepared.temporaryFiles:
        try:
          removeFile(path)
        except CatchableError:
          discard
      raise
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
      doneFlag: false,
      waitStatus: -1,
      stdoutBytes: 0'u64,
      stderrBytes: 0'u64,
      peakResidentMemoryBytes: 0'u64,
      processCount: 0'u32,
      telemetrySource: backendProfile().telemetry,
      lastTelemetrySampleSeconds: 0.0,
      info: LaunchResult(
        processId: processId,
        processGroupId: processId,
        running: true,
        backend: backendProfile()
      ),
      winProcess: process,
      winJobHandle: uint64(job),
      temporaryLaunchFiles: prepared.temporaryFiles
    )

proc launchProcess*(spec: CommandSpec): LaunchedProcess =
  when defined(posix):
    if spec.argv.len == 0:
      raise newException(ValueError, "empty argv")

    # Everything the child needs between fork and exec is composed here, while
    # there is still a whole process to compose it in. After the fork the child
    # may only read what is already built.
    let childEnv = childEnvEntries(spec.env)
    let program = resolveProgram(spec.argv[0], execSearchPath(childEnv))
    let shellArgv = shellFallbackArgv(program, spec.argv)

    var stdoutPipe: array[0..1, cint]
    var stderrPipe: array[0..1, cint]
    # Close-on-exec from birth: these are runquota's own control descriptors,
    # and a concurrent lease's child must never inherit them. The kernel drops
    # them at `execve` at no per-launch cost.
    if not createControlPipe(stdoutPipe):
      raise newException(OSError, "stdout pipe failed")
    if not createControlPipe(stderrPipe):
      discard close(stdoutPipe[0])
      discard close(stdoutPipe[1])
      raise newException(OSError, "stderr pipe failed")

    # `argv[0]` stays whatever the caller passed, exactly as `execvp` leaves it;
    # only the path handed to the kernel is the resolved one.
    let argv = allocCStringArray(spec.argv)
    defer: deallocCStringArray(argv)
    let envp = allocCStringArray(childEnv)
    defer: deallocCStringArray(envp)
    let shellArgvC = allocCStringArray(shellArgv)
    defer: deallocCStringArray(shellArgvC)
    let pid = fork()
    if pid == 0:
      discard close(stdoutPipe[0])
      discard close(stderrPipe[0])
      if spec.createProcessGroup:
        discard setpgid(0, 0)
      if spec.cwd.len > 0 and chdir(cstring(spec.cwd)) != 0:
        childExit(126)
      let devNull = open(cstring("/dev/null"), O_RDONLY)
      if devNull >= 0:
        discard dup2(devNull, STDIN_FILENO)
        if devNull != STDIN_FILENO:
          discard close(devNull)
      discard dup2(stdoutPipe[1], STDOUT_FILENO)
      discard dup2(stderrPipe[1], STDERR_FILENO)
      discard close(stdoutPipe[1])
      discard close(stderrPipe[1])
      closeInheritedChildFds()
      discard execve(cstring(program), argv, envp)
      if errno == ENOEXEC:
        discard execve(cstring(ExecShellPath), shellArgvC, envp)
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
    if not child.runningFlag or child.winProcess.isNil:
      return false
    child.winProcess.running()
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
  elif defined(windows):
    # Windows: there are no POSIX-style signals — `child.waitStatus` holds the
    # raw process exit code (or -1 if the child has not been observed to exit).
    # The whole tree's CPU time comes from Job Object accounting; the same
    # fields and semantics as the POSIX completion otherwise.
    result = ProcessCompletion(
      processId: uint64(child.pid),
      processGroupId: uint64(child.processGroupId),
      exitCode: -1,
      signal: 0,
      exited: false,
      signaled: false,
      cancelled: child.cancelSent,
      timedOut: timedOut,
      stdout: child.stdoutText,
      stderr: child.stderrText,
      stdoutBytes: child.stdoutBytes,
      stderrBytes: child.stderrBytes,
      elapsedMillis: uint64(max(0, int((epochTime() - child.startedSeconds) * 1000.0))),
      peakResidentMemoryBytes: child.peakResidentMemoryBytes,
      processCount: child.processCount,
      telemetrySource: child.telemetrySource
    )
    if not timedOut and child.waitStatus >= 0:
      result.exited = true
      result.exitCode = child.waitStatus
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
        child.doneSeconds = epochTime()
      elif waited < 0:
        if errno != EINTR:
          child.doneFlag = true
          child.runningFlag = false
          child.waitStatus = 1 shl 8
          child.doneSeconds = epochTime()

    if child.doneFlag:
      child.stdoutFd.drainFd(child.stdoutText, child.stdoutBytes,
                             child.stdoutLimit)
      child.stderrFd.drainFd(child.stderrText, child.stderrBytes,
                             child.stderrLimit)
      # Completion is gated on the leased process itself being reaped (the
      # waitpid above), NOT on every inherited pipe reaching EOF. A forking
      # action's surviving descendants (e.g. cc spawning cc1/as, or a monitor
      # shim's children) inherit the stdout/stderr write-ends and keep them
      # open, so the pipes would never hit EOF and completion would never be
      # declared — the supervisor would wait forever and never emit
      # LeaseFinished. Once both write-ends are observed closed (the common,
      # non-forking case) we report immediately; otherwise we keep draining
      # whatever the descendants emit until a short bounded grace period
      # elapses, then declare completion regardless.
      if child.stdoutFd < 0 and child.stderrFd < 0:
        child.completion = child.buildCompletion(timedOut = false)
        if child.completion.processCount == 0:
          child.completion.processCount = 1
        return true
      const lingeringPipeDrainSeconds = 0.25
      if child.doneSeconds > 0.0 and
          epochTime() - child.doneSeconds >= lingeringPipeDrainSeconds:
        closeFd(child.stdoutFd)
        closeFd(child.stderrFd)
        child.completion = child.buildCompletion(timedOut = false)
        if child.completion.processCount == 0:
          child.completion.processCount = 1
        return true
    false
  elif defined(windows):
    # Windows: nonblocking completion check. We sample live tree telemetry,
    # drain any output the pipe already holds (PeekNamedPipe-gated so an idle
    # child doesn't stall us), and ask osproc whether the process has exited.
    # When it has, drain the remainder and populate `child.completion`.
    if child.completion.exited or child.completion.signaled or
        child.completion.timedOut:
      return true
    if child.winProcess.isNil:
      return false
    let process = child.winProcess

    # Windows: sample RSS / process count before draining so even a very
    # short-lived child gets at least one snapshot while still alive.
    winSampleTelemetry(child)
    winDrainOutput(child, process, blocking = false)

    if not child.doneFlag:
      var alive = true
      try:
        alive = process.running()
      except CatchableError:
        alive = false
      if not alive:
        child.doneFlag = true
        child.runningFlag = false
        try:
          child.waitStatus = process.peekExitCode()
        except CatchableError:
          child.waitStatus = -1

    if child.doneFlag:
      # Windows: take one final telemetry snapshot and drain whatever the pipe
      # still buffers before reporting completion.
      winSampleTelemetry(child, force = true)
      winDrainOutput(child, process, blocking = true)
      if child.winJobHandle != 0:
        var cpuMicros = 0'u64
        var jobProcessCount = 0'u32
        readJobAccounting(Handle(child.winJobHandle), cpuMicros, jobProcessCount)
        # Windows: prefer the Job Object's TotalProcesses (counts every process
        # the tree ever spawned) over the live toolhelp32 count.
        if jobProcessCount > child.processCount:
          child.processCount = jobProcessCount
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
    elif not child.winProcess.isNil:
      try: child.winProcess.terminate() except CatchableError: discard

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
    elif not child.winProcess.isNil:
      try: child.winProcess.kill() except CatchableError: discard

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
    # Windows: mirror the POSIX structure — repeatedly call pollCompletion
    # (which drains the bounded stdout buffer, samples Job Object / toolhelp32
    # telemetry, and detects exit) until the child finishes or the deadline
    # elapses. stderr is merged into stdout via poStdErrToStdOut at launch, so
    # there is no separate stderr stream.
    if child.winProcess.isNil:
      raise newException(OSError, "runquota_process: missing Windows process handle")
    let process = child.winProcess
    var timedOut = false

    while true:
      if child.pollCompletion():
        break

      let elapsed = int((epochTime() - child.startedSeconds) * 1000.0)
      if timeout >= 0 and elapsed >= timeout:
        timedOut = true
        # Windows: terminate the whole tree via the Job Object, then give it a
        # short grace period to actually drop before hard-killing.
        child.terminate()
        let killDeadline = epochTime() + 1.0
        while epochTime() < killDeadline:
          winSampleTelemetry(child)
          winDrainOutput(child, process, blocking = false)
          var alive = true
          try:
            alive = process.running()
          except CatchableError:
            alive = false
          if not alive:
            child.doneFlag = true
            child.runningFlag = false
            try:
              child.waitStatus = process.peekExitCode()
            except CatchableError:
              child.waitStatus = -1
            break
          sleep(10)
        if not child.doneFlag:
          child.killNow()
          try: discard process.waitForExit(timeout = 1000)
          except CatchableError: discard
          try:
            child.waitStatus = process.peekExitCode()
          except CatchableError:
            child.waitStatus = -1
          child.doneFlag = true
          child.runningFlag = false
        # Windows: final telemetry + output drain, plus Job Object accounting.
        winSampleTelemetry(child, force = true)
        winDrainOutput(child, process, blocking = true)
        if child.winJobHandle != 0:
          var cpuMicros = 0'u64
          var jobProcessCount = 0'u32
          readJobAccounting(Handle(child.winJobHandle), cpuMicros, jobProcessCount)
          if jobProcessCount > child.processCount:
            child.processCount = jobProcessCount
        break

      # Windows: short sleep so we don't burn a core polling the pipe / tree.
      sleep(10)

    if timedOut:
      child.completion = child.buildCompletion(timedOut = true)
    result = child.completion
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
  elif defined(windows):
    # Windows: release osproc resources and let the Job Object close. With
    # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE set, closing the last handle reaps
    # any straggler processes in the tree.
    if not child.winProcess.isNil:
      try: child.winProcess.close() except CatchableError: discard
      child.winProcess = nil
    if child.winJobHandle != 0:
      discard closeHandle(Handle(child.winJobHandle))
      child.winJobHandle = 0
    for path in child.temporaryLaunchFiles:
      try:
        removeFile(path)
      except CatchableError:
        discard
    child.temporaryLaunchFiles.setLen(0)
