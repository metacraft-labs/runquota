## A lease granted while the observation store is still opening is sampled.
##
## `serve` opens the store on a thread of its own (`captureOpenerMain`) and
## serves leases throughout, so a client can be granted a lease before the
## ambient sampler exists. The lease authority publishes its live-lease count
## on every grant and release (`setAmbientLiveLeaseCount`), and
## `startAmbientSampler` starts the sampler from a count of zero. Before the
## fix nothing republished the count when the store was handed over, so a
## lease granted before that point was not live to the sampler:
## - every tick of its run fell outside the live-lease gate;
## - no ambient sample covered it;
## - its finish was unjudged (`cvUnknown`) and taught the key nothing;
## - the second identical run then read an expected uncontended duration of 0.
##
## That is reprobuild-pm
## `issues/2026-11-16-runquota-expected-uncontended-duration-is-never-learned-on-a-loaded-host.md`,
## where `t_build_wait_pressure` read `learned == @[0, 0]`.
##
## WHAT IS GUARDED. The sampler counts a lease that was live when the store
## was installed, and takes samples over it. Mutation: drop the republish in
## `installCapture`, and the count reads 0 and the window holds no sample.
##
## The order `serve` uses is reproduced here: `initDaemon(deferCapture =
## true)`, a grant, `openCapture`, then `installCapture`. All of them are
## production procs, and no mocks are used. The lease is entered through
## `applyLeaseResourceUsage`, the proc every grant passes through, so that
## the order is deterministic rather than a race against a thread.

import std/[os, tables, tempfiles, unittest]

import runquota_core
import runquota_daemon {.all.}
import runquota_observation_store

proc testConfig(root: string): DaemonConfig =
  DaemonConfig(
    daemonId: 1'u64,
    cpuSlots: milliCpu(4000),
    memoryBytes: bytes(8_000_000_000'u64),
    ioSlots: 8'u32,
    machines: initTable[string, MachineCapacity](),
    cpuShareGroups: initTable[string, CpuShareGroup](),
    namedPoolCaps: initTable[string, uint32](),
    version: "test",
    estimateDbPath: root / "estimates.db",
    estimateQueueCapacity: 8,
    observationDbPath: root / "observations.sqlite3",
    hostIdentityFilePath: root / "host-id",
    captureOn: true,
    ambientSampleIntervalMillis: 20)

when defined(linux) or defined(macosx):
  suite "a lease live before the store is installed":
    test "the sampler counts it and samples its run":
      let root = createTempDir("runquota-live-before-capture", "")
      defer:
        try: removeDir(root) except CatchableError: discard
      var daemon = initDaemon(testConfig(root), deferCapture = true)
      # The grant, before the store is open: what a client that connects
      # right after the socket binds gets.
      let lease = LeaseRow(id: leaseId(1'u64),
        resources: resourceVector(milliCpu(1000), bytes(64'u64 shl 20)))
      daemon.applyLeaseResourceUsage(lease, add = true)
      require daemon.activeLeaseCount == 1'u32
      # The opener thread's work, then its hand-over.
      var setup = openCapture(daemon.config, true, daemon.observationBootId)
      daemon.installCapture(move setup)
      defer:
        stopAmbientSampler()
        stopRetentionSweeper()
        stopObservationWriter()
      require ambientSamplerActive()
      check ambientLiveLeaseCount() == 1
      # And the run is sampled: the window a finish would be judged on holds
      # samples (at 20 ms cadence, 400 ms leaves room for a slow first tick).
      let since = unixMillisNow()
      sleep(400)
      var busy = 0.0
      let samples = meanHostCpuBusyPct(since, unixMillisNow(), busy)
      checkpoint "samples in the window: " & $samples
      check samples > 0
