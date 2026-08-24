## THE WRITE SIDE of the published aggregate table — `runquotad`'s only.
##
## SEPARATED FROM THE READER ON PURPOSE, and the separation is the enforcement
## mechanism rather than a matter of taste. Two rules the transport spec states
## and this split makes structural:
##
##   * **Single writer.** Only `runquotad` writes the table. There is no
##     ticket, no arbiter and no CAS loop here because there is no
##     multi-producer problem to solve — and there must never be one, so no
##     client-side library may import this module.
##     ``tests/unit/t_stats_table_rules.nim`` scans every source file under
##     ``libs/`` and ``apps/`` and fails if anything outside
##     ``runquota_daemon`` / ``apps/runquotad`` reaches it.
##   * **The daemon MUST NOT read the table back as authority.** It is
##     published output. This module therefore NEVER LOADS A BYTE FROM THE
##     SEGMENT after creating it: slot placement, eviction victims and the
##     per-slot sequence numbers all come from a shadow in the daemon's own
##     private heap (``slotKeys``, ``slotSeq``, ``slotUse``, ``slotTick``).
##     A build in which the segment is zeroed behind the publisher's back
##     therefore changes nothing about what the daemon decides — which is
##     exactly what ``t_stats_table_cache_control.nim`` measures.
##
## ------------------------------------------------------------------------
## THE PUBLISHING ROUND
## ------------------------------------------------------------------------
##
## Rendered as the C11 seqlock (Boehm, MSPC 2012), which is what MV3's
## ``verification/litmus/seqlock-recheck-vs-payload.litmus`` says M13b must be
## written as:
##
## ``` text
##   seq <- s+1   relaxed          (odd: a round is in flight)
##   fence(RELEASE)
##   keyLen, key, payload          relaxed
##   fence(RELEASE)
##   seq <- s+2   relaxed          (even: the round is complete and stable)
## ```
##
## **The counter is a full 64-bit word.** It is never packed beside the key
## hash to save room in a fixed-size entry, which is precisely the saving MV3
## found the protocol cannot survive: on a narrow counter the shipped protocol,
## unmodified, violates ``NoTornRead`` at depth 19 by admitting the seqlock's
## ABA. The saving is real and the protocol it breaks is invisible.
##
## **Eviction is a round like any other.** Rebinding a slot to a different key
## bumps to odd, writes the NEW key and the NEW payload, and bumps to even —
## so key and payload change together. Without that a reader can take a
## perfectly *coherent* snapshot of a slot rebound underneath it and receive
## another key's distribution: nothing about the sequence number detects it,
## no tear occurred, and the consequence is an admission decision made on the
## wrong work's history, which is worse than a miss.

import std/[algorithm, os, posix, strutils, times]

import ./types
export types

from shm_lease/anchor import bootId, processStartTime
from shm_lease/waitword import pageSize

const statsPublisherSupported* = defined(linux) or defined(macosx)

type
  StatsPublisher* = object
    ## The daemon's handle on the segment it publishes into.
    available*: bool
    path*: string
    size*: int
    slotCount*: int
    publishCount*: uint64
    evictionCount*: uint64
    rejectedCount*: uint64
    # --- THE SHADOW, and the reason it exists -----------------------------
    # Everything the publisher needs to know about the table's current
    # contents lives here, in the daemon's private heap, and NOT in the
    # segment. The segment is write-only from this side. See the header.
    slotKeys: seq[string]
    slotSeq: seq[uint64]
    slotUse: seq[uint64]
    slotTick: seq[uint64]
    tick: uint64
    when statsPublisherSupported:
      base: ptr UncheckedArray[byte]
      fd: cint

when statsPublisherSupported:
  type ShmBase = ptr UncheckedArray[byte]

  template atField(base: ShmBase; offset: int; T: typedesc): ptr T =
    cast[ptr T](addr base[offset])

  proc storeU64Relaxed(base: ShmBase; off: int; v: uint64) {.inline.} =
    atomicStoreN(atField(base, off, uint64), v, ATOMIC_RELAXED)
  proc storeU64Release(base: ShmBase; off: int; v: uint64) {.inline.} =
    atomicStoreN(atField(base, off, uint64), v, ATOMIC_RELEASE)
  proc storeU32Relaxed(base: ShmBase; off: int; v: uint32) {.inline.} =
    atomicStoreN(atField(base, off, uint32), v, ATOMIC_RELAXED)
  proc storeU32Release(base: ShmBase; off: int; v: uint32) {.inline.} =
    atomicStoreN(atField(base, off, uint32), v, ATOMIC_RELEASE)
  proc releaseFence() {.inline.} =
    atomicThreadFence(ATOMIC_RELEASE)

proc statsSegmentSize*(slotCount: int): int =
  ## Page-rounded. ``pageSize()`` asks ``sysconf(_SC_PAGESIZE)`` rather than
  ## assuming 4096 — it is 16 KiB on Apple Silicon, the hazard that has bitten
  ## every segment in this campaign at least once.
  let raw = statsSegmentRawSize(slotCount)
  when statsPublisherSupported:
    let ps = pageSize()
    ((raw + ps - 1) div ps) * ps
  else:
    raw

proc createStatsPublisher*(path: string; slotCount = DefaultStatsSlotCount;
                           mode = 0o640): StatsPublisher =
  ## Create + map a fresh table. Never raises: a daemon that cannot publish
  ## keeps serving over the socket, which is the answer of record anyway.
  ##
  ## PUBLISH-BEFORE-WRITE: the segment is built under a unique temp name,
  ## every field is written, the magic is release-stored LAST, and only then
  ## is it renamed into place. A reader that observes the magic has, by that
  ## release, observed everything written before it; a crash before the
  ## rename leaves nothing discoverable.
  ##
  ## ``mode`` defaults to ``0640`` — DAEMON-WRITTEN, GROUP-READABLE, and
  ## deliberately not ``0600``. This is the one structure in the design that
  ## is host-wide rather than per-user: a page no client can write cannot be
  ## used by one user to perturb another, so every user on the host reads the
  ## same table and the zero-IPC estimate is not one account's privilege.
  ## Callers pass ``runquota_ipc.requiredSegmentMode(segmentHostWide)``
  ## rather than a literal.
  result.available = false
  result.path = path
  when statsPublisherSupported:
    result.fd = -1
    if path.len == 0: return
    if slotCount <= 0 or slotCount > MaxStatsSlotCount: return
    if (slotCount and (slotCount - 1)) != 0: return # power of two
    let size = statsSegmentSize(slotCount)
    let boot = bootId()
    try:
      let dir = parentDir(path)
      if dir.len > 0 and not dirExists(dir): return
    except CatchableError: return
    let uniq = int(epochTime() * 1_000_000) mod 1_000_000
    let tmp = path & ".tmp." & $getpid() & "." & $uniq
    discard unlink(tmp.cstring)
    let tfd = open(tmp.cstring, O_RDWR or O_CREAT or O_EXCL, Mode(mode))
    if tfd < 0: return
    # `open` honours the umask, and a table the group cannot read is a table
    # every user but one falls back from -- silently, and looking exactly
    # like a cold cache. Set the mode explicitly.
    if chmod(tmp.cstring, Mode(mode)) != 0:
      discard close(tfd); discard unlink(tmp.cstring); return
    if ftruncate(tfd, Off(size)) != 0:
      discard close(tfd); discard unlink(tmp.cstring); return
    let p = mmap(nil, size, PROT_READ or PROT_WRITE, MAP_SHARED, tfd, 0)
    if p == MAP_FAILED:
      discard close(tfd); discard unlink(tmp.cstring); return
    let base = cast[ShmBase](p)
    storeU32Relaxed(base, StatsOffFlags, 0)
    storeU64Relaxed(base, StatsOffSlotCount, uint64(slotCount))
    storeU64Relaxed(base, StatsOffEntryStride, uint64(StatsEntryStride))
    storeU64Relaxed(base, StatsOffEntriesOff, uint64(StatsEntriesOff))
    storeU64Relaxed(base, StatsOffSegmentSize, uint64(size))
    storeU64Relaxed(base, StatsOffMaxKeyBytes, uint64(StatsTableMaxKeyBytes))
    storeU64Relaxed(base, StatsOffReserved1, 0)
    storeU64Relaxed(base, StatsOffReserved2, 0)
    storeU64Relaxed(base, StatsOffBootId, boot)
    storeU64Relaxed(base, StatsOffOwnerPid, uint64(getpid()))
    storeU64Relaxed(base, StatsOffOwnerStartTime, processStartTime(int(getpid())))
    storeU32Release(base, StatsOffFormatVersion, StatsSegFormatVersion)
    storeU64Release(base, StatsOffMagic, StatsSegMagic)
    discard munmap(p, size)
    discard close(tfd)
    try:
      moveFile(tmp, path)
    except OSError:
      discard unlink(tmp.cstring); return
    let fd = open(path.cstring, O_RDWR)
    if fd < 0: return
    let mapped = mmap(nil, size, PROT_READ or PROT_WRITE, MAP_SHARED, fd, 0)
    if mapped == MAP_FAILED:
      discard close(fd); return
    result.base = cast[ShmBase](mapped)
    result.fd = fd
    result.size = size
    result.slotCount = slotCount
    result.slotKeys = newSeq[string](slotCount)
    result.slotSeq = newSeq[uint64](slotCount)
    result.slotUse = newSeq[uint64](slotCount)
    result.slotTick = newSeq[uint64](slotCount)
    result.available = true

proc close*(publisher: var StatsPublisher) =
  ## GUARDED ON ``available`` RATHER THAN ON THE DESCRIPTOR, because a
  ## default-constructed ``StatsPublisher`` has ``fd == 0`` and closing
  ## descriptor 0 would take the process's standard input out from under it
  ## — a failure that would show up somewhere else entirely.
  when statsPublisherSupported:
    if publisher.available:
      discard munmap(cast[pointer](publisher.base), publisher.size)
      publisher.base = nil
      if publisher.fd > 0:
        discard close(publisher.fd)
      publisher.fd = -1
  publisher.available = false

when statsPublisherSupported:
  proc writeRound(publisher: var StatsPublisher; slot: int; key: string;
                  estimate: PublishedEstimate) =
    ## ONE ROUND. Bump to odd, write key AND payload, bump to even.
    ##
    ## The sequence number comes from the shadow rather than from a load of
    ## the segment, so this procedure reads nothing back and the "must not
    ## read it back as authority" rule is not something a later edit can
    ## quietly break in passing.
    let entry = StatsEntriesOff + slot * StatsEntryStride
    let s = publisher.slotSeq[slot]
    storeU64Relaxed(publisher.base, entry + StatsEntryOffSeq, s + 1'u64)
    releaseFence()
    let words = keyWordsOf(key)
    # THE KEY IS WRITTEN INSIDE THE ROUND, always -- on a plain update as
    # well as on a rebind. Writing it only when it changes would make the
    # eviction path structurally different from the update path, and the
    # eviction path is the one nobody exercises by accident.
    storeU64Relaxed(publisher.base, entry + StatsEntryOffKeyLen,
      uint64(key.len))
    for i in 0 ..< words.len:
      storeU64Relaxed(publisher.base, entry + StatsEntryOffKey + i * 8,
        words[i])
    storeU64Relaxed(publisher.base, entry + StatsEntryOffKnowledge,
      if estimate.knowledge == statsTableKnown: 1'u64 else: 0'u64)
    storeU64Relaxed(publisher.base, entry + StatsEntryOffMemoryBytes,
      estimate.memoryBytes)
    storeU64Relaxed(publisher.base, entry + StatsEntryOffRecentPeak,
      estimate.recentPeakBytes)
    storeU64Relaxed(publisher.base, entry + StatsEntryOffSampleCount,
      estimate.sampleCount)
    storeU64Relaxed(publisher.base, entry + StatsEntryOffUpdatedMillis,
      estimate.updatedUnixMillis)
    releaseFence()
    storeU64Relaxed(publisher.base, entry + StatsEntryOffSeq, s + 2'u64)
    publisher.slotSeq[slot] = s + 2'u64

proc publishEstimate*(publisher: var StatsPublisher; key: string;
                      estimate: PublishedEstimate): StatsPublishResult =
  ## Publish (or refresh) one key's aggregate.
  ##
  ## PLACEMENT IS DECIDED FROM THE SHADOW. Linear probing from
  ## ``hash(key) mod slotCount``, bounded at ``StatsProbeLimit``; an existing
  ## slot for this key wins, then a free slot, and only if neither exists is
  ## a victim evicted. The victim is the least-used entry among the probed
  ## slots, ties broken by least-recently-used — "eviction by recency and
  ## frequency", and bounded by construction: the table never grows, so a
  ## key beyond capacity costs another key's residency and nothing else.
  if not publisher.available:
    return sprUnavailable
  if key.len == 0 or key.len > StatsTableMaxKeyBytes:
    inc publisher.rejectedCount
    return sprRejected
  when statsPublisherSupported:
    inc publisher.tick
    let mask = uint64(publisher.slotCount - 1)
    let start = statsKeyHash(key) and mask
    var freeSlot = -1
    var victim = -1
    for probe in 0 ..< StatsProbeLimit:
      let slot = int((start + uint64(probe)) and mask)
      if publisher.slotKeys[slot] == key:
        inc publisher.slotUse[slot]
        publisher.slotTick[slot] = publisher.tick
        publisher.writeRound(slot, key, estimate)
        inc publisher.publishCount
        return sprPublished
      if publisher.slotKeys[slot].len == 0:
        if freeSlot < 0: freeSlot = slot
      elif victim < 0 or
          publisher.slotUse[slot] < publisher.slotUse[victim] or
          (publisher.slotUse[slot] == publisher.slotUse[victim] and
           publisher.slotTick[slot] < publisher.slotTick[victim]):
        victim = slot
    let chosen = if freeSlot >= 0: freeSlot else: victim
    if chosen < 0:
      inc publisher.rejectedCount
      return sprRejected
    let evicting = publisher.slotKeys[chosen].len > 0
    publisher.slotKeys[chosen] = key
    publisher.slotUse[chosen] = 1
    publisher.slotTick[chosen] = publisher.tick
    publisher.writeRound(chosen, key, estimate)
    inc publisher.publishCount
    if evicting:
      inc publisher.evictionCount
      return sprEvicted
    return sprPublished
  else:
    return sprUnavailable

proc unsafeMappedBase*(publisher: StatsPublisher): pointer =
  ## The writer's mapping address. Exists so the SM-7 assertion can show
  ## that the publisher and the reader really are at DIFFERENT virtual
  ## bases — an assertion nobody can make without both numbers, and one
  ## that is worthless if the two processes happened to land at the same
  ## address. Nothing in the library calls this.
  when statsPublisherSupported:
    if publisher.available: cast[pointer](publisher.base) else: nil
  else:
    nil

proc residentKeys*(publisher: StatsPublisher): seq[string] =
  ## FROM THE SHADOW, never from the segment. Used by the bounded-eviction
  ## gate, which asserts this never exceeds ``slotCount`` however many keys
  ## are published, and by the emptied-table control, which needs to show
  ## that zeroing the segment leaves the daemon's own state untouched.
  result = @[]
  for key in publisher.slotKeys:
    if key.len > 0: result.add(key)
  result.sort()

proc statsPublisherReport*(publisher: StatsPublisher): string =
  if not publisher.available:
    return "published stats table: not publishing (socket remains authoritative)"
  "published stats table: " & publisher.path & " slots=" &
    $publisher.slotCount & " resident=" & $publisher.residentKeys().len &
    " published=" & $publisher.publishCount & " evicted=" &
    $publisher.evictionCount

when isMainModule:
  echo align($statsPublisherSupported, 6)
