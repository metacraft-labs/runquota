## Format and geometry of the PUBLISHED AGGREGATE TABLE.
##
## Design authority, in order of precedence:
##
##   * ``reprobuild-specs/RunQuota-Shared-Memory-Structures.md``
##     §"Structures Not Yet Built", the published-aggregate-table entry —
##     the format and algorithm contract;
##   * ``reprobuild-specs/RunQuota-Shared-Memory-Transport.md`` §1b (why it
##     exists) and §"Trust and the privilege boundary" (who may map it how);
##   * ``reprobuild-specs/RunQuota-Observation-Store.md`` §"Query Interface"
##     → Transport (that it is a CACHE and not a second source of truth);
##   * campaign milestone ``RunQuota-Observation-Store.milestones.org`` ** M13b,
##     whose gate is spread over ``tests/unit/t_stats_table_rules.nim``,
##     ``tests/integration/t_stats_table_publication.nim``,
##     ``tests/integration/t_stats_table_concurrency.nim`` and
##     ``tests/integration/t_stats_table_cache_control.nim``.
##
## THE COUNTER IS A FULL WORD AND THAT IS LOAD-BEARING, NOT INCIDENTAL.
## ``s2 == s1`` is evidence that the payload was stable ONLY because the
## counter cannot return to a value it has left. MV3 model-checked the
## shipped protocol, unmodified, on a NARROW counter and it violates
## ``NoTornRead`` at depth 19 — the seqlock's ABA, a reader accepting a
## snapshot belonging to no round at all. The trap is specific and this
## layout is written against it: a *bounded, fixed-size-entry* table is
## exactly the setting in which someone packs the sequence number in beside
## a key hash to save room. ``StatsEntryOffSeq`` therefore owns a whole
## ``uint64`` with nothing else in it, and ``t_stats_table_rules`` reads the
## raw word back after N rounds and requires exactly ``2*N`` — a value a
## packed counter cannot produce.
##
## THE KEY LIVES INSIDE THE SEQLOCKED REGION. This is first a requirement of
## OPEN ADDRESSING: a reader probing for key K may legitimately land on a
## slot holding key K′, so it has to compare the key to know whether it found
## its entry at all. Once the key is inside the protected region, eviction
## written AS A ROUND (bump to odd → rebind key and payload → bump to even)
## also closes the rebind hazard for free — without which a reader takes a
## perfectly *coherent* snapshot of another key's distribution, no sequence
## number detects it, and an admission decision is made on the wrong work's
## history.
##
## THE KEY IS STORED VERBATIM, NOT AS A DIGEST. It fits: the protocol caps
## a stats key at ``MaxCommandStatsIdBytes`` (64) bytes, so the whole key
## goes in the entry and the re-check is a comparison of the key rather
## than of a hash of it. The hash decides PLACEMENT only, which is why a
## hash collision here costs one wasted probe rather than a wrong answer.

type
  PublishedKnowledge* = enum
    ## Cold start, made a value rather than a convention — the same
    ## distinction ``runquota_observation_store.StatsKnowledge`` carries over
    ## the socket. "Nothing is known" and "known to be zero" are different
    ## facts and a caller does different things with them.
    ##
    ## DELIBERATELY NOT CALLED ``StatsKnowledge``: the daemon imports both
    ## this module and the observation store, and two enums of one name in
    ## one scope resolve by luck.
    statsTableUnknown = "unknown"
    statsTableKnown = "known"

  PublishedEstimate* = object
    ## One entry's payload: what ``runquotad`` currently believes work under
    ## ``statsKey`` costs. Deliberately small and flat — no offsets to
    ## chase, no allocation, no growth.
    statsKey*: string
    knowledge*: PublishedKnowledge
    memoryBytes*: uint64
      ## The admission estimate: the conservative figure a client may put on
      ## a lease request. This is the number the whole structure exists to
      ## deliver without a syscall.
    recentPeakBytes*: uint64
    sampleCount*: uint64
    updatedUnixMillis*: uint64

  StatsLookup* = enum
    ## What a lookup did. EVERY value except ``stlHit`` means the same thing
    ## to a caller — ask over the socket, or use your own default — and that
    ## is the point: no reader may block and no reader may fail.
    stlUnavailable
      ## No table is attached (not published, not readable, wrong format,
      ## different boot). Not an error.
    stlAbsent
      ## The table is attached and this key is not resident.
    stlTorn
      ## The retry budget was exhausted while a writer kept updating this
      ## slot. Distinguished from ``stlAbsent`` so the CONCURRENCY can be
      ## counted, not so a caller can behave differently.
    stlHit

  StatsPublishResult* = enum
    sprUnavailable ## no segment; publication is off
    sprRejected    ## key empty or longer than ``StatsTableMaxKeyBytes``
    sprPublished   ## an existing slot for this key was updated
    sprEvicted     ## another key's slot was rebound to make room

const
  StatsSegMagic* = 0x5251_5354_4154_01'u64
    ## "RQSTAT" + format tag. Written LAST, with release ordering, after the
    ## rename — publish-before-write, the convention every segment in this
    ## campaign obeys.
  StatsSegFormatVersion* = 1'u32

  StatsOffMagic* = 0 ## u64, written LAST with release ordering
  StatsOffFormatVersion* = 8 ## u32
  StatsOffFlags* = 12 ## u32, reserved
  StatsOffBootId* = 16 ## u64 — anchor
  StatsOffOwnerPid* = 24 ## u64 — anchor
  StatsOffOwnerStartTime* = 32 ## u64 — anchor; defeats pid reuse
  StatsOffSlotCount* = 40 ## u64
  StatsOffEntryStride* = 48 ## u64
  StatsOffEntriesOff* = 56 ## u64
  StatsOffSegmentSize* = 64 ## u64
  StatsOffMaxKeyBytes* = 72 ## u64
  StatsOffReserved1* = 80 ## u64
  StatsOffReserved2* = 88 ## u64

  StatsHeaderSize* = 128
  StatsEntriesOff* = StatsHeaderSize

  # --- the entry -------------------------------------------------------------
  #
  # Everything from `StatsEntryOffKeyLen` to `StatsEntryOffUpdatedMillis`
  # inclusive is INSIDE THE SEQLOCKED REGION: written between the bump to odd
  # and the bump to even, read between the reader's two counter loads. The key
  # is in that list on purpose; see this module's header.
  StatsEntryOffSeq* = 0
    ## u64, AND NOTHING ELSE IN THESE EIGHT BYTES. See the header.
  StatsEntryOffKeyLen* = 8 ## u64
  StatsEntryOffKey* = 16 ## `StatsTableMaxKeyBytes` bytes, zero-padded
  StatsEntryOffKnowledge* = 80 ## u64
  StatsEntryOffMemoryBytes* = 88 ## u64
  StatsEntryOffRecentPeak* = 96 ## u64
  StatsEntryOffSampleCount* = 104 ## u64
  StatsEntryOffUpdatedMillis* = 112 ## u64
  StatsEntryOffReserved* = 120 ## u64

  StatsTableMaxKeyBytes* = 64
    ## The protocol's own cap on ``commandStatsId``
    ## (``runquota_protocol.MaxCommandStatsIdBytes``), asserted equal to it in
    ## ``runquota_stats_table``. A longer key is simply not publishable and
    ## not lookupable, which is a MISS — the table is a cache and a miss is
    ## always answerable over the socket.
  StatsEntryStride* = 256
    ## A power of two so slot addressing is a shift, and four cache lines
    ## wide so two adjacent entries never share one. Publishing key A must
    ## not invalidate a reader of key B; a shared line would reintroduce
    ## exactly the cross-key interference the per-entry seqlock exists to
    ## avoid.

  DefaultStatsSlotCount* = 256
    ## BOUNDED. The table is a working set, not a mirror of the database:
    ## 256 × 256 B = 64 KiB, and it never grows. Eviction by recency and
    ## frequency is what keeps it that size under any number of keys.
  MaxStatsSlotCount* = 1 shl 16

  StatsProbeLimit* = 8
    ## Linear-probe depth. Bounded, because an unbounded probe on a full
    ## table is an unbounded read on the client's hot path.
  StatsReadRetryBudget* = 8
    ## How many times a reader re-attempts one slot before giving up and
    ## reporting ``stlTorn``. A BUDGET RATHER THAN A LOOP: a reader that
    ## spun until it won would be a reader that can block, and the whole
    ## point of the fall-back is that it never has to.

static:
  doAssert StatsEntryOffKeyLen - StatsEntryOffSeq == 8,
    "the sequence counter must own a full word; packing it beside a key " &
    "hash admits the seqlock's ABA (MV3 finding 7)"
  doAssert StatsEntryOffKey + StatsTableMaxKeyBytes <= StatsEntryOffKnowledge
  doAssert StatsEntryOffReserved + 8 <= StatsEntryStride
  doAssert StatsTableMaxKeyBytes mod 8 == 0
  doAssert (StatsEntryStride and (StatsEntryStride - 1)) == 0

func statsSegmentRawSize*(slotCount: int): int {.inline.} =
  StatsEntriesOff + slotCount * StatsEntryStride

func keyWordsOf*(key: string): array[StatsTableMaxKeyBytes div 8, uint64] =
  ## The key, zero-padded to the entry's fixed-size key field, as the same
  ## words the entry stores. ONE DEFINITION, shared by the writer's store and
  ## the reader's comparison: two copies of this would be two things to keep
  ## in step, and the failure of keeping them in step is a reader that never
  ## matches anything — a permanently cold cache that looks exactly like an
  ## empty one.
  for i in 0 ..< key.len:
    let word = i div 8
    let shift = (i mod 8) * 8
    result[word] = result[word] or (uint64(uint8(key[i])) shl shift)

func statsKeyHash*(key: string): uint64 =
  ## FNV-1a. It decides PLACEMENT ONLY. Correctness comes from the reader's
  ## comparison of the key itself, so a collision costs a probe and can
  ## never produce another key's distribution.
  result = 0xcbf29ce484222325'u64
  for ch in key:
    result = result xor uint64(uint8(ch))
    result = result * 0x100000001b3'u64
