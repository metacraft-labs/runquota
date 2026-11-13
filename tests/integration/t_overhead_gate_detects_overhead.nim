## The measurement overhead gate detects an overhead it must detect, passes
## one it must pass, and never passes when it ran out of rounds.
##
## WHAT IS UNDER TEST is the gate's decision procedure as the real gate runs
## it -- `runGate` from `benchmarks/lib/runquota_overhead_gate.nim`, with its
## warm-up pair, its interleaving, its stopping rule and its verdict, and
## `decide` from its `statistics` module -- not a copy of either. Only the
## source of the per-run costs differs between the cases below.
##
## TWO COST SOURCES, AND WHY.
##
## * A SEEDED COST MODEL drives the decision cases (pass, fail, out of
##   rounds). It is a `GateCase` like the gate's own: its `run` returns a
##   `RunCost` per arm and round, and `runGate` cannot tell it from a
##   process. The work of a run is the gate's own synthetic workload
##   (`syntheticIterations`: the base, the injected overhead in the ON arm,
##   the periodic disturbance), turned into seconds at a fixed rate and
##   multiplied by seeded log-normal noise: a level shared by both arms of a
##   round (a slow round is slow for both, which the gate's ratio removes),
##   per-run CPU noise, and extra per-run wall noise on top of it. Per-round
##   log-ratio spreads come out at about 1.4% for CPU and 2% for wall, the
##   spread one-second real children showed on a quiet host, so the gate
##   needs dozens of rounds to reach its precision, as it does for real.
##
##   This is the one mock-like part of the test, and it is here because the
##   real thing cannot answer the question deterministically on the hosts
##   this suite runs on. A real child's WALL time on a shared host under
##   foreign load is decided by the scheduler, not by the child: measured
##   with 32 busy loops on a 32-CPU host, one-second children gave a per-round
##   wall log-ratio spread of about 13% (CPU time: about 1.6%). Reaching
##   +-0.5% at that spread takes thousands of rounds, so a real
##   no-overhead run ends inconclusive however correct the gate is -- which
##   is the gate's honest answer about that host, and says nothing about its
##   decision logic. What these cases must show is the decision logic, so
##   they feed it costs whose distribution is known.
##
## * REAL CHILD PROCESSES drive one case, so the real measurement path is
##   still exercised end to end: the gate's own `synthetic` case, children
##   spawned and timed through the same `wait4` rusage path as the
##   Reprobuild case, with a 2% overhead injected. The gate must reach a
##   FAIL verdict. It can do so on CPU time alone, which stays precise under
##   foreign load (see the spreads above), so this case does not depend on
##   the host being quiet; a host so loaded that even CPU time cannot
##   establish the overhead within the time limit ends inconclusive, which
##   fails this test visibly rather than passing it. Real processes are not
##   used for the no-overhead pass, for the reason given above.
##
## THE INJECTED OVERHEAD. In the ON arm each run does 2% more work. That is
## twice the 1% budget, so the gate must FAIL it.
##
## THE DISTURBANCE. A burst of foreign load lands on whatever happens to be
## running. Both cost sources model one burst every 25 rounds, a 6% slowdown
## of the round's FIRST run, starting with round 0, whose first run is the
## OFF arm. That makes the very first pair show the ON arm about 4% FASTER
## than OFF despite the injected 2%. A gate that compared single runs would
## therefore pass the injected overhead. The interleaved, repeated gate is
## not fooled: the period is odd, so the disturbed arm alternates and the
## bursts cancel in the mean.
##
## FALSIFYING MUTATION: make `decide` (`runquota_overhead_gate/statistics`)
## judge the first round alone -- pass if that pair's on/off ratio is within
## the budget for wall and CPU -- and "a 2% injected overhead fails the
## gate" fails here, for every seed and for the real processes.
##
## SEEDS, NOT ONE LUCKY DRAW. Each decision case runs the gate over many
## seeds and asserts on all of them, so it states a property of the gate
## under this noise rather than of one sequence. The pass case cannot demand
## a pass for every seed, and must not: with no true overhead, the gate stops
## at a half-width of 0.5% and passes only when the upper bound is within
## 1%, so it fails a truly free measurement whenever the mean lands more
## than 1.96 standard errors high -- about 2.5% of runs per metric, by
## design (`statistics.nim`, "LOOKING AFTER EVERY ROUND"). The case
## therefore asserts that every seed reaches a decision, that at least 90%
## of them pass, and that every pass meets the precision and the budget.
## The model is deterministic, so the count is fixed; the threshold states
## what the design promises, with room for the expected few.
##
## TIME. The seeded cases take well under a second. The real-process case
## stops as soon as its CPU lower bound clears 1%, about 15-30 rounds of
## two one-second children, so a minute or two on a loaded host.

when defined(posix):
  import std/[json, math, os, random, tempfiles, unittest]

  import ../../benchmarks/lib/runquota_overhead_gate
  import ../../benchmarks/lib/runquota_overhead_gate/process_cost
  import ../../benchmarks/lib/runquota_overhead_gate/statistics

  # This binary is also the synthetic case's child.
  if serveSyntheticChild(commandLineParams()):
    quit 0

  const
    burnIterations = 800_000_000
      ## About one second of CPU per real child.
    seeds = 1 .. 60
    secondsPerIteration = 1.25e-9
      ## The seeded model's rate: about one second per run, like the real
      ## children. Only ratios matter to the gate; this keeps the figures in
      ## its report plausible.
    roundLevelSigma = 0.05
      ## A round's common level, shared by both arms: the gate's ratio must
      ## remove it, and does.
    runSigma = 0.01
      ## Per-run CPU noise; wall carries it plus as much again of its own.

  proc syntheticConfig(injectPercent: float; maxRounds: int;
                       maxMinutes = 3.0): GateConfig =
    result = parseGateArgs(["--case=synthetic",
      "--burn-iterations=" & $burnIterations,
      "--inject-percent=" & $injectPercent,
      "--disturbance-percent=6", "--disturbance-every=25",
      "--max-rounds=" & $maxRounds, "--max-minutes=" & $maxMinutes])
    result.syntheticChild = getAppFilename()

  proc seededCase(cfg: GateConfig; seed: int64): GateCase =
    ## The seeded cost model (header). The work comes from the gate's own
    ## `syntheticIterations`, so the injection and the disturbance are the
    ## real case's; only the conversion to seconds is modelled.
    var rng = initRand(seed)
    var levelRound = int.low
    var level = 0.0
    result.name = "synthetic-seeded"
    result.run = proc (arm: Arm; round: int): RunCost =
      if round != levelRound:
        levelRound = round
        level = rng.gauss(0, roundLevelSigma)
      let work = float(cfg.syntheticIterations(round, arm)) *
        secondsPerIteration
      let cpuNoise = rng.gauss(0, runSigma)
      let wallNoise = cpuNoise + rng.gauss(0, runSigma)
      result.cpuSeconds = work * exp(level + cpuNoise)
      result.wallSeconds = work * exp(level + wallNoise)
    result.stop = proc () = discard
    result.details = newJNull()

  proc runSeeded(cfg: GateConfig; seed: int64): GateResult =
    let gateCase = seededCase(cfg, seed)
    defer: gateCase.stop()
    runGate(cfg, gateCase, progress = false)

  proc runReal(cfg: GateConfig): GateResult =
    let scratch = createTempDir("rqgate-test", "")
    defer: removeDir(scratch)
    let gateCase = makeCase(cfg, scratch)
    defer: gateCase.stop()
    result = runGate(cfg, gateCase, progress = false)

  proc describe(outcome: GateResult): string =
    $outcome.decision.verdict & ": " & outcome.decision.reason & " after " &
      $outcome.rounds.len & " rounds"

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
      # And in the seeded model the noise does not undo that: round 0's
      # measured ratio is within the budget for both metrics, for every
      # seed, so judging it alone would pass every one of them.
      for seed in seeds:
        let outcome = runSeeded(cfg, seed)
        let r = outcome.rounds[0]
        check r.onWall / r.offWall <= 1 + cfg.policy.budget
        check r.onCpu / r.offCpu <= 1 + cfg.policy.budget

    test "a 2% injected overhead fails the gate, for every seed":
      let cfg = syntheticConfig(2, 500)
      for seed in seeds:
        let outcome = runSeeded(cfg, seed)
        checkpoint "seed " & $seed & ": " & describe(outcome)
        check outcome.decision.verdict == verdictFail
        check outcome.rounds.len >= cfg.policy.minRounds

    test "no injected overhead passes the gate":
      let cfg = syntheticConfig(0, 500)
      var passes = 0
      for seed in seeds:
        let outcome = runSeeded(cfg, seed)
        checkpoint "seed " & $seed & ": " & describe(outcome)
        # Never undecided: the noise allows the precision well within the
        # round limit.
        check outcome.decision.verdict in {verdictPass, verdictFail}
        if outcome.decision.verdict == verdictPass:
          inc passes
          # The precision, not the minimum, ended the run.
          check outcome.rounds.len > cfg.policy.minRounds
          for metric in GateMetric:
            check outcome.decision.estimates[metric].halfWidth <= 0.005
            check outcome.decision.estimates[metric].upper <= 0.01
      echo "    ", passes, " of ", seeds.len, " seeds passed"
      check passes * 10 >= seeds.len * 9

    test "running out of rounds is inconclusive, never a pass":
      let cfg = syntheticConfig(0, 10)
      for seed in seeds:
        let outcome = runSeeded(cfg, seed)
        checkpoint "seed " & $seed & ": " & describe(outcome)
        check outcome.rounds.len == 10
        check outcome.decision.verdict == verdictInconclusive
        check exitStatusFor(outcome.decision.verdict) == exitInconclusive

    test "real child processes: a 2% injected overhead fails the gate":
      let cfg = syntheticConfig(2, 500, maxMinutes = 4)
      let outcome = runReal(cfg)
      echo "    ", describe(outcome), " in ", outcome.elapsedSeconds, " s"
      check outcome.decision.verdict == verdictFail
      check outcome.rounds.len >= cfg.policy.minRounds
      for r in outcome.rounds:
        check r.offWall > 0 and r.onWall > 0
        check r.offCpu > 0 and r.onCpu > 0
