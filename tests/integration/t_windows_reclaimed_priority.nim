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
## WHAT IS PROVEN, with the mutation that turns it red:
##   * a reclaimed grant's child -- and the grandchild it spawns -- run at
##     below-normal; skipping the `SetPriorityClass` call in the launcher
##     leaves them at normal and the checks fail;
##   * a non-reclaimed grant's child runs at normal, so the lowering is tied
##     to the reclaimed flag, not applied to everything.

when defined(windows):
  import std/[os, strutils, tempfiles, unittest]
  import std/winlean

  import runquota_process

  const
    NormalPriorityClass = 0x00000020'u32
    BelowNormalPriorityClass = 0x00004000'u32

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

  proc priorityAfterLaunch(niceIncrement: int):
      tuple[child, grandchild: uint32] =
    ## Launch a child (which spawns a grandchild) with `niceIncrement`, let it
    ## report, and read both classes back.
    let dir = createTempDir("rqprio", "")
    defer: removeDir(dir)
    let outPath = dir / "child"
    let goPath = dir / "go"
    let grandOut = dir / "grand"
    var spec = selfSpec(@["--rqtest-report-priority", outPath, goPath, grandOut])
    spec.niceIncrement = niceIncrement
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
else:
  echo "t_windows_reclaimed_priority: Windows only"
