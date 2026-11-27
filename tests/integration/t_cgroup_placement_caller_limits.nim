## A launcher that runs under a cgroup limit its caller set on purpose keeps
## its trees under that limit; only the agent session's own scope, named by
## `RUNQUOTA_AGENT_SESSION_SCOPE`, is left.
##
## THE RULE (unit level: `libs/runquota_process/tests/t_caller_limit_placement.nim`).
## The deepest limited cgroup L between the launcher and the root it would
## use, other than the marked scope, holds the tree: the root becomes
## `L/runquota` when L is delegated, and placement is refused (the tree runs
## where the launcher is, under L's limit, at the fallback nice) when it is
## not.
##
## WHAT IS GUARDED, each with the change that makes it fail. Every case
## starts a copy of this test as the LAUNCHER inside a real
## `systemd-run --user --scope` with a real limit; the launcher resolves its
## root as RunQuota's launchers do (`currentCgroupRoot`, with a test-owned
## explicit root in `RUNQUOTA_CGROUP_ROOT`, never the user's
## `runquota.slice`), launches, and prints what happened.
##
## * (a) A delegated scope with `MemoryMax=96M` (systemd asked at most once,
##   the answer recorded, and a second launcher process not asking:
##   mutations, not asking -- refused -- and not recording -- asked again):
##   the tree is placed under
##   `L/runquota`, the launcher moved into `L/caller`. A tree that allocates
##   160 MiB, under its own 256 MiB cap, is killed by the scope's limit and
##   classified as killed from outside its cap; an uncapped tree launched
##   afterwards by the same launcher runs normally. Mutation: placing in the
##   candidate root (the tree then survives past MemoryMax).
## * (b) A scope with `MemoryMax` that is not delegated: placement is
##   refused, the reason names the scope, `memory.max=...` and
##   `-p Delegate=yes` and systemd's `Delegate=no`, the child runs in the
##   scope at the fallback nice, the "no" is recorded too (one query over two
##   launcher processes; mutation: recording only "yes"), and
##   a memory cap on it reports that reason. Mutation:
##   ignoring the limit (the child is placed in the test root, out of the
##   scope).
## * (c) The marked scope: a capped scope whose unit name the launcher's
##   `RUNQUOTA_AGENT_SESSION_SCOPE` names is left (the tree goes to the test
##   root); with the marker naming another unit, or with an agent-session-like
##   unit name and no marker, the tree stays. Mutation: matching by the
##   name pattern.
## * (d) A limited cgroup nested inside the marked scope keeps the tree
##   inside it. Mutation: honouring the marker for any ancestor.
## * (f) A `systemctl` that sleeps 30 s holding its output pipe open: the
##   launch returns within a few seconds, placement refused with the
##   timeout. Mutation: a blocking drain of the pipe.
## * (g) A `systemctl` that answers but leaves a child holding its output
##   pipe: the answer is used at once. Mutation: a blocking drain.
## * (h) A delegated cgroup the cpu controller does not reach: the launch
##   names the missing controller, places nothing, and leaves no
##   `L/runquota` behind. Mutation: creating the root before the holder is
##   ready.
## * (e) Eight launchers started together in one delegated scope (three
##   rounds) ask systemd exactly once per round (mutation: no lock on the
##   unit around the query -- several ask) and all place their trees: L's
##   lock serializes the move of the scope's processes and the enabling of
##   its controllers. This is a
##   positive check only: with the lock removed, 9 rounds of 8 launchers
##   still all placed their trees on the host it was written on (every step
##   accepts what a concurrent launcher already did, and the first mover
##   empties the scope in one pass), so it does not prove the lock is
##   needed.
##
## DELEGATION is what systemd says. On the host this was written on (systemd
## 260) the user manager writes no `user.delegate` attribute on the cgroup of
## a unit it delegates, so the launcher, finding none, asks the manager once
## (`systemctl --user show -p Delegate --value <unit>`) and records the
## answer, yes or no, in RunQuota's own `user.runquota.delegated` attribute
## on the unit's cgroup (it only reads systemd's `user.delegate`). (a) checks
## that the first launch asked at most once and recorded a "yes", and that a
## second launcher process read the record instead of asking; (b) that a
## "no" is recorded too, asked once over two launcher processes and refused
## with systemd's answer in the reason; (d) that a plain cgroup below a
## delegated unit is delegated by the unit's answer; (e) that launchers
## starting together ask exactly once.
##
## THE OBSERVATION POINT: a `systemctl` on the launcher's PATH that logs its
## arguments and runs the real `systemctl` (`systemctlShim`). It changes no
## answer; it only lets the test count the queries.
##
## SKIPPED, with the reason, where this user has no `systemd-run --user`, no
## delegated cgroup v2 subtree for the test root, or a scope on which
## systemd did not apply the limit.
##
## NO MOCKS otherwise: real scopes, real limits, real cgroup files, a real
## OOM kill. Each scope ends with its launcher, and systemd removes its
## cgroup and everything the launcher created in it.

when defined(linux):
  import std/[monotimes, os, osproc, posix, streams, strutils, times, unittest]

  import runquota_core
  import runquota_process
  import cgroup_test_root

  proc getpriority(which: cint; who: Id): cint {.importc, header: "<sys/resource.h>".}
  var PRIO_PROCESS {.importc, header: "<sys/resource.h>".}: cint
  var MAP_ANONYMOUS_FLAG {.importc: "MAP_ANONYMOUS", header: "<sys/mman.h>".}: cint

  proc ownDir(): string = CgroupMountPoint & cgroupOfPid(getCurrentProcessId())

  proc getxattr(path, name: cstring; value: pointer; size: csize_t): int {.
    importc, header: "<sys/xattr.h>".}

  proc recordedAnswer(dir: string): string =
    ## RunQuota's record of systemd's answer on `dir`.
    var value: array[16, char]
    let got = getxattr(cstring(dir), cstring(DelegationRecordAttr),
      addr value[0], csize_t(value.len))
    for i in 0 ..< max(got, 0): result.add(value[i])

  proc logLine(text: string) =
    ## A line in the systemctl shim's log (`RQTEST_SHIM_LOG`), to tell the
    ## queries of the first launch from those after it.
    let log = getEnv("RQTEST_SHIM_LOG")
    if log.len > 0:
      let f = open(log, fmAppend)
      f.writeLine(text)
      f.close()

  if paramCount() >= 1 and paramStr(1) == "--report":
    echo $getpriority(PRIO_PROCESS, Id(0)) & " " &
      cgroupOfPid(getCurrentProcessId())
    quit(0)

  if paramCount() >= 2 and paramStr(1) == "--alloc":
    let size = parseInt(paramStr(2)) * 1024 * 1024
    let base = mmap(nil, size, PROT_READ or PROT_WRITE,
      MAP_PRIVATE or MAP_ANONYMOUS_FLAG, -1, 0)
    if base == MAP_FAILED:
      quit(3)
    let bytes = cast[ptr UncheckedArray[byte]](base)
    var i = 0
    while i < size:
      bytes[i] = 1
      i += 4096
    echo "allocated"
    quit(0)

  if paramCount() >= 3 and paramStr(1) == "--launch":
    # The launcher inside its scope. argv: --launch <explicit root> <mode>
    # where mode is report | alloc | nested-report | resolve (resolve only,
    # launch nothing).
    let mode = paramStr(3)
    if mode == "nested-nocpu":
      # A limited cgroup of the launcher's own inside its delegated scope,
      # given memory but NOT cpu: delegated (through the scope), but the
      # cpu controller does not reach it.
      let outer = ownDir()
      let inner = outer / "inner"
      createDir(inner)
      writeFile(inner / "cgroup.procs", $getCurrentProcessId())
      writeFile(outer / "cgroup.subtree_control", "+memory")
      writeFile(inner / "memory.max", $(512 * 1024 * 1024))
    if mode == "nested-report":
      # A limited, delegated cgroup of the launcher's own inside its
      # (marked) scope: move into it, then limit it.
      let outer = ownDir()
      let inner = outer / "inner"
      createDir(inner)
      writeFile(inner / "cgroup.procs", $getCurrentProcessId())
      writeFile(outer / "cgroup.subtree_control", "+cpu +memory")
      writeFile(inner / "memory.max", $(512 * 1024 * 1024))
    putEnv(CgroupRootEnvVar, paramStr(2))
    let started = getMonoTime()
    let root = currentCgroupRoot()
    echo "resolve_ms=" & $(getMonoTime() - started).inMilliseconds
    echo "root_state=" & $root.state
    echo "root_path=" & root.path
    echo "root_reason=" & root.reason.replace("\n", " ")
    var target = targetFor(root, "caller-limits", sessionPriorityLow,
      reclaimed = false)
    proc launch(argv: openArray[string]; capMiB: int; label: string) =
      var spec = commandSpec(argv)
      spec.cgroup = target
      spec.placementFallbackNice = fallbackNice(sessionPriorityLow,
        reclaimed = false)
      if capMiB > 0:
        spec.memoryCapBytes = uint64(capMiB) shl 20
        spec.memoryCapAction = mcaKill
      var child = launchProcess(spec)
      let info = child.info
      let completion = child.waitForCompletion(60_000)
      child.close()
      echo label & "_cgroup_path=" & info.cgroupPath
      echo label & "_problem=" & info.cgroupProblem.replace("\n", " ")
      echo label & "_memory_problem=" &
        info.memoryCapProblem.replace("\n", " ")
      echo label & "_stdout=" & completion.stdout.strip().replace("\n", " ")
      echo label & "_signaled=" & $completion.signaled
      echo label & "_outside=" & $completion.oomKilledOutsideCap
      echo label & "_cap_killed=" & $completion.capKilled
    if mode == "alloc":
      launch([getAppFilename(), "--alloc", "160"], 256, "alloc")
    if mode == "nested-nocpu":
      echo "holder_root_exists=" & $dirExists(root.path)
    if mode != "resolve":
      launch([getAppFilename(), "--report"],
        (if mode == "alloc": 0 else: 64), "report")
    if mode == "nested-nocpu":
      echo "holder_root_exists_after=" & $dirExists(root.path)
    let scope = ownDir().parentDir
    echo "recorded=" & recordedAnswer(if root.holder.len > 0: root.holder
      else: ownDir())
    echo "caller_cgroup=" & cgroupOfPid(getCurrentProcessId())
    echo "caller_nice=" & $getpriority(PRIO_PROCESS, Id(0))
    discard scope
    if getEnv("RQTEST_SECOND") == "1":
      # A SECOND LAUNCHER PROCESS in the same scope, as the next `runquota
      # run` would be: the per-process memo is gone, so only what the first
      # recorded can spare it the query. Exactly one: it must not start a
      # third.
      delEnv("RQTEST_SECOND")
      logLine("--- second launcher")
      let second = startProcess(getAppFilename(),
        args = ["--launch", paramStr(2), "resolve"],
        options = {poStdErrToStdOut})
      let output = second.outputStream.readAll()
      discard second.waitForExit()
      second.close()
      for line in output.splitLines():
        if line.len > 0:
          echo "second_" & line
    quit(0)

  if paramCount() >= 3 and paramStr(1) == "--race":
    # Several launchers started at once in one delegated, capped scope:
    # argv: --race <explicit root> <count>. Each runs `--launch ... report`;
    # this prints how many placed their tree, and every failure.
    var launchers: seq[Process]
    # The launchers' own systemctl queries are counted by the shim on PATH.
    for _ in 0 ..< parseInt(paramStr(3)):
      launchers.add(startProcess(getAppFilename(),
        args = ["--launch", paramStr(2), "report"], options = {}))
    var placed = 0
    for launcher in launchers:
      let output = launcher.outputStream.readAll()
      discard launcher.waitForExit()
      launcher.close()
      var path = ""
      for line in output.splitLines():
        if line.startsWith("report_cgroup_path="):
          path = line["report_cgroup_path=".len .. ^1]
      if path.len > 0:
        inc placed
      else:
        echo "unplaced: " & output.replace("\n", " | ")
    echo "placed=" & $placed
    quit(0)

  proc field(output, key: string): string =
    for line in output.splitLines():
      if line.startsWith(key & "="):
        return line[key.len + 1 .. ^1]
    ""

  proc systemdRunProblem(): string =
    if findExe("systemd-run").len == 0:
      return "no systemd-run on PATH"
    let (output, code) = execCmdEx("systemd-run --user --scope -q -- true")
    if code != 0:
      return "systemd-run --user --scope does not work here (exit " & $code &
        "): " & output.strip()
    ""

  proc systemctlShim(dir: string; slow = false; lingering = false): string =
    ## A `systemctl` that appends its arguments to `<dir>/calls` and then
    ## runs the real one: put first on the launcher's PATH, it counts how
    ## often the launcher asks systemd. An observation point, not a mock:
    ## the real systemctl answers every call. Returns the log's path.
    let real = findExe("systemctl")
    createDir(dir)
    let log = dir / "calls"
    # Absolute paths only: the launcher runs systemctl with an environment
    # that has no PATH.
    writeFile(dir / "systemctl", "#!/bin/sh\necho \"$*\" >> " &
      quoteShell(log) & "\n" &
      (if slow: "echo waiting\n" &
        quoteShell(findExe("sleep", followSymlinks = false)) & " 30\n"
       else: "") &
      (if lingering: quoteShell(findExe("sleep", followSymlinks = false)) &
        " 30 &\n" else: "") & "exec " &
      quoteShell(real) & " \"$@\"\n")
    setFilePermissions(dir / "systemctl",
      {fpUserRead, fpUserWrite, fpUserExec})
    log

  proc queries(log: string; afterSecond = false): int =
    ## How many systemctl calls the shim logged, before the second
    ## launcher's marker line or (`afterSecond`) after it.
    var second = false
    let text = try: readFile(log) except IOError, OSError: ""
    for line in text.splitLines():
      if line.len == 0: continue
      if line.startsWith("--- "):
        second = true
      elif second == afterSecond:
        inc result

  proc inScope(properties: seq[string]; unit: string; env: seq[string];
               root, mode: string): string =
    ## Run the launcher in a fresh scope; its output.
    var command = "systemd-run --user --scope -q"
    if unit.len > 0:
      command.add(" --unit=" & quoteShell(unit))
    for property in properties:
      command.add(" -p " & quoteShell(property))
    command.add(" -- env -u " & AgentSessionScopeEnvVar)
    for entry in env:
      command.add(" " & quoteShell(entry))
    if mode.startsWith("race:"):
      command.add(" " & quoteShell(getAppFilename()) & " --race " &
        quoteShell(root) & " " & mode[5 .. ^1])
    else:
      command.add(" " & quoteShell(getAppFilename()) & " --launch " &
        quoteShell(root) & " " & mode)
    let (output, code) = execCmdEx(command)
    checkpoint output
    doAssert code == 0, "the scope's launcher failed: " & output
    output

  proc reportCgroup(output, label: string): string =
    let report = output.field(label & "_stdout").splitWhitespace()
    if report.len == 2: report[1] else: ""

  suite "a launcher under a caller's limit":
    let unavailable = systemdRunProblem()
    var reason = unavailable
    let testRoot =
      if unavailable.len == 0: delegatedTestRoot(reason, checkLimits = false)
      else: ""
    let relRoot =
      if testRoot.len > 0: testRoot[CgroupMountPoint.len .. ^1] else: ""
    let tag = $getCurrentProcessId()

    test "(a) a delegated, capped scope keeps the tree, and its limit kills it":
      if testRoot.len == 0:
        echo "SKIPPED: " & reason
        skip()
      else:
        let log = systemctlShim(getTempDir() / ("rq-shim-a-" & tag))
        defer: removeDir(log.parentDir)
        let output = inScope(@["Delegate=yes", "MemoryMax=96M"], "",
          @["PATH=" & log.parentDir & ":" & getEnv("PATH"),
            "RQTEST_SHIM_LOG=" & log, "RQTEST_SECOND=1"], testRoot, "alloc")
        # systemd was asked at most once (none at all where it marks the
        # unit itself), said yes, and the answer was recorded ...
        check queries(log) <= 1
        check output.field("recorded") == "yes" or queries(log) == 0
        # ... and a second launcher process, with no memo of its own, read
        # the record and did not ask.
        check queries(log, afterSecond = true) == 0
        check output.field("second_root_path") == output.field("root_path")
        let caller = output.field("caller_cgroup")
        let scope = caller.parentDir
        check caller.endsWith("/caller")
        check output.field("root_path") ==
          CgroupMountPoint & scope & "/runquota"
        # The capped allocator: placed under the scope, killed by the
        # scope's limit, from outside its own cap.
        check output.field("alloc_cgroup_path").startsWith(
          CgroupMountPoint & scope & "/runquota/")
        check output.field("alloc_signaled") == "true"
        check output.field("alloc_outside") == "true"
        check output.field("alloc_cap_killed") == "false"
        check "allocated" notin output.field("alloc_stdout")
        # An uncapped tree of the same launcher runs, placed, unaffected.
        check reportCgroup(output, "report").startsWith(scope & "/runquota/")
        check output.field("report_problem") == ""

    test "(b) a capped scope that is not delegated refuses placement":
      if testRoot.len == 0:
        echo "SKIPPED: " & reason
        skip()
      else:
        let log = systemctlShim(getTempDir() / ("rq-shim-b-" & tag))
        defer: removeDir(log.parentDir)
        let output = inScope(@["MemoryMax=1G"], "",
          @["PATH=" & log.parentDir & ":" & getEnv("PATH"),
            "RQTEST_SHIM_LOG=" & log, "RQTEST_SECOND=1"], testRoot, "report")
        # The "no" is recorded too: one query over two launcher processes.
        check queries(log) == 1
        check queries(log, afterSecond = true) == 0
        check output.field("recorded") == "no"
        check output.field("second_root_state") == $crsUnavailable
        let caller = output.field("caller_cgroup")
        let rootReason = output.field("root_reason")
        check output.field("root_state") == $crsUnavailable
        check caller in rootReason
        check "memory.max=1073741824" in rootReason
        check "-p Delegate=yes" in rootReason
        # systemd's own answer, which the launcher asked for.
        check "Delegate=no" in rootReason
        check output.field("report_cgroup_path") == ""
        check reportCgroup(output, "report") == caller
        let report = output.field("report_stdout").splitWhitespace()
        check report.len == 2
        check report.len == 2 and report[0] == $min(parseInt(
          output.field("caller_nice")) + LowPriorityNiceIncrement, 19)
        check "memory.max=1073741824" in output.field("report_memory_problem")
        check not dirExists(testRoot)

    test "(c) only the scope the marker names is left":
      if testRoot.len == 0:
        echo "SKIPPED: " & reason
        skip()
      else:
        let unit = "agent-session-rqtest-" & tag & "-c"
        let marked = inScope(@["MemoryMax=1G"], unit,
          @[AgentSessionScopeEnvVar & "=" & unit & ".scope"], testRoot,
          "report")
        check marked.field("root_path") == testRoot
        check reportCgroup(marked, "report").startsWith(relRoot & "/")
        let other = inScope(@["MemoryMax=1G"], unit & "2",
          @[AgentSessionScopeEnvVar & "=" & unit & ".scope"], testRoot,
          "report")
        check other.field("root_state") == $crsUnavailable
        check reportCgroup(other, "report") == other.field("caller_cgroup")
        let unmarked = inScope(@["MemoryMax=1G"], unit & "3", @[], testRoot,
          "report")
        check unmarked.field("root_state") == $crsUnavailable
        check reportCgroup(unmarked, "report") ==
          unmarked.field("caller_cgroup")
        check removeTestRoot(testRoot) == ""

    test "(d) a capped cgroup nested inside the marked scope keeps the tree":
      if testRoot.len == 0:
        echo "SKIPPED: " & reason
        skip()
      else:
        let unit = "agent-session-rqtest-" & tag & "-d"
        let output = inScope(@["Delegate=yes", "MemoryMax=1G"], unit,
          @[AgentSessionScopeEnvVar & "=" & unit & ".scope"], testRoot,
          "nested-report")
        let caller = output.field("caller_cgroup")
        check caller.endsWith("/inner/caller")
        let inner = caller.parentDir
        check output.field("root_path") == CgroupMountPoint & inner &
          "/runquota"
        check reportCgroup(output, "report").startsWith(inner & "/runquota/")
        check removeTestRoot(testRoot) == ""

    test "(e) launchers starting together in one scope all place their trees":
      if testRoot.len == 0:
        echo "SKIPPED: " & reason
        skip()
      else:
        # Eight launchers race to ask systemd whether the scope is
        # delegated, to move the scope's processes (each other included)
        # into its caller leaf and to enable its controllers. The unit's
        # lock makes the question one question: exactly one query per
        # round (mutation: no lock -- several launchers ask). L's lock
        # serializes the rest, and every tree is placed.
        for round in 0 ..< 3:
          let log = systemctlShim(getTempDir() / ("rq-shim-e-" & tag & "-" &
            $round))
          defer: removeDir(log.parentDir)
          let output = inScope(@["Delegate=yes", "MemoryMax=1G"], "",
            @["PATH=" & log.parentDir & ":" & getEnv("PATH")], testRoot,
            "race:8")
          check output.field("placed") == "8"
          check queries(log) == 1

    test "(f) a systemctl that does not answer costs one bounded wait":
      if testRoot.len == 0:
        echo "SKIPPED: " & reason
        skip()
      else:
        # A systemctl that sleeps 30 s, keeping its output pipe open
        # through its own child: the launcher kills it at its 2 s timeout,
        # does not wait on the pipe, and refuses placement with the timeout
        # as the reason. Mutation: a blocking drain (the launch then waits
        # out the 30 s).
        let log = systemctlShim(getTempDir() / ("rq-shim-f-" & tag),
          slow = true)
        defer: removeDir(log.parentDir)
        let started = getMonoTime()
        let output = inScope(@["Delegate=yes", "MemoryMax=1G"], "",
          @["PATH=" & log.parentDir & ":" & getEnv("PATH")], testRoot,
          "resolve")
        let elapsed = (getMonoTime() - started).inMilliseconds
        check parseInt(output.field("resolve_ms")) < 6_000
        check elapsed < 10_000
        check output.field("root_state") == $crsUnavailable
        check "did not answer within 2000 ms" in output.field("root_reason")

    test "(g) a systemctl whose child keeps the pipe open still answers in time":
      if testRoot.len == 0:
        echo "SKIPPED: " & reason
        skip()
      else:
        # The real systemctl answers and exits, but a child the shim left
        # behind keeps the output pipe open for 30 s: the launcher reads
        # what is there without waiting for the end of the pipe, and places
        # the tree. Mutation: a blocking drain (the launch waits out the
        # 30 s).
        let log = systemctlShim(getTempDir() / ("rq-shim-g-" & tag),
          lingering = true)
        defer: removeDir(log.parentDir)
        let output = inScope(@["Delegate=yes", "MemoryMax=1G"], "",
          @["PATH=" & log.parentDir & ":" & getEnv("PATH")], testRoot,
          "resolve")
        check parseInt(output.field("resolve_ms")) < 6_000
        check output.field("root_path").endsWith("/runquota")

    test "(h) a delegated cgroup without the cpu controller leaves nothing behind":
      if testRoot.len == 0:
        echo "SKIPPED: " & reason
        skip()
      else:
        # The holder is delegated (its scope said yes) but cannot carry the
        # trees: the launch says which controller is missing, runs the tree
        # where the launcher is, and creates no `L/runquota` in it.
        # Mutation: taking the root's lock (which creates the root) before
        # the holder is ready -- an empty `L/runquota` is left behind.
        let output = inScope(@["Delegate=yes", "MemoryMax=1G"], "", @[],
          testRoot, "nested-nocpu")
        let inner = CgroupMountPoint & output.field("caller_cgroup")
        check output.field("root_path").endsWith("/inner/runquota")
        check output.field("holder_root_exists") == "false"
        check output.field("report_cgroup_path") == ""
        check "the cpu controller is not delegated to it" in
          output.field("report_problem")
        check output.field("holder_root_exists_after") == "false"
        check inner.endsWith("/inner")

