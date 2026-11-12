## `runquotad --idle-exit-after N`: a daemon that ends itself once no client
## connection has been open for N seconds.
##
## WHY THIS EXISTS. On a host with no provisioned RunQuota service, `repro`
## used to start a PRIVATE daemon per invocation, so two concurrent builds each
## admitted against the whole budget. It now starts ONE daemon per user, on a
## well-known endpoint, which every later invocation adopts -- and which must
## therefore end by itself when nobody uses it (reprobuild-pm
## `spec/RunQuota-Host-Configuration.md`, "The shared per-user daemon (POSIX)",
## "The idle period"). The clauses, each observed from outside:
##
## * a daemon with the flag and no client exits 0 once the period has passed,
##   not before it; its socket is gone afterwards (the orderly shutdown freed
##   the endpoint) and its lifetime lock is free;
## * a held connection keeps it alive well past the period, and it exits a
##   period after that connection closes -- the period is counted from the
##   moment the last connection ended, not from start-up;
## * a period that is not a positive integer is a usage error (exit 2).
##
## Remove the watcher and the first two cases fail on the exit budget; count
## the period from start-up instead of from the last close and the second one
## fails (the daemon exits under the held connection); skip the "endpoint
## first" order and the first one still passes -- that order is the
## retirement decision's, tested by `t_daemon_retirement`.
##
## A PRIVATE DAEMON, ALWAYS: an explicit `--socket` in a scratch `0700`
## directory under `RUNQUOTA_ENDPOINT_SCOPE=private`
## (`tests/support/private_daemon_fixture`). Nothing here touches the real
## per-user endpoint or any daemon this test did not start.
##
## NO MOCKS. The built `runquotad`, a real socket and the real client library.
## POSIX only: the per-user daemon is the POSIX row of the specification.

when defined(posix):
  import std/[monotimes, os, osproc, strutils, times, unittest]

  import runquota_client
  import runquota_ipc
  import private_daemon_fixture

  const
    PeriodSeconds = 2
    ExitBudgetMillis = 60_000
      ## The clause is "it exits", not "it exits fast": the orderly shutdown
      ## joins a worker pool, and the hosts this runs on are often loaded.

  proc setClientPolicy(): tuple[had: bool, value: string] =
    ## The in-process client reads its endpoint policy from the environment,
    ## exactly as `repro`'s does. Returns what to put back.
    result = (existsEnv("RUNQUOTA_ENDPOINT_SCOPE"),
      getEnv("RUNQUOTA_ENDPOINT_SCOPE"))
    putEnv("RUNQUOTA_ENDPOINT_SCOPE", "private")

  proc restoreClientPolicy(saved: tuple[had: bool, value: string]) =
    if saved.had: putEnv("RUNQUOTA_ENDPOINT_SCOPE", saved.value)
    else: delEnv("RUNQUOTA_ENDPOINT_SCOPE")

  suite "idle exit":
    test "an idle daemon exits 0 after the period and frees its socket and lock":
      let root = scratchDir("rqidle")
      defer: removeDir(root)
      let socket = root / "ep" / "d.sock"
      let started = getMonoTime()
      let daemon = launch(root, socket, privateEnv(socket),
        ["--idle-exit-after", $PeriodSeconds])
      defer: stopOwned(daemon)
      prerequisite awaitSocket(daemon, socket),
        daemon.startupContext("the daemon did not bind " & socket)
      # Alive and holding its lifetime lock while it waits out the period.
      check lockState(lockPathOf(socket)) == lockHeld
      let code = daemon.exitWithin(ExitBudgetMillis)
      let elapsed = getMonoTime() - started
      let log = daemon.output
      checkpoint "daemon output:\n" & log
      check code == 0
      # Not before the period: it is counted from start-up, and start-up
      # began after `started`.
      check elapsed >= initDuration(seconds = PeriodSeconds)
      check "runquotad: idle exit: no client connection for " &
        $PeriodSeconds & " s" in log
      # The orderly shutdown freed the endpoint and the kernel released the
      # lock with the process.
      check not pathExists(socket)
      check lockState(lockPathOf(socket)) == lockFree

    test "a held connection keeps it alive; it exits a period after the close":
      let root = scratchDir("rqhold")
      defer: removeDir(root)
      let socket = root / "ep" / "d.sock"
      let daemon = launch(root, socket, privateEnv(socket),
        ["--idle-exit-after", $PeriodSeconds])
      defer: stopOwned(daemon)
      prerequisite awaitSocket(daemon, socket),
        daemon.startupContext("the daemon did not bind " & socket)
      let saved = setClientPolicy()
      defer: restoreClientPolicy(saved)
      var client = connect(endpointForPath(socket))
      # Two and a half periods with a connection open.
      sleep(PeriodSeconds * 2500)
      check daemon.running
      # And it still answers on that connection.
      let status = client.daemonStatus(timeoutMs = 30_000)
      check status.activeLeases == 0'u32
      client.close()
      let closedAt = getMonoTime()
      let code = daemon.exitWithin(ExitBudgetMillis)
      let sinceClose = getMonoTime() - closedAt
      let log = daemon.output
      checkpoint "daemon output:\n" & log
      check code == 0
      # The daemon counts the connection out after the client closed it, so
      # its period cannot have ended before one period after `closedAt`.
      check sinceClose >= initDuration(seconds = PeriodSeconds)
      check "idle exit" in log
      check not pathExists(socket)
      check lockState(lockPathOf(socket)) == lockFree

    test "a period that is not a positive integer is a usage error":
      let root = scratchDir("rqbad")
      defer: removeDir(root)
      let socket = root / "ep" / "d.sock"
      for bad in [@["--idle-exit-after", "0"], @["--idle-exit-after", "-5"],
                  @["--idle-exit-after", "ten"], @["--idle-exit-after", "1.5"],
                  @["--idle-exit-after"]]:
        let daemon = launch(root, socket, privateEnv(socket), bad)
        defer: stopOwned(daemon)
        let code = daemon.exitWithin(ExitBudgetMillis)
        let log = daemon.output
        checkpoint bad.join(" ") & " -> " & $code & "\n" & log
        check code == 2
        check "--idle-exit-after" in log
        check not pathExists(socket)
else:
  echo "t_idle_exit: POSIX only (the per-user daemon is the POSIX row)"
