import std/[monotimes, os, strutils, times]

when defined(posix):
  import std/posix

when defined(windows):
  # Windows: spawn child processes with a raw CreateProcessW, placed in a
  # Job Object at creation (PROC_THREAD_ATTRIBUTE_JOB_LIST) so the whole
  # tree can be tracked and (optionally) killed atomically. `std/osproc` is
  # kept only for `countProcessors` -- the launcher no longer uses its
  # `Process` type or `startProcess`.
  import std/[osproc, strtabs, tempfiles]
  import std/winlean

import runquota_core
import runquota_core/cpu_profile
import runquota_core/measurement
when defined(linux):
  import runquota_host_linux
import runquota_host_macos
when defined(windows):
  # Windows: per-lease RSS telemetry comes from the Windows host backend so
  # waitForCompletion can record peakResidentMemoryBytes on the ProcessCompletion.
  import runquota_host_windows
import runquota_process/types as processTypes
import runquota_process/enforcement
import runquota_process/job_priority
import runquota_process/qos_priority

export processTypes, enforcement, job_priority, qos_priority

const libraryName* = "runquota_process"
const DefaultOutputLimit* = 1_048_576

when defined(posix):
  proc childExit(status: cint) {.importc: "_exit", header: "<unistd.h>", noreturn.}

  when defined(macosx):
    # The background policy of a whole process (what `taskpolicy -b` sets):
    # `setpriority(PRIO_DARWIN_PROCESS, 0, PRIO_DARWIN_BG)`. Declared here
    # because `std/posix` has neither constant. See `runquota_process/
    # qos_priority` for what this and nice measured as.
    proc darwinSetpriority(which: cint; who: cint; prio: cint): cint {.
      importc: "setpriority", header: "<sys/resource.h>".}
    var PRIO_DARWIN_PROCESS {.importc, header: "<sys/resource.h>".}: cint
    var PRIO_DARWIN_BG {.importc, header: "<sys/resource.h>".}: cint

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
    # NOT EXECUTED ANYWHERE YET. Everything below this line is verified by
    # CODEGEN ONLY: it compiles for amd64/arm64/i386/arm, the `offsetOf` assert
    # on the dirent layout fires when perturbed, the child-path allocation
    # checker reports it clean, and the parse loop was transcribed to C and run
    # against synthetic `linux_dirent64` records. No Linux host has ever run it.
    # Treat a failure here as a first observation, not a regression.
    #
    # `close_range(2)` (Linux 5.9) closes the whole range in one syscall, but
    # glibc only wraps it from 2.34. Issue the syscall directly so the build
    # does not depend on the libc version.
    const SYS_close_range = clong(436)
      ## Same number on every architecture (the unified table).

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

    JobCpuRateControlW = object
      ## JOBOBJECT_CPU_RATE_CONTROL_INFORMATION. The second field is a union
      ## in the SDK (CpuRate / Weight / {MinRate, MaxRate}); for the hard-cap
      ## case it is the CpuRate DWORD, which is all this launcher sets, so the
      ## 8-byte struct is modelled as the two DWORDs the cap path uses.
      ControlFlags: uint32
      CpuRate: uint32

    JobNotificationLimitW = object
      ## JOBOBJECT_NOTIFICATION_LIMIT_INFORMATION. Only the two members this
      ## launcher gives real meaning (LimitFlags, JobMemoryLimit) are used;
      ## the I/O and CPU-rate-tolerance notification fields stay zeroed and
      ## their LimitFlags bits are never set.
      IoReadBytesLimit: uint64
      IoWriteBytesLimit: uint64
      PerJobUserTimeLimit: int64
      JobMemoryLimit: uint64
      RateControlTolerance: int32
      RateControlToleranceInterval: int32
      LimitFlags: uint32

    JobLimitViolationW = object
      ## JOBOBJECT_LIMIT_VIOLATION_INFORMATION, read after
      ## JOB_OBJECT_MSG_NOTIFICATION_LIMIT to learn which notification limit
      ## fired (`ViolationLimitFlags`) and to re-arm the next notification --
      ## the system withholds it until this query is made.
      LimitFlags: uint32
      ViolationLimitFlags: uint32
      IoReadBytes: uint64
      IoReadBytesLimit: uint64
      IoWriteBytes: uint64
      IoWriteBytesLimit: uint64
      PerJobUserTime: int64
      PerJobUserTimeLimit: int64
      JobMemory: uint64
      JobMemoryLimit: uint64
      RateControlTolerance: int32
      RateControlToleranceLimit: int32

    JobAssociateCompletionPortW = object
      ## JOBOBJECT_ASSOCIATE_COMPLETION_PORT.
      CompletionKey: pointer
      CompletionPort: Handle

    StartupInfoExW = object
      ## STARTUPINFOEXW: the base STARTUPINFO plus an attribute list.
      ## `StartupInfo.cb` MUST be `sizeof(StartupInfoExW)`, not
      ## `sizeof(STARTUPINFO)` -- otherwise the kernel reads this as the
      ## plain, non-extended form and ignores `lpAttributeList` even with
      ## `EXTENDED_STARTUPINFO_PRESENT` set.
      StartupInfo: STARTUPINFO
      lpAttributeList: pointer

  const
    # Windows: JobObjectAssociateCompletionPortInformation = 7,
    # JobObjectBasicAndIoAccountingInformation = 8,
    # JobObjectExtendedLimitInformation = 9,
    # JobObjectNotificationLimitInformation = 12,
    # JobObjectLimitViolationInformation = 13 (an unrelated enumeration from
    # PROC_THREAD_ATTRIBUTE_JOB_LIST's own attribute number 13 below -- the
    # two just happen to share the integer),
    # JobObjectCpuRateControlInformation = 15.
    # Source: learn.microsoft.com SetInformationJobObject /
    # QueryInformationJobObject parameter tables.
    JobObjectAssociateCompletionPortInformation = 7'i32
    JobObjectBasicAndIoAccountingInformation = 8'i32
    JobObjectExtendedLimitInformation = 9'i32
    JobObjectNotificationLimitInformationClass = 12'i32
    JobObjectLimitViolationInformationClass = 13'i32
    JobObjectCpuRateControlInformation = 15'i32
    # Windows: JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000 so when the daemon
    # drops its handle the child tree is reaped automatically. We don't set
    # JOB_OBJECT_LIMIT_BREAKAWAY_OK; child processes inherit job membership.
    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000'i32
    # Windows: JOB_OBJECT_LIMIT_PRIORITY_CLASS forces every process in the job
    # -- now and every one it later spawns -- to the job's PriorityClass. It
    # shares the one LimitFlags of the job's basic limits with
    # KILL_ON_JOB_CLOSE above (both live in JOBOBJECT_BASIC_LIMIT_INFORMATION),
    # so a set of the basic limits replaces the whole LimitFlags: a
    # priority-class set must re-assert KILL_ON_JOB_CLOSE or it would clear it.
    JOB_OBJECT_LIMIT_PRIORITY_CLASS = 0x00000020'i32
    # Windows: a hard CPU-rate cap enables rate control (0x1) and makes it a
    # ceiling the tree cannot exceed (0x4) rather than a weight-based share.
    JOB_OBJECT_CPU_RATE_CONTROL_ENABLE = 0x00000001'u32
    JOB_OBJECT_CPU_RATE_CONTROL_HARD_CAP = 0x00000004'u32
    # Windows: the same bit (0x200), reused with three different meanings
    # depending which struct/info-class carries it: an ENFORCED job-wide
    # commit cap in JOBOBJECT_EXTENDED_LIMIT_INFORMATION (JobMemoryLimit), a
    # NOTIFICATION-ONLY threshold in JOBOBJECT_NOTIFICATION_LIMIT_INFORMATION
    # (also JobMemoryLimit), and "this is the limit that fired" in
    # JOBOBJECT_LIMIT_VIOLATION_INFORMATION's ViolationLimitFlags. Sources:
    # learn.microsoft.com JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
    # JOBOBJECT_NOTIFICATION_LIMIT_INFORMATION,
    # JOBOBJECT_LIMIT_VIOLATION_INFORMATION.
    JOB_OBJECT_LIMIT_JOB_MEMORY = 0x00000200'u32
    # Windows: the ONE completion-port message delivery is guaranteed for
    # (JOBOBJECT_ASSOCIATE_COMPLETION_PORT Remarks: "except for limits set
    # with the JobObjectNotificationLimitInformation information class,
    # messages are intended only as notifications and their delivery...is
    # not guaranteed. Notifications for limits set with
    # JobObjectNotificationLimitInformation are guaranteed to arrive at the
    # completion port"). `JOB_OBJECT_MSG_JOB_MEMORY_LIMIT`, the HARD limit's
    # own message, is NOT guaranteed, so it is never used as a kill trigger
    # here.
    JOB_OBJECT_MSG_NOTIFICATION_LIMIT = 11'u32
    # Windows: ProcThreadAttributeJobList (13) | PROC_THREAD_ATTRIBUTE_INPUT
    # (0x20000) -- the lpValue parameter is a pointer to a LIST of job
    # handles, assigned to the child in the order given, atomically as part
    # of process creation. Needs Windows 10 / Windows Server 2016 or newer.
    # Source: learn.microsoft.com UpdateProcThreadAttribute.
    PROC_THREAD_ATTRIBUTE_JOB_LIST = 0x0002000D'u
    EXTENDED_STARTUPINFO_PRESENT = 0x00080000'i32

  const windowsCapExceededExitCode* = 2'u32
    ## The reserved exit code `TerminateJobObject` reports for a `kill`-mode
    ## memory-cap breach, distinct from `windowsCancelledExitCode` (ordinary
    ## cancellation) below, so a reader of the exit code alone can tell the
    ## two apart.

  proc createJobObjectW(
    lpJobAttributes: pointer, lpName: WideCString
  ): Handle {.stdcall, dynlib: "kernel32.dll", importc: "CreateJobObjectW".}

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

  proc setPriorityClass(
    hProcess: Handle, dwPriorityClass: uint32
  ): WINBOOL {.stdcall, dynlib: "kernel32.dll", importc: "SetPriorityClass".}

  proc initializeProcThreadAttributeList(
    lpAttributeList: pointer, dwAttributeCount: int32, dwFlags: int32,
    lpSize: ptr csize_t
  ): WINBOOL {.stdcall, dynlib: "kernel32.dll",
    importc: "InitializeProcThreadAttributeList".}

  proc updateProcThreadAttribute(
    lpAttributeList: pointer, dwFlags: int32, attribute: uint,
    lpValue: pointer, cbSize: csize_t, lpPreviousValue: pointer,
    lpReturnSize: ptr csize_t
  ): WINBOOL {.stdcall, dynlib: "kernel32.dll",
    importc: "UpdateProcThreadAttribute".}

  proc deleteProcThreadAttributeList(
    lpAttributeList: pointer
  ) {.stdcall, dynlib: "kernel32.dll",
    importc: "DeleteProcThreadAttributeList".}

  proc createProcessExW(
    lpApplicationName: WideCString, lpCommandLine: WideCString,
    lpProcessAttributes, lpThreadAttributes: pointer,
    bInheritHandles: WINBOOL, dwCreationFlags: int32,
    lpEnvironment: WideCString, lpCurrentDirectory: WideCString,
    lpStartupInfo: pointer, lpProcessInformation: var PROCESS_INFORMATION
  ): WINBOOL {.stdcall, dynlib: "kernel32.dll", importc: "CreateProcessW".}
    ## The same `CreateProcessW` entry point `winlean.createProcessW` already
    ## binds, redeclared to take a `pointer` for `lpStartupInfo` so it can be
    ## a `StartupInfoExW`'s address instead of a plain `STARTUPINFO`'s.

  proc createIoCompletionPort(
    fileHandle: Handle, existingCompletionPort: Handle,
    completionKey: uint, numberOfConcurrentThreads: int32
  ): Handle {.stdcall, dynlib: "kernel32.dll",
    importc: "CreateIoCompletionPort".}

  proc getQueuedCompletionStatus(
    completionPort: Handle, lpNumberOfBytesTransferred: ptr uint32,
    lpCompletionKey: ptr uint, lpOverlapped: ptr pointer,
    dwMilliseconds: int32
  ): WINBOOL {.stdcall, dynlib: "kernel32.dll",
    importc: "GetQueuedCompletionStatus".}

  proc postQueuedCompletionStatus(
    completionPort: Handle, bytesTransferred: uint32,
    completionKey: uint, overlapped: pointer
  ): WINBOOL {.stdcall, dynlib: "kernel32.dll",
    importc: "PostQueuedCompletionStatus".}

  const
    # Windows: the lower scheduling weight a RECLAIMED grant's tree runs at.
    # A process in this class is inherited by the children it spawns, so the
    # whole tree runs below normal, mirroring how POSIX `nice` is inherited
    # through `fork`. Unlike a Job Object CPU-rate cap it is a priority, not a
    # ceiling: the tree may use all free CPU when nothing contends, and only
    # loses contests when the work it was admitted beside wants the processor.
    BELOW_NORMAL_PRIORITY_CLASS = 0x00004000'u32

  proc applyKillOnJobClose(job: Handle) =
    var info: JobExtendedLimitW
    info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    discard setInformationJobObject(
      job,
      JobObjectExtendedLimitInformation,
      addr info,
      int32(sizeof(JobExtendedLimitW))
    )

  proc applyJobPriorityClass(job: Handle; priorityClass: uint32) =
    ## Forces every process in `job` -- now and every one it later spawns --
    ## to `priorityClass`, the switchable below-admission tiering layered on
    ## top of the unconditional `BELOW_NORMAL_PRIORITY_CLASS` a reclaimed tree
    ## already runs at (`runquota_process/job_priority`). A Job Object
    ## PriorityClass LIMIT, unlike the per-process `SetPriorityClass` the base
    ## mechanism uses, a child cannot override for itself: it holds the whole
    ## tree to its group's priority below admission.
    ##
    ## KILL_ON_JOB_CLOSE is re-asserted here (and the same extended struct and
    ## info class `applyKillOnJobClose` uses): both flags share the one
    ## LimitFlags of the job's basic limits, so a set that named only
    ## PRIORITY_CLASS would clear the kill-on-close that reaps the tree. This
    ## is independent of the `--cap` CPU-rate control, which is a different
    ## info class (`JobObjectCpuRateControlInformation`) and does not touch
    ## these limits.
    if priorityClass == 0'u32:
      return
    var info: JobExtendedLimitW
    info.BasicLimitInformation.LimitFlags =
      JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE or JOB_OBJECT_LIMIT_PRIORITY_CLASS
    info.BasicLimitInformation.PriorityClass = int32(priorityClass)
    discard setInformationJobObject(
      job,
      JobObjectExtendedLimitInformation,
      addr info,
      int32(sizeof(JobExtendedLimitW))
    )

  proc applyCpuRateCap(job: Handle; capMilli: uint32) =
    ## Caps the whole tree in `job` at `capMilli` milli-cores of CPU, as a hard
    ## Job Object CPU-rate ceiling. The kernel's `CpuRate` is a fraction of the
    ## TOTAL system CPU in 1/100 of a percent (10000 = every core busy), not a
    ## per-core figure, so a cap of `capMilli` milli-cores on a host of
    ## `countProcessors()` cores is `capMilli / (cores * 1000)` of the whole,
    ## i.e. `capMilli * 10 / cores` hundredths of a percent. Rounded, and
    ## clamped to [1, 10000]: the kernel rejects 0 and anything above 10000.
    if capMilli == 0'u32:
      return
    let cores = max(1, countProcessors())
    var rate = (int64(capMilli) * 10'i64 + int64(cores) div 2) div int64(cores)
    if rate < 1: rate = 1
    if rate > 10000: rate = 10000
    var info = JobCpuRateControlW(
      ControlFlags: JOB_OBJECT_CPU_RATE_CONTROL_ENABLE or
        JOB_OBJECT_CPU_RATE_CONTROL_HARD_CAP,
      CpuRate: uint32(rate))
    discard setInformationJobObject(
      job,
      JobObjectCpuRateControlInformation,
      addr info,
      int32(sizeof(JobCpuRateControlW))
    )

  proc readJobAccounting(job: Handle; userMicros, kernelMicros: var uint64;
                         processCount: var uint32) =
    var info: JobBasicAndIoAccountingW
    var ret: int32 = 0
    if queryInformationJobObject(
      job,
      JobObjectBasicAndIoAccountingInformation,
      addr info,
      int32(sizeof(JobBasicAndIoAccountingW)),
      addr ret) != 0:
      # Windows: TotalUserTime and TotalKernelTime are 100ns ticks. Divide by
      # 10 to get microseconds. These are the WHOLE tree's totals -- the Job
      # Object counts every process spawned inside it, so a grandchild's CPU
      # is accounted here just as a direct child's is.
      if info.BasicInfo.TotalUserTime > 0:
        userMicros = uint64(info.BasicInfo.TotalUserTime div 10)
      if info.BasicInfo.TotalKernelTime > 0:
        kernelMicros = uint64(info.BasicInfo.TotalKernelTime div 10)
      processCount = uint32(max(int32(0), info.BasicInfo.TotalProcesses))

  proc applyMemoryCapHard*(job: Handle; capBytes: uint64) =
    ## `kill` mode's enforced half: a job-wide commit limit
    ## (`JOB_OBJECT_LIMIT_JOB_MEMORY` in `JOBOBJECT_EXTENDED_LIMIT_INFORMATION`).
    ## On breach the commit fails for whichever process attempted it; nothing
    ## is killed by this alone -- that is `applyMemoryCapNotification` and the
    ## watcher below. Re-asserts `KILL_ON_JOB_CLOSE` for the same reason
    ## `applyJobPriorityClass` does: one `LimitFlags` covers both.
    if capBytes == 0:
      return
    var info: JobExtendedLimitW
    info.BasicLimitInformation.LimitFlags =
      JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE or int32(JOB_OBJECT_LIMIT_JOB_MEMORY)
    info.JobMemoryLimit = uint(capBytes)
    discard setInformationJobObject(
      job,
      JobObjectExtendedLimitInformation,
      addr info,
      int32(sizeof(JobExtendedLimitW))
    )

  proc applyMemoryCapNotification*(job: Handle; capBytes: uint64) =
    ## The watcher's actual trigger: a notification-only threshold at
    ## `capBytes` (`JobObjectNotificationLimitInformation`), independent of
    ## whether `applyMemoryCapHard` set an enforced limit too. Crossing it
    ## never fails an allocation; it posts the one completion-port message
    ## Windows guarantees to deliver (`JOB_OBJECT_MSG_NOTIFICATION_LIMIT`).
    if capBytes == 0:
      return
    var info: JobNotificationLimitW
    info.LimitFlags = JOB_OBJECT_LIMIT_JOB_MEMORY
    info.JobMemoryLimit = capBytes
    discard setInformationJobObject(
      job,
      JobObjectNotificationLimitInformationClass,
      addr info,
      int32(sizeof(JobNotificationLimitW))
    )

  proc memoryLimitViolated(job: Handle): bool =
    ## Called after `JOB_OBJECT_MSG_NOTIFICATION_LIMIT`: queries which
    ## notification limit fired, which ALSO re-arms the next notification --
    ## the system withholds it until this query is made, so this must be
    ## called exactly once per message, even when the answer turns out to be
    ## "not memory" (this launcher never sets any other notification limit,
    ## so that should not happen, but a watcher that skipped the query on
    ## that path would silently stop being notified of real breaches).
    var info: JobLimitViolationW
    var ret: int32 = 0
    if queryInformationJobObject(
      job,
      JobObjectLimitViolationInformationClass,
      addr info,
      int32(sizeof(JobLimitViolationW)),
      addr ret) == 0:
      return false
    (info.ViolationLimitFlags and JOB_OBJECT_LIMIT_JOB_MEMORY) != 0

  proc readPeakJobMemoryUsed*(job: Handle): uint64 =
    ## `PeakJobMemoryUsed`: the kernel tracks this constantly, with or
    ## without any limit set, so it is readable in `advisory` mode and for a
    ## lifted (`RUNQUOTA_MEMORY_CAP=off`) run exactly as in `kill` mode --
    ## commit, not resident memory (source `job`).
    var info: JobExtendedLimitW
    var ret: int32 = 0
    if queryInformationJobObject(
      job,
      JobObjectExtendedLimitInformation,
      addr info,
      int32(sizeof(JobExtendedLimitW)),
      addr ret) != 0:
      result = uint64(info.PeakJobMemoryUsed)

  const
    MemoryCapWatcherStopSentinel = 0xFFFF_FFFF'u32
      ## Not a real `JOB_OBJECT_MSG_*` value (the highest documented one is
      ## in the low teens): posted by `stopMemoryCapWatcher` to wake a
      ## watcher thread that saw no breach, so it joins instead of blocking
      ## in `GetQueuedCompletionStatus` forever.

  type
    MemoryCapWatchState = object
      job: Handle
      port: Handle
      killed: bool
        ## Set by the watcher thread alone, read by `stopMemoryCapWatcher`
        ## only after it has joined the thread -- never concurrently.

  proc createThreadWin(lpThreadAttributes: pointer; dwStackSize: csize_t;
                       lpStartAddress: proc (p: pointer): int32 {.stdcall.};
                       lpParameter: pointer; dwCreationFlags: int32;
                       lpThreadId: ptr int32): Handle {.
    stdcall, dynlib: "kernel32.dll", importc: "CreateThread".}

  proc memoryCapWatcherThreadProc(param: pointer): int32 {.stdcall.} =
    ## The watcher thread: a raw `CreateThread`, not `std/typedthreads`, so
    ## the two handles it hands back (`startMemoryCapWatcher`'s result) are
    ## plain `uint64`s `LaunchedProcess` can carry on every platform, the
    ## same way it already carries `winJobHandle`.
    let state = cast[ptr MemoryCapWatchState](param)
    while true:
      var bytes: uint32 = 0
      var key: uint = 0
      var overlapped: pointer = nil
      let ok = getQueuedCompletionStatus(state.port, addr bytes, addr key,
        addr overlapped, INFINITE)
      if ok == 0 or bytes == MemoryCapWatcherStopSentinel:
        return 0
      if bytes == JOB_OBJECT_MSG_NOTIFICATION_LIMIT:
        if memoryLimitViolated(state.job):
          state.killed = true
          discard terminateJobObject(state.job, windowsCapExceededExitCode)
          return 0
        # Re-armed by `memoryLimitViolated`'s query; keep watching in case a
        # future version of this launcher adds another notification limit.

  const
    MemoryCapNotifyMarginMilli = 950'u64
      ## The notification threshold is armed at this fraction (in
      ## thousandths) of the hard cap, never AT it. Measured 2026-11-27: a
      ## notification armed at exactly `capBytes`, with the hard cap also
      ## at `capBytes`, never fires at all -- the hard limit refuses the
      ## very commit that would bring the job's total to the threshold, so
      ## the total never actually reaches it and the "guaranteed" message
      ## is never posted. Confirmed with a worker that ignores its own
      ## allocation failures (so nothing but the watcher can stop it): with
      ## the margin, the watcher kills it every time; with none, it runs to
      ## completion every time. The margin must leave room for at least one
      ## more realistic allocation to still succeed after the notification
      ## fires, so the watcher has a window to act before the hard limit
      ## would have refused anyway.

  proc startMemoryCapWatcher*(job: Handle; capBytes: uint64):
      tuple[threadHandle: uint64; state: uint64] =
    ## Associates a fresh I/O completion port with `job`
    ## (`JobObjectAssociateCompletionPortInformation`), arms the
    ## notification threshold BELOW `capBytes` (`MemoryCapNotifyMarginMilli`;
    ## see its comment for why it cannot be AT `capBytes`), and starts a
    ## thread that calls `TerminateJobObject` with `windowsCapExceededExitCode`
    ## the instant the threshold is crossed. The port is associated before
    ## the threshold is armed, which is itself before any process joins the
    ## job (every caller places the job via `PROC_THREAD_ATTRIBUTE_JOB_LIST`
    ## only after this returns), so no breach can be missed.
    ##
    ## Call `stopMemoryCapWatcher` exactly once with both results, whether
    ## or not the breach happened -- the watcher thread never exits on its
    ## own otherwise. `(0, 0)` means the watcher could not be started (the
    ## cap is then unenforced for this launch; callers fall back exactly as
    ## they do when the job itself could not be created).
    let port = createIoCompletionPort(INVALID_HANDLE_VALUE, 0, 0, 1)
    var assoc = JobAssociateCompletionPortW(CompletionKey: nil,
      CompletionPort: port)
    discard setInformationJobObject(
      job,
      JobObjectAssociateCompletionPortInformation,
      addr assoc,
      int32(sizeof(JobAssociateCompletionPortW)))
    let notifyBytes = (capBytes * MemoryCapNotifyMarginMilli) div 1000'u64
    applyMemoryCapNotification(job, notifyBytes)
    let state = cast[ptr MemoryCapWatchState](
      alloc0(sizeof(MemoryCapWatchState)))
    state.job = job
    state.port = port
    var tid: int32 = 0
    let th = createThreadWin(nil, 0, memoryCapWatcherThreadProc, state, 0,
      addr tid)
    if th == 0:
      discard closeHandle(port)
      dealloc(state)
      return (0'u64, 0'u64)
    (uint64(th), cast[uint64](state))

  proc stopMemoryCapWatcher*(threadHandle, state: uint64): bool =
    ## Joins the watcher thread and releases its completion port. Returns
    ## whether it terminated the job for a breach. A no-op (returns false)
    ## when `state` is 0, matching `startMemoryCapWatcher`'s "could not
    ## start" result.
    if state == 0:
      return false
    let statePtr = cast[ptr MemoryCapWatchState](state)
    discard postQueuedCompletionStatus(
      statePtr.port, MemoryCapWatcherStopSentinel, 0, nil)
    if threadHandle != 0:
      discard waitForSingleObject(Handle(threadHandle), INFINITE)
      discard closeHandle(Handle(threadHandle))
    result = statePtr.killed
    discard closeHandle(statePtr.port)
    dealloc(statePtr)

  proc finalizeMemoryCap(child: var LaunchedProcess) =
    ## Stops this launch's watcher (if any) and reads the tree's peak,
    ## exactly once -- called at the done transition in `pollCompletion`
    ## and in `waitForCompletion`'s timeout path, right beside the
    ## existing `readJobAccounting` call. `buildCompletion` only reads
    ## what this leaves on `child`; it never calls it itself, since it
    ## takes `child` by value and stopping a watcher twice would double-
    ## close its handles.
    if child.memoryCapFinalized:
      return
    child.memoryCapFinalized = true
    if child.winJobHandle == 0:
      return
    if child.memoryCapMeasuring:
      child.memoryPeakBytesMeasured =
        readPeakJobMemoryUsed(Handle(child.winJobHandle))
    if child.winMemoryCapState != 0:
      child.memoryCapKilled = stopMemoryCapWatcher(
        child.winMemoryCapThread, child.winMemoryCapState)
      child.winMemoryCapThread = 0
      child.winMemoryCapState = 0

proc shellScriptDir*(): string =
  ## Where Windows launches stage a long ``sh -c`` program as a wrapper
  ## script. A directory of its own, so a consumer that observes the
  ## launched process's file accesses can recognise the wrapper as launch
  ## machinery: its content is the ``-c`` program already present in argv,
  ## and its per-launch random name would otherwise make every observation
  ## of the same command differ. Build systems mirror this path; changing it
  ## is a contract change.
  getTempDir() / "runquota-shell"

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
    # Windows: each lease's child tree is placed in a Job Object at
    # creation, so cancellation and accounting are scoped to the tree, not
    # the leader process alone.
    ProcessBackendProfile(
      name: "windows-jobobject",
      launchPrimitive: "CreateProcessW+PROC_THREAD_ATTRIBUTE_JOB_LIST",
      outputCapture: "nonblocking-pipes-peek-bounded",
      completionWait: "exit-code-poll",
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

const windowsCancelledExitCode* = 1'u32
  ## The exit code a child ended by `terminate`, `killNow` or `cancelAndWait`
  ## reports on Windows. There are no POSIX signals there, so a cancelled
  ## child is known by its exit status alone -- the form
  ## `runquota_protocol.killedWithExitCode` documents as the only kill
  ## evidence a Windows supervisor can offer. Exported so a caller can
  ## recognise it rather than restate the number.

proc commandSpec*(argv: openArray[string]; cwd = ""; env: openArray[string] = [];
                  stdoutLimit = DefaultOutputLimit; stderrLimit = DefaultOutputLimit;
                  createProcessGroup = true; inheritEnv = true;
                  stdio = captureStdio;
                  unsetEnv: openArray[string] = []): CommandSpec =
  for item in argv:
    result.argv.add(item)
  result.cwd = cwd
  for item in env:
    result.env.add(item)
  result.inheritEnv = inheritEnv
  for name in unsetEnv:
    result.unsetEnv.add(name)
  result.stdoutLimit = stdoutLimit
  result.stderrLimit = stderrLimit
  result.createProcessGroup = createProcessGroup
  result.stdio = stdio

const treeSampleIntervalSeconds = 0.1
  ## The `tree-sampling` cadence: the launcher reads its tree's resident
  ## memory and process count at most this often while it waits.

proc launchTelemetrySource(treeSampling: bool): string =
  ## The telemetry source a launch starts with. With `tree-sampling` off the
  ## completion says so, so a reader of a zero peak can tell "nobody
  ## measured" from "the backend could not read it".
  if treeSampling: backendProfile().telemetry
  else: "off (RUNQUOTA_MEASUREMENT tree-sampling=off)"

proc launchResult*(processId: uint64; running: bool): LaunchResult =
  LaunchResult(
    processId: processId,
    processGroupId: processId,
    running: running,
    backend: backendProfile()
  )

proc appendCapturedOutput(target: var string; total: var uint64;
                          data: pointer; count, limit: int;
                          unlimitedWhenNonPositive: bool) =
  ## Keep the newest bounded bytes so a failed command retains its terminal
  ## diagnostic. ``total`` still records every byte emitted.
  if count <= 0:
    return
  total += uint64(count)
  let source = cast[ptr UncheckedArray[char]](data)
  if limit <= 0:
    if unlimitedWhenNonPositive:
      let oldLen = target.len
      target.setLen(oldLen + count)
      copyMem(addr target[oldLen], addr source[0], count)
    return
  if count >= limit:
    target.setLen(limit)
    copyMem(addr target[0], addr source[count - limit], limit)
    return

  let overflow = max(0, target.len + count - limit)
  if overflow > 0:
    let retained = target.len - overflow
    if retained > 0:
      moveMem(addr target[0], addr target[overflow], retained)
    target.setLen(retained)
  let oldLen = target.len
  target.setLen(oldLen + count)
  copyMem(addr target[oldLen], addr source[0], count)

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
    appendCapturedOutput(
      target, total, data, count, limit,
      unlimitedWhenNonPositive = false)

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

  proc envEntryNamedIn(entry: string; names: openArray[string]): bool =
    ## Is `entry` (`NAME=VALUE`) one of the `names` a launch removes?
    for name in names:
      if entry.envEntryHasKey(name):
        return true
    false

  proc childEnvEntries(overrides: openArray[string];
                       inherit = true;
                       unset: openArray[string] = []): seq[string] =
    ## The environment the child should exec with: the launcher's own
    ## environment with `overrides` layered on top. This reproduces what the
    ## in-child `putEnv` loop produced -- including that an entry with no name
    ## (`=value`) or no separator at all is not an assignment and is ignored --
    ## except that it is computed before the fork. With `inherit = false` the
    ## launcher's own environment is not the base: the child gets `overrides`
    ## alone (`CommandSpec.inheritEnv`). `unset` names are dropped from the
    ## inherited base before the overrides go on, so an override still sets
    ## its name (`CommandSpec.unsetEnv`).
    let inherited = if inherit: currentEnviron() else: nil
    if inherited != nil:
      var index = 0
      while inherited[index] != nil:
        let entry = $inherited[index]
        if not envEntryNamedIn(entry, unset):
          result.add(entry)
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

  proc execFailurePrefix(program: string; argv: openArray[string];
                         envp: openArray[string]): string =
    ## The part of the "could not exec" message that is known before the fork:
    ## what was being run and how big the argument and environment blocks were.
    ## The sizes are the reason this message exists: `execve` answers E2BIG
    ## for an argument over `MAX_ARG_STRLEN` (131072 bytes on Linux) and for an
    ## argument-plus-environment block over the stack-derived limit, and
    ## neither is diagnosable from an exit code alone. Each string counts its
    ## terminating NUL, as the kernel does.
    var argvBytes = 0
    for item in argv:
      argvBytes += item.len + 1
    var envBytes = 0
    for item in envp:
      envBytes += item.len + 1
    "runquota: cannot execute " & program & " (argv bytes " & $argvBytes &
      ", env bytes " & $envBytes & "): "

  proc writeAllToStderr(text: cstring) =
    ## Async-signal-safe: `write` on a buffer the parent built. A short write
    ## is not retried -- this is a diagnostic on the way to `_exit`.
    if text != nil:
      discard posix.write(STDERR_FILENO, pointer(text), len(text))

  proc childReportExecFailure(prefix: cstring; failure: cint) =
    ## Runs in the forked child after `execve` failed. Allocation-free: the
    ## errno name is a literal and the decimal is formatted into a stack buffer.
    writeAllToStderr(prefix)
    # An `if` chain, not a `case`: on a non-Linux target the POSIX errno values
    # are C-header variables (`var E2BIG {.importc.}`), and `case` demands
    # compile-time constants, so a `case` here breaks the cross-OS compile.
    let name: cstring =
      if failure == E2BIG: "E2BIG"
      elif failure == ENOENT: "ENOENT"
      elif failure == EACCES: "EACCES"
      elif failure == ENOEXEC: "ENOEXEC"
      elif failure == ENOMEM: "ENOMEM"
      elif failure == ENOTDIR: "ENOTDIR"
      elif failure == ELOOP: "ELOOP"
      elif failure == ENAMETOOLONG: "ENAMETOOLONG"
      elif failure == ETXTBSY: "ETXTBSY"
      elif failure == EISDIR: "EISDIR"
      else: "errno"
    writeAllToStderr(name)
    writeAllToStderr(" (errno ")
    var digits: array[12, char]
    var position = digits.high
    digits[position] = '\0'
    var remaining = int(failure)
    if remaining <= 0:
      dec position
      digits[position] = '0'
    while remaining > 0:
      dec position
      digits[position] = char(ord('0') + remaining mod 10)
      remaining = remaining div 10
    writeAllToStderr(cast[cstring](addr digits[position]))
    writeAllToStderr(")\n")

  proc timevalMicros(value: Timeval): uint64 =
    uint64(max(0'i64, int64(value.tv_sec))) * 1_000_000'u64 +
      uint64(max(0'i64, int64(value.tv_usec)))

  when defined(linux):
    proc ioTotalsFromRusage(usage: Rusage): IoTotals =
      ## The tree's storage bytes from the `wait4` that reaped its root:
      ## `ru_inblock` / `ru_oublock`, which Linux counts in 512-byte units
      ## from the same task IO accounting that feeds `read_bytes` /
      ## `write_bytes` of `/proc/<pid>/io`, for the root and every
      ## descendant it waited for (getrusage(2); the kernel folds a reaped
      ## child's IO into its parent's, as it does its CPU time).
      ##
      ## WHY NOT `/proc/<pid>/io` OF THE EXITED ROOT, which is what this
      ## read until 2026-11-19: once a task has exited, Linux shows its
      ## `/proc/<pid>` files as owned by root, and `io` is mode 0400. The
      ## open fails with EACCES for a launcher that is not root, even though
      ## it is the task's parent and has the same uid (measured on Linux
      ## 6.18; CAP_DAC_READ_SEARCH reads it, CAP_SYS_PTRACE does not). So an
      ## unprivileged launcher measured nothing. `wait4` has no such check:
      ## the parent is entitled to its child's usage.
      ##
      ## Each task's count is truncated to whole 512-byte units, so the
      ## figure can read below the byte count by less than 512 bytes per
      ## process and thread of the tree.
      ##
      ## Not known where the kernel does not account task IO
      ## (`CONFIG_TASK_IO_ACCOUNTING` off): both fields are then always 0,
      ## and a zero nobody measured must not be stored as a measurement.
      ## `/proc/self/io` is the file that option provides. Without procfs
      ## mounted nothing is reported either, although `wait4` measured.
      if not fileExists("/proc/self/io"):
        return IoTotals(known: false)
      IoTotals(known: true,
        readBytes: uint64(max(0'i64, int64(usage.ru_inblock))) * 512'u64,
        writeBytes: uint64(max(0'i64, int64(usage.ru_oublock))) * 512'u64)

  when defined(macosx):
    const pPid = cint(1)
      ## `P_PID` of `idtype_t` (<sys/wait.h>).

    proc readExitedRootIo(pid: int): IoTotals =
      ## The root's `ri_diskio_bytesread` / `ri_diskio_byteswritten` from
      ## `proc_pid_rusage`, read while it is a zombie (after it exited,
      ## before it is reaped). THESE ARE THE ROOT'S OWN BYTES: macOS keeps no
      ## reaped-children share for disk IO (there is `ri_child_user_time` but
      ## no `ri_child_diskio_*`), so what a descendant wrote is NOT in the
      ## root's figure, unlike Linux's `wait4` block counts. A tree whose root
      ## only forks reads low (often 0). Not known when the read fails.
      var readBytes, writtenBytes = 0'u64
      if readMacosProcessDiskIo(uint64(pid), readBytes, writtenBytes):
        IoTotals(known: true, readBytes: readBytes, writeBytes: writtenBytes)
      else:
        IoTotals(known: false)

  proc reapChild(child: var LaunchedProcess; status: var cint;
                 options: cint): Pid =
    ## `waitpid` that also keeps what the kernel says the reaped tree used.
    ##
    ## `wait4` returns, with the status, the rusage of the child INCLUDING
    ## every descendant it waited for, directly or through descendants that
    ## were themselves waited for -- which is the tree's CPU time, read at
    ## the one moment the launcher has it for free. Not `getrusage(
    ## RUSAGE_CHILDREN)`: that is process-wide, and a launcher with many
    ## children at once (a build engine) cannot attribute it to one of them.
    ## What neither can see is a descendant re-parented away before it was
    ## waited for; see `runquota_core/cpu_profile`.
    when defined(macosx):
      # `sizing-data`: LOOK AT THE EXIT WITHOUT CONSUMING IT, read the
      # zombie's IO counters, then reap it below as always (Linux takes
      # the counters from the `wait4` below instead). `waitid` with
      # `WNOWAIT` leaves the child waitable, so the `wait4` that follows
      # returns at once with the same status and the rusage.
      # The cap's watch reads the root's high-water mark from the same
      # zombie: its own peak, however short, and however soon it exited.
      let wantIo = child.sizingData and not child.ioTotals.known
      let wantPeak = child.memoryCap.active and not child.memoryCap.rootPeakRead
      if wantIo or wantPeak:
        var info: SigInfo
        zeroMem(addr info, sizeof(info))
        let flags = WEXITED or WNOWAIT or (options and WNOHANG)
        let probed = waitid(pPid, Id(child.pid), info, flags)
        if probed == 0 and info.si_pid == Pid(child.pid):
          if wantIo:
            child.ioTotals = readExitedRootIo(child.pid)
          if wantPeak:
            var footprint, lifetimeMax: uint64
            if readMacosProcessFootprint(uint64(child.pid), footprint,
                                         lifetimeMax):
              let wasExceeded = child.memoryCap.exceeded
              child.memoryCap.observeExitedRoot(lifetimeMax)
              # A BREACH FIRST SEEN AT THE ROOT'S EXIT, under `mcaKill`: the
              # root peaked and exited before any reading. The root itself
              # has finished (its status stands, so the tree is reported as
              # over its cap but not killed), but what is left of its tree is
              # killed, as it would have been at a reading.
              if not wasExceeded and child.memoryCap.exceeded and
                  child.memoryCap.action == mcaKill and
                  child.memoryCap.applied:
                child.memoryCap.killedAfterRootExit = killMacosTree(
                  child.memoryCap.root,
                  (if child.memoryCap.ownGroup: child.processGroupId else: 0),
                  trackedMembers(child.memoryCap.tracker))
        elif probed == 0 and (options and WNOHANG) != 0:
          # NOT EXITED YET, so answer that and do NOT go on to `wait4`. The
          # root can exit between the two calls, and a `wait4` that then
          # reaped it would consume the zombie this probe exists to read:
          # its figures would be lost for good, and the finish would carry no
          # root peak and no IO (measured on macOS 26.5: one launch in 30 lost the
          # root's peak this way). The next poll finds the zombie, reads it
          # and reaps it.
          return Pid(0)
        # A probe that FAILED changes nothing: `wait4` below gives the answer
        # it always did, without the zombie's figures.
    var usage: Rusage
    result = wait4(Pid(child.pid), addr status, options, addr usage)
    if result == Pid(child.pid):
      # The root is reaped: no reading of its tree follows, so the cap's
      # kqueue goes now, on every path to the completion, rather than at
      # `close` (which a caller may never call).
      close(child.memoryCap.tracker)
      child.rusageKnown = true
      child.rusageUserMicros = timevalMicros(usage.ru_utime)
      child.rusageSysMicros = timevalMicros(usage.ru_stime)
      # `ru_maxrss` is in KiB on Linux and in bytes on macOS (getrusage(2)
      # on each).
      let maxRss = uint64(max(0'i64, int64(usage.ru_maxrss)))
      child.rusageMaxRssBytes =
        when defined(macosx): maxRss else: maxRss * 1024'u64
      child.rusageMajorFaults = uint64(max(0'i64, int64(usage.ru_majflt)))
      child.reapMonoMillis = getMonoTime().ticks div 1_000_000
      when defined(linux):
        # `sizing-data`: the tree's storage bytes are in the same rusage.
        if child.sizingData and not child.ioTotals.known:
          child.ioTotals = ioTotalsFromRusage(usage)

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
    if child.rusageKnown:
      result.totals = FinishTotals(known: true,
        cpuUserMicros: child.rusageUserMicros,
        cpuSysMicros: child.rusageSysMicros,
        maxRssBytes: child.rusageMaxRssBytes,
        majorPageFaults: child.rusageMajorFaults,
        durationMillis: uint64(max(0'i64,
          child.reapMonoMillis - child.launchMonoMillis)))
      if child.profiles or child.sizingData:
        var sampler = child.profileSampler
        sampler.finish(child.reapMonoMillis - child.launchMonoMillis,
          result.totals.totalCpuMicros)
        if child.profiles:
          result.cpuProfile = sampler.profile()
        result.memoryProfileMiB = sampler.memoryProfileMiB()
        if child.sizingData:
          result.memoryProfile = sampler.memoryProfile()
    if child.sizingData:
      result.io = child.ioTotals
    if child.memoryCap.active:
      result.memoryCapBytes = child.memoryCap.capBytes
      result.memoryCapProblem = child.memoryCap.problem
      if child.memoryCap.applied:
        result.memoryCapMeasured = true
        result.capExceeded = child.memoryCap.exceeded
        result.capKilled = child.memoryCap.killed
        result.memoryPeakBytes = child.memoryCap.peakBytes
        result.memoryPeakSource = mpsPoll
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
    # Windows: start from the current process env (unless the caller asked
    # for exactly its own entries, `inheritEnv = false`), then layer overrides.
    # Windows names are case-insensitive: an inherited Path and a PATH
    # override must describe one value in the child's environment block.
    result = newStringTable(modeCaseInsensitive)
    if spec.inheritEnv:
      for k, v in envPairs():
        var removed = false
        for name in spec.unsetEnv:
          if cmpIgnoreCase(name, k) == 0:
            removed = true
            break
        if not removed:
          result[k] = v
    for entry in spec.env:
      let eq = entry.find('=')
      if eq <= 0:
        continue
      result[entry[0 ..< eq]] = entry[eq + 1 .. ^1]

  proc winAppendBounded(target: var string; total: var uint64; data: pointer;
                        count, limit: int) =
    appendCapturedOutput(
      target, total, data, count, limit,
      unlimitedWhenNonPositive = true)

  const winLingeringPipeDrainSeconds = 0.25
    ## How long output is still collected after the leased process itself has
    ## exited, when something it started keeps a pipe write-end open. The
    ## POSIX arm's `lingeringPipeDrainSeconds`, for the same reason.

  proc winDrainPipe(handle: Handle; closed: var bool;
                    target: var string; total: var uint64; limit: int) =
    ## Read what one pipe holds RIGHT NOW, never waiting for more.
    ##
    ## `PeekNamedPipe` says how much is buffered and, by failing (with
    ## `ERROR_BROKEN_PIPE`), that every write end has closed and nothing is
    ## left -- which is the only non-blocking way to see end of input on an
    ## anonymous pipe. Reads are sized to what the peek reported, so
    ## `ReadFile` returns at once instead of parking until the writer writes
    ## again or goes away. That wait is what used to make completion of a
    ## FORKING action -- a leader that exits while a descendant holds the
    ## inherited write end -- take as long as the descendant lived.
    if closed or handle == 0:
      return
    var buffer: array[8192, char]
    while true:
      var available = 0'i32
      if not peekNamedPipe(handle, lpTotalBytesAvail = addr available):
        closed = true
        return
      if available <= 0:
        return
      var got: int32 = 0
      let toRead = min(available, int32(buffer.len))
      if readFile(handle, addr buffer[0], toRead, addr got, nil) == 0:
        closed = true
        return
      if got <= 0:
        closed = true
        return
      winAppendBounded(target, total, addr buffer[0], int(got), limit)

  proc winDrainOutput(child: var LaunchedProcess) =
    # Windows: drain whatever the stdout and stderr pipes currently hold into
    # `child.stdoutText` / `child.stderrText`. The two are separate pipes, as
    # on POSIX: every consumer writes `completion.stdout` and
    # `completion.stderr` to different places, and `stderrLimit` bounds the
    # second one.
    if child.winStdoutClosed and child.winStderrClosed:
      return
    winDrainPipe(Handle(child.winStdoutHandle), child.winStdoutClosed,
      child.stdoutText, child.stdoutBytes, child.stdoutLimit)
    winDrainPipe(Handle(child.winStderrHandle), child.winStderrClosed,
      child.stderrText, child.stderrBytes, child.stderrLimit)

  proc winProcessRunning(handle: Handle): bool =
    if handle == 0:
      return false
    var code: int32 = 0
    getExitCodeProcess(handle, code) != 0 and code == STILL_ACTIVE

  proc winProcessExitCode(handle: Handle): int32 =
    discard getExitCodeProcess(handle, result)

  proc winOutputSettled(child: LaunchedProcess): bool =
    ## After the leased process has exited: true once both pipes have reached
    ## end of input (the ordinary case) or the lingering-drain grace is over
    ## (a descendant still holds a write end open). Completion is gated on
    ## the leased process itself, never on its descendants' pipes.
    (child.winStdoutClosed and child.winStderrClosed) or
      epochTime() - child.doneSeconds >= winLingeringPipeDrainSeconds

  proc winSampleTelemetry(child: var LaunchedProcess; force = false) =
    # Windows: sample the live process tree's RSS / process count via the
    # Windows host backend, throttled to ~10Hz like the POSIX path. Peak RSS
    # cannot be read after the tree exits, so callers must sample while it is
    # still alive.
    if not child.treeSampling:
      return
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

    createDir(shellScriptDir())
    let (scriptFile, scriptPath) = createTempFile(
      "runquota-shell-", ".sh", shellScriptDir())
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

  proc buildWindowsCommandLine(argv: openArray[string]): string =
    ## `quoteShell` on Windows is `quoteShellWindows` (`std/strutils`,
    ## public): the same quoting `std/osproc`'s private `buildCommandLine`
    ## uses, which this module cannot call.
    result = quoteShell(argv[0])
    for i in 1 ..< argv.len:
      result.add(' ')
      result.add(quoteShell(argv[i]))

  proc buildWindowsEnvBlock(env: StringTableRef): tuple[data: cstring; len: int] =
    ## The double-NUL-terminated block `CreateProcessW` expects.
    ## `newWideCString(data, len)` (called on the result by the caller) adds
    ## its own terminating wide NUL after `len` content bytes, which is
    ## already the env block's required trailing double-NUL once the last
    ## entry's own embedded `\0` (included in `len`) is counted -- the same
    ## trick `std/osproc`'s private `buildEnv` relies on, which this module
    ## cannot call either. With ZERO entries (`inheritEnv = false` and no
    ## declared `env`) there is no entry to borrow that second null from, so
    ## `len` must still be at least 1 -- one zeroed content byte, making the
    ## terminator `newWideCString` appends the second -- or `CreateProcessW`
    ## sees a single-NUL block and refuses with ERROR_INVALID_PARAMETER.
    var total = 0
    for key, val in pairs(env):
      total += key.len + val.len + 2 # "=" and the entry's own "\0"
    var buf = cast[cstring](alloc0(max(total, 1)))
    var pos = 0
    for key, val in pairs(env):
      let entry = key & "=" & val
      copyMem(addr buf[pos], cstring(entry), entry.len + 1)
      pos += entry.len + 1
    (buf, max(total, 1))

  proc winMakeInheritablePipe(readEnd, writeEnd: var Handle) =
    var sa: SECURITY_ATTRIBUTES
    sa.nLength = int32(sizeof(SECURITY_ATTRIBUTES))
    sa.lpSecurityDescriptor = nil
    sa.bInheritHandle = 1
    if createPipe(readEnd, writeEnd, sa, 0) == 0:
      raiseOSError(osLastError())

  proc winOpenNulForRead(): Handle =
    ## The child's stdin, redirected from the NUL device -- the Windows
    ## analog of POSIX dup2'ing `/dev/null` onto `STDIN_FILENO`. Unlike the
    ## anonymous pipe `std/osproc` creates for stdin, nothing here needs to
    ## be drained or ever written to.
    var sa: SECURITY_ATTRIBUTES
    sa.nLength = int32(sizeof(SECURITY_ATTRIBUTES))
    sa.lpSecurityDescriptor = nil
    sa.bInheritHandle = 1
    const
      GenericRead = cast[int32](0x80000000'u32)
      FileShareReadWrite = 0x00000003'i32
      OpenExisting = 3'i32
      FileAttributeNormal = 0x00000080'i32
    result = createFileW(newWideCString("NUL"), GenericRead,
      FileShareReadWrite, addr sa, OpenExisting, FileAttributeNormal, 0)
    if result == INVALID_HANDLE_VALUE:
      raiseOSError(osLastError())

  proc winCreateProcessInJob(cmdLine: string;
                             envBlock: tuple[data: cstring; len: int];
                             cwd: string; si: STARTUPINFO; job: Handle):
      tuple[ok: bool; procInfo: PROCESS_INFORMATION] =
    ## `CreateProcessW` with `job` named in a `PROC_THREAD_ATTRIBUTE_JOB_LIST`,
    ## so the child is a member of `job` from its very first instruction --
    ## no window in which it, or a grandchild it forks immediately, is not.
    var attrListSize: csize_t = 0
    discard initializeProcThreadAttributeList(nil, 1, 0, addr attrListSize)
    if attrListSize == 0:
      return (false, PROCESS_INFORMATION())
    let attrListBuf = alloc(int(attrListSize))
    defer: dealloc(attrListBuf)
    if initializeProcThreadAttributeList(attrListBuf, 1, 0,
        addr attrListSize) == 0:
      return (false, PROCESS_INFORMATION())
    defer: deleteProcThreadAttributeList(attrListBuf)
    var jobList = [job]
    if updateProcThreadAttribute(attrListBuf, 0, PROC_THREAD_ATTRIBUTE_JOB_LIST,
        addr jobList[0], csize_t(sizeof(Handle)), nil, nil) == 0:
      return (false, PROCESS_INFORMATION())
    var siEx: StartupInfoExW
    siEx.StartupInfo = si
    siEx.StartupInfo.cb = int32(sizeof(StartupInfoExW))
    siEx.lpAttributeList = attrListBuf
    let cmdWide = newWideCString(cmdLine)
    let envWide = if envBlock.data.isNil: newWideCString(cstring(nil))
                  else: newWideCString(envBlock.data, envBlock.len)
    let cwdWide = newWideCString(cwd)
    var procInfo: PROCESS_INFORMATION
    const flags = NORMAL_PRIORITY_CLASS or CREATE_UNICODE_ENVIRONMENT or
      EXTENDED_STARTUPINFO_PRESENT
    let ok = createProcessExW(nil, cmdWide, nil, nil, 1, flags, envWide,
      cwdWide, addr siEx, procInfo) != 0
    (ok, procInfo)

  proc winCreateProcessPlain(cmdLine: string;
                             envBlock: tuple[data: cstring; len: int];
                             cwd: string; si: STARTUPINFO):
      tuple[ok: bool; procInfo: PROCESS_INFORMATION] =
    ## The fallback when no job could be created, or the job-list attribute
    ## was refused: an ordinary, unplaced launch. Placement must never fail
    ## a launch outright -- the same principle the Linux cgroup module
    ## states for itself.
    var siVar = si
    let cmdWide = newWideCString(cmdLine)
    let envWide = if envBlock.data.isNil: newWideCString(cstring(nil))
                  else: newWideCString(envBlock.data, envBlock.len)
    let cwdWide = newWideCString(cwd)
    var procInfo: PROCESS_INFORMATION
    const flags = NORMAL_PRIORITY_CLASS or CREATE_UNICODE_ENVIRONMENT
    let ok = createProcessExW(nil, cmdWide, nil, nil, 1, flags, envWide,
      cwdWide, addr siVar, procInfo) != 0
    (ok, procInfo)

  proc launchWindowsProcess(spec: CommandSpec): LaunchedProcess =
    if spec.argv.len == 0:
      raise newException(ValueError, "empty argv")
    let treeSampling = measureTreeSampling in clientMeasurements()
    let cwd = if spec.cwd.len > 0: spec.cwd else: getCurrentDir()
    let prepared = prepareWindowsArgv(spec.argv)
    let cmdLine = buildWindowsCommandLine(prepared.argv)
    let envBlock = buildWindowsEnvBlock(windowsChildEnv(spec))

    var si: STARTUPINFO
    si.cb = int32(sizeof(STARTUPINFO))
    si.dwFlags = STARTF_USESTDHANDLES
    var stdinHandle, stdoutRead, stdoutWrite, stderrRead, stderrWrite: Handle
    if spec.stdio == inheritStdio:
      si.hStdInput = getStdHandle(STD_INPUT_HANDLE)
      si.hStdOutput = getStdHandle(STD_OUTPUT_HANDLE)
      si.hStdError = getStdHandle(STD_ERROR_HANDLE)
    else:
      # stdout and stderr on SEPARATE pipes, as on POSIX: `completion.stdout`
      # and `completion.stderr` go to different places, and `stderrLimit`
      # bounds the second one.
      stdinHandle = winOpenNulForRead()
      winMakeInheritablePipe(stdoutRead, stdoutWrite)
      winMakeInheritablePipe(stderrRead, stderrWrite)
      # The ends THIS process keeps must not be inherited by a FUTURE child
      # it launches; only the child-side ends (and the NUL handle) stay
      # inheritable.
      discard setHandleInformation(stdoutRead, DWORD(HANDLE_FLAG_INHERIT), 0)
      discard setHandleInformation(stderrRead, DWORD(HANDLE_FLAG_INHERIT), 0)
      si.hStdInput = stdinHandle
      si.hStdOutput = stdoutWrite
      si.hStdError = stderrWrite

    # Windows: every leased tree is placed in a Job Object AT CREATION
    # (PROC_THREAD_ATTRIBUTE_JOB_LIST, below), closing the race the previous
    # CreateJobObjectW-then-AssignProcessToJobObject sequence accepted. Every
    # limit below-admission wants on this tree -- KILL_ON_JOB_CLOSE, the CPU
    # cap, priority, a memory cap once wired in -- is set on the job BEFORE
    # the child exists, so there is no "assigned yet?" uncertainty at all:
    # if `CreateProcessW` below succeeds with this job in its attribute
    # list, every limit already in force on the job covers the child from
    # its first instruction.
    var job = createJobObjectW(nil, nil)
    if job != 0:
      applyKillOnJobClose(job)
      # A granted CPU cap (`runquota run --cap`) becomes a hard Job Object
      # CPU-rate ceiling on the whole tree.
      if spec.cpuRateCapMilli > 0'u32:
        applyCpuRateCap(job, spec.cpuRateCapMilli)
      # Enforcement below admission, the switchable layer: when job-priority
      # enforcement is on, the whole tree is forced to its group's priority
      # class (idle for a reclaimed grant), a Job Object limit no child can
      # escape.
      #
      # THE CLASS IS READ AT THE LAST INSTANT, right here before the limit is
      # set, through the same `GroupPrioritySource` the Linux weight uses
      # (`cgroupPriority`): a `session set --priority` that lands between the
      # placement decision and this call is seen, not overwritten by the
      # stale class. On a read failure (the daemon could not answer under the
      # client's bound) the class keeps `spec.jobPriorityClass`, the fallback
      # resolved at placement from the priority last known, and the launch
      # still proceeds -- as the Linux weight write does. No lock is needed:
      # a single `SetInformationJobObject` call has no critical section a
      # concurrent set can land inside (unlike Linux's prepare-then-write).
      if spec.jobPriorityClass != 0'u32:
        var priorityClass = spec.jobPriorityClass
        var inForce: SessionPriority
        if spec.cgroupPriority.readNow(inForce):
          priorityClass = jobPriorityClassFor(inForce, reclaimed = false)
        applyJobPriorityClass(job, priorityClass)
      elif spec.niceIncrement > 0:
        # A RECLAIMED grant's whole tree runs at a lower scheduling weight,
        # the Windows realization of POSIX `nice`. Previously a per-process
        # `SetPriorityClass` a child could override; now a Job Object
        # PRIORITY-CLASS LIMIT like `jobPriorityClass` above, because the job
        # exists before any process does.
        applyJobPriorityClass(job, BELOW_NORMAL_PRIORITY_CLASS)

    # Windows design of RunQuota-Memory-Caps.md: `kill` mode sets both the
    # hard limit (so an over-cap commit fails immediately) and a
    # notification at the same threshold -- the watcher's actual,
    # guaranteed trigger. `advisory` mode and a lifted run
    # (`memoryCapBytes == 0` with `memoryCapMeasure` asking for it anyway)
    # set neither: `PeakJobMemoryUsed` is readable with no limit at all, so
    # they read it back retrospectively instead (`close`, below).
    var memoryCapThread = 0'u64
    var memoryCapState = 0'u64
    let memoryCapMeasuring = job != 0 and
      (spec.memoryCapBytes > 0 or spec.memoryCapMeasure)
    if job != 0 and spec.memoryCapBytes > 0 and spec.memoryCapAction == mcaKill:
      applyMemoryCapHard(job, spec.memoryCapBytes)
      let watcher = startMemoryCapWatcher(job, spec.memoryCapBytes)
      memoryCapThread = watcher.threadHandle
      memoryCapState = watcher.state

    var created = if job != 0: winCreateProcessInJob(cmdLine, envBlock, cwd, si, job)
                  else: (ok: false, procInfo: PROCESS_INFORMATION())
    if job != 0 and not created.ok:
      # The job itself is fine, but something about placing the child in it
      # at creation was refused (an unexpected environment, not a case this
      # launcher has seen) -- fall back to an ordinary, unplaced launch
      # rather than failing the command outright. Any watcher already
      # started would otherwise be left pointing at a job about to close.
      if memoryCapState != 0:
        discard stopMemoryCapWatcher(memoryCapThread, memoryCapState)
        memoryCapThread = 0
        memoryCapState = 0
      discard closeHandle(job)
      job = 0
    if not created.ok:
      created = winCreateProcessPlain(cmdLine, envBlock, cwd, si)

    # The handles CreateProcess duplicated into the child are this process's
    # own copies of the CHILD-side ends; they must be closed so the pipe's
    # write end (and the NUL read handle) truly closes once the child and
    # everything it spawned have exited, not merely once this process does.
    if spec.stdio != inheritStdio:
      discard closeHandle(stdinHandle)
      discard closeHandle(stdoutWrite)
      discard closeHandle(stderrWrite)
    if envBlock.data != nil:
      dealloc(envBlock.data)

    if not created.ok:
      let err = osLastError()
      if job != 0:
        discard closeHandle(job)
      if spec.stdio != inheritStdio:
        discard closeHandle(stdoutRead)
        discard closeHandle(stderrRead)
      for path in prepared.temporaryFiles:
        try:
          removeFile(path)
        except CatchableError:
          discard
      raiseOSError(err, prepared.argv[0])

    discard closeHandle(created.procInfo.hThread)
    let processId = uint64(created.procInfo.dwProcessId)
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
      telemetrySource: launchTelemetrySource(treeSampling),
      lastTelemetrySampleSeconds: 0.0,
      treeSampling: treeSampling,
      info: LaunchResult(
        processId: processId,
        processGroupId: processId,
        running: true,
        backend: backendProfile(),
        fallbackNice: spec.placementFallbackNice,
        # The cap is in force when the tree is in its Job Object and, in
        # kill mode, the watcher that terminates the job at the cap runs.
        memoryCapApplied: memoryCapMeasuring and
          (spec.memoryCapBytes == 0 or spec.memoryCapAction != mcaKill or
           memoryCapThread != 0'u64),
        memoryCapProblem:
          (if not (spec.memoryCapBytes > 0 or spec.memoryCapMeasure): ""
           elif job == 0: "the tree is in no Job Object"
           elif spec.memoryCapBytes > 0 and spec.memoryCapAction == mcaKill and
               memoryCapThread == 0'u64:
             "the watcher that terminates the job at the cap did not start"
           else: "")
      ),
      winStdoutClosed: spec.stdio == inheritStdio,
      winStderrClosed: spec.stdio == inheritStdio,
      winProcessHandle: uint64(created.procInfo.hProcess),
      winStdoutHandle: (if spec.stdio == inheritStdio: 0'u64
                        else: uint64(stdoutRead)),
      winStderrHandle: (if spec.stdio == inheritStdio: 0'u64
                        else: uint64(stderrRead)),
      winJobHandle: uint64(job),
      winMemoryCapThread: memoryCapThread,
      winMemoryCapState: memoryCapState,
      memoryCapBytes: spec.memoryCapBytes,
      memoryCapAction: spec.memoryCapAction,
      memoryCapMeasuring: memoryCapMeasuring,
      temporaryLaunchFiles: prepared.temporaryFiles
    )

when defined(linux):
  # ---------------------------------------------------------------------------
  # clone3(CLONE_INTO_CGROUP)
  # ---------------------------------------------------------------------------
  #
  # A MEMORY-CAPPED TREE IS CREATED IN ITS LEAF. `clone3` with
  # `CLONE_INTO_CGROUP` and the leaf's directory descriptor puts the child in
  # the leaf from its first instruction, with no migration afterwards: no
  # write into `cgroup.procs`, no handshake, and none of the kernel's cgroup
  # threadgroup lock that a migration takes. `stack` 0 makes it behave like
  # `fork` (the child runs on a copy of the parent's stack); `exit_signal`
  # SIGCHLD makes it waitable like a forked child. clone(2):
  # https://man7.org/linux/man-pages/man2/clone.2.html
  #
  # IT IS A RAW SYSTEM CALL, so the C library's fork handlers do not run:
  # neither `pthread_atfork` handlers nor the library's own bookkeeping
  # (glibc does not, for instance, refresh the thread's cached tid). The
  # child below therefore runs exactly the code the fork path's child runs,
  # which makes only plain system calls and allocates nothing, so it needs
  # none of that. What does rely on the fork handlers is an `LD_PRELOAD`
  # shim that hooks `fork` to follow the tree (a build monitor), which is why
  # a launcher with `LD_PRELOAD` set keeps the ordinary `fork`
  # (`launchProcess`).
  const
    SysClone3 = clong(435)
      ## `__NR_clone3`: the same number on every architecture, from the
      ## unified system call table (Linux 5.3 and later).
    CloneIntoCgroup = 0x200000000'u64
      ## `CLONE_INTO_CGROUP` (Linux 5.7 and later).

  type
    CloneArgs {.pure, final.} = object
      ## `struct clone_args` up to `cgroup` (`CLONE_ARGS_SIZE_VER2`, 88
      ## bytes), every field a `__aligned_u64`.
      flags: uint64
      pidfd: uint64
      childTid: uint64
      parentTid: uint64
      exitSignal: uint64
      stack: uint64
      stackSize: uint64
      tls: uint64
      setTid: uint64
      setTidSize: uint64
      cgroup: uint64

  proc clone3IntoCgroup(leafFd: cint): Pid =
    ## Fork into the cgroup `leafFd` names: the child's pid in the parent,
    ## 0 in the child, -1 with `errno` on failure (ENOSYS / E2BIG before
    ## 5.3, EINVAL before 5.7 or for a bad descriptor, EPERM under a
    ## seccomp filter that refuses it, ENOENT / ENODEV for a removed
    ## cgroup, EBUSY for one that enables controllers for its children).
    var args = CloneArgs(flags: CloneIntoCgroup,
      exitSignal: uint64(SIGCHLD), cgroup: uint64(leafFd))
    Pid(rawSyscall(SysClone3, addr args, csize_t(sizeof(CloneArgs))))

  proc preloadFileSet*(path: string): bool =
    ## Whether `path` (the dynamic linker's `/etc/ld.so.preload`) names
    ## anything: a non-empty file preloads its libraries into every
    ## program, exactly as `LD_PRELOAD` does, so it keeps the fork path for
    ## the same reason. ld.so(8).
    var info: Stat
    stat(cstring(path), info) == 0 and info.st_size > 0

  var systemPreloadState: int
    ## 0 not read yet, 1 no system preload, 2 set: `/etc/ld.so.preload` is
    ## looked at once per process, not once per launch.

  proc systemPreloadSet(): bool =
    var state = atomicLoadN(addr systemPreloadState, ATOMIC_ACQUIRE)
    if state == 0:
      state = if preloadFileSet("/etc/ld.so.preload"): 2 else: 1
      atomicStoreN(addr systemPreloadState, state, ATOMIC_RELEASE)
    state == 2

  proc clone3FallsBack(code: cint): bool =
    ## The `clone3` failures after which the ordinary fork and the child's
    ## own write into the leaf still work: everything except a leaf that
    ## vanished, which is prepared again instead.
    code != ENOENT and code != ENODEV

  var memoryLeafSequence: int
    ## The `<n>` of the `cap-<pid>-<n>` leaves this process creates for
    ## memory-capped trees. Process-wide and atomic: a build engine
    ## launches from several threads.

  proc nextMemoryLeafSequence(): int =
    atomicInc(memoryLeafSequence)

  proc openJoinPipes(statusPipe, verdictPipe: var array[0..1, cint]): bool =
    ## The two pipes of the fork path's placement handshake, or none.
    if createControlPipe(statusPipe):
      if createControlPipe(verdictPipe):
        return true
      discard posix.close(statusPipe[0])
      discard posix.close(statusPipe[1])
      statusPipe = [cint(-1), cint(-1)]
    false

  proc readPlacementByte(fd: cint; value: var uint8): bool =
    ## One byte of the placement handshake; false at end of input (the
    ## other side closed or died) or on an error.
    while true:
      let got = posix.read(fd, addr value, 1)
      if got == 1: return true
      if got < 0 and errno == EINTR: continue
      return false

  proc writePlacementByte(fd: cint; value: uint8) =
    var byteValue = value
    while true:
      let put = posix.write(fd, addr byteValue, 1)
      if put == 1 or not (put < 0 and errno == EINTR): return

proc launchProcess*(spec: CommandSpec): LaunchedProcess =
  when defined(posix):
    if spec.argv.len == 0:
      raise newException(ValueError, "empty argv")
    # THE LAUNCHER'S OWN SWITCH, read from this process's environment and
    # never from `spec.env`: the measurement is taken here, by the client,
    # and the child's environment is the child's business.
    let measurements = clientMeasurements()
    let treeSampling = measureTreeSampling in measurements
    # PROFILES ONLY WHERE THE TREE CAN BE READ. On Linux the launcher reads
    # its own descendants from `/proc`, on macOS through libproc
    # (`proc_listchildpids`, `proc_pid_rusage`); elsewhere nothing here can,
    # so the switch is inert rather than producing a profile of the root
    # alone.
    let profiles = measureProfiles in measurements and
      (defined(linux) or defined(macosx))
    # SIZING DATA ON LINUX AND MACOS: the memory profile needs the tree
    # reader (`/proc` on Linux, libproc on macOS; both sum the resident set
    # over the tree) and the IO counters are the reaping `wait4`'s block
    # counts on Linux and `proc_pid_rusage` on macOS (the root's own bytes
    # there). Inert
    # elsewhere.
    let sizingData = measureSizingData in measurements and
      (defined(linux) or defined(macosx))

    # Everything the child needs between fork and exec is composed here, while
    # there is still a whole process to compose it in. After the fork the child
    # may only read what is already built.
    let childEnv = childEnvEntries(spec.env, spec.inheritEnv, spec.unsetEnv)
    let program = resolveProgram(spec.argv[0], execSearchPath(childEnv))
    let shellArgv = shellFallbackArgv(program, spec.argv)
    let execFailureText = execFailurePrefix(program, spec.argv, childEnv)

    var stdoutPipe = [cint(-1), cint(-1)]
    var stderrPipe = [cint(-1), cint(-1)]
    # Close-on-exec from birth: these are runquota's own control descriptors,
    # and a concurrent lease's child must never inherit them. The kernel drops
    # them at `execve` at no per-launch cost.
    if spec.stdio == captureStdio:
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
    # THE CHILD WRITES ITSELF INTO ITS CGROUP when the spec names one
    # (Linux), right after an ordinary `fork` and before it does anything
    # else, so no descendant can start outside the leaf. An ordinary fork
    # keeps libc's fork handlers, which LD_PRELOAD shims that hook fork and
    # execve rely on. The parent opens the leaf's `cgroup.procs` before the
    # fork; the child writes "0" (itself) to it and reports the result on a
    # pipe, then waits for the parent's verdict. If the leaf vanished in
    # between (another launcher's clean-up removed it: ENOENT / ENODEV), the
    # parent prepares it again and moves the waiting child itself, at most
    # `PlacementAttempts` times. Any other failure leaves the child unplaced,
    # and it then takes `placementFallbackNice`. Every variable the child
    # touches is declared here, so the child runs no destructor (no `free`
    # between fork and exec).
    var pid: Pid = -1
    var inCgroup = false
    var placementProblem = ""
    var joining = false
    var procsFd: cint = -1
    var statusPipe = [cint(-1), cint(-1)]
    var verdictPipe = [cint(-1), cint(-1)]
    # The root's SHARED lock, from preparing the leaf until the child is in
    # it: no other launcher's clean-up can remove the leaf in between
    # (`lockCgroupRoot`). Released before this launch's own clean-up below.
    var rootLock: cint = -1
    # The target and the fallback nice may still change below (the priority
    # in force, read under the lock), so the launch works on its own copies.
    var target = spec.cgroup
    var fallbackNiceWanted = spec.placementFallbackNice
    # THE MEMORY CAP (Linux): a tree with a cap, or one only measured by the
    # cap's mechanism (`memoryCapMeasure`), gets a leaf of its own with the
    # cap's limits (`memoryCapTarget`), is spawned into it by `clone3`, and
    # is classified from the leaf's counters after its root is reaped. None
    # of it can fail the launch: what could not be done is reported in
    # `memoryCapProblem`, and the tree runs without it.
    let memoryWanted = spec.memoryCapBytes > 0'u64 or spec.memoryCapMeasure
    var memoryStage = mcsClassify
    var memoryPrep: MemoryPreparation
    var memoryCapApplied = false
    var memoryCapProblem = ""
    var memoryStageProblem = ""
      ## The gate-only stage variable's complaint, kept apart so that a
      ## later preparation's own report does not erase it.
    var memoryClassify = false
    var useClone3 = false
    var spawnedByClone3 = false
    var leafFd: cint = -1
    var leafProblem = ""
    var leafVanished = false
    var cloneErrno: cint = 0
    var againTarget = CgroupTarget()
    var againRetryable = false
    when defined(linux):
      if memoryWanted and not target.placed:
        memoryCapProblem = "no cgroup root"
      if memoryWanted and target.placed:
        # The gate-only stage, read once per launch from the LAUNCHER's own
        # environment and only for a capped tree, so an uncapped launch
        # reads nothing it did not read before.
        let stageText = getEnv(MemoryCapStageEnvVar)
        if not parseMemoryCapStage(stageText, memoryStage):
          memoryStageProblem = MemoryCapStageEnvVar & "='" & stageText &
            "' is not controller, leaf, limits or classify; the whole " &
            "mechanism applies"
        target = memoryCapTarget(target, spec.memoryCapBytes,
          spec.memoryCapAction, memoryStage, getCurrentProcessId(),
          nextMemoryLeafSequence())
      # A CAP LEAF HOLDS ONE TREE (`CgroupTarget.freshLeaf`), a CPU-capped
      # one too: its leaf is created by this launch, never found.
      if target.isCapLeaf:
        target.freshLeaf = true
        # A launch that creates a cap leaf first removes the empty cap
        # leaves of launchers that died before their clean-up, in the
        # directory it caps into: a memory-only cap leaf has no other
        # sweep, and it would stay for good. It is the only sweep: the
        # launcher libraries above leave it to this launch.
        sweepStaleCapLeaves(target)
      if target.placed:
        rootLock = lockCgroupRoot(target.root, exclusive = false)
        # THE PRIORITY IS READ UNDER THE SHARED LOCK, and the weight below is
        # written before the lock is released: a `session set --priority`
        # rewrites the weight only under the exclusive lock, after the daemon
        # took its change, so it either lands after this launch's write or
        # this read already sees its priority (`lockCgroupRoot`).
        var inForce: SessionPriority
        if spec.cgroupPriority.readNow(inForce):
          target.cpuWeight = cpuWeightFor(inForce)
          fallbackNiceWanted = fallbackNice(inForce, reclaimed = false)
        var tries = 0
        var renames = 0
        var retryable = false
        while tries < PlacementAttempts:
          inc tries
          procsFd = openPreparedProcs(target, placementProblem, retryable,
            memoryPrep)
          if procsFd < 0 and memoryPrep.leafTaken and
              renames < CapLeafNameAttempts:
            # The cap leaf's name is in use (a leftover of an earlier
            # process with this pid, or another launch's): another name,
            # which is not one of the vanished-leaf attempts.
            inc renames
            dec tries
            target.leafName = capLeafName(getCurrentProcessId(),
              nextMemoryLeafSequence())
            continue
          if procsFd >= 0 or not retryable:
            break
          # Preparing again: a leaf this attempt created is still this
          # launch's own, and is reused under its name, not renamed.
          if memoryPrep.leafCreated:
            target.freshLeaf = false
        if procsFd >= 0 and target.memory:
          memoryCapApplied = memoryPrep.limits
          if memoryPrep.problem.len > 0:
            memoryCapProblem = memoryPrep.problem
          memoryClassify = memoryStage >= mcsClassify and memoryPrep.limits
          # CLONE3 FROM THE `limits` STAGE ON, INTO A LEAF OF ITS OWN. Not
          # when this launcher runs with `LD_PRELOAD` set, or with a
          # non-empty `/etc/ld.so.preload` (the same preload, host-wide):
          # a shim that hooks
          # `fork` (a build monitor following the tree) relies on the C
          # library's fork handlers, which the raw `clone3` skips. The fork
          # path below puts the child in the same leaf before it executes
          # anything, so the cap is the same either way.
          useClone3 = memoryStage >= mcsLimits and target.freshLeaf and
            getEnv("LD_PRELOAD").len == 0 and not systemPreloadSet()
        if procsFd >= 0 and useClone3:
          leafFd = openLeafDir(target, leafProblem, leafVanished)
        if procsFd >= 0 and leafFd < 0:
          if openJoinPipes(statusPipe, verdictPipe):
            joining = true
          else:
            placementProblem = "cannot create the cgroup placement pipes"
            discard posix.close(procsFd)
            procsFd = -1
    else:
      if target.placed:
        placementProblem = "cgroup placement is implemented on Linux only"
    # macOS: THE TIER IS READ AT THE LAST INSTANT, right before the fork, the
    # same read the Linux weight takes under its lock and the Windows class
    # takes before its Job Object call: a `session set --priority` that
    # landed since the placement was decided is seen, not overwritten. The
    # tier resolved at placement is the fallback when the daemon cannot
    # answer. A reclaimed tree is background whatever its group and reads
    # nothing (`cgroupPriority` is unset for it).
    var qosTierWanted = when defined(macosx): spec.qosTier else: QosTierNone
    when defined(macosx):
      if qosTierWanted != QosTierNone:
        var inForce: SessionPriority
        if spec.cgroupPriority.readNow(inForce):
          qosTierWanted = qosTierFor(inForce, reclaimed = false)
    when defined(linux):
      if leafFd >= 0:
        # Into the leaf by `clone3`. The child returns here with 0 and
        # leaves the loop at once; every variable it touches was declared
        # above, so it runs no destructor (no `free` between the clone and
        # the exec).
        var cloneTries = 0
        while true:
          inc cloneTries
          pid = clone3IntoCgroup(leafFd)
          if pid >= 0:
            spawnedByClone3 = true
            # In the child too: a plain assignment, no allocation (the
            # retry's failure text, if any, is the parent's to drop).
            break
          cloneErrno = errno
          discard posix.close(leafFd)
          leafFd = -1
          if clone3FallsBack(cloneErrno) or cloneTries >= PlacementAttempts:
            break
          # The leaf vanished (the root's lock could not be taken, and
          # another launcher's clean-up removed it): prepare it again, under
          # its own name, and clone again.
          discard posix.close(procsFd)
          againTarget = target
          againTarget.freshLeaf = false
          procsFd = openPreparedProcs(againTarget, placementProblem,
            againRetryable, memoryPrep)
          if procsFd < 0:
            break
          memoryCapApplied = memoryPrep.limits
          memoryCapProblem = memoryPrep.problem
          memoryClassify = memoryStage >= mcsClassify and memoryPrep.limits
          leafFd = openLeafDir(target, leafProblem, leafVanished)
          if leafFd < 0:
            break
        if not spawnedByClone3 and procsFd >= 0:
          # The ordinary fork and the child's own write into the leaf.
          if openJoinPipes(statusPipe, verdictPipe):
            joining = true
          else:
            placementProblem = "cannot create the cgroup placement pipes"
            discard posix.close(procsFd)
            procsFd = -1
      if spawnedByClone3:
        inCgroup = true
    if not spawnedByClone3:
      pid = fork()
    when defined(linux):
      if pid == 0 and joining:
        # The child: one write, one report, one wait. Allocation-free.
        # It first closes the parent's ends: holding the verdict pipe's
        # write end itself, the child would never see end-of-input on it
        # and would wait forever, never executing, if the parent died
        # before it answered.
        discard posix.close(statusPipe[0])
        discard posix.close(verdictPipe[1])
        var status = 0'u8
        if posix.write(procsFd, cstring("0"), 1) != 1:
          status = uint8(max(1, min(int(errno), 255)))
        writePlacementByte(statusPipe[1], status)
        var verdict = 1'u8
        if readPlacementByte(verdictPipe[0], verdict) and verdict == 0'u8:
          inCgroup = true
    if pid == 0:
      if spec.stdio == captureStdio:
        discard close(stdoutPipe[0])
        discard close(stderrPipe[0])
      if spec.createProcessGroup and setpgid(0, 0) != 0:
        childExit(126)
      # A child that is not in its cgroup takes the weaker stand-in for the
      # lower weight the cgroup would have given it.
      let niceWanted =
        if inCgroup: spec.niceIncrement
        else: max(spec.niceIncrement, fallbackNiceWanted)
      when defined(macosx):
        # The priority policy of the macOS layer (`qos_priority`), applied in
        # the child by plain system calls before the `execve`, so it is
        # inherited by every process of the tree and the C library's fork
        # handlers have run. A call that fails leaves the child at its
        # inherited policy: the grant is still within what admission
        # predicted, so failing the launch would cost the work for nothing.
        if qosTierWanted == QosTierBackground:
          discard darwinSetpriority(PRIO_DARWIN_PROCESS, 0, PRIO_DARWIN_BG)
      if niceWanted > 0:
        # Async-signal-safe in effect (two syscalls, no allocation). A nice
        # that fails leaves the child at its inherited weight: the grant is
        # still within what admission predicted, so failing the launch
        # would cost the work for nothing.
        discard posix.nice(cint(niceWanted))
      if spec.cwd.len > 0 and chdir(cstring(spec.cwd)) != 0:
        childExit(126)
      if spec.stdio == captureStdio:
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
      # Still here, so the program was never started. Say why on the child's
      # own stderr -- the stream the caller already captures -- before the 127.
      childReportExecFailure(cstring(execFailureText), errno)
      childExit(127)
    when defined(linux):
      if spawnedByClone3 and pid > 0:
        # A retry that succeeded leaves no problem behind.
        placementProblem = ""
        memoryCapProblem = memoryPrep.problem
      if spawnedByClone3:
        # The child was created in its leaf; nothing to hand over.
        discard posix.close(leafFd)
        leafFd = -1
        discard posix.close(procsFd)
        procsFd = -1
      if joining:
        # The parent's half of the handshake (see above).
        discard posix.close(procsFd)
        discard posix.close(statusPipe[1])
        discard posix.close(verdictPipe[0])
        if pid > 0:
          var status = 0'u8
          var verdict = 1'u8
          let leaf = target.leafPath
          if not readPlacementByte(statusPipe[0], status):
            placementProblem = "the child ended before it joined " & leaf
          elif status == 0'u8:
            verdict = 0'u8
          elif cint(status) == ENOENT or cint(status) == ENODEV:
            var tries = 1
            placementProblem = "cgroup " & leaf & " vanished before the " &
              "child joined it"
            while tries < PlacementAttempts:
              inc tries
              if moveIntoTarget(target, int(pid), placementProblem,
                  memoryPrep):
                verdict = 0'u8
                # The leaf was prepared again: what is on it now.
                if target.memory:
                  memoryCapApplied = memoryPrep.limits
                  memoryCapProblem = memoryPrep.problem
                  memoryClassify = memoryStage >= mcsClassify and
                    memoryPrep.limits
                break
          else:
            placementProblem = "the child could not join " & leaf & ": " &
              $strerror(cint(status))
          if verdict == 0'u8:
            inCgroup = true
            placementProblem = ""
          writePlacementByte(verdictPipe[1], verdict)
        discard posix.close(statusPipe[0])
        discard posix.close(verdictPipe[1])
      # The child is in its leaf (or will not be): the leaf may go now.
      unlockCgroupRoot(rootLock)
      rootLock = -1
    if pid < 0:
      if spec.stdio == captureStdio:
        discard close(stdoutPipe[0])
        discard close(stdoutPipe[1])
        discard close(stderrPipe[0])
        discard close(stderrPipe[1])
      # Nothing was started: take away the leaf (and an empty group
      # directory) this launch prepared, which would otherwise stay.
      if target.placed:
        releaseTarget(target)
      raise newException(OSError, "fork failed")

    if spec.stdio == captureStdio:
      discard close(stdoutPipe[1])
      discard close(stderrPipe[1])
      setNonblock(int(stdoutPipe[0]))
      setNonblock(int(stderrPipe[0]))
    if spec.createProcessGroup:
      discard setpgid(pid, pid)
    let pgid = if spec.createProcessGroup: int(pid) else: int(getpgid(pid))
    var placedTarget = CgroupTarget()
    var placedLeaf = ""
    if inCgroup:
      placedTarget = target
      placedLeaf = target.leafPath
    elif target.placed:
      # Directories a failed attempt prepared are left empty; take them away
      # unless another tree is in them.
      releaseTarget(target)
      if memoryWanted:
        memoryCapApplied = false
        memoryClassify = false
        memoryCapProblem = "the tree is not in a cgroup (" &
          placementProblem & ")"
    # macOS judges the cap itself, from its own readings of the tree
    # (`runquota_process/memory_cap_watch`); Linux's cap is the tree's cgroup leaf
    # and Windows's its Job Object, so neither reads the tree for it. The
    # tracker is opened at once, so it watches the root before the child's
    # command can fork (whatever the child forked before it, the tracker's
    # first list finds).
    var memoryCap = MemoryCapWatch()
    when defined(macosx):
      memoryCap = initMemoryCapWatch(spec.memoryCapBytes,
        spec.memoryCapAction, spec.memoryCapMeasure)
      if memoryCap.active:
        memoryCap.ownGroup = spec.createProcessGroup
        memoryCap.tracker = openMacosTreeTracker(uint64(pid))
        if memoryCap.tracker.isOpen and
            readMacosTreeMember(int32(pid), memoryCap.root):
          memoryCap.applied = true
        else:
          memoryCap.problem = "the macOS tree tracker could not be armed: " &
            (if memoryCap.tracker.problem.len > 0: memoryCap.tracker.problem
             else: "the root could not be read")
          close(memoryCap.tracker)
    var sampler = initCpuProfileSampler()
    if profiles or sizingData:
      # The profile's clock starts at 0, the launch.
      sampler.start(0'i64)
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
      telemetrySource: launchTelemetrySource(treeSampling),
      lastTelemetrySampleSeconds: 0.0,
      treeSampling: treeSampling,
      profiles: profiles,
      sizingData: sizingData,
      profileSampler: sampler,
      launchMonoMillis: getMonoTime().ticks div 1_000_000,
      info: LaunchResult(
        processId: uint64(pid),
        processGroupId: uint64(max(pgid, 0)),
        running: true,
        backend: backendProfile(),
        cgroupPath: placedLeaf,
        cgroupProblem: placementProblem,
        fallbackNice: fallbackNiceWanted,
        qosTier: qosTierWanted,
        spawnedByClone3: spawnedByClone3,
        # macOS arms its own tracker; Linux's cap is the cgroup leaf.
        memoryCapApplied:
          (when defined(macosx): memoryCap.applied else: memoryCapApplied),
        memoryCapProblem:
          (when defined(macosx): memoryCap.problem
           elif defined(linux):
             (if memoryStageProblem.len == 0: memoryCapProblem
              elif memoryCapProblem.len == 0: memoryStageProblem
              else: memoryStageProblem & "; " & memoryCapProblem)
           else: memoryCapProblem)
      ),
      cgroupTarget: placedTarget,
      memoryCap: memoryCap,
      memoryCapBytes: spec.memoryCapBytes,
      memoryCapAction: spec.memoryCapAction,
      memoryCapWanted: memoryWanted,
      memoryClassify: memoryClassify
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
    if not child.runningFlag or child.winProcessHandle == 0:
      return false
    winProcessRunning(Handle(child.winProcessHandle))
  else:
    false

when defined(linux):
  proc classifyMemoryCap(child: LaunchedProcess;
                         completion: var ProcessCompletion) =
    ## The memory-cap half of a completion: the leaf's own counters, read
    ## ONCE, here, after the root was reaped and before `close` removes the
    ## leaf. Nothing polls them while the tree runs. The kernel counts an
    ## OOM kill when it kills, before the killed process can be reaped, so
    ## the counts are complete for every kill that ended the root.
    completion.memoryCapBytes = child.memoryCapBytes
    if not child.memoryCapWanted:
      return
    if not child.memoryClassify:
      completion.memoryCapProblem =
        if child.info.memoryCapProblem.len > 0: child.info.memoryCapProblem
        else: "the tree was not measured by its leaf (stage " &
          "below classify, or no leaf of its own)"
      return
    var events: MemoryEvents
    var peak = 0'u64
    var peakKnown = false
    var problem = ""
    if not readLeafMemory(child.cgroupTarget, events, peak, peakKnown,
        problem):
      completion.memoryCapProblem = problem
      return
    # Without `memory.peak` (before 5.19) the events still classify the
    # end; the peak stays unknown (`mpsNone`), and `problem` says why.
    completion.memoryCapProblem = problem
    # KILL EVIDENCE: the root died of a signal, or exited non-zero (a
    # parent that reported its child's kill). A tree whose root exited 0
    # has its own conclusion whatever the counters say.
    let killEvidence = completion.signaled or
      (completion.exited and completion.exitCode != 0)
    let verdict = memoryCapVerdict(events, peak, child.memoryCapBytes,
      child.memoryCapAction, killEvidence)
    completion.memoryCapMeasured = true
    completion.memoryPeakBytes = peak
    completion.memoryPeakSource = if peakKnown: mpsCgroup else: mpsNone
    completion.capExceeded = verdict.capExceeded
    completion.capKilled = verdict.capKilled
    completion.capReached = verdict.capReached
    completion.oomKilledOutsideCap = verdict.oomKilledOutsideCap

proc buildCompletion(child: LaunchedProcess; timedOut: bool): ProcessCompletion =
  when defined(posix):
    result = buildCompletion(
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
    when defined(linux):
      classifyMemoryCap(child, result)
    else:
      result.memoryCapBytes = child.memoryCapBytes
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
    # The tree's CPU totals from Job Object accounting (`readJobAccounting`,
    # stored on the child before this is built). The Job Object sums every
    # descendant, so these are the whole tree's figures, not the leader's
    # alone -- the same contract the POSIX `rusage` totals carry.
    if child.rusageKnown:
      result.totals = FinishTotals(known: true,
        cpuUserMicros: child.rusageUserMicros,
        cpuSysMicros: child.rusageSysMicros,
        maxRssBytes: child.peakResidentMemoryBytes,
        majorPageFaults: 0'u64,
        durationMillis: result.elapsedMillis)
    if not timedOut and child.waitStatus >= 0:
      result.exited = true
      result.exitCode = child.waitStatus
    # The memory-cap mechanism (`finalizeMemoryCap`, called at the done
    # transition before this): a capped or measured launch reports its cap,
    # the mechanism's own peak and whether it was killed or merely passed
    # the cap. An unmeasured launch leaves every field at its zero value,
    # which `breached`-style readers already treat as "nothing to report".
    if child.memoryCapMeasuring:
      result.memoryCapMeasured = true
      result.memoryPeakBytes = child.memoryPeakBytesMeasured
      result.memoryPeakSource = mpsJob
      result.memoryCapBytes = child.memoryCapBytes
      if child.memoryCapBytes > 0:
        # A kill IS passing the cap, even though the watcher's own
        # notification margin (`MemoryCapNotifyMarginMilli`) means the
        # measured peak at the moment of the kill can read a little under
        # `memoryCapBytes` -- the numeric comparison alone would then miss
        # it, which `capKilled` on its own never does.
        let exceeded = child.memoryCapKilled or
          child.memoryPeakBytesMeasured >= child.memoryCapBytes
        result.capExceeded = exceeded
        result.capKilled = child.memoryCapKilled
        if exceeded and child.memoryCapAction == mcaKill and
            not child.memoryCapKilled:
          # The hard limit refused a commit before the watcher's
          # notification was handled: nothing was killed, but the cap was
          # reached.
          result.capReached = true
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
      # A TREE SAMPLE ONLY WHEN ONE IS DUE: one interval after the launch,
      # then one interval after the previous sample, however often the
      # caller polls (every 10 ms in `waitForCompletion`, as often as an
      # engine likes through `pollCompletion`). Not at the first poll, which
      # comes right after the fork: the tree is then the launcher's own
      # forked image, not yet the command, and a command that exits inside
      # the first interval is covered by `ru_maxrss` from the totals, which
      # the daemon takes as the peak when no sample is larger.
      let treeDue = child.treeSampling and
        now - max(child.lastTelemetrySampleSeconds, child.startedSeconds) >=
          treeSampleIntervalSeconds
      # ONE READING OF THE TREE SERVES BOTH MEASUREMENTS when both are due;
      # the profile's own reading comes once per profile interval (1 s,
      # doubling as the run lengthens), so with tree sampling off a profile
      # costs one walk of the tree per interval and nothing in between.
      let sinceLaunch = getMonoTime().ticks div 1_000_000 -
        child.launchMonoMillis
      let profileDue = (child.profiles or child.sizingData) and
        child.profileSampler.due(sinceLaunch)
      # A CAPPED TREE IS READ AT THE SAME CADENCE, on the same rule (not at
      # the first poll, then once per interval), from its tracker: kernel
      # events keep its members, so a reading is one footprint read per
      # member and no search for them.
      let capDue = child.memoryCap.active and
        now - max(child.memoryCap.lastReadingSeconds, child.startedSeconds) >=
          MemoryCapIntervalSeconds
      when defined(macosx):
        if capDue:
          child.memoryCap.lastReadingSeconds = now
          var footprint, highWater: uint64
          var members: uint32
          if readMacosTrackedFootprint(child.memoryCap.tracker, footprint,
                                       highWater, members) and
              child.memoryCap.observe(footprint, highWater) and
              child.memoryCap.action == mcaKill:
            # The first reading over the cap, under `mcaKill`: freeze and
            # kill exactly this tree now. The root is reaped below as
            # always, and its signal is the kill's evidence.
            discard killMacosTree(child.memoryCap.root,
              (if child.memoryCap.ownGroup: child.processGroupId else: 0),
              trackedMembers(child.memoryCap.tracker))
            child.memoryCap.killed = true
      if treeDue or profileDue:
        inc child.treeWalks
        let sample =
          when defined(linux):
            sampleLinuxProcessTreeTelemetry(uint64(child.pid))
          else:
            sampleMacosProcessTreeTelemetry(uint64(child.pid))
        if treeDue:
          child.lastTelemetrySampleSeconds = now
          child.telemetrySource = sample.source
          if sample.diagnostic.code == diagOk:
            if sample.residentMemoryBytes > child.peakResidentMemoryBytes:
              child.peakResidentMemoryBytes = sample.residentMemoryBytes
            if sample.processCount > child.processCount:
              child.processCount = sample.processCount
        if (child.profiles or child.sizingData) and
            sample.diagnostic.code == diagOk and sample.cumulativeCpuKnown:
          child.profileSampler.observe(sinceLaunch,
            sample.cumulativeCpuTimeMicros, sample.residentMemoryBytes)
        # A JOB'S PEAK IS ITS TREE'S SUM. With `sizing-data` on, every walk
        # the memory profile takes also raises the finish's peak, so sizing
        # sees four 1-GiB processes running together as 4 GiB even with
        # `tree-sampling` off (whose own walks do the same).
        if child.sizingData and sample.diagnostic.code == diagOk and
            sample.residentMemoryBytes > child.peakResidentMemoryBytes:
          child.peakResidentMemoryBytes = sample.residentMemoryBytes
      var status: cint = 0
      let waited = child.reapChild(status, WNOHANG)
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
    # child doesn't stall us), and ask the kernel whether the process has
    # exited. When it has, keep draining until both pipes reach end of input
    # or the lingering-drain grace expires, then populate `child.completion`.
    if child.completion.exited or child.completion.signaled or
        child.completion.timedOut:
      return true
    if child.winProcessHandle == 0:
      return false
    let processHandle = Handle(child.winProcessHandle)

    # Windows: sample RSS / process count before draining so even a very
    # short-lived child gets at least one snapshot while still alive.
    if not child.doneFlag:
      winSampleTelemetry(child)
    winDrainOutput(child)

    if not child.doneFlag:
      if not winProcessRunning(processHandle):
        child.doneFlag = true
        child.runningFlag = false
        child.doneSeconds = epochTime()
        child.waitStatus = winProcessExitCode(processHandle)
        # Windows: one final telemetry snapshot, taken once.
        winSampleTelemetry(child, force = true)
        winDrainOutput(child)

    if child.doneFlag:
      # Gated on the leased process having exited, NOT on its pipes reaching
      # end of input -- see `winOutputSettled`. Until then the caller polls
      # again, exactly as the POSIX arm does.
      if not child.winOutputSettled():
        return false
      if child.winJobHandle != 0:
        var userMicros = 0'u64
        var kernelMicros = 0'u64
        var jobProcessCount = 0'u32
        readJobAccounting(Handle(child.winJobHandle), userMicros, kernelMicros,
          jobProcessCount)
        child.rusageKnown = true
        child.rusageUserMicros = userMicros
        child.rusageSysMicros = kernelMicros
        # Windows: prefer the Job Object's TotalProcesses (counts every process
        # the tree ever spawned) over the live toolhelp32 count.
        if jobProcessCount > child.processCount:
          child.processCount = jobProcessCount
      finalizeMemoryCap(child)
      child.completion = child.buildCompletion(timedOut = false)
      if child.completion.processCount == 0:
        child.completion.processCount = 1
      return true
    false
  else:
    raise newException(OSError, "runquota_process is only implemented on POSIX")

when defined(windows):
  proc winTerminateLeader(child: LaunchedProcess) =
    ## The fallback when the child is in no Job Object: terminate the leader
    ## alone, with the same exit code a job termination gives. NOT
    ## `osproc.terminate`, which calls `TerminateProcess(handle, 0)` -- a
    ## cancelled child reported as a clean exit 0, which is the one pair
    ## `KillEvidence` exists to make unstatable.
    const ProcessTerminate = 0x0001'i32
    if child.pid <= 0:
      return
    let handle = openProcess(ProcessTerminate, 0'i32, int32(child.pid))
    if handle != 0:
      discard terminateProcess(handle, int(windowsCancelledExitCode))
      discard closeHandle(handle)

  proc jobActiveProcesses(job: Handle): int32 =
    ## How many processes are still alive in `job`. `ActiveProcesses` is a live
    ## count (unlike `TotalProcesses`, which only grows), so this reads 0 once
    ## the tree is gone.
    var info: JobBasicAndIoAccountingW
    var ret: int32 = 0
    if queryInformationJobObject(job, JobObjectBasicAndIoAccountingInformation,
        addr info, int32(sizeof(JobBasicAndIoAccountingW)), addr ret) != 0:
      result = info.BasicInfo.ActiveProcesses

proc endJobLeftovers*(child: LaunchedProcess;
                      exitCode = windowsCancelledExitCode): bool =
  ## Ends what the command left running in its Job Object once the command's
  ## own process has been waited for. The Job Object holds every descendant
  ## the tree spawned (nothing breaks away), so a build tool whose recipes
  ## outlived it is still a live member here; if any member is alive the whole
  ## job is terminated. Answers whether anything was left. The Windows analog
  ## of the POSIX process-group leftover sweep.
  ##
  ## THERE IS NO SIGTERM-THEN-GRACE-THEN-SIGKILL on Windows: `TerminateJobObject`
  ## is unconditional, so there is no gentle phase to wait out and no grace
  ## period to honour -- a POSIX-style delay here would accomplish nothing, so
  ## there is none. (`close` would also reap the tree through
  ## `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`; this makes the sweep observable and
  ## bounds it to the leftovers rather than to releasing handles.)
  when defined(windows):
    if child.winJobHandle == 0:
      return false
    if jobActiveProcesses(Handle(child.winJobHandle)) <= 0:
      return false
    result = true
    discard terminateJobObject(Handle(child.winJobHandle), exitCode)
  else:
    discard child
    discard exitCode
    false

proc terminate*(child: var LaunchedProcess) =
  when defined(posix):
    child.cancelSent = true
    if child.processGroupId > 0:
      discard kill(Pid(-child.processGroupId), SIGTERM)
    elif child.pid > 0:
      discard kill(Pid(child.pid), SIGTERM)
  elif defined(windows):
    # Windows: terminate the whole tree by terminating its Job Object. If the
    # job handle is missing (job creation or placement failed), fall back to
    # terminating the primary process directly.
    child.cancelSent = true
    if child.winJobHandle != 0:
      discard terminateJobObject(Handle(child.winJobHandle),
        windowsCancelledExitCode)
    else:
      winTerminateLeader(child)

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
      discard terminateJobObject(Handle(child.winJobHandle),
        windowsCancelledExitCode)
    else:
      winTerminateLeader(child)

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
          let waited = child.reapChild(status, WNOHANG)
          if waited == Pid(child.pid):
            child.doneFlag = true
            child.runningFlag = false
            child.waitStatus = int(status)
            break
          sleep(10)
        if not child.doneFlag:
          child.killNow()
          var status: cint = 0
          # A blocking wait can be interrupted by a signal before the
          # killed root is reaped; retry, or the root is left a zombie and
          # the totals are lost. Any other failure (ECHILD: already reaped
          # elsewhere) leaves the totals unknown, never zero.
          while child.reapChild(status, 0) < 0 and errno == EINTR:
            discard
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
    # (which drains the bounded stdout and stderr buffers, samples Job Object /
    # toolhelp32 telemetry, and detects exit) until the child finishes or the
    # deadline elapses.
    if child.winProcessHandle == 0:
      raise newException(OSError, "runquota_process: missing Windows process handle")
    let processHandle = Handle(child.winProcessHandle)
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
          winDrainOutput(child)
          if not winProcessRunning(processHandle):
            child.doneFlag = true
            child.runningFlag = false
            child.waitStatus = winProcessExitCode(processHandle)
            break
          sleep(10)
        if not child.doneFlag:
          child.killNow()
          discard waitForSingleObject(processHandle, 1000'i32)
          child.waitStatus = winProcessExitCode(processHandle)
          child.doneFlag = true
          child.runningFlag = false
        # Windows: final telemetry + output drain, plus Job Object accounting.
        # The drain is bounded like the ordinary completion path's: the Job
        # Object took the whole tree down, so the pipes normally close at
        # once, but nothing here may wait on a write end it cannot see.
        winSampleTelemetry(child, force = true)
        child.doneSeconds = epochTime()
        while true:
          winDrainOutput(child)
          if child.winOutputSettled():
            break
          sleep(5)
        if child.winJobHandle != 0:
          var userMicros = 0'u64
          var kernelMicros = 0'u64
          var jobProcessCount = 0'u32
          readJobAccounting(Handle(child.winJobHandle), userMicros,
            kernelMicros, jobProcessCount)
          child.rusageKnown = true
          child.rusageUserMicros = userMicros
          child.rusageSysMicros = kernelMicros
          if jobProcessCount > child.processCount:
            child.processCount = jobProcessCount
        finalizeMemoryCap(child)
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
    # The tree's leaf and its group directory go when empty; a tree that
    # left a process behind keeps them until that process ends (a later
    # launch of the group, or of a cap, removes them then).
    when defined(linux):
      # AFTER A GROUP KILL, the kernel has killed every process of the leaf
      # but the ones other than the root may still be exiting when the root
      # is reaped. Wait for them, briefly and only then, so the leaf is not
      # left behind. Outside the root's lock: nothing else uses a cap leaf.
      if child.cgroupTarget.isCapLeaf and (child.completion.capKilled or
          child.completion.oomKilledOutsideCap):
        discard waitUntilEmpty(child.cgroupTarget.leafPath,
          GroupKillSettleMillis)
    releaseTarget(child.cgroupTarget)
    child.cgroupTarget = CgroupTarget()
    close(child.memoryCap.tracker)
  elif defined(windows):
    # Windows: release the process and pipe handles, then let the Job Object
    # close. With JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE set, closing the last
    # handle reaps any straggler processes in the tree.
    #
    # A watcher not already stopped by `finalizeMemoryCap` (the caller
    # closed without ever calling `waitForCompletion`/`pollCompletion`
    # through to done) is stopped here instead, so it is never leaked.
    if child.winMemoryCapState != 0:
      discard stopMemoryCapWatcher(child.winMemoryCapThread,
        child.winMemoryCapState)
      child.winMemoryCapThread = 0
      child.winMemoryCapState = 0
    if child.winProcessHandle != 0:
      discard closeHandle(Handle(child.winProcessHandle))
      child.winProcessHandle = 0
    if child.winStdoutHandle != 0:
      discard closeHandle(Handle(child.winStdoutHandle))
      child.winStdoutHandle = 0
    if child.winStderrHandle != 0:
      discard closeHandle(Handle(child.winStderrHandle))
      child.winStderrHandle = 0
    if child.winJobHandle != 0:
      discard closeHandle(Handle(child.winJobHandle))
      child.winJobHandle = 0
    for path in child.temporaryLaunchFiles:
      try:
        removeFile(path)
      except CatchableError:
        discard
    child.temporaryLaunchFiles.setLen(0)

proc finishSizing*(completion: ProcessCompletion): FinishSizing =
  ## The sizing figures a finish carries for this completion: the memory
  ## profile and the IO bytes when the launch took them (`sizing-data`),
  ## absent otherwise. ``after`` is the caller's to declare: only a client
  ## that knows its graph can.
  FinishSizing(memoryProfile: completion.memoryProfile, io: completion.io,
    afterKnown: false, afterLeases: @[])
