## WHO THE CHILD OF A ``supervisor_lost`` LEASE IS, and whether it is still
## there.
##
## A pid alone does not name a process for longer than that process lives.
## Windows hands a freed pid to the next ``CreateProcess`` almost at once, and
## Linux and macOS wrap theirs on a busy host, so "is pid N alive?" asked hours
## after the lease was lost answers a question about SOME process, not about
## the child. Answered for the wrong process it strands the reservation for
## the daemon's whole lifetime -- the reaper keeps it because a stranger now
## wears the child's pid -- which is exactly the leak this module exists to
## close. The identity is therefore the PAIR (pid, start stamp):
##
## * Windows: the process creation time from ``GetProcessTimes``, in 100 ns
##   FILETIME units.
##   https://learn.microsoft.com/windows/win32/api/processthreadsapi/nf-processthreadsapi-getprocesstimes
## * Linux / macOS: ``shm_lease/anchor.processStartTime`` -- ``starttime``
##   from ``/proc/<pid>/stat`` (clock ticks since boot) and
##   ``kp_proc.p_starttime`` from ``sysctl(KERN_PROC_PID)`` respectively. The
##   same anchor the shared-memory reaper uses, so the two reapers agree on
##   what "the same process" means.
##
## WHY CAPTURING THE STAMP AT ``LeaseRunning`` IS RACE-FREE. The supervising
## client reports ``LeaseRunning`` for a child it launched and has not yet
## waited on: on Windows it still holds the handle ``CreateProcess`` returned,
## and a process object that is still referenced keeps its pid out of
## circulation; on POSIX an exited-but-unwaited child is a zombie, which holds
## its pid (and its ``/proc`` entry) until its parent reaps it. Either way the
## pid in the frame names the child, or its corpse, at the moment the daemon
## reads the stamp -- never a successor.
##
## THE DIRECTION OF EVERY UNCERTAINTY IS "ALIVE". A stamp that cannot be read
## (a protected process, a platform without the interface) is recorded as 0,
## which means UNKNOWN and is never taken to match or to differ; a process that
## exists but cannot be queried is alive. Releasing a reservation a live
## process still consumes hands the same CPU and memory to a second tenant,
## which is the one outcome worse than holding it.
##
## This is identity, not supervision: the daemon never waits on, signals, or
## enumerates the child's tree (`AGENTS.md`, "Boundaries"). It asks the kernel
## two questions about one pid, and only for a lease whose supervisor is gone.

when defined(windows):
  import std/winlean
elif defined(linux) or defined(macosx):
  import std/posix
  from shm_lease/anchor import processStartTime
elif defined(posix):
  import std/posix

type
  ChildVerdict* = enum
    ## Why a lost lease's child was judged gone or present. Reported rather
    ## than collapsed to a bool so a test -- or a later diagnostic -- can say
    ## WHICH check fired.
    cvNoChild    ## pid 0: the lease never reported ``LeaseRunning``
    cvExited     ## the pid no longer names a live process
    cvPidReused  ## the pid is live, but its start stamp is not the child's
    cvAlive      ## the child is still running, or existence is unsettled

proc childGone*(verdict: ChildVerdict): bool =
  ## True when the reservation can be released: nothing that the lease
  ## launched is still consuming it.
  verdict in {cvNoChild, cvExited, cvPidReused}

when defined(windows):
  const
    Synchronize = 0x0010_0000'i32
    ProcessQueryLimitedInformation = 0x1000'i32
    WaitObject0 = 0'i32
    StillActive = 259'i32
    # "No such process": what `OpenProcess` reports for a pid that names
    # nothing. winlean carries ERROR_ACCESS_DENIED but not this one.
    ErrorInvalidParameter = 87'i32

  proc creationStamp(handle: Handle): uint64 =
    ## The process creation FILETIME as one integer, or 0 when unreadable.
    var creation, exitTime, kernelTime, userTime: FILETIME
    if getProcessTimes(handle, creation, exitTime, kernelTime, userTime) == 0:
      return 0'u64
    (uint64(cast[uint32](creation.dwHighDateTime)) shl 32) or
      uint64(cast[uint32](creation.dwLowDateTime))

  proc openForIdentity(processId: uint64; synchronize: var bool): Handle =
    ## Opens ``processId`` with the smallest access that answers both
    ## questions. SYNCHRONIZE is preferred -- a zero-timeout wait is the
    ## exact "has it exited?" test, where an exit code of 259 is not -- but
    ## a process this account may query without being allowed to wait on is
    ## still answerable through ``GetExitCodeProcess``, so that is the
    ## fallback rather than giving up.
    ## PROCESS_QUERY_LIMITED_INFORMATION is the right-sized right: it is
    ## granted for processes this user may not fully open, so a child that
    ## dropped privileges is still identifiable.
    synchronize = true
    # Windows pids are DWORDs; the wire carries a u64 for every platform.
    # Wider values name nothing, and `DWORD(...)` would raise on them.
    if processId > uint64(high(uint32)):
      return Handle(0)
    let pid = cast[DWORD](uint32(processId))
    result = openProcess(Synchronize or ProcessQueryLimitedInformation,
      WINBOOL(0), pid)
    if result == Handle(0) and getLastError() != ErrorInvalidParameter:
      synchronize = false
      result = openProcess(ProcessQueryLimitedInformation, WINBOOL(0), pid)

proc processStartStamp*(processId: uint64): uint64 =
  ## The start stamp of the process ``processId`` names right now, or 0 when
  ## it cannot be read. Only ever compared with another stamp read on the same
  ## host and boot, so the unit is the platform's own.
  if processId == 0'u64:
    return 0'u64
  when defined(windows):
    var synchronize = false
    let handle = openForIdentity(processId, synchronize)
    if handle == Handle(0):
      return 0'u64
    defer: discard closeHandle(handle)
    creationStamp(handle)
  elif defined(linux) or defined(macosx):
    if processId > uint64(high(int32)):
      return 0'u64
    processStartTime(int(processId))
  else:
    0'u64

proc childVerdict*(processId, recordedStartStamp: uint64): ChildVerdict =
  ## Is the child a lost lease recorded at ``LeaseRunning`` still running?
  ##
  ## ``recordedStartStamp`` is the stamp ``processStartStamp`` read when the
  ## lease reported the child; 0 means it could not be read then, and the
  ## verdict falls back to pid existence alone -- the weaker judgement, and
  ## stated as such rather than assumed.
  if processId == 0'u64:
    return cvNoChild
  when defined(windows):
    if processId > uint64(high(uint32)):
      return cvExited
    var synchronize = false
    let handle = openForIdentity(processId, synchronize)
    if handle == Handle(0):
      # Cannot open: either the pid names nothing, or it names a process
      # this account may not query at all. Only the first is evidence.
      if getLastError() == ErrorInvalidParameter:
        return cvExited
      return cvAlive
    defer: discard closeHandle(handle)
    # A process object outlives its process while anyone holds a handle to
    # it, so an open that succeeds is not yet proof of life.
    if synchronize:
      if waitForSingleObject(handle, 0'i32) == WaitObject0:
        return cvExited
    else:
      var code: int32 = 0
      if getExitCodeProcess(handle, code) != 0 and code != StillActive:
        return cvExited
    let current = creationStamp(handle)
    if recordedStartStamp != 0'u64 and current != 0'u64 and
        current != recordedStartStamp:
      return cvPidReused
    cvAlive
  elif defined(posix):
    if processId > uint64(high(int32)):
      # Not a pid this kernel could have handed out; `kill` would see it
      # truncated and answer about somebody else.
      return cvExited
    # Signal 0 performs the permission and existence checks without
    # delivering anything. EPERM proves existence just as well as success.
    if kill(Pid(processId), 0) != 0 and errno != EPERM:
      return cvExited
    let current = processStartStamp(processId)
    if recordedStartStamp != 0'u64 and current != 0'u64 and
        current != recordedStartStamp:
      return cvPidReused
    cvAlive
  else:
    cvAlive
