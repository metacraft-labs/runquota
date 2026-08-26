## KERNEL-MAINTAINED counters, for this process and for another one.
##
## PORTED, NOT REINVENTED. The self-process half is a port of
## ``nim-shm-lease``'s ``src/shm_lease/syscount.nim`` -- same
## ``task_info(mach_task_self(), TASK_EVENTS_INFO)`` call, same
## ``0xFFFFFFFFFFFFFFFF``-means-unavailable convention, same reasoning. It is
## copied rather than imported because ``nim-shm-lease`` is not a dependency
## of this repository and M1 must be runnable from a ``runquota`` checkout
## alone. The M8 preemption study's calibration numbers therefore apply to it
## unchanged, and ``runquota_m1_bench`` re-establishes them in-run anyway.
##
## WHAT IS NEW HERE IS THE CROSS-PROCESS HALF, and M1 needs it for a reason
## the shm study did not have: the subject under measurement is a DIFFERENT
## PROCESS -- ``repro`` -- which this repository does not compile and cannot
## instrument. ``proc_pidinfo(pid, PROC_PIDTASKINFO, ...)`` exposes the same
## kernel record (``pti_syscalls_unix``, ``pti_syscalls_mach``, ``pti_csw``)
## for any process of the same uid, with no entitlement and no
## ``task_for_pid``. It returns ``EPERM`` for processes this uid does not own,
## which is the honest failure and is reported rather than swallowed.
##
## A COUNTER READ FROM OUTSIDE CANNOT BE READ AT EXIT. The subject's final
## syscalls happen after the last sample and before the process is reaped, so
## a cross-process total is a LOWER BOUND by however many syscalls fall in
## that window. The bench states the sampling interval so the bound is
## quantified rather than implied.

const syscallCountSupported* = defined(macosx)

when defined(macosx):
  {.emit: """/*TYPESECTION*/
#include <mach/mach.h>
#include <mach/task_info.h>
#include <libproc.h>
#include <errno.h>

/* This task's kernel-maintained UNIX (BSD) syscall count, or
   0xFFFFFFFFFFFFFFFF when task_info is unavailable. Verbatim in behaviour from
   nim-shm-lease's shmLeaseUnixSyscalls. */
static unsigned long long rqM1SelfUnixSyscalls(void) {
  struct task_events_info info;
  mach_msg_type_number_t cnt = TASK_EVENTS_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_EVENTS_INFO, (task_info_t)&info, &cnt)
      != KERN_SUCCESS) {
    return (unsigned long long)-1;
  }
  return (unsigned long long)info.syscalls_unix;
}

/* Another process's counters, from the same kernel record. `which` selects
   0 = syscalls_unix, 1 = syscalls_mach, 2 = context switches. Returns
   0xFFFFFFFFFFFFFFFF when the pid is gone or not readable by this uid. */
static unsigned long long rqM1PidCounter(int pid, int which) {
  struct proc_taskinfo ti;
  int rc = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, sizeof(ti));
  if (rc <= 0) {
    return (unsigned long long)-1;
  }
  switch (which) {
    case 0: return (unsigned long long)ti.pti_syscalls_unix;
    case 1: return (unsigned long long)ti.pti_syscalls_mach;
    case 2: return (unsigned long long)ti.pti_csw;
    default: return (unsigned long long)-1;
  }
}
""".}
  proc rqM1SelfUnixSyscalls(): uint64 {.importc: "rqM1SelfUnixSyscalls",
    nodecl.}
  proc rqM1PidCounter(pid: cint; which: cint): uint64 {.
    importc: "rqM1PidCounter", nodecl.}

  proc syscallCountAvailable*(): bool =
    rqM1SelfUnixSyscalls() != high(uint64)

  proc unixSyscallCount*(): uint64 =
    ## This task's UNIX syscall count. Reading it is a MACH syscall, not a
    ## UNIX one, so bracketing a region with two reads does not perturb the
    ## number being read -- the property the calibration re-establishes.
    let v = rqM1SelfUnixSyscalls()
    if v == high(uint64): 0'u64 else: v

  proc pidUnixSyscallCount*(pid: int): uint64 =
    ## Another process's UNIX syscall count, or ``high(uint64)`` when it
    ## cannot be read. The sentinel is NOT collapsed to zero here: a caller
    ## differencing two samples must be able to tell "the process exited"
    ## from "it made no syscalls".
    rqM1PidCounter(cint(pid), 0)

  proc pidContextSwitches*(pid: int): uint64 =
    rqM1PidCounter(cint(pid), 2)

else:
  proc syscallCountAvailable*(): bool = false
  proc unixSyscallCount*(): uint64 = 0'u64
  proc pidUnixSyscallCount*(pid: int): uint64 = high(uint64)
  proc pidContextSwitches*(pid: int): uint64 = high(uint64)
