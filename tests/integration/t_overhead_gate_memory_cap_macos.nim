## The overhead gate's memory-cap switch on macOS: one comparison, no cap
## against a 1 GiB cap in kill mode, and a configuration check that refuses
## to run when the ON arm's launches apply no cap.
##
## WHAT IS GUARDED, each with the change that makes it fail:
##
## * The pairing (`memoryCapArms` with `macos`): plain `memory-cap` is no
##   cap against the gate's cap, whose arm must show `mclTracked`; a stage
##   is a usage error on macOS. Mutation: giving macOS the Linux pairing
##   (its ON arm then expects `mclLimits`, which no macOS launch shows).
## * The probe's classifier (`memoryCapProbeLevelMacos`), from `runquota
##   run --verbose`'s statement of the cap it applied, its breach report and
##   the exit status. Mutations: accepting a killed probe without the CLI's
##   breach report (a probe killed for any other reason would then pass as a
##   cap); classifying the OFF arm by survival alone (an OFF arm that a host
##   file caps, which the probe survives, would then pass as uncapped).
## * The probe's own stats key (`memoryCapProbeArgv`). Mutation: dropping
##   `--stats-key`. The probe then shares the rounds' key, and the OFF arm's
##   surviving probe teaches its daemon a learned figure that throttles
##   that arm's rounds.
## * The gate's own `run64Case`: its probes pass its check, and one round of
##   each arm runs. Mutations: the arms' environments for the rounds and the
##   probe diverging (the check sees one, the rounds run the other); the
##   macOS placement path of the case breaking.
## * THE CONFIGURATION CHECK, WITH REAL LAUNCHES through the real `runquota`
##   CLI and a real private `runquotad`: the OFF arm's probe survives its
##   1.25 GiB, the ON arm's is killed for it and reported, and an ON arm
##   whose cap is left out is refused as vacuous. Mutations: the arm
##   environment leaving the cap out (the ON arm shows `mclNone`); a
##   launcher that never kills (the ON arm shows `mclUnknown`).
## * The warning (`dyldInsertWarning`) the gate prints when its own
##   environment sets `DYLD_INSERT_LIBRARIES`. Mutation: ignoring it.
##
## NO MOCKS: the real CLI and daemon (`daemon_binary`), real memory touched by
## the probe. macOS only: elsewhere the cap is a cgroup or a Job Object, with
## tests of their own.

when defined(macosx):
  import std/[json, os, strutils, tempfiles, unittest]

  import runquota_core
  import daemon_binary

  import ../../benchmarks/lib/runquota_overhead_gate as gate

  suite "the overhead gate's memory-cap switch on macOS":
    test "one comparison: no cap against the gate's cap, read by the launcher":
      let arms = memoryCapArms("memory-cap", macos = true)
      check arms[armOff].cap == "" and arms[armOff].level == mclNone
      check arms[armOn].cap == GateMemoryCap
      check arms[armOn].level == mclTracked
      for stage in ["controller", "leaf", "limits", "classify"]:
        expect ValueError:
          discard memoryCapArms("memory-cap:" & stage, macos = true)

    test "the probe's classifier reads the cap the CLI says it applied":
      let off = "runquota run: memory cap none: memory cap off (the host " &
        "file's [enforcement] memoryCap is off or absent)\nsurvived\n"
      check memoryCapProbeLevelMacos(off, 0) == mclNone
      let on = "runquota run: memory cap 1073741824 bytes (mcbRunSize, " &
        "mcaKill)\nrunquota: memory cap exceeded: /bin/sh -c perl -e " &
        "'... print \"survived\\n\"' (command id x)\n" &
        "  cap 1.0 GiB = RUNQUOTA_MEMORY_CAP for this run; peak 1.1 GiB; " &
        "killed\n"
      check memoryCapProbeLevelMacos(on, 137) == mclTracked
      # An OFF arm that is in fact capped (a host file that turns the cap
      # on gives it the grant's cap): the probe survives, and must not pass
      # for an arm with no cap.
      let trackedOff = "runquota run: memory cap 8589934592 bytes " &
        "(mcbBudget, mcaKill)\nsurvived\n"
      check memoryCapProbeLevelMacos(trackedOff, 0) == mclUnknown
      # Killed with no breach report, or at another cap: not the gate's.
      # Killed by something other than the cap, whose own message says so
      # ("killed"), with no breach report from the CLI: not the cap's kill.
      check memoryCapProbeLevelMacos(
        "runquota run: memory cap 1073741824 bytes (mcbRunSize, mcaKill)\n" &
        "perl: killed by signal 9 (from another process)\n",
        137) == mclUnknown
      check memoryCapProbeLevelMacos(on.replace("1073741824", "2147483648"),
        137) == mclUnknown
      # Advisory at the gate's cap: reported, not killed.
      check memoryCapProbeLevelMacos(on.replace("mcaKill", "mcaAdvisory"),
        137) == mclUnknown

    test "the probe has a stats key of its own, never the rounds'":
      # The rounds' actions are `sh` run in the arm's work directory, keyed
      # `run/sh@<dir>`. A probe under that key would teach the OFF arm's
      # daemon its 1.25 GiB, which admission would then charge to every
      # action of every round.
      let argv = memoryCapProbeArgv("/x/runquota", memoryCapProbeScriptMacos)
      let at = argv.find("--stats-key")
      check at >= 0 and at + 1 < argv.len
      if at >= 0 and at + 1 < argv.len:
        check argv[at + 1] == MemoryCapProbeStatsKey
        check not argv[at + 1].startsWith("run/sh@")
      check "--verbose" in argv
      check argv.find("--stats-key") < argv.find("--")

    test "the gate warns when DYLD_INSERT_LIBRARIES is set":
      check dyldInsertWarning(["PATH=/bin"]) == ""
      check "DYLD_INSERT_LIBRARIES" in
        dyldInsertWarning(["DYLD_INSERT_LIBRARIES=/x/shim.dylib"])

    test "test_rqm_overhead_gate_memory_cap (macOS): real launches pass the check, a vacuous ON arm is refused":
      let scratch = createTempDir("rqgmcm", "")
      defer: removeDir(scratch)
      var cfg = parseGateArgs(["--case=run-64", "--switch=memory-cap"])
      cfg.daemonBin = daemonPath()
      cfg.cliBin = cliPath()
      let arms = memoryCapArms("memory-cap", macos = true)
      var observed: array[Arm, MemoryCapLevel]
      for arm in Arm:
        let switches = armSwitchText(cfg, arm)
        let dir = scratch / $arm
        createDir(dir)
        let daemon = gate.startDaemon(cfg, dir, arm, switches)
        defer: stopDaemon(daemon)
        let probed = probeMemoryCapLevel(cfg.cliBin, runEnv(daemon.socketPath,
          switches, "off", memoryCap = arms[arm]), dir)
        checkpoint $arm & " probe output: " & probed.output
        observed[arm] = probed.level
        if arm == armOn:
          # The same arm with its cap left out: the vacuous configuration.
          var leftOut = arms[armOn]
          leftOut.cap = ""
          let vacuous = probeMemoryCapLevel(cfg.cliBin,
            runEnv(daemon.socketPath, switches, "off", memoryCap = leftOut),
            dir)
          check vacuous.level == mclNone
          check "vacuous" in memoryCapConfigProblem(arms,
            [observed[armOff], vacuous.level])
      check observed[armOff] == mclNone
      check observed[armOn] == mclTracked
      check memoryCapConfigProblem(arms, observed) == ""

    test "the gate's own run-64 case passes its check, and both arms run a round":
      # `run64Case` itself, not a copy of its steps: the arms' environments
      # as the rounds get them, the probes, the check, one round of each.
      let scratch = createTempDir("rqgmcr", "")
      defer: removeDir(scratch)
      var cfg = parseGateArgs(["--case=run-64", "--switch=memory-cap"])
      cfg.daemonBin = daemonPath()
      cfg.cliBin = cliPath()
      let gateCase = run64Case(cfg, scratch)
      defer: gateCase.stop()
      let details = gateCase.details["memory_cap"]
      check details["observed_level"]["off"].getStr == $mclNone
      check details["observed_level"]["on"].getStr == $mclTracked
      for arm in Arm:
        let cost = gateCase.run(arm, 0)
        check cost.exitStatus == 0
else:
  echo "t_overhead_gate_memory_cap_macos: the macOS arm of the memory-cap " &
    "switch; nothing to test on this OS"
