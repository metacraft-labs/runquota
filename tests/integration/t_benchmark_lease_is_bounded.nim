## A benchmark lease cannot halt a host-wide daemon's admission for longer
## than the host file allows (reprobuild-pm issue
## 2026-11-12-any-user-can-halt-admission-for-the-whole-host-with-an-unbounded-benchmark-lease).
##
## WHAT IS GUARDED, each with the mutation that breaks it:
##
## 1. A QUEUED benchmark that waits for the host to drain is denied after
##    `[benchmark] max-queue-wait`, and the work lease it was gating is then
##    granted although the first work lease still runs. Mutation: drop
##    `enforceBenchmarkBounds`' queued arm and the benchmark waits (and gates
##    the second work lease) for as long as the first one runs.
## 2. A GRANTED benchmark stops gating after `[benchmark] max-hold`: a work
##    lease that fits beside it is granted then. Mutation: drop the held arm
##    and the work lease waits for the benchmark's release (a crashed
##    supervisor's benchmark would block admission until the orphan policy).
##
## NOT HERE: the refusal of a user who is neither the daemon's user, root nor
## listed needs a second uid this suite cannot become; that decision is a pure
## function covered in `libs/runquota_daemon/tests/t_benchmark_policy`.
##
## NO MOCKS: the built `runquotad`, a real socket, the real client library.

when defined(posix):
  import std/[os, times, unittest]

  import runquota_client
  import runquota_core
  import private_daemon_fixture

  const GiB = 1024'u64 * 1024'u64 * 1024'u64

  let root = scratchDir("rqbench")
  let socket = root / "d.sock"
  writeFile(root / "host.toml",
    "schema = \"runquota.host-config.v1\"\n[benchmark]\n" &
    "max-queue-wait = \"2s\"\nmax-hold = \"2s\"\n")
  var daemon = launch(root, socket, privateEnv(socket),
    ["--cpu-milli", "4000", "--memory-bytes", $(16'u64 * GiB)])
  prerequisite awaitSocket(daemon, socket),
    daemon.startupContext("the daemon did not bind " & socket)
  putEnv("RUNQUOTA_ENDPOINT_SCOPE", "private")
  putEnv("RUNQUOTA_SOCKET", socket)
  delEnv("RUNQUOTA_SESSION")

  proc work(milli: uint32): ResourceRequest =
    resourceRequest("host", milliCpu(milli), bytes(1'u64 * GiB))

  suite "a benchmark lease is bounded":
    test "a queued benchmark is denied after max-queue-wait and unblocks work":
      var client = connectDefault()
      defer: client.close()
      var holder = client.registerSession("holder", "1")
      var running = holder.requestLeaseWaiting(work(1000), 20, 100)
      var bencher = client.registerSession("bencher", "1")
      var other = client.registerSession("other", "1")
      # Queue the benchmark behind the running lease, then a work lease that
      # would fit but is gated by it.
      let offer = bencher.sendCandidateOffer([toCandidate(900'u64,
        benchmarkRequest(work(2000)))])
      let decisions = bencher.receiveCandidateDecisions(offer)
      check decisions.len == 1
      check decisions[0].queued
      let started = epochTime()
      var granted = other.requestLeaseWaiting(work(1000), 20, 1000)
      let waited = epochTime() - started
      check granted.active
      check waited >= 1.0     # it really was gated while the benchmark queued
      check waited < 8.0      # and released by the bound, not by `running`
      check client.daemonStatus().activeLeases == 2'u32
      # The benchmark's session is told it was denied, not left waiting.
      var denied = false
      for _ in 0 ..< 50:
        for grant in bencher.pollNextGrant():
          if grant.clientCandidateId == 900'u64 and not grant.lease.active:
            denied = true
        if denied: break
        sleep(20)
      check denied
      granted.release()
      running.release()
      other.closeSession()
      bencher.closeSession()
      holder.closeSession()

    test "a granted benchmark stops gating after max-hold":
      var client = connectDefault()
      defer: client.close()
      var bencher = client.registerSession("bencher", "1")
      var bench = bencher.requestLeaseWaiting(benchmarkRequest(work(1000)),
        20, 200)
      check bench.active
      var other = client.registerSession("other", "1")
      let started = epochTime()
      var granted = other.requestLeaseWaiting(work(1000), 20, 1000)
      let waited = epochTime() - started
      check granted.active
      check waited >= 1.0
      check waited < 8.0
      granted.release()
      bench.release()
      # Releasing a benchmark whose gate was already released must not
      # corrupt the count: a fresh benchmark is granted at once.
      var again = bencher.requestLeaseWaiting(benchmarkRequest(work(1000)),
        20, 100)
      check again.active
      again.release()
      other.closeSession()
      bencher.closeSession()

  stopOwned(daemon)
  removeDir(root)
else:
  echo "t_benchmark_lease_is_bounded: POSIX only"
