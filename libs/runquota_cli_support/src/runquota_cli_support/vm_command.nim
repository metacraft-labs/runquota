## `runquota vm hold`: hold a virtual machine's registration on the host
## daemon for as long as the VM runs.
##
##   runquota vm hold --name NAME --cpu-milli N --memory-bytes N
##                    [--machine ID]
##                    (--pid PID [--vsock-cid CID] | --started-from-stdin)
##                    [--restart-grace SECONDS -- PROBE [ARGS...]]
##
## A VM provider runs this BEFORE it starts the VM. It registers the VM's
## shape (`RegisterVirtualMachine`), waits for the grant -- the host's memory
## for the VM is then reserved -- and prints `granted <lease-id>`. The
## provider starts the VM and writes one line, `<pid> [<vsock-cid>]`: the
## VM's host process and the CID its guest daemon will link from. This
## sends `VirtualMachineStarted`, prints `started`, detaches its standard
## streams and waits for that process to exit, then releases the lease.
## (`--pid` gives both on the command line instead, for a VM that already
## runs.)
##
## A VM RESTARTED IN PLACE gets a new hypervisor process (an Incus VM does on
## a guest reboot), so without more the registration would end while the VM
## runs on. With `--restart-grace SECONDS -- PROBE...`, when the watched
## process exits this runs PROBE (every 500 ms, each run bounded to 10 s)
## for up to SECONDS before releasing. PROBE is the provider's: on exit 0 it
## prints `<pid> [<vsock-cid>]` while the VM runs, `0` while it exists but
## does not run, and nothing at all once the VM no longer exists. A new pid
## is reported to the daemon (`VirtualMachineStarted` again: the new process
## becomes the watched child) and holding goes on; nothing, or the grace
## running out, releases. A probe that fails is retried within the grace, so
## an unanswered question keeps the reservation rather than dropping it.
##
## THE DAEMON NEVER STOPS THE VM, AND NEITHER DOES THIS. A SIGTERM or SIGINT
## ends this process without releasing: the lease is then supervisor-lost,
## and the daemon holds the reservation exactly as long as the VM process
## lives, because that process is the lease's watched child. Stdin ending
## before a pid arrived releases at once (the provider did not start the
## VM).
##
## EXIT STATUS
##   0  the VM process exited and the lease was released (or no VM started);
##   1  no daemon, a refusal, or the daemon went away while holding;
##   2  bad arguments.

import std/[net, os, osproc, streams, strutils, times]
when defined(posix):
  import std/posix

import runquota_client
import runquota_core
import runquota_protocol

type
  VmHoldOptions = object
    name: string
    cpuMilli: uint32
    memoryBytes: uint64
    machine: string
    pid: uint64
    vsockCid: uint32
    fromStdin: bool
    restartGraceSec: int
    probe: seq[string]

proc parseVmHold(args: seq[string]; options: var VmHoldOptions): string =
  var i = 0
  while i < args.len:
    let flag = args[i]
    if flag == "--started-from-stdin":
      options.fromStdin = true
      inc i
      continue
    if flag == "--":
      options.probe = args[i + 1 .. ^1]
      break
    if i + 1 >= args.len:
      return flag & " needs a value"
    let value = args[i + 1]
    try:
      case flag
      of "--name": options.name = value
      of "--cpu-milli": options.cpuMilli = uint32(parseUInt(value))
      of "--memory-bytes": options.memoryBytes = uint64(parseBiggestUInt(value))
      of "--machine": options.machine = value
      of "--pid": options.pid = uint64(parseBiggestUInt(value))
      of "--vsock-cid": options.vsockCid = uint32(parseUInt(value))
      of "--restart-grace":
        options.restartGraceSec = parseInt(value)
        if options.restartGraceSec < 0:
          return "--restart-grace needs a non-negative number of seconds"
      else: return "unknown option " & flag
    except ValueError, RangeDefect:
      return flag & " needs a whole number, got: " & value
    i += 2
  let problem = virtualMachineNameProblem(options.name)
  if problem.len > 0:
    return problem
  if options.cpuMilli == 0'u32 or options.memoryBytes == 0'u64:
    return "--cpu-milli and --memory-bytes are the VM's shape and must be " &
      "non-zero"
  if options.fromStdin == (options.pid != 0'u64):
    return "give exactly one of --pid and --started-from-stdin"
  if options.fromStdin and options.vsockCid != 0'u32:
    return "--vsock-cid goes with --pid; with --started-from-stdin it is " &
      "on the line"
  if (options.restartGraceSec > 0) != (options.probe.len > 0):
    return "--restart-grace and a probe command after -- go together"
  ""

when defined(linux):
  proc c_syscall(number: clong): clong {.importc: "syscall",
    header: "<unistd.h>", varargs.}
  const SysPidfdOpen = clong(434)

  proc waitForExit(pid: uint64; daemonFd: cint): bool =
    ## Wait until process `pid` exits; true when it did, false when the
    ## daemon connection closed first. A pidfd, so there is no polling; a
    ## kernel without one is read from /proc once a second.
    let pidfd = cint(c_syscall(SysPidfdOpen, cint(pid), cuint(0)))
    if pidfd < 0:
      if osLastError().int32 == ESRCH:
        return true
    while true:
      var fds = [TPollfd(fd: daemonFd, events: POLLIN),
                 TPollfd(fd: pidfd, events: POLLIN)]
      let count = if pidfd >= 0: 2 else: 1
      let ready = poll(addr fds[0], Tnfds(count),
        cint(if pidfd >= 0: -1 else: 1000))
      if ready < 0 and osLastError().int32 != EINTR:
        return true
      if (fds[0].revents and (POLLIN or POLLHUP or POLLERR)) != 0:
        # The daemon sends nothing unasked, so a readable connection is a
        # closed one.
        if pidfd >= 0: discard posix.close(pidfd)
        return false
      if pidfd >= 0 and (fds[1].revents and POLLIN) != 0:
        discard posix.close(pidfd)
        return true
      if pidfd < 0 and not dirExists("/proc/" & $pid):
        return true

  type ProbeAnswer = enum
    probeFailed, probeGone, probeNotRunning, probeRunning

  proc runProbe(probe: seq[string]; pid: var uint64;
                cid: var uint32): ProbeAnswer =
    ## One run of the provider's probe, bounded to 10 s.
    var p: Process
    try:
      p = startProcess(probe[0], args = probe[1 .. ^1],
        options = {poUsePath, poStdErrToStdOut})
    except CatchableError:
      return probeFailed
    defer: p.close()
    try:
      p.inputStream.close()
    except CatchableError:
      discard
    var waited = 0
    while p.running():
      if waited >= 10_000:
        # Our own child, started just above.
        p.kill()
        discard p.waitForExit()
        return probeFailed
      sleep(20)
      waited += 20
    let output =
      try: p.outputStream.readAll()
      except CatchableError: return probeFailed
    if p.waitForExit() != 0:
      return probeFailed
    let fields = output.splitWhitespace()
    if fields.len == 0:
      return probeGone
    try:
      pid = uint64(parseBiggestUInt(fields[0]))
      cid = if fields.len >= 2: uint32(parseUInt(fields[1])) else: 0'u32
    except ValueError, RangeDefect:
      return probeFailed
    if pid == 0'u64: probeNotRunning else: probeRunning

  proc followRestart(options: VmHoldOptions; ended: uint64;
                     cid: var uint32): uint64 =
    ## The watched process `ended` exited. The VM's new process when the
    ## probe reports one within the grace, else 0 (gone, or never back).
    let deadline = epochTime() + float(options.restartGraceSec)
    while true:
      var pid = 0'u64
      var probedCid = 0'u32
      case runProbe(options.probe, pid, probedCid)
      of probeGone:
        return 0'u64
      of probeRunning:
        if pid != ended and dirExists("/proc/" & $pid):
          if probedCid != 0'u32:
            cid = probedCid
          return pid
      of probeNotRunning, probeFailed:
        discard
      if epochTime() >= deadline:
        return 0'u64
      sleep(500)

  proc detachStreams() =
    ## The provider may exit while this holds; nothing it left connected
    ## may stop this process (SIGPIPE) or keep its pipes open.
    signal(SIGPIPE, SIG_IGN)
    let devNull = posix.open("/dev/null", O_RDWR)
    if devNull >= 0:
      discard dup2(devNull, 0)
      discard dup2(devNull, 1)
      discard dup2(devNull, 2)
      if devNull > 2: discard posix.close(devNull)

proc runVmHold*(args: seq[string]; clientVersion: string): int =
  when not defined(linux):
    stderr.writeLine("runquota vm hold: virtual machine registration is " &
      "implemented on Linux only")
    return 2
  else:
    var options = VmHoldOptions()
    let problem = parseVmHold(args, options)
    if problem.len > 0:
      stderr.writeLine("runquota vm hold: " & problem)
      return 2
    var client: RunQuotaClient
    try:
      client = connectDefault()
    except CatchableError as failure:
      stderr.writeLine("runquota vm hold: no daemon reached: " & failure.msg)
      return 1
    defer: client.close()
    if not client.supportsVirtualMachines():
      stderr.writeLine("runquota vm hold: the daemon (protocol minor " &
        $client.capabilities.protocolMinor & ") predates virtual machine " &
        "registration")
      return 1
    var session = client.registerSession("runquota vm hold", clientVersion)
    var resources = resourceVector(milliCpu(options.cpuMilli),
      bytes(options.memoryBytes))
    resources.machineId =
      if options.machine.len > 0: options.machine else: DefaultMachineId
    var lease: RunQuotaLease
    try:
      lease = session.registerVirtualMachineWaiting(options.name,
        "vm " & options.name, resources)
    except RunQuotaClientError:
      stderr.writeLine("runquota vm hold: registration refused: " &
        client.lastDiagnostic.message &
        (if client.lastDiagnostic.detail.len > 0:
           " (" & client.lastDiagnostic.detail & ")" else: ""))
      return 1
    echo "granted " & $lease.id.value
    flushFile(stdout)
    var pid = options.pid
    var cid = options.vsockCid
    if options.fromStdin:
      var line = ""
      if not stdin.readLine(line):
        lease.release()
        stderr.writeLine("runquota vm hold: no VM was started; released")
        return 0
      let fields = line.splitWhitespace()
      try:
        if fields.len < 1 or fields.len > 2:
          raise newException(ValueError, "expected '<pid> [<vsock-cid>]'")
        pid = uint64(parseBiggestUInt(fields[0]))
        if fields.len == 2:
          cid = uint32(parseUInt(fields[1]))
      except ValueError, RangeDefect:
        lease.release()
        stderr.writeLine("runquota vm hold: could not read '" & line &
          "' as '<pid> [<vsock-cid>]'; released")
        return 2
    let kind = if cid != 0'u32: vmLinkVsock else: vmLinkNone
    var linkKind = kind
    try:
      lease.markVirtualMachineStarted(pid, kind, cid)
    except RunQuotaClientError:
      if kind == vmLinkNone:
        stderr.writeLine("runquota vm hold: " & client.lastDiagnostic.message)
        lease.release()
        return 1
      # THE LINK ADDRESS WAS REFUSED (another registration holds the CID):
      # the VM still runs, so it is held WITHOUT a link, at its full shape,
      # and said so.
      stderr.writeLine("runquota vm hold: " & client.lastDiagnostic.message &
        "; holding the VM without a link, counted at its full shape")
      linkKind = vmLinkNone
      try:
        lease.markVirtualMachineStarted(pid, vmLinkNone, 0'u32)
      except RunQuotaClientError:
        stderr.writeLine("runquota vm hold: " & client.lastDiagnostic.message)
        lease.release()
        return 1
    echo "started"
    flushFile(stdout)
    detachStreams()
    let daemonFd = cint(client.connection.socket.getFd())
    var watched = pid
    while true:
      if not waitForExit(watched, daemonFd):
        return 1
      if options.restartGraceSec == 0:
        break
      # RESTARTED IN PLACE, OR GONE? Held while the probe decides.
      var nextCid = cid
      let next = followRestart(options, watched, nextCid)
      if next == 0'u64:
        break
      let nextKind = if linkKind == vmLinkVsock and nextCid != 0'u32:
                       vmLinkVsock else: vmLinkNone
      var reported = true
      try:
        lease.markVirtualMachineStarted(next, nextKind,
          if nextKind == vmLinkVsock: nextCid else: 0'u32)
      except RunQuotaClientError:
        reported = false
      if not reported and nextKind == vmLinkVsock:
        # As at the first start: a refused link address leaves the VM held
        # without a link, at its full shape.
        try:
          lease.markVirtualMachineStarted(next, vmLinkNone, 0'u32)
          reported = true
          nextCid = 0'u32
        except RunQuotaClientError:
          discard
      if not reported:
        break
      watched = next
      cid = nextCid
      linkKind = if nextCid != 0'u32: nextKind else: vmLinkNone
    try:
      lease.release()
      session.closeSession()
    except CatchableError:
      return 1
    0
