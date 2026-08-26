## The M1 instrument: an RQSP-aware measuring TAP on a real build's socket.
##
## WHY A TAP AND NOT A DRIVER. The M1 gate asks for admission and completion
## cost "for a real wide build and a real parallel test run". Every RunQuota
## benchmark before this one drove the daemon from a synthetic loop -- real
## daemon, real socket, but an arrival pattern no build has: no think time
## between leases, no dependency structure, no fan-out, and 78k-156k grants/s
## against a build's few hundred. The workload has to BE a build, which means
## the instrument cannot be the client.
##
## The subject is ``repro``, a binary this repository does not compile and
## cannot instrument. So the measurement is taken on the WIRE: a relay binds a
## unix socket, ``repro`` is pointed at it with ``RUNQUOTA_SOCKET``, and every
## RQSP frame is forwarded verbatim to the real ``runquotad`` while its
## 24-byte header is parsed and timestamped. Requests and responses carry the
## same ``requestId``, so a round trip is a pairing rather than an inference,
## and ``RqspMessageKind`` says which round trip it was -- which is the whole
## point of M1, whose instruction is to measure the BREAKDOWN of admission
## against completion reporting.
##
## WHAT THE TAP MEASURES IS NOT EXACTLY THE CLIENT ROUND TRIP, and this is
## stated rather than hoped away. The tap stamps a request when the last byte
## of it has arrived FROM the client, and its response when the last byte has
## arrived FROM the daemon. That window contains the tap-to-daemon hop, the
## daemon's service time and the daemon-to-tap hop -- one socket hop pair,
## the same count a direct client pays -- plus the tap's own forwarding work,
## and it EXCLUDES the client-to-tap and tap-to-client hops. The two errors
## have opposite signs and neither is assumed small: ``--mode=tap-overhead``
## measures the difference directly, driving identical lease traffic through
## the tap and straight at the daemon, and the published figure carries that
## correction as a stated band.
##
## THE HEADER PARSER IS THE SHIPPED ONE. ``decodeFrameHeader`` from
## ``runquota_protocol`` is called on the 24 bytes, so the tap cannot drift
## from the wire format it is watching; a hand-rolled parser here would be a
## second definition of the frame, free to be wrong.

import std/[atomics, os, posix]

import runquota_protocol

const
  TapHeaderLen* = int(RqspHeaderLen)
  MaxFrameBytes* = int(DefaultMaxFrameBytes)
  DefaultEventCapacity* = 4_000_000
    ## 4M events at 32 bytes is 128 MiB of shared buffer. A wide build's whole
    ## RunQuota conversation is a few thousand frames, so this is three orders
    ## of magnitude of headroom -- deliberately, because a buffer that WRAPS
    ## would silently drop the tail of a long test run and the resulting
    ## percentiles would describe the beginning of the run only. The tap
    ## refuses to wrap: it stops recording and raises ``overflowed``, which the
    ## published result reports.

type
  Direction* = enum
    dirClientToDaemon = 0
    dirDaemonToClient = 1

  TapEvent* = object
    tNs*: int64
    requestId*: uint64
    payloadLen*: uint32
    kind*: uint16
    dir*: uint8
    conn*: uint16
    peerPid*: int32

  TapState* = object
    events*: ptr UncheckedArray[TapEvent]
    capacity*: int
    count*: Atomic[int]
    overflowed*: Atomic[bool]
    connSeq*: Atomic[int]
    accepting*: Atomic[bool]
    listenFd*: Atomic[int]
    acceptErrors*: Atomic[int]
    upstreamErrors*: Atomic[int]
    upstreamPathLen*: int
    upstreamPath*: array[104, char]

  ConnCtx = object
    state: ptr TapState
    src: SocketHandle
    dst: SocketHandle
    dir: Direction
    conn: uint16
    peerPid: int32

when defined(macosx):
  {.emit: """/*TYPESECTION*/
#include <sys/socket.h>
#include <sys/un.h>
/* SO_PEERPID equivalent on Darwin: LOCAL_PEERPID at level SOL_LOCAL. Used to
   record WHICH process each RunQuota connection belonged to, so the published
   result can say whether the build's child actions speak RQSP at all or
   whether every frame came from the engine process. That is not a detail: it
   decides whether "syscalls attributable to RunQuota IPC" is a property of one
   process or of the whole tree. */
static int rqM1PeerPid(int fd) {
  pid_t pid = 0;
  socklen_t len = sizeof(pid);
  if (getsockopt(fd, 0 /*SOL_LOCAL*/, 0x002 /*LOCAL_PEERPID*/, &pid, &len)
      != 0) {
    return -1;
  }
  return (int)pid;
}
""".}
  proc rqM1PeerPid(fd: cint): cint {.importc: "rqM1PeerPid", nodecl.}
else:
  proc rqM1PeerPid(fd: cint): cint = -1

const ClockMonotonicRaw* = ClockId(4)
  ## Darwin's ``CLOCK_MONOTONIC_RAW``.
  ##
  ## NOT ``CLOCK_MONOTONIC``, AND THE DIFFERENCE IS NOT COSMETIC -- this is a
  ## correction the in-run calibration forced, and it refines what the M8
  ## study recorded. M8 states that "``CLOCK_MONOTONIC`` costs 14.0-14.6 ns and
  ## ZERO SYSCALLS over 10^6 calls" with "CLOCK RESOLUTION IS 41 ns -- a 24 MHz
  ## timebase". On this host (Darwin 26.5.1 / arm64), measured with the same
  ## kernel counter M8 used, ``clock_gettime(CLOCK_MONOTONIC)`` is NEITHER of
  ## those things: its resolution is 1000 ns and it makes 1-3 syscalls per 10^6
  ## calls. ``CLOCK_MONOTONIC_RAW`` and ``CLOCK_UPTIME_RAW`` are the clocks
  ## that reproduce M8's description exactly -- 41 ns resolution, ZERO syscalls
  ## over 10^6 calls, ~22 ns per call -- so M8's figure describes the raw
  ## timebase rather than the POSIX-adjusted clock its name says.
  ##
  ## THAT MATTERS FOR M1 SPECIFICALLY, twice over. A 1000 ns floor would
  ## quantise a 30 us round trip into 3% steps; and a clock that enters the
  ## kernel cannot be used inside a window whose syscalls are being counted,
  ## which is the whole reason M8 separated its CPU-clock build arm.

proc monoNs*(): int64 =
  ## THE ONLY CLOCK ALLOWED INSIDE A COUNTED WINDOW: 41 ns resolution, ~22 ns
  ## per call, ZERO syscalls. ``runquota_m1_bench --mode=calibrate``
  ## re-establishes all three in-run, every run, and REFUSES TO REPORT if any
  ## of them fails to hold.
  var ts: Timespec
  discard clock_gettime(ClockMonotonicRaw, ts)
  int64(ts.tv_sec) * 1_000_000_000'i64 + int64(ts.tv_nsec)

proc newTapState*(capacity = DefaultEventCapacity): ptr TapState =
  result = cast[ptr TapState](allocShared0(sizeof(TapState)))
  result.events = cast[ptr UncheckedArray[TapEvent]](
    allocShared0(capacity * sizeof(TapEvent)))
  result.capacity = capacity
  result.count.store(0)
  result.overflowed.store(false)
  result.connSeq.store(0)
  result.accepting.store(true)
  result.listenFd.store(-1)
  result.acceptErrors.store(0)
  result.upstreamErrors.store(0)

proc record(state: ptr TapState; ev: TapEvent) =
  let idx = state.count.fetchAdd(1)
  if idx >= state.capacity:
    state.overflowed.store(true)
    return
  state.events[idx] = ev

proc setUpstream*(state: ptr TapState; path: string) =
  if path.len >= state.upstreamPath.len:
    raise newException(ValueError, "upstream socket path too long: " & path)
  for i in 0 ..< path.len:
    state.upstreamPath[i] = path[i]
  state.upstreamPathLen = path.len

proc upstream(state: ptr TapState): string =
  result = newString(state.upstreamPathLen)
  for i in 0 ..< state.upstreamPathLen:
    result[i] = state.upstreamPath[i]

proc readExactly(fd: SocketHandle; buf: pointer; n: int): bool =
  ## True on a full read, false on clean EOF or error. Partial reads are
  ## normal on a stream socket and are looped over rather than treated as
  ## framing -- a tap that assumed one read per frame would mis-time every
  ## frame that arrived split.
  var off = 0
  while off < n:
    let got = posix.read(cint(fd), cast[pointer](cast[uint](buf) + uint(off)),
      n - off)
    if got == 0:
      return false
    if got < 0:
      if errno == EINTR:
        continue
      return false
    off += int(got)
  true

proc writeExactly(fd: SocketHandle; buf: pointer; n: int): bool =
  var off = 0
  while off < n:
    let put = posix.write(cint(fd), cast[pointer](cast[uint](buf) + uint(off)),
      n - off)
    if put <= 0:
      if put < 0 and errno == EINTR:
        continue
      return false
    off += int(put)
  true

proc pump(ctx: ptr ConnCtx) {.thread.} =
  ## One direction of one connection: read a whole frame, stamp it, forward it
  ## BYTE FOR BYTE. The tap never rewrites, reorders or coalesces; it is a
  ## measurement, and a measurement that changed the thing it measured would
  ## be reporting on itself.
  var buf = cast[ptr UncheckedArray[char]](
    allocShared0(TapHeaderLen + MaxFrameBytes))
  var headerStr = newString(TapHeaderLen)
  try:
    while true:
      if not readExactly(ctx.src, addr buf[0], TapHeaderLen):
        break
      for i in 0 ..< TapHeaderLen:
        headerStr[i] = buf[i]
      var header: FrameHeader
      if not decodeFrameHeader(headerStr, header):
        # NOT SILENTLY TOLERATED. An undecodable header means the tap and the
        # peers disagree about the wire, and every latency after it would be
        # mis-paired. Forward what we have and stop measuring this direction.
        discard writeExactly(ctx.dst, addr buf[0], TapHeaderLen)
        discard ctx.state.upstreamErrors.fetchAdd(1)
        break
      let payloadLen = int(header.payloadLen)
      if payloadLen > MaxFrameBytes:
        discard ctx.state.upstreamErrors.fetchAdd(1)
        break
      if payloadLen > 0:
        if not readExactly(ctx.src, addr buf[TapHeaderLen], payloadLen):
          break
      let stamp = monoNs()
      if not writeExactly(ctx.dst, addr buf[0], TapHeaderLen + payloadLen):
        break
      ctx.state.record(TapEvent(
        tNs: stamp,
        requestId: header.requestId,
        payloadLen: header.payloadLen,
        kind: uint16(ord(header.messageKind)),
        dir: uint8(ord(ctx.dir)),
        conn: ctx.conn,
        peerPid: ctx.peerPid
      ))
  finally:
    deallocShared(buf)
    discard posix.shutdown(ctx.dst, cint(SHUT_RDWR))
    discard posix.close(ctx.src)
    deallocShared(ctx)

proc connectUnix*(path: string): SocketHandle =
  let fd = posix.socket(AF_UNIX, SOCK_STREAM, 0)
  if cint(fd) < 0:
    return SocketHandle(-1)
  var addrIn: Sockaddr_un
  addrIn.sun_family = TSa_Family(AF_UNIX)
  if path.len >= addrIn.sun_path.len:
    discard posix.close(fd)
    return SocketHandle(-1)
  for i in 0 ..< path.len:
    addrIn.sun_path[i] = path[i]
  if posix.connect(fd, cast[ptr SockAddr](addr addrIn),
      SockLen(sizeof(addrIn))) != 0:
    discard posix.close(fd)
    return SocketHandle(-1)
  fd

proc listenUnix*(path: string): SocketHandle =
  removeFile(path)
  let fd = posix.socket(AF_UNIX, SOCK_STREAM, 0)
  if cint(fd) < 0:
    return SocketHandle(-1)
  var addrIn: Sockaddr_un
  addrIn.sun_family = TSa_Family(AF_UNIX)
  if path.len >= addrIn.sun_path.len:
    discard posix.close(fd)
    return SocketHandle(-1)
  for i in 0 ..< path.len:
    addrIn.sun_path[i] = path[i]
  if posix.bindSocket(fd, cast[ptr SockAddr](addr addrIn),
      SockLen(sizeof(addrIn))) != 0:
    discard posix.close(fd)
    return SocketHandle(-1)
  if posix.listen(fd, 64) != 0:
    discard posix.close(fd)
    return SocketHandle(-1)
  fd

proc acceptLoop*(state: ptr TapState) {.thread.} =
  let listenFd = SocketHandle(state.listenFd.load())
  var threads: seq[ref Thread[ptr ConnCtx]] = @[]
  while state.accepting.load():
    let clientFd = posix.accept(listenFd, nil, nil)
    if cint(clientFd) < 0:
      if errno == EINTR:
        continue
      discard state.acceptErrors.fetchAdd(1)
      break
    let daemonFd = connectUnix(state.upstream())
    if cint(daemonFd) < 0:
      discard state.upstreamErrors.fetchAdd(1)
      discard posix.close(clientFd)
      continue
    let conn = uint16(state.connSeq.fetchAdd(1))
    let peerPid = int32(rqM1PeerPid(cint(clientFd)))

    var upCtx = cast[ptr ConnCtx](allocShared0(sizeof(ConnCtx)))
    upCtx.state = state
    upCtx.src = clientFd
    upCtx.dst = daemonFd
    upCtx.dir = dirClientToDaemon
    upCtx.conn = conn
    upCtx.peerPid = peerPid

    var downCtx = cast[ptr ConnCtx](allocShared0(sizeof(ConnCtx)))
    downCtx.state = state
    downCtx.src = daemonFd
    downCtx.dst = clientFd
    downCtx.dir = dirDaemonToClient
    downCtx.conn = conn
    downCtx.peerPid = peerPid

    var upThread = new(Thread[ptr ConnCtx])
    var downThread = new(Thread[ptr ConnCtx])
    createThread(upThread[], pump, upCtx)
    createThread(downThread[], pump, downCtx)
    threads.add(upThread)
    threads.add(downThread)

proc snapshot*(state: ptr TapState): seq[TapEvent] =
  ## A COPY, taken once, after the subject has exited. Nothing reads the
  ## shared buffer while a pump thread might still be writing it.
  let n = min(state.count.load(), state.capacity)
  result = newSeq[TapEvent](n)
  for i in 0 ..< n:
    result[i] = state.events[i]

proc kindName*(kind: uint16): string =
  var parsed: RqspMessageKind
  if messageKindFromWire(kind, parsed):
    ($parsed).substr(2)
  else:
    "unknown(" & $kind & ")"

proc isRequestKind*(kind: RqspMessageKind): bool =
  kind in {rqHello, rqRegisterSession, rqCloseSession, rqRequestLease,
    rqReleaseLease, rqStatusRequest, rqLeaseStarting, rqLeaseRunning,
    rqLeaseFinished, rqOfferCandidates, rqGrantNext, rqInspectionRequest,
    rqStatsQuery, rqDeclareExtension}

type
  CostClass* = enum
    ccAdmission
    ccCompletion
    ccSession
    ccOther

proc costClass*(kind: RqspMessageKind): CostClass =
  ## THE BREAKDOWN M1 EXISTS TO PRODUCE, assigned per message kind rather
  ## than per round trip, because a round trip's class is a property of what
  ## was asked.
  ##
  ## ADMISSION is everything on the path from "the engine wants to run this
  ## action" to "it may": ``RequestLease``/``LeaseGranted``, the batched
  ## ``OfferCandidates``/``LeaseDecisionBatch`` form, and ``GrantNext``.
  ##
  ## COMPLETION REPORTING is everything the engine says about an execution it
  ## has already been admitted to run -- the lifecycle marks
  ## (``LeaseStarting``, ``LeaseRunning``), the observation report, the
  ## finish, and the release. RELEASE IS COUNTED AS COMPLETION, DELIBERATELY:
  ## the M4 observation ring would carry the reports and M23 would carry
  ## admission, and a release is a report that the execution is over. Putting
  ## it in admission would flatter the ring's share.
  case kind
  of rqRequestLease, rqLeaseGranted, rqLeaseDenied, rqOfferCandidates,
     rqLeaseDecisionBatch, rqGrantNext:
    ccAdmission
  of rqLeaseStarting, rqLeaseStartingAck, rqLeaseRunning, rqLeaseRunningAck,
     rqLeaseFinished, rqLeaseFinishedAck, rqLeaseObservation, rqReleaseLease,
     rqLeaseReleased, rqDeferredObservations:
    ccCompletion
  of rqHello, rqHelloOk, rqRegisterSession, rqSessionRegistered,
     rqCloseSession, rqSessionClosed:
    ccSession
  else:
    ccOther
