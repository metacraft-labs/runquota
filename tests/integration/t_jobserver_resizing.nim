## `runquota jobserver` following a moving width, end to end: the built CLI,
## a real private `runquotad` on a scratch socket, and GNU make as the
## jobserver client.
##
## WHAT IS GUARDED, each with the mutation that breaks it:
##
## 1. Widening uses free slots: a bridge granted 2 of a 2..8 range while a
##    neighbour holds 6 is widened by the admission pass of the neighbour's
##    release (its target is 8 before the bridge has reported anything), and
##    the jobserver issues the extra tokens, so make runs 8 jobs at once.
##    Mutation: never widen (`widenIntoFreeSlots` returning at once) and make
##    stays at 2.
## 2. Narrowing never takes running tokens: with 8 jobs busy, a waiter for 6
##    slots makes the daemon narrow the bridge's target to 2. No job is
##    signalled or cut short, and the waiter is granted only once six jobs
##    have finished -- when the bridge holds 2 -- and before the seventh
##    does. Mutations: charge the target at once (`resizeCharge` returning
##    the target) and the waiter is granted while all 8 still run; never
##    withhold returned tokens (`withholdTokens` returning 0) and the waiter
##    is granted only when the bridge's lease is released, after the last
##    job.
##
## NO MOCKS, EXCEPT ONE, JUSTIFIED. Each make recipe is a small shell job
## that logs its start and end with a wall-clock stamp and sleeps for a known
## time, and traps SIGTERM, SIGINT and SIGHUP to log that it was signalled:
## real compiles end too fast and too unevenly to show eight jobs overlapping
## or to tell a job cut short from one that finished. The jobs hold make's
## tokens exactly as compiles would.
##
## ISOLATION. One private daemon per case, on its own socket inside a fresh
## 0700 directory with `RUNQUOTA_ENDPOINT_SCOPE=private`; the bridge runs
## with that endpoint in its environment. Only processes this file started
## are signalled: the daemons, through their `Process`.

when defined(posix):
  import std/[algorithm, json, monotimes, os, osproc, streams, strtabs,
    strutils, times, unittest]

  import runquota_client
  import runquota_core
  import daemon_binary
  import private_daemon_fixture

  const GiB = 1024'u64 * 1024'u64 * 1024'u64

  type
    Daemon = object
      root, socket: string
      env: StringTableRef
      process: Process
    JobEvent = object
      start: bool
      stamp: int64 ## wall-clock nanoseconds
      job: int

  proc startDaemon(prefix: string; cpuMilli: int): Daemon =
    result.root = scratchDir(prefix)
    result.socket = result.root / "d.sock"
    result.env = privateEnv(result.socket)
    for key in ["RUNQUOTA_PARENT_LEASE", "RUNQUOTA_JOBSERVER_FIFO",
        "MAKEFLAGS", "MFLAGS", "CARGO_MAKEFLAGS", "RUNQUOTA_SESSION"]:
      result.env.del(key)
    result.process = launch(result.root, result.socket, result.env,
      ["--cpu-milli", $cpuMilli, "--memory-bytes", $(64'u64 * GiB)])
    prerequisite awaitSocket(result.process, result.socket),
      result.process.startupContext("the daemon did not bind " &
        result.socket)
    # The in-process client (the neighbour and the waiter) reaches the same
    # daemon.
    putEnv("RUNQUOTA_ENDPOINT_SCOPE", "private")
    putEnv("RUNQUOTA_SOCKET", result.socket)
    delEnv("RUNQUOTA_SESSION")

  proc stop(daemon: var Daemon) =
    stopOwned(daemon.process)
    removeDir(daemon.root)

  proc nowNanos(): int64 =
    let t = getTime()
    t.toUnix() * 1_000_000_000'i64 + int64(t.nanosecond)

  proc makeProject(dir, log: string; sleeps: openArray[string]) =
    ## One target per entry of `sleeps`, each logging `+ <ns> <k>` when it
    ## starts, `- <ns> <k>` when its sleep is over, and `! <ns> <k>` if it is
    ## sent SIGTERM, SIGINT or SIGHUP.
    createDir(dir)
    var targets: seq[string] = @[]
    var rules = ""
    for k, seconds in sleeps:
      let name = "t" & $(k + 1)
      targets.add name
      rules.add name & ":\n" &
        "\t@trap 'echo \"! $$(date +%s%N) " & $(k + 1) & "\" >> " & log &
        "; exit 1' TERM INT HUP; " &
        "echo \"+ $$(date +%s%N) " & $(k + 1) & "\" >> " & log & "; " &
        "sleep " & seconds & "; " &
        "echo \"- $$(date +%s%N) " & $(k + 1) & "\" >> " & log & "\n"
    writeFile(dir / "Makefile", "all: " & targets.join(" ") & "\n" & rules &
      ".PHONY: all " & targets.join(" ") & "\n")

  proc events(log: string): seq[JobEvent] =
    if not fileExists(log): return
    for line in readFile(log).splitLines():
      let parts = line.splitWhitespace()
      if parts.len != 3: continue
      if parts[0] == "!":
        result.add JobEvent(start: false, stamp: -1, job: parseInt(parts[2]))
        continue
      result.add JobEvent(start: parts[0] == "+",
        stamp: parseBiggestInt(parts[1]), job: parseInt(parts[2]))
    result.sort(proc (a, b: JobEvent): int =
      if a.stamp != b.stamp: cmp(a.stamp, b.stamp)
      else: cmp(ord(a.start), ord(b.start)))

  proc peakBetween(evs: seq[JobEvent]; fromNs, toNs: int64): int =
    ## The deepest overlap of job intervals inside [fromNs, toNs].
    var depth = 0
    for ev in evs:
      if ev.stamp < 0: continue
      depth += (if ev.start: 1 else: -1)
      if ev.stamp >= fromNs and ev.stamp <= toNs:
        result = max(result, depth)

  proc startedCount(log: string): int =
    for ev in events(log):
      if ev.start: inc result

  proc bridgeLease(client: var RunQuotaClient): JsonNode =
    for row in parseJson(client.inspectionJson("leases"))["leases"]:
      if row["label"].getStr().startsWith("jobserver"):
        return row
    nil

  proc waitFor(condition: proc (): bool; seconds: int): bool =
    let deadline = getMonoTime() + initDuration(seconds = seconds)
    while getMonoTime() < deadline:
      if condition(): return true
      sleep(20)
    condition()

  proc startBridge(daemon: Daemon; dir: string): Process =
    startProcess(cliPath(), workingDir = dir, env = daemon.env,
      args = ["jobserver", "--width", "2:8", "--verbose", "--", "make"],
      options = {poStdErrToStdOut})

  suite "runquota jobserver follows the lease's width":
    prerequisite findExe("make").len > 0,
      "make is not on PATH (it is in the development shell)"

    test "widening_uses_free_slots: a neighbour's release widens the " &
        "bridge within one admission cycle and make runs 8 jobs":
      var daemon = startDaemon("rqjwide", 8000)
      defer: daemon.stop()
      var client = connectDefault()
      defer: client.close()
      var neighbourSession = client.registerSession("neighbour", "1")
      var neighbour = neighbourSession.requestLease(resourceRequest(
        "neighbour", milliCpu(6000), bytes(GiB)))
      let dir = daemon.root / "make"
      let log = daemon.root / "jobs.log"
      var sleeps: seq[string] = @[]
      for _ in 1 .. 12: sleeps.add "2"
      makeProject(dir, log, sleeps)
      var bridge = daemon.startBridge(dir)
      defer: bridge.close()
      check waitFor(proc (): bool = startedCount(log) >= 2, 30)
      sleep(500)
      let lease = client.bridgeLease()
      check lease != nil
      check lease["width"]["granted_milli"].getInt() == 2000
      let released = nowNanos()
      neighbour.release()
      # THE RELEASE'S OWN PASS raised the target: nothing else has happened
      # since, the bridge's next report included.
      let widened = client.bridgeLease()
      check widened["width"]["target_milli"].getInt() == 8000
      let code = bridge.waitForExit(120_000)
      let output = bridge.outputStream.readAll()
      checkpoint output
      check code == 0
      let evs = events(log)
      check evs.len == 24
      check peakBetween(evs, 0'i64, released) <= 2
      # The jobserver issued the six extra tokens: 8 at once after it.
      check peakBetween(evs, released, high(int64)) == 8
      neighbourSession.closeSession()

    test "narrowing_never_takes_running_tokens: 8 busy jobs, narrowed to " &
        "2, reach 2 only as jobs finish, and none is signalled":
      var daemon = startDaemon("rqjnarrow", 8000)
      defer: daemon.stop()
      var client = connectDefault()
      defer: client.close()
      var neighbourSession = client.registerSession("neighbour", "1")
      var neighbour = neighbourSession.requestLease(resourceRequest(
        "neighbour", milliCpu(6000), bytes(GiB)))
      let dir = daemon.root / "make"
      let log = daemon.root / "jobs.log"
      # Staggered: job k sleeps 3 + 0.7k s, so the eight overlap for about
      # three seconds and then end one at a time, 0.7 s apart.
      var sleeps: seq[string] = @[]
      for k in 1 .. 8:
        sleeps.add formatFloat(3.0 + 0.7 * float(k), ffDecimal, 1)
      makeProject(dir, log, sleeps)
      var bridge = daemon.startBridge(dir)
      defer: bridge.close()
      check waitFor(proc (): bool = startedCount(log) >= 2, 30)
      neighbour.release()
      check waitFor(proc (): bool = startedCount(log) == 8, 30)
      # Eight jobs busy. A waiter for 6 slots: the daemon narrows the
      # bridge's target back to its grant.
      var waiterSession = client.registerSession("waiter", "1")
      let offered = waiterSession.offerCandidates([toCandidate(1'u64,
        resourceRequest("waiter", milliCpu(6000), bytes(GiB)))])
      check offered.len == 1 and offered[0].queued
      let narrowedAt = nowNanos()
      check client.bridgeLease()["width"]["target_milli"].getInt() == 2000
      var grantedAt = 0'i64
      var waiterLease: RunQuotaLease
      let deadline = getMonoTime() + initDuration(seconds = 60)
      while grantedAt == 0 and getMonoTime() < deadline:
        for grant in waiterSession.pollNextGrant():
          if not grant.queued and grant.lease.active:
            grantedAt = nowNanos()
            waiterLease = grant.lease
        if grantedAt == 0: sleep(20)
      check grantedAt != 0
      let code = bridge.waitForExit(120_000)
      let output = bridge.outputStream.readAll()
      checkpoint output
      check code == 0
      let evs = events(log)
      var ends: seq[int64] = @[]
      var starts: array[1 .. 8, int64]
      var signalled = 0
      for ev in evs:
        if ev.stamp < 0: inc signalled
        elif ev.start: starts[ev.job] = ev.stamp
        else:
          ends.add ev.stamp
          # Not cut short: the job slept its whole time.
          let wanted = int64((3.0 + 0.7 * float(ev.job)) * 1e9)
          check ev.stamp - starts[ev.job] >= wanted
      check signalled == 0
      check ends.len == 8
      ends.sort()
      # All eight were running when the narrowing came.
      check ends[0] > narrowedAt
      # Granted only once the bridge was down to 2 -- six jobs finished --
      # and before the seventh: the bridge kept the returned tokens.
      check grantedAt >= ends[5]
      check grantedAt < ends[6]
      if grantedAt != 0:
        waiterLease.release()
      waiterSession.closeSession()
      neighbourSession.closeSession()
