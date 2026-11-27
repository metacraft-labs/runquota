## The memory cap a macOS launcher judges itself (`runquota_process/
## memory_cap`): it reads its tree's physical footprint while it waits,
## reports the tree's peak and a breach of the cap, and, under `mcaKill`,
## kills exactly that tree.
##
## The cases and the mutation each one falsifies:
##
## * advisory: a child holding 160 MiB under a 64 MiB cap is reported as
##   over the cap, NOT killed, and exits 0. Mutation: killing under
##   `mcaAdvisory` fails the exit status. (A walk that never judges a breach
##   does NOT fail this case: the root's zombie reading still catches it.
##   That mutation fails the sum, spike and kill cases instead.)
## * within the cap: a child holding 48 MiB under a 512 MiB cap is not over
##   it, and its peak is at least what it touched. Mutations: a judgement
##   that compares with `>=` 0, or that sums high-water marks, still passes
##   this; it is the false-breach control for the next two.
## * the sum: two processes holding 56 MiB each under a 96 MiB cap are over
##   it together, neither alone. Mutation: judging the largest process
##   instead of the sum fails it.
## * a spike between readings: a long-lived process that touches 160 MiB and
##   unmaps it within one reading interval, under a 96 MiB cap, is caught by
##   its kernel-kept high-water mark. Mutation: dropping
##   `maxProcessFootprintBytes` from the judgement fails it.
## * the root's own spike: a root that touches 160 MiB and exits at once,
##   before any reading, is caught from its zombie at the exit. Mutation:
##   dropping `observeExitedRoot` from the reap fails it.
## * no exit lost to the reap: a hundred roots that touch 32 MiB and exit
##   at once each report that peak. Mutation: going on to `wait4` after the
##   `WNOHANG` probe said "not exited" loses the zombie of a root that
##   exits between the two calls, about one launch in 30.
## * the kill: under `mcaKill` a tree of a shell, a background sleeper and
##   an allocating child is killed by SIGKILL, every process of it ends, and
##   a sibling tree launched beside it is untouched and exits 0. Mutation:
##   killing only the root (`kill(pid)` instead of `killMacosTree`) leaves
##   the sleeper alive.
## * the kill escapes nothing that forks: a process that forks children
##   into process groups of their own, as fast as it can, is killed with
##   every child it forked. Mutation: dropping the freeze (no SIGSTOP pass)
##   lets children forked after the walk survive; the case counts them.
##   The storm is BOUNDED (child count, its own lifetime, each child's), and
##   the case kills it by pid however it ends: a mutation that breaks the
##   kill must not leave a forking process behind on a shared host.
## * the tracker keeps a process re-parented to launchd after it was
##   found, and reads it. Mutation: reading the cap from the ancestry walk
##   (`sampleMacosProcessTreeTelemetry`) instead fails it.
## * the tracker costs nothing between forks: once a tree has stopped
##   forking, a reading lists no children. Mutation: listing every member's
##   children at every reading (what the ancestry walk does) fails it.
## * no cap, no cost: a launch with no cap and no `memoryCapMeasure` reads
##   its tree not once (`treeWalks` = 0 with tree sampling off). Mutation:
##   an always-active watch fails it. `memoryCapMeasure` alone reads the
##   peak and never reports a breach.
##
## NO MOCKS: the real launcher, real children (this binary re-executed, or
## `/bin/sh`), real memory touched with `mmap` so the kernel charges it to
## the process, and the kernel's own footprint accounting. macOS only: the
## Linux and Windows caps are the tree's cgroup leaf and Job Object, tested
## with their own launchers.
import std/[os, strutils, times, unittest]

import runquota_process

const
  MiB = 1024'u64 * 1024'u64
  HoldArgument = "--hold"         ## <MiB> <milliseconds>
  HoldLaterArgument = "--hold-later" ## <delay ms> <MiB> <milliseconds>
  SpikeArgument = "--spike"       ## <MiB> <milliseconds to live after>
  SleepArgument = "--sleep-pidfile" ## <path>: write the pid, sleep 20 s
  ForkStormArgument = "--fork-storm" ## <dir>: fork children, bounded
  StormPidFile = "storm.pid"
  StormMaxChildren = 300
  StormLifetimeMillis = 8_000
  StormChildMillis = 3_000
  StormForkEveryMillis = 1
  StormRounds = 5
  ReapRaceLaunches = 200
  SpikeRounds = 3
  SharedGroupArgument = "--launch-in-shared-group"
    ## Launch a capped `mcaKill` tree that shares THIS process's group, from
    ## a process group of our own; exit 0 when the tree was killed.
  NoDescriptorsArgument = "--launch-without-descriptors"
    ## Use up every descriptor, then launch with a cap; exit 0 when the
    ## launch reports the cap as not applied and says why.
  OrphanSpikeArgument = "--orphan-then-spike" ## <pidfile> <MiB>

when defined(macosx):
  import std/posix

  proc touch(mib: int): pointer =
    ## Map `mib` MiB and write every page, so the kernel charges all of it
    ## to this process's footprint.
    let size = mib * 1024 * 1024
    result = mmap(nil, size, PROT_READ or PROT_WRITE,
      MAP_PRIVATE or MAP_ANONYMOUS, -1, 0)
    doAssert result != MAP_FAILED, "mmap failed"
    var offset = 0
    while offset < size:
      cast[ptr byte](cast[uint](result) + uint(offset))[] = 1
      offset += 4096

  if paramCount() >= 1:
    case paramStr(1)
    of HoldArgument:
      discard touch(parseInt(paramStr(2)))
      sleep(parseInt(paramStr(3)))
      quit(0)
    of HoldLaterArgument:
      sleep(parseInt(paramStr(2)))
      discard touch(parseInt(paramStr(3)))
      sleep(parseInt(paramStr(4)))
      quit(0)
    of OrphanSpikeArgument:
      # Leave a sleeper behind, then peak and exit at once, before any
      # reading: only the root's zombie shows the breach.
      let pidfile = paramStr(2)
      let sleeper = fork()
      if sleeper == 0:
        writeFile(pidfile, $getpid())
        sleep(20_000)
        exitnow(0)
      while not fileExists(pidfile):
        sleep(1)
      let mib = parseInt(paramStr(3))
      doAssert munmap(touch(mib), mib * 1024 * 1024) == 0
      quit(0)
    of SpikeArgument:
      let mib = parseInt(paramStr(2))
      let mapped = touch(mib)
      doAssert munmap(mapped, mib * 1024 * 1024) == 0
      sleep(parseInt(paramStr(3)))
      quit(0)
    of SleepArgument:
      writeFile(paramStr(2), $getpid())
      sleep(20_000)
      quit(0)
    of ForkStormArgument:
      # Each child leaves this process group, so only the walk by ancestry
      # (not the group kill) can find it, and records its pid.
      #
      # BOUNDED WHATEVER HAPPENS TO IT. A mutation that breaks the kill (the
      # point of running mutations) leaves this process alive and orphaned,
      # and nothing else would ever stop it. An unbounded storm did exactly
      # that once and exhausted its user's process limit on a shared host.
      # So it forks at most `StormMaxChildren`, stops forking after
      # `StormLifetimeMillis`, and each child lives `StormChildMillis`: an
      # orphaned storm holds at most `StormMaxChildren` processes (300; it
      # forks them in about 0.3 s) and is gone about 3 s after its last
      # fork. It writes its own pid so the test kills it in any case.
      let dir = paramStr(2)
      writeFile(dir / StormPidFile, $getpid())
      let started = epochTime()
      var forked = 0
      while forked < StormMaxChildren and
          (epochTime() - started) * 1000.0 < float(StormLifetimeMillis):
        let pid = fork()
        if pid == 0:
          discard setpgid(0, 0)
          writeFile(dir / $getpid(), "")
          sleep(StormChildMillis)
          exitnow(0)
        if pid > 0:
          inc forked
        sleep(StormForkEveryMillis)
      quit(0)
    else:
      discard

  let self = getAppFilename()

  proc capped(argv: openArray[string]; capMiB: uint64;
              action = mcaAdvisory; measure = false): ProcessCompletion =
    var spec = commandSpec(argv)
    spec.memoryCapBytes = capMiB * MiB
    spec.memoryCapAction = action
    spec.memoryCapMeasure = measure
    var child = launchProcess(spec)
    result = child.waitForCompletion(timeout = 30_000)
    child.close()

  proc cappedWatch(argv: openArray[string]; capMiB: uint64;
                   action = mcaAdvisory; measure = false):
      tuple[done: ProcessCompletion; watch: MemoryCapWatch] =
    ## `capped`, keeping the launcher's own record of the cap as well.
    var spec = commandSpec(argv)
    spec.memoryCapBytes = capMiB * MiB
    spec.memoryCapAction = action
    spec.memoryCapMeasure = measure
    var child = launchProcess(spec)
    result.done = child.waitForCompletion(timeout = 30_000)
    result.watch = child.memoryCap
    child.close()

  if paramCount() >= 1 and paramStr(1) == SharedGroupArgument:
    # Our own group first, so a launcher that stops its group stops only
    # this helper and not the test that started it.
    discard setpgid(0, 0)
    var spec = commandSpec([self, HoldArgument, "160", "20000"],
      createProcessGroup = false)
    spec.memoryCapBytes = 64'u64 * MiB
    spec.memoryCapAction = mcaKill
    var child = launchProcess(spec)
    let done = child.waitForCompletion(timeout = 15_000)
    child.close()
    quit(if done.capKilled and done.signaled: 0 else: 3)

  if paramCount() >= 1 and paramStr(1) == NoDescriptorsArgument:
    # Fill the descriptor table, then launch without capture pipes: the
    # fork needs no descriptor, the kqueue does.
    var held: seq[cint]
    while true:
      let fd = dup(0)
      if fd < 0: break
      held.add(fd)
    var spec = commandSpec([self, HoldArgument, "8", "100"],
      stdio = inheritStdio)
    spec.memoryCapBytes = 64'u64 * MiB
    var child = launchProcess(spec)
    let applied = child.info.memoryCapApplied
    let problem = child.info.memoryCapProblem
    let done = child.waitForCompletion(timeout = 10_000)
    child.close()
    for fd in held: discard posix.close(fd)
    stderr.writeLine("applied=" & $applied & " problem=" & problem)
    quit(if not applied and problem.len > 0 and
        done.memoryCapProblem == problem and not done.memoryCapMeasured: 0
      else: 3)

  proc alive(pid: int): bool =
    ## Whether `pid` names a process that has not exited; a zombie counts as
    ## exited.
    if kill(Pid(pid), 0) != 0:
      return false
    # proc_pidinfo reports a zombie with no task; `ps` is the plain reading.
    let state = execShellCmd("ps -o stat= -p " & $pid &
      " | grep -q Z") == 0
    not state

  proc waitGone(pid: int; seconds = 5.0): bool =
    let deadline = epochTime() + seconds
    while epochTime() < deadline:
      if not alive(pid):
        return true
      sleep(20)
    not alive(pid)

  suite "macOS memory cap":
    test "advisory: over the cap is reported, nothing is killed":
      let done = capped([self, HoldArgument, "160", "600"], 64)
      check done.exited and done.exitCode == 0
      check done.capExceeded
      check not done.capKilled
      check done.memoryCapBytes == 64'u64 * MiB
      check done.memoryPeakSource == mpsPoll
      check done.memoryPeakBytes >= 160'u64 * MiB

    test "within the cap: no breach, and the peak is what was touched":
      let done = capped([self, HoldArgument, "48", "400"], 512)
      check done.exited and done.exitCode == 0
      check not done.capExceeded
      check done.memoryPeakBytes >= 48'u64 * MiB
      check done.memoryPeakBytes < 512'u64 * MiB

    test "the sum: two processes together over a cap neither reaches alone":
      let script = quoteShell(self) & " " & HoldArgument & " 56 800 & " &
        quoteShell(self) & " " & HoldArgument & " 56 800; wait"
      let done = capped(["/bin/sh", "-c", script], 96)
      check done.exited and done.exitCode == 0
      check done.capExceeded
      check done.memoryPeakBytes >= 112'u64 * MiB

    test "a spike between readings is caught by the high-water mark":
      # The spike is over in a few milliseconds; the process then lives on,
      # low, for several reading intervals, so a reading finds it alive. A
      # reading that lands during the touch sees part of it, so the full
      # 160 MiB is required of the peak (only the high-water mark has it),
      # and the round runs `SpikeRounds` times.
      let script = quoteShell(self) & " " & SpikeArgument & " 160 600; true"
      for _ in 0 ..< SpikeRounds:
        let done = capped(["/bin/sh", "-c", script], 96)
        check done.exited and done.exitCode == 0
        check done.capExceeded
        check done.memoryPeakBytes >= 160'u64 * MiB

    test "the root's own spike is read from its zombie":
      let (done, watch) = cappedWatch([self, SpikeArgument, "160", "0"], 96)
      check done.exited and done.exitCode == 0
      check watch.rootPeakRead
      check done.capExceeded
      check done.memoryPeakBytes >= 160'u64 * MiB

    test "no root's exit is lost between the zombie probe and the reap":
      # The launcher probes for its root's exit (`waitid` with `WNOWAIT`)
      # and then reaps it (`wait4`). A root that exits between the two was
      # reaped unread, and its peak was lost: about one launch in 30 on macOS 26.5.
      # A hundred short roots make that loss show in nearly every run of a
      # build that has it.
      var lost = 0
      for _ in 0 ..< ReapRaceLaunches:
        let (done, watch) = cappedWatch([self, SpikeArgument, "32", "0"], 0,
          measure = true)
        if not watch.rootPeakRead or done.memoryPeakBytes < 32'u64 * MiB:
          inc lost
      check lost == 0

    test "kill: the whole tree ends, a sibling tree is untouched":
      let pidfile = getTempDir() / ("rq-memcap-sleeper-" & $getpid())
      removeFile(pidfile)
      var sibling = launchProcess(commandSpec(["/bin/sh", "-c", "sleep 1"]))
      # The allocation waits for the sleeper's pid file, so the kill always
      # meets a sleeper that has said who it is.
      let script = quoteShell(self) & " " & SleepArgument & " " &
        quoteShell(pidfile) & " & while [ ! -f " & quoteShell(pidfile) &
        " ]; do sleep 0.01; done; " & quoteShell(self) & " " & HoldArgument &
        " 160 20000; wait"
      let done = capped(["/bin/sh", "-c", script], 64, mcaKill)
      check done.capExceeded
      check done.capKilled
      check done.signaled and done.signal == SIGKILL
      check fileExists(pidfile)
      if fileExists(pidfile):
        let sleeper = parseInt(readFile(pidfile).strip())
        check waitGone(sleeper)
        removeFile(pidfile)
      let siblingDone = sibling.waitForCompletion(timeout = 10_000)
      sibling.close()
      check siblingDone.exited and siblingDone.exitCode == 0

    test "kill: a process forking children out of its group loses none":
      # An escape needs a fork to land between the walk that finds a process
      # and the signal that stops it: a race. So the
      # round runs `StormRounds` times and any escape fails the case; with
      # the freeze nothing can escape (a stopped process cannot fork), so the
      # repetition makes the mutation's survival unlikely, not the case
      # flaky.
      var totalForked, totalSurvivors = 0
      for round in 0 ..< StormRounds:
        let dir = getTempDir() / ("rq-memcap-storm-" & $getpid() & "-" & $round)
        removeDir(dir)
        createDir(dir)
        # The storm and the allocation start together. The allocation takes
        # the tree over the cap within about 150 ms (the touch, then the next
        # reading), well inside the storm's ~300 ms of forking a child every
        # millisecond, so the kill meets a tree that is forking densely: a
        # walk of it then always misses a child forked while it ran, which
        # is what only the freeze can stop.
        let script = quoteShell(self) & " " & ForkStormArgument & " " &
          quoteShell(dir) & " & " & quoteShell(self) & " " &
          HoldArgument & " 160 20000; wait"
        try:
          let done = capped(["/bin/sh", "-c", script], 64, mcaKill)
          check done.capKilled
          for kind, path in walkDir(dir):
            if kind == pcFile and path.extractFilename != StormPidFile:
              inc totalForked
              if not waitGone(parseInt(path.extractFilename), 1.0):
                inc totalSurvivors
        finally:
          # WHATEVER THE OUTCOME, nothing of the storm outlives the round:
          # the storm first (so it forks no more), then every child it
          # recorded. These pids are this round's own processes, recorded
          # seconds ago by the processes themselves; a kill that finds one
          # gone does nothing.
          let stormPid = dir / StormPidFile
          if fileExists(stormPid):
            discard kill(Pid(parseInt(readFile(stormPid).strip())), SIGKILL)
          for kind, path in walkDir(dir):
            if kind == pcFile and path.extractFilename != StormPidFile:
              discard kill(Pid(parseInt(path.extractFilename)), SIGKILL)
          removeDir(dir)
      check totalForked > 0
      check totalSurvivors == 0

    test "tracker: a process re-parented away from the tree is still read":
      # A subshell starts the allocator and exits half a second later, so
      # the allocator is re-parented to launchd; only then, a second in, does
      # it touch 160 MiB. By ancestry it is no longer below the root, so
      # only a record of members kept by pid still reads it.
      let script = "(" & quoteShell(self) & " " & HoldLaterArgument &
        " 1000 160 1500 & sleep 0.5); sleep 3"
      let done = capped(["/bin/sh", "-c", script], 96)
      check done.exited and done.exitCode == 0
      check done.capExceeded
      check done.memoryPeakBytes >= 160'u64 * MiB

    test "tracker: readings of a tree that no longer forks list no children":
      # Eight sleepers, then nothing forks. Each reading after that must be
      # footprint reads only: the host-wide child listing is paid per fork,
      # not per member per reading.
      var script = ""
      for _ in 0 ..< 7:
        script.add("sleep 3 & ")
      script.add("sleep 3")
      var spec = commandSpec(["/bin/sh", "-c", script])
      spec.memoryCapBytes = 4096'u64 * MiB
      var child = launchProcess(spec)
      let deadline = epochTime() + 1.0
      while epochTime() < deadline:
        discard child.pollCompletion()
        sleep(10)
      let settledRelists = child.memoryCap.tracker.relists
      let settledReadings = child.memoryCap.tracker.readings
      let more = epochTime() + 1.0
      while epochTime() < more:
        discard child.pollCompletion()
        sleep(10)
      check child.memoryCap.tracker.readings >= settledReadings + 5
      check child.memoryCap.tracker.relists == settledRelists
      child.killNow()
      discard child.waitForCompletion(timeout = 5_000)
      child.close()

    test "kill: a tree in the launcher's own group does not stop the launcher":
      # A launch that makes no process group shares the launcher's. The kill
      # must then leave the group alone, or it stops the launcher with it.
      # The launcher here is a helper in a group of its own, so a launcher
      # that stops its group stops only the helper, which this case kills.
      var helper = launchProcess(commandSpec([self, SharedGroupArgument]))
      let done = helper.waitForCompletion(timeout = 20_000)
      if not done.exited:
        helper.killNow()
      helper.close()
      check done.exited and done.exitCode == 0

    test "kill: a breach seen only at the root's exit kills what is left":
      let pidfile = getTempDir() / ("rq-memcap-orphan-" & $getpid())
      removeFile(pidfile)
      let done = capped([self, OrphanSpikeArgument, pidfile, "160"], 96,
        mcaKill)
      check done.capExceeded
      check fileExists(pidfile)
      if fileExists(pidfile):
        let sleeper = parseInt(readFile(pidfile).strip())
        let gone = waitGone(sleeper, 3.0)
        check gone
        if not gone: discard kill(Pid(sleeper), SIGKILL)
        removeFile(pidfile)

    test "a tracker that cannot be armed reports the cap as not applied":
      var helper = launchProcess(commandSpec([self, NoDescriptorsArgument]))
      let done = helper.waitForCompletion(timeout = 20_000)
      helper.close()
      check done.exited and done.exitCode == 0
      if done.exitCode != 0: echo done.stderr

    test "no cap and no measurement: the tree is never read":
      let saved = getEnv("RUNQUOTA_MEASUREMENT")
      putEnv("RUNQUOTA_MEASUREMENT", "tree-sampling=off")
      defer: putEnv("RUNQUOTA_MEASUREMENT", saved)
      var spec = commandSpec([self, HoldArgument, "16", "400"])
      var child = launchProcess(spec)
      let done = child.waitForCompletion(timeout = 10_000)
      check not child.memoryCap.active
      check not child.info.memoryCapApplied
      check child.memoryCap.tracker.readings == 0'u32
      check not done.memoryCapMeasured
      check done.memoryPeakSource == mpsNone
      check not done.capExceeded
      child.close()

    test "measured without a cap: the peak, never a breach":
      let done = capped([self, HoldArgument, "48", "400"], 0, measure = true)
      check done.exited and done.exitCode == 0
      check not done.capExceeded
      check done.memoryCapBytes == 0'u64
      check done.memoryCapMeasured
      check done.memoryPeakSource == mpsPoll
      check done.memoryPeakBytes >= 48'u64 * MiB
else:
  echo "t_memory_cap_macos: the launcher-judged cap is macOS's; nothing to " &
    "test on this OS"
