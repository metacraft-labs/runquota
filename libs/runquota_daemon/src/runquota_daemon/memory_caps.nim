## The daemon's half of the per-task memory cap: the figure a grant carries,
## and what a finish teaches the command's learned row.
##
## PURE, AND SEPARATE FROM THE DAEMON, so each rule can be stated over plain
## numbers and asserted without a socket; `runquota_daemon` supplies the
## figures it holds (the machine's budget, what other leases hold, the
## command's row) and stores what comes back.
##
## THE CAP IS NOT ADMISSION. Admission charges a lease's effective memory to
## the host ledger before it starts; the cap is a ceiling the LAUNCHER puts on
## the tree once it runs, which kills only that tree when it is passed. The
## cap is therefore never raised to the reservation, to a client estimate or
## to the conservative figure, and it never lowers them: a cap below the
## effective memory (after a host OOM raised the conservative figure) is
## possible and correct, because admission over-reserves and the cap still
## catches a regression. `runquotad` computes the figure and never touches a
## cgroup, a job or a process.

import runquota_core/memory_cap
import runquota_persistence/types
import runquota_protocol/types as protocolTypes

const DeclarationScope* = "declared:"
  ## The estimate-table scope that holds GROWTH DECLARATIONS
  ## (`runquota expect-growth`). A declaration is about a COMMAND, not about
  ## which launcher ran it: the learned rows are scoped by the launching
  ## session's name (`session:runquota run`, `session:reprobuild action`, ...)
  ## and a request to declare growth names no session, so a declaration kept
  ## in one launcher's scope would be invisible to the others. One row per
  ## command stats id in this scope holds the declaration (its other figures
  ## stay 0), and every grant of that id reads it whichever launcher asked.
  ## A session scope always starts with `session:`, so no session can name
  ## this one.

proc saturatingMul(a, b: uint64): uint64 =
  if a != 0'u64 and b > high(uint64) div a: high(uint64) else: a * b

proc learnedCapBytes*(maxPeakBytes: uint64; factorMilli: uint32): uint64 =
  ## ⌈f × M⌉ with the factor in thousandths, saturating instead of wrapping:
  ## a peak large enough to overflow is clamped to the budget by the caller
  ## anyway, and a wrapped product would be a tiny cap that kills the run.
  let product = saturatingMul(maxPeakBytes, uint64(factorMilli))
  if product == high(uint64): high(uint64)
  else: product div 1000'u64 + (if product mod 1000'u64 != 0'u64: 1'u64
                               else: 0'u64)

proc effectiveFactorMilli*(configured: uint32): uint32 =
  ## The factor in force: the configured one, or the default when nothing
  ## configured one (0, a configuration that never went through the host
  ## file's reader). The reader refuses a factor below the floor, so a
  ## non-zero value here is always at least `MinMemoryCapFactorMilli`.
  if configured == 0'u32: DefaultMemoryCapFactorMilli else: configured

proc grantMemoryCap*(maxPeakBytes, declaredBytes, budgetBytes,
                     othersBytes: uint64; factorMilli: uint32): GrantMemoryCap =
  ## The cap of a host lease with a memory dimension, from the command's
  ## largest successful peak (M), its declared cap (D), the target machine's
  ## memory budget (B) and the memory every OTHER lease on that machine holds
  ## at the grant (H):
  ##
  ## * M > 0: min(B, max(⌈f × M⌉, D)), basis `learned`, or `declared` when D
  ##   is the larger;
  ## * M = 0, D > 0: min(B, D), basis `declared`;
  ## * otherwise B − H, basis `budget`: the memory admission had not promised
  ##   to anyone else when this lease was granted. The lease was admitted, so
  ##   this is at least its own effective memory, and the cap never undercuts
  ##   what admission charged. A breach of it is not a regression: the
  ##   command has no recorded maximum and the host was short.
  let factor = effectiveFactorMilli(factorMilli)
  result = GrantMemoryCap(known: true, previousMaxBytes: maxPeakBytes,
    factorMilli: factor, budgetBytes: budgetBytes)
  if maxPeakBytes > 0'u64:
    let learned = learnedCapBytes(maxPeakBytes, factor)
    if declaredBytes > learned:
      result.capBytes = min(budgetBytes, declaredBytes)
      result.basis = mcbDeclared
    else:
      result.capBytes = min(budgetBytes, learned)
      result.basis = mcbLearned
  elif declaredBytes > 0'u64:
    result.capBytes = min(budgetBytes, declaredBytes)
    result.basis = mcbDeclared
  else:
    result.capBytes =
      if othersBytes >= budgetBytes: 0'u64 else: budgetBytes - othersBytes
    result.basis = mcbBudget

proc finishBreachesCap*(finish: LeaseFinishedMessage): bool =
  ## A finish that passed its cap: killed by it, or a block that says an
  ## allocation was refused at it or that it was passed in advisory mode.
  finish.finish.kind == lfCapExceeded or finish.memoryCap.breached

proc doubledFor(peakBytes, leaseMemoryBytes: uint64): uint64 =
  saturatingMul(max(peakBytes, leaseMemoryBytes), 2'u64)

proc learnFromFinish*(row: var LearnedEstimateRow; finish: LeaseFinishedMessage;
                      observedPeakBytes, leaseMemoryBytes,
                      nowMillis: uint64): bool =
  ## Fold one finish into the command's learned row. Returns false when the
  ## finish teaches nothing and the row must not be written (no peak was
  ## observed and nothing was breached): a row is never created out of a
  ## finish that carried no figure.
  ##
  ## THE RULES (each one is a sentence of the memory-cap design, in order):
  ##
  ## 1. A BREACH DOES NOT CHANGE THE LEARNED FIGURES. A cap-exceeded finish,
  ##    or a block flagged `capReached` or `exceededAdvisory`, of basis
  ##    `learned`, `declared`, `run-size` or `run-lifted`, changes neither
  ##    the conservative figure nor M: exceeding the cap is an issue to
  ##    report, and learning it would make the next cap follow the
  ##    regression. The row records the outcome and the breach's cap, peak
  ##    and time, so the report can say what was exceeded and when.
  ## 2. A BREACH OF A `budget` CAP is not a regression -- the command has no
  ##    recorded maximum and the host was short -- so it is treated as an
  ##    outside kill: the conservative figure becomes max(current, 2 ×
  ##    max(peak, the lease's memory)), so the next run waits for more room;
  ##    M is unchanged and the breach is recorded.
  ## 3. AN `lfOomKilled` FINISH raises the admission figure only: max(current,
  ##    2 × max(peak, the lease's memory)); M never changes.
  ## 4. ANY OTHER FINISH sets the conservative figure to max(1.25 × peak,
  ##    current).
  ## 5. ONLY A MEASURED SUCCESS RAISES M: max(M, the block's tree peak) for an
  ##    `lfSucceeded` finish whose block is present and flags no breach. A
  ##    peak from `ru_maxrss` or tree sampling never feeds M: those are lower
  ##    bounds of another mechanism, and a cap computed from one would kill a
  ##    healthy tree whose memory is spread over several processes.
  ##
  ## The conservative figure never decreases, as before.
  let capBlock = finish.memoryCap
  let breach = finishBreachesCap(finish)
  let measuredSuccess = finish.finish.kind == lfSucceeded and
    capBlock.present and not breach
  if observedPeakBytes == 0'u64 and not breach and
      not (measuredSuccess and capBlock.treePeakBytes > 0'u64):
    return false
  row.sampleCount += 1'u32
  row.lastOutcome = uint32(ord(finish.finish.kind))
  row.updatedUnixMillis = nowMillis
  if breach:
    # The peak that passed the cap is the one the cap's own mechanism
    # measured; a launcher that sent no block (impossible for a cap kill,
    # which the decoder refuses without one) leaves the observed peak.
    let breachPeak =
      if capBlock.present and capBlock.treePeakBytes > 0'u64: capBlock.treePeakBytes
      else: observedPeakBytes
    row.lastBreachCapBytes = capBlock.capBytes
    row.lastBreachPeakBytes = breachPeak
    row.lastBreachUnixMillis = nowMillis
    if capBlock.basis == mcbBudget:
      row.conservativeMemoryBytes = max(row.conservativeMemoryBytes,
        doubledFor(breachPeak, leaseMemoryBytes))
    return true
  if observedPeakBytes > 0'u64:
    row.recentPeakMemoryBytes = observedPeakBytes
  if finish.finish.kind == lfOomKilled:
    row.conservativeMemoryBytes = max(row.conservativeMemoryBytes,
      doubledFor(observedPeakBytes, leaseMemoryBytes))
  elif observedPeakBytes > 0'u64:
    let scaled = saturatingMul(observedPeakBytes, 125'u64) div 100'u64
    row.conservativeMemoryBytes = max(row.conservativeMemoryBytes,
      max(observedPeakBytes, scaled))
  if measuredSuccess:
    row.maxObservedPeakBytes = max(row.maxObservedPeakBytes,
      capBlock.treePeakBytes)
  true
