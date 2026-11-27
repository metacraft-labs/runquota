## The launcher's memory-cap policy, shared by every launcher
## (`runquota_exec/memory_cap_launch`), over plain values: which cap a launch
## applies, what its finish says, and how a breach is reported.
##
## WHAT IS GUARDED.
##
## * `resolveMemoryCap`, EXHAUSTIVELY over the host file's three modes, the
##   variable's forms (unset, `off`, a size, `advisory`, `kill`, garbage), a
##   grant with and without a cap, and nested or not: the table in the switch
##   section of the memory-cap design, one assertion per cell. Mutations:
##   ignoring the variable (every `off`/size/mode row goes red), treating a
##   nested launcher like an outer one, and capping a lifted run.
## * `finishOutcome`: a cap kill with kill evidence is `lfCapExceeded`, an
##   outside OOM kill is `lfOomKilled`, either without evidence is not
##   stated, and a cap kill the launch did not measure is not named a cap
##   kill (the daemon would refuse it without its block).
## * `finishMemoryCap`: present only for a measured tree, with the
##   resolution's basis and the flags split as the protocol defines them.
## * `memoryCapReport`: the exact text shapes of the reporting section --
##   learned (both declaration forms, "killed"), advisory, `capReached`,
##   declared and run-size derivations, and the budget form that says "not a
##   regression" -- and no report without a breach.
## * `parseByteSize` / `formatBinaryBytes`: binary suffixes, refusals, one
##   decimal.
##
## NO MOCKS: pure functions over values.

import std/[strutils, unittest]

import runquota_core
import runquota_core/byte_sizes
import runquota_exec
import runquota_process
import runquota_protocol

const
  MiB = 1024'u64 * 1024'u64
  GiB = 1024'u64 * MiB

let learnedGrant = GrantMemoryCap(known: true, capBytes: 2'u64 * GiB,
  basis: mcbLearned, previousMaxBytes: 1'u64 * GiB, factorMilli: 2_000'u32,
  budgetBytes: 16'u64 * GiB)
let noGrant = GrantMemoryCap(known: false)

suite "resolveMemoryCap":
  test "unset: the host file decides, with the grant's cap":
    let off = resolveMemoryCap(learnedGrant, mcmOff, "", nested = false)
    check off.error.len == 0
    check off.capBytes == 0'u64 and not off.measure and not off.applies
    check off.basis == mcbNone
    check "off" in off.reason
    let advisory = resolveMemoryCap(learnedGrant, mcmAdvisory, "", false)
    check advisory.capBytes == 2'u64 * GiB and advisory.measure
    check advisory.action == mcaAdvisory and advisory.basis == mcbLearned
    let kill = resolveMemoryCap(learnedGrant, mcmKill, "", false)
    check kill.capBytes == 2'u64 * GiB and kill.measure
    check kill.action == mcaKill and kill.basis == mcbLearned
    check kill.reason.len == 0

  test "a grant without a cap leaves nothing to apply, and says why":
    for mode in [mcmAdvisory, mcmKill]:
      let r = resolveMemoryCap(noGrant, mode, "", false)
      check r.error.len == 0 and not r.applies
      check r.reason == "the daemon granted no memory cap"
    for value in ["advisory", "kill"]:
      let r = resolveMemoryCap(noGrant, mcmOff, value, false)
      check not r.applies
      check r.reason == "the daemon granted no memory cap"
    # A zero cap would kill on the first page: none instead.
    let zero = GrantMemoryCap(known: true, capBytes: 0'u64, basis: mcbBudget)
    check not resolveMemoryCap(zero, mcmKill, "", false).applies

  test "off lifts the cap, still measured where the host file has it on":
    for (mode, measured, action) in [(mcmOff, false, mcaKill),
        (mcmAdvisory, true, mcaAdvisory), (mcmKill, true, mcaKill)]:
      checkpoint($mode)
      for grant in [learnedGrant, noGrant]:
        let r = resolveMemoryCap(grant, mode, "off", false)
        check r.error.len == 0
        check r.capBytes == 0'u64
        check r.basis == mcbRunLifted
        check r.measure == measured
        check r.action == action
        check "lifted" in r.reason

  test "a size is this run's cap, in the host file's mode or kill":
    for (mode, action) in [(mcmOff, mcaKill), (mcmAdvisory, mcaAdvisory),
        (mcmKill, mcaKill)]:
      checkpoint($mode)
      for grant in [learnedGrant, noGrant]:
        let r = resolveMemoryCap(grant, mode, "3G", false)
        check r.error.len == 0
        check r.capBytes == 3'u64 * GiB
        check r.basis == mcbRunSize
        check r.measure and r.action == action
    check resolveMemoryCap(learnedGrant, mcmKill, " 512M ", false).capBytes ==
      512'u64 * MiB
    check resolveMemoryCap(learnedGrant, mcmKill, "1048576", false).capBytes ==
      1'u64 * MiB
    check resolveMemoryCap(learnedGrant, mcmKill, "2T", false).capBytes ==
      2'u64 * 1024'u64 * GiB

  test "advisory and kill set the mode for this run, whatever the file says":
    for mode in [mcmOff, mcmAdvisory, mcmKill]:
      checkpoint($mode)
      let advisory = resolveMemoryCap(learnedGrant, mode, "advisory", false)
      check advisory.capBytes == 2'u64 * GiB and advisory.measure
      check advisory.action == mcaAdvisory and advisory.basis == mcbLearned
      let kill = resolveMemoryCap(learnedGrant, mode, "kill", false)
      check kill.capBytes == 2'u64 * GiB and kill.action == mcaKill
      check kill.basis == mcbLearned

  test "anything else is refused, naming the variable":
    for value in ["on", "OFF", "Kill", "0", "-1G", "1.5G", "2GB", "lots", "1K2"]:
      checkpoint(value)
      for mode in [mcmOff, mcmKill]:
        for nested in [false, true]:
          let r = resolveMemoryCap(learnedGrant, mode, value, nested)
          check r.error.len > 0
          check MemoryCapEnvVar in r.error
          check value in r.error
          check not r.applies

  test "a nested launcher applies no cap, whatever the file and the variable":
    for mode in [mcmOff, mcmAdvisory, mcmKill]:
      for value in ["", "off", "advisory", "kill", "4G"]:
        checkpoint($mode & " " & value)
        let r = resolveMemoryCap(learnedGrant, mode, value, nested = true)
        check r.error.len == 0
        check not r.applies and r.capBytes == 0'u64
        check "parent lease" in r.reason

  test "applyMemoryCap puts the resolution on the launch":
    var spec = commandSpec(@["true"])
    spec.applyMemoryCap(resolveMemoryCap(learnedGrant, mcmAdvisory, "", false))
    check spec.memoryCapBytes == 2'u64 * GiB
    check spec.memoryCapAction == mcaAdvisory
    check spec.memoryCapMeasure
    var lifted = commandSpec(@["true"])
    lifted.applyMemoryCap(resolveMemoryCap(learnedGrant, mcmKill, "off", false))
    check lifted.memoryCapBytes == 0'u64 and lifted.memoryCapMeasure

proc completion(exitCode = 0; signal = 0; measured = true;
                capKilled = false; outside = false; reached = false;
                exceeded = false; peak = 0'u64): ProcessCompletion =
  result = ProcessCompletion(exited: signal == 0, exitCode: exitCode,
    signaled: signal != 0, signal: signal, memoryCapBytes: 2'u64 * GiB,
    memoryCapMeasured: measured, memoryPeakBytes: peak,
    memoryPeakSource: mpsCgroup, capKilled: capKilled,
    oomKilledOutsideCap: outside, capReached: reached,
    capExceeded: exceeded or capKilled)

suite "finishOutcome and finishMemoryCap":
  test "a cap kill with evidence is cap-exceeded; from outside, an OOM kill":
    let bySignal = finishOutcome(completion(signal = 9, capKilled = true))
    check bySignal.kind == lfCapExceeded and bySignal.kill.signal == 9'u32
    let byStatus = finishOutcome(completion(exitCode = 137, capKilled = true))
    check byStatus.kind == lfCapExceeded and not byStatus.kill.bySignal
    check byStatus.kill.exitCode == 137'u32
    let outside = finishOutcome(completion(signal = 9, outside = true))
    check outside.kind == lfOomKilled and outside.kill.signal == 9'u32

  test "without kill evidence no kill is stated":
    check finishOutcome(completion(capKilled = true)).kind == lfSucceeded
    check finishOutcome(completion(outside = true)).kind == lfSucceeded

  test "a cap kill the launch did not measure is an OOM kill":
    let unmeasured = finishOutcome(completion(signal = 9, capKilled = true,
      measured = false))
    check unmeasured.kind == lfOomKilled

  test "ordinary endings are unchanged":
    check finishOutcome(completion()).kind == lfSucceeded
    check finishOutcome(completion(exitCode = 3)).kind == lfFailed
    check finishOutcome(completion(signal = 11)).kind == lfCrashed

  test "the block: present for a measured tree, flags as the protocol says":
    let resolution = resolveMemoryCap(learnedGrant, mcmAdvisory, "", false)
    let advisory = completion(measured = true, exceeded = true,
      peak = 3'u64 * GiB).finishMemoryCap(resolution)
    check advisory.present and advisory.exceededAdvisory
    check not advisory.capReached
    check advisory.basis == mcbLearned
    check advisory.treePeakBytes == 3'u64 * GiB
    check advisory.capBytes == 2'u64 * GiB
    check advisory.peakSource == mpsCgroup
    let killed = completion(signal = 9, capKilled = true,
      peak = 2'u64 * GiB).finishMemoryCap(resolution)
    check killed.present and not killed.breached # the kill is the conclusion
    let reached = completion(reached = true,
      peak = 2'u64 * GiB).finishMemoryCap(resolution)
    check reached.capReached and reached.breached
    check not completion(measured = false).finishMemoryCap(resolution).present
    let none = resolveMemoryCap(learnedGrant, mcmOff, "", false)
    check not completion().finishMemoryCap(none).present

suite "memoryCapReport":
  test "a learned cap exceeded and killed: the regression report":
    let killedBlock = FinishMemoryCap(present: true, capBytes: 2'u64 * GiB,
      basis: mcbLearned, treePeakBytes: 2'u64 * GiB, peakSource: mpsCgroup)
    let report = memoryCapReport("cc big.c", "cc-big", learnedGrant,
      killedBlock, killed = true)
    check report ==
      "runquota: memory cap exceeded: cc big.c (command id cc-big)\n" &
      "  cap 2.0 GiB = 2 × the largest successful peak, 1.0 GiB; peak 2.0 GiB; killed\n" &
      "  If this growth is expected:\n" &
      "    for one run:     RUNQUOTA_MEMORY_CAP=off   (or RUNQUOTA_MEMORY_CAP=<size>)\n" &
      "    from now on:     runquota expect-growth cc-big --to <size>\n" &
      "  Otherwise it is a memory regression: report it to the project that owns\n" &
      "  this command.\n"

  test "advisory and capReached replace only the outcome":
    let advisory = memoryCapReport("x", "k", learnedGrant, FinishMemoryCap(
      present: true, capBytes: 2'u64 * GiB, basis: mcbLearned,
      treePeakBytes: 3'u64 * GiB, exceededAdvisory: true), killed = false)
    check "memory cap exceeded: x (command id k)" in advisory
    check "; peak 3.0 GiB; not killed (advisory)\n" in advisory
    check "runquota expect-growth k --to <size>" in advisory
    let reached = memoryCapReport("x", "k", learnedGrant, FinishMemoryCap(
      present: true, capBytes: 2'u64 * GiB, basis: mcbLearned,
      treePeakBytes: 2'u64 * GiB, capReached: true), killed = false)
    check "memory cap reached: x (command id k)" in reached
    check "; an allocation was refused at the cap\n" in reached

  test "a factor that is not whole, a declared cap and a run's size":
    var grant = learnedGrant
    grant.factorMilli = 1_500'u32
    grant.capBytes = 1536'u64 * MiB
    let fractional = memoryCapReport("x", "k", grant, FinishMemoryCap(
      present: true, capBytes: 1536'u64 * MiB, basis: mcbLearned,
      treePeakBytes: 1600'u64 * MiB), killed = true)
    check "cap 1.5 GiB = 1.5 × the largest successful peak, 1.0 GiB" in
      fractional
    let declared = memoryCapReport("x", "k", learnedGrant, FinishMemoryCap(
      present: true, capBytes: 8'u64 * GiB, basis: mcbDeclared,
      treePeakBytes: 8'u64 * GiB), killed = true)
    check "cap 8.0 GiB = the declared growth (runquota expect-growth)" in
      declared
    let sized = memoryCapReport("x", "k", noGrant, FinishMemoryCap(
      present: true, capBytes: 512'u64 * MiB, basis: mcbRunSize,
      treePeakBytes: 512'u64 * MiB), killed = true)
    check "cap 512.0 MiB = RUNQUOTA_MEMORY_CAP for this run" in sized

  test "a budget cap: not a regression":
    let grant = GrantMemoryCap(known: true, capBytes: 6656'u64 * MiB,
      basis: mcbBudget, factorMilli: 2_000'u32, budgetBytes: 16'u64 * GiB)
    let report = memoryCapReport("make", "make-all", grant, FinishMemoryCap(
      present: true, capBytes: 6656'u64 * MiB, basis: mcbBudget,
      treePeakBytes: 6656'u64 * MiB), killed = true)
    check report ==
      "runquota: stopped at the memory free when it started: make (command id make-all)\n" &
      "  cap 6.5 GiB = the host budget 16.0 GiB minus 9.5 GiB granted to other work;\n" &
      "  no successful run of this command is recorded yet, so it had no learned\n" &
      "  cap. This is not a regression. The next run waits for more free memory.\n"

  test "no breach, no report":
    check memoryCapReport("x", "k", learnedGrant, FinishMemoryCap(
      present: true, capBytes: 2'u64 * GiB, basis: mcbLearned,
      treePeakBytes: 1'u64 * GiB), killed = false) == ""
    check memoryCapReport("x", "k", learnedGrant,
      FinishMemoryCap(present: false), killed = false) == ""

suite "sizes":
  test "parseByteSize takes bytes and binary suffixes, and nothing else":
    var value = 0'u64
    for (text, bytes) in [("1", 1'u64), ("4K", 4'u64 * 1024'u64),
        ("4KiB", 4'u64 * 1024'u64), ("3M", 3'u64 * MiB), ("3MiB", 3'u64 * MiB),
        ("2G", 2'u64 * GiB), ("2GiB", 2'u64 * GiB),
        ("1T", 1024'u64 * GiB), ("1TiB", 1024'u64 * GiB)]:
      checkpoint(text)
      check parseByteSize(text, value) and value == bytes
    for text in ["", "0", "0G", "G", "-1", "1.5G", "1GB", "1g", "1 G",
        "99999999999999999999", "20000000T"]:
      checkpoint(text)
      value = 7'u64
      check not parseByteSize(text, value)
      check value == 7'u64

  test "formatBinaryBytes: the largest unit, one decimal":
    check formatBinaryBytes(512'u64) == "512 bytes"
    check formatBinaryBytes(1536'u64) == "1.5 KiB"
    check formatBinaryBytes(1'u64 * GiB) == "1.0 GiB"
    check formatBinaryBytes(6656'u64 * MiB) == "6.5 GiB"
    check formatBinaryBytes(1023'u64 * MiB) == "1023.0 MiB"
    check formatBinaryBytes(2'u64 * GiB - 1'u64) == "2.0 GiB"
    check formatBinaryBytes(high(uint64)) == "16777216.0 TiB"
