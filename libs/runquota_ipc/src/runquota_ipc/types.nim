import std/[net, nativesockets]

# Windows: avoid pulling in std/winlean from this very small types module;
# the public API only needs to expose a discriminated union, and the actual
# Windows handle representation lives in runquota_ipc.nim where we already
# import the necessary headers.

type
  LibraryInfo* = object
    name*: string

  EndpointKind* = enum
    endpointUnsupported
    endpointUnixSocket
    endpointNamedPipe  # Windows: native local transport per spec.

  PeerIdentityKind* = enum
    peerIdentityUnavailable
    peerIdentityUser
    peerIdentityProcess

  Endpoint* = object
    kind*: EndpointKind
    path*: string
    rendezvousPath*: string
      ## The FILESYSTEM path a named-pipe endpoint was derived from, or ""
      ## when it was named as a pipe outright. A Unix socket IS a filesystem
      ## path, so there it is simply ``path``; a Windows pipe lives in the
      ## kernel object namespace, and without this the directory the caller
      ## named -- where the published stats table lives beside it -- would be
      ## lost the moment the name was mapped onto a pipe.

  PeerIdentity* = object
    kind*: PeerIdentityKind
    processId*: uint64
    userId*: uint64
    groupId*: uint64
    # Windows: the textual SID of the peer when available (empty otherwise).
    sid*: string

  AcceptedConnection* = object
    case kind*: EndpointKind
    of endpointUnixSocket:
      handle*: SocketHandle
    of endpointNamedPipe:
      # Windows: the just-connected named-pipe instance, stored as an int so
      # this header does not need to depend on Windows-specific aliases.
      pipeHandle*: int
    else:
      discard

  LocalConnection* = object
    endpoint*: Endpoint
    case kind*: EndpointKind
    of endpointUnixSocket:
      socket*: Socket
    of endpointNamedPipe:
      # Windows: the active named-pipe handle for this connection.
      pipeHandle*: int
    else:
      discard

  LocalListener* = object
    endpoint*: Endpoint
    case kind*: EndpointKind
    of endpointUnixSocket:
      socket*: Socket
    of endpointNamedPipe:
      # Windows: name we listen on; each accept creates a fresh pipe instance.
      # The currently pre-created (but not yet ConnectClient-returned) instance
      # is parked here so accept can ConnectNamedPipe on it before pre-creating
      # the next one.
      pendingPipeHandle*: int
    else:
      discard
