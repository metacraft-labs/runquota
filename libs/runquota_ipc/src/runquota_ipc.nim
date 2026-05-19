import std/[net, nativesockets, os, strutils]

when defined(posix):
  import std/posix
  when defined(macosx) or defined(freebsd) or defined(openbsd):
    proc getpeereid(socket: SocketHandle; euid: ptr Uid; egid: ptr Gid): cint {.
      importc, header: "<unistd.h>".}
  when defined(linux):
    type
      LinuxPeerCred {.importc: "struct ucred", header: "<sys/socket.h>", bycopy.} = object
        pid {.importc: "pid".}: Pid
        uid {.importc: "uid".}: Uid
        gid {.importc: "gid".}: Gid

    const SoPeerCred = cint(17)

when defined(windows):
  # Windows: native named-pipe transport implementation. We use winlean for
  # the low-level pieces and call a handful of advapi32 functions that
  # winlean does not expose directly. The Windows daemon spawns one
  # listener thread that pre-creates a pipe instance, calls
  # ConnectNamedPipe to wait for a client, hands the connected handle to
  # a worker thread, then loops to pre-create the next instance.
  import std/winlean

  const
    # Windows: PIPE_UNLIMITED_INSTANCES from winbase.h.
    PIPE_UNLIMITED_INSTANCES = 255'i32
    PIPE_ACCESS_DUPLEX_W = 0x00000003'i32
    PIPE_TYPE_BYTE_W = 0x00000000'i32
    PIPE_READMODE_BYTE_W = 0x00000000'i32
    PIPE_WAIT_W = 0x00000000'i32
    PIPE_REJECT_REMOTE_CLIENTS_W = 0x00000008'i32
    NMPWAIT_USE_DEFAULT_WAIT = 0x00000000'i32
    GENERIC_READ_W = 0x80000000'i32
    GENERIC_WRITE_W = 0x40000000'i32
    OPEN_EXISTING_W = 3'i32
    DefaultPipeBufferSize = 65536'i32
    # Windows: GetTokenInformation TokenUser class (TOKEN_INFORMATION_CLASS=1).
    TokenUserClass = 1'i32
    TOKEN_QUERY_W = 0x0008'i32
    ERROR_PIPE_CONNECTED = 535'i32
    ERROR_NO_DATA = 232'i32
    ERROR_BROKEN_PIPE = 109'i32

  type
    WinHandle = winlean.Handle

  proc createNamedPipeW(
    lpName: WideCString,
    dwOpenMode: int32,
    dwPipeMode: int32,
    nMaxInstances: int32,
    nOutBufferSize: int32,
    nInBufferSize: int32,
    nDefaultTimeOut: int32,
    lpSecurityAttributes: pointer
  ): WinHandle {.stdcall, dynlib: "kernel32.dll", importc: "CreateNamedPipeW".}

  proc connectNamedPipe(
    hNamedPipe: WinHandle, lpOverlapped: pointer
  ): WINBOOL {.stdcall, dynlib: "kernel32.dll", importc: "ConnectNamedPipe".}

  proc disconnectNamedPipe(
    hNamedPipe: WinHandle
  ): WINBOOL {.stdcall, dynlib: "kernel32.dll", importc: "DisconnectNamedPipe".}

  proc waitNamedPipeW(
    lpName: WideCString, nTimeOut: int32
  ): WINBOOL {.stdcall, dynlib: "kernel32.dll", importc: "WaitNamedPipeW".}

  proc getNamedPipeClientProcessId(
    Pipe: WinHandle, ClientProcessId: ptr int32
  ): WINBOOL {.stdcall, dynlib: "kernel32.dll", importc: "GetNamedPipeClientProcessId".}

  proc openProcessToken(
    ProcessHandle: WinHandle, DesiredAccess: int32, TokenHandle: ptr WinHandle
  ): WINBOOL {.stdcall, dynlib: "advapi32.dll", importc: "OpenProcessToken".}

  proc getTokenInformation(
    TokenHandle: WinHandle, TokenInformationClass: int32,
    TokenInformation: pointer, TokenInformationLength: int32,
    ReturnLength: ptr int32
  ): WINBOOL {.stdcall, dynlib: "advapi32.dll", importc: "GetTokenInformation".}

  proc convertSidToStringSidW(
    Sid: pointer, StringSid: ptr ptr uint16
  ): WINBOOL {.stdcall, dynlib: "advapi32.dll", importc: "ConvertSidToStringSidW".}

  proc localFree(hMem: pointer): pointer {.stdcall, dynlib: "kernel32.dll", importc: "LocalFree".}

  proc getCurrentProcessHandle(): WinHandle {.stdcall, dynlib: "kernel32.dll", importc: "GetCurrentProcess".}

  proc closeHandleW(hObject: WinHandle): WINBOOL {.stdcall, dynlib: "kernel32.dll", importc: "CloseHandle".}

import runquota_ipc/types as ipcTypes
import runquota_core
import runquota_protocol

export ipcTypes

const libraryName* = "runquota_ipc"

proc libraryInfo*(): ipcTypes.LibraryInfo =
  ipcTypes.LibraryInfo(name: libraryName)

proc unixEndpoint*(path: string): Endpoint =
  Endpoint(kind: endpointUnixSocket, path: path)

when defined(windows):
  # Windows: build the spec-defined named-pipe path. We sanitise the user
  # name so the path stays well-formed regardless of locale or special chars.
  proc namedPipeEndpoint*(path: string): Endpoint =
    Endpoint(kind: endpointNamedPipe, path: path)

  proc sanitiseUserToken(token: string): string =
    result = newStringOfCap(token.len)
    for ch in token:
      if ch.isAlphaNumeric or ch == '-' or ch == '_' or ch == '.':
        result.add(ch)
      else:
        result.add('_')

  proc currentUserToken(): string =
    # Windows: prefer USERNAME but fall back to a literal "default" so the
    # daemon still has a usable per-process endpoint even in stripped envs.
    let username = getEnv("USERNAME")
    if username.len > 0:
      sanitiseUserToken(username)
    else:
      "default"

  proc defaultWindowsPipePath(): string =
    r"\\.\pipe\runquota-" & currentUserToken()

proc defaultEndpoint*(): Endpoint =
  let overridePath = getEnv("RUNQUOTA_SOCKET")
  if overridePath.len > 0:
    when defined(windows):
      # Windows: respect the override but treat values starting with \\.\pipe\
      # as named-pipe paths and everything else as a Unix-socket override
      # (used in cross-platform fixtures that already set the env var).
      if overridePath.startsWith(r"\\.\pipe\") or overridePath.startsWith(r"\\?\pipe\"):
        return namedPipeEndpoint(overridePath)
      return unixEndpoint(overridePath)
    else:
      return unixEndpoint(overridePath)
  when defined(posix):
    let base = getEnv("XDG_RUNTIME_DIR", getEnv("TMPDIR", getTempDir()))
    let dir = base / ("runquota-" & $getuid())
    unixEndpoint(dir / "runquotad.sock")
  elif defined(windows):
    # Windows: named pipes don't need a parent directory and live in the
    # NPFS namespace, so just return the canonical per-user path.
    namedPipeEndpoint(defaultWindowsPipePath())
  else:
    Endpoint(kind: endpointUnsupported, path: "")

proc ensureEndpointDir*(endpoint: Endpoint) =
  case endpoint.kind
  of endpointUnixSocket:
    if endpoint.path.len > 0:
      createDir(parentDir(endpoint.path))
  of endpointNamedPipe, endpointUnsupported:
    # Windows: named pipes live in the kernel object namespace; no fs dir.
    discard

when defined(windows):
  proc raiseLastWinError(prefix: string) =
    raise newException(OSError, prefix & ": Windows error " & $osLastError().int32)

  proc createServerPipe(name: string; first: bool): WinHandle =
    # Windows: per CreateNamedPipeW, FILE_FLAG_FIRST_PIPE_INSTANCE (0x80000) is
    # required on the first instance to detect path collisions. Subsequent
    # instances must omit it. We also reject remote clients for security.
    var openMode = PIPE_ACCESS_DUPLEX_W
    if first:
      openMode = openMode or 0x00080000'i32  # FILE_FLAG_FIRST_PIPE_INSTANCE
    let mode = PIPE_TYPE_BYTE_W or PIPE_READMODE_BYTE_W or PIPE_WAIT_W or
      PIPE_REJECT_REMOTE_CLIENTS_W
    result = createNamedPipeW(
      newWideCString(name),
      openMode,
      mode,
      PIPE_UNLIMITED_INSTANCES,
      DefaultPipeBufferSize,
      DefaultPipeBufferSize,
      0'i32,
      nil
    )
    if result == INVALID_HANDLE_VALUE:
      raiseLastWinError("CreateNamedPipeW failed for " & name)

  proc connectClient(handle: WinHandle): bool =
    # Windows: ConnectNamedPipe returns 0 with last-error ERROR_PIPE_CONNECTED
    # when the client raced ahead and is already on the pipe. Both outcomes
    # mean "ready to use".
    let rc = connectNamedPipe(handle, nil)
    if rc != 0:
      return true
    let err = osLastError().int32
    if err == ERROR_PIPE_CONNECTED:
      return true
    false

proc connectEndpoint*(endpoint: Endpoint): LocalConnection =
  case endpoint.kind
  of endpointUnixSocket:
    when defined(windows):
      raise newException(OSError, "Unix-socket endpoints are not supported on Windows")
    else:
      var socket = newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_NONE)
      socket.connectUnix(endpoint.path)
      LocalConnection(kind: endpointUnixSocket, socket: socket, endpoint: endpoint)
  of endpointNamedPipe:
    when defined(windows):
      # Windows: open the pipe with read+write access. If the server is
      # accepting another client right now (all instances busy), the call
      # would fail with ERROR_PIPE_BUSY; we wait briefly and retry.
      let wide = newWideCString(endpoint.path)
      var handle: WinHandle = INVALID_HANDLE_VALUE
      for attempt in 0 ..< 5:
        handle = createFileW(
          wide,
          GENERIC_READ_W or GENERIC_WRITE_W,
          0'i32,
          nil,
          OPEN_EXISTING_W,
          0'i32,
          0
        )
        if handle != INVALID_HANDLE_VALUE:
          break
        let err = osLastError().int32
        if err == 231'i32:  # Windows: ERROR_PIPE_BUSY
          discard waitNamedPipeW(wide, NMPWAIT_USE_DEFAULT_WAIT)
          continue
        raiseLastWinError("CreateFileW failed for " & endpoint.path)
      if handle == INVALID_HANDLE_VALUE:
        raise newException(OSError, "could not open named pipe " & endpoint.path)
      LocalConnection(kind: endpointNamedPipe, pipeHandle: int(handle), endpoint: endpoint)
    else:
      raise newException(OSError, "named-pipe endpoints are only supported on Windows")
  else:
    raise newException(OSError, "unsupported RunQuota endpoint")

proc connectDefault*(): LocalConnection =
  connectEndpoint(defaultEndpoint())

proc bindEndpoint*(endpoint: Endpoint): LocalListener =
  case endpoint.kind
  of endpointUnixSocket:
    when defined(windows):
      raise newException(OSError, "Unix-socket endpoints are not supported on Windows")
    else:
      ensureEndpointDir(endpoint)
      if fileExists(endpoint.path):
        removeFile(endpoint.path)
      var socket = newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_NONE)
      socket.bindUnix(endpoint.path)
      socket.listen()
      LocalListener(kind: endpointUnixSocket, socket: socket, endpoint: endpoint)
  of endpointNamedPipe:
    when defined(windows):
      # Windows: pre-create the first pipe instance so the listener has an
      # instance ready for the very first accept call.
      let handle = createServerPipe(endpoint.path, first = true)
      LocalListener(
        kind: endpointNamedPipe,
        pendingPipeHandle: int(handle),
        endpoint: endpoint
      )
    else:
      raise newException(OSError, "named-pipe endpoints are only supported on Windows")
  else:
    raise newException(OSError, "unsupported RunQuota endpoint")

proc acceptConnection*(listener: var LocalListener): LocalConnection =
  case listener.kind
  of endpointUnixSocket:
    when defined(windows):
      raise newException(OSError, "Unix-socket endpoints are not supported on Windows")
    else:
      var client: owned(Socket)
      listener.socket.accept(client)
      LocalConnection(kind: endpointUnixSocket, socket: client, endpoint: listener.endpoint)
  of endpointNamedPipe:
    when defined(windows):
      # Windows: ConnectNamedPipe on the pre-created instance, then pre-create
      # the next instance so the next accept call is ready to go.
      let activeHandle = WinHandle(listener.pendingPipeHandle)
      if not connectClient(activeHandle):
        raiseLastWinError("ConnectNamedPipe failed")
      let nextHandle = createServerPipe(listener.endpoint.path, first = false)
      listener.pendingPipeHandle = int(nextHandle)
      LocalConnection(
        kind: endpointNamedPipe,
        pipeHandle: int(activeHandle),
        endpoint: listener.endpoint
      )
    else:
      raise newException(OSError, "named-pipe endpoints are only supported on Windows")
  else:
    raise newException(OSError, "unsupported RunQuota endpoint")

proc acceptNativeConnection*(listener: var LocalListener): AcceptedConnection =
  case listener.kind
  of endpointUnixSocket:
    when defined(windows):
      raise newException(OSError, "Unix-socket endpoints are not supported on Windows")
    else:
      let accepted = nativesockets.accept(listener.socket.getFd())
      if accepted[0] == osInvalidSocket:
        raiseOSError(osLastError())
      AcceptedConnection(kind: endpointUnixSocket, handle: accepted[0])
  of endpointNamedPipe:
    when defined(windows):
      # Windows: accept by completing ConnectNamedPipe on the parked instance,
      # then pre-create the replacement.
      let activeHandle = WinHandle(listener.pendingPipeHandle)
      if not connectClient(activeHandle):
        raiseLastWinError("ConnectNamedPipe failed")
      let nextHandle = createServerPipe(listener.endpoint.path, first = false)
      listener.pendingPipeHandle = int(nextHandle)
      AcceptedConnection(kind: endpointNamedPipe, pipeHandle: int(activeHandle))
    else:
      raise newException(OSError, "named-pipe endpoints are only supported on Windows")
  else:
    raise newException(OSError, "unsupported RunQuota endpoint")

proc localConnection*(accepted: AcceptedConnection): LocalConnection =
  case accepted.kind
  of endpointUnixSocket:
    LocalConnection(
      kind: endpointUnixSocket,
      socket: newSocket(accepted.handle, AF_UNIX, SOCK_STREAM, IPPROTO_NONE),
      endpoint: Endpoint(kind: endpointUnixSocket, path: "")
    )
  of endpointNamedPipe:
    when defined(windows):
      LocalConnection(
        kind: endpointNamedPipe,
        pipeHandle: accepted.pipeHandle,
        endpoint: Endpoint(kind: endpointNamedPipe, path: "")
      )
    else:
      raise newException(OSError, "named-pipe endpoints are only supported on Windows")
  else:
    raise newException(OSError, "unsupported accepted connection")

when defined(windows):
  proc readPeerSidFromHandle(pipe: WinHandle; identity: var PeerIdentity) =
    # Windows: best-effort peer identity. We open the client's process for
    # token query only; if any step fails we leave the identity as
    # peerIdentityUnavailable. The textual SID is returned to callers so the
    # daemon can log it.
    var clientPid: int32 = 0
    if getNamedPipeClientProcessId(pipe, addr clientPid) == 0:
      return
    identity.processId = uint64(clientPid)
    identity.kind = peerIdentityProcess
    const PROCESS_QUERY_LIMITED_INFORMATION = 0x1000'i32
    let processHandle = openProcess(
      PROCESS_QUERY_LIMITED_INFORMATION,
      0'i32,
      int32(clientPid)
    )
    if processHandle == 0:
      return
    var tokenHandle: WinHandle = 0
    if openProcessToken(WinHandle(processHandle), TOKEN_QUERY_W, addr tokenHandle) == 0:
      discard closeHandleW(WinHandle(processHandle))
      return
    var needed: int32 = 0
    discard getTokenInformation(tokenHandle, TokenUserClass, nil, 0, addr needed)
    if needed <= 0:
      discard closeHandleW(tokenHandle)
      discard closeHandleW(WinHandle(processHandle))
      return
    var buffer = newString(needed)
    if getTokenInformation(
      tokenHandle, TokenUserClass, addr buffer[0], needed, addr needed) != 0:
      # Windows: TOKEN_USER layout is { SID_AND_ATTRIBUTES Sid; }; SID_AND_ATTRIBUTES
      # is { PSID Sid; DWORD Attributes; }. So the first pointer-sized field is
      # a pointer to the SID we want to stringify.
      let sidPtr = cast[ptr pointer](addr buffer[0])[]
      var stringSid: ptr uint16 = nil
      if convertSidToStringSidW(sidPtr, addr stringSid) != 0 and stringSid != nil:
        identity.sid = $cast[WideCString](stringSid)
        discard localFree(stringSid)
    discard closeHandleW(tokenHandle)
    discard closeHandleW(WinHandle(processHandle))

proc peerIdentity*(connection: LocalConnection): PeerIdentity =
  case connection.kind
  of endpointUnixSocket:
    when defined(macosx) or defined(freebsd) or defined(openbsd):
      var uid: Uid
      var gid: Gid
      if getpeereid(connection.socket.getFd(), addr uid, addr gid) == 0:
        return PeerIdentity(
          kind: peerIdentityUser,
          processId: 0'u64,
          userId: uint64(uid),
          groupId: uint64(gid),
          sid: ""
        )
    elif defined(linux):
      var credentials: LinuxPeerCred
      var credentialsLen = SockLen(sizeof(credentials))
      if getsockopt(
        connection.socket.getFd(),
        SOL_SOCKET,
        SoPeerCred,
        addr credentials,
        addr credentialsLen
      ) == 0:
        return PeerIdentity(
          kind: peerIdentityProcess,
          processId: uint64(credentials.pid),
          userId: uint64(credentials.uid),
          groupId: uint64(credentials.gid),
          sid: ""
        )
    PeerIdentity(
      kind: peerIdentityUnavailable,
      processId: 0'u64,
      userId: 0'u64,
      groupId: 0'u64,
      sid: ""
    )
  of endpointNamedPipe:
    when defined(windows):
      result = PeerIdentity(
        kind: peerIdentityUnavailable,
        processId: 0'u64,
        userId: 0'u64,
        groupId: 0'u64,
        sid: ""
      )
      readPeerSidFromHandle(WinHandle(connection.pipeHandle), result)
      return result
    else:
      PeerIdentity(
        kind: peerIdentityUnavailable,
        processId: 0'u64,
        userId: 0'u64,
        groupId: 0'u64,
        sid: ""
      )
  else:
    PeerIdentity(
      kind: peerIdentityUnavailable,
      processId: 0'u64,
      userId: 0'u64,
      groupId: 0'u64,
      sid: ""
    )

proc close*(connection: var LocalConnection) =
  case connection.kind
  of endpointUnixSocket:
    if connection.socket != nil:
      connection.socket.close()
      connection.socket = nil
  of endpointNamedPipe:
    when defined(windows):
      if connection.pipeHandle != 0:
        # Windows: FlushFileBuffers would wait for the client to drain; we
        # only need DisconnectNamedPipe semantics on the server side, but
        # this proc is also called on the client side, where CloseHandle
        # alone is correct. Calling CloseHandle on a disconnected pipe is
        # always safe.
        discard closeHandleW(WinHandle(connection.pipeHandle))
        connection.pipeHandle = 0
    else:
      discard
  else:
    discard

proc close*(listener: var LocalListener) =
  case listener.kind
  of endpointUnixSocket:
    if listener.socket != nil:
      listener.socket.close()
    if listener.endpoint.path.len > 0 and fileExists(listener.endpoint.path):
      removeFile(listener.endpoint.path)
  of endpointNamedPipe:
    when defined(windows):
      if listener.pendingPipeHandle != 0:
        discard closeHandleW(WinHandle(listener.pendingPipeHandle))
        listener.pendingPipeHandle = 0
    else:
      discard
  else:
    discard

when defined(windows):
  proc winReadExact(handle: WinHandle; size: int; data: var string): bool =
    data.setLen(size)
    var offset = 0
    while offset < size:
      var got: int32 = 0
      let want = int32(size - offset)
      let rc = readFile(handle, addr data[offset], want, addr got, nil)
      if rc == 0:
        let err = osLastError().int32
        if err == ERROR_BROKEN_PIPE:
          data.setLen(0)
          return false
        # Windows: any other I/O error is fatal for this connection.
        data.setLen(0)
        return false
      if got <= 0:
        data.setLen(0)
        return false
      offset += int(got)
    true

  proc winWriteAll(handle: WinHandle; data: string): bool =
    if data.len == 0:
      return true
    var offset = 0
    while offset < data.len:
      var wrote: int32 = 0
      let want = int32(data.len - offset)
      let rc = writeFile(handle, unsafeAddr data[offset], want, addr wrote, nil)
      if rc == 0 or wrote <= 0:
        return false
      offset += int(wrote)
    true

proc readExactSocket(socket: Socket; size: int; data: var string): bool =
  data.setLen(0)
  var remaining = size
  while remaining > 0:
    let part = socket.recv(remaining)
    if part.len == 0:
      return false
    data.add(part)
    remaining -= part.len
  true

proc sendFrame*(connection: var LocalConnection; frame: string) =
  case connection.kind
  of endpointUnixSocket:
    connection.socket.send(frame)
  of endpointNamedPipe:
    when defined(windows):
      if not winWriteAll(WinHandle(connection.pipeHandle), frame):
        raiseLastWinError("WriteFile on named pipe failed")
    else:
      raise newException(OSError, "named-pipe send is only supported on Windows")
  else:
    raise newException(OSError, "unsupported RunQuota connection")

proc readExact(connection: var LocalConnection; size: int; data: var string): bool =
  case connection.kind
  of endpointUnixSocket:
    readExactSocket(connection.socket, size, data)
  of endpointNamedPipe:
    when defined(windows):
      winReadExact(WinHandle(connection.pipeHandle), size, data)
    else:
      false
  else:
    false

proc receiveFrame*(connection: var LocalConnection; frame: var RqspFrame;
                   frameDiagnostic: var Diagnostic): bool =
  frameDiagnostic = okDiagnostic()
  var headerBytes: string
  if not connection.readExact(int(RqspHeaderLen), headerBytes):
    return false
  var header: FrameHeader
  if not decodeFrameHeader(headerBytes, header):
    frameDiagnostic = diagnostic(diagProtocol, "invalid RQSP frame header")
    return false
  if header.payloadLen > DefaultMaxFrameBytes:
    frame = RqspFrame(header: header, payload: "")
    frameDiagnostic = diagnostic(
      diagProtocol,
      "RQSP frame exceeds negotiated flow-control limit",
      "max_frame_bytes=" & $DefaultMaxFrameBytes
    )
    return false
  var payload: string
  if not connection.readExact(int(header.payloadLen), payload):
    return false
  frame = RqspFrame(header: header, payload: payload)
  true

proc receiveFrame*(connection: var LocalConnection; frame: var RqspFrame): bool =
  var frameDiagnostic = okDiagnostic()
  connection.receiveFrame(frame, frameDiagnostic)
