## THE READ SIDE of the published aggregate table: how a client obtains its
## admission estimate with ZERO syscalls.
##
## `runquotad` publishes the current aggregate for hot stats keys into a
## host-wide segment as it folds in each run's results
## (``runquota_stats_table/publisher``); this module is what every client
## reads it with. The socket interface of M13a remains the FALLBACK and the
## ANSWER OF RECORD — see ``runquota_client.queryStats`` — and this module
## exists only to remove the round trip from the one read that has a latency
## budget.
##
## ------------------------------------------------------------------------
## THE FOUR THINGS THIS MODULE IS ACCOUNTABLE FOR
## ------------------------------------------------------------------------
##
## **1. It is a CACHE, never a second source of truth.** Every value it can
## return is answerable over the socket, and no behaviour anywhere may exist
## only while an entry is resident. That is the property worth protecting,
## because a table that is merely a cache can be dropped, resized or skipped
## in a degraded mode without any correctness argument at all. It is gated by
## ``tests/integration/t_stats_table_cache_control.nim``, which FORCIBLY
## EMPTIES the table and requires every store gate and every client gate to
## keep passing.
##
## **2. A reader never blocks and never fails.** Absent key, stale entry, a
## torn read whose retry budget ran out, no segment at all, a segment from a
## previous boot, an unreadable file — all of them mean the same thing to the
## caller: ask over the socket, or use your own default. There is no error
## path out of ``lookupEstimate`` because there is no failure a caller could
## do anything different about.
##
## **3. It holds a READ-ONLY MAPPING, and that is enforced by the kernel
## rather than by care.** The file is opened ``O_RDONLY`` and mapped
## ``PROT_READ``. A client that could write the table could feed another
## user's admission decisions, and — worse — `runquotad`'s own decisions if
## the daemon ever read it back. Both are refused structurally: the writer
## lives in a different module that no client-side code imports, and
## ``tests/integration/t_stats_table_publication.nim`` forks a child that
## stores through this mapping and requires it to die of a fatal signal.
##
## **4. The seqlock is written as the C11 seqlock, not as the sketch.** See
## ``readSlot`` below. "Read it and check the counter twice" is not an
## implementation: the reader races the writer BY CONSTRUCTION, so the
## payload accesses must be relaxed atomics with EXPLICIT FENCES. MV3
## model-checked both ordering pairs with ``herd7`` and recorded, per model,
## that the shipped rendering is Forbidden on C11, x86-TSO and ARMv8 while
## the relaxed variant of EITHER pair is *Allowed on C11 and ARMv8 and
## Forbidden on x86-TSO*. A defect here is therefore invisible to any amount
## of testing on x86 and live on ARM, which is why the fences are written
## out rather than left to whatever a particular target happens to emit.

import std/[os, strutils]

import runquota_stats_table/types as statsTableTypes
export statsTableTypes

const libraryName* = "runquota_stats_table"

type LibraryInfo* = object
  name*: string

proc libraryInfo*(): LibraryInfo =
  LibraryInfo(name: libraryName)

const statsTableSupported* = defined(linux) or defined(macosx)
  ## False on any platform without POSIX ``mmap(MAP_SHARED)``. Every
  ## operation then reports unavailable, so a caller degrades to the socket
  ## instead of failing — the same portable no-op arm the rest of the
  ## campaign's segments carry.

when statsTableSupported:
  import std/posix

  # REUSED, NOT REIMPLEMENTED. Boot id, process start time and the
  # liveness verdict that defeats pid reuse are `nim-shm-lease`'s
  # (`shm_lease/anchor`), the library that owns every other segment in this
  # campaign. This milestone is the first thing in `runquota` to depend on
  # it; see this repo's `config.nims` and `flake.nix` for the wiring.
  from shm_lease/anchor import bootId, anchorVerdict, AnchorVerdict, avLive

  type ShmBase = ptr UncheckedArray[byte]

  template atField(base: ShmBase; offset: int; T: typedesc): ptr T =
    cast[ptr T](addr base[offset])

  proc loadU64Acquire(base: ShmBase; off: int): uint64 {.inline.} =
    atomicLoadN(atField(base, off, uint64), ATOMIC_ACQUIRE)
  proc loadU64Relaxed(base: ShmBase; off: int): uint64 {.inline.} =
    atomicLoadN(atField(base, off, uint64), ATOMIC_RELAXED)
  proc loadU32Acquire(base: ShmBase; off: int): uint32 {.inline.} =
    atomicLoadN(atField(base, off, uint32), ATOMIC_ACQUIRE)
  proc acquireFence() {.inline.} =
    atomicThreadFence(ATOMIC_ACQUIRE)

type
  StatsTable* = object
    ## An attached, READ-ONLY view of the published aggregate table.
    ##
    ## ``available`` is false after any failure to attach, so a caller that
    ## ignores the result of ``openStatsTable`` still degrades rather than
    ## faults.
    available*: bool
    path*: string
    size*: int
    slotCount*: int
    ownerAlive*: bool
      ## Recorded, NOT enforced. A table published by a daemon that has since
      ## exited is STALE, and a stale entry is a slightly worse estimate
      ## rather than an incorrect admission. Refusing it here would turn a
      ## tolerated condition into a behaviour difference.
    retryCount*: uint64
      ## THE CONCURRENCY WITNESS. Incremented every time a slot read is
      ## re-attempted because the counter was odd or had moved. M13b's gate
      ## asserts this NON-ZERO under a writer updating continuously, because
      ## a broken retry loop passes every other clause when the writer
      ## happens to be idle — and a run in which this counter is zero is a
      ## run that tested nothing.
    tornCount*: uint64
      ## Lookups that gave up after ``StatsReadRetryBudget`` attempts.
    hitCount*: uint64
    missCount*: uint64
    when statsTableSupported:
      base: ShmBase
      fd: cint

  SlotRead = enum
    ## The outcome of ONE stable snapshot of ONE slot.
    slotEmpty    ## keyLen == 0: the probe terminates here
    slotOtherKey ## occupied by a different key: keep probing
    slotMatch    ## this is the entry we were looking for
    slotUnstable ## the retry budget ran out on this slot

proc statsTableEnvPath*(): string =
  ## ``RUNQUOTA_STATS_TABLE_PATH`` overrides the shipped host-wide path, and
  ## ``RUNQUOTA_STATS_TABLE=off`` disables the fast path entirely. The second
  ## is not merely a test affordance: "skipped in a degraded mode" is one of
  ## the things being a cache is supposed to buy, and an option nobody can
  ## exercise is a claim rather than a property.
  if getEnv("RUNQUOTA_STATS_TABLE") == "off":
    return ""
  getEnv("RUNQUOTA_STATS_TABLE_PATH")

when statsTableSupported:
  proc statsHeaderValid(base: ShmBase; boot: uint64; size: int): bool =
    ## Validated on attach with ACQUIRE loads. A reader that does not
    ## recognise the format version REFUSES rather than interpreting unknown
    ## bytes; refusing is a miss, and a miss is answerable over the socket.
    if loadU64Acquire(base, StatsOffMagic) != StatsSegMagic: return false
    if loadU32Acquire(base, StatsOffFormatVersion) != StatsSegFormatVersion:
      return false
    if loadU64Relaxed(base, StatsOffBootId) != boot: return false
    if loadU64Relaxed(base, StatsOffEntryStride) != uint64(StatsEntryStride):
      return false
    if loadU64Relaxed(base, StatsOffEntriesOff) != uint64(StatsEntriesOff):
      return false
    if loadU64Relaxed(base, StatsOffMaxKeyBytes) != uint64(StatsTableMaxKeyBytes):
      return false
    let slots = loadU64Relaxed(base, StatsOffSlotCount)
    if slots == 0 or slots > uint64(MaxStatsSlotCount): return false
    if (slots and (slots - 1)) != 0: return false # power of two: probe masking
    if loadU64Relaxed(base, StatsOffSegmentSize) != uint64(size): return false
    if statsSegmentRawSize(int(slots)) > size: return false
    true

proc openStatsTable*(path: string; wantBase: pointer = nil): StatsTable =
  ## Attach the published table read-only. Never raises; an unattachable
  ## table is reported as unavailable.
  ##
  ## ``wantBase`` maps at a CHOSEN virtual address (``MAP_FIXED``). It is a
  ## first-class parameter for the same reason it is one throughout
  ## ``nim-shm-lease``: SM-7 — "correct when the daemon and each client map
  ## it at DIFFERENT virtual bases" — is only PROVABLE if a test can choose
  ## the bases, and two processes both calling ``mmap(nil, ...)`` would very
  ## likely land at the same address and prove nothing. MV3 explicitly did
  ## not model cross-mapping; it is asserted by execution.
  result.available = false
  result.path = path
  when statsTableSupported:
    result.fd = -1
    if path.len == 0: return
    var info: Stat
    if stat(path.cstring, info) != 0: return
    if not S_ISREG(info.st_mode): return
    let size = int(info.st_size)
    if size < StatsEntriesOff + StatsEntryStride: return
    # O_RDONLY, and it is not a detail. A client MUST NOT hold a writable
    # mapping of the host-wide table (transport spec §"Trust and the
    # privilege boundary"); opening read-write here would make that a matter
    # of what the caller then does with it.
    let fd = open(path.cstring, O_RDONLY)
    if fd < 0: return
    let p =
      if wantBase != nil:
        mmap(wantBase, size, PROT_READ, MAP_SHARED or MAP_FIXED, fd, 0)
      else:
        mmap(nil, size, PROT_READ, MAP_SHARED, fd, 0)
    if p == MAP_FAILED:
      discard close(fd)
      return
    let base = cast[ShmBase](p)
    let boot = bootId()
    if not statsHeaderValid(base, boot, size):
      discard munmap(p, size)
      discard close(fd)
      return
    result.base = base
    result.fd = fd
    result.size = size
    result.slotCount = int(loadU64Relaxed(base, StatsOffSlotCount))
    let verdict = anchorVerdict(
      loadU64Relaxed(base, StatsOffBootId),
      loadU64Relaxed(base, StatsOffOwnerPid),
      loadU64Relaxed(base, StatsOffOwnerStartTime))
    result.ownerAlive = verdict == avLive
    result.available = true

proc openDefaultStatsTable*(defaultPath: string): StatsTable =
  ## ``defaultPath`` is what ``runquota_ipc.defaultStatsTablePath()`` says,
  ## passed in rather than imported so this library does not depend on the
  ## IPC layer for a string.
  let overridePath = statsTableEnvPath()
  if overridePath.len > 0:
    return openStatsTable(overridePath)
  if getEnv("RUNQUOTA_STATS_TABLE") == "off":
    return StatsTable(available: false, path: "")
  openStatsTable(defaultPath)

proc close*(table: var StatsTable) =
  ## GUARDED ON ``available`` RATHER THAN ON THE DESCRIPTOR: a
  ## default-constructed ``StatsTable`` has ``fd == 0``, and closing
  ## descriptor 0 would take standard input out from under the process.
  when statsTableSupported:
    if table.available:
      discard munmap(cast[pointer](table.base), table.size)
      table.base = nil
      if table.fd > 0:
        discard close(table.fd)
      table.fd = -1
  table.available = false

proc unsafeMappedBase*(table: StatsTable): pointer =
  ## The raw mapping, for the two tests that have to reason about the
  ## MAPPING rather than about its contents: the cross-mapping assertion
  ## (SM-7) needs to know the bases really differ, and the read-only
  ## assertion has to store through it in a child process and observe the
  ## kernel refuse. Nothing in the library itself calls this.
  when statsTableSupported:
    if table.available: cast[pointer](table.base) else: nil
  else:
    nil

when statsTableSupported:
  proc readSlot(table: var StatsTable; slot: int; wanted: string;
                wantedWords: array[StatsTableMaxKeyBytes div 8, uint64];
                estimate: var PublishedEstimate): SlotRead =
    ## ONE SLOT, ONE STABLE SNAPSHOT — the C11 seqlock reader, rendered
    ## exactly as MV3's ``litmus/seqlock-*.litmus`` pair requires:
    ##
    ## ``` text
    ##   s1 <- seq            ACQUIRE          <-- pair (a) against the
    ##   if odd(s1): retry                         writer's publishing store
    ##   key, payload         relaxed
    ##   fence(ACQUIRE)                        <-- pair (b), THE ONE A
    ##   s2 <- seq            relaxed              HAND-WRITTEN SEQLOCK
    ##   if s2 /= s1: retry                        MOST OFTEN GETS WRONG
    ## ```
    ##
    ## The acquire fence before the SECOND counter load is the whole of pair
    ## (b). Written as ``if (seq != s1) retry`` with no fence, that load may
    ## be issued before the payload copy completes — by the hardware on
    ## ARMv8, and by the compiler anywhere, since a relaxed atomic load may
    ## move ahead of ordinary reads. The reader would then validate against a
    ## counter it read before the data it is validating, its two loads would
    ## agree, and it would return a torn aggregate having passed both halves
    ## of its own check.
    ##
    ## THE KEY IS READ INSIDE THE ROUND AND COMPARED AFTER IT. Open
    ## addressing makes that mandatory — a probe for K may legitimately land
    ## on K′ — and it is also what makes eviction safe: the writer rebinds
    ## key and payload together inside one round, so a slot rebound under
    ## this reader is caught by ``s2 /= s1`` and, failing that, by the key
    ## comparison. Neither alone is sufficient and both are cheap.
    let entry = StatsEntriesOff + slot * StatsEntryStride
    var attempts = 0
    while attempts < StatsReadRetryBudget:
      inc attempts
      let s1 = loadU64Acquire(table.base, entry + StatsEntryOffSeq)
      if (s1 and 1'u64) != 0'u64:
        # A round is in flight. RETRY, DO NOT WAIT: the writer is never
        # blocked by a reader and a reader is never blocked by the writer.
        inc table.retryCount
        continue
      let keyLen = loadU64Relaxed(table.base, entry + StatsEntryOffKeyLen)
      var keyWords: array[StatsTableMaxKeyBytes div 8, uint64]
      for i in 0 ..< keyWords.len:
        keyWords[i] = loadU64Relaxed(table.base,
          entry + StatsEntryOffKey + i * 8)
      let knowledge = loadU64Relaxed(table.base, entry + StatsEntryOffKnowledge)
      let memoryBytes = loadU64Relaxed(table.base,
        entry + StatsEntryOffMemoryBytes)
      let recentPeak = loadU64Relaxed(table.base, entry + StatsEntryOffRecentPeak)
      let sampleCount = loadU64Relaxed(table.base,
        entry + StatsEntryOffSampleCount)
      let updated = loadU64Relaxed(table.base, entry + StatsEntryOffUpdatedMillis)
      acquireFence()
      let s2 = loadU64Relaxed(table.base, entry + StatsEntryOffSeq)
      if s2 != s1:
        inc table.retryCount
        continue
      if keyLen == 0'u64:
        return slotEmpty
      if keyLen > uint64(StatsTableMaxKeyBytes):
        # A slot whose length field is out of range cannot be this key's,
        # and it is not a reason to fail: treat it as somebody else's.
        return slotOtherKey
      if int(keyLen) != wanted.len:
        return slotOtherKey
      for i in 0 ..< keyWords.len:
        if keyWords[i] != wantedWords[i]:
          return slotOtherKey
      estimate = PublishedEstimate(
        statsKey: wanted,
        knowledge:
        if knowledge == 0'u64: statsTableUnknown else: statsTableKnown,
        memoryBytes: memoryBytes,
        recentPeakBytes: recentPeak,
        sampleCount: sampleCount,
        updatedUnixMillis: updated)
      return slotMatch
    slotUnstable

proc lookupEstimate*(table: var StatsTable; key: string;
                     estimate: var PublishedEstimate): StatsLookup =
  ## The zero-syscall read. Returns ``stlHit`` and fills ``estimate`` when
  ## the key is resident and a stable snapshot was taken; every other value
  ## means "fall back", and none of them is an error.
  estimate = PublishedEstimate(statsKey: key, knowledge: statsTableUnknown)
  if not table.available:
    return stlUnavailable
  if key.len == 0 or key.len > StatsTableMaxKeyBytes:
    inc table.missCount
    return stlAbsent
  when statsTableSupported:
    let wantedWords = keyWordsOf(key)
    let mask = uint64(table.slotCount - 1)
    let start = statsKeyHash(key) and mask
    var torn = false
    for probe in 0 ..< StatsProbeLimit:
      let slot = int((start + uint64(probe)) and mask)
      case table.readSlot(slot, key, wantedWords, estimate)
      of slotMatch:
        inc table.hitCount
        return stlHit
      of slotEmpty:
        # AN EMPTY SLOT ENDS THE PROBE -- but only concludes ABSENCE if
        # every slot before it was actually read. A slot this reader could
        # not stabilise might have held the key, so reporting a confident
        # miss here would be claiming something it has not earned. Both
        # answers mean "fall back" to a caller; the difference is that only
        # one of them is counted as concurrency, and a run whose torn
        # counter is zero is a run that tested nothing.
        if torn:
          inc table.tornCount
          return stlTorn
        inc table.missCount
        return stlAbsent
      of slotOtherKey:
        discard
      of slotUnstable:
        # KEEP PROBING RATHER THAN GIVING UP HERE. A slot this reader could
        # not stabilise is a slot it knows nothing about, including whether
        # it holds this key; the remaining probes may still find the entry,
        # and if none does the lookup reports `stlTorn` rather than a
        # confident absence it has not earned.
        torn = true
    if torn:
      inc table.tornCount
      return stlTorn
    inc table.missCount
    return stlAbsent
  else:
    return stlUnavailable

type
  EstimateSource* = enum
    ## WHERE an admission estimate came from. Recorded so a test can assert
    ## that the fast path was actually taken, and so the emptied-table
    ## control can assert that the answer is the SAME while the source
    ## differs — which is the whole content of "this is a cache".
    esNone
    esTable
    esSocket

  SocketEstimateFallback* = proc (statsKey: string;
                                  memoryBytes: var uint64): bool {.closure.}
    ## The M13a socket read, supplied by the caller. Passed in rather than
    ## imported so this library does not depend on ``runquota_client``, and
    ## so the ORDER below is one thing rather than a pattern re-typed at
    ## every call site.

proc resolveAdmissionEstimate*(table: var StatsTable; statsKey: string;
                               socketFallback: SocketEstimateFallback;
                               memoryBytes: var uint64): EstimateSource =
  ## Table first, socket second, nothing third — and the SECOND STEP IS
  ## WHAT MAKES THE FIRST ONE SAFE TO HAVE.
  ##
  ## The published table and the socket answer the SAME QUESTION WITH THE
  ## SAME NUMBER: `runquotad` publishes exactly the figure its
  ## ``statsSubjectDistribution`` answer carries, as it folds in each run's
  ## results. So a miss here costs a round trip and changes nothing else,
  ## and a caller cannot observe a behaviour that exists only while the
  ## entry is resident. That is asserted, not assumed:
  ## ``tests/integration/t_stats_table_cache_control.nim`` empties the table
  ## and requires every answer to be identical.
  memoryBytes = 0'u64
  var estimate: PublishedEstimate
  if table.lookupEstimate(statsKey, estimate) == stlHit and
      estimate.knowledge == statsTableKnown:
    memoryBytes = estimate.memoryBytes
    return esTable
  if socketFallback != nil:
    var fromSocket = 0'u64
    if socketFallback(statsKey, fromSocket):
      memoryBytes = fromSocket
      return esSocket
  esNone

proc statsTableReport*(table: StatsTable): string =
  ## One line for daemon and CLI output. Reading it costs nothing and it is
  ## the only place the retry counter is visible outside a test.
  if not table.available:
    return "published stats table: not attached (socket fallback)"
  "published stats table: " & table.path & " slots=" & $table.slotCount &
    " hits=" & $table.hitCount & " misses=" & $table.missCount &
    " retries=" & $table.retryCount & " torn=" & $table.tornCount &
    (if table.ownerAlive: "" else: " (publisher not running; entries are stale)")

when isMainModule:
  echo libraryInfo().name & " " & $statsTableSupported & " " &
    align($StatsEntryStride, 4)
