## Lists of bytes the PROCESS owns, for state that outlives the threads that
## wrote into it.
##
## WHY THIS MODULE EXISTS. Under Nim's ORC allocator every thread gets its
## own region -- ``var allocator {.rtlThreadVar.}: MemRegion`` in
## ``system/mmdisp.nim``, the region ``system/alloc.nim``'s
## ``instantiateForRegion`` is instantiated with -- and every allocated chunk
## records the region that owns it. Freeing a chunk from a DIFFERENT thread
## is supported: ``rawDealloc`` hands it back through
## ``addToSharedFreeList``, which dereferences ``chunk.owner``. That is sound
## only while the owner still EXISTS, and a thread's region lives in its
## thread-local storage and goes away with the thread. A block allocated on
## one thread and freed after that thread has exited therefore dereferences a
## dead region, and the crash lands inside the allocator with no user frame
## near it.
##
## A LOCK DOES NOT HELP. Mutual exclusion and heap ownership are different
## problems: serialising access says nothing about which region a chunk came
## from. Neither does ``allocShared``, which under ORC is ``allocImpl``
## verbatim (``system/alloc.nim``'s ``allocSharedImpl``) with exactly the
## same per-thread ownership.
##
## WHAT THIS IS. A growable list of byte strings held in the C allocator,
## which has ONE arena for the whole process and no notion of an owning
## thread, so which thread frees a blob, and when, stops mattering. The
## shape follows the one ``runquota_observation_store/ambient`` already uses
## for its live self-report set; this module is that pattern factored out so
## the three queues that needed it do not each grow a copy of it.
##
## WHAT IT IS NOT. It is NOT thread-safe. Ownership is answered here; mutual
## exclusion is still the caller's, and every caller in this tree already
## holds a lock over the queue it is replacing. Both have to be answered and
## this answers one.
##
## VALUES CROSSING THE BOUNDARY STAY ORDINARY NIM STRINGS. ``add`` copies
## bytes IN and ``at``/``takeAll`` copy them OUT, so a ``string`` handed to
## this module is allocated and freed on the caller's own thread, exactly as
## it was before.

proc cMalloc(size: csize_t): pointer {.importc: "malloc",
  header: "<stdlib.h>".}
proc cRealloc(p: pointer; size: csize_t): pointer {.importc: "realloc",
  header: "<stdlib.h>".}
proc cFree(p: pointer) {.importc: "free", header: "<stdlib.h>".}

type
  OwnedSlice = object
    bytes: ptr UncheckedArray[char]
    length: int

  OwnedStrings* = object
    ## A list of byte strings in process-owned storage.
    ##
    ## Declared as a plain object with raw pointers deliberately: it carries
    ## no destructor, no copy hook and no GC reference, so a module-level
    ## ``var`` of this type is not part of any thread's heap.
    items: ptr UncheckedArray[OwnedSlice]
    count: int
    capacity: int

proc len*(store: OwnedStrings): int {.inline.} =
  store.count

proc releaseSlice(slice: var OwnedSlice) =
  if slice.bytes != nil:
    cFree(slice.bytes)
    slice.bytes = nil
  slice.length = 0

proc adopt(slice: var OwnedSlice; value: string): bool =
  ## Replaces ``slice`` with a C-heap copy of ``value``. Returns false, and
  ## leaves ``slice`` exactly as it was, when the allocator has nothing to
  ## give -- THE ONE CONDITION A QUEUE CANNOT RECORD ITS WAY OUT OF is the
  ## machine having no memory to record in, and every caller here already
  ## has a "dropped and counted" arm for a full queue to fold this into.
  if value.len == 0:
    releaseSlice(slice)
    return true
  let fresh = cast[ptr UncheckedArray[char]](cMalloc(csize_t(value.len)))
  if fresh == nil:
    return false
  copyMem(fresh, unsafeAddr value[0], value.len)
  releaseSlice(slice)
  slice.bytes = fresh
  slice.length = value.len
  true

proc reserve(store: var OwnedStrings; needed: int): bool =
  if needed <= store.capacity:
    return true
  var capacity = max(8, store.capacity)
  while capacity < needed:
    capacity = capacity * 2
  let grown = cRealloc(store.items, csize_t(capacity * sizeof(OwnedSlice)))
  if grown == nil:
    return false
  store.items = cast[ptr UncheckedArray[OwnedSlice]](grown)
  store.capacity = capacity
  true

proc add*(store: var OwnedStrings; value: string): bool {.discardable.} =
  ## Appends a copy of ``value``. False means the allocator refused and
  ## nothing was appended.
  if not store.reserve(store.count + 1):
    return false
  store.items[store.count] = OwnedSlice(bytes: nil, length: 0)
  if not adopt(store.items[store.count], value):
    return false
  store.count += 1
  true

proc setAt*(store: var OwnedStrings; index: int; value: string): bool
    {.discardable.} =
  ## Replaces the entry at ``index``. False means the allocator refused and
  ## the entry is unchanged.
  adopt(store.items[index], value)

proc equalsAt*(store: OwnedStrings; index: int; value: string): bool =
  ## Byte comparison against an entry, allocating nothing. Lookups are what
  ## every caller does most, and converting an entry back to a ``string`` to
  ## compare it would allocate once per entry scanned -- on the calling
  ## thread, in the middle of a lock.
  if store.items[index].length != value.len:
    return false
  if value.len == 0:
    return true
  equalMem(store.items[index].bytes, unsafeAddr value[0], value.len)

proc startsWithAt*(store: OwnedStrings; index: int; prefix: string): bool =
  ## As ``equalsAt``, for a caller that keeps a key in front of a payload.
  if prefix.len == 0:
    return true
  if store.items[index].length < prefix.len:
    return false
  equalMem(store.items[index].bytes, unsafeAddr prefix[0], prefix.len)

proc at*(store: OwnedStrings; index: int): string =
  ## One entry as an ordinary Nim string, allocated on the CALLING thread
  ## and so freed by it too.
  result = newString(store.items[index].length)
  if store.items[index].length > 0:
    copyMem(addr result[0], store.items[index].bytes,
      store.items[index].length)

proc removeAt*(store: var OwnedStrings; index: int) =
  ## Removes one entry, keeping the rest in order. Order is load-bearing for
  ## at least one caller -- the estimate writer evicts the OLDEST entry when
  ## its queue is full -- so this shifts rather than swapping with the last.
  releaseSlice(store.items[index])
  for i in index ..< store.count - 1:
    store.items[i] = store.items[i + 1]
  store.count -= 1

proc clear*(store: var OwnedStrings) =
  ## Drops every entry and the slot array with them, back to the C
  ## allocator. Safe on any thread, at any time, which is the whole point.
  for i in 0 ..< store.count:
    releaseSlice(store.items[i])
  store.count = 0
  if store.items != nil:
    cFree(store.items)
    store.items = nil
  store.capacity = 0

proc takeAll*(store: var OwnedStrings): seq[string] =
  ## The list as ordinary Nim values, allocated on the CALLING thread, and
  ## the store emptied. This is the drain every queue here performs.
  result = newSeqOfCap[string](store.count)
  for i in 0 ..< store.count:
    result.add(store.at(i))
  store.clear()
