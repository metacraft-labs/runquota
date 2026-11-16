## The lower scheduling weight a RECLAIMED grant runs at on Windows, at the
## `runquota_process` launcher level -- no daemon, no sqlite, no external tool.
##
## A reclaimed grant arrives at the launcher as `CommandSpec.niceIncrement > 0`
## (the Windows realization of POSIX `nice`). The launcher must lower the
## child, and so the tree it spawns, to `BELOW_NORMAL_PRIORITY_CLASS`, so the
## reclaimed work yields the CPU to the work it was admitted beside; a grant
## that is NOT reclaimed (`niceIncrement == 0`) must run at the normal class.
##
## Each case launches a process tree through `launchProcess` and reads the
## priority class back from the processes themselves (each writes its own
## `GetPriorityClass` to a file). The tree is THIS TEST BINARY re-invoked in a
## worker mode, as `t_windows_job_object_cpu` already does, so the fixture is
## one binary and needs no shell. A "go" file the test writes only AFTER
## `launchProcess` has returned (the launcher sets the priority before it
## returns) gates the worker's read, so the worker never races the launcher.
##
## The SWITCHABLE second layer (enforcement below admission, job-priority on)
## is a Job Object priority-class LIMIT the launcher puts on the tree
## (`CommandSpec.jobPriorityClass`), which forces EVERY process in the job to
## that class, now and every one it later spawns, below the unconditional
## below-normal. A reclaimed grant is forced to `IDLE_PRIORITY_CLASS`, lower
## still -- the Windows analogue of the reclaimed cgroup's `cpu.weight` 1.
##
## WHAT IS PROVEN, with the mutation that turns it red:
##   * a reclaimed grant's child -- and the grandchild it spawns -- run at
##     below-normal; skipping the `SetPriorityClass` call in the launcher
##     leaves them at normal and the checks fail;
##   * a non-reclaimed grant's child runs at normal, so the lowering is tied
##     to the reclaimed flag, not applied to everything;
##   * with the job-priority switch on, a reclaimed grant's whole tree is
##     forced to IDLE -- stronger than the below-normal baseline alone;
##     dropping the Job Object priority-class limit in the launcher leaves the
##     child at below-normal and the stronger-than-baseline check fails;
##   * the class is read at THE LAST INSTANT before the limit is set, through
##     the same `GroupPrioritySource` (`CommandSpec.cgroupPriority`) the Linux
##     weight uses, so a `session set --priority` landing between the placement
##     decision and the launch is not overwritten by the stale class; the
##     launcher applying the placement-time class directly, without the
##     last-instant read, leaves the tree at the stale class and the check
##     fails (the Windows analogue of `t_group_weight_race`'s case 3).

when defined(windows):
  import std/[os, strutils, tempfiles, unittest]
  import std/winlean

  import runquota_process

  import runquota_core

  const
    NormalPriorityClass = 0x00000020'u32
    BelowNormalPriorityClass = 0x00004000'u32
    IdlePriorityClass = 0x00000040'u32
    AboveNormalPriorityClass = 0x00008000'u32

  proc readFixedHigh(context: pointer; priority: var SessionPriority): bool
      {.nimcall, raises: [].} =
    ## A `GroupPrioritySource.read` that answers `high` -- the test's stand-in
    ## for a `runquota session set --priority high` the daemon has taken by the
    ## time the launch reads the priority in force, after the placement decided
    ## a different class. Real `GroupPrioritySource`, real `readNow` call in the
    ## launcher; only the daemon round-trip is replaced, the seam the Linux
    ## weight-race test (`t_group_weight_race`) uses for the same proof.
    priority = sessionPriorityHigh
    true

  proc getPriorityClass(hProcess: Handle): uint32
    {.stdcall, dynlib: "kernel32.dll", importc: "GetPriorityClass".}
  proc getCurrentProcessHandle(): Handle
    {.stdcall, dynlib: "kernel32.dll", importc: "GetCurrentProcess".}

  proc ownPriority(): uint32 = getPriorityClass(getCurrentProcessHandle())

  proc awaitFile(path: string; timeoutMillis = 10_000): bool =
    var waited = 0
    while waited < timeoutMillis:
      if fileExists(path): return true
      sleep(20)
      waited += 20

  # -------------------------------------------------------------------
  # The worker arms of this binary (run before any test)
  # -------------------------------------------------------------------

  proc spawnGrandchildRaw(grandOut: string) =
    ## Spawn the grandchild through a bare `CreateProcessW` with NO creation
    ## flags, so the documented priority-class inheritance applies (a child of
    ## a below-normal process is itself below-normal). `std/osproc` would
    ## defeat the check: it hard-codes `NORMAL_PRIORITY_CLASS` on every child
    ## it creates, which real leased programs -- compilers, shells -- do not.
    let commandLine = "\"" & getAppFilename() & "\" --rqtest-report-own \"" &
      grandOut & "\""
    var si = STARTUPINFO(cb: int32(sizeof(STARTUPINFO)))
    var pi: PROCESS_INFORMATION
    if createProcessW(nil, newWideCString(commandLine), nil, nil, 0, 0'i32,
        nil, nil, si, pi) != 0:
      discard waitForSingleObject(pi.hProcess, 10_000)
      discard closeHandle(pi.hThread)
      discard closeHandle(pi.hProcess)

  proc runWorkerOrReturn() =
    let params = commandLineParams()
    if params.len == 0:
      return
    case params[0]
    of "--rqtest-report-priority":
      # params: OUT GO GRANDOUT. Wait for the launcher to have set our
      # priority (the GO file), spawn a grandchild that reports ITS class
      # (it inherits ours), wait for it, then report our own class.
      let outPath = params[1]
      let goPath = params[2]
      let grandOut = params[3]
      discard awaitFile(goPath)
      spawnGrandchildRaw(grandOut)
      writeFile(outPath, $ownPriority())
      quit(0)
    of "--rqtest-report-own":
      writeFile(params[1], $ownPriority())
      quit(0)
    else:
      return

  runWorkerOrReturn()

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  proc selfSpec(args: seq[string]): CommandSpec =
    var argv = @[getAppFilename()]
    argv.add args
    commandSpec(argv, stdio = inheritStdio, createProcessGroup = false)

  proc priorityAfterLaunch(niceIncrement: int; jobPriorityClass = 0'u32;
      prioritySource = GroupPrioritySource()):
      tuple[child, grandchild: uint32] =
    ## Launch a child (which spawns a grandchild) with `niceIncrement` and,
    ## when non-zero, the Job Object priority-class limit `jobPriorityClass`;
    ## with a `prioritySource` the launcher reads the class at the last instant
    ## from it instead (`CommandSpec.cgroupPriority`). Let it report, and read
    ## both classes back.
    let dir = createTempDir("rqprio", "")
    defer: removeDir(dir)
    let outPath = dir / "child"
    let goPath = dir / "go"
    let grandOut = dir / "grand"
    var spec = selfSpec(@["--rqtest-report-priority", outPath, goPath, grandOut])
    spec.niceIncrement = niceIncrement
    spec.jobPriorityClass = jobPriorityClass
    spec.cgroupPriority = prioritySource
    var child = launchProcess(spec)
    # The launcher has set (or not set) the priority by now; release the
    # worker, which only then reads its class.
    writeFile(goPath, "go")
    let completion = child.waitForCompletion()
    child.close()
    doAssert completion.exited and completion.exitCode == 0,
      "the priority worker did not exit cleanly"
    doAssert awaitFile(outPath, 2000) and awaitFile(grandOut, 2000),
      "the priority worker wrote no reading"
    (parseUInt(readFile(outPath).strip()).uint32,
     parseUInt(readFile(grandOut).strip()).uint32)

  suite "windows reclaimed priority":

    test "a reclaimed grant runs its tree at below-normal priority":
      let p = priorityAfterLaunch(niceIncrement = 10)
      checkpoint "child class: 0x" & toHex(p.child) &
        "; grandchild class: 0x" & toHex(p.grandchild)
      check p.child == BelowNormalPriorityClass
      # Inherited by the tree, as POSIX nice is through fork.
      check p.grandchild == BelowNormalPriorityClass

    test "a non-reclaimed grant runs at normal priority":
      let p = priorityAfterLaunch(niceIncrement = 0)
      checkpoint "child class: 0x" & toHex(p.child)
      # NOT below-normal: the lowering is tied to the reclaimed flag.
      check p.child == NormalPriorityClass
      check p.grandchild == NormalPriorityClass

    test "job-priority on forces a reclaimed tree to idle, below the baseline":
      # The switchable layer: a reclaimed grant (niceIncrement > 0) with the
      # Job Object priority-class limit of idle. The limit forces EVERY process
      # in the tree -- child and the grandchild it spawned with a bare
      # CreateProcessW -- to idle, lower than the below-normal baseline the
      # unconditional layer alone gives (the test above). Mutation: dropping
      # the Job Object limit leaves both at below-normal and this fails.
      let onp = priorityAfterLaunch(niceIncrement = 10,
        jobPriorityClass = IdlePriorityClass)
      checkpoint "child class: 0x" & toHex(onp.child) &
        "; grandchild class: 0x" & toHex(onp.grandchild)
      check onp.child == IdlePriorityClass
      check onp.grandchild == IdlePriorityClass
      # Stronger than the baseline: the switch-off reclaimed tree runs at
      # below-normal, this one at idle, and they are not the same class.
      let offp = priorityAfterLaunch(niceIncrement = 10)
      check offp.child == BelowNormalPriorityClass
      check onp.child != offp.child

    test "job-priority reads the priority in force at the launch, not at placement":
      # THE WINDOWS WEIGHT-RACE SEAM (the analogue of t_group_weight_race's
      # case 3). The placement resolved a STALE class -- below-normal, as if the
      # group was `low` when treePlacement ran -- and carries it on
      # `jobPriorityClass`. Between placement and the launch a `session set
      # --priority high` lands: the launcher's `cgroupPriority.readNow` answers
      # `high` now, so the Job Object limit must be ABOVE_NORMAL (high's class),
      # read at the last instant, NOT the stale below-normal. The whole tree
      # (child and the bare-CreateProcessW grandchild) reads back above-normal.
      # Mutation: the launcher applying `spec.jobPriorityClass` directly without
      # the last-instant read leaves both at below-normal (the stale class) and
      # this fails -- the same race, and the same failure, as the Linux leg.
      let raced = priorityAfterLaunch(niceIncrement = 0,
        jobPriorityClass = jobPriorityClassFor(sessionPriorityLow, reclaimed = false),
        prioritySource = GroupPrioritySource(read: readFixedHigh, context: nil))
      checkpoint "child class: 0x" & toHex(raced.child) &
        "; grandchild class: 0x" & toHex(raced.grandchild)
      check raced.child == AboveNormalPriorityClass
      check raced.grandchild == AboveNormalPriorityClass
      check raced.child != BelowNormalPriorityClass
else:
  echo "t_windows_reclaimed_priority: Windows only"
