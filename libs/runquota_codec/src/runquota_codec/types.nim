type
  LibraryInfo* = object
    name*: string

  CodecKind* = enum
    ckBinaryEnvelope
    ckSszEnvelope
    ckCborMetadata
    ckInspectionJson

  CodecError* = enum
    codecOk
    codecShortRead
    codecBadMagic
    codecBadVersion
    codecBadLength
    codecUnknownTag

  EnvelopeTag* = enum
    envelopeProtocolPayload = 1
    envelopeInspectionView = 2

  DynamicMetadataKind* = enum
    metadataNone
    metadataCborPlaceholder

  DynamicMetadata* = object
    kind*: DynamicMetadataKind
    bytes*: string

  BinaryEnvelope* = object
    tag*: EnvelopeTag
    version*: uint16
    metadata*: DynamicMetadata
    payload*: string

  BinaryWriter* = object
    data*: string

  BinaryReader* = object
    data*: string
    pos*: int
    error*: CodecError
