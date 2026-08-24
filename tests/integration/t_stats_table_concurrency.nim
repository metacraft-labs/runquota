## M13b: THE CONCURRENCY MUST BE SHOWN TO HAVE HAPPENED.
##
## Every other clause in this milestone passes when the writer is idle. A
## reader whose retry loop does nothing returns the right answer, never
## blocks, never fails, and satisfies the emptied-table control — so a run
## in which the retry counter is zero is a run that tested nothing, and the
## gate says so in as many words. This file is where a REAL SECOND PROCESS
## updates entries continuously while this one reads them.
##
## Three properties, and each needs the second process for its own reason:
##
##   1. **The retry counter is non-zero, and no snapshot is torn.** Every
##      payload word of a round carries the same generation number (the
##      device `shm_lease_seqlock.tla` uses: "round k stores k into every
##      word"), so "this is some single writer round's complete payload" is a
##      checkable equality. A reader that returns five words that are not all
##      equal has torn.
##   2. **A slot rebound under a reader never yields the other key's
##      numbers.** MV3's finding 8: this failure is NOT a tear. The snapshot
##      is perfectly coherent and no sequence number detects anything; what
##      it belongs to is another key's work. The two keys' payloads live in
##      disjoint numeric bands so the wrong answer is recognisable.
##   3. **SM-7 by execution: different virtual bases.** MV3 explicitly did
##      not model cross-mapping. The writer reports the address it mapped at
##      and this test attaches at a deliberately different one with
##      `MAP_FIXED`; the assertion fails if they coincide, so a run that
##      proved nothing cannot pass quietly.
##
## NO MOCKS. A real segment on a real filesystem, a real second process, and
## the shipped reader.

import std/[os, osproc, streams, strutils, tables, times, unittest]

import runquota_stats_table

const driverSource = "tests/fixtures/stats-table/publish_driver.nim"

var driverBinary = ""

proc scratchDir(tag: string): string =
  result = getTempDir() / ("rq-stats-conc-" & tag & "-" & $getCurrentProcessId())
  removeDir(result)
  createDir(result)

proc parseReport(output: string): Table[string, string] =
  result = initTable[string, string]()
  for line in output.splitLines():
    let parts = line.strip().split(' ', maxsplit = 1)
    if parts.len == 2:
      result[parts[0]] = parts[1]

proc waitForReady(path: string; timeoutMs: int): bool =
  let deadline = epochTime() + float(timeoutMs) / 1000.0
  while epochTime() < deadline:
    if fileExists(path): return true
    sleep(5)
  false

suite "stats_table_concurrency":

  setup:
    if driverBinary.len == 0:
      let compiler = findExe("nim")
      check compiler.len > 0
      if compiler.len > 0:
        let outPath = getCurrentDir() / "build" / "test-bin" /
          "stats_table_publish_driver"
        # THE INNER COMPILE INHERITS THIS FILE'S BUILD MODE, and it has to.
        # The writer's release fences are what the reader's acquire fence
        # pairs with, and neither is observable at -O0: removing them leaves
        # a debug build green. The driver is the WRITER, so a hardcoded
        # argument list here would leave the writer at -O0 no matter how the
        # suite was built -- which is exactly the hole M13b's writer-fence
        # mutation fell into. It was reported red under `-d:release`, and it
        # was red the way it was run by hand; the shipped test could not
        # reach that configuration at all.
        var buildArgs = @["c", "--threads:on",
                          "--nimcache:build/nimcache/stats_table_publish_driver",
                          "--out:" & outPath]
        when defined(release):
          buildArgs.add("-d:release")
        buildArgs.add(driverSource)
        let build = execProcess(compiler, args = buildArgs,
          env = nil, options = {poStdErrToStdOut})
        if not fileExists(outPath):
          echo build
        check fileExists(outPath)
        if fileExists(outPath):
          driverBinary = outPath

  test "a reader RETRIES under a continuous writer, and never returns a torn snapshot":
    require driverBinary.len > 0
    let root = scratchDir("retry")
    defer: removeDir(root)
    let path = root / "stats-table"
    let ready = root / "ready"

    var writer = startProcess(driverBinary,
      args = ["hammer", path, "16", "hot-key", "1500", ready],
      options = {poStdErrToStdOut})
    check waitForReady(ready, 8000)

    var table = openStatsTable(path)
    check table.available
    var estimate: PublishedEstimate
    var hits = 0
    var coherent = 0
    var torn = 0
    var gaveUp = 0
    let deadline = epochTime() + 1.2
    while epochTime() < deadline:
      case table.lookupEstimate("hot-key", estimate)
      of stlHit:
        inc hits
        # EVERY WORD OF A ROUND IS THE SAME NUMBER. A snapshot that mixes
        # two rounds fails this, and nothing else in the payload could.
        if estimate.memoryBytes == estimate.recentPeakBytes and
            estimate.memoryBytes == estimate.sampleCount and
            estimate.memoryBytes == estimate.updatedUnixMillis:
          inc coherent
        else:
          inc torn
      of stlTorn:
        # THE EXHAUSTED-BUDGET PATH, which the gate names among the three
        # things a reader must survive. It is only reachable while a writer
        # is genuinely updating the slot, so this is the only place in the
        # suite it can be counted at all.
        inc gaveUp
      else:
        discard

    let retries = table.retryCount
    let tornCounter = table.tornCount
    table.close()
    discard writer.waitForExit(15000)
    writer.close()

    echo "  reader: hits=" & $hits & " coherent=" & $coherent &
      " torn=" & $torn & " gaveUp=" & $gaveUp & " retries=" & $retries

    # THE FIXTURE MUST BE REAL BEFORE THE ASSERTION MEANS ANYTHING.
    check hits > 1000
    # THE CLAUSE THE GATE NAMES. Zero here is a run in which the writer was
    # idle and this whole file asserted nothing.
    check retries > 0'u64
    # ...and the reader really did run out of budget and fall back, rather
    # than the retry loop always winning: "exhausted retry under a torn
    # read" is a state the gate requires to be survivable, and a state
    # nothing else in the suite can reach.
    check gaveUp > 0
    check tornCounter == uint64(gaveUp)
    # ...and with the retry loop doing its job, not one snapshot tore.
    check torn == 0
    check coherent == hits

  test "a slot REBOUND under a reader never yields the other key's numbers":
    require driverBinary.len > 0
    let root = scratchDir("rebind")
    defer: removeDir(root)
    let path = root / "stats-table"
    let ready = root / "ready"

    # ONE SLOT, so every publication of `cold-key` evicts `warm-key` and
    # vice versa: the rebind hazard driven continuously rather than hoped
    # for.
    var writer = startProcess(driverBinary,
      args = ["rebind", path, "warm-key", "cold-key", "1500", ready],
      options = {poStdErrToStdOut})
    check waitForReady(ready, 8000)

    var table = openStatsTable(path)
    check table.available
    var estimate: PublishedEstimate
    var hits = 0
    var misses = 0
    var wrongKeyPayloads = 0
    var incoherent = 0
    let deadline = epochTime() + 1.2
    while epochTime() < deadline:
      case table.lookupEstimate("warm-key", estimate)
      of stlHit:
        inc hits
        # `cold-key`'s payloads are all >= 1_000_000 and `warm-key`'s are
        # all < 1000. A value in the wrong band is another key's
        # distribution returned as this key's -- coherent, undetected by any
        # sequence number, and an admission decision on the wrong work's
        # history.
        if estimate.memoryBytes >= 1_000_000'u64:
          inc wrongKeyPayloads
        if estimate.memoryBytes != estimate.sampleCount:
          inc incoherent
      of stlAbsent, stlTorn:
        inc misses
      of stlUnavailable:
        discard

    let retries = table.retryCount
    table.close()
    discard writer.waitForExit(15000)
    writer.close()

    echo "  rebind: hits=" & $hits & " misses=" & $misses &
      " wrongKey=" & $wrongKeyPayloads & " retries=" & $retries

    # BOTH OUTCOMES MUST HAVE HAPPENED, or the test saw only one side of the
    # alternation and the rebind was never under this reader at all.
    check hits > 0
    check misses > 0
    check retries > 0'u64
    check wrongKeyPayloads == 0
    check incoherent == 0

  test "SM-7: publisher and reader at DIFFERENT virtual bases, coherent either way":
    require driverBinary.len > 0
    let root = scratchDir("bases")
    defer: removeDir(root)
    let path = root / "stats-table"
    let ready = root / "ready"

    # `hold` rather than `hammer`: this test's subject is the MAPPING, and
    # under a continuous writer a reader spends nearly every attempt
    # retrying, so the run would measure the retry budget instead. The
    # contention property is asserted in the test above, which has its own
    # writer for it.
    var writer = startProcess(driverBinary,
      args = ["hold", path, "16", "mapped-key", "6000", ready],
      options = {poStdErrToStdOut})
    check waitForReady(ready, 8000)

    # A THIRD process reads at an address chosen by `MAP_FIXED`, well away
    # from wherever it would otherwise have landed.
    let readerOut = execProcess(driverBinary,
      args = ["read-at", path, "mapped-key", "20000", $(64 * 1024 * 1024)],
      env = nil, options = {poStdErrToStdOut})

    # ...and this process reads it too, at its own base.
    var table = openStatsTable(path)
    check table.available
    var estimate: PublishedEstimate
    var localHits = 0
    var localCoherent = 0
    for _ in 0 ..< 20000:
      if table.lookupEstimate("mapped-key", estimate) == stlHit:
        inc localHits
        if estimate.memoryBytes == estimate.sampleCount and
            estimate.memoryBytes == estimate.updatedUnixMillis:
          inc localCoherent
    let localBase = cast[uint](table.unsafeMappedBase())
    table.close()

    let writerOutput = writer.outputStream.readAll()
    discard writer.waitForExit(15000)
    writer.close()

    let writerReport = parseReport(writerOutput)
    let readerReport = parseReport(readerOut)
    echo "  bases: writer=" & writerReport.getOrDefault("base") &
      " reader=" & readerReport.getOrDefault("base") &
      " local=" & toHex(localBase, 16)

    check writerReport.hasKey("base")
    check readerReport.hasKey("base")
    let writerBase = parseHexInt(writerReport["base"])
    let readerBase = parseHexInt(readerReport["base"])

    # THE ASSERTION THAT MAKES THE REST OF THIS TEST EVIDENCE. If the three
    # mappings coincided, "correct at different virtual bases" would have
    # been asserted against one base.
    check writerBase != readerBase
    check uint(writerBase) != localBase
    check uint(readerBase) != localBase

    # Every process read coherent entries from its own base.
    check readerReport.hasKey("hits")
    check parseInt(readerReport["hits"]) > 1000
    check parseInt(readerReport["coherent"]) == parseInt(readerReport["hits"])
    check localHits > 1000
    check localCoherent == localHits
