## M13b's DECISIVE NEGATIVE CONTROL: with the table forcibly EMPTIED, every
## store gate and every client gate still passes.
##
## THIS IS THE CLAUSE THAT MAKES THE TABLE A CACHE. A published aggregate
## that is merely fast is an optimisation; one that can be dropped, resized
## or zeroed without any correctness argument at all is a cache, and only the
## second can be reasoned about without the socket interface having to agree
## with it. So the test is not "the reader survives an empty table" — that is
## a unit assertion and lives in ``t_stats_table_rules`` — but "every answer
## this system gives is the same answer with the table gone".
##
## THREE STATES, AND THE COMPARISON IS THE ASSERTION:
##
##   1. **resident** — the daemon has published, the client resolves its
##      estimate from the segment, ``esTable``;
##   2. **emptied** — every entry zeroed behind the daemon's back, header
##      intact; the client resolves the SAME NUMBER over the socket,
##      ``esSocket``;
##   3. **off** — a daemon started with ``RUNQUOTA_STATS_TABLE=off`` that
##      never publishes at all; same number again, ``esSocket``.
##
## The three are required to agree on every number and to DISAGREE on the
## source. Both halves matter: without the second, a client that never
## consulted the table would pass this test trivially, which is the
## anti-evidence shape this campaign keeps finding.
##
## MUTATION (4) OF THE GATE — "make an estimate resolvable ONLY when
## resident" — fails here and nowhere else.
##
## NO MOCKS: the real daemon binary, a real socket, the shipped client-side
## resolution (``runquota_cli_support.openPublishedTable`` and
## ``socketEstimateFallback``, the same two procs the CLI calls), and the
## shipped ``runquota acquire`` for the end-to-end arm.

import std/[os, osproc, posix, streams, strutils, unittest]

from runquota_ipc import endpointDirectoryPermissions
import runquota_cli_support
import runquota_client
import runquota_core
import runquota_protocol
import runquota_stats_table
import daemon_binary

const
  MiB = 1024'u64 * 1024'u64
  CacheKey = "m13b-cache-control-key"
  ObservedPeakBytes = 512'u64 * MiB

proc scratchRoot(name: string): string =
  result = getTempDir() / ("rq-c-" & $getCurrentProcessId() & "-" & name)
  removeDir(result)
  createDir(result)

proc rendezvousDir(root: string): string =
  result = root / "ep"
  createDir(result)
  setFilePermissions(result, endpointDirectoryPermissions())

proc hostStateDir(root: string): string =
  result = root / "state"
  createDir(result)
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc socketIsBound(path: string): bool =
  var info: Stat
  lstat(path.cstring, info) == 0 and S_ISSOCK(info.st_mode)

type DaemonHandle = object
  process: Process

proc startDaemon(socketPath: string; extraArgs: openArray[string]):
    DaemonHandle =
  var args = @["--socket", socketPath]
  for arg in extraArgs: args.add(arg)
  let process = startProcess(daemonPath(), args = args,
    options = {poStdErrToStdOut})
  for _ in 0 ..< 400:
    if socketIsBound(socketPath): break
    sleep(25)
  for _ in 0 ..< 3:
    discard process.outputStream.readLine()
  DaemonHandle(process: process)

proc stop(handle: var DaemonHandle) =
  if handle.process.running:
    handle.process.terminate()
    discard handle.process.waitForExit(5000)
  if handle.process.running:
    handle.process.kill()
    discard handle.process.waitForExit(5000)
  handle.process.close()

proc completeOneExecution(client: var RunQuotaClient; statsKey: string;
                          peakBytes: uint64) =
  var session = client.registerSession("m13b-cache", "0.1.0")
  var request = resourceRequest(statsKey, milliCpu(1000), bytes(64'u64 * MiB))
  request.commandStatsId = statsKey
  var lease = session.requestLease(request)
  doAssert lease.active
  lease.markStarting()
  lease.markRunning(childProcessId = uint64(getCurrentProcessId()))
  sleep(20)
  lease.finish(outcome = leaseFinishSucceeded, exitCode = 0'u32,
    peakMemoryBytes = peakBytes, processCount = 1'u32, majorPageFaults = 0'u64)
  lease.release()
  session.closeSession()

type StoreGateAnswers = object
  ## THE STORE GATES, as M13a stated them: a resource distribution over a
  ## stats key, rows for the human surfaces, and the unknown-versus-zero
  ## distinction. Captured as a value so the two runs can be compared field
  ## by field rather than re-asserted by hand in each state.
  distributionKnown: bool
  peakRssBytesMax: uint64
  sampleCount: uint64
  profileCarried: bool
  executionsSeen: int
  rankingSeen: int
  coldStartUnknown: bool
  bareLeaseMemoryBytes: uint64
    ## THE DAEMON'S OWN ADMISSION PATH, with NO client estimate supplied, so
    ## the daemon's LEARNED table is the fallback. This is the clause that
    ## covers "the daemon MUST NOT read the published table back as
    ## authority": if any daemon-side decision consulted the segment, this
    ## number would move when the segment is emptied, and every other clause
    ## here would still pass because none of them goes through admission
    ## without an estimate.

proc readStoreGates(client: var RunQuotaClient; statsKey: string):
    StoreGateAnswers =
  let distribution = client.queryStats(statsSubjectDistribution,
    statsKey = statsKey)
  result.distributionKnown = distribution.knowledge == statsKnowledgeWireKnown
  for entry in distribution.distributions:
    if entry.knowledge == statsKnowledgeWireKnown:
      result.peakRssBytesMax = entry.peakRssBytesMax
      result.sampleCount = entry.sampleCount
      result.profileCarried = entry.profile.hostId.len > 0 and
        entry.profile.profileIdPresent
  result.executionsSeen = client.queryStats(statsSubjectExecutions,
    statsKey = statsKey, scope = statsScopeWireHost).executions.len
  result.rankingSeen = client.queryStats(statsSubjectRanking,
    scope = statsScopeWireHost, limit = 32'u32).rankings.len
  # COLD START IS PART OF THE GATE, and it is the one a table could most
  # easily corrupt: a key with no history must stay distinguishable from a
  # key known to cost zero.
  result.coldStartUnknown = client.queryStats(statsSubjectDistribution,
    statsKey = statsKey & "-never-seen").knowledge == statsKnowledgeWireUnknown
  # THE SAME SESSION NAME the teaching execution used, and it has to be: the
  # daemon's learned estimates are keyed by session SCOPE, so a bare request
  # under a different name finds nothing and this clause would compare two
  # untouched defaults instead of two fallbacks.
  var session = client.registerSession("m13b-cache", "0.1.0")
  var bare = resourceRequest("bare", milliCpu(1000), bytes(1'u64 * MiB))
  bare.commandStatsId = statsKey
  var lease = session.requestLease(bare)
  doAssert lease.active
  result.bareLeaseMemoryBytes = lease.resources.memory.value
  lease.release()
  session.closeSession()

type ClientGateAnswer = object
  source: EstimateSource
  memoryBytes: uint64
  leaseMemoryBytes: uint64

proc readClientGate(client: var RunQuotaClient; statsKey: string):
    ClientGateAnswer =
  ## THE SHIPPED CLIENT-SIDE RESOLUTION, not a copy of it: these are the two
  ## procs `runquota acquire` calls.
  var table = openPublishedTable()
  defer: table.close()
  result.source = table.resolveAdmissionEstimate(statsKey,
    socketEstimateFallback(addr client), result.memoryBytes)
  var session = client.registerSession("m13b-client-gate", "0.1.0")
  var request = resourceRequest("gate", milliCpu(1000), bytes(1'u64 * MiB))
  request.commandStatsId = statsKey
  if result.source != esNone:
    request = request.withEstimate(result.memoryBytes)
  var lease = session.requestLease(request)
  doAssert lease.active
  result.leaseMemoryBytes = lease.resources.memory.value
  lease.release()
  session.closeSession()

proc emptyTheTable(path: string) =
  ## FORCIBLY EMPTIED: every entry zeroed, the header left intact, behind the
  ## daemon's back and without telling it. A client cannot do this in a
  ## deployment — the segment is `0640` and daemon-owned — and that is
  ## precisely why it is the control: it produces a state the system must
  ## survive and no well-behaved participant can construct.
  var blob = readFile(path)
  doAssert blob.len > StatsEntriesOff
  for i in StatsEntriesOff ..< blob.len:
    blob[i] = '\0'
  writeFile(path, blob)

suite "stats_table_cache_control":

  test "EMPTIED: every store gate and every client gate still passes, unchanged":
    let root = scratchRoot("empty")
    defer: removeDir(root)
    let endpointDir = rendezvousDir(root)
    let socketPath = endpointDir / "d.sock"
    let state = hostStateDir(root)
    require fileExists(daemonPath())
    require fileExists(cliPath())

    putEnv("RUNQUOTA_SOCKET", socketPath)
    var daemon = startDaemon(socketPath,
      ["--host-identity-file", state / "host-id",
       "--ambient-sample-interval-millis", "0"])
    try:
      let tablePath = endpointDir / "stats-table"
      check fileExists(tablePath)

      var client = connectDefault()
      completeOneExecution(client, CacheKey, ObservedPeakBytes)

      # Wait for the publication, so the RESIDENT state is really resident.
      var table = openPublishedTable()
      var estimate: PublishedEstimate
      var resident = false
      for _ in 0 ..< 400:
        table.close()
        table = openPublishedTable()
        if table.available and table.lookupEstimate(CacheKey, estimate) == stlHit:
          resident = true
          break
        sleep(25)
      table.close()
      check resident

      # ---------------------------------------------------------------
      # STATE 1: RESIDENT.
      # ---------------------------------------------------------------
      let storeBefore = readStoreGates(client, CacheKey)
      let clientBefore = readClientGate(client, CacheKey)
      let cliBefore = execProcess(cliPath(),
        args = ["acquire", "--cpu", "1000", "--mem", "1MiB",
                "--stats-key", CacheKey],
        env = nil, options = {poStdErrToStdOut})
      echo "  resident: " & $clientBefore.source & " " &
        $clientBefore.memoryBytes

      # THE FIXTURE MUST BE REAL. Every clause below compares two states, and
      # comparing two vacuous states is the easiest way to pass a control
      # like this without testing anything.
      check storeBefore.distributionKnown
      check storeBefore.peakRssBytesMax == ObservedPeakBytes
      check storeBefore.sampleCount >= 1'u64
      check storeBefore.profileCarried
      check storeBefore.executionsSeen >= 1
      check storeBefore.rankingSeen >= 1
      check storeBefore.coldStartUnknown
      # The learned fallback really is in play, so comparing it later is not
      # comparing two defaults: 512 MiB observed becomes 640 MiB learned.
      check storeBefore.bareLeaseMemoryBytes > 1'u64 * MiB
      check clientBefore.source == esTable
      check clientBefore.memoryBytes == ObservedPeakBytes
      check clientBefore.leaseMemoryBytes == ObservedPeakBytes
      check cliBefore.contains("granted")

      # ---------------------------------------------------------------
      # STATE 2: EMPTIED.
      # ---------------------------------------------------------------
      emptyTheTable(tablePath)
      var afterEmpty = openPublishedTable()
      var gone: PublishedEstimate
      check afterEmpty.available
      check afterEmpty.lookupEstimate(CacheKey, gone) == stlAbsent
      afterEmpty.close()

      let storeAfter = readStoreGates(client, CacheKey)
      let clientAfter = readClientGate(client, CacheKey)
      let cliAfter = execProcess(cliPath(),
        args = ["acquire", "--cpu", "1000", "--mem", "1MiB",
                "--stats-key", CacheKey],
        env = nil, options = {poStdErrToStdOut})
      echo "  emptied:  " & $clientAfter.source & " " &
        $clientAfter.memoryBytes

      # EVERY STORE GATE, UNCHANGED. Field by field rather than "still
      # answers something": a daemon that had started consulting its own
      # published table would answer differently here, and a coarse check
      # would not see it.
      check storeAfter.distributionKnown == storeBefore.distributionKnown
      check storeAfter.peakRssBytesMax == storeBefore.peakRssBytesMax
      check storeAfter.sampleCount == storeBefore.sampleCount
      check storeAfter.profileCarried == storeBefore.profileCarried
      check storeAfter.executionsSeen >= storeBefore.executionsSeen
      check storeAfter.rankingSeen == storeBefore.rankingSeen
      check storeAfter.coldStartUnknown == storeBefore.coldStartUnknown
      check storeAfter.bareLeaseMemoryBytes == storeBefore.bareLeaseMemoryBytes

      # EVERY CLIENT GATE, UNCHANGED IN THE ANSWER...
      check clientAfter.memoryBytes == clientBefore.memoryBytes
      check clientAfter.leaseMemoryBytes == clientBefore.leaseMemoryBytes
      check cliAfter.contains("granted")
      # ...AND CHANGED IN THE SOURCE, which is what says the fast path was
      # really the thing that went away rather than something the client had
      # never used.
      check clientAfter.source == esSocket
      check clientAfter.source != clientBefore.source

      client.close()
    finally:
      daemon.stop()
      delEnv("RUNQUOTA_SOCKET")

  test "OFF: a daemon that never publishes answers exactly the same":
    ## "Skipped in a degraded mode without any correctness argument at all"
    ## is one of the things being a cache is supposed to buy, and an option
    ## nobody can exercise is a claim rather than a property.
    let root = scratchRoot("off")
    defer: removeDir(root)
    let endpointDir = rendezvousDir(root)
    let socketPath = endpointDir / "d.sock"
    let state = hostStateDir(root)
    require fileExists(daemonPath())

    putEnv("RUNQUOTA_SOCKET", socketPath)
    putEnv("RUNQUOTA_STATS_TABLE", "off")
    var daemon = startDaemon(socketPath,
      ["--host-identity-file", state / "host-id",
       "--ambient-sample-interval-millis", "0"])
    try:
      # NOTHING WAS PUBLISHED AT ALL: there is no segment to read.
      check not fileExists(endpointDir / "stats-table")

      var client = connectDefault()
      completeOneExecution(client, CacheKey, ObservedPeakBytes)

      let storeGates = readStoreGates(client, CacheKey)
      let clientGate = readClientGate(client, CacheKey)
      echo "  off:      " & $clientGate.source & " " & $clientGate.memoryBytes

      check storeGates.distributionKnown
      check storeGates.peakRssBytesMax == ObservedPeakBytes
      check storeGates.sampleCount >= 1'u64
      check storeGates.profileCarried
      check storeGates.executionsSeen >= 1
      check storeGates.rankingSeen >= 1
      check storeGates.coldStartUnknown
      check storeGates.bareLeaseMemoryBytes > 1'u64 * MiB

      check clientGate.source == esSocket
      check clientGate.memoryBytes == ObservedPeakBytes
      check clientGate.leaseMemoryBytes == ObservedPeakBytes

      client.close()
    finally:
      daemon.stop()
      delEnv("RUNQUOTA_STATS_TABLE")
      delEnv("RUNQUOTA_SOCKET")
