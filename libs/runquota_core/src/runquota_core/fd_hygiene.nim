## POSIX descriptor hygiene shared by RunQuota's IPC and process layers.
##
## RunQuota launches leased commands underneath reproducibility monitors. Any
## descriptor RunQuota itself holds -- the daemon socket a session is talking
## over, another lease's stdout pipe -- that survives into a leased child is
## classified by those monitors as opaque external content, because the
## producing endpoint sits outside the monitored action tree. So RunQuota's own
## descriptors must not reach a leased child.
##
## The cheap way to guarantee that is to never make them inheritable in the
## first place: create them close-on-exec and the kernel drops them at
## ``execve`` for free, with no per-launch work at all. ``setCloseOnExec`` is
## the retrofit for the descriptors that cannot be *created* that way -- Darwin
## has no ``pipe2``, and ``std/net`` gives no way to pass ``SOCK_CLOEXEC`` --
## and it still costs one ``fcntl`` at creation rather than anything per launch.
##
## Sweeping descriptors closed between fork and exec is a backstop for
## descriptors RunQuota did not open (a build tool that invoked ``runquota``
## while holding its own files open), not the primary mechanism. That backstop
## lives in ``runquota_process`` because it may only use async-signal-safe
## calls; everything here runs in an ordinary parent-process context.

when defined(posix):
  import std/posix

  proc setCloseOnExec*(fd: cint): bool {.discardable.} =
    ## Mark ``fd`` close-on-exec. Returns false if the descriptor is invalid or
    ## the kernel refused; callers treat that as non-fatal because the
    ## between-fork-and-exec backstop still covers the descriptor.
    if fd < 0:
      return false
    let flags = fcntl(fd, F_GETFD)
    if flags < 0:
      return false
    fcntl(fd, F_SETFD, flags or FD_CLOEXEC) >= 0

  proc isCloseOnExec*(fd: cint): bool =
    ## Whether ``fd`` will be dropped by the kernel at ``execve``. Tests assert
    ## on this so "our descriptors are CLOEXEC at birth" is a checked property
    ## rather than a claim in a comment.
    if fd < 0:
      return false
    let flags = fcntl(fd, F_GETFD)
    flags >= 0 and (flags and FD_CLOEXEC) != 0
