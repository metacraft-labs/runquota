## A LEASE WHOSE OWNER WAS KILLED MUST COME BACK TO A CLIENT THAT IS WAITING
## FOR IT -- and must not come back while the work it pays for still runs.
##
## No mocks. A real `runquotad` from `build/bin` on a private endpoint, real
## supervisor processes killed abruptly by pid, and a waiting client that
## asks the way reprobuild asks: `OfferCandidates` once, then `GrantNext`
## polls until it is granted.
##
## THE DEFECT THIS EXISTS FOR, reproduced on a Windows host before it was
## repaired. Two builds were killed mid-execution; their leases went to
## `supervisor_lost` and pinned 1.5 GiB and 6.6 GiB of a 16 GiB budget for a
## day, and a `repro exec` then queued behind them indefinitely. The daemon's
## lost-lease reaper existed, but it ran only inside the `RequestLease`
## handler, and a waiting client never sends one -- so the host reported
## `lost_leases_reaped: 0` for its whole lifetime. The same shape, driven
## here, left the waiter below queued for as long as anyone cared to wait.
##
## WHY THE WAITER POLLS RATHER THAN CALLING `requestLeaseWaiting`. A timeout
## there leaves the queued lease in the daemon and says nothing about what
## happened meanwhile; the explicit loop lets the first case assert BOTH
## directions against one queued request: held while the orphan runs,
## granted once it is gone.
##
## Each case writes its own log (its timeline and the daemon's output)
## under `test-logs/t_e2e_runquota_killed_owner_lease_reclaimed/`, and names
## it only when the case fails.

import std/[envvars, json, os, osproc, streams, strtabs, strutils, times,
  unittest]

when defined(windows):
  import std/winlean
else:
  import std/posix

import runquota_client
import runquota_core
import runquota_protocol
from runquota_ipc import endpointForPath
# The daemon's own identity probe, used here only to make CLEANUP safe: a
# child is killed by pid only while that pid still names the child.
import runquota_daemon/child_identity
import daemon_binary
import daemon_endpoint
import scratch_root

const
  MiB = 1024'u64 * 1024'u64
  BudgetBytes = 1024'u64 * MiB
    ## The private daemon's whole memory budget.
  HolderBytes = 768'u64 * MiB
    ## What the killed owner holds: enough that the waiter cannot fit
    ## beside it, so the waiter's grant is evidence of the reservation
    ## coming back and of nothing else.
  WaiterBytes = 512'u64 * MiB
  HelperModeEnv = "RUNQUOTA_E2E_KILLED_OWNER_MODE"
  SleeperFlag = "--sleeper-seconds"
  GrantBoundMillis = 10_000
    ## How long a waiter may take to be granted once the owner's child is
    ## gone. The reaper runs on the waiter's very next poll, so this is
    ## margin for a loaded CI host; before the fix no bound was enough.

# ---------------------------------------------------------------------------
# Re-executed roles. The test binary is its own holder and its own child, so
# the scenario needs no tool that differs between platforms.
# ---------------------------------------------------------------------------

let argv = commandLineParams()
if argv.len == 2 and argv[0] == SleeperFlag:
  # A child that does nothing, silently. Writing nothing matters: a child
  # blocked on a full pipe whose reader was killed would die of the write,
  # not of anything this test is about.
  sleep(parseInt(argv[1]) * 1000)
  quit 0

proc runHolder(readyPath, childPidPath: string): int =
  ## A supervisor that takes the lease, launches a child that will OUTLIVE
  ## it (plain `startProcess`: no kill-on-close job, no process-group kill),
  ## reports it running, and then waits to be killed.
  var child = startProcess(getAppFilename(), args = [SleeperFlag, "600"],
    options = {})
  writeFile(childPidPath, $child.processID)
  var client = connectDefault()
  var session = client.registerSession("e2e-killed-owner", "0.1.0")
  var lease = session.requestLease(resourceRequest("killed-owner",
    milliCpu(1000), bytes(HolderBytes)))
  lease.markStarting()
  lease.markRunning(childProcessId = uint64(child.processID))
  writeFile(readyPath, "ready")
  while true:
    sleep(1000)

let helperMode = getEnv(HelperModeEnv)
if helperMode == "holder":
  if argv.len != 2:
    quit 2
  quit runHolder(argv[0], argv[1])
elif helperMode.len > 0:
  quit 2

# ---------------------------------------------------------------------------
# Per-case log
# ---------------------------------------------------------------------------

type CaseLog = object
  path: string
  started: float

proc openCaseLog(name: string): CaseLog =
  let dir = getCurrentDir() / "test-logs" /
    "t_e2e_runquota_killed_owner_lease_reclaimed"
  createDir(dir)
  result = CaseLog(path: dir / (name & ".log"), started: epochTime())
  writeFile(result.path, "")

proc note(log: CaseLog; message: string) =
  let f = open(log.path, fmAppend)
  defer: f.close()
  f.writeLine(formatFloat(epochTime() - log.started, ffDecimal, 3) & "s " &
    message)

proc reportOnFailure(log: CaseLog; failed: bool) =
  if failed:
    echo "    case log: " & log.path & " (" & $getFileSize(log.path) &
      " bytes)"

# ---------------------------------------------------------------------------
# The private daemon
# ---------------------------------------------------------------------------

type PrivateDaemon = object
  root: string
  socketPath: string
  process: Process

proc scratchRoot(tag: string): string =
  # SHORT ON PURPOSE on POSIX, where `sun_path` is ~104 bytes; Windows maps
  # `--socket` onto a named pipe (`endpointForPath`) and has no such limit.
  let base =
    when defined(windows): getTempDir()
    else: "/tmp"
  result = base / ("rq-ko-" & tag & "-" & $getCurrentProcessId())
  removeDir(result)
  createDir(result)
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})

proc childEnv(socketPath: string): StringTableRef =
  ## The environment every process this test starts runs with. The socket is
  ## set EXPLICITLY on each one: a child that fell back to the default
  ## endpoint would be talking to the host's real daemon.
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    result[key] = value
  result["RUNQUOTA_SOCKET"] = socketPath

proc startPrivateDaemon(tag: string; log: CaseLog): PrivateDaemon =
  result.root = scratchRoot(tag)
  result.socketPath = result.root / "d.sock"
  # Every piece of host state in the scratch directory, and an explicit
  # budget: the daemon reads the host budget file at start, and a flag is
  # what overrides it. No observation capture and no pressure source, so
  # admission is decided by the ledger alone.
  let args = @["--socket", result.socketPath,
    "--host-identity-file", result.root / "host-id",
    "--estimate-db", result.root / "estimates.db",
    "--no-write-stats",
    "--memory-pressure-source", "unavailable",
    "--cpu-milli", "4000",
    "--memory-bytes", $BudgetBytes]
  log.note("daemon: " & daemonPath() & " " & args.join(" "))
  result.process = startProcess(daemonPath(), args = args,
    options = {poStdErrToStdOut})
  for _ in 0 ..< 400:
    if endpointIsBound(result.socketPath): break
    sleep(25)
  doAssert endpointIsBound(result.socketPath),
    "private runquotad did not bind " & result.socketPath

proc stop(daemon: var PrivateDaemon; log: CaseLog) =
  if daemon.process.running:
    daemon.process.terminate()
    discard daemon.process.waitForExit(5000)
  if daemon.process.running:
    daemon.process.kill()
    discard daemon.process.waitForExit(5000)
  # Only now, with the daemon gone and its end of the pipe closed, is its
  # output bounded -- read it whole into the case log.
  try:
    log.note("daemon output:\n" & daemon.process.outputStream.readAll())
  except CatchableError as error:
    log.note("daemon output unreadable: " & error.msg)
  daemon.process.close()
  removeScratchRoot(daemon.root)

proc connectTo(daemon: PrivateDaemon): RunQuotaClient =
  connect(endpointForPath(daemon.socketPath))

proc inspect(daemon: PrivateDaemon; subject: string): JsonNode =
  var client = daemon.connectTo()
  defer: client.close()
  parseJson(client.inspectionJson(subject))

proc status(daemon: PrivateDaemon): DaemonStatusMessage =
  var client = daemon.connectTo()
  defer: client.close()
  client.daemonStatus()

proc lostLeasesReaped(daemon: PrivateDaemon): int =
  daemon.inspect("observations")["observations"]["lost_leases_reaped"].getInt

proc waitFor(log: CaseLog; what: string; budgetMillis: int;
             condition: proc (): bool): bool =
  let deadline = epochTime() + budgetMillis / 1000
  while epochTime() < deadline:
    if condition():
      log.note("reached: " & what)
      return true
    sleep(25)
  log.note("NOT reached within " & $budgetMillis & " ms: " & what)
  false

# ---------------------------------------------------------------------------
# Processes this test started, killed by pid and by nothing broader
# ---------------------------------------------------------------------------

proc killPid(pid: int) =
  ## Abrupt, like the OOM killer or a closed terminal: no chance to send
  ## `LeaseFinished`. Only ever called on a pid this test itself launched,
  ## and -- through `killChild` -- only while it still names that process.
  when defined(windows):
    const ProcessTerminate = 0x0001'i32
    let handle = openProcess(ProcessTerminate, WINBOOL(0), DWORD(pid))
    if handle != Handle(0):
      discard terminateProcess(handle, 1)
      discard closeHandle(handle)
  else:
    discard kill(Pid(pid), SIGKILL)

type ChildRef = object
  pid: int
  stamp: uint64   ## as the daemon recorded it at LeaseRunning

proc killChild(child: var ChildRef) =
  ## Kills the lease's child if -- and only if -- its pid still names it.
  ## After a test has let the child exit, the same pid may already belong to
  ## an unrelated process, and killing THAT is what this refuses to do.
  if child.pid != 0 and child.stamp != 0'u64 and
      childVerdict(uint64(child.pid), child.stamp) == cvAlive:
    killPid(child.pid)
  child.pid = 0

proc killAbruptly(process: Process) =
  when defined(windows):
    process.terminate()     # TerminateProcess: no cleanup runs
  else:
    discard kill(Pid(process.processID), SIGKILL)
  discard process.waitForExit(5000)

proc must(condition: bool; what: string) =
  ## `check`, and then stop the case. Unlike `require` it leaves by an
  ## exception, so the `finally` that kills this case's processes and stops
  ## its daemon still runs.
  check condition
  if not condition:
    raise newException(CatchableError, "precondition failed: " & what)

proc waitForFile(path: string; budgetMillis = 10_000): bool =
  var waited = 0
  while waited < budgetMillis:
    if fileExists(path) and readFile(path).len > 0:
      return true
    sleep(25)
    waited += 25
  false

# ---------------------------------------------------------------------------
# The waiting client, shaped like reprobuild's
# ---------------------------------------------------------------------------

type Waiter = object
  client: RunQuotaClient
  session: RunQuotaSession
  candidateId: uint64
  lease: RunQuotaLease
  granted: bool

proc offerWaiter(daemon: PrivateDaemon; log: CaseLog): Waiter =
  result.client = daemon.connectTo()
  result.session = result.client.registerSession("e2e-waiter", "0.1.0")
  result.candidateId = 1'u64
  let decisions = result.session.offerCandidates([toCandidate(
    result.candidateId, resourceRequest("waiter", milliCpu(1000),
      bytes(WaiterBytes)))])
  for decision in decisions:
    if decision.clientCandidateId == result.candidateId and
        decision.lease.active and not decision.queued:
      result.granted = true
      result.lease = decision.lease
  log.note("waiter offered; granted immediately: " & $result.granted)

proc pollForGrant(waiter: var Waiter; log: CaseLog;
                  budgetMillis: int): bool =
  ## `GrantNext` polls -- and nothing else -- until the candidate is granted
  ## or the budget runs out.
  if waiter.granted:
    return true
  let deadline = epochTime() + budgetMillis / 1000
  var polls = 0
  while epochTime() < deadline:
    inc polls
    for grant in waiter.session.pollNextGrant():
      if grant.clientCandidateId == waiter.candidateId and not grant.queued:
        waiter.granted = true
        waiter.lease = grant.lease
        log.note("waiter granted after " & $polls & " GrantNext polls")
        return true
    sleep(50)
  log.note("waiter still queued after " & $polls & " GrantNext polls")
  false

proc finish(waiter: var Waiter) =
  if waiter.granted and waiter.lease.active:
    waiter.lease.release()
  try:
    waiter.session.closeSession()
  except CatchableError:
    discard
  waiter.client.close()

proc leaseRow(daemon: PrivateDaemon; label: string): JsonNode =
  for row in daemon.inspect("leases")["leases"]:
    if row["label"].getStr == label:
      return row
  newJNull()

# ---------------------------------------------------------------------------

suite "e2e_runquota_killed_owner_lease_reclaimed":

  test "a killed owner's lease is held while its child runs, then reclaimed for a waiting client":
    let log = openCaseLog("held-then-reclaimed")
    var daemon = startPrivateDaemon("held", log)
    var holder: Process = nil
    var child = ChildRef()
    try:
      let readyPath = daemon.root / "holder.ready"
      let childPidPath = daemon.root / "child.pid"
      var env = childEnv(daemon.socketPath)
      env[HelperModeEnv] = "holder"
      # PARENT STREAMS, NOT A PIPE. The holder's child inherits the holder's
      # standard handles, so a pipe read here would not see end-of-file
      # until the CHILD exited -- after the holder is killed, that is a read
      # that outlives the case. The holder prints nothing when it works.
      holder = startProcess(getAppFilename(), args = [readyPath, childPidPath],
        env = env, options = {poParentStreams})
      must(waitForFile(readyPath), "holder reported ready")
      let childPid = parseInt(readFile(childPidPath).strip())
      log.note("holder pid " & $holder.processID & ", child pid " & $childPid)

      # The daemon read the child's identity itself at LeaseRunning.
      let running = daemon.leaseRow("killed-owner")
      check running["state"].getStr == "running"
      check running["child_process_id"].getInt == childPid
      child = ChildRef(pid: childPid,
        stamp: uint64(running["child_start_stamp"].getBiggestInt))
      check child.stamp != 0'u64
      # The same identity this process reads for that pid: what the daemon
      # recorded is the child, not a guess.
      check processStartStamp(uint64(childPid)) == child.stamp

      # KILL THE OWNER. Its child keeps running.
      holder.killAbruptly()
      check not holder.running
      log.note("holder killed")
      check waitFor(log, "lease supervisor_lost", 5000, proc (): bool =
        daemon.status().supervisorLostLeases == 1'u32)

      # HELD: the child is alive, so the reservation must not be handed to
      # the waiter, however often it asks.
      var waiter = offerWaiter(daemon, log)
      try:
        check not waiter.granted
        check not waiter.pollForGrant(log, 1500)
        check daemon.leaseRow("killed-owner")["state"].getStr ==
          "supervisor_lost"
        check daemon.lostLeasesReaped() == 0

        # RECLAIMED: the child goes, and the waiter -- which sends nothing
        # but GrantNext -- is granted.
        child.killChild()
        log.note("child killed")
        check waiter.pollForGrant(log, GrantBoundMillis)
        check daemon.leaseRow("killed-owner").kind == JNull
        check daemon.lostLeasesReaped() == 1
        let final = daemon.status()
        check final.supervisorLostLeases == 0'u32
        # Never mistaken for a completion.
        check final.totalFinished == 0'u64
      finally:
        waiter.finish()
    finally:
      child.killChild()
      if holder != nil:
        if holder.running:
          holder.killAbruptly()
        holder.close()
      daemon.stop(log)
      log.reportOnFailure(testStatusIMPL == TestStatus.FAILED)

  test "a killed `runquota acquire` releases its reservation to a waiting client":
    # THE HOST SCENARIO END TO END, through the shipped CLI and the shipped
    # launcher. On Windows the launcher binds the child to a kill-on-close
    # job, so killing the CLI kills the child with it and the reservation is
    # already dead weight when the waiter arrives; elsewhere the child is in
    # its own process group, survives the CLI, and ends on its own a few
    # seconds later. Either way the waiter must be granted inside the bound,
    # and before the fix it never was.
    let log = openCaseLog("killed-cli")
    var daemon = startPrivateDaemon("cli", log)
    var cli: Process = nil
    var child = ChildRef()
    try:
      let childSeconds =
        when defined(windows): "600"   # the job must be what ends it
        else: "3"
      let args = @["acquire", "--cpu", "1000", "--mem",
        $(HolderBytes div MiB) & "mib", "--label", "killed-cli", "--",
        getAppFilename(), SleeperFlag, childSeconds]
      log.note("cli: " & cliPath() & " " & args.join(" "))
      # Parent streams for the same reason as the holder above: the CLI's
      # child inherits its standard handles.
      cli = startProcess(cliPath(), args = args,
        env = childEnv(daemon.socketPath), options = {poParentStreams})
      must(waitFor(log, "cli lease running", 10_000, proc (): bool =
        let row = daemon.leaseRow("killed-cli")
        row.kind != JNull and row["state"].getStr == "running"),
        "cli lease running")
      let row = daemon.leaseRow("killed-cli")
      child = ChildRef(pid: row["child_process_id"].getInt,
        stamp: uint64(row["child_start_stamp"].getBiggestInt))
      log.note("cli pid " & $cli.processID & ", child pid " & $child.pid)

      cli.killAbruptly()
      check not cli.running
      log.note("cli killed")
      # The lease was lost, not finished: whatever happens next is the
      # orphan policy's doing.
      check waitFor(log, "cli session gone", 5000, proc (): bool =
        daemon.status().activeSessions == 0'u32)
      check daemon.status().totalFinished == 0'u64

      var waiter = offerWaiter(daemon, log)
      try:
        check waiter.pollForGrant(log, GrantBoundMillis)
        check daemon.leaseRow("killed-cli").kind == JNull
        check daemon.lostLeasesReaped() == 1
      finally:
        waiter.finish()
    finally:
      # A no-op whenever the case passed: the child is gone, which is what
      # the grant proved. Here for the case that did not.
      child.killChild()
      if cli != nil:
        if cli.running:
          cli.killAbruptly()
        cli.close()
      daemon.stop(log)
      log.reportOnFailure(testStatusIMPL == TestStatus.FAILED)
