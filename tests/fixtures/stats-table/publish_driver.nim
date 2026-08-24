## A REAL SECOND PROCESS for M13b's concurrency and cross-mapping gates.
##
## The properties this fixture exists to make testable are properties of two
## address spaces, and neither is expressible inside one process:
##
##   * the reader's RETRY COUNTER is only non-zero while a writer is
##     genuinely updating the entry the reader is reading — a run in which it
##     is zero is a run that tested nothing, so the writer has to be real and
##     continuous rather than interleaved by the test;
##   * SM-7 asks that the publisher and the reader map the table at
##     DIFFERENT VIRTUAL BASES, which two mappings in one process cannot
##     demonstrate.
##
## EVERY PAYLOAD WORD OF A ROUND CARRIES THE SAME GENERATION NUMBER — the
## same device `shm_lease_seqlock.tla` uses, where "round k stores k into
## every word" turns "this snapshot is some single writer round's complete
## payload" into a checkable equality rather than a paraphrase. A reader that
## returns a snapshot whose five words are not all equal has torn.
##
## Commands:
##   hammer <path> <slots> <key> <durationMs> <readyFile>
##   hold <path> <slots> <key> <durationMs> <readyFile>
##   rebind <path> <keyA> <keyB> <durationMs> <readyFile>
##   read-at <path> <key> <iterations> <baseOffsetBytes>

import std/[os, strutils, times]

import runquota_stats_table
import runquota_stats_table/publisher

when defined(posix):
  import std/posix

proc stampedPayload(key: string; generation: uint64): PublishedEstimate =
  PublishedEstimate(
    statsKey: key,
    knowledge: statsTableKnown,
    memoryBytes: generation,
    recentPeakBytes: generation,
    sampleCount: generation,
    updatedUnixMillis: generation)

proc nowMillis(): float = epochTime() * 1000.0

proc runHammer(path: string; slots: int; key: string; durationMs: int;
               readyFile: string): int =
  var pub = createStatsPublisher(path, slots)
  if not pub.available:
    echo "ERROR could not create " & path
    return 1
  echo "base " & toHex(cast[uint](pub.unsafeMappedBase()), 16)
  echo "ready"
  flushFile(stdout)
  writeFile(readyFile, "ready")
  let deadline = nowMillis() + float(durationMs)
  var generation = 0'u64
  while nowMillis() < deadline:
    for _ in 0 ..< 64:
      inc generation
      discard pub.publishEstimate(key, stampedPayload(key, generation))
  echo "generations " & $generation
  flushFile(stdout)
  pub.close()
  0

proc runHold(path: string; slots: int; key: string; durationMs: int;
             readyFile: string): int =
  ## Publish a handful of rounds and then STOP, keeping the segment mapped.
  ##
  ## Used by the cross-mapping gate, whose subject is coherence at differing
  ## virtual bases and NOT contention: under `hammer`'s continuous writer a
  ## reader spends nearly every attempt retrying, so the run would measure
  ## the retry budget instead of the mapping. Contention is asserted where it
  ## belongs, in the retry-counter test, with its own writer.
  var pub = createStatsPublisher(path, slots)
  if not pub.available:
    echo "ERROR could not create " & path
    return 1
  echo "base " & toHex(cast[uint](pub.unsafeMappedBase()), 16)
  for generation in 1'u64 .. 8'u64:
    discard pub.publishEstimate(key, stampedPayload(key, generation))
  echo "generations 8"
  echo "ready"
  flushFile(stdout)
  writeFile(readyFile, "ready")
  let deadline = nowMillis() + float(durationMs)
  while nowMillis() < deadline:
    sleep(10)
  pub.close()
  0

proc runRebind(path: string; keyA, keyB: string; durationMs: int;
               readyFile: string): int =
  ## ONE SLOT, TWO KEYS. With a single slot every key probes the same entry,
  ## so each publication of the other key EVICTS the resident one — the
  ## rebind hazard, driven continuously instead of hoped for.
  ##
  ## The two keys' payloads live in disjoint numeric bands, so a reader that
  ## accepted a rebound slot as its own key returns a number that could not
  ## have come from the key it asked about. That is what makes the assertion
  ## on the other side an assertion rather than a description: without the
  ## bands, a coherent snapshot of the WRONG key is indistinguishable from a
  ## coherent snapshot of the right one.
  var pub = createStatsPublisher(path, 1)
  if not pub.available:
    echo "ERROR could not create " & path
    return 1
  echo "base " & toHex(cast[uint](pub.unsafeMappedBase()), 16)
  echo "ready"
  flushFile(stdout)
  writeFile(readyFile, "ready")
  let deadline = nowMillis() + float(durationMs)
  var generation = 0'u64
  while nowMillis() < deadline:
    for _ in 0 ..< 32:
      inc generation
      let low = 1'u64 + (generation mod 1000'u64)
      discard pub.publishEstimate(keyA, stampedPayload(keyA, low))
      let high = 1_000_000'u64 + (generation mod 1000'u64)
      discard pub.publishEstimate(keyB, stampedPayload(keyB, high))
  echo "generations " & $generation
  flushFile(stdout)
  pub.close()
  0

proc runReadAt(path: string; key: string; iterations: int;
               baseOffset: int): int =
  ## Attach at a CHOSEN address. A pre-reserved anonymous region is mapped
  ## first and the segment is then placed inside it with `MAP_FIXED`, which
  ## is how `nim-shm-lease` makes the differing-base property provable
  ## instead of merely likely: two processes both calling `mmap(nil, ...)`
  ## would very often land at the same address and prove nothing.
  when defined(posix):
    var info: Stat
    if stat(path.cstring, info) != 0:
      echo "ERROR no segment " & path
      return 1
    let size = int(info.st_size)
    let reservation = mmap(nil, size + baseOffset + 1 shl 20, PROT_NONE,
      MAP_PRIVATE or MAP_ANONYMOUS, -1, 0)
    if reservation == MAP_FAILED:
      echo "ERROR could not reserve"
      return 1
    let want = cast[pointer](cast[uint](reservation) + uint(baseOffset))
    var table = openStatsTable(path, want)
    if not table.available:
      echo "ERROR could not attach " & path
      return 1
    echo "base " & toHex(cast[uint](table.unsafeMappedBase()), 16)
    var hits = 0
    var torn = 0
    var coherent = 0
    var lastMemory = 0'u64
    var estimate: PublishedEstimate
    for _ in 0 ..< iterations:
      case table.lookupEstimate(key, estimate)
      of stlHit:
        inc hits
        if estimate.memoryBytes == estimate.recentPeakBytes and
            estimate.memoryBytes == estimate.sampleCount and
            estimate.memoryBytes == estimate.updatedUnixMillis:
          inc coherent
        lastMemory = estimate.memoryBytes
      of stlTorn:
        inc torn
      else:
        discard
    echo "hits " & $hits
    echo "coherent " & $coherent
    echo "torn " & $torn
    echo "retries " & $table.retryCount
    echo "last " & $lastMemory
    flushFile(stdout)
    table.close()
    0
  else:
    echo "ERROR not supported"
    1

when isMainModule:
  let args = commandLineParams()
  if args.len == 0:
    echo "usage: publish_driver hammer|rebind|read-at ..."
    quit 2
  case args[0]
  of "hammer":
    if args.len != 6: quit 2
    quit runHammer(args[1], parseInt(args[2]), args[3], parseInt(args[4]),
      args[5])
  of "hold":
    if args.len != 6: quit 2
    quit runHold(args[1], parseInt(args[2]), args[3], parseInt(args[4]),
      args[5])
  of "rebind":
    if args.len != 6: quit 2
    quit runRebind(args[1], args[2], args[3], parseInt(args[4]), args[5])
  of "read-at":
    if args.len != 5: quit 2
    quit runReadAt(args[1], args[2], parseInt(args[3]), parseInt(args[4]))
  else:
    echo "unknown command " & args[0]
    quit 2
