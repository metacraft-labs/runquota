## The launcher's half of the per-task memory cap, shared by every launcher
## that runs a tree under a RunQuota lease (`runquota run`, `runquota acquire
## -- CMD`, `runquota jobserver`, `runWithLease`, and Reprobuild's per-action
## launch): what cap to apply, what to report with the finish, and how to say
## that a tree passed it.
##
## THE DAEMON COMPUTES THE CAP; THE LAUNCHER DECIDES WHAT TO DO WITH IT. The
## grant carries the figure (`GrantMemoryCap`). Whether it is enforced,
## measured or lifted is the host file's `[enforcement] memoryCap` and the
## per-run variable `RUNQUOTA_MEMORY_CAP`, both read by the launching client,
## and the enforcement is the platform's own mechanism in `runquota_process`.
## So this module is pure policy: no process is touched here.
##
## Static-helper rules apply (no `ref` types): `runquota_exec` is linked into
## the static helpers.

import std/strutils

import runquota_core/byte_sizes
import runquota_core/memory_cap
import runquota_process/types as processTypes
import runquota_protocol/types as protocolTypes

type
  MemoryCapResolution* = object
    ## What a launch does with the memory cap (`resolveMemoryCap`).
    capBytes*: uint64
      ## The cap to apply; 0 for none (`CommandSpec.memoryCapBytes`).
    action*: MemoryCapAction
      ## Enforce, or only measure and report (`CommandSpec.memoryCapAction`).
    measure*: bool
      ## Measure the tree with the cap's own mechanism, cap or not
      ## (`CommandSpec.memoryCapMeasure`): true whenever the tree is capped,
      ## and for a run whose cap is lifted where the host file has it on.
    basis*: MemoryCapBasis
      ## Where the applied cap came from: the grant's basis, or `run-size` /
      ## `run-lifted` from the variable. `mcbNone` when nothing is applied.
    reason*: string
      ## Why no cap is applied (empty when one is): for the launcher's
      ## verbose output and the capability record, never an error.
    error*: string
      ## A value of `RUNQUOTA_MEMORY_CAP` that is none of the accepted ones.
      ## The launcher refuses to launch and prints this: a typo in a switch
      ## that decides whether a tree may be killed must not be guessed at.

proc applies*(resolution: MemoryCapResolution): bool =
  ## Whether the launch has anything to do for the cap: apply one, or
  ## measure a lifted run.
  resolution.capBytes > 0'u64 or resolution.measure

proc actionOf(mode: MemoryCapMode): MemoryCapAction =
  if mode == mcmAdvisory: mcaAdvisory else: mcaKill

proc resolveMemoryCap*(grant: GrantMemoryCap; hostMode: MemoryCapMode;
                       envValue: string; nested: bool): MemoryCapResolution =
  ## THE SWITCH AND THE PER-RUN OVERRIDE. `hostMode` is the host file's
  ## `[enforcement] memoryCap` (`mcmOff` when absent or unreadable);
  ## `envValue` is `RUNQUOTA_MEMORY_CAP` (empty when unset); `nested` is true
  ## for a launcher that itself runs inside a leased tree
  ## (`RUNQUOTA_PARENT_LEASE` set).
  ##
  ## * unset: the host file decides; with it on, the grant's cap in its mode.
  ## * `off`: the cap is LIFTED for this run. Where the host file has the cap
  ##   on, the tree is still measured as a capped tree would be, so a
  ##   successful run records its peak and the next cap follows it; where the
  ##   file has it off there is nothing to measure with.
  ## * `<size>` (bytes, or with a `K`/`M`/`G`/`T` binary suffix): this run's
  ##   cap is that size, in the host file's mode, or `kill` when the file
  ##   leaves the cap off -- asking for a size is asking for a cap.
  ## * `advisory` / `kill`: that mode for this run, whatever the file says,
  ##   with the grant's cap.
  ## * anything else is refused, naming the variable (`error`).
  ##
  ## A NESTED LAUNCHER APPLIES NO CAP, as it applies no placement: its tree
  ## is already inside its parent's, and so inside its parent's cap. A grant
  ## without a cap (an older daemon, a lease without a memory dimension)
  ## leaves nothing to apply unless the variable names a size.
  let value = envValue.strip()
  var runSize = 0'u64
  var mode = hostMode
  var lifted = false
  case value
  of "":
    discard
  of "off":
    lifted = true
  of "advisory":
    mode = mcmAdvisory
  of "kill":
    mode = mcmKill
  else:
    if not parseByteSize(value, runSize):
      result.error = MemoryCapEnvVar & " must be off, advisory, kill or a " &
        "size in bytes (optionally with a K, M, G or T binary suffix), " &
        "got `" & envValue & "`"
      return
  if nested:
    result.reason = "inside the tree of a parent lease, whose launcher " &
      "applies the cap"
    return
  if lifted:
    result.basis = mcbRunLifted
    result.capBytes = 0'u64
    result.measure = hostMode != mcmOff
    result.action = actionOf(hostMode)
    result.reason = "lifted for this run by " & MemoryCapEnvVar & "=off"
    return
  if runSize > 0'u64:
    result.capBytes = runSize
    result.basis = mcbRunSize
    result.measure = true
    result.action = if hostMode == mcmOff: mcaKill else: actionOf(hostMode)
    return
  if mode == mcmOff:
    result.reason = "memory cap off (the host file's [enforcement] " &
      "memoryCap is off or absent)"
    return
  if not grant.known:
    result.reason = "the daemon granted no memory cap"
    return
  if grant.capBytes == 0'u64:
    # A budget cap on a machine every byte of which other leases hold. The
    # lease was admitted, so this cannot arise unless the budget shrank
    # under it; a 0 cap would kill the tree on its first page, so none.
    result.reason = "the granted memory cap is 0 bytes"
    return
  result.capBytes = grant.capBytes
  result.basis = grant.basis
  result.measure = true
  result.action = actionOf(mode)

proc applyMemoryCap*(spec: var CommandSpec; resolution: MemoryCapResolution) =
  ## Put the resolved cap on a launch. Nothing is applied for a resolution
  ## that carries an error: the launcher refuses before it gets here.
  if resolution.error.len > 0:
    return
  spec.memoryCapBytes = resolution.capBytes
  spec.memoryCapAction = resolution.action
  spec.memoryCapMeasure = resolution.measure

proc platformMemoryCapGap(): string =
  ## Why this platform's launcher applies no memory cap at all yet, for a
  ## launch that did not say why itself.
  when defined(linux):
    "this build's launcher did not apply it"
  elif defined(macosx):
    "this build's launcher did not apply it"
  elif defined(windows):
    "this build's launcher did not apply it"
  else:
    "not implemented on this platform yet"

proc memoryCapNotEnforced*(resolution: MemoryCapResolution;
                           launch: LaunchResult): string =
  ## "memory cap not enforced: <why>" when the launch was asked to apply a
  ## cap (or to measure a lifted run, "memory cap not measured: <why>") and
  ## the platform layer did not; "" when it did, or when nothing was asked.
  ##
  ## SAID, NEVER SILENT. A cap the host file turned on and the grant
  ## carried, but that nothing enforces, is the state a user must be able
  ## to see: a regression would then run unchecked while every figure in
  ## the verbose output says it is capped. The launch never fails over it
  ## (the tree runs regardless), exactly as an unenforceable `--cap` does.
  ## The reason is the launch's own (`LaunchResult.memoryCapProblem`), or,
  ## where the platform has no mechanism yet, that it has none.
  if resolution.error.len > 0 or not resolution.applies or
      launch.memoryCapApplied:
    return ""
  var why =
    if launch.memoryCapProblem.len > 0: launch.memoryCapProblem
    else: platformMemoryCapGap()
  # The platform layer reports a bare reason, but a layer below it may
  # already have said what failed; say it once.
  for prefix in ["memory cap not enforced: ", "memory cap not applied: ",
                 "memory cap not measured: "]:
    if why.startsWith(prefix):
      why = why[prefix.len .. ^1]
  if resolution.capBytes > 0'u64: "memory cap not enforced: " & why
  else: "memory cap not measured: " & why

proc finishMemoryCap*(completion: ProcessCompletion;
                      resolution: MemoryCapResolution): FinishMemoryCap =
  ## The finish's memory-cap block: present when the launch measured the
  ## tree with the cap's mechanism (`completion.memoryCapMeasured`), and
  ## then the cap the launch applied, the basis it came from, the peak the
  ## mechanism measured and the breach flags. A launch that could not apply
  ## or measure the cap (no cgroup root, an OS leg not built yet) sends no
  ## block, and the daemon then learns no maximum from it.
  if not completion.memoryCapMeasured or resolution.basis == mcbNone:
    return FinishMemoryCap(present: false)
  # KILLED FOR THE CAP ONLY WITH KILL EVIDENCE, the same test the finish's
  # conclusion takes (`lfCapExceeded` needs a signal or a non-zero exit
  # status). A launcher may report its tree killed for the cap while the
  # root itself ended cleanly before the kill (macOS: a breach first read
  # from the root's zombie). Then the finish is the root's own conclusion,
  # and the breach must ride in the block as a flag; otherwise the daemon
  # would take a peak above the cap for a clean measured success and learn
  # it as the command's new size.
  let killedForCap = completion.capKilled and
    ((completion.signaled and completion.signal > 0) or
     (completion.exited and completion.exitCode > 0))
  FinishMemoryCap(
    present: true,
    capBytes: completion.memoryCapBytes,
    basis: resolution.basis,
    treePeakBytes: completion.memoryPeakBytes,
    peakSource: completion.memoryPeakSource,
    capReached: completion.capReached and not killedForCap,
    exceededAdvisory: completion.capExceeded and not killedForCap)

proc factorText(factorMilli: uint32): string =
  ## `2`, `1.5`, `2.25`: the factor as the host file writes it.
  result = $(factorMilli div 1000'u32)
  var fraction = factorMilli mod 1000'u32
  if fraction != 0'u32:
    var digits = align($fraction, 3, '0')
    while digits.endsWith("0"):
      digits.setLen(digits.len - 1)
    result.add("." & digits)

proc memoryCapReport*(command, commandStatsId: string; grant: GrantMemoryCap;
                      finishBlock: FinishMemoryCap; killed: bool): string =
  ## The report a launcher prints (the `runquota` CLI on stderr; Reprobuild
  ## with the action's failure) when a tree passed its memory cap: killed by
  ## it (`killed`, an `lfCapExceeded` finish), or, short of a kill, a block
  ## flagged `exceededAdvisory` or `capReached`. Empty when there was no
  ## breach.
  ##
  ## TWO SHAPES. A cap learned from the command's history (or declared, or
  ## set for the run) that was passed is a possible MEMORY REGRESSION: the
  ## report says so and gives both ways to declare that the growth is
  ## expected. A cap computed from the free BUDGET was not learned from
  ## anything -- no successful run is recorded -- so the report says what it
  ## was and that it is not a regression, lest a healthy first run near the
  ## budget be blamed for one.
  let breached = killed or finishBlock.breached
  if not breached:
    return ""
  let capBytes =
    if finishBlock.present: finishBlock.capBytes else: grant.capBytes
  let basis =
    if finishBlock.present: finishBlock.basis else: grant.basis
  let peakText =
    if finishBlock.present: formatBinaryBytes(finishBlock.treePeakBytes)
    else: "unknown"
  let outcome =
    if killed: "killed"
    elif finishBlock.exceededAdvisory: "not killed (advisory)"
    else: "an allocation was refused at the cap"
  let subject = command & " (command id " & commandStatsId & ")"
  if basis == mcbBudget:
    let others =
      if grant.budgetBytes > capBytes: grant.budgetBytes - capBytes
      else: 0'u64
    let headline =
      if killed: "stopped at the memory free when it started"
      elif finishBlock.exceededAdvisory:
        "passed the memory free when it started, not killed (advisory)"
      else: "an allocation was refused at the memory free when it started"
    return "runquota: " & headline & ": " & subject & "\n" &
      "  cap " & formatBinaryBytes(capBytes) & " = the host budget " &
      formatBinaryBytes(grant.budgetBytes) & " minus " &
      formatBinaryBytes(others) & " granted to other work;\n" &
      "  no successful run of this command is recorded yet, so it had no " &
      "learned\n" &
      "  cap. This is not a regression. The next run waits for more free " &
      "memory.\n"
  let derivation =
    case basis
    of mcbLearned:
      " = " & factorText(grant.factorMilli) &
        " × the largest successful peak, " &
        formatBinaryBytes(grant.previousMaxBytes)
    of mcbDeclared:
      " = the declared growth (runquota expect-growth)" &
        (if grant.previousMaxBytes > 0'u64:
          "; the largest successful peak is " &
            formatBinaryBytes(grant.previousMaxBytes)
         else: "")
    of mcbRunSize:
      " = " & MemoryCapEnvVar & " for this run"
    of mcbRunLifted:
      " (lifted for this run)"
    of mcbNone, mcbBudget:
      ""
  let headline =
    if killed or finishBlock.exceededAdvisory: "memory cap exceeded"
    else: "memory cap reached"
  "runquota: " & headline & ": " & subject & "\n" &
    "  cap " & formatBinaryBytes(capBytes) & derivation & "; peak " &
    peakText & "; " & outcome & "\n" &
    "  If this growth is expected:\n" &
    "    for one run:     " & MemoryCapEnvVar & "=off   (or " &
    MemoryCapEnvVar & "=<size>)\n" &
    "    from now on:     runquota expect-growth " & commandStatsId &
    " --to <size>\n" &
    "  Otherwise it is a memory regression: report it to the project that " &
    "owns\n" &
    "  this command.\n"
