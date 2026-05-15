type
  LibraryInfo* = object
    name*: string
  ClientState* = enum
    csDisconnected
    csConnected
    csClosed
