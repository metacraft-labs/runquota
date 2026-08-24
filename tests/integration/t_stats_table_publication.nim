## M13b gate, the end-to-end half: the REAL ``runquotad`` publishes the
## current aggregate for a stats key as it folds in a run's results, and a
## real client reads its admission estimate from the segment with ZERO
## SYSCALLS.
##
## NO MOCKS. The daemon binary from ``build/bin``, a real Unix-domain
## socket, a real lease taken and finished through the shipped client
## library, the segment the daemon really wrote, and — for the syscall
## clause — the KERNEL's own counter rather than a number this code
## maintains.
##
## THREE OF THE FOUR CLAUSES HERE ARE REFUSAL- OR DEGRADATION-SHAPED, and
## each is asserted where the code does the dangerous thing rather than
## where it is convenient to reach:
##
##   * **zero syscalls** is measured, not argued, and against a CONTROL that
##     must move the same counter — a measurement with no control measures
##     the instrument;
##   * **the client's mapping is read-only** is asserted by a child process
##     STORING THROUGH IT and being killed by the kernel. A test that merely
##     showed the reader works would pass against a read-write mapping;
##   * **the segment's mode is group-readable and not 0600** is the clause a
##     blanket per-segment ``0600`` rule would silently break, taking the
##     host-wide table away from every user but one — and looking exactly
##     like a cold cache while it did.
##
## The fourth — that the published number is the number the socket answers
## with — is an ordinary acceptance path and is asserted as one. It is also
## the precondition for ``t_stats_table_cache_control.nim``, whose emptied
## table has to produce the SAME answer over the socket.

import std/[options, os, osproc, posix, streams, strutils, times, unittest]

from runquota_ipc import endpointDirectoryPermissions, requiredSegmentMode,
  segmentHostWide, segmentIsGroupReadable, defaultStatsTablePath, unixEndpoint
import runquota_client
import runquota_core
import runquota_protocol
import runquota_stats_table

from shm_lease/syscount import syscallCountAvailable, unixSyscallCount

const
  MiB = 1024'u64 * 1024'u64
  PublishedKey = "m13b-published-key"
  ObservedPeakBytes = 700'u64 * MiB

proc scratchRoot(name: string): string =
  # Short on purpose: `Sockaddr_un_path_length` is 92 on macOS.
  result = getTempDir() / ("rq-p-" & $getCurrentProcessId() & "-" & name)
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

proc daemonPath(): string = getCurrentDir() / "build" / "bin" / "runquotad"

proc socketIsBound(path: string): bool =
  var info: Stat
  lstat(path.cstring, info) == 0 and S_ISSOCK(info.st_mode)

proc modeOf(path: string): int =
  var info: Stat
  if lstat(path.cstring, info) != 0: return -1
  int(info.st_mode) and 0o7777

type DaemonHandle = object
  process: Process
  listeningLine: string

proc startDaemon(socketPath: string; extraArgs: openArray[string]):
    DaemonHandle =
  var args = @["--socket", socketPath]
  for arg in extraArgs: args.add(arg)
  let process = startProcess(daemonPath(), args = args,
    options = {poStdErrToStdOut})
  for _ in 0 ..< 400:
    if socketIsBound(socketPath): break
    sleep(25)
  # EXACTLY THREE STARTUP LINES, still. M13b appends its report to the
  # listening line rather than printing a fourth, because the startup output
  # is consumed by count and a reader that guessed wrong would block.
  let listening = process.outputStream.readLine()
  discard process.outputStream.readLine()
  discard process.outputStream.readLine()
  DaemonHandle(process: process, listeningLine: listening)

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
  var session = client.registerSession("m13b-publish", "0.1.0")
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

proc waitForPublished(path, statsKey: string; timeoutMs: int;
                      estimate: var PublishedEstimate): bool =
  let deadline = epochTime() + float(timeoutMs) / 1000.0
  while epochTime() < deadline:
    var table = openStatsTable(path)
    if table.available:
      let verdict = table.lookupEstimate(statsKey, estimate)
      table.close()
      if verdict == stlHit: return true
    else:
      table.close()
    sleep(25)
  false

proc socketPeakFor(client: var RunQuotaClient; statsKey: string): uint64 =
  ## THE ANSWER OF RECORD. What M13a's socket read says about the same key,
  ## which is what the published entry has to equal.
  let answer = client.queryStats(statsSubjectDistribution, statsKey = statsKey)
  for entry in answer.distributions:
    if entry.knowledge == statsKnowledgeWireKnown:
      return entry.peakRssBytesMax
  0'u64

suite "stats_table_publication":

  test "runquotad publishes the aggregate, at a group-readable host-wide mode":
    let root = scratchRoot("pub")
    defer: removeDir(root)
    let endpointDir = rendezvousDir(root)
    let socketPath = endpointDir / "d.sock"
    let state = hostStateDir(root)
    require fileExists(daemonPath())

    putEnv("RUNQUOTA_SOCKET", socketPath)
    var daemon = startDaemon(socketPath,
      ["--host-identity-file", state / "host-id",
       "--ambient-sample-interval-millis", "0"])
    try:
      # The path is DERIVED FROM THE ENDPOINT rather than configured
      # separately: a table published where this daemon's clients do not
      # look is an unpublished table, and it fails as a permanently cold
      # cache rather than as an error.
      let tablePath = defaultStatsTablePath(unixEndpoint(socketPath))
      check tablePath == endpointDir / "stats-table"
      check fileExists(tablePath)
      check daemon.listeningLine.contains("published stats table")
      check daemon.listeningLine.contains(tablePath)

      # THE MODE CLAUSE. 0640: daemon-written, group-readable, and
      # deliberately NOT 0600. This is the one segment in the design that is
      # host-wide, and a blanket per-segment 0600 rule would make it
      # unreadable by every user but one.
      check modeOf(tablePath) == requiredSegmentMode(segmentHostWide)
      check modeOf(tablePath) == 0o640
      check (modeOf(tablePath) and 0o040) != 0
      check (modeOf(tablePath) and 0o022) == 0
      check segmentIsGroupReadable(segmentHostWide)

      var client = connectDefault()
      completeOneExecution(client, PublishedKey, ObservedPeakBytes)

      var published: PublishedEstimate
      check waitForPublished(tablePath, PublishedKey, 10_000, published)
      check published.knowledge == statsTableKnown
      check published.sampleCount >= 1'u64

      # THE PUBLISHED NUMBER IS THE SOCKET'S NUMBER. Not "close to", not
      # "derived from": the daemon publishes exactly what `estimateFor`
      # answers, which is what makes a table miss cost a round trip and
      # change nothing else.
      let overSocket = socketPeakFor(client, PublishedKey)
      check overSocket == ObservedPeakBytes
      check published.memoryBytes == overSocket

      client.close()
    finally:
      daemon.stop()
      delEnv("RUNQUOTA_SOCKET")

  test "a client reads its estimate with ZERO syscalls, against a control that is not zero":
    let root = scratchRoot("sysc")
    defer: removeDir(root)
    let endpointDir = rendezvousDir(root)
    let socketPath = endpointDir / "d.sock"
    let state = hostStateDir(root)
    require fileExists(daemonPath())

    putEnv("RUNQUOTA_SOCKET", socketPath)
    var daemon = startDaemon(socketPath,
      ["--host-identity-file", state / "host-id",
       "--ambient-sample-interval-millis", "0"])
    try:
      let tablePath = endpointDir / "stats-table"
      var client = connectDefault()
      completeOneExecution(client, PublishedKey, ObservedPeakBytes)
      var published: PublishedEstimate
      check waitForPublished(tablePath, PublishedKey, 10_000, published)

      if not syscallCountAvailable():
        # SKIPPED LOUDLY. Linux exposes no cheap per-task syscall counter,
        # and a silent skip here would leave the milestone's headline clause
        # looking asserted when nothing measured it.
        echo "  SKIPPED: no kernel syscall counter on this platform; " &
          "the zero-syscall clause was NOT executed"
        check defined(linux) or defined(windows)
      else:
        var table = openStatsTable(tablePath)
        check table.available
        var estimate: PublishedEstimate

        # Warm the mapping first. A page fault is not a UNIX syscall, but
        # measuring the first touch would still be measuring the mapping
        # rather than the lookup.
        for _ in 0 ..< 1000:
          discard table.lookupEstimate(PublishedKey, estimate)

        const Reads = 200_000
        let before = unixSyscallCount()
        var hits = 0
        for _ in 0 ..< Reads:
          if table.lookupEstimate(PublishedKey, estimate) == stlHit:
            inc hits
        let delta = unixSyscallCount() - before
        echo "  fast path: " & $Reads & " reads, syscall delta " & $delta
        check hits == Reads
        check estimate.memoryBytes == ObservedPeakBytes
        # THE CLAUSE.
        check delta == 0'u64

        # THE CONTROL, and without it the number above is a statement about
        # the instrument. The same question over the socket MUST move the
        # same counter.
        let controlBefore = unixSyscallCount()
        var controlAnswers = 0
        for _ in 0 ..< 20:
          if socketPeakFor(client, PublishedKey) == ObservedPeakBytes:
            inc controlAnswers
        let controlDelta = unixSyscallCount() - controlBefore
        echo "  socket control: 20 queries, syscall delta " & $controlDelta
        check controlAnswers == 20
        check controlDelta > 0'u64
        table.close()

      client.close()
    finally:
      daemon.stop()
      delEnv("RUNQUOTA_SOCKET")

  test "a client's mapping is READ-ONLY, and the kernel is what enforces it":
    ## Mutation (3) of the gate — "let a client hold a WRITABLE mapping" —
    ## has two independent detectors, and this is the one that can see what
    ## the kernel did. `t_stats_table_rules` carries the other, a source
    ## scan; neither alone is sufficient, because a scan cannot observe a
    ## mapping's real protection and a crash test cannot observe a mapping
    ## nobody stored through.
    let root = scratchRoot("ro")
    defer: removeDir(root)
    let endpointDir = rendezvousDir(root)
    let socketPath = endpointDir / "d.sock"
    let state = hostStateDir(root)
    require fileExists(daemonPath())

    putEnv("RUNQUOTA_SOCKET", socketPath)
    var daemon = startDaemon(socketPath,
      ["--host-identity-file", state / "host-id",
       "--ambient-sample-interval-millis", "0"])
    try:
      let tablePath = endpointDir / "stats-table"
      var client = connectDefault()
      completeOneExecution(client, PublishedKey, ObservedPeakBytes)
      var published: PublishedEstimate
      check waitForPublished(tablePath, PublishedKey, 10_000, published)
      client.close()

      var table = openStatsTable(tablePath)
      check table.available
      let base = table.unsafeMappedBase()
      check base != nil

      # A CHILD, because the store is expected to be fatal and a fatal
      # signal in this process would take the suite with it.
      let child = fork()
      check child >= 0
      if child == 0:
        # The child's Nim runtime prints a traceback for the fault before
        # the process dies of the signal; that noise on stdout is expected
        # and the assertion below is on the WAIT STATUS, which is the
        # kernel's account rather than the runtime's.
        #
        # Store through the client's mapping. If it succeeds, this process
        # exits 0 and the parent's assertion below fails -- which is exactly
        # what a read-write mapping would produce.
        let word = cast[ptr uint64](base)
        word[] = 0xdeadbeef'u64
        exitnow(0)
      var status: cint = 0
      discard waitpid(child, status, 0)
      let signalled = WIFSIGNALED(status)
      let signalNumber = if signalled: WTERMSIG(status) else: 0.cint
      echo "  write through a client mapping: signalled=" & $signalled &
        " signal=" & $signalNumber
      check signalled
      check signalNumber in [SIGSEGV, SIGBUS]

      # ...and the table is intact FOR EVERY OTHER CLIENT ON THE HOST, which
      # is the consequence a successful store would have had: the word at
      # the mapping's base is the segment MAGIC, so a client able to write
      # there can make the host-wide table unreadable for everybody — and
      # do it silently, since an unreadable table is indistinguishable from
      # a cold one. Re-attaching from scratch is what tests that, because
      # the already-validated handle above would carry on working either
      # way.
      var reopened = openStatsTable(tablePath)
      check reopened.available
      var after: PublishedEstimate
      check reopened.lookupEstimate(PublishedKey, after) == stlHit
      check after.memoryBytes == ObservedPeakBytes
      reopened.close()
      table.close()
    finally:
      daemon.stop()
      delEnv("RUNQUOTA_SOCKET")

  test "a STALE table -- publisher gone -- is still read, and says it is stale":
    ## "Readers tolerate everything ... a stale entry is a slightly worse
    ## estimate, never an incorrect admission." A table whose publisher has
    ## exited is the only form of staleness a client can actually observe,
    ## and it is a DEGRADATION rather than an acceptance path: refusing it
    ## here would turn a tolerated condition into a behaviour difference,
    ## and every other clause in this file would still pass.
    let root = scratchRoot("stale")
    defer: removeDir(root)
    let endpointDir = rendezvousDir(root)
    let socketPath = endpointDir / "d.sock"
    let state = hostStateDir(root)
    require fileExists(daemonPath())

    putEnv("RUNQUOTA_SOCKET", socketPath)
    var daemon = startDaemon(socketPath,
      ["--host-identity-file", state / "host-id",
       "--ambient-sample-interval-millis", "0"])
    let tablePath = endpointDir / "stats-table"
    var published: PublishedEstimate
    try:
      var client = connectDefault()
      completeOneExecution(client, PublishedKey, ObservedPeakBytes)
      check waitForPublished(tablePath, PublishedKey, 10_000, published)
      client.close()

      # LIVE FIRST, so the comparison below is a comparison.
      var live = openStatsTable(tablePath)
      check live.available
      check live.ownerAlive
      live.close()
    finally:
      daemon.stop()
      delEnv("RUNQUOTA_SOCKET")

    # The publisher is gone. The segment is not.
    var stale = openStatsTable(tablePath)
    check stale.available
    check not stale.ownerAlive
    var estimate: PublishedEstimate
    check stale.lookupEstimate(PublishedKey, estimate) == stlHit
    check estimate.memoryBytes == ObservedPeakBytes
    # ...and the fact is SAID, not merely represented: a stale estimate that
    # reads exactly like a fresh one is the case an operator cannot diagnose.
    check statsTableReport(stale).contains("stale")
    stale.close()
