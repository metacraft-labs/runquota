type
  LibraryInfo* = object
    name*: string
  CodecKind* = enum
    ckSszEnvelope
    ckCborMetadata
    ckInspectionJson
