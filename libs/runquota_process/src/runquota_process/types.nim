import std/osproc

import runquota_core/cpu_profile
import runquota_core/memory_cap
import runquota_process/cgroup_placement
import runquota_process/memory_cap_watch

export cpu_profile, cgroup_placement, memory_cap, memory_cap_watch

type
  LibraryInfo* = object
    name*: string

  ProcessBackendProfile* = object
    name*: string
    launchPrimitive*: string
    outputCapture*: string
    completionWait*: string
    cancellation*: string
    telemetry*: string
    directArgv*: bool
    implicitShell*: bool

  ProcessStdio* = enum
    ## Captured output is bounded; inherited stdio creates no capture pipes.
    captureStdio, inheritStdio

  CommandSpec* = object
    argv*: seq[string]
    cwd*: string
    env*: seq[string]
    inheritEnv*: bool
      ## When true (`commandSpec`'s default) the child starts from the
      ## launcher's environment and `env` is layered over it. When false the
      ## child's environment is EXACTLY `env`: nothing is inherited, so a
      ## caller that must control what a process can observe (a build that
      ## keys an action on the variables it reads) can do so. There is no
      ## other removal channel for an inherited variable: see `unsetEnv`.
      ##
      ## The OS loader may normalize reserved platform variables: Windows x64
      ## emulation sets `PROCESSOR_ARCHITECTURE=AMD64` even for an explicit
      ## block. Declare the target architecture when composing such a block.
    unsetEnv*: seq[string]
      ## The names removed from the INHERITED environment before `env` is
      ## layered over it, so an inheriting child does not see a variable its
      ## launcher has. Layering can replace a variable but never remove one,
      ## which is why this exists: a caller that must keep one variable away
      ## from a child (a build whose compiler choice comes from the ambient
      ## shell, say) names it here. The removal happens first, so a name also
      ## set in `env` takes the `env` value. Names match exactly, and
      ## case-insensitively on Windows where environment names do. The list
      ## is ignored when `inheritEnv` is false: an isolated child inherits
      ## nothing to remove.
    stdoutLimit*: int
    stderrLimit*: int
    createProcessGroup*: bool
    stdio*: ProcessStdio
    niceIncrement*: int
      ## Added to the child's nice value before it executes (POSIX), so
      ## the whole tree it starts inherits the lower scheduling weight. 0
      ## leaves it unchanged. A launcher sets it for a RECLAIMED grant (CPU
      ## admitted into predicted slack), which must yield to the work it
      ## was admitted beside. On Windows any positive value lowers the child
      ## (and so the tree it spawns) to `BELOW_NORMAL_PRIORITY_CLASS`, the
      ## platform's realization of the same lower weight; the Windows
      ## launcher does not read the magnitude, only that it is positive.
    cpuRateCapMilli*: uint32
      ## 0 = no cap. The grant's CPU budget in milli-cores (1000 = one core
      ## busy). The Windows launcher turns this into a hard Job Object CPU-rate
      ## cap on the child's whole tree, so the tree cannot use more CPU than
      ## the lease granted however many threads it spawns. Not applied on POSIX
      ## yet: cap enforcement there is cgroup work (`cpu.max`), out of scope
      ## for the Windows launcher.
    memoryCapBytes*: uint64
      ## The tree's memory cap in bytes; 0 = none. Enforced (or only
      ## measured, per `memoryCapAction`) by the platform's mechanism: a
      ## task leaf's `memory.max` (Linux), the Job Object's job-memory limit
      ## (Windows), the footprint walk (macOS). Only the tree is killed.
    memoryCapAction*: MemoryCapAction
      ## `mcaKill` enforces the cap; `mcaAdvisory` measures and reports a
      ## breach (`ProcessCompletion.capExceeded`) and kills nothing.
    memoryCapMeasure*: bool
      ## Measure the tree's peak with the cap's own mechanism even when
      ## `memoryCapBytes` is 0 (a run whose cap is lifted by
      ## `RUNQUOTA_MEMORY_CAP=off`), so that a success can record it. Implied
      ## by a non-zero `memoryCapBytes`.
    cgroup*: CgroupTarget
      ## Linux: the cgroup the child joins right after the fork, before it
      ## does anything else (it writes itself into the leaf's
      ## `cgroup.procs`), so its whole tree runs there. The launch prepares
      ## the directories itself, again if another launcher removed them
      ## meanwhile. Empty: not placed. Ignored elsewhere.
    placementFallbackNice*: int
      ## Added to the child's nice value INSTEAD of the cgroup when the child
      ## was not placed (no target, or the placement failed): the weaker
      ## stand-in for a lower weight. The larger of this and
      ## `niceIncrement` applies.
    cgroupPriority*: GroupPrioritySource
      ## Where the launch reads the group's priority in force at the last
      ## instant before it is used, instead of before the launch: on Linux a
      ## group target reads it while it holds the cgroup root's shared lock,
      ## for the `cpu.weight` it writes (replacing `cgroup.cpuWeight`) and the
      ## fallback nice (replacing `placementFallbackNice`); on WINDOWS the
      ## same source is read right before the Job Object priority-class limit
      ## is set, for the class a non-reclaimed tree takes (replacing the
      ## placement-time `jobPriorityClass`). Reading it there, not before the
      ## launch, is what keeps a concurrent `session set --priority` from
      ## being overwritten by an older priority (on Linux under
      ## `lockCgroupRoot`; on Windows a single `SetInformationJobObject` call
      ## has no critical section for a set to land inside, so it needs no
      ## lock). Not set: the target's weight / `jobPriorityClass` are used as
      ## given. The source's context must stay valid until `launchProcess`
      ## returns.
    jobPriorityClass*: uint32
      ## Windows: the Win32 priority class the launcher forces on the child's
      ## whole tree through a Job Object priority-class LIMIT, below admission
      ## (`runquota_process/job_priority.jobPriorityClassFor`). 0 = no limit
      ## (the switchable layer off): the tree keeps its unconditional class
      ## (`BELOW_NORMAL_PRIORITY_CLASS` for a reclaimed grant, normal
      ## otherwise). The class resolved at PLACEMENT time from the priority
      ## then known: for a reclaimed tree it is idle and final (reclaimed asks
      ## no priority, so `cgroupPriority` is unset); for a non-reclaimed tree
      ## it is the FALLBACK the launch keeps only if the last-instant read
      ## through `cgroupPriority` cannot answer. A Job Object limit, unlike a
      ## per-process `SetPriorityClass` a child could override, forces every
      ## process in the tree, now and every one it later spawns. Ignored off
      ## Windows.
    qosTier*: uint8
      ## macOS: the priority policy the child applies to itself before it
      ## executes, below admission (`runquota_process/qos_priority`: 0 none,
      ## 1 the background policy), inherited by every
      ## process the tree starts. 0 = the switchable layer off. The tier
      ## resolved at PLACEMENT time is, for a reclaimed tree, final
      ## (`cgroupPriority` is unset); for any other it is the FALLBACK the
      ## launch keeps only if the last-instant read through `cgroupPriority`
      ## cannot answer. Applied by an ordinary fork and execve, so the fork
      ## handlers of preload libraries still run. Ignored off macOS.

  LaunchResult* = object
    processId*: uint64
    processGroupId*: uint64
    running*: bool
    backend*: ProcessBackendProfile
    cgroupPath*: string
      ## The leaf cgroup the child was created in, or "" when it was not
      ## placed.
    cgroupProblem*: string
      ## Why a requested placement did not happen, or "".
    fallbackNice*: int
      ## The nice the child took in place of its cgroup when it was not
      ## placed (`CommandSpec.placementFallbackNice`, or the one the launch
      ## derived from the priority it read through `cgroupPriority`).
    qosTier*: uint8
      ## macOS: the tier (`runquota_process/qos_priority`) the child applied
      ## to itself before it executed; 0 elsewhere or with the layer off.
    memoryCapApplied*: bool
      ## The launch's memory cap (or its measurement, `memoryCapMeasure`) is
      ## in force: the platform's mechanism is armed for this tree. False when
      ## the launch asked for no cap, and false with `memoryCapProblem` set
      ## when it asked and the mechanism could not be armed.
    memoryCapProblem*: string
      ## Why a cap the launch asked for is not in force, else "".

  ProcessCompletion* = object
    processId*: uint64
    processGroupId*: uint64
    exitCode*: int
    signal*: int
    exited*: bool
    signaled*: bool
    cancelled*: bool
    timedOut*: bool
    stdout*: string
    stderr*: string
    stdoutBytes*: uint64
    stderrBytes*: uint64
    elapsedMillis*: uint64
    peakResidentMemoryBytes*: uint64
      ## The largest SUMMED resident set the tree samples saw while it ran
      ## (`tree-sampling`). 0 when nothing sampled it. See `totals` for the
      ## largest single process, which needs no sampling.
    memoryCapBytes*: uint64
      ## The memory cap the launch applied (`CommandSpec.memoryCapBytes`),
      ## 0 when none.
    memoryCapMeasured*: bool
      ## The tree was measured by the cap's mechanism (a cap was applied, or
      ## `memoryCapMeasure` asked for it): `memoryPeakBytes` and the flags
      ## below are meaningful only when this is true.
    memoryPeakBytes*: uint64
      ## The tree's peak as the cap's mechanism measured it (`memory.peak`,
      ## `PeakJobMemoryUsed`, the footprint walk's largest sum).
    memoryPeakSource*: MemoryPeakSource
    capExceeded*: bool
      ## The tree passed its cap (killed or, in advisory mode, not).
    capKilled*: bool
      ## The tree was killed because it passed its cap.
    capReached*: bool
      ## An allocation was refused at the cap and nothing was killed.
    memoryCapProblem*: string
      ## Why a cap the launch asked for was not in force, else "" (the
      ## launch's `LaunchResult.memoryCapProblem`).
    oomKilledOutsideCap*: bool
      ## A process of the tree was killed for memory by something other than
      ## its cap (a host-wide OOM, an ancestor's limit).
    processCount*: uint32
    telemetrySource*: string
    totals*: FinishTotals
      ## The tree's CPU time, largest single resident set and duration, from
      ## the wait that reaped its root. `totals.known` is false where the
      ## platform gave none.
    cpuProfile*: CpuProfile
      ## The tree's CPU use over time, when the `profiles` measurement is on
      ## and the platform can read the tree (Linux). Otherwise absent.
    memoryProfileMiB*: seq[uint16]
      ## The largest summed resident set per profile interval, in MiB, on
      ## `cpuProfile`'s intervals. Taken by the same tree readings, so it
      ## costs nothing extra; sent as `memoryProfile` when `sizing-data` is
      ## on.
    memoryProfile*: MemoryProfile
      ## The tree's summed resident set per interval (`sizing-data`, Linux
      ## and macOS),
      ## sent with the finish for sizing replay. Absent otherwise.
    io*: IoTotals
      ## Storage read and write bytes, measured at the root's exit
      ## (`sizing-data`): on Linux the `ru_inblock` / `ru_oublock` of the
      ## `wait4` that reaped it, times 512 (the root and the descendants it
      ## waited for); on macOS `proc_pid_rusage` of the exited, not yet
      ## reaped root (the root's own bytes only). Not known otherwise.

  LaunchedProcess* = object
    pid*: int
    processGroupId*: int
    stdoutFd*: int
    stderrFd*: int
    stdoutLimit*: int
    stderrLimit*: int
    startedSeconds*: float
    runningFlag*: bool
    cancelSent*: bool
    doneFlag*: bool
    # Wall-clock time (epochTime seconds) at which the leased child itself was
    # reaped. Used to bound the final output drain: once the direct child has
    # exited we must declare completion even if forked descendants keep the
    # inherited pipe write-ends open (so the pipes never reach EOF). 0.0 means
    # "not yet reaped".
    doneSeconds*: float
    waitStatus*: int
    stdoutText*: string
    stderrText*: string
    stdoutBytes*: uint64
    stderrBytes*: uint64
    peakResidentMemoryBytes*: uint64
    processCount*: uint32
    telemetrySource*: string
    lastTelemetrySampleSeconds*: float
    treeSampling*: bool
      ## Whether this launch samples its tree's resident memory and process
      ## count while it waits: the `tree-sampling` measurement switch
      ## (`runquota_core/measurement`), read once at launch. Off, the
      ## completion carries no peak memory (0, which every reader already
      ## treats as "not measured") and `telemetrySource` says why.
    profiles*: bool
      ## Whether this launch takes a CPU profile of its tree: the `profiles`
      ## measurement switch, read once at launch, and only where the tree
      ## can be read (Linux `/proc`).
    sizingData*: bool
      ## Whether this launch takes the `sizing-data` figures: a memory
      ## profile (the tree read at the profile cadence, with or without
      ## `profiles`), the tree's summed peak memory, and the root's IO
      ## counters at exit. Read once at launch; Linux and macOS.
    profileSampler*: CpuProfileSampler
      ## Running when `profiles` or `sizingData` is on.
    ioTotals*: IoTotals
      ## Read at the root's exit, before the reap (`sizingData`).
    treeWalks*: uint32
      ## How many times this launch has read its process tree while waiting
      ## (POSIX). The cost of `tree-sampling` and `profiles` is this count
      ## times one walk, so the cadence rule -- a walk only when a sample is
      ## due, one walk for both measurements -- is asserted on it rather
      ## than on a stopwatch.
    launchMonoMillis*: int64
      ## The launch on the monotonic clock: the origin of the profile's
      ## intervals and of the totals' duration.
    rusageKnown*: bool
    rusageUserMicros*: uint64
    rusageSysMicros*: uint64
    rusageMaxRssBytes*: uint64
    rusageMajorFaults*: uint64
    reapMonoMillis*: int64
    info*: LaunchResult
    completion*: ProcessCompletion
    # Windows: extra slots store the osproc Process ref and the Job Object
    # handle so the rest of the lifecycle (wait/terminate/close) can find
    # them. The fields are present on all platforms (kept simple to avoid
    # case-object constructor noise) but only populated on Windows.
    #
    # `winProcess` MUST be a typed `Process` ref (not a raw `pointer`):
    # Nim's Process is a ref ProcessObj, and storing only an untyped
    # pointer cast hides the reference from the GC. At higher concurrency
    # the GC can collect the underlying ProcessObj before the LaunchedProcess
    # is finished with it; the next pollCompletion then dereferences freed
    # memory, occasionally tripping the
    # `poParentStreams notin p.options` assert inside osproc.outputStream
    # when the freed memory happens to alias a Process with those options.
    winProcess*: Process
    winJobHandle*: uint64
    # Windows: end of input seen on the child's stdout / stderr pipe.
    winStdoutClosed*: bool
    winStderrClosed*: bool
    temporaryLaunchFiles*: seq[string]
    cgroupTarget*: CgroupTarget
      ## The placement this launch made, released (its leaf and group
      ## directory removed when empty) by `close`.
    memoryCap*: MemoryCapWatch
      ## The launcher's readings and judgement of the tree's memory cap
      ## (macOS; inactive elsewhere and when the launch has no cap).
