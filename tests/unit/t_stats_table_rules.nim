## M13b, the rules that can be stated without a second process: the entry
## format, the reader's tolerance, bounded eviction, and the SINGLE-WRITER
## inspection gate.
##
## THREE OF THESE ARE REFUSAL-SHAPED and are therefore written against the
## thing being refused rather than against the happy path that neighbours it:
##
##   * the sequence counter's WIDTH — asserted by reading the raw word back
##     after N rounds and requiring exactly 2N, which a counter packed beside
##     a key hash cannot produce, rather than by asserting a constant equals
##     64;
##   * the reader's KEY RE-CHECK — asserted with two keys deliberately
##     constructed to probe the SAME SLOT, so the reader really does land on
##     somebody else's entry and has to reject it;
##   * the SINGLE-WRITER gate — an inspection over the discovered tree, with
##     both controls, because there is no runtime moment at which a second
##     writer misbehaves visibly. It corrupts an entry occasionally and
##     silently.
##
## The behavioural clauses that ARE reachable from a well-behaved caller —
## absent key, oversized key, no segment — are asserted here too, and they
## are the cheap ones; nothing in this file should be read as claiming they
## are the hard part.

import std/[algorithm, os, strutils, unittest]

import runquota_protocol
import runquota_stats_table
import runquota_stats_table/publisher

const
  repoRoot = currentSourcePath().parentDir.parentDir.parentDir

proc scratchDir(tag: string): string =
  result = getTempDir() / ("runquota-stats-" & tag & "-" & $getCurrentProcessId())
  removeDir(result)
  createDir(result)

proc rawU64(path: string; offset: int): uint64 =
  ## Read one little-endian word straight out of the segment FILE, without
  ## going through the reader. The point of several assertions below is what
  ## the bytes are, and asking the reader would be asking the thing under
  ## test.
  let blob = readFile(path)
  doAssert blob.len >= offset + 8
  for i in countdown(7, 0):
    result = (result shl 8) or uint64(uint8(blob[offset + i]))

proc entryOffset(slot: int; field: int): int =
  StatsEntriesOff + slot * StatsEntryStride + field

proc payload(key: string; n: uint64): PublishedEstimate =
  PublishedEstimate(statsKey: key, knowledge: statsTableKnown,
    memoryBytes: n, recentPeakBytes: n, sampleCount: n, updatedUnixMillis: n)

proc codeOnly(text: string): string =
  ## The source with comments removed, string-aware — the same cut
  ## ``t_observation_store_reader_boundary`` makes and for the same reason:
  ## every file in this tree explains at length the module it is NOT allowed
  ## to link, and a scanner that read prose would fire on documentation and
  ## then be silenced.
  var lines: seq[string] = @[]
  for line in text.splitLines():
    var inString = false
    var escaped = false
    var cut = line.len
    for index, character in line:
      if escaped:
        escaped = false
      elif character == '\\' and inString:
        escaped = true
      elif character == '"':
        inString = not inString
      elif character == '#' and not inString:
        cut = index
        break
    lines.add(line[0 ..< cut])
  lines.join("\n")

proc shippedSources(): seq[string] =
  for root in ["libs", "apps"]:
    for path in walkDirRec(repoRoot / root):
      if not path.endsWith(".nim"): continue
      if "/tests/" in path: continue
      result.add(path)
  result.sort()

proc relativeToRepo(path: string): string =
  if path.startsWith(repoRoot & "/"): path[repoRoot.len + 1 .. ^1] else: path

proc writesTheTable(source: string): bool =
  ## What makes a file a WRITER of the published table: it names the
  ## publisher module, or it names the one entry point that stores into it.
  let text = codeOnly(source)
  "runquota_stats_table/publisher" in text or
    "createStatsPublisher" in text or
    "publishEstimate" in text

suite "stats_table_rules":

  test "the boundary is written down where a reader of this repo will see it":
    # A GATE NOBODY CAN FIND THE RULE FOR GETS DELETED as an obstacle, which
    # is the reasoning `t_observation_store_reader_boundary` already applies
    # to the store. The rule lives in the repository's own boundary document
    # and the wording is pinned, so removing it fails here rather than
    # quietly.
    let boundary = readFile(repoRoot / "AGENTS.md")
    check "only writer of the published aggregate table" in boundary
    check "may hold a writable mapping of it" in boundary
    check "must not read it back as\n  authority" in boundary
    check "cache and never a second source of truth" in boundary

  test "the key field is the protocol's own cap, so a key is stored VERBATIM":
    # The whole reason the reader can compare THE KEY rather than a digest
    # of it. If the protocol ever raised its cap past the entry's key field
    # this stops being true silently -- a long key would be truncated into
    # somebody else's identity -- so the two numbers are pinned together.
    check StatsTableMaxKeyBytes == MaxCommandStatsIdBytes

  test "the sequence counter owns a FULL WORD, and packing it would show here":
    ## MV3's finding 7. `s2 == s1` proves the payload was stable only because
    ## the counter cannot return to a value it has left; on a narrow counter
    ## the shipped protocol violates NoTornRead at depth 19. A *bounded,
    ## fixed-size-entry* table is exactly where someone packs the counter in
    ## beside the key hash to save room.
    ##
    ## ASSERTED BY READING THE RAW WORD BACK, not by checking a constant. A
    ## constant saying "64" would still say 64 after somebody packed the
    ## counter in beside a key hash; the raw word after N rounds would not.
    ##
    ## WHAT THIS CATCHES AND WHAT IT DOES NOT, stated rather than implied.
    ## `rounds` is chosen so `2*rounds` overflows any counter narrower than
    ## SEVENTEEN bits, which is the size band a packed-beside-a-hash layout
    ## actually lands in — a first attempt at 5000 rounds did NOT catch a
    ## 16-bit mask, because 10000 fits in it, and that is the shape of hole
    ## this campaign keeps finding. A truncation at 32 bits would need 2^31
    ## rounds to show here and is covered instead by the second assertion
    ## below (a hash in the high half is non-zero on some key) and by the
    ## layout constant.
    let root = scratchDir("width")
    defer: removeDir(root)
    let path = root / "stats-table"
    var pub = createStatsPublisher(path, 8)
    check pub.available
    defer: pub.close()

    const rounds = 40_000
    static: doAssert 2 * rounds > 0xFFFF,
      "fewer rounds than this cannot overflow a 16-bit counter, and the " &
      "assertion below would pass against one"
    for n in 1 .. rounds:
      check pub.publishEstimate("width-key", payload("width-key", uint64(n))) ==
        sprPublished
    # Find the slot it landed in from the published side, not from the
    # shadow: this assertion is about the SEGMENT.
    var found = -1
    for slot in 0 ..< 8:
      if rawU64(path, entryOffset(slot, StatsEntryOffKeyLen)) ==
          uint64("width-key".len):
        found = slot
    check found >= 0
    let seqWord = rawU64(path, entryOffset(found, StatsEntryOffSeq))
    check seqWord == uint64(2 * rounds)
    # ...and it really is 64 bits wide with nothing else in them: the next
    # word along is the key length, which is a small number, so a counter
    # that had overflowed into it would be visible.
    check rawU64(path, entryOffset(found, StatsEntryOffKeyLen)) ==
      uint64("width-key".len)
    check StatsEntryOffKeyLen - StatsEntryOffSeq == 8

    # NOTHING ELSE LIVES IN THAT WORD, on any slot. A layout that packed the
    # key hash into the counter's high half would put a different, non-zero
    # value there for every key; after exactly one round each, every
    # resident slot's raw word must be exactly 2.
    let sweepRoot = scratchDir("width2")
    defer: removeDir(sweepRoot)
    let sweepPath = sweepRoot / "stats-table"
    var sweep = createStatsPublisher(sweepPath, 8)
    check sweep.available
    defer: sweep.close()
    for i in 0 ..< 8:
      let key = "wk-" & $i
      discard sweep.publishEstimate(key, payload(key, uint64(i)))
    var occupied = 0
    for slot in 0 ..< 8:
      if rawU64(sweepPath, entryOffset(slot, StatsEntryOffKeyLen)) == 0'u64:
        continue
      inc occupied
      check rawU64(sweepPath, entryOffset(slot, StatsEntryOffSeq)) == 2'u64
    check occupied > 1

  test "a reader lands on ANOTHER key's slot and refuses it":
    ## The reason the key must live inside the seqlocked region, before
    ## eviction is even considered: open addressing means a probe for K may
    ## legitimately land on a slot holding K'. A reader that did not compare
    ## the key would return that entry's distribution as K's -- coherently,
    ## with no tear, and no sequence number detecting anything.
    let root = scratchDir("probe")
    defer: removeDir(root)
    let path = root / "stats-table"
    const slots = 8
    var pub = createStatsPublisher(path, slots)
    check pub.available
    defer: pub.close()

    # Two keys whose PROBE STARTS AT THE SAME SLOT. Constructed rather than
    # hoped for: a test that used two arbitrary keys would almost never
    # exercise the collision it is named after.
    let mask = uint64(slots - 1)
    var keyA = ""
    var keyB = ""
    for i in 0 .. 400:
      let candidate = "collide-" & $i
      if (statsKeyHash(candidate) and mask) == (statsKeyHash("anchor-key") and mask):
        if keyA.len == 0: keyA = candidate
        elif keyB.len == 0: keyB = candidate
    check keyA.len > 0
    check keyB.len > 0
    check (statsKeyHash(keyA) and mask) == (statsKeyHash(keyB) and mask)

    check pub.publishEstimate(keyA, payload(keyA, 111'u64)) == sprPublished

    var table = openStatsTable(path)
    check table.available
    defer: table.close()

    var got: PublishedEstimate
    check table.lookupEstimate(keyA, got) == stlHit
    check got.memoryBytes == 111'u64

    # keyB probes the SAME slot, finds keyA there, and must not take it.
    var other: PublishedEstimate
    check table.lookupEstimate(keyB, other) == stlAbsent
    check other.memoryBytes == 0'u64

  test "eviction rebinds key and payload TOGETHER, in one round":
    ## Finding 8. The failure this forbids is not a tear: a reader whose slot
    ## is rebound takes a perfectly coherent snapshot of another key's
    ## distribution. What makes that impossible is that the key moved inside
    ## the same round as the payload, so after the rebind the slot answers to
    ## the NEW key and to nothing else.
    let root = scratchDir("evict")
    defer: removeDir(root)
    let path = root / "stats-table"
    const slots = 8
    var pub = createStatsPublisher(path, slots)
    check pub.available
    defer: pub.close()

    var table = openStatsTable(path)
    check table.available
    defer: table.close()

    # Fill it, then keep going: something must be evicted.
    var evicted = 0
    for i in 0 ..< slots * 8:
      let key = "evk-" & $i
      if pub.publishEstimate(key, payload(key, uint64(1000 + i))) == sprEvicted:
        inc evicted
    check evicted > 0

    # BOUNDED: the table never grew, in slots or in bytes.
    check pub.residentKeys().len <= slots
    check getFileSize(path) == int64(statsSegmentSize(slots))

    # Every key the publisher still considers resident reads back as ITSELF,
    # with its own payload -- not as a survivor of a half-finished rebind.
    for key in pub.residentKeys():
      var got: PublishedEstimate
      check table.lookupEstimate(key, got) == stlHit
      check got.statsKey == key
      let index = parseInt(key["evk-".len .. ^1])
      check got.memoryBytes == uint64(1000 + index)

    # And an evicted key is a MISS, never another key's numbers.
    var missed = 0
    for i in 0 ..< slots * 8:
      let key = "evk-" & $i
      if key in pub.residentKeys(): continue
      var got: PublishedEstimate
      check table.lookupEstimate(key, got) in {stlAbsent, stlTorn}
      check got.memoryBytes == 0'u64
      inc missed
    check missed > 0

  test "a reader tolerates everything: no table, absent key, oversized key":
    let root = scratchDir("tolerate")
    defer: removeDir(root)

    # No segment at all.
    var absent = openStatsTable(root / "not-there")
    check not absent.available
    var got: PublishedEstimate
    check absent.lookupEstimate("anything", got) == stlUnavailable
    absent.close()

    # A file that is not a segment.
    writeFile(root / "junk", repeat('x', 64 * 1024))
    var junk = openStatsTable(root / "junk")
    check not junk.available
    junk.close()

    let path = root / "stats-table"
    var pub = createStatsPublisher(path, 8)
    check pub.available
    defer: pub.close()
    check pub.publishEstimate("present", payload("present", 7'u64)) == sprPublished

    var table = openStatsTable(path)
    check table.available
    defer: table.close()
    check table.lookupEstimate("present", got) == stlHit
    check table.lookupEstimate("missing", got) == stlAbsent
    check table.lookupEstimate("", got) == stlAbsent
    check table.lookupEstimate(repeat('k', StatsTableMaxKeyBytes + 1), got) ==
      stlAbsent
    # An oversized key is refused on the WRITE side too, rather than
    # truncated into somebody else's identity.
    let long = repeat('k', StatsTableMaxKeyBytes + 1)
    check pub.publishEstimate(long, payload(long, 1'u64)) == sprRejected

  test "an emptied segment reads as absent, and nothing raises":
    ## The unit-level half of the decisive control: zeroing the table is a
    ## thing a reader survives. The gate's real version -- every store gate
    ## and every client gate still passing with the table emptied -- is in
    ## `t_stats_table_cache_control.nim`.
    let root = scratchDir("empty")
    defer: removeDir(root)
    let path = root / "stats-table"
    var pub = createStatsPublisher(path, 8)
    check pub.available
    check pub.publishEstimate("gone", payload("gone", 5'u64)) == sprPublished
    pub.close()

    var table = openStatsTable(path)
    check table.available
    var got: PublishedEstimate
    check table.lookupEstimate("gone", got) == stlHit

    # Zero every entry, leaving the header intact -- which is exactly what
    # "forcibly emptied" means for a table whose header carries the geometry.
    var blob = readFile(path)
    for i in StatsEntriesOff ..< blob.len:
      blob[i] = '\0'
    writeFile(path, blob)

    var reopened = openStatsTable(path)
    check reopened.available
    check reopened.lookupEstimate("gone", got) == stlAbsent
    reopened.close()
    table.close()

  test "the reader module holds no writable mapping, by construction":
    ## Mutation (3) of the gate is "let a client hold a WRITABLE mapping",
    ## and this is the half of its detector that lives in the source. The
    ## other half is in `t_stats_table_publication.nim`, which stores through
    ## a client's mapping in a child process and requires the kernel to kill
    ## it -- neither alone is enough, because a source scan cannot see what
    ## the kernel did and a crash test cannot see a mapping nobody wrote to.
    let readerSource = codeOnly(readFile(repoRoot / "libs" /
      "runquota_stats_table" / "src" / "runquota_stats_table.nim"))
    check "PROT_READ" in readerSource
    check "PROT_WRITE" notin readerSource
    check "O_RDONLY" in readerSource
    check "O_RDWR" notin readerSource
    # ...and the CONTROL, without which the two `notin`s above would pass
    # against a scanner reading the wrong file: the publisher, which really
    # does map read-write, must trip the same tokens.
    let writerSource = codeOnly(readFile(repoRoot / "libs" /
      "runquota_stats_table" / "src" / "runquota_stats_table" /
      "publisher.nim"))
    check "PROT_WRITE" in writerSource
    check "O_RDWR" in writerSource

  test "the scanner can see a writer, and can see that a reader is not one":
    # A SCANNER THAT MATCHES NOTHING PASSES EVERYWHERE. Both controls, before
    # the gate itself is allowed to mean anything.
    check writesTheTable(readFile(repoRoot / "libs" / "runquota_stats_table" /
      "src" / "runquota_stats_table" / "publisher.nim"))
    check writesTheTable(readFile(repoRoot / "libs" / "runquota_daemon" /
      "src" / "runquota_daemon.nim"))
    check not writesTheTable(readFile(repoRoot / "libs" /
      "runquota_stats_table" / "src" / "runquota_stats_table.nim"))
    check not writesTheTable(readFile(repoRoot / "libs" /
      "runquota_cli_support" / "src" / "runquota_cli_support.nim"))

  test "SINGLE WRITER: nothing outside runquotad writes the published table":
    ## The gate. Discovered rather than listed, so a violation in a module
    ## that does not exist yet is caught by a test written before it.
    const sanctioned = ["libs/runquota_stats_table/src/runquota_stats_table/publisher.nim",
      "libs/runquota_daemon/", "apps/runquotad/"]
    let sources = shippedSources()
    check sources.len > 20
    var sawSanctionedWriter = false
    var offenders: seq[string] = @[]
    for path in sources:
      if not writesTheTable(readFile(path)): continue
      let rel = relativeToRepo(path)
      var allowed = false
      for prefix in sanctioned:
        if rel.startsWith(prefix): allowed = true
      if allowed:
        sawSanctionedWriter = true
      else:
        offenders.add(rel)
    check sawSanctionedWriter
    if offenders.len > 0:
      echo "files writing the published stats table outside runquotad:"
      for path in offenders: echo "  " & path
    check offenders.len == 0

  test "the client library links the READER and never the publisher":
    # Stated separately from the sweep above because it is the specific
    # thing that would happen: somebody wanting to "just refresh the entry"
    # from the client side.
    for rel in ["libs/runquota_client/src/runquota_client.nim",
                "libs/runquota_cli_support/src/runquota_cli_support.nim",
                "libs/runquota_exec/src/runquota_exec.nim"]:
      let text = codeOnly(readFile(repoRoot / rel))
      check "runquota_stats_table/publisher" notin text
