## The launching client's tree sampler: what it costs, and that what it
## costs buys a peak the totals cannot give.
##
## WHAT IS GUARDED.
##
## 1. A WALK ONLY WHEN A SAMPLE IS DUE. However often the caller polls, the
##    launcher reads its tree at most once per `tree-sampling` interval
##    (0.1 s), never at the first poll after the fork, and with only
##    `profiles` on, once per profile interval (1 s). With both on, one walk
##    serves both: no more walks than tree sampling alone. Counted with
##    `LaunchedProcess.treeWalks`, so the rule is asserted on the work done
##    and not on a stopwatch. Falsifying mutation: walk the tree at every
##    poll regardless of the cadence; the 1 ms poll loop below then makes
##    hundreds of walks and every bound fails.
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
  import std/[os, strutils, unittest]

  import runquota_core
  import runquota_process

  const
    measurementVariable = "RUNQUOTA_MEASUREMENT"
    holdMiB = 48
    holders = 4

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

  suite "tree sampler cost":
    test "tree sampling walks the tree only when a sample is due":
      withMeasurement("tree-sampling=on,profiles=off") do ():
        let child = pollTightly(@["/bin/sh", "-c", "sleep 1"])
        checkpoint "walks: " & $child.treeWalks
        # One walk per 0.1 s of a ~1 s run, none at launch: about 10. The
        # bound leaves room for a slow exit, not for a walk per poll.
        check child.treeWalks >= 5'u32
        check child.treeWalks <= 14'u32
        check child.completion.peakResidentMemoryBytes > 0'u64

    test "profiles alone walk once per profile interval":
      withMeasurement("tree-sampling=off,profiles=on") do ():
        let child = pollTightly(@["/bin/sh", "-c", "sleep 2.2"])
        checkpoint "walks: " & $child.treeWalks
        check child.treeWalks >= 1'u32
        check child.treeWalks <= 3'u32
        check child.completion.cpuProfile.present

    test "both on share one walk":
      withMeasurement("tree-sampling=on,profiles=on") do ():
        let child = pollTightly(@["/bin/sh", "-c", "sleep 1"])
        checkpoint "walks: " & $child.treeWalks
        check child.treeWalks <= 14'u32
        check child.completion.cpuProfile.present

    test "a command shorter than one interval is not walked at all":
      withMeasurement("tree-sampling=on,profiles=on") do ():
        let child = pollTightly(@["/bin/true"])
        check child.treeWalks == 0'u32
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
