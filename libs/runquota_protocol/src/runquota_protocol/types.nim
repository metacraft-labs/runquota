type
  LibraryInfo* = object
    name*: string
  MessageKind* = enum
    mkHello
    mkSession
    mkLease
    mkTelemetry
