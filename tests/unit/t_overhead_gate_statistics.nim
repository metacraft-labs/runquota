## The overhead gate's statistics, on fixed inputs: the t multiplier, the
## interval of a mean of paired log-ratios, and each branch of the verdict.
##
## The gate's behaviour against real processes is
## `tests/integration/t_overhead_gate_detects_overhead.nim`; this file pins
## the arithmetic it rests on, so a regression there names the formula
## rather than a noisy run.
##
## NO MOCKS: pure functions over constructed rounds.

import std/[math, unittest]

import ../../benchmarks/lib/runquota_overhead_gate/statistics

proc rounds(ratios: openArray[float]; base = 10.0): seq[RoundSample] =
  ## Rounds whose wall and CPU ratio on/off are each `ratios[i]`.
  for r in ratios:
    result.add(RoundSample(offWall: base, onWall: base * r,
      offCpu: base, onCpu: base * r))

suite "overhead gate statistics":
  test "t quantiles match the table and converge to the normal":
    check abs(studentT975(1) - 12.7062) < 1e-4
    check abs(studentT975(9) - 2.2622) < 1e-4
    check abs(studentT975(20) - 2.0860) < 1e-4
    # Beyond the table, the series (exact values from standard tables).
    check abs(studentT975(30) - 2.0423) < 2e-4
    check abs(studentT975(60) - 2.0003) < 2e-4
    check abs(studentT975(120) - 1.9799) < 2e-4
    check abs(studentT975(100_000) - 1.96) < 1e-3

  test "the estimate is the geometric mean ratio with a t interval":
    let rs = rounds([1.01, 1.03, 1.02, 1.02])
    let e = estimate(rs, metricWall)
    check e.rounds == 4
    let logs = [ln(1.01), ln(1.03), ln(1.02), ln(1.02)]
    let mean = (logs[0] + logs[1] + logs[2] + logs[3]) / 4
    var ss = 0.0
    for x in logs: ss += (x - mean) * (x - mean)
    let margin = studentT975(3) * sqrt(ss / 3) / 2
    check abs(e.overhead - (exp(mean) - 1)) < 1e-12
    check abs(e.lower - (exp(mean - margin) - 1)) < 1e-12
    check abs(e.upper - (exp(mean + margin) - 1)) < 1e-12

  test "the interval matches values computed outside this code":
    # Expected figures computed independently (Python's `statistics` and the
    # exact t quantiles 3.182446 for df 3 and 2.045230 for df 29), so a
    # wrong formula cannot agree with itself here. The second case has
    # df > 20 and pins the series branch of `studentT975`.
    let small = estimate(rounds([1.01, 1.03, 1.02, 1.02]), metricWall)
    check abs(small.overhead - 0.019975489312601624) < 1e-9
    check abs(small.lower - 0.00706542466681892) < 1e-6
    check abs(small.upper - 0.033051054396664004) < 1e-6
    var ratios: seq[float]
    for i in 0 ..< 30:
      ratios.add(1.0 + 0.001 * float((i * 7) mod 11 - 5))
    let wide = estimate(rounds(ratios), metricCpu)
    check abs(wide.overhead - 6.16022734354349e-05) < 1e-9
    check abs(wide.lower - (-0.0011464306671065128)) < 1e-6
    check abs(wide.upper - 0.0012710962325195307) < 1e-6

  test "one round has no interval":
    let e = estimate(rounds([1.5]), metricCpu)
    check e.halfWidth == Inf
    check e.upper == Inf

  test "too few rounds continue, or are inconclusive when exhausted":
    let policy = defaultGatePolicy()
    var rs = rounds([1.0, 1.0, 1.0])
    check decide(rs, policy).verdict == verdictContinue
    check decide(rs, policy, exhausted = true).verdict == verdictInconclusive

  test "a precise interval within budget passes":
    var ratios: seq[float]
    for i in 0 ..< 40:
      ratios.add(if i mod 2 == 0: 1.001 else: 0.999)
    let d = decide(rounds(ratios), defaultGatePolicy())
    check d.verdict == verdictPass

  test "a precise interval straddling the budget fails on its upper bound":
    var ratios: seq[float]
    for i in 0 ..< 40:
      ratios.add(if i mod 2 == 0: 1.016 else: 1.004)
    let d = decide(rounds(ratios), defaultGatePolicy())
    check d.estimates[metricWall].lower < 0.01
    check d.estimates[metricWall].upper > 0.01
    check d.estimates[metricWall].halfWidth <= 0.005
    check d.verdict == verdictFail

  test "a lower bound above the budget fails before precision":
    var ratios: seq[float]
    for i in 0 ..< 12:
      ratios.add(if i mod 2 == 0: 1.06 else: 1.04)
    let d = decide(rounds(ratios), defaultGatePolicy())
    check d.verdict == verdictFail

  test "an imprecise interval keeps going, and is inconclusive when exhausted":
    var ratios: seq[float]
    for i in 0 ..< 12:
      ratios.add(if i mod 2 == 0: 1.08 else: 0.92)
    let rs = rounds(ratios)
    check decide(rs, defaultGatePolicy()).verdict == verdictContinue
    check decide(rs, defaultGatePolicy(), exhausted = true).verdict ==
      verdictInconclusive

  test "CPU alone over budget fails even when wall time is fine":
    var rs: seq[RoundSample]
    for i in 0 ..< 40:
      rs.add(RoundSample(offWall: 10, onWall: 10,
        offCpu: 10, onCpu: 10 * (if i mod 2 == 0: 1.031 else: 1.029)))
    let d = decide(rs, defaultGatePolicy())
    check d.verdict == verdictFail
