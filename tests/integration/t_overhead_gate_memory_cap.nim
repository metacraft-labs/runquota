## `test_rqm_overhead_gate_memory_cap`: the overhead gate's memory-cap switch
## compares arms that differ by exactly one stage of the cap, and refuses to
## run when its ON arm's launches apply no cap.
##
## WHAT IS GUARDED, each with the change that makes it fail:
##
## * The pairing (`memoryCapArms`): `memory-cap` is the whole mechanism
##   against none of it; `memory-cap:<stage>` is that stage against the
##   stage before it, so each comparison adds exactly one stage, and an
##   unknown stage is a usage error. Mutation: pairing a stage against
##   the bottom arm (two stages at once) fails the one-step property.
## * The argument parsing: `--switch=memory-cap[:STAGE]` reaches the
##   configuration as given.
## * The probe (`memoryCapProbeLevel`): the level a tree's own cgroup shows
##   (none, controller, leaf, limits), from the probe script's output.
## * THE CONFIGURATION CHECK PASSES ONLY ARMS THAT REALLY APPLY THEIR
##   STAGE, AND REFUSES A VACUOUS ON ARM, with real launches: for every
##   switch, each arm's environment, exactly as the gate builds it
##   (`memoryCapArms`), is resolved into a launch, the gate's probe script
##   runs in that launch's real cgroup, and `memoryCapConfigProblem` must
##   accept what it saw. An arm whose cap is left out must be refused.
##   Mutations: the switch leaving the ON arm's cap out (every switch's
##   real launch then shows a lower level, and the check that must accept
##   fails); a check that accepts any level (the vacuous arm is accepted).
## * The bottom arm through the REAL `runquota` CLI and a real private
##   `runquotad`: with `RUNQUOTA_MEMORY_CAP` unset its tree has no memory
##   cap at all. Mutation: an environment that leaks a cap into the bottom
##   arm (the probe then shows one).
##
## THE ONE STAND-IN: `resolveArm`. Turning `RUNQUOTA_MEMORY_CAP` and the
## host file's mode into a launch's cap is the launching client's resolver,
## which is not in this tree yet. The test resolves each arm with the
## client's documented rule (unset: the host mode, off on a gate host;
## `off`: cap 0, measured only when the host mode is not off; a size: that
## cap, in kill mode when the host leaves the cap off; `advisory` / `kill`:
## the mode) and launches through the real `runquota_process` launcher.
## Once the resolver lands, the real-CLI case below covers every arm.
##
## * The report's spawn path (`memoryCapSpawnPath`): `clone3` for a capped
##   arm at the `limits` stage or later, `fork` below it or when
##   `LD_PRELOAD` is set in the launchers' environment, and the warning
##   (`ldPreloadWarning`) the gate prints when its own environment sets it.
##   Mutation: ignoring the environment.
##
## NO MOCKS: the real CLI and daemon (`daemon_binary`), the real cgroups of
## a test-owned root (`cgroup_test_root`). Linux only: the cap is a cgroup.

when defined(linux):
  import std/[os, strutils, tempfiles, unittest]

  import runquota_core
  import runquota_process
  import cgroup_test_root
  import daemon_binary

  import ../../benchmarks/lib/runquota_overhead_gate as gate

  suite "the overhead gate's memory-cap switch":
    test "each comparison adds exactly one stage":
      let order = [mclNone, mclController, mclLeaf, mclLimits]
      proc rank(level: MemoryCapLevel): int = order.find(level)
      let whole = memoryCapArms("memory-cap")
      check whole[armOff].cap == "" and whole[armOff].level == mclNone
      check whole[armOn].cap == GateMemoryCap
      check whole[armOn].stage == ""
      check whole[armOn].level == mclLimits
      var previous = "off"
      for stage in ["controller", "leaf", "limits", "classify"]:
        let arms = memoryCapArms("memory-cap:" & stage)
        check arms[armOn].stage == stage
        check arms[armOn].cap == GateMemoryCap
        # The OFF arm is the stage before: unset for the first stage.
        if previous == "off":
          check arms[armOff].cap == ""
          check arms[armOff].stage == ""
        else:
          check arms[armOff].cap == GateMemoryCap
          check arms[armOff].stage == previous
        # One visible step, except classify, whose reads at the end are
        # invisible from inside the tree.
        if stage == "classify":
          check arms[armOff].level == arms[armOn].level
        else:
          check rank(arms[armOn].level) == rank(arms[armOff].level) + 1
        previous = stage
      for bad in ["memory-cap:", "memory-cap:none", "memory-capx",
                  "memory-cap:limits:x"]:
        expect ValueError:
          discard memoryCapArms(bad)

    test "the switch is parsed as given":
      let cfg = parseGateArgs(["--case=run-64", "--switch=memory-cap:leaf"])
      check cfg.switch == "memory-cap:leaf"
      check isMemoryCapSwitch(cfg.switch)
      check isMemoryCapSwitch("memory-cap")
      check not isMemoryCapSwitch("cgroups")

    test "the probe's levels":
      const capped = "cgroup=/u/r/group-x/cap-1-2\nmemory=1\nmax=1073741824\n" &
        "oomgroup=1\n"
      check memoryCapProbeLevel(capped, GateMemoryCapBytes) == mclLimits
      check memoryCapProbeLevel(capped, 2 * GateMemoryCapBytes) == mclUnknown
      check memoryCapProbeLevel("cgroup=/u/r/group-x/cap-1-2\nmemory=1\n" &
        "max=max\noomgroup=1\n", GateMemoryCapBytes) == mclLeaf
      check memoryCapProbeLevel("cgroup=/u/r/group-x/shared\nmemory=1\n" &
        "max=max\noomgroup=0\n", GateMemoryCapBytes) == mclController
      check memoryCapProbeLevel("cgroup=/u/r/group-x/shared\nmemory=0\n",
        GateMemoryCapBytes) == mclNone
      check memoryCapProbeLevel("", GateMemoryCapBytes) == mclUnknown

    test "the check refuses an arm that is not at its level":
      let arms = memoryCapArms("memory-cap")
      check memoryCapConfigProblem(arms, [mclNone, mclLimits]) == ""
      let vacuous = memoryCapConfigProblem(arms, [mclNone, mclNone])
      check "on arm" in vacuous
      check "vacuous" in vacuous
      check memoryCapConfigProblem(arms, [mclLimits, mclLimits]).len > 0
      check memoryCapConfigProblem(memoryCapArms("memory-cap:leaf"),
        [mclController, mclController]).len > 0

    test "the report names the spawn path, and LD_PRELOAD is warned about":
      # The launcher creates a capped tree with clone3 from the `limits`
      # stage on, unless LD_PRELOAD is set in ITS environment, which the
      # gate's clients inherit from the gate. Mutation: ignoring the
      # environment (every limits arm then reads clone3).
      let whole = memoryCapArms("memory-cap")
      let preload = @["PATH=/bin", "LD_PRELOAD=/x/shim.so"]
      let clean = @["PATH=/bin", "LD_PRELOAD="]
      check memoryCapSpawnPath(whole[armOn], clean) == "clone3"
      check memoryCapSpawnPath(whole[armOn], preload) == "fork"
      check memoryCapSpawnPath(whole[armOff], clean) == "uncapped"
      let leafArms = memoryCapArms("memory-cap:leaf")
      check memoryCapSpawnPath(leafArms[armOn], clean) == "fork"
      check memoryCapSpawnPath(leafArms[armOff], clean) == "fork"
      check memoryCapSpawnPath(memoryCapArms("memory-cap:controller")[armOff],
        clean) == "uncapped"
      check memoryCapSpawnPath(memoryCapArms("memory-cap:classify")[armOff],
        preload) == "fork"
      check ldPreloadWarning(clean) == ""
      let warning = ldPreloadWarning(preload)
      check "LD_PRELOAD" in warning
      check "/x/shim.so" in warning
      check "fork" in warning

    var reason = ""
    let root = delegatedMemoryTestRoot(reason)

    proc parseSize(text: string): uint64 =
      ## A size with an optional binary suffix (K, M, G, T).
      let unit = text[^1]
      let digits = if unit in {'K', 'M', 'G', 'T'}: text[0 ..< ^1] else: text
      let shift = case unit
        of 'K': 10
        of 'M': 20
        of 'G': 30
        of 'T': 40
        else: 0
      uint64(parseBiggestUInt(digits)) shl shift

    proc resolveArm(arm: MemoryCapArm; spec: var CommandSpec) =
      ## The launching client's rule for `RUNQUOTA_MEMORY_CAP`, with the
      ## host file's mode off (the stand-in; see the header).
      case arm.cap
      of "", "off", "advisory", "kill":
        discard               # host mode off: no cap, nothing measured
      else:
        spec.memoryCapBytes = parseSize(arm.cap)
        spec.memoryCapAction = mcaKill

    proc launchedLevel(arm: MemoryCapArm; root, group: string):
        MemoryCapLevel =
      ## The level the gate's probe sees in a real launch of `arm`.
      var spec = commandSpec(["/bin/sh", "-c", memoryCapProbeScript])
      spec.cgroup = targetFor(CgroupRoot(state: crsExplicit, path: root),
        group, sessionPriorityNormal, reclaimed = false)
      resolveArm(arm, spec)
      if arm.stage.len > 0:
        putEnv(MemoryCapStageEnvVar, arm.stage)
      else:
        delEnv(MemoryCapStageEnvVar)
      defer: delEnv(MemoryCapStageEnvVar)
      var child = launchProcess(spec)
      let completion = child.waitForCompletion(30_000)
      child.close()
      memoryCapProbeLevel(completion.stdout, GateMemoryCapBytes)

    test "test_rqm_overhead_gate_memory_cap: real launches pass the check, a vacuous ON arm is refused":
      if root.len == 0:
        echo "SKIPPED: " & reason
        skip()
      else:
        for switch in ["memory-cap", "memory-cap:controller",
                       "memory-cap:leaf", "memory-cap:limits",
                       "memory-cap:classify"]:
          let arms = memoryCapArms(switch)
          var observed: array[Arm, MemoryCapLevel]
          for arm in Arm:
            observed[arm] = launchedLevel(arms[arm], root,
              switch.replace(":", "-") & "-" & $arm)
          checkpoint switch & ": off " & $observed[armOff] & ", on " &
            $observed[armOn]
          check memoryCapConfigProblem(arms, observed) == ""
        # The vacuous ON arm: the cap left out, the stage still asked for.
        let arms = memoryCapArms("memory-cap")
        var leftOut = arms[armOn]
        leftOut.cap = ""
        let vacuous = launchedLevel(leftOut, root, "vacuous")
        check vacuous == mclNone
        check "vacuous" in memoryCapConfigProblem(arms, [mclNone, vacuous])

    test "the bottom arm through the real CLI and daemon has no memory cap":
      if root.len == 0:
        echo "SKIPPED: " & reason
        skip()
      else:
        let scratch = createTempDir("rqgmc", "")
        defer: removeDir(scratch)
        var cfg = parseGateArgs(["--case=run-64", "--switch=memory-cap"])
        cfg.daemonBin = daemonPath()
        cfg.cliBin = cliPath()
        let switches = armSwitchText(cfg, armOff)
        let daemon = gate.startDaemon(cfg, scratch, armOff, switches)
        defer: stopDaemon(daemon)
        let arms = memoryCapArms("memory-cap")
        let probed = probeMemoryCapLevel(cfg.cliBin, runEnv(daemon.socketPath,
          switches, root, memoryCap = arms[armOff]), scratch)
        checkpoint "probe output: " & probed.output
        check probed.level == mclNone
        # The real ON arm, reported for the record: it shows the full cap
        # only once the launching client resolves the variable.
        let real = probeMemoryCapLevel(cfg.cliBin, runEnv(daemon.socketPath,
          switches, root, memoryCap = arms[armOn]), scratch)
        echo "  the ON arm through the real CLI shows '" & $real.level & "'"

    test "the test root is left empty":
      if root.len > 0:
        check removeTestRoot(root) == ""
