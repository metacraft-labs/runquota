## The overhead gate's statistics: when to stop repeating, and what the
## repetitions say.
##
## THE QUESTION. Does turning RunQuota's measurements on make a build slower,
## in wall time or in CPU time, by more than the budget (1%)? A single pair of
## runs cannot answer it: on a shared host two runs of the SAME configuration
## routinely differ by several percent, so one "on" run against one "off" run
## measures the noise, not the measurements. The gate therefore repeats, and
## stops on a stated rule.
##
## THE DESIGN.
##
## * PAIRED AND INTERLEAVED. Each round runs both arms back to back and
##   alternates which goes first (off-on, on-off, off-on, ...), so a load
##   that drifts over minutes lands on both arms of a round alike and an
##   order effect (a warm cache for whichever runs second) cancels over pairs
##   of rounds. The unit of analysis is the round, not the run.
## * LOG-RATIO. Each round contributes `d = ln(on / off)`. A ratio removes
##   the round's common level (a slow round is slow in both arms), and the
##   logarithm makes the mean of ratios symmetric and lets the interval be
##   carried back to a percentage exactly: overhead = exp(mean d) - 1.
## * STUDENT t INTERVAL at 95%, two-sided, on the mean of `d`. The paired
##   differences are close to normal for the round counts the gate uses
##   (tens to hundreds), and the t interval is the textbook one for a mean of
##   paired differences (see
##   https://www.itl.nist.gov/div898/handbook/eda/section3/eda352.htm).
## * THE STOPPING RULE, from the requirement: repeat until the interval of the
##   difference is narrower than the precision, 0.5 percentage points of
##   HALF-WIDTH (the interval is overhead +- 0.5%), for wall AND CPU time,
##   then judge it. Never fewer than `minRounds` rounds, so a lucky early
##   streak cannot end the run.
## * THE VERDICT.
##   - FAIL as soon as the LOWER bound of either metric exceeds the budget:
##     the overhead is established beyond it, and more rounds cannot clear it.
##   - Once both intervals are precise: PASS when both UPPER bounds are within
##     the budget, FAIL otherwise. A pass needs the upper bound, not the
##     point estimate, within budget: "probably under 1%" is not the claim.
##   - INCONCLUSIVE when the round or time limit is reached first. That is a
##     failure of the gate, never a pass: it means the host was too noisy to
##     establish the claim, and saying so is the honest result.
##
## LOOKING AFTER EVERY ROUND, AND WHAT IT COSTS. The rule is checked after
## every round, which is sequential testing: each look is another chance for
## a 95% interval to miss. The two verdicts are affected differently, and
## neither needs a stricter interval for the interim looks:
##
## * PASS is decided once, at the round where both intervals first reach
##   the precision. That round depends on the spread of the log-ratios, not
##   on their mean, so a pass is a single look at an upper bound, and the
##   chance of passing a true overhead of exactly 1% stays near the nominal
##   one-sided 2.5% (about 3% in simulation, from the slight dependence of
##   the stopping round on the sample spread). This is the error that would
##   let a too-costly measurement go on by default.
## * EARLY FAIL looks at the lower bound after every round, so its chance of
##   firing is inflated: for a true overhead of exactly 1% it fires in 2-16%
##   of runs as the per-round spread goes from 0.5% to 3% (a fixed-size test
##   would fire in 2.5%). But it only fires where the final verdict would be
##   a fail anyway: in simulation (normal log-ratios, spread 0.5-3%, true
##   overhead 0-1%) the share of runs that it failed and that the rule
##   without it would have passed was at most 0.5%. That is the whole
##   price of stopping early, and it falls on the conservative side.
##
## The simulation is a straight transcription of `decide` for one metric;
## with two metrics a pass needs both, which only lowers its error rate.
## A 2% overhead against a 1% budget is detected with a wide margin either
## way, which is what the gate's own test asserts.

import std/[math, strutils]

type
  GateMetric* = enum
    metricWall = "wall"
    metricCpu = "cpu"

  RoundSample* = object
    ## One round: both arms of the same workload, in seconds.
    offWall*, onWall*: float
    offCpu*, onCpu*: float

  GatePolicy* = object
    budget*: float       ## Allowed overhead, as a fraction (0.01 is 1%).
    precision*: float    ## Required interval half-width, as a fraction.
    confidence*: float   ## Two-sided confidence level; 0.95 is supported.
    minRounds*: int      ## Never judge on fewer rounds than this.
    maxRounds*: int      ## Give up (inconclusive) after this many.

  MetricEstimate* = object
    rounds*: int
    overhead*: float     ## exp(mean log-ratio) - 1
    lower*, upper*: float
    halfWidth*: float    ## (upper - lower) / 2

  GateVerdict* = enum
    verdictContinue = "continue"
    verdictPass = "pass"
    verdictFail = "fail"
    verdictInconclusive = "inconclusive"

  GateDecision* = object
    verdict*: GateVerdict
    reason*: string
    estimates*: array[GateMetric, MetricEstimate]

proc defaultGatePolicy*(): GatePolicy =
  ## The requirement's numbers: 1% budget, +-0.5% precision, 95%.
  GatePolicy(budget: 0.01, precision: 0.005, confidence: 0.95,
    minRounds: 10, maxRounds: 200)

proc studentT975*(df: int): float =
  ## The 0.975 quantile of Student's t with `df` degrees of freedom, the
  ## multiplier of a two-sided 95% interval. Exact table values for small
  ## `df` (where the series below is least accurate), the Cornish-Fisher
  ## expansion around the normal quantile beyond (Abramowitz & Stegun
  ## 26.7.5), which is within 1e-4 of the exact value from df = 9 on.
  const table = [12.7062, 4.3027, 3.1824, 2.7764, 2.5706, 2.4469, 2.3646,
    2.3060, 2.2622, 2.2281, 2.2010, 2.1788, 2.1604, 2.1448, 2.1314, 2.1199,
    2.1098, 2.1009, 2.0930, 2.0860]
  if df < 1:
    return Inf
  if df <= table.len:
    return table[df - 1]
  let z = 1.959963984540054
  let n = float(df)
  let z3 = z * z * z
  let z5 = z3 * z * z
  let z7 = z5 * z * z
  z + (z3 + z) / (4 * n) + (5 * z5 + 16 * z3 + 3 * z) / (96 * n * n) +
    (3 * z7 + 19 * z5 + 17 * z3 - 15 * z) / (384 * n * n * n)

proc logRatio(sample: RoundSample; metric: GateMetric): float =
  case metric
  of metricWall: ln(sample.onWall / sample.offWall)
  of metricCpu: ln(sample.onCpu / sample.offCpu)

proc estimate*(rounds: openArray[RoundSample]; metric: GateMetric):
    MetricEstimate =
  ## The overhead of `metric` and its 95% interval over `rounds`. With fewer
  ## than two rounds there is no interval: the bounds are infinite, which no
  ## rule below can mistake for a precise one.
  result.rounds = rounds.len
  if rounds.len == 0:
    result.overhead = NaN
    result.lower = -Inf
    result.upper = Inf
    result.halfWidth = Inf
    return
  var total = 0.0
  for r in rounds:
    total += logRatio(r, metric)
  let mean = total / float(rounds.len)
  result.overhead = exp(mean) - 1
  if rounds.len < 2:
    result.lower = -Inf
    result.upper = Inf
    result.halfWidth = Inf
    return
  var squares = 0.0
  for r in rounds:
    let d = logRatio(r, metric) - mean
    squares += d * d
  let sd = sqrt(squares / float(rounds.len - 1))
  let margin = studentT975(rounds.len - 1) * sd / sqrt(float(rounds.len))
  result.lower = exp(mean - margin) - 1
  result.upper = exp(mean + margin) - 1
  result.halfWidth = (result.upper - result.lower) / 2

proc pct(x: float): string =
  formatFloat(x * 100, ffDecimal, 3) & "%"

proc decide*(rounds: openArray[RoundSample]; policy: GatePolicy;
             exhausted = false): GateDecision =
  ## Apply the stopping rule and the verdict (module header) to the rounds
  ## so far. `exhausted` says the caller can run no more (round or time
  ## limit); without it, an undecided state is `verdictContinue`.
  doAssert policy.confidence == 0.95,
    "only a 95% interval is implemented (studentT975)"
  for metric in GateMetric:
    result.estimates[metric] = estimate(rounds, metric)
  if rounds.len < policy.minRounds:
    if exhausted:
      result.verdict = verdictInconclusive
      result.reason = "stopped after " & $rounds.len & " rounds, fewer " &
        "than the minimum of " & $policy.minRounds
    else:
      result.verdict = verdictContinue
    return
  for metric in GateMetric:
    let e = result.estimates[metric]
    if e.lower > policy.budget:
      result.verdict = verdictFail
      result.reason = $metric & " overhead " & pct(e.overhead) & " [" &
        pct(e.lower) & ", " & pct(e.upper) & "]: the lower bound exceeds " &
        "the " & pct(policy.budget) & " budget"
      return
  var precise = true
  for metric in GateMetric:
    if not (result.estimates[metric].halfWidth <= policy.precision):
      precise = false
  if precise:
    for metric in GateMetric:
      let e = result.estimates[metric]
      if e.upper > policy.budget:
        result.verdict = verdictFail
        result.reason = $metric & " overhead " & pct(e.overhead) & " [" &
          pct(e.lower) & ", " & pct(e.upper) & "]: the upper bound " &
          "exceeds the " & pct(policy.budget) & " budget"
        return
    result.verdict = verdictPass
    result.reason = "both intervals are within +-" & pct(policy.precision) &
      " and both upper bounds are within the " & pct(policy.budget) &
      " budget"
    return
  if exhausted:
    result.verdict = verdictInconclusive
    var widest = metricWall
    for metric in GateMetric:
      if result.estimates[metric].halfWidth >
          result.estimates[widest].halfWidth:
        widest = metric
    result.reason = "stopped after " & $rounds.len & " rounds with the " &
      $widest & " interval at +-" &
      pct(result.estimates[widest].halfWidth) & ", wider than the +-" &
      pct(policy.precision) & " required"
  else:
    result.verdict = verdictContinue
