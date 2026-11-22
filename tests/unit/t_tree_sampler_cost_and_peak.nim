## The launching client's tree sampler: what it costs, and that what it
## costs buys a peak the totals cannot give.
##
## WHAT IS GUARDED.
##
## 1. A WALK ONLY WHEN A SAMPLE IS DUE. However often the caller polls, the
##    launcher reads its tree at most once per `tree-sampling` interval
##    (0.1 s), never at the first poll after the fork, and with only
##    `profiles` on, once per profile interval (1 s). With both on, a walk
##    due for both is one walk, and the profile adds a walk of its own only
##    when its interval ends between two tree samples: at most one per
##    profile interval. Counted with `LaunchedProcess.treeWalks`, so the
##    rule is asserted on the work done.
##
##    THE BOUND IS THE RUN'S MEASURED LENGTH, NOT ITS NOMINAL ONE. Each case
##    times its own run, launch to completion, and allows one walk per
##    interval that has passed. A run longer than its nominal `sleep` is
##    walked more often, and that is the specified cadence, not a defect:
##    a fixed bound of 14 walks for `sleep 1` failed with 15, 16 and 24
##    walks on loaded hosts (load 24-25 on nixos-ci-bare-002), where the run
##    took up to 2.3 s. To recreate those conditions on demand, run the test
##    binary under a CPU quota:
##    `systemd-run --user --scope -p CPUQuota=2% -- ./t_tree_sampler_cost_and_peak`.
##    Falsifying mutation: walk the tree at every poll regardless of the
##    cadence; the 1 ms poll loop below then makes hundreds of walks in a
##    run of a second or two, and every bound fails.
## 2. THE SAMPLED PEAK IS THE TREE'S. Four processes each holding 48 MiB at
##    once are sampled as one tree, so the completion's peak exceeds what
##    the totals alone report -- `ru_maxrss`, the largest SINGLE process --
##    by well over twice. Falsifying mutation: report `ru_maxrss` as the
##    peak instead of the sampled sum; the check that the peak exceeds twice
##    `ru_maxrss` then fails.
## 3. The cheaper walk reads the same tree: process count and summed
##    resident memory for a tree of a shell and its children.
##
## FIXTURE: this test binary re-executes itself as the memory holder
## (`--hold MIB SECONDS`), so the workload depends on nothing outside this
## file. NO MOCKS: real processes, the real `/proc`.

when defined(linux):
  import std/[math, monotimes, os, strutils, times, unittest]

  import runquota_core
  import runquota_process

  import host_true_command

  const
    measurementVariable = "RUNQUOTA_MEASUREMENT"
    holdMiB = 48
    holders = 4
    treeSampleIntervalSeconds = 0.1
      ## `runquota_process`'s `treeSampleIntervalSeconds`, which it does not
      ## export; the header above states the same interval.
    profileIntervalSeconds = BaseCpuProfileIntervalMillis.float / 1000.0
      ## The profile's first interval. It doubles only once a profile holds
      ## `MaxCpuProfileSamples` samples, far beyond these few seconds.
    launcherClockSeconds = 0.001
      ## The profile's due test reads a monotonic clock truncated to whole
      ## milliseconds at the launch and at each poll, so a profile walk can
      ## come up to 1 ms before a full interval has really passed.

  if paramCount() >= 3 and paramStr(1) == "--hold":
    # Allocate and TOUCH every page, so the resident set really is that
    # large, then hold it.
    let bytes = parseInt(paramStr(2)) * 1024 * 1024
    var held = newSeq[byte](bytes)
    var i = 0
    while i < bytes:
      held[i] = byte(i and 0xff)
      i += 4096
    sleep(int(parseFloat(paramStr(3)) * 1000.0))
    # Keep the block alive to here.
    if held[bytes - 4096] == 7: echo ""
    quit(0)

  let self = getAppFilename()

  proc withMeasurement(value: string; body: proc ()) =
    let had = existsEnv(measurementVariable)
    let previous = getEnv(measurementVariable)
    putEnv(measurementVariable, value)
    try:
      body()
    finally:
      if had: putEnv(measurementVariable, previous)
      else: delEnv(measurementVariable)

  proc pollTightly(argv: seq[string]): LaunchedProcess =
    ## Polls every millisecond -- ten times as often as `waitForCompletion`
    ## -- so a sampler that walked at every poll could not hide.
    result = launchProcess(commandSpec(argv))
    while not result.pollCompletion():
      sleep(1)

  proc pollTightlyTimed(argv: seq[string];
                        elapsedSeconds: var float): LaunchedProcess =
    ## `pollTightly`, timed from before the launch to the completion. Every
    ## walk falls inside that span, so it bounds the walks the cadence
    ## allows however long the host made the run.
    let started = getMonoTime()
    result = pollTightly(argv)
    elapsedSeconds = (getMonoTime() - started).inNanoseconds.float / 1e9

  proc treeWalksAllowed(elapsedSeconds: float): float =
    ## One tree walk per tree interval that has passed: each comes at least
    ## one interval after the launch or the previous one.
    elapsedSeconds / treeSampleIntervalSeconds

  proc profileWalksAllowed(elapsedSeconds: float): float =
    ## One profile walk per profile interval that has passed, on the
    ## launch-relative grid (`CpuProfileSampler.nextDueMillis`).
    floor((elapsedSeconds + launcherClockSeconds) / profileIntervalSeconds)

  suite "tree sampler cost":
    test "tree sampling walks the tree only when a sample is due":
      withMeasurement("tree-sampling=on,profiles=off") do ():
        var elapsedSeconds = 0.0
        let child = pollTightlyTimed(@["/bin/sh", "-c", "sleep 1"],
                                     elapsedSeconds)
        checkpoint "walks: " & $child.treeWalks & " in " & $elapsedSeconds & " s"
        check child.completion.exited
        check child.completion.exitCode == 0
        # One walk per 0.1 s of a run of at least 1 s, none at launch: about
        # 10 on an idle host, more when the host stretches the run.
        check child.treeWalks >= 5'u32
        check child.treeWalks.float <= treeWalksAllowed(elapsedSeconds)
        check child.completion.peakResidentMemoryBytes > 0'u64

    test "profiles alone walk once per profile interval":
      withMeasurement("tree-sampling=off,profiles=on") do ():
        var elapsedSeconds = 0.0
        let child = pollTightlyTimed(@["/bin/sh", "-c", "sleep 2.2"],
                                     elapsedSeconds)
        checkpoint "walks: " & $child.treeWalks & " in " & $elapsedSeconds & " s"
        check child.completion.exited
        check child.completion.exitCode == 0
        # Due at 1 s and 2 s of a 2.2 s run: 2 walks on an idle host.
        check child.treeWalks >= 1'u32
        check child.treeWalks.float <= profileWalksAllowed(elapsedSeconds)
        check child.completion.cpuProfile.present

    test "both on share one walk":
      withMeasurement("tree-sampling=on,profiles=on") do ():
        var elapsedSeconds = 0.0
        let child = pollTightlyTimed(@["/bin/sh", "-c", "sleep 1"],
                                     elapsedSeconds)
        checkpoint "walks: " & $child.treeWalks & " in " & $elapsedSeconds & " s"
        check child.completion.exited
        check child.completion.exitCode == 0
        # The tree's walks, plus at most one of the profile's own per profile
        # interval: about 11 on an idle host.
        check child.treeWalks.float <= treeWalksAllowed(elapsedSeconds) +
          profileWalksAllowed(elapsedSeconds)
        check child.completion.cpuProfile.present

    test "a command shorter than one interval is not walked at all":
      withMeasurement("tree-sampling=on,profiles=on") do ():
        # `true` as this host has it: there is no `/bin/true` on NixOS.
        let command = trueCommand()
        let started = getMonoTime()
        let child = pollTightly(@[command])
        let elapsedSeconds = (getMonoTime() - started).inNanoseconds.float / 1e9
        # THE COMMAND RAN. A launch whose exec failed is just as short and
        # is not walked either, so without these two the case would pass
        # having measured no command at all (exit 127).
        check child.completion.exited
        check child.completion.exitCode == 0
        # NOT WALKED BEFORE AN INTERVAL HAS PASSED. `true` usually exits well
        # inside one 0.1 s interval, and then this is "no walk at all". On a
        # loaded host it can take longer -- 1 walk and 3 walks were seen at
        # load 20-30 on nixos-ci-bare-002 -- and then one walk per interval
        # that has passed is the specified behaviour, not a defect. The bound
        # is the elapsed time this test measured, which covers the child's
        # whole life, so a sampler that walked at launch or at every 1 ms
        # poll still fails it.
        checkpoint "walks: " & $child.treeWalks & " in " & $elapsedSeconds & " s"
        # Profiles are on too, so a run stretched past a profile interval
        # may also take the profile's walk.
        check child.treeWalks.float <= treeWalksAllowed(elapsedSeconds) +
          profileWalksAllowed(elapsedSeconds)
        # Its peak then comes from the totals, which the daemon takes.
        check child.completion.totals.known
        check child.completion.totals.maxRssBytes > 0'u64

  suite "tree sampler peak":
    test "a sampled peak exceeds ru_maxrss for a tree of concurrent processes":
      withMeasurement("tree-sampling=on") do ():
        var script = ""
        for i in 0 ..< holders:
          script.add(quoteShell(self) & " --hold " & $holdMiB & " 1.5 & ")
        script.add("wait")
        var child = launchProcess(commandSpec(@["/bin/sh", "-c", script]))
        let completion = child.waitForCompletion()
        check completion.exited
        check completion.exitCode == 0
        let peak = completion.peakResidentMemoryBytes
        let single = completion.totals.maxRssBytes
        checkpoint "sampled peak " & $peak & " B, ru_maxrss " & $single & " B"
        check completion.totals.known
        # ONE holder's worth, at least: the control that `ru_maxrss` saw a
        # holder at all, so the comparison below is not against nothing.
        check single >= uint64(holdMiB) * 1024'u64 * 1024'u64
        # The four held at once, sampled as one tree.
        check peak > 2'u64 * single
        check peak >= uint64(holders * holdMiB) * 1024'u64 * 1024'u64 * 3'u64 div 4'u64
        check completion.processCount >= uint32(holders + 1)
