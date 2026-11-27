## test_rqm_declared_growth_lifts_the_cap: `runquota expect-growth`, the
## persistent way to say a command's memory is expected to grow, through the
## real CLI against a private `runquotad`, and the run-lifted finish that is
## the one-run way.
##
## WHAT IS GUARDED.
##
## * `expect-growth <id> --to 8G` raises the next grant's cap to 8 GiB, basis
##   `declared`, and the figures it prints name the declaring uid (the peer
##   credentials of the CLI: this process's uid) and the largest successful
##   peak. A query changes nothing; `--json` prints the same figures.
## * The declaration is the COMMAND's, whichever launcher runs it: a session
##   of another name, with no learned row of its own, is granted it too.
## * `--reset` removes it: the next cap is the learned 2 × M again.
## * A successful finish of a run whose cap was lifted
##   (`RUNQUOTA_MEMORY_CAP=off`, basis `run-lifted`, cap 0, measured in its
##   leaf) raises M, and the next cap follows the new maximum.
## * A command with no row takes a declaration-only row, and its cap is the
##   declaration clamped to the budget.
## * The declaration survives a daemon restart (it is persisted with the
##   row).
## * Refusals: a size below 1 MiB, a malformed size, `--to` with `--reset`,
##   and an over-long command id are refused by the CLI with exit 2, and the
##   daemon refuses a request below the floor that reaches it.
##
## Falsifying mutations: the daemon ignoring the declaration (D taken as 0
## in the cap) turns the first and second cases red; the daemon refusing to
## learn M from a `run-lifted` block turns the lifted case red. The
## launcher half of `RUNQUOTA_MEMORY_CAP` is `t_rqm_launcher_policy`.
##
## No mocks: the built `runquotad` and `runquota`, a real estimate store.

when defined(posix):
  import std/[json, os, posix, strutils, unittest]

  import runquota_client
  import runquota_core
  import runquota_protocol
  import rqm_daemon

  proc grantOf(session: var RunQuotaSession; key: string;
               memoryBytes = 1'u64 * GiB): RunQuotaLease =
    session.requestLease(request(key, memoryBytes))

  proc capOf(session: var RunQuotaSession; key: string): GrantMemoryCap =
    var lease = session.grantOf(key)
    result = lease.memoryCap
    lease.release()

  suite "test_rqm_declared_growth_lifts_the_cap":
    test "a declaration raises the cap, a reset removes it, a lifted run raises M":
      let daemon = startRqmDaemon("rqmgrow")
      defer: daemon.stop()
      var client = connectDefault()
      defer: client.close()
      var session = client.registerSession(SessionName, "0")
      var first = session.grantOf("grow")
      first.finishWith(succeeded(), peakBytes = 1'u64 * GiB,
        capBlock = measured(first.memoryCap.capBytes, 1'u64 * GiB,
          first.memoryCap.basis))
      check session.capOf("grow").capBytes == 2'u64 * GiB

      let declared = daemon.rqmCli(["expect-growth", "grow", "--to", "8G"])
      checkpoint(declared.output)
      check declared.code == 0
      check "declared cap: 8.0 GiB, declared by uid " & $getuid() & " at " in
        declared.output
      check "largest successful peak: 1.0 GiB" in declared.output
      let cap = session.capOf("grow")
      check cap.basis == mcbDeclared
      check cap.capBytes == 8'u64 * GiB
      check cap.previousMaxBytes == 1'u64 * GiB

      # The command's, whichever launcher asks.
      var otherSession = client.registerSession("another-launcher", "0")
      let other = otherSession.capOf("grow")
      check other.basis == mcbDeclared
      check other.capBytes == 8'u64 * GiB
      otherSession.closeSession()

      # A query changes nothing, and says the same in JSON.
      let queried = daemon.rqmCli(["expect-growth", "grow", "--json"])
      check queried.code == 0
      let figures = parseJson(queried.output)
      check figures["declared_cap_bytes"].getBiggestInt() == int64(8'u64 * GiB)
      check figures["declared_by_uid"].getBiggestInt() == int64(getuid())
      check figures["max_observed_peak_bytes"].getBiggestInt() ==
        int64(1'u64 * GiB)
      check figures["factor_milli"].getInt() == 2000
      let stamp = figures["declared_unix_millis"].getBiggestInt()
      check stamp > 0
      let again = parseJson(daemon.rqmCli(["expect-growth", "grow",
        "--json"]).output)
      check again["declared_unix_millis"].getBiggestInt() == stamp
      check session.capOf("grow").capBytes == 8'u64 * GiB

      let reset = daemon.rqmCli(["expect-growth", "grow", "--reset"])
      check reset.code == 0
      check "declared cap: none" in reset.output
      let learned = session.capOf("grow")
      check learned.basis == mcbLearned
      check learned.capBytes == 2'u64 * GiB

      # RUNQUOTA_MEMORY_CAP=off for one run: the cap is lifted, the tree is
      # measured, it succeeds at 3 GiB, and the next cap follows it.
      var lifted = session.grantOf("grow")
      lifted.finishWith(succeeded(), peakBytes = 3'u64 * GiB,
        capBlock = measured(0'u64, 3'u64 * GiB, mcbRunLifted))
      check client.learnedRow("grow").figure("max_observed_peak_bytes") ==
        3'u64 * GiB
      let followed = session.capOf("grow")
      check followed.basis == mcbLearned
      check followed.capBytes == 6'u64 * GiB
      session.closeSession()

    test "a command with no row, the budget, and a restart":
      let daemon = startRqmDaemon("rqmfresh")
      var stopped = false
      defer:
        if not stopped: daemon.stop()
      block:
        var client = connectDefault()
        defer: client.close()
        var session = client.registerSession(SessionName, "0")
        check daemon.rqmCli(["expect-growth", "fresh", "--to", "2G"]).code == 0
        let fresh = session.capOf("fresh")
        check fresh.basis == mcbDeclared
        check fresh.capBytes == 2'u64 * GiB
        check fresh.previousMaxBytes == 0'u64
        check daemon.rqmCli(["expect-growth", "huge", "--to", "64G"]).code == 0
        let huge = session.capOf("huge")
        check huge.basis == mcbDeclared
        check huge.capBytes == BudgetBytes
        session.closeSession()
      # The declaration is persisted with the row.
      daemon.halt()
      stopped = true
      let restarted = startRqmDaemon("", root = daemon.root)
      defer: restarted.stop()
      let shown = restarted.rqmCli(["expect-growth", "fresh"])
      checkpoint(shown.output)
      check shown.code == 0
      check "declared cap: 2.0 GiB, declared by uid " & $getuid() in
        shown.output
      var client = connectDefault()
      defer: client.close()
      var session = client.registerSession(SessionName, "0")
      check session.capOf("fresh").capBytes == 2'u64 * GiB
      session.closeSession()

    test "refusals":
      let daemon = startRqmDaemon("rqmref")
      defer: daemon.stop()
      for args in [@["expect-growth", "k", "--to", "512K"],
                   @["expect-growth", "k", "--to", "1.5G"],
                   @["expect-growth", "k", "--to", "8G", "--reset"],
                   @["expect-growth", "k", "--to"],
                   @["expect-growth"],
                   @["expect-growth", "a", "b"],
                   @["expect-growth", repeat('x', MaxCommandStatsIdBytes + 1),
                     "--to", "8G"]]:
        checkpoint(args.join(" "))
        let answer = daemon.rqmCli(args)
        checkpoint(answer.output)
        check answer.code == 2
      # The daemon is the authority over what is recorded: a request that
      # reaches it below the floor, or with an over-long id, is refused.
      var client = connectDefault()
      defer: client.close()
      expect RunQuotaClientError:
        discard client.expectGrowth("k", egSet, 1000'u64)
      check "at least" in client.lastDiagnostic.message
      expect RunQuotaClientError:
        discard client.expectGrowth(repeat('y', MaxCommandStatsIdBytes + 1),
          egSet, 8'u64 * GiB)
      # And a query of a command it knows nothing about says so.
      let unknown = daemon.rqmCli(["expect-growth", "never-seen"])
      check unknown.code == 0
      check "no memory figures are recorded" in unknown.output
