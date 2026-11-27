## The per-task memory cap: the figures shared by the daemon that computes a
## lease's cap, the protocol that carries it, and the launchers that enforce
## it on each OS.
##
## WHAT A CAP IS. A host lease is granted with a memory cap: a ceiling on the
## memory its process tree may use, which the launching client enforces with
## the platform's own mechanism (a cgroup v2 leaf's `memory.max` on Linux, a
## Job Object's job-memory limit on Windows, a footprint walk on macOS) and
## which kills only that tree when it is exceeded. The cap is NOT admission:
## admission charges a lease's effective memory to the host ledger before it
## starts; the cap stops a tree that grows far past what the command has used
## before. Exceeding it is reported as an issue to the user and is never
## learned as the command's new size.
##
## Static-helper library rules apply (no `ref` types): `runquota_core` is
## linked into the static helpers.

const
  DefaultMemoryCapFactorMilli* = 2_000'u32
    ## The cap is this factor (in thousandths) times the command's largest
    ## successful tree peak, unless the host file says otherwise.
  MinMemoryCapFactorMilli* = 1_500'u32
    ## A factor below 1.5 would kill healthy runs on ordinary run-to-run
    ## noise, so a host file that asks for one does not parse.
  MinDeclaredMemoryCapBytes* = 1'u64 shl 20
    ## The smallest size `runquota expect-growth --to` accepts (1 MiB): a
    ## smaller declaration is a typo, not an expectation.
  MemoryCapEnvVar* = "RUNQUOTA_MEMORY_CAP"
    ## The launcher's per-run override: `off` lifts the cap for this run,
    ## a size is this run's cap, `advisory` / `kill` set the mode.
  MemoryCapStageEnvVar* = "RUNQUOTA_MEMORY_CAP_STAGE"
    ## Overhead gate only: how much of the Linux mechanism a launch applies,
    ## so each stage can be measured separately.

type
  MemoryCapBasis* = enum
    ## Where a cap's figure came from. The first three are decided by the
    ## daemon at the grant; the last two by the launcher, from
    ## `RUNQUOTA_MEMORY_CAP`.
    mcbNone = 0
      ## No cap was computed (no memory dimension, or a daemon that does not
      ## compute one).
    mcbLearned = 1
      ## The factor times the command's largest successful tree peak.
    mcbDeclared = 2
      ## A growth declaration (`runquota expect-growth --to`), larger than
      ## the learned figure or standing in for a missing one.
    mcbBudget = 3
      ## No successful peak is recorded: the machine's memory budget minus
      ## the effective memory every OTHER lease held at the grant. A breach
      ## of this cap is not a regression.
    mcbRunSize = 4
      ## `RUNQUOTA_MEMORY_CAP=<size>` for this run.
    mcbRunLifted = 5
      ## `RUNQUOTA_MEMORY_CAP=off` for this run: measured, not capped.

  MemoryPeakSource* = enum
    ## Which mechanism measured a tree's peak. Each is the mechanism that
    ## enforces the cap on its OS, so a learned maximum and the cap it
    ## produces are always in the same units.
    mpsNone = 0
    mpsCgroup = 1
      ## The task leaf's `memory.peak` (Linux).
    mpsJob = 2
      ## The Job Object's `PeakJobMemoryUsed`: commit (Windows).
    mpsPoll = 3
      ## The launcher's footprint walk (macOS).

  MemoryCapAction* = enum
    ## What a launcher does when its tree passes the cap.
    mcaAdvisory = 0
      ## Measure and report; never kill.
    mcaKill = 1
      ## Enforce: the tree is killed (or, on Linux, the kernel's OOM killer
      ## kills it inside its leaf).

  MemoryCapMode* = enum
    ## The host file's `[enforcement] memoryCap`, as the launcher resolves it.
    mcmOff = "off"
    mcmAdvisory = "advisory"
    mcmKill = "kill"

  GrantMemoryCap* = object
    ## The cap a grant carries (protocol minor `MemoryCapMinor`).
    known*: bool
      ## False when the grant carried no cap block (an older daemon, or a
      ## lease with no memory dimension).
    capBytes*: uint64
    basis*: MemoryCapBasis
    previousMaxBytes*: uint64
      ## The command's largest successful tree peak, 0 when none is recorded.
    factorMilli*: uint32
      ## The factor the daemon applied, in thousandths.

  FinishMemoryCap* = object
    ## What a launcher that enforced or measured a cap reports with the
    ## finish (protocol minor `MemoryCapMinor`).
    present*: bool
    capBytes*: uint64
      ## The cap the launcher applied; 0 when the run was lifted.
    basis*: MemoryCapBasis
    treePeakBytes*: uint64
      ## The tree's peak as the enforcing mechanism measured it.
    peakSource*: MemoryPeakSource
    capReached*: bool
      ## An allocation was refused at the cap and nothing was killed
      ## (Linux `ENOMEM` at `memory.max`, a Windows commit refused).
    exceededAdvisory*: bool
      ## The tree passed the cap in advisory mode and was not killed.

proc breached*(cap: FinishMemoryCap): bool =
  ## Whether the block reports any breach short of a kill. A kill is the
  ## finish's own conclusion (`lfCapExceeded`), not a flag.
  cap.present and (cap.capReached or cap.exceededAdvisory)
