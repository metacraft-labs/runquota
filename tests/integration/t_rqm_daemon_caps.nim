## The daemon's half of the per-task memory cap, end to end over the real
## protocol: the cap each grant carries, and what each kind of finish teaches
## the command's learned row.
##
## WHAT IS GUARDED, one case per rule, each with the mutation that turns it
## red (recorded in the commit that adds this file):
##
## * test_rqm_learned_cap_is_factor_times_max: with a largest successful
##   peak M recorded, the next grant's cap is ⌈f × M⌉, basis `learned`, with
##   f from the host file's `[enforcement] memoryCapFactor` (2.5 here, then
##   1.5 after a reload); a factor below 1.5 makes the file not parse, so the
##   reload is refused and the cap keeps the factor in force. Mutation: use
##   the conservative figure instead of M (the cap then follows the 1.25 ×
##   admission figure, not M).
## * test_rqm_cap_exceeded_does_not_learn: after a cap-exceeded finish -- and
##   after an advisory breach of a successful one -- the conservative figure
##   and M are unchanged, and the breach (cap, peak, time) and the outcome
##   are recorded. Mutation: apply the old doubling to a cap-exceeded finish.
## * test_rqm_outside_oom_raises_admission_only: an `lfOomKilled` finish
##   raises the conservative figure to 2 × max(peak, the lease's memory) and
##   leaves M alone, even with a measured block. Mutation: fold the peak into
##   M.
## * test_rqm_only_measured_success_raises_max: a success with no block (only
##   `ru_maxrss` and sampling), and a failure with a block, leave M at 0; a
##   success with a block raises it. Mutation: feed M from `ru_maxrss`.
## * test_rqm_first_run_cap_is_the_free_budget: a command with no row,
##   granted while another lease holds H, gets cap B − H, basis `budget`; a
##   breach of it raises the conservative figure and leaves M at 0, and its
##   report says "not a regression". Mutation: cap the first run at the
##   reservation.
## * A sub-lease carries no cap of its own (it runs inside its parent's).
##
## The finishes are sent by the ordinary client library with chosen figures
## (`tests/support/rqm_daemon.nim` says why that is a real client). No mocks.

when defined(posix):
  import std/[options, os, strutils, unittest]

  import runquota_client
  import runquota_core
  import runquota_exec
  import runquota_protocol
  import runquota_daemon/host_config
  import rqm_daemon

  proc grantOf(session: var RunQuotaSession; key: string;
               memoryBytes = 1'u64 * GiB): RunQuotaLease =
    session.requestLease(request(key, memoryBytes))

  proc establishMax(session: var RunQuotaSession; key: string;
                    peakBytes: uint64) =
    ## A first, successful, measured run of `key` with tree peak `peakBytes`.
    var lease = session.grantOf(key)
    lease.finishWith(succeeded(), peakBytes = peakBytes,
      capBlock = measured(lease.memoryCap.capBytes, peakBytes,
        lease.memoryCap.basis))

  suite "the memory cap a grant carries":
    test "test_rqm_learned_cap_is_factor_times_max":
      let daemon = startRqmDaemon("rqmfac", factor = "2.5")
      defer: daemon.stop()
      var client = connectDefault()
      defer: client.close()
      check client.supportsMemoryCap()
      var session = client.registerSession(SessionName, "0")
      # An odd peak, so the ceiling is visible: 2.5 × M ends in .5.
      let peak = 1_000_000_007'u64
      session.establishMax("learned", peak)
      let row = client.learnedRow("learned")
      check row.figure("max_observed_peak_bytes") == peak
      # The admission figure is 1.25 × the peak: a cap computed from it
      # would be 2.5 × 1.25 × M, which is what the mutation produces.
      check row.figure("conservative_memory_bytes") > peak
      var next = session.grantOf("learned")
      check next.memoryCap.known
      check next.memoryCap.basis == mcbLearned
      check next.memoryCap.capBytes == 2_500_000_018'u64 # ⌈2.5 × M⌉
      check next.memoryCap.previousMaxBytes == peak
      check next.memoryCap.factorMilli == 2_500'u32
      check next.memoryCap.budgetBytes == BudgetBytes
      next.release()

      # The factor follows the host file on a reload.
      writeFile(daemon.root / "host.toml", hostFileText("1.5"))
      discard client.reloadHostConfig()
      var reloaded = session.grantOf("learned")
      check reloaded.memoryCap.capBytes == 1_500_000_011'u64 # ⌈1.5 × M⌉
      check reloaded.memoryCap.factorMilli == 1_500'u32
      reloaded.release()

      # Below the floor the file does not parse: the reload is refused and
      # the factor in force stays.
      writeFile(daemon.root / "host.toml", hostFileText("1.4"))
      var refused = false
      try:
        discard client.reloadHostConfig()
      except RunQuotaClientError:
        refused = true
      check refused
      var kept = session.grantOf("learned")
      check kept.memoryCap.factorMilli == 1_500'u32
      kept.release()
      # The same refusal from the reader itself, with the words it gives,
      # and the other shapes a factor may not take.
      for bad in ["1.4", "1", "\"2\"", "two", "2.0001", "-2"]:
        checkpoint("memoryCapFactor = " & bad)
        expect HostConfigError:
          discard parseHostConfig(hostFileText(bad), "host.toml")
      check parseHostConfig(hostFileText("1.5"),
        "host.toml").memoryCapFactorMilli.get == 1_500'u32
      check parseHostConfig(hostFileText("2"),
        "host.toml").memoryCapFactorMilli.get == 2_000'u32
      let floorMessage =
        try:
          discard parseHostConfig(hostFileText("1.4"), "host.toml")
          ""
        except HostConfigError as error:
          error.msg
      check "at least 1.5" in floorMessage
      session.closeSession()

    test "test_rqm_first_run_cap_is_the_free_budget":
      let daemon = startRqmDaemon("rqmbud")
      defer: daemon.stop()
      var client = connectDefault()
      defer: client.close()
      var session = client.registerSession(SessionName, "0")
      # H: another command's lease, granted and held (6 GiB of 16).
      var other = session.grantOf("other", 6'u64 * GiB)
      check other.memoryCap.basis == mcbBudget
      check other.memoryCap.capBytes == BudgetBytes # nothing else held yet
      # A command with no row: its cap is B − H, not its 1 GiB reservation.
      var first = session.grantOf("first-run", 1'u64 * GiB)
      check first.memoryCap.known
      check first.memoryCap.basis == mcbBudget
      check first.memoryCap.capBytes == BudgetBytes - 6'u64 * GiB
      check first.memoryCap.previousMaxBytes == 0'u64
      check first.memoryCap.budgetBytes == BudgetBytes
      let cap = first.memoryCap
      # It breaches its budget cap and is killed: the host was short.
      let breach = measured(cap.capBytes, cap.capBytes, mcbBudget)
      first.finishWith(capExceeded(killedBySignal(9'u32)),
        peakBytes = cap.capBytes, capBlock = breach)
      let row = client.learnedRow("first-run")
      check row.figure("max_observed_peak_bytes") == 0'u64
      # 2 × max(the peak, the lease's memory): the next run waits for room.
      check row.figure("conservative_memory_bytes") == 2'u64 * cap.capBytes
      check row.figure("last_breach_cap_bytes") == cap.capBytes
      check row.figure("last_breach_peak_bytes") == cap.capBytes
      check row.figure("last_breach_unix_millis") > 0'u64
      check row.figure("last_outcome") == uint64(ord(lfCapExceeded))
      # And the report says what it was, and that it is not a regression.
      let report = memoryCapReport("make big", "first-run", cap, breach,
        killed = true)
      checkpoint(report)
      check "stopped at the memory free when it started: make big " &
        "(command id first-run)" in report
      check "cap 10.0 GiB = the host budget 16.0 GiB minus 6.0 GiB granted " &
        "to other work;" in report
      check "This is not a regression." in report
      check "memory regression" notin report
      other.release()
      session.closeSession()

    test "a sub-lease carries no cap of its own":
      let daemon = startRqmDaemon("rqmsub")
      defer: daemon.stop()
      var client = connectDefault()
      defer: client.close()
      var session = client.registerSession(SessionName, "0")
      var parent = session.grantOf("parent", 4'u64 * GiB)
      check parent.memoryCap.known
      parent.markStarting()
      parent.markRunning(childProcessId = uint64(getCurrentProcessId()))
      var child = session.requestSubLeaseWaiting(parent.id, "child", "child",
        milliCpu(500), milliCpu(500), bytes(1'u64 * GiB))
      check child.active
      check not child.memoryCap.known
      child.release()
      parent.release()
      session.closeSession()

  suite "what a finish teaches the learned row":
    test "test_rqm_cap_exceeded_does_not_learn":
      let daemon = startRqmDaemon("rqmexc")
      defer: daemon.stop()
      var client = connectDefault()
      defer: client.close()
      var session = client.registerSession(SessionName, "0")
      session.establishMax("regress", 1'u64 * GiB)
      let before = client.learnedRow("regress")
      let conservative = before.figure("conservative_memory_bytes")
      check before.figure("max_observed_peak_bytes") == 1'u64 * GiB
      var lease = session.grantOf("regress")
      check lease.memoryCap.basis == mcbLearned
      check lease.memoryCap.capBytes == 2'u64 * GiB
      # Killed past its cap: a regression is reported, never learned.
      let peak = 2'u64 * GiB + 64'u64 * MiB
      lease.finishWith(capExceeded(killedBySignal(9'u32)), peakBytes = peak,
        capBlock = measured(2'u64 * GiB, peak, mcbLearned))
      let after = client.learnedRow("regress")
      check after.figure("conservative_memory_bytes") == conservative
      check after.figure("max_observed_peak_bytes") == 1'u64 * GiB
      check after.figure("last_outcome") == uint64(ord(lfCapExceeded))
      check after.figure("last_breach_cap_bytes") == 2'u64 * GiB
      check after.figure("last_breach_peak_bytes") == peak
      check after.figure("last_breach_unix_millis") > 0'u64
      # The next cap is still 2 × the old maximum.
      var again = session.grantOf("regress")
      check again.memoryCap.capBytes == 2'u64 * GiB
      # A success that passed its cap in advisory mode teaches nothing either.
      again.finishWith(succeeded(), peakBytes = 3'u64 * GiB,
        capBlock = measured(2'u64 * GiB, 3'u64 * GiB, mcbLearned,
          exceededAdvisory = true))
      let advisory = client.learnedRow("regress")
      check advisory.figure("conservative_memory_bytes") == conservative
      check advisory.figure("max_observed_peak_bytes") == 1'u64 * GiB
      check advisory.figure("last_breach_peak_bytes") == 3'u64 * GiB
      session.closeSession()

    test "test_rqm_outside_oom_raises_admission_only":
      let daemon = startRqmDaemon("rqmoom")
      defer: daemon.stop()
      var client = connectDefault()
      defer: client.close()
      var session = client.registerSession(SessionName, "0")
      session.establishMax("host-oom", 1'u64 * GiB)
      var lease = session.grantOf("host-oom", 1'u64 * GiB)
      # Killed for memory from outside its cap (a host-wide OOM), with the
      # tree measured in its leaf at 1.5 GiB.
      let peak = 1'u64 * GiB + 512'u64 * MiB
      lease.finishWith(oomKilled(killedBySignal(9'u32)), peakBytes = peak,
        capBlock = measured(2'u64 * GiB, peak, mcbLearned))
      let row = client.learnedRow("host-oom")
      check row.figure("conservative_memory_bytes") == 2'u64 * peak
      check row.figure("max_observed_peak_bytes") == 1'u64 * GiB
      check row.figure("last_breach_unix_millis") == 0'u64
      session.closeSession()

    test "test_rqm_only_measured_success_raises_max":
      let daemon = startRqmDaemon("rqmmax")
      defer: daemon.stop()
      var client = connectDefault()
      defer: client.close()
      var session = client.registerSession(SessionName, "0")
      # A success measured only by sampling and `ru_maxrss`: admission
      # learns, the cap's maximum does not.
      var unmeasured = session.grantOf("measured")
      unmeasured.finishWith(succeeded(), peakBytes = 3'u64 * GiB,
        maxRssBytes = 3'u64 * GiB)
      var row = client.learnedRow("measured")
      check row.figure("conservative_memory_bytes") >= 3'u64 * GiB
      check row.figure("max_observed_peak_bytes") == 0'u64
      # A failure with a block is not a measurement of what success needs.
      var failing = session.grantOf("measured")
      failing.finishWith(failed(1'u32), peakBytes = 4'u64 * GiB,
        capBlock = measured(failing.memoryCap.capBytes, 4'u64 * GiB,
          failing.memoryCap.basis))
      row = client.learnedRow("measured")
      check row.figure("max_observed_peak_bytes") == 0'u64
      # A measured success raises it, to the block's peak.
      var success = session.grantOf("measured")
      success.finishWith(succeeded(), peakBytes = 512'u64 * MiB,
        maxRssBytes = 512'u64 * MiB,
        capBlock = measured(success.memoryCap.capBytes, 1'u64 * GiB,
          success.memoryCap.basis))
      row = client.learnedRow("measured")
      check row.figure("max_observed_peak_bytes") == 1'u64 * GiB
      # And a smaller measured success never lowers it.
      var smaller = session.grantOf("measured")
      smaller.finishWith(succeeded(), peakBytes = 256'u64 * MiB,
        capBlock = measured(smaller.memoryCap.capBytes, 256'u64 * MiB,
          smaller.memoryCap.basis))
      row = client.learnedRow("measured")
      check row.figure("max_observed_peak_bytes") == 1'u64 * GiB
      session.closeSession()
