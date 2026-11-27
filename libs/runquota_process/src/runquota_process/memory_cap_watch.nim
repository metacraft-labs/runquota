## A launcher's memory cap on the tree it starts, the part that is measured
## and judged by the launcher itself: macOS, where no public, unprivileged
## interface lets a process limit the memory of another (measured on macOS
## 26.5.1: `task_set_phys_footprint_limit` on the caller's own task answers
## `KERN_NO_ACCESS` without privilege).
##
## WHAT IS MEASURED. The tree's physical footprint, the figure the kernel
## charges each process for its memory, compressed pages included
## (`ri_phys_footprint` of `proc_pid_rusage`). The tree is kept by kernel
## events (`runquota_host_macos/process_tracker`: kqueue `NOTE_FORK` /
## `NOTE_EXIT`), not re-discovered by ancestry at every reading, which would
## cost one host-wide scan per member. Each reading yields two figures:
##
## * the SUM of the live processes' footprints, a peak of the tree at that
##   instant; and
## * the largest LIFETIME HIGH-WATER MARK of any one process
##   (`ri_lifetime_max_phys_footprint`), which the kernel keeps for each
##   process, so a single process's peak between two readings is never
##   missed. It is read once more from the root's zombie at its exit.
##
## The tree's peak is the larger of the two. Both are lower bounds of the
## true peak of the tree: what a poll can miss is a moment when several
## processes peaked together between two readings. A high-water mark is never
## summed across processes, because two processes' marks may come from
## different moments, and a sum of them could report a breach that never
## happened.
##
## THE JUDGEMENT. The tree exceeded its cap when either reading is above it.
## Both readings are things that really happened: a summed footprint above the
## cap is the tree over the cap at that instant, and one process's mark above
## the cap is that process alone over it. So the judgement makes no false
## breach. It can miss a short breach of the sum.
##
## THE ACTION. `mcaAdvisory` records the breach and kills nothing.
## `mcaKill` kills the tree at the first reading above the cap
## (`killMacosTree`): first FROZEN, so that no process of it can fork a new
## one while it is being killed, then killed.
##
## Static-helper library rules apply (no `ref` types).

import std/[hashes, sets]

when defined(posix):
  import std/posix

import runquota_core/memory_cap
import runquota_host_macos

type
  MemoryCapWatch* = object
    ## The launcher's state for one tree's cap: what it read and what it
    ## concluded. Zero-valued (`active` false) when the launch has no cap and
    ## measures no peak.
    active*: bool
      ## The launcher reads the tree's footprint while it waits.
    capBytes*: uint64
      ## The cap; 0 = none (only measured: `memoryCapMeasure`).
    action*: MemoryCapAction
    peakBytes*: uint64
      ## The largest of every summed footprint and every single process's
      ## high-water mark read so far.
    exceeded*: bool
      ## A reading was above the cap.
    killed*: bool
      ## The launcher killed the tree for it (`mcaKill`).
    rootPeakRead*: bool
      ## The root's high-water mark was read from its zombie.
    readings*: uint32
      ## How many times the tree's footprint was read: the cost of the
      ## mechanism is this count times one walk.
    lastReadingSeconds*: float
    tracker*: MacosTreeTracker
      ## The tree's members, kept by kernel events (macOS).
    root*: MacosTreeMember
      ## The root as it was at the launch: the identity the kill checks.
    ownGroup*: bool
      ## The launch made the tree a process group of its own, so the kill may
      ## signal the group. False when the tree shares the caller's group.
    applied*: bool
      ## The tracker was armed: the cap is in force.
    problem*: string
      ## Why the cap is not in force, else "".
    killedAfterRootExit*: int
      ## Processes still alive after the root's exit, killed because the
      ## breach was first seen at that exit (`mcaKill`).

const
  MemoryCapIntervalSeconds* = 0.1
    ## How often a capped launch reads its tree: the `tree-sampling`
    ## cadence, so that with both on one walk serves both.

proc initMemoryCapWatch*(capBytes: uint64; action: MemoryCapAction;
                         measure: bool): MemoryCapWatch =
  ## The watch for a launch with `capBytes` (0 = none) and `action`; active
  ## when there is a cap or the peak is to be measured anyway (`measure`: a
  ## run whose cap was lifted still records its peak).
  MemoryCapWatch(active: capBytes > 0'u64 or measure, capBytes: capBytes,
    action: action)

proc over(watch: MemoryCapWatch; bytes: uint64): bool {.inline.} =
  watch.capBytes > 0'u64 and bytes > watch.capBytes

proc observe*(watch: var MemoryCapWatch; footprintSumBytes,
              maxProcessFootprintBytes: uint64): bool =
  ## Take one reading of the tree: the summed footprint of its live
  ## processes and the largest one-process high-water mark among them.
  ## True when this reading is the FIRST above the cap, which is when a
  ## killing launcher must act. Never true without a cap.
  inc watch.readings
  watch.peakBytes = max(watch.peakBytes,
    max(footprintSumBytes, maxProcessFootprintBytes))
  if not watch.exceeded and (watch.over(footprintSumBytes) or
      watch.over(maxProcessFootprintBytes)):
    watch.exceeded = true
    return true
  false

proc observeExitedRoot*(watch: var MemoryCapWatch; lifetimeMaxBytes: uint64) =
  ## The root's high-water mark, read from its zombie at its exit: its own
  ## peak, however short, even when the root exited before any reading.
  watch.rootPeakRead = true
  watch.peakBytes = max(watch.peakBytes, lifetimeMaxBytes)
  if watch.over(lifetimeMaxBytes):
    watch.exceeded = true

const
  FreezeRounds = 64
    ## A bound on the freeze's re-walks: each round stops every process the
    ## previous one had not seen, so a tree that is no longer growing is
    ## frozen in two rounds; the bound only keeps a pathological tree from
    ## holding the launcher.

proc hash*(member: MacosTreeMember): Hash =
  !$(hash(member.pid) !& hash(member.startSeconds) !&
    hash(member.startMicroseconds))

when defined(posix):
  proc signalMember(member: MacosTreeMember; signal: cint): bool =
    ## Signal `member` only while its pid is still the process the walk
    ## found (same start time), so a reused pid is never signalled.
    if not stillMacosTreeMember(member):
      return false
    kill(Pid(member.pid), signal) == 0

proc killMacosTree*(root: MacosTreeMember; processGroupId: int;
                    tracked: openArray[MacosTreeMember] = []): int =
  ## Kill exactly the tree of `root`: its process group when the launch made
  ## it (`processGroupId` > 0, and never the caller's own group), the members
  ## the tracker kept (`tracked`, which include processes re-parented away
  ## from the root), and every process found below any of them by ancestry.
  ## Returns the number of processes stopped.
  ##
  ## FREEZE, THEN KILL. A process being killed can still fork for as long as
  ## it runs, and a child forked after the walk that found its parent would
  ## escape. So every process is first stopped (`SIGSTOP`, which cannot be
  ## caught or ignored): the group in one call, then each process the walk
  ## finds, re-walking until a walk finds no process it has not stopped.
  ## A stopped tree cannot grow, so the last walk is all of it. Then the
  ## group and every process found get `SIGKILL`.
  ##
  ## THE GROUP ONLY WHEN IT IS THE TREE'S OWN. A launch that did not create
  ## a process group shares the CALLER's (the launcher's, and its shell
  ## job's), and stopping that group would stop the launcher itself before it
  ## could send the kill. So `processGroupId` must be 0 for such a launch,
  ## and a group equal to the caller's own is refused here as well.
  ##
  ## IDENTITIES ARE THE ONES RECORDED WHEN EACH PROCESS WAS FOUND. A process
  ## is signalled, and walked from, only while its pid still names that
  ## process (`stillMacosTreeMember`). What cannot be reached is a process
  ## that left both the group and the tracker's sight before it was found;
  ## nothing public on macOS names it.
  when defined(macosx):
    var group = processGroupId
    if group > 0 and Pid(group) == getpgrp():
      group = 0
    if group > 0:
      discard kill(Pid(-group), SIGSTOP)
    var stopped = initHashSet[MacosTreeMember]()
    var order: seq[MacosTreeMember]
    var roots = @[root]
    for member in tracked:
      if member != root:
        roots.add(member)
    for member in roots:
      # The tracked members themselves, before any walk.
      if member notin stopped and signalMember(member, SIGSTOP):
        stopped.incl(member)
        order.add(member)
    for _ in 0 ..< FreezeRounds:
      var grew = false
      for start in roots:
        if not stillMacosTreeMember(start):
          continue
        for member in macosTreeMembers(uint64(start.pid)):
          if member notin stopped:
            discard signalMember(member, SIGSTOP)
            stopped.incl(member)
            order.add(member)
            grew = true
      # Walk next round from everything stopped so far: a stopped process's
      # children are found from it even once its parent is gone.
      roots = order
      if not grew:
        break
    if group > 0:
      discard kill(Pid(-group), SIGKILL)
    for member in order:
      discard signalMember(member, SIGKILL)
    order.len
  else:
    discard root
    discard processGroupId
    discard tracked
    0
