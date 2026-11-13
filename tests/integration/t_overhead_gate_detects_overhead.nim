## The measurement overhead gate detects an overhead it must detect, passes
## one it must pass, and never passes when it ran out of rounds.
##
## WHAT IS UNDER TEST is the gate's decision procedure as the real gate runs
## it -- `runGate` from `benchmarks/lib/runquota_overhead_gate.nim`, with its
## interleaving, its warm-up, its stopping rule and its verdict -- driven by
## the gate's own `synthetic` case: real child processes, timed by the same
## `wait4` rusage path the Reprobuild case uses, burning a fixed amount of CPU.
##
## THE INJECTED OVERHEAD. In the ON arm each child burns 2% more. That is
## twice the 1% budget, so the gate must FAIL it.
##
## THE DISTURBANCE, AND WHY IT IS HERE. A shared host does not deliver
## uniform noise: a burst of foreign load lands on whatever happens to be
## running. The synthetic case models one such burst every 25 rounds, a 6%
## slowdown of the round's FIRST run, starting with round 0, whose first run
## is the OFF arm. That makes the very first pair show the ON arm about 4%
## FASTER than OFF despite the injected 2%. A gate that compared single runs
## would therefore pass the injected overhead, deterministically, whatever
## the host's own noise (which would have to exceed 5% in the right direction
## to rescue it). The interleaved, repeated gate is not fooled: the period is
## odd, so the disturbed arm alternates and the bursts cancel in the mean.
##
## FALSIFYING MUTATION: make `decide` (`runquota_overhead_gate/statistics`)
## judge the first round alone -- pass if that pair's on/off ratio is within
## the budget for wall and CPU -- and "a 2% injected overhead fails the gate"
## fails here.
##
## THE CONVERSE, so the gate is not simply always failing: with nothing
## injected (and the same disturbances) it passes. And a run cut short by the
## round limit is INCONCLUSIVE, not a pass.
##
## TIME. Three to five minutes on a loaded 32-CPU host. Each synthetic
## child burns about one second of CPU. That length is chosen for the noise,
## not for realism: on a shared host the wall time of a run carries a jitter
## of some tens of milliseconds that does not shrink with the run (start-up,
## wake-up latency), so a 0.27 s child had a per-round wall log-ratio
## spread of about 7% under a load of 10-20, and the no-overhead case could
## not reach +-0.5% within 500 rounds; one-second children measured about 2%
## on the same host, which needs about 60 rounds. The fail case stops as
## soon as the lower bound clears 1% (about 20 rounds). Each case has its
## own time limit, together under the suite's per-binary bound, and a host
## too noisy to reach precision within it is reported as inconclusive,
## which fails this test visibly rather than passing it.
##
## NO MOCKS. The synthetic workload is the gate's own instrument-check case,
## not a stand-in for a dependency: its children are real processes and its
## times are real `wait4` measurements. The disturbance is a deterministic
## workload change, justified above.

when defined(posix):
  import std/[os, tempfiles, unittest]

  import ../../benchmarks/lib/runquota_overhead_gate
  import ../../benchmarks/lib/runquota_overhead_gate/statistics

  # This binary is also the synthetic case's child.
  if serveSyntheticChild(commandLineParams()):
    quit 0

  proc syntheticConfig(injectPercent: float; maxRounds: int;
                       maxMinutes = 3.0): GateConfig =
    ## About one second of CPU per child (see TIME in the header).
    result = parseGateArgs(["--case=synthetic",
      "--burn-iterations=800000000",
      "--inject-percent=" & $injectPercent,
      "--disturbance-percent=6", "--disturbance-every=25",
      "--max-rounds=" & $maxRounds, "--max-minutes=" & $maxMinutes])
    result.syntheticChild = getAppFilename()

  proc runSynthetic(cfg: GateConfig): GateResult =
    let scratch = createTempDir("rqgate-test", "")
    defer: removeDir(scratch)
    let gateCase = makeCase(cfg, scratch)
    defer: gateCase.stop()
    result = runGate(cfg, gateCase, progress = false)
    checkpoint "verdict " & $result.decision.verdict & ": " &
      result.decision.reason & " after " & $result.rounds.len & " rounds"

  suite "measurement overhead gate":
    test "the first round alone would hide the injected overhead":
      # The premise of the falsifying mutation, checked rather than assumed:
      # in round 0 the OFF arm runs first and is disturbed, so the ON arm
      # does less work than OFF despite the injection.
      let cfg = syntheticConfig(2, 500)
      check firstArm(0) == armOff
      check cfg.disturbed(0, armOff)
      check not cfg.disturbed(0, armOn)
      let off0 = cfg.syntheticIterations(0, armOff)
      let on0 = cfg.syntheticIterations(0, armOn)
      check float(on0) / float(off0) < 0.97
      # The disturbed arm alternates, so bursts cancel over the run.
      check cfg.disturbed(25, armOn)
      check not cfg.disturbed(25, armOff)

    test "a 2% injected overhead fails the gate":
      let outcome = runSynthetic(syntheticConfig(2, 500))
      check outcome.decision.verdict == verdictFail
      check outcome.rounds.len >= defaultGatePolicy().minRounds

    test "no injected overhead passes the gate":
      let outcome = runSynthetic(syntheticConfig(0, 500, maxMinutes = 5.5))
      check outcome.decision.verdict == verdictPass
      for metric in GateMetric:
        check outcome.decision.estimates[metric].halfWidth <= 0.005
        check outcome.decision.estimates[metric].upper <= 0.01

    test "running out of rounds is inconclusive, never a pass":
      let outcome = runSynthetic(syntheticConfig(0, 10))
      check outcome.decision.verdict == verdictInconclusive
      check exitStatusFor(outcome.decision.verdict) == exitInconclusive
