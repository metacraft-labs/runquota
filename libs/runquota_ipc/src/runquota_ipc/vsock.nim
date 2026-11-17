## virtio-vsock stream sockets (Linux `AF_VSOCK`), the transport of the host
## link between a guest's RunQuota daemon and the host's.
##
## Only what the link needs: a listener on every CID, an accept that reports
## the peer's CID, and a client connect. A CID is assigned to each guest by
## the hypervisor; a guest addresses the host as `VMADDR_CID_HOST` (2).

when defined(linux):
  import std/[oserrors, posix]

  const
    AfVsock* = cint(40)
      ## `AF_VSOCK` (linux/socket.h).
    VmaddrCidAny* = 0xFFFF_FFFF'u32
    VmaddrCidHost* = 2'u32

  type
    SockaddrVm* {.pure.} = object
      ## `struct sockaddr_vm` (linux/vm_sockets.h), 16 bytes.
      family*: uint16
      reserved1*: uint16
      port*: uint32
      cid*: uint32
      flags*: uint8
      zero*: array[3, uint8]

  proc vsockAddress(cid, port: uint32): SockaddrVm =
    SockaddrVm(family: uint16(AfVsock), port: port, cid: cid)

  proc newVsockStream(): cint =
    result = cint(socket(AfVsock, SOCK_STREAM or SOCK_CLOEXEC, 0))
    if result < 0:
      raiseOSError(osLastError(), "socket(AF_VSOCK)")

  proc vsockListen*(port: uint32; backlog = 64): cint =
    ## A listening stream socket on `port` of every local CID. Raises
    ## `OSError` when vsock is unavailable (no `vhost_vsock` on a host) or
    ## the port is taken.
    let fd = newVsockStream()
    var address = vsockAddress(VmaddrCidAny, port)
    if bindSocket(SocketHandle(fd), cast[ptr SockAddr](addr address),
        SockLen(sizeof(address))) != 0:
      let error = osLastError()
      discard close(fd)
      raiseOSError(error, "bind(AF_VSOCK, port " & $port & ")")
    if listen(SocketHandle(fd), cint(backlog)) != 0:
      let error = osLastError()
      discard close(fd)
      raiseOSError(error, "listen(AF_VSOCK, port " & $port & ")")
    fd

  proc vsockAccept*(listener: cint; peerCid: var uint32): cint =
    ## Accept one connection; `peerCid` is the CID the connection came from.
    ## Returns -1 (errno set) when nothing could be accepted.
    var address: SockaddrVm
    var length = SockLen(sizeof(address))
    let fd = accept4(SocketHandle(listener), cast[ptr SockAddr](addr address),
      addr length, SOCK_CLOEXEC)
    if cint(fd) < 0:
      return -1
    peerCid = address.cid
    cint(fd)

  proc vsockConnect*(cid, port: uint32): cint =
    ## A connected stream to `cid:port`. Raises `OSError` on failure: a
    ## refused port (no listener) fails at once, an absent peer after the
    ## kernel's connect timeout (2 s by default).
    let fd = newVsockStream()
    var address = vsockAddress(cid, port)
    if connect(SocketHandle(fd), cast[ptr SockAddr](addr address),
        SockLen(sizeof(address))) != 0:
      let error = osLastError()
      discard close(fd)
      raiseOSError(error, "connect(AF_VSOCK " & $cid & ":" & $port & ")")
    fd

  proc setNonBlocking*(fd: cint) =
    let flags = fcntl(fd, F_GETFL)
    if flags >= 0:
      discard fcntl(fd, F_SETFL, flags or O_NONBLOCK)

  proc writeAllFd*(fd: cint; data: string; timeoutMs = 5000): bool =
    ## Write all of `data`, waiting up to `timeoutMs` for room each time the
    ## socket is full. False when it could not (closed, or timed out).
    var offset = 0
    while offset < data.len:
      # `send` with MSG_NOSIGNAL: a peer that went away must not raise
      # SIGPIPE in a daemon.
      let n = send(SocketHandle(fd), unsafeAddr data[offset], data.len - offset,
        MSG_NOSIGNAL)
      if n > 0:
        offset += n
        continue
      let errno = osLastError()
      if n < 0 and (errno.int32 == EAGAIN or errno.int32 == EWOULDBLOCK or
          errno.int32 == EINTR):
        var pfd = TPollfd(fd: fd, events: POLLOUT)
        if poll(addr pfd, 1, cint(timeoutMs)) <= 0:
          return false
        continue
      return false
    true
