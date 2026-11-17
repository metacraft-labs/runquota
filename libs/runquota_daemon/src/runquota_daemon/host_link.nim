## The GUEST side of the host link: a `runquotad` running inside a virtual
## machine tells the host's daemon what its own leases hold, so the host can
## use the vCPUs the guest leaves idle and give them back when it does not.
##
## One thread. It connects to the host over vsock (`runquotad --link-host`),
## sends `MachineLink`, and then a `MachineReport` every time the guest's
## granted CPU changes -- the admission code calls `noteHostLinkGranted`
## from the one place every grant and release passes. Nothing is sent on a
## timer unless the operator asked for sampling (`--link-sample-millis`, off
## by default): with it, the guest's busy CPU and CPU pressure are read and
## sent every interval. A refused or lost link is retried after 1 s, then
## after twice as long each time, up to 30 s.
##
## The guest never waits for the host and never asks it anything: its own
## admission runs against its own budget, the VM's shape. The link only
## changes what the HOST charges for the VM.

import std/[atomics, locks, monotimes, strutils, times]

import runquota_codec
import runquota_core
import runquota_protocol

when defined(linux):
  import std/[oserrors, posix]
  import runquota_ipc/vsock

type
  HostLinkState* = enum
    hlOff = "off"
    hlConnecting = "connecting"
    hlLinked = "linked"
    hlRefused = "refused"
    hlLost = "lost"

var
  linkEnabled = false
  linkGranted: Atomic[uint32]
  linkStop: Atomic[bool]
  linkWake: array[2, cint] = [cint(-1), cint(-1)]
  linkThread: Thread[void]
  linkStatusLock: Lock
  linkState = hlOff
  linkLastError = ""
  linkHostName = ""
  linkReportsSent = 0'u64
  linkAttempts = 0'u64
  linkCid = 0'u32
  linkPort = 0'u32
  linkName = ""
  linkVersion = ""
  linkBudgetCpu = 0'u32
  linkBudgetMemory = 0'u64
  linkSampleMillis = 0
initLock(linkStatusLock)

proc setLinkStatus(state: HostLinkState; error = ""; hostName = "") =
  acquire(linkStatusLock)
  try:
    linkState = state
    if error.len > 0 or state == hlLinked:
      linkLastError = error
    if state == hlLinked:
      linkHostName = hostName
  finally:
    release(linkStatusLock)

proc parseLinkHost*(spec: string; cid, port: var uint32): string =
  ## `vsock`, `vsock:PORT` or `vsock:CID:PORT`. Returns "" when it parses,
  ## else why not. The CID defaults to the host's (2) and the port to
  ## `DefaultVmLinkVsockPort`.
  let parts = spec.split(':')
  if parts.len == 0 or parts[0] != "vsock" or parts.len > 3:
    return "--link-host is vsock, vsock:PORT or vsock:CID:PORT, got: " & spec
  cid = VsockHostCid
  port = DefaultVmLinkVsockPort
  try:
    if parts.len == 2:
      port = uint32(parseUInt(parts[1]))
    elif parts.len == 3:
      cid = uint32(parseUInt(parts[1]))
      port = uint32(parseUInt(parts[2]))
  except ValueError, RangeDefect:
    return "--link-host has a CID or port that is not a whole number: " & spec
  if port == 0'u32:
    return "--link-host needs a non-zero port: " & spec
  ""

proc hostLinkJson*(): string =
  ## The guest's view of its link, for `runquota status --json`.
  if not linkEnabled:
    return "{\"state\":\"off\"}"
  acquire(linkStatusLock)
  try:
    result = "{\"state\":" & jsonEscape($linkState) &
      ",\"transport\":\"vsock\",\"cid\":" & $linkCid & ",\"port\":" &
      $linkPort & ",\"host_vm_name\":" & jsonEscape(linkHostName) &
      ",\"granted_cpu_milli\":" & $linkGranted.load() &
      ",\"reports_sent\":" & $linkReportsSent &
      ",\"attempts\":" & $linkAttempts &
      ",\"sample_millis\":" & $linkSampleMillis &
      ",\"last_error\":" & jsonEscape(linkLastError) & "}"
  finally:
    release(linkStatusLock)

proc wakeLink() =
  when defined(linux):
    if linkWake[1] >= 0:
      var b = 'w'
      discard posix.write(linkWake[1], addr b, 1)

proc noteHostLinkGranted*(milli: uint32) {.gcsafe.} =
  ## The guest's granted CPU is now `milli`. Called under the daemon lock on
  ## every grant, release and charge change; costs one atomic exchange when
  ## nothing changed and nothing at all when no link is configured.
  {.cast(gcsafe).}:
    if not linkEnabled:
      return
    if linkGranted.exchange(milli) != milli:
      wakeLink()

when defined(linux):
  proc readExactFd(fd: cint; size: int; timeoutMs: int; data: var string): bool =
    data = newString(size)
    var got = 0
    let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
    while got < size:
      let left = int((deadline - getMonoTime()).inMilliseconds)
      if left <= 0:
        return false
      var pfd = TPollfd(fd: fd, events: POLLIN)
      if poll(addr pfd, 1, cint(left)) <= 0:
        return false
      let n = posix.read(fd, addr data[got], size - got)
      if n <= 0:
        return false
      got += n
    true

  proc readFrameFd(fd: cint; timeoutMs: int; frame: var RqspFrame): bool =
    var head: string
    if not readExactFd(fd, int(RqspHeaderLen), timeoutMs, head):
      return false
    var header: FrameHeader
    if not decodeFrameHeader(head, header):
      return false
    if int(header.payloadLen) + int(RqspHeaderLen) > MaxLinkFrameBytes:
      return false
    var payload = ""
    if header.payloadLen > 0'u32 and
        not readExactFd(fd, int(header.payloadLen), timeoutMs, payload):
      return false
    frame = RqspFrame(header: header, payload: payload)
    true

  type CpuSample = object
    known: bool
    busy: uint64
    total: uint64

  proc readCpuSample(): CpuSample =
    try:
      let line = readFile("/proc/stat").splitLines()[0]
      let fields = line.splitWhitespace()
      if fields.len < 5 or fields[0] != "cpu":
        return
      var total = 0'u64
      var idle = 0'u64
      for i in 1 ..< fields.len:
        let v = parseBiggestUInt(fields[i])
        # guest and guest_nice (fields 9, 10) are already in user and nice.
        if i <= 8: total += v
        if i == 4 or i == 5: idle += v
      CpuSample(known: true, busy: total - idle, total: total)
    except CatchableError:
      CpuSample()

  proc readCpuSomePermille(value: var uint32): bool =
    try:
      for line in readFile("/proc/pressure/cpu").splitLines():
        if line.startsWith("some "):
          for field in line.splitWhitespace():
            if field.startsWith("avg10="):
              value = uint32(parseFloat(field[6 .. ^1]) * 10.0 + 0.5)
              return true
    except CatchableError:
      discard
    false

  proc sendReport(fd: cint; sequence: var uint64; granted: uint32;
                  usedPresent: bool; used: uint32;
                  pressurePresent: bool; pressure: uint32): bool =
    inc sequence
    let frame = encodeFrame(rqMachineReport, FrameFlagRequest, sequence,
      encodeMachineReport(MachineReportMessage(sequence: sequence,
        grantedCpuMilli: granted, usedPresent: usedPresent,
        usedCpuMilli: used, pressurePresent: pressurePresent,
        cpuSomePermille: pressure)))
    if not writeAllFd(fd, frame):
      return false
    acquire(linkStatusLock)
    inc linkReportsSent
    release(linkStatusLock)
    true

  proc drainWake() =
    var buffer: array[64, char]
    while posix.read(linkWake[0], addr buffer[0], buffer.len) > 0:
      discard

  proc waitStopOrTimeout(timeoutMs: int): bool =
    ## Sleep up to `timeoutMs`, waking for a stop. True when stopping.
    let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
    while not linkStop.load():
      let left = int((deadline - getMonoTime()).inMilliseconds)
      if left <= 0:
        return false
      var pfd = TPollfd(fd: linkWake[0], events: POLLIN)
      discard poll(addr pfd, 1, cint(left))
      drainWake()
    true

  proc serveLink(fd: cint): bool =
    ## One link, until it is refused, lost, or the daemon stops. True when
    ## it had been attached, so the next attempt starts from the shortest
    ## wait again.
    let hello = encodeFrame(rqMachineLink, FrameFlagRequest, 1'u64,
      encodeMachineLink(MachineLinkMessage(guestVersion: linkVersion,
        name: linkName, budgetCpuMilli: linkBudgetCpu,
        budgetMemoryBytes: linkBudgetMemory,
        grantedCpuMilli: linkGranted.load())))
    var lastSent = linkGranted.load()
    if not writeAllFd(fd, hello):
      setLinkStatus(hlLost, "could not send MachineLink")
      return false
    var answer: RqspFrame
    if not readFrameFd(fd, 10_000, answer) or
        answer.header.messageKind != rqMachineLinked:
      setLinkStatus(hlLost, "the host did not answer MachineLink")
      return false
    var linked: MachineLinkedMessage
    if not decodeMachineLinked(answer.payload, linked):
      setLinkStatus(hlLost, "the host's MachineLinked did not decode")
      return false
    if not linked.accepted:
      setLinkStatus(hlRefused, "the host refused the link: " &
        linked.diagnostic.message)
      return false
    setLinkStatus(hlLinked, "", linked.name)
    var sequence = 1'u64
    var previous = if linkSampleMillis > 0: readCpuSample() else: CpuSample()
    let cpus = max(1'u32, linkBudgetCpu div 1000'u32)
    var nextSample = getMonoTime() +
      initDuration(milliseconds = max(linkSampleMillis, 1))
    while not linkStop.load():
      # Anything granted between the link message and now goes out first.
      let granted = linkGranted.load()
      if granted != lastSent:
        if not sendReport(fd, sequence, granted, false, 0, false, 0):
          setLinkStatus(hlLost, "the link closed while reporting")
          return true
        lastSent = granted
      var timeout = -1
      if linkSampleMillis > 0:
        timeout = max(0, int((nextSample - getMonoTime()).inMilliseconds))
      var fds = [TPollfd(fd: fd, events: POLLIN),
                 TPollfd(fd: linkWake[0], events: POLLIN)]
      let ready = poll(addr fds[0], 2, cint(timeout))
      if ready < 0:
        if osLastError().int32 == EINTR: continue
        setLinkStatus(hlLost, "poll failed: " & osErrorMsg(osLastError()))
        return true
      if (fds[0].revents and (POLLIN or POLLHUP or POLLERR)) != 0:
        # The host sends nothing after MachineLinked, so a readable link is a
        # closed one (or one the host ended because the VM was forgotten).
        setLinkStatus(hlLost, "the host closed the link")
        return true
      if (fds[1].revents and POLLIN) != 0:
        drainWake()
      if linkSampleMillis > 0 and getMonoTime() >= nextSample:
        nextSample = getMonoTime() +
          initDuration(milliseconds = linkSampleMillis)
        let sample = readCpuSample()
        var usedPresent = false
        var used = 0'u32
        if sample.known and previous.known and sample.total > previous.total:
          let busy = float(sample.busy - previous.busy) /
            float(sample.total - previous.total)
          used = uint32(busy * float(cpus) * 1000.0 + 0.5)
          usedPresent = true
        previous = sample
        var pressure = 0'u32
        let pressurePresent = readCpuSomePermille(pressure)
        let granted = linkGranted.load()
        if not sendReport(fd, sequence, granted, usedPresent, used,
            pressurePresent, pressure):
          setLinkStatus(hlLost, "the link closed while reporting")
          return true
        lastSent = granted
    true

  proc hostLinkMain() {.thread.} =
    {.cast(gcsafe).}:
      var backoff = 1000
      while not linkStop.load():
        setLinkStatus(hlConnecting)
        acquire(linkStatusLock)
        inc linkAttempts
        release(linkStatusLock)
        var fd = cint(-1)
        try:
          fd = vsockConnect(linkCid, linkPort)
        except OSError as error:
          setLinkStatus(hlLost, error.msg)
        var wasLinked = false
        if fd >= 0:
          wasLinked = serveLink(fd)
          discard posix.close(fd)
        if wasLinked:
          backoff = 1000
        if waitStopOrTimeout(backoff):
          break
        if not wasLinked:
          backoff = min(backoff * 2, 30_000)
      setLinkStatus(hlOff)

proc startHostLink*(cid, port: uint32; name, version: string;
                    budgetCpuMilli: uint32; budgetMemoryBytes: uint64;
                    sampleMillis: int; grantedNow: uint32): string =
  ## Start the link thread. Returns "" on success, else why it cannot run
  ## (vsock exists on Linux only).
  when defined(linux):
    var fds: array[2, cint]
    if pipe(fds) != 0:
      return "cannot create the host link's wake pipe: " &
        osErrorMsg(osLastError())
    for fd in fds:
      discard fcntl(fd, F_SETFD, FD_CLOEXEC)
      setNonBlocking(fd)
    linkWake = fds
    linkCid = cid
    linkPort = port
    linkName = name
    linkVersion = version
    linkBudgetCpu = budgetCpuMilli
    linkBudgetMemory = budgetMemoryBytes
    linkSampleMillis = max(0, sampleMillis)
    linkGranted.store(grantedNow)
    linkStop.store(false)
    linkEnabled = true
    createThread(linkThread, hostLinkMain)
    ""
  else:
    "the host link needs vsock, which this platform does not have"

proc stopHostLink*() =
  when defined(linux):
    if not linkEnabled:
      return
    linkStop.store(true)
    wakeLink()
    joinThread(linkThread)
    linkEnabled = false
    for fd in linkWake:
      if fd >= 0: discard posix.close(fd)
    linkWake = [cint(-1), cint(-1)]
