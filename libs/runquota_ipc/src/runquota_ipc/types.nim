import std/net

type
  LibraryInfo* = object
    name*: string

  EndpointKind* = enum
    endpointUnsupported
    endpointUnixSocket

  PeerIdentityKind* = enum
    peerIdentityUnavailable
    peerIdentityUser
    peerIdentityProcess

  Endpoint* = object
    kind*: EndpointKind
    path*: string

  PeerIdentity* = object
    kind*: PeerIdentityKind
    processId*: uint64
    userId*: uint64
    groupId*: uint64

  LocalConnection* = object
    socket*: Socket
    endpoint*: Endpoint

  LocalListener* = object
    socket*: Socket
    endpoint*: Endpoint
