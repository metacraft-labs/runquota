## Supervising a test child that is *expected* to be able to wedge.
##
## Every deadlock regression test in this repository runs the call under test
## in a re-executed child, because a hung call cannot report its own failure.
## That makes the child's own children the test's responsibility.
##
## It lives here, and not next to any one of them, because the spawn defects it
## supervises are not the property of a single library: the observation store,
## the estimate store and the macOS host backend all reach a child process, and
## the tests for all three need the same supervision. Three copies of a
## process-group kill is three chances for one of them to drift.
##
## Killing the direct child is not enough. The processes a deadlock test wedges
## are its GRANDchildren, and the interesting ones are wedged precisely because
## they hold each other's pipes open -- so when the direct child dies they do
## not see end of input, do not exit, and are reparented to pid 1 where they sit
## forever. A red test that leaves two immortal `sqlite3` processes behind is a
## gate failure in a campaign whose rule is that a milestone leaves nothing
## running, and it is also actively misleading: the leftovers look like a live
## defect long after the run that produced them is gone.
##
## So the whole tree is ended, which reaches every descendant however deep, and
## `awaitNoSurvivors` then makes the absence of leftovers a checked property
## rather than a hope -- it is asserted on the passing path too, where a leak
## would otherwise be invisible.
##
## THE SAME CONTRACT ON EVERY PLATFORM, FROM EACH PLATFORM'S OWN PRIMITIVES:
##
## ==========================  ===============================  ==============================================
##                             POSIX                            Windows
## ==========================  ===============================  ==============================================
## the tree                    the child's own process group    a Job Object the child is assigned to at start,
##                                                              plus the child's descendants by parent pid
## ending it                   `SIGKILL` to the group           `TerminateJobObject`, then `TerminateProcess`
##                                                              on every descendant found by parent pid
## the survivor inventory      `ps -axo pid=,command=`          every process's command line, read with
##                                                              `NtQueryInformationProcess`
## ==========================  ===============================  ==============================================
##
## Windows needs both halves of "the tree". The job is the only record of a
## descendant whose parent has already exited -- Windows never reparents, so a
## parent-pid walk loses it -- and the walk is the only record of anything the
## child started before `AssignProcessToJobObject` ran, because `startProcess`
## cannot start a child suspended. Neither alone covers what the POSIX group
## does. The walk runs only while the child is still running: once it has
## exited, its pid is free for reuse and only the job still names its tree.
## Windows also has no `ps` that sees native command lines: MSYS `ps`
## rejects `-o` outright, and lists only MSYS processes even where it runs.
##
## This is a TEST helper. It ends trees the test itself started; nothing in
## `runquotad` takes on terminating client process trees because of it.

import std/[os, osproc, strutils, times]

when defined(posix):
  import std/posix
  import runquota_process

  type SupervisedChild* = ref object
    child: LaunchedProcess

  proc processID*(process: SupervisedChild): int = process.child.pid

  proc peekExitCode*(process: SupervisedChild): int =
    if not process.child.pollCompletion():
      return -1
    let completion = process.child.completion
    if completion.signaled: 128 + completion.signal else: completion.exitCode

  proc running*(process: SupervisedChild): bool =
    not process.child.pollCompletion()

  proc close*(process: SupervisedChild) = process.child.close()
else:
  type SupervisedChild* = Process

when defined(windows):
  import std/[tables, widestrs, winlean]

  type
    ProcessEntry = object
      ## `PROCESSENTRY32W`, laid out as tlhelp32.h declares it.
      size: int32
      usage: int32
      processId: int32
      defaultHeapId: uint
      moduleId: int32
      threads: int32
      parentProcessId: int32
      priorityClassBase: int32
      flags: int32
      exeFile: array[260, Utf16Char]

    JobBasicLimit = object
      perProcessUserTimeLimit: int64
      perJobUserTimeLimit: int64
      limitFlags: int32
      minimumWorkingSetSize: uint
      maximumWorkingSetSize: uint
      activeProcessLimit: int32
      affinity: uint
      priorityClass: int32
      schedulingClass: int32

    JobIoCounters = object
      counters: array[6, uint64]

    JobExtendedLimit = object
      ## `JOBOBJECT_EXTENDED_LIMIT_INFORMATION`.
      basic: JobBasicLimit
      io: JobIoCounters
      processMemoryLimit: uint
      jobMemoryLimit: uint
      peakProcessMemoryUsed: uint
      peakJobMemoryUsed: uint

    UnicodeString = object
      ## `UNICODE_STRING`: `length` is in BYTES, without a terminator.
      length: uint16
      maximumLength: uint16
      buffer: ptr UncheckedArray[Utf16Char]

    FileTime = object
      low: uint32
      high: uint32

  const
    SnapProcess = 0x00000002'i32
    ProcessSetQuota = 0x00000100'i32
    JobObjectExtendedLimitInformation = 9'i32
    JobObjectLimitKillOnJobClose = 0x00002000'i32
    ProcessCommandLineInformation = 60'i32
      ## Windows 8.1 and later; needs only `PROCESS_QUERY_LIMITED_INFORMATION`,
      ## not `PROCESS_VM_READ`, so no other process's memory is read.

  proc createToolhelp32Snapshot(flags, processId: int32): Handle
    {.stdcall, dynlib: "kernel32.dll", importc: "CreateToolhelp32Snapshot".}
  proc process32FirstW(snapshot: Handle; entry: ptr ProcessEntry): WINBOOL
    {.stdcall, dynlib: "kernel32.dll", importc: "Process32FirstW".}
  proc process32NextW(snapshot: Handle; entry: ptr ProcessEntry): WINBOOL
    {.stdcall, dynlib: "kernel32.dll", importc: "Process32NextW".}
  proc createJobObjectW(attributes: pointer; name: WideCString): Handle
    {.stdcall, dynlib: "kernel32.dll", importc: "CreateJobObjectW".}
  proc setInformationJobObject(job: Handle; infoClass: int32; info: pointer;
                               length: int32): WINBOOL
    {.stdcall, dynlib: "kernel32.dll", importc: "SetInformationJobObject".}
  proc assignProcessToJobObject(job, process: Handle): WINBOOL
    {.stdcall, dynlib: "kernel32.dll", importc: "AssignProcessToJobObject".}
  proc terminateJobObject(job: Handle; exitCode: uint32): WINBOOL
    {.stdcall, dynlib: "kernel32.dll", importc: "TerminateJobObject".}
  proc watchdogProcessTimes(process: Handle; creation, exited, kernel,
                            user: ptr FileTime): WINBOOL
    {.stdcall, dynlib: "kernel32.dll", importc: "GetProcessTimes".}
  proc ntQueryInformationProcess(process: Handle; infoClass: int32;
                                 info: pointer; length: uint32;
                                 returned: ptr uint32): int32
    {.stdcall, dynlib: "ntdll.dll", importc: "NtQueryInformationProcess".}

  var supervisedJobs = initTable[int, Handle]()
    ## The job each supervised child was assigned to, by its pid. A handle is
    ## closed only by `killProcessTree`; on the passing path it stays open, so
    ## the job's kill-on-close limit also ends the tree if the test process
    ## itself dies before it gets that far.

  proc processTable(): seq[(int, int)] =
    ## Every (pid, parent pid) pair in one Toolhelp32 snapshot.
    let snapshot = createToolhelp32Snapshot(SnapProcess, 0)
    if snapshot == INVALID_HANDLE_VALUE or snapshot == 0:
      return
    defer: discard closeHandle(snapshot)
    var entry: ProcessEntry
    entry.size = int32(sizeof(ProcessEntry))
    if process32FirstW(snapshot, addr entry) == 0:
      return
    while true:
      result.add((int(uint32(entry.processId)),
                  int(uint32(entry.parentProcessId))))
      entry.size = int32(sizeof(ProcessEntry))
      if process32NextW(snapshot, addr entry) == 0:
        break

  proc creationTime(process: Handle): uint64 =
    ## 0 when it cannot be read.
    var creation, exited, kernel, user: FileTime
    if watchdogProcessTimes(process, addr creation, addr exited, addr kernel,
        addr user) != 0:
      result = (uint64(creation.high) shl 32) or uint64(creation.low)

  proc openDescendants(rootPid: int; access: int32): seq[Handle] =
    ## A handle to every live descendant of `rootPid`, deepest last.
    ##
    ## A snapshot's parent pid is the parent AT CREATION and Windows reuses
    ## pids, so an unrelated process whose parent died long ago can name a pid
    ## that now belongs to someone in this tree. A real child is never created
    ## before its parent: a link that says otherwise is rejected. The handle is
    ## opened before the creation time is read, so the time belongs to the
    ## process the handle holds, not to whatever reuses the pid next.
    let rows = processTable()
    let root = openProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, DWORD(rootPid))
    if root == 0:
      return
    var parents = @[(rootPid, creationTime(root))]
    discard closeHandle(root)
    var seen = @[rootPid]
    var index = 0
    while index < parents.len:
      let (parentPid, parentBorn) = parents[index]
      inc index
      for (pid, ppid) in rows:
        if ppid != parentPid or pid in seen or pid == 0:
          continue
        let handle = openProcess(access or PROCESS_QUERY_LIMITED_INFORMATION,
          0, DWORD(pid))
        if handle == 0:
          continue
        let born = creationTime(handle)
        if born != 0 and parentBorn != 0 and born < parentBorn:
          discard closeHandle(handle)
          continue
        seen.add(pid)
        result.add(handle)
        parents.add((pid, born))

  proc commandLineOf(process: Handle): string =
    ## The process's command line as the kernel recorded it, or "".
    var buffer = newSeq[byte](4096)
    for _ in 0 ..< 4:
      var returned = 0'u32
      let status = ntQueryInformationProcess(process,
        ProcessCommandLineInformation, addr buffer[0], uint32(buffer.len),
        addr returned)
      if status >= 0:
        let text = cast[ptr UnicodeString](addr buffer[0])
        let units = int(text.length) div 2
        if units == 0 or text.buffer == nil:
          return ""
        var wide = newSeq[Utf16Char](units + 1)
        copyMem(addr wide[0], text.buffer, units * 2)
        return $cast[WideCString](addr wide[0])
      if int(returned) <= buffer.len:
        return ""
      buffer.setLen(int(returned))
    ""

  proc stillRunning(process: Handle): bool =
    var code = 0'i32
    getExitCodeProcess(process, code) != 0 and code == STILL_ACTIVE

proc startSupervisedChild*(command: string; args: openArray[string]): SupervisedChild =
  ## Start ``command`` so that everything it spawns can be ended as a unit.
  ##
  ## POSIX process groups come from the client process substrate, rather
  ## than osproc's platform-dependent daemon option. Inherited stdio adds no
  ## undrained pipes to the deadlock fixtures being supervised.
  when defined(posix):
    result = SupervisedChild(child: launchProcess(commandSpec(
      @[command] & @args, stdio = inheritStdio, createProcessGroup = true)))
  else:
    result = startProcess(command, args = @args,
      options = {poParentStreams, poDaemon})
  when defined(windows):
    let pid = result.processID
    let job = createJobObjectW(nil, nil)
    if job == 0:
      return
    var limits: JobExtendedLimit
    limits.basic.limitFlags = JobObjectLimitKillOnJobClose
    discard setInformationJobObject(job, JobObjectExtendedLimitInformation,
      addr limits, int32(sizeof(limits)))
    let child = openProcess(ProcessSetQuota or PROCESS_TERMINATE, 0, DWORD(pid))
    var assigned = false
    if child != 0:
      assigned = assignProcessToJobObject(job, child) != 0
      discard closeHandle(child)
    if not assigned:
      # Still killable through the parent-pid walk in `killProcessTree`.
      discard closeHandle(job)
      return
    let adoptAccess = ProcessSetQuota or PROCESS_TERMINATE
    for descendant in openDescendants(pid, adoptAccess):
      discard assignProcessToJobObject(job, descendant)
      discard closeHandle(descendant)
    supervisedJobs[pid] = job

proc waitBounded*(process: SupervisedChild; seconds: int): int =
  ## The child's exit code, or -1 if it was still running at the deadline.
  let deadline = epochTime() + float(seconds)
  while epochTime() < deadline:
    let code = process.peekExitCode()
    if code != -1:
      return code
    sleep(25)
  -1

proc killProcessTree*(process: SupervisedChild) =
  ## End the child's whole tree, then reap the child.
  ##
  ## The tree is the point: a wedged grandchild holding a sibling's pipe will
  ## not exit just because its parent did, so ending only the direct child is
  ## what strands it.
  when defined(posix):
    process.child.killNow()
    discard process.child.waitForCompletion()
  when defined(windows):
    # The descendants are found BEFORE anything is ended: once the child is
    # gone its children name a parent that no longer exists, and the walk can
    # no longer reach them.
    #
    # Only while the child is still running, though: `osproc` closes its
    # handle the moment it observes the exit, and from then on nothing keeps
    # the pid from being reused, so a walk from it could end some unrelated
    # process's children. A child that has already exited is left to its job.
    let pid = process.processID
    var doomed: seq[Handle]
    if process.peekExitCode() == -1:
      doomed = openDescendants(pid, PROCESS_TERMINATE or SYNCHRONIZE)
    if pid in supervisedJobs:
      let job = supervisedJobs[pid]
      discard terminateJobObject(job, 1)
      discard closeHandle(job)
      supervisedJobs.del(pid)
    for handle in doomed:
      discard terminateProcess(handle, 1)
  when not defined(posix):
    try:
      kill(process)
    except CatchableError:
      discard
    discard process.waitForExit()
  when defined(windows):
    # Termination is asynchronous; return only once every descendant has
    # actually gone, so a survivor check that follows sees the end state.
    for handle in doomed:
      discard waitForSingleObject(handle, 10_000)
      discard closeHandle(handle)

proc survivingProcesses*(marker: string): seq[string] =
  ## Every process whose command line still mentions ``marker``, each as
  ## ``"<pid> <command line>"``.
  ##
  ## ``marker`` should be the run's unique temporary directory, which appears
  ## in the arguments of anything the child launched against it. Deleting that
  ## directory does not erase it from a running process's argv, so this still
  ## finds leftovers after cleanup.
  when defined(windows):
    let self = getCurrentProcessId()
    for (pid, _) in processTable():
      if pid == 0 or pid == self:
        continue
      let handle = openProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, DWORD(pid))
      if handle == 0:
        continue  # protected or already gone: never one of ours
      let commandLine =
        if stillRunning(handle): commandLineOf(handle) else: ""
      discard closeHandle(handle)
      if commandLine.len > 0 and marker in commandLine:
        result.add($pid & " " & commandLine.strip())
  else:
    # stderr is folded into stdout rather than left on an unread pipe -- the
    # defect these tests exist for.
    let listing = execProcess(
      "ps",
      args = ["-axo", "pid=,command="],
      options = {poUsePath, poStdErrToStdOut}
    )
    for line in listing.splitLines():
      if marker in line and line.len > 0:
        result.add(line.strip())

proc awaitNoSurvivors*(marker: string; seconds: int): seq[string] =
  ## Poll until nothing mentioning ``marker`` is left, or the deadline passes.
  ## Returns whatever is still alive, so a caller can report it.
  let deadline = epochTime() + float(seconds)
  while true:
    result = survivingProcesses(marker)
    if result.len == 0:
      return
    if epochTime() >= deadline:
      return
    sleep(100)
