import std/net

type
  LibraryInfo* = object
    name*: string

  EndpointKind* = enum
    endpointUnsupported
    endpointUnixSocket

  Endpoint* = object
    kind*: EndpointKind
    path*: string

  LocalConnection* = object
    socket*: Socket
    endpoint*: Endpoint

  LocalListener* = object
    socket*: Socket
    endpoint*: Endpoint
