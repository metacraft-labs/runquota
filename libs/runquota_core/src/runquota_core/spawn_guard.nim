## Serialised child-process creation, so two threads spawning at the same
## moment cannot take each other's pipes.
##
## ``runquota_core/fd_hygiene`` states RunQuota's rule: a descriptor RunQuota
## holds is created close-on-exec, so no child inherits it. ``std/osproc`` does
## not follow that rule and cannot be told to. ``startProcess`` creates the
## three parent-side pipes with a plain ``pipe(2)`` -- Darwin has no ``pipe2``
## and osproc does not ``fcntl`` them afterwards -- and hands them to
## ``posix_spawn``, whose file actions close only the descriptors belonging to
## that one call. A pipe another thread created moments earlier is still
## inheritable, and the new child gets it.
##
## The consequence is a hang, not a leak. A child holding the write end of
## another child's stdin keeps that child from ever seeing end of input, so it
## never exits. A child holding the write end of another child's stdout keeps
## the reading parent from ever seeing EOF. Two threads spawning at the same
## instant take each other's descriptors and both block in ``read(2)`` for as
## long as the process lives -- no timeout expires, because nothing is waiting
## on a timer.
##
## This is not a theoretical window. Two threads in a spawn loop reproduce it
## within seconds, and ``lsof`` on the wedged pair shows each child holding all
## three of the other's pipes.
##
## Two mechanisms, because neither covers the other's case:
##
## * ``withSpawnGuard`` serialises the interval inside ``startProcess`` during
##   which the descriptors exist and are still inheritable. It binds only the
##   spawners that take it.
## * ``protectSpawnedPipes`` marks the parent-side descriptors close-on-exec
##   the instant ``startProcess`` returns them, so that every *later* spawn
##   anywhere in the process -- including from code that knows nothing about
##   the guard -- cannot inherit them.
##
## The guard is held across process creation only, never while a child runs,
## so a slow child cannot keep another thread from spawning.
##
## WHY THIS LIVES IN ``runquota_core``. The lock only works if it is *one*
## lock for the whole process. Every RunQuota spawner has to be able to reach
## it, and the spawners sit in libraries that do not depend on one another --
## the observation store, the estimate store, the macOS host backend. Only the
## base library is below all of them. It is deliberately not re-exported from
## the ``runquota_core`` umbrella: that module is a static-helper entry point
## and has no business pulling ``osproc`` and a global lock into every consumer
## that only wanted the shared types.

import std/[locks, osproc]

import ./fd_hygiene

var spawnLock: Lock
spawnLock.initLock()

template withSpawnGuard*(body: untyped) =
  ## Run ``body`` -- which should be a ``startProcess`` call and nothing more
  ## expensive -- with no other guarded spawn in flight.
  acquire(spawnLock)
  try:
    body
  finally:
    release(spawnLock)

proc protectSpawnedPipes*(process: Process) =
  ## Mark the parent-side pipe descriptors of ``process`` close-on-exec.
  ##
  ## Standard descriptors are skipped. Under ``poParentStreams`` osproc
  ## reports 0, 1 and 2 here, and marking this process's own stdio
  ## close-on-exec would break every child it later launches.
  when defined(posix):
    for handle in [process.inputHandle, process.outputHandle,
                   process.errorHandle]:
      if handle.cint > 2:
        setCloseOnExec(handle.cint)
  else:
    discard
