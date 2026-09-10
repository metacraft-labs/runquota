## The dirty-key queue must outlive the connection workers that fill it.
##
## THE DEFECT THIS EXISTS FOR. `markAggregateDirty` runs on a CONNECTION
## WORKER: it is reached from `LeaseFinished`, which is served by whichever
## worker picked the connection up. The queue it appends to is drained by
## `publishDirtyAggregates`, and `serve`'s shutdown path calls
## `stopAggregatePublisher()` -- whose final drain is the last thing the
## publisher thread does -- AFTER `joinThread`ing every connection worker.
## As a `seq[string]` the queue's payload and its key strings were therefore
## freed on a thread that did not allocate them, at a moment when the thread
## that did no longer existed.
##
## WHY THAT IS NOT A DATA RACE AND A LOCK DOES NOT FIX IT. Under ORC every
## thread has its own allocator region (`var allocator {.rtlThreadVar.}:
## MemRegion`, `system/mmdisp.nim`) and every chunk records the region that
## owns it. `rawDealloc` hands a foreign chunk back through
## `addToSharedFreeList` / `addToSharedFreeListBigChunks`, both of which
## DEREFERENCE `chunk.owner`. That is sound while the owner thread still
## exists and undefined once it does not, because the region lives in the
## thread's TLS and goes away with it. `publicationLock` serialises ACCESS;
## this is a question of OWNERSHIP, and the two are different problems.
##
## HOW THIS TEST MAKES IT DETERMINISTIC. glibc caches a joined thread's
## stack -- and the static TLS block that sits in the same mapping -- up to
## `stack_cache_maxsize`, 40 MiB by default. Below that ceiling the dead
## region is still mapped and the foreign free silently corrupts memory
## somebody else may later be handed; above it, glibc `munmap`s the stack and
## the very next foreign free reads unmapped memory. `Producers` is therefore
## chosen so that the joined threads' stacks (2 MiB each, Nim's
## `ThreadStackSize`) exceed that ceiling with room to spare, which turns a
## probabilistic corruption into a SIGSEGV inside the allocator. Measured
## against the `seq[string]` queue this file was written for: 3 crashes in 3
## runs, every one of them in `addToSharedFreeListBigChunks`.
##
## The keys are large enough to be big chunks (over `SmallChunkSize`) and no
## two share a length, so `notePendingKey`'s coalescing scan rejects on the
## length check and the test does not spend its time in `equalMem`.

import std/[strutils, unittest]

import runquota_daemon {.all.}

const
  Producers = 64
    ## Over the 40 MiB stack cache at 2 MiB a thread; see the note above.
  PerProducer = 16
  Rounds = 4
  KeyBaseBytes = 8192
    ## Comfortably past `SmallChunkSize`, so the payload is a big chunk and
    ## the free goes through `addToSharedFreeListBigChunks`.

type Producer = object
  id: int

proc keyFor(producer, index: int): string =
  ## Unique CONTENT and unique LENGTH. The length is what keeps the linear
  ## coalescing scan cheap.
  "aggregate-key-" & $producer & "-" & $index & "-" &
    repeat('x', KeyBaseBytes + producer * PerProducer + index)

proc fillQueue(state: ptr Producer) {.thread.} =
  {.cast(gcsafe).}:
    for i in 0 ..< PerProducer:
      notePendingKey(keyFor(state.id, i))

var
  producers: array[Producers, Producer]
  producerThreads: array[Producers, Thread[ptr Producer]]

suite "publication queue ownership":
  test "keys queued by threads that have exited are drained without crashing":
    for round in 0 ..< Rounds:
      for i in 0 ..< Producers:
        producers[i] = Producer(id: i)
        createThread(producerThreads[i], fillQueue, addr producers[i])
      for i in 0 ..< Producers:
        joinThread(producerThreads[i])

      # EVERY PRODUCER IS GONE BY THIS LINE, and this is the drain
      # `stopAggregatePublisher`'s final `publishDirtyAggregates` performs
      # on the publisher thread. It runs here on the main thread for the
      # same reason: neither is the thread that allocated what it frees.
      let keys = takePendingKeys()
      check keys.len == Producers * PerProducer
      # The keys survived the boundary intact, which is the other half of
      # "process-owned": storage that is safe to free is worth nothing if
      # what comes back out of it is not what went in.
      check keys[0].len >= KeyBaseBytes
      check takePendingKeys().len == 0
      echo "  round ", round, ": drained ", keys.len, " keys"

  test "a key already queued is coalesced rather than queued twice":
    check takePendingKeys().len == 0
    notePendingKey("same-key")
    notePendingKey("same-key")
    notePendingKey("other-key")
    let keys = takePendingKeys()
    check keys.len == 2
    check "same-key" in keys
    check "other-key" in keys

  test "the queue is bounded, and a key past the bound is dropped":
    check takePendingKeys().len == 0
    let before = publicationsDropped
    for i in 0 ..< MaxPendingPublications + 8:
      notePendingKey("bounded-" & $i)
    let keys = takePendingKeys()
    check keys.len == MaxPendingPublications
    check publicationsDropped == before + 8'u64
