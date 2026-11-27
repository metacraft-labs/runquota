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
##   "off" (two stages at once) fails the one-step property.
## * The argument parsing: `--switch=memory-cap[:STAGE]` reaches the
##   configuration as given.
## * The probe (`memoryCapProbeLevel`): the level a tree's own cgroup shows
##   (none, controller, leaf, limits), from the probe script's output.
## * THE CONFIGURATION CHECK REFUSES A VACUOUS ON ARM, with real processes:
##   the probe runs through the real `runquota` CLI against a real private
##   `runquotad`, in a test-owned cgroup root, with the ON arm's cap turned
##   off (`RUNQUOTA_MEMORY_CAP=off`: the switch leaving the cap off, the
##   spec's mutation for this test). Its launch shows no cap, and
##   `memoryCapConfigProblem` must refuse the run rather than let the gate
##   compare two identical arms. Mutation: a check that accepts any level
##   (or only looks at the OFF arm) passes the vacuous arm here.
##
## * The report's spawn path (`memoryCapSpawnPath`): `clone3` for a capped
##   arm at the `limits` stage or later, `fork` below it or when
##   `LD_PRELOAD` is set in the launchers' environment, and the warning
##   (`ldPreloadWarning`) the gate prints when its own environment sets it.
##   Mutation: ignoring the environment.
##
## WHAT IS NOT YET RUN: the gate end to end with the cap ON. Turning
## `RUNQUOTA_MEMORY_CAP=1G` into a launch's cap is the launching client's
## resolver, which this tree does not have yet; until it does, the real ON
## arm shows no cap and the gate refuses, which is the behaviour asserted
## above. The case below that probes the real ON arm reports what it saw
## and asserts the check's answer for it either way.
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
      check whole[armOff].cap == "off" and whole[armOff].level == mclNone
      check whole[armOn].cap == GateMemoryCap
      check whole[armOn].stage == ""
      check whole[armOn].level == mclLimits
      var previous = "off"
      for stage in ["controller", "leaf", "limits", "classify"]:
        let arms = memoryCapArms("memory-cap:" & stage)
        check arms[armOn].stage == stage
        check arms[armOn].cap == GateMemoryCap
        # The OFF arm is the stage before: "off" for the first stage.
        if previous == "off":
          check arms[armOff].cap == "off"
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

    test "test_rqm_overhead_gate_memory_cap: a vacuous ON arm is refused (real CLI and daemon)":
      if root.len == 0:
        echo "SKIPPED: " & reason
        skip()
      else:
        let scratch = createTempDir("rqgmc", "")
        defer: removeDir(scratch)
        var cfg = parseGateArgs(["--case=run-64", "--switch=memory-cap"])
        cfg.daemonBin = daemonPath()
        cfg.cliBin = cliPath()
        let switches = armSwitchText(cfg, armOn)
        let daemon = gate.startDaemon(cfg, scratch, armOn, switches)
        defer: stopDaemon(daemon)
        let arms = memoryCapArms("memory-cap")
        # THE MUTATION: the ON arm's cap left off.
        var leftOff = arms[armOn]
        leftOff.cap = "off"
        let probed = probeMemoryCapLevel(cfg.cliBin, runEnv(daemon.socketPath,
          switches, root, memoryCap = leftOff), scratch)
        checkpoint "probe output: " & probed.output
        check probed.level == mclNone
        let problem = memoryCapConfigProblem(arms, [mclNone, probed.level])
        check "vacuous" in problem
        # The real ON arm, as configured. Until the launching client
        # resolves the variable into a cap it shows no cap and is refused
        # in the same way; once it does, it must show the full cap and
        # pass the check.
        let real = probeMemoryCapLevel(cfg.cliBin, runEnv(daemon.socketPath,
          switches, root, memoryCap = arms[armOn]), scratch)
        echo "the ON arm as configured shows '" & $real.level & "'"
        let realProblem = memoryCapConfigProblem(arms, [mclNone, real.level])
        if real.level == mclLimits:
          check realProblem == ""
        else:
          check realProblem.len > 0
        check removeTestRoot(root) == ""
