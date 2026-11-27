## A launcher's running record of the processes of one tree on macOS, kept
## by kernel events instead of re-discovered at every reading.
##
## WHY NOT THE ANCESTRY WALK. Finding a tree by ancestry calls
## `proc_listchildpids` once per member, and that call scans every process on
## the host: measured on macOS 26.5.1 with 1765 processes, 19.75 us a call,
## against 0.43 us for the `proc_pid_rusage` that reads the member's memory.
## So a walk of a 64-process tree costs about 1.4 ms, nearly all of it
## spent finding again members that rarely change.
##
## HOW. Each member is watched with a kqueue `EVFILT_PROC` knote for
## `NOTE_FORK` and `NOTE_EXIT` (kqueue(2); public, and it works for any
## process of the same user, not only a child: measured). A reading drains
## the queue once, re-lists the children only of the members that forked
## since the last reading, drops the members that exited, and reads each
## remaining member's memory. Forks coalesce (`EV_CLEAR`: five forks were
## one event, measured), which is enough, because an event only says "list
## this process's children again".
##
## REGISTER, THEN LIST. A new member is watched before its children are
## listed, so a fork it made before the knote existed is still found by the
## list, and a fork after it raises an event. The root is added right after
## the launch the same way. What no event or list can find is a process
## forked by a member that exits before the next reading: its children are
## re-parented to launchd by the time the list runs, so a short-lived
## intermediate's orphans are lost (as they are to the ancestry walk).
##
## WHAT IT KEEPS THAT THE WALK DOES NOT. A member is tracked by pid, not by
## ancestry, so a process whose parent exited (re-parented to launchd, or
## left by `setsid` and a double fork after it was found) stays in the tree.
##
## IDENTITY. Each member is recorded with its start time when it is found,
## and a reading whose `ri_proc_start_abstime` differs drops it: the pid
## now names another process. Stale members are dropped BEFORE new ones are
## adopted, so a pid reused by a new process of the tree is adopted as that
## process. The kill is given the identities recorded when each member was
## found, never ones read again at kill time.
##
## MEMBERSHIP, NOT ANCESTRY, IS WHAT IS CHARGED. A server a build step
## starts to outlive the build (`setsid` and a double fork) stays a member
## and is charged to the cap and killed with the tree. That is deliberate,
## and it is what a Linux cgroup leaf and a Windows Job Object do too: both
## are membership, not ancestry.
##
## The kqueue is not inherited by a child created with `fork` (kqueue(2)),
## and its descriptor is close-on-exec. Static-helper library rules apply (no
## `ref` types).

import std/sets

when defined(macosx):
  import std/posix

import runquota_host_macos/process_telemetry

const
  MaxTrackedProcesses* = 65536
    ## A bound on one tree, so a fork bomb cannot make the record unbounded.
  EventsPerDrain = 64
  MaxDrainCalls = 16
    ## A bound on one reading's drain: a tree whose members fork faster than
    ## the launcher drains could otherwise hold it in the drain for as long
    ## as the storm lasts. What is left is drained at the next reading.

when defined(macosx):
  type
    KEvent {.importc: "struct kevent", header: "<sys/event.h>",
             bycopy.} = object
      ident {.importc.}: uint
      filter {.importc.}: int16
      flags {.importc.}: uint16
      fflags {.importc.}: uint32
      data {.importc.}: int
      udata {.importc.}: pointer

    RusageInfoV4Start {.importc: "struct rusage_info_v4",
                        header: "<sys/resource.h>", bycopy.} = object
      ri_phys_footprint {.importc.}: uint64
      ri_proc_start_abstime {.importc.}: uint64
      ri_lifetime_max_phys_footprint {.importc.}: uint64

  var
    EVFILT_PROC {.importc, header: "<sys/event.h>".}: int16
    EV_ADD {.importc, header: "<sys/event.h>".}: uint16
    EV_CLEAR {.importc, header: "<sys/event.h>".}: uint16
    EV_ERROR {.importc, header: "<sys/event.h>".}: uint16
    NOTE_FORK {.importc, header: "<sys/event.h>".}: uint32
    NOTE_EXIT {.importc, header: "<sys/event.h>".}: uint32

  proc kqueue(): cint {.importc, header: "<sys/event.h>".}
  proc kevent(kq: cint; changelist: ptr KEvent; nchanges: cint;
              eventlist: ptr KEvent; nevents: cint;
              timeout: ptr Timespec): cint {.importc, header: "<sys/event.h>".}
  proc procListChildPidsRaw(parent: int32; buffer: pointer;
                            bufferSize: cint): cint {.
    importc: "proc_listchildpids", header: "<libproc.h>".}
  proc procPidRusageRaw(pid: cint; flavor: cint; buffer: pointer): cint {.
    importc: "proc_pid_rusage", header: "<libproc.h>".}

type
  TrackedProcess = object
    pid: int32
    startAbsTime: uint64
      ## `ri_proc_start_abstime` when it was found: its identity for readings.
    identity: MacosTreeMember
      ## Its pid and BSD start time when it was found: its identity for the
      ## kill (`stillMacosTreeMember`).

  MacosTreeTracker* = object
    ## The record of one tree. Zero-valued (`kq` = -1 after `close`, or 0
    ## never opened) is an inert tracker that reads nothing.
    kq: cint
    opened: bool
    members: seq[TrackedProcess]
    present: HashSet[int32]
      ## The members' pids, for constant-time membership.
    problem*: string
      ## Why the tracker could not be opened, else "".
    relists*: uint32
      ## How many times a member's children were listed: the event-driven
      ## part of the cost (the walk paid this once per member per reading).
    readings*: uint32

when defined(macosx):
  proc startOf(pid: int32; start, footprint, lifetimeMax: var uint64): bool =
    var usage: RusageInfoV4Start
    if procPidRusageRaw(cint(pid), 4.cint, addr usage) != 0.cint:
      return false
    start = usage.ri_proc_start_abstime
    footprint = usage.ri_phys_footprint
    lifetimeMax = usage.ri_lifetime_max_phys_footprint
    true

  proc watch(tracker: var MacosTreeTracker; pid: int32): bool =
    var change = KEvent(ident: uint(pid), filter: EVFILT_PROC,
      flags: EV_ADD or EV_CLEAR, fflags: NOTE_FORK or NOTE_EXIT)
    kevent(tracker.kq, addr change, 1, nil, 0, nil) == 0

  proc listChildren(parent: int32; children: var seq[int32]) =
    var capacity = 32
    for _ in 0 ..< 8:
      var pids = newSeq[int32](capacity)
      let count = procListChildPidsRaw(parent, addr pids[0],
        cint(pids.len * sizeof(int32)))
      if count < 0:
        return
      if int(count) < capacity:
        for index in 0 ..< int(count):
          if pids[index] > 0:
            children.add(pids[index])
        return
      capacity *= 4

  proc addTo(total: var uint64; value: uint64) {.inline.} =
    if value > high(uint64) - total: total = high(uint64)
    else: total += value

  proc adopt(tracker: var MacosTreeTracker; pid: int32;
             footprintBytes, maxProcessFootprintBytes: var uint64) =
    ## Add `pid` and, transitively, every descendant it already has: each
    ## one watched BEFORE its children are listed. Each new member's memory
    ## is read here and added to the reading in progress.
    var pending = @[pid]
    while pending.len > 0 and tracker.members.len < MaxTrackedProcesses:
      let next = pending.pop()
      if next in tracker.present:
        continue
      if not tracker.watch(next):
        continue          # gone already (ESRCH): not a member
      var start, footprint, lifetimeMax: uint64
      var identity: MacosTreeMember
      if not startOf(next, start, footprint, lifetimeMax) or
          not readMacosTreeMember(next, identity):
        continue
      tracker.members.add(TrackedProcess(pid: next, startAbsTime: start,
        identity: identity))
      tracker.present.incl(next)
      footprintBytes.addTo(footprint)
      maxProcessFootprintBytes = max(maxProcessFootprintBytes, lifetimeMax)
      inc tracker.relists
      var children: seq[int32]
      listChildren(next, children)
      for child in children:
        if child notin tracker.present:
          pending.add(child)

proc openMacosTreeTracker*(rootProcessId: uint64): MacosTreeTracker =
  ## The record of the tree under `rootProcessId`, opened right after the
  ## launch: the root watched, then whatever it has already forked. A
  ## tracker that could not be opened says why in `problem`; the launcher
  ## then reports the cap as not applied.
  when defined(macosx):
    if rootProcessId == 0'u64 or rootProcessId > uint64(high(int32)):
      result.problem = "root process id is outside the Darwin PID range"
      return
    result.kq = kqueue()
    if result.kq < 0:
      result.problem = "kqueue() failed: " & $strerror(errno)
      return
    discard fcntl(result.kq, F_SETFD, FD_CLOEXEC)
    result.opened = true
    var footprint, highWater: uint64
    result.adopt(int32(rootProcessId), footprint, highWater)
    if result.members.len == 0:
      result.problem = "the root process could not be watched"
  else:
    discard rootProcessId
    result.problem = "the tree tracker is macOS's"

proc close*(tracker: var MacosTreeTracker) =
  ## Release the kqueue. Idempotent on the same value.
  when defined(macosx):
    if tracker.opened:
      discard posix.close(tracker.kq)
  tracker.opened = false
  tracker.kq = -1
  tracker.members.setLen(0)
  tracker.present.clear()

proc isOpen*(tracker: MacosTreeTracker): bool = tracker.opened

proc readMacosTrackedFootprint*(tracker: var MacosTreeTracker;
                                footprintBytes, maxProcessFootprintBytes:
                                  var uint64;
                                processCount: var uint32): bool =
  ## One reading of the tree: every member's footprint summed and the
  ## largest one-process high-water mark, with the events since the last
  ## reading applied. False when the tracker is not open.
  when defined(macosx):
    footprintBytes = 0
    maxProcessFootprintBytes = 0
    processCount = 0
    if not tracker.opened:
      return false
    inc tracker.readings
    # 1. Drain the events (bounded): which members forked.
    var forked = initHashSet[int32]()
    var events: array[EventsPerDrain, KEvent]
    var zero = Timespec(tv_sec: posix.Time(0), tv_nsec: 0)
    for _ in 0 ..< MaxDrainCalls:
      let count = kevent(tracker.kq, nil, 0, addr events[0],
        cint(EventsPerDrain), addr zero)
      if count <= 0:
        break
      for index in 0 ..< int(count):
        let event = events[index]
        if (event.flags and EV_ERROR) == 0 and
            (event.fflags and NOTE_FORK) != 0 and
            int32(event.ident) in tracker.present:
          forked.incl(int32(event.ident))
      if int(count) < EventsPerDrain:
        break
    # 2. Read every member, and drop the ones that are gone or are no longer
    #    the process that was found. This comes BEFORE adopting, so a pid a
    #    new process of the tree reuses is free to be adopted as it.
    var kept = 0
    for index in 0 ..< tracker.members.len:
      let member = tracker.members[index]
      var start, footprint, lifetimeMax: uint64
      if startOf(member.pid, start, footprint, lifetimeMax) and
          start == member.startAbsTime:
        footprintBytes.addTo(footprint)
        maxProcessFootprintBytes = max(maxProcessFootprintBytes, lifetimeMax)
        tracker.members[kept] = member
        inc kept
      else:
        tracker.present.excl(member.pid)
        forked.excl(member.pid)
    tracker.members.setLen(kept)
    # 3. List again the children of each member that forked, and adopt the
    #    new ones (their memory is added to this reading).
    for forker in forked:
      inc tracker.relists
      var children: seq[int32]
      listChildren(forker, children)
      for child in children:
        tracker.adopt(child, footprintBytes, maxProcessFootprintBytes)
    processCount = uint32(tracker.members.len)
    true
  else:
    discard tracker
    footprintBytes = 0
    maxProcessFootprintBytes = 0
    processCount = 0
    false

proc trackedMembers*(tracker: MacosTreeTracker): seq[MacosTreeMember] =
  ## The members as the last reading left them, each with the identity
  ## recorded WHEN IT WAS FOUND, for the kill to check before it signals.
  for member in tracker.members:
    result.add(member.identity)
