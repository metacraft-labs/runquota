## A private `runquotad` for the memory-cap tests (`t_rqm_*`), and the few
## steps those tests repeat: grant a lease of a command, finish it with a
## chosen conclusion and memory-cap block, and read the command's learned row
## back from the daemon's own inspection output.
##
## A CLIENT SENDING FINISHES IS A REAL CLIENT. The finishes these tests send
## are frames a launcher on any OS sends after it enforced or measured a cap
## (`runquota_exec.finishMemoryCap`); choosing their figures here is what lets
## each learning rule be asserted exactly, without a kernel killing anything.
## The launcher side of the same figures is the platform legs' to test. No
## mocks: the built `runquotad` from `build/bin`, a real scratch endpoint, the
## ordinary client library, a real estimate store.

when defined(posix):
  import std/[json, os, osproc]

  import runquota_client
  import runquota_core
  import runquota_protocol
  import private_daemon_fixture

  export private_daemon_fixture

  const
    MiB* = 1024'u64 * 1024'u64
    GiB* = 1024'u64 * MiB
    BudgetBytes* = 16'u64 * GiB
      ## The private daemon's memory budget (B in the cap's table).
    SessionName* = "rqm-test"
      ## The session every test registers; its learned rows live in scope
      ## `session:rqm-test`.

  type RqmDaemon* = object
    root*: string
    socket*: string
    process*: Process

  proc hostFileText*(factor = ""): string =
    ## The budget the tests reason in: 16 GiB, 16 CPUs, and the factor when
    ## one is given (`[enforcement] memoryCapFactor`).
    result = "schema = \"runquota.host-config.v1\"\n[machine]\n" &
      "memory_bytes = " & $BudgetBytes & "\ncpu_milli = 16000\n"
    if factor.len > 0:
      result.add("[enforcement]\nmemoryCapFactor = " & factor & "\n")

  proc startRqmDaemon*(prefix: string; factor = ""; root = ""): RqmDaemon =
    ## A daemon of its own in a fresh scratch directory (or in `root`, to
    ## restart over the same estimate store), bound before this returns. On
    ## any failure here the daemon is stopped before the raise, since the
    ## caller's `defer` does not exist yet.
    result.root = if root.len > 0: root else: scratchDir(prefix)
    result.socket = result.root / "d.sock"
    writeFile(result.root / "host.toml", hostFileText(factor))
    result.process = launch(result.root, result.socket,
      privateEnv(result.socket))
    try:
      # The daemon's output is read only once it has exited: reading it
      # while it runs would wait for an end that never comes.
      if not awaitSocket(result.process, result.socket):
        stopOwned(result.process)
        prerequisite(false, "runquotad did not bind: " &
          result.process.output())
    except CatchableError:
      stopOwned(result.process)
      raise
    putEnv("RUNQUOTA_ENDPOINT_SCOPE", "private")
    putEnv("RUNQUOTA_SOCKET", result.socket)

  proc halt*(daemon: RqmDaemon) =
    ## Stop the daemon and keep its directory (its estimate store).
    stopOwned(daemon.process)

  proc stop*(daemon: RqmDaemon) =
    stopOwned(daemon.process)
    try: removeDir(daemon.root)
    except CatchableError: discard

  proc request*(key: string; memoryBytes: uint64; cpuMilli = 1000'u32):
      ResourceRequest =
    ## A host lease of `key` with a memory dimension, and a supplied estimate
    ## of exactly that much, so admission charges what the test names and no
    ## learned figure changes the reservation under it.
    result = resourceRequest("rqm " & key, milliCpu(cpuMilli),
      bytes(memoryBytes)).withEstimate(memoryBytes)
    result.commandStatsId = key

  proc finishWith*(lease: var RunQuotaLease; outcome: LeaseFinish;
                   peakBytes = 0'u64; capBlock = FinishMemoryCap(present: false);
                   maxRssBytes = 0'u64) =
    ## Run a lease's lifecycle to its finish with the given figures, and
    ## release it.
    lease.markStarting()
    lease.markRunning(childProcessId = uint64(getCurrentProcessId()))
    lease.finish(outcome = outcome, peakMemoryBytes = peakBytes,
      processCount = 1'u32,
      totals = (if maxRssBytes > 0'u64:
                  FinishTotals(known: true, maxRssBytes: maxRssBytes,
                    durationMillis: 10'u64)
                else: FinishTotals(known: false)),
      memoryCap = capBlock)
    lease.release()

  proc measured*(capBytes, peakBytes: uint64; basis: MemoryCapBasis;
                 capReached = false; exceededAdvisory = false):
      FinishMemoryCap =
    ## The block a Linux launcher sends for a tree it measured in its leaf.
    FinishMemoryCap(present: true, capBytes: capBytes, basis: basis,
      treePeakBytes: peakBytes, peakSource: mpsCgroup,
      capReached: capReached, exceededAdvisory: exceededAdvisory)

  proc learnedRow*(client: var RunQuotaClient; key: string;
                   scope = "session:" & SessionName): JsonNode =
    ## The command's learned row as the daemon reports it (`estimates`), or
    ## nil when it holds none.
    let answer = parseJson(client.inspectionJson("estimates"))
    for row in answer["estimates"]:
      if row["scope"].getStr() == scope and
          row["command_stats_id"].getStr() == key:
        return row
    nil

  proc figure*(row: JsonNode; name: string): uint64 =
    ## One figure of a row; 0 for a row that is not there.
    if row.isNil: 0'u64 else: uint64(row[name].getBiggestInt())

  proc rqmCli*(daemon: RqmDaemon; args: openArray[string]):
      tuple[code: int, output: string] =
    ## The real `runquota` CLI against this daemon.
    cli(privateEnv(daemon.socket), args)
