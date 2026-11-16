## The CPU pressure gate corrects admission on Windows, end to end: a real
## `runquotad` on a named pipe reads synthetic pressure from a file
## (`--cpu-pressure-file`, in `/proc/pressure/cpu`'s format) and stops widening
## a resizable lease while the reading is high, resuming when it falls.
##
## WHY THIS CASE, and not the reclaimed-admission case the Linux leg leads
## with. The gate governs two things: admitting reclaimed work into predicted
## free CPU, and WIDENING resizable leases. The first needs a learned CPU
## shape to predict free capacity beyond the ledger, and shapes are learned
## only where the launcher can profile a tree (Linux `/proc`, macOS libproc) --
## not on Windows, where `profiles` is inert, so no reclaimed grant into a tail
## is reachable here. The widening arm needs no shape: it applies whether or
## not `admission.predictive` is on (§ Measured command shape). It is the
## shape-independent half of the SAME gate, reading the SAME
## `--cpu-pressure-file` injection this leg makes work on Windows, so it is the
## faithful Windows analog of the Linux pressure case. The reclaimed/weight
## half is covered by `t_windows_reclaimed_priority` (the lower weight the
## launcher applies) and `t_cpu_pressure_windows` (the reader) instead.
##
## WHAT IS GUARDED, with the change that breaks it:
##   * with pressure low a resizable lease widens into freed slots (the
##     control, so the case is not vacuously green);
##   * with pressure above `admission.pressure-high` it does NOT widen, a
##     reading between the thresholds keeps it so (hysteresis), and one below
##     `admission.pressure-low` lets the next pass widen it. Reverting the
##     Windows `readCpuPressure` file-override (so the synthetic file is never
##     read) leaves the gate open throughout and the "high" check fails;
##     widening without consulting the gate (`allowsWidening`) fails it too.
##
## NO MOCKS: the built `runquotad`, a real named pipe, the real client
## library. The one substitution is the CPU pressure signal, held where the
## case needs it -- the host's own is neither controllable nor repeatable. The
## native PDH reader is exercised by `t_cpu_pressure_windows`.

when defined(windows):
  import std/[json, os, osproc, strutils, unittest]

  import runquota_client
  import runquota_core
  import runquota_ipc
  import daemon_binary
  import windows_daemon_fixture

  const
    GiB = 1024'u64 * 1024'u64 * 1024'u64
    BudgetMilli = 8000

  type Fixture = object
    daemon: Daemon
    root: string

  proc writePressure(root: string; pct: float64) =
    ## The CPU pressure the daemon reads, written whole and renamed into place
    ## so it never reads half a file.
    let path = root / "psi"
    writeFile(path & ".tmp", "some avg10=" & formatFloat(pct, ffDecimal, 2) &
      " avg60=0.00 avg300=0.00 total=0\n" &
      "full avg10=0.00 avg60=0.00 avg300=0.00 total=0\n")
    moveFile(path & ".tmp", path)

  proc startFixture(): Fixture =
    result.root = scratchDir("rqwidthwin")
    writePressure(result.root, 0.0)
    result.daemon.root = result.root
    result.daemon.pipe = uniquePipe()
    result.daemon.env = hostEnv(result.daemon.pipe)
    let args = daemonArgs(result.daemon.root, result.daemon.pipe,
      ["--cpu-milli", $BudgetMilli, "--memory-bytes", $(64'u64 * GiB),
       "--cpu-pressure-file", result.root / "psi"])
    result.daemon.process = startProcess(daemonPath(),
      env = result.daemon.env, args = args, options = {poStdErrToStdOut})
    prerequisite awaitDaemon(result.daemon),
      "the private daemon did not serve " & result.daemon.pipe

  proc fixed(session: var RunQuotaSession; cpuMilli: uint32): RunQuotaLease =
    session.requestLease(resourceRequest("fixed", milliCpu(cpuMilli),
      bytes(GiB)))

  proc ranged(minMilli, prefMilli: uint32): ResourceRequest =
    resourceRequest("ranged", milliCpu(prefMilli), bytes(GiB)).withWidthRange(
      milliCpu(minMilli), milliCpu(prefMilli), resizable = true)

  proc targetOf(daemon: Daemon; lease: RunQuotaLease): int =
    let leases = parseJson(runq(daemon.env, ["leases", "--json"]).output)
    for row in leases["leases"]:
      if row["id"].getBiggestInt() == BiggestInt(lease.id.value):
        return row["width"]["target_milli"].getInt()
    -1

  proc gateClosed(daemon: Daemon): bool =
    let status = parseJson(runq(daemon.env, ["status", "--json"]).output.strip()
      .splitLines()[^1])
    status["admission_prediction"]["cpu_pressure"]["gate_closed"].getBool()

  suite "windows negotiated widths pressure gate":

    test "widening stops while CPU pressure is high and resumes when it falls":
      var fixture = startFixture()
      defer:
        fixture.daemon.stop()
        try: removeDir(fixture.root) except CatchableError: discard
      putEnv("RUNQUOTA_SOCKET", fixture.daemon.pipe)
      delEnv("RUNQUOTA_SESSION")
      delEnv("RUNQUOTA_SESSION_PRIORITY")
      var client = connect(namedPipeEndpoint(fixture.daemon.pipe), "widths")
      defer: client.close()
      var neighbourSession = client.registerSession("neighbour", "1")
      var session = client.registerSession("jobserver", "1")

      # THE CONTROL: pressure low, widening works. A resizable lease granted
      # its minimum (2) while a neighbour holds 6; the neighbour's release
      # widens it to 8 in the release's own pass.
      block:
        var neighbour = neighbourSession.fixed(6000)
        var lease = session.requestLease(ranged(2000, 8000))
        check lease.resources.cpu.value == 2000'u32
        check fixture.daemon.targetOf(lease) == 2000
        neighbour.release()
        check fixture.daemon.targetOf(lease) == 8000
        let answer = lease.reportResized(milliCpu(2000))
        check answer.cpuTargetMilli == 8000'u32
        lease.release()

      # THE SUBJECT: pressure above high, no widening.
      writePressure(fixture.root, 50.0)
      # The gate is read at most every 500 ms: let a fresh reading be due.
      sleep(600)
      var neighbour = neighbourSession.fixed(6000)
      var lease = session.requestLease(ranged(2000, 8000))
      check lease.resources.cpu.value == 2000'u32
      neighbour.release()
      # Free slots, nothing waiting -- and pressure above high: no widening.
      check fixture.daemon.targetOf(lease) == 2000
      var answer = lease.reportResized(milliCpu(2000))
      check answer.cpuTargetMilli == 2000'u32
      check fixture.daemon.gateClosed()

      # Between the thresholds (default 5..10): still closed.
      writePressure(fixture.root, 7.0)
      sleep(600)
      discard neighbourSession.pollNextGrant()
      check fixture.daemon.targetOf(lease) == 2000
      check fixture.daemon.gateClosed()

      # Below low: the next pass widens it.
      writePressure(fixture.root, 1.0)
      sleep(600)
      discard neighbourSession.pollNextGrant()
      check fixture.daemon.targetOf(lease) == 8000
      answer = lease.reportResized(milliCpu(2000))
      check answer.cpuTargetMilli == 8000'u32
      check not fixture.daemon.gateClosed()

      lease.release()
      neighbourSession.closeSession()
      session.closeSession()
else:
  echo "t_negotiated_widths_windows: Windows only"
