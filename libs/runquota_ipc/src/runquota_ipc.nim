import std/[net, os]

when defined(posix):
  import std/posix

import runquota_ipc/types as ipcTypes
import runquota_protocol

export ipcTypes

const libraryName* = "runquota_ipc"

proc libraryInfo*(): ipcTypes.LibraryInfo =
  ipcTypes.LibraryInfo(name: libraryName)

proc unixEndpoint*(path: string): Endpoint =
  Endpoint(kind: endpointUnixSocket, path: path)

proc defaultEndpoint*(): Endpoint =
  let overridePath = getEnv("RUNQUOTA_SOCKET")
  if overridePath.len > 0:
    return unixEndpoint(overridePath)
  when defined(posix):
    let base = getEnv("XDG_RUNTIME_DIR", getEnv("TMPDIR", getTempDir()))
    let dir = base / ("runquota-" & $getuid())
    unixEndpoint(dir / "runquotad.sock")
  else:
    Endpoint(kind: endpointUnsupported, path: "")

proc ensureEndpointDir*(endpoint: Endpoint) =
  if endpoint.path.len > 0:
    createDir(parentDir(endpoint.path))

proc connectEndpoint*(endpoint: Endpoint): LocalConnection =
  if endpoint.kind != endpointUnixSocket:
    raise newException(OSError, "unsupported RunQuota endpoint")
  var socket = newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_NONE)
  socket.connectUnix(endpoint.path)
  LocalConnection(socket: socket, endpoint: endpoint)

proc connectDefault*(): LocalConnection =
  connectEndpoint(defaultEndpoint())

proc bindEndpoint*(endpoint: Endpoint): LocalListener =
  if endpoint.kind != endpointUnixSocket:
    raise newException(OSError, "unsupported RunQuota endpoint")
  ensureEndpointDir(endpoint)
  if fileExists(endpoint.path):
    removeFile(endpoint.path)
  var socket = newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_NONE)
  socket.bindUnix(endpoint.path)
  socket.listen()
  LocalListener(socket: socket, endpoint: endpoint)

proc acceptConnection*(listener: var LocalListener): LocalConnection =
  var client: owned(Socket)
  listener.socket.accept(client)
  LocalConnection(socket: client, endpoint: listener.endpoint)

proc close*(connection: var LocalConnection) =
  if connection.socket != nil:
    connection.socket.close()

proc close*(listener: var LocalListener) =
  if listener.socket != nil:
    listener.socket.close()
  if listener.endpoint.kind == endpointUnixSocket and fileExists(listener.endpoint.path):
    removeFile(listener.endpoint.path)

proc readExact(socket: Socket; size: int; data: var string): bool =
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
  connection.socket.send(frame)

proc receiveFrame*(connection: var LocalConnection; frame: var RqspFrame): bool =
  var headerBytes: string
  if not readExact(connection.socket, int(RqspHeaderLen), headerBytes):
    return false
  var header: FrameHeader
  if not decodeFrameHeader(headerBytes, header):
    return false
  if header.payloadLen > DefaultMaxFrameBytes:
    return false
  var payload: string
  if not readExact(connection.socket, int(header.payloadLen), payload):
    return false
  frame = RqspFrame(header: header, payload: payload)
  true
