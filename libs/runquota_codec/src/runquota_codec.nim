import std/strutils

import runquota_codec/types
import runquota_core

export types

const libraryName* = "runquota_codec"
const EnvelopeMagic* = "RQEN"
const EnvelopeVersion* = 1'u16
const MaxInspectionJsonBytes* = 1_048_576'u32

proc libraryInfo*(): LibraryInfo =
  LibraryInfo(name: libraryName)

proc metadataNone*(): DynamicMetadata =
  DynamicMetadata(kind: metadataNone, bytes: "")

proc cborMetadataPlaceholder*(bytes: string): DynamicMetadata =
  DynamicMetadata(kind: metadataCborPlaceholder, bytes: bytes)

proc writer*(): BinaryWriter =
  BinaryWriter(data: "")

proc reader*(data: string): BinaryReader =
  BinaryReader(data: data, pos: 0, error: codecOk)

proc remaining*(r: BinaryReader): int =
  r.data.len - r.pos

proc failed*(r: BinaryReader): bool =
  r.error != codecOk

proc writeU8*(w: var BinaryWriter; value: uint8) =
  w.data.add(char(value))

proc writeU16*(w: var BinaryWriter; value: uint16) =
  w.data.add(char(value and 0xff'u16))
  w.data.add(char((value shr 8) and 0xff'u16))

proc writeU32*(w: var BinaryWriter; value: uint32) =
  for shift in countup(0, 24, 8):
    w.data.add(char((value shr uint32(shift)) and 0xff'u32))

proc writeU64*(w: var BinaryWriter; value: uint64) =
  for shift in countup(0, 56, 8):
    w.data.add(char((value shr uint64(shift)) and 0xff'u64))

proc writeBool*(w: var BinaryWriter; value: bool) =
  w.writeU8(if value: 1'u8 else: 0'u8)

proc writeBytes*(w: var BinaryWriter; value: string) =
  w.writeU32(uint32(value.len))
  w.data.add(value)

proc writeString*(w: var BinaryWriter; value: string) =
  w.writeBytes(value)

proc requireBytes(r: var BinaryReader; count: int): bool =
  if r.error != codecOk:
    return false
  if count < 0 or r.pos + count > r.data.len:
    r.error = codecShortRead
    return false
  true

proc readU8*(r: var BinaryReader; value: var uint8): bool =
  if not r.requireBytes(1):
    return false
  value = uint8(ord(r.data[r.pos]))
  inc r.pos
  true

proc readU16*(r: var BinaryReader; value: var uint16): bool =
  if not r.requireBytes(2):
    return false
  value = uint16(ord(r.data[r.pos])) or
    (uint16(ord(r.data[r.pos + 1])) shl 8)
  inc r.pos, 2
  true

proc readU32*(r: var BinaryReader; value: var uint32): bool =
  if not r.requireBytes(4):
    return false
  value = 0'u32
  for i in 0 ..< 4:
    value = value or (uint32(ord(r.data[r.pos + i])) shl uint32(i * 8))
  inc r.pos, 4
  true

proc readU64*(r: var BinaryReader; value: var uint64): bool =
  if not r.requireBytes(8):
    return false
  value = 0'u64
  for i in 0 ..< 8:
    value = value or (uint64(ord(r.data[r.pos + i])) shl uint64(i * 8))
  inc r.pos, 8
  true

proc readBool*(r: var BinaryReader; value: var bool): bool =
  var raw: uint8
  if not r.readU8(raw):
    return false
  value = raw != 0
  true

proc readBytes*(r: var BinaryReader; value: var string): bool =
  var length: uint32
  if not r.readU32(length):
    return false
  if not r.requireBytes(int(length)):
    return false
  value = r.data.substr(r.pos, r.pos + int(length) - 1)
  inc r.pos, int(length)
  true

proc readString*(r: var BinaryReader; value: var string): bool =
  r.readBytes(value)

proc writeResourceVector*(w: var BinaryWriter; resources: ResourceVector) =
  w.writeU32(resources.cpu.value)
  w.writeU64(resources.memory.value)
  w.writeU64(resources.hardMemoryLimit.value)
  w.writeU32(uint32(ord(resources.ioClass)))
  w.writeU32(resources.processCount)
  w.writeU32(uint32(resources.namedPools.len))
  for demand in resources.namedPools:
    w.writeString(demand.name)
    w.writeU32(demand.units)

proc readResourceVector*(r: var BinaryReader; resources: var ResourceVector): bool =
  var cpu: uint32
  var memory: uint64
  var hardLimit: uint64
  var ioRaw: uint32
  var processCount: uint32
  var namedPoolCount: uint32
  if not r.readU32(cpu): return false
  if not r.readU64(memory): return false
  if not r.readU64(hardLimit): return false
  if not r.readU32(ioRaw): return false
  if ioRaw > uint32(ord(high(IoClass))):
    r.error = codecUnknownTag
    return false
  if not r.readU32(processCount): return false
  if not r.readU32(namedPoolCount): return false
  var namedPools: seq[NamedPoolDemand] = @[]
  for _ in 0 ..< namedPoolCount:
    var name: string
    var units: uint32
    if not r.readString(name): return false
    if not r.readU32(units): return false
    namedPools.add(NamedPoolDemand(name: name, units: units))
  resources = ResourceVector(
    cpu: MilliCpu(cpu),
    memory: Bytes(memory),
    hardMemoryLimit: Bytes(hardLimit),
    ioClass: IoClass(ioRaw),
    processCount: processCount,
    namedPools: namedPools
  )
  true

proc writeDeadline*(w: var BinaryWriter; deadline: Deadline) =
  w.writeU32(uint32(ord(deadline.kind)))
  w.writeU64(deadline.millis.value)

proc readDeadline*(r: var BinaryReader; deadline: var Deadline): bool =
  var kindRaw: uint32
  var millis: uint64
  if not r.readU32(kindRaw): return false
  if kindRaw > uint32(ord(high(DeadlineKind))):
    r.error = codecUnknownTag
    return false
  if not r.readU64(millis): return false
  deadline = Deadline(kind: DeadlineKind(kindRaw), millis: DeadlineMillis(millis))
  true

proc writeDiagnostic*(w: var BinaryWriter; diagnostic: Diagnostic) =
  w.writeU32(uint32(ord(diagnostic.code)))
  w.writeString(diagnostic.message)
  w.writeString(diagnostic.detail)

proc readDiagnostic*(r: var BinaryReader; diagnostic: var Diagnostic): bool =
  var codeRaw: uint32
  var message: string
  var detail: string
  if not r.readU32(codeRaw): return false
  if codeRaw > uint32(ord(high(DiagnosticCode))):
    r.error = codecUnknownTag
    return false
  if not r.readString(message): return false
  if not r.readString(detail): return false
  diagnostic = Diagnostic(code: DiagnosticCode(codeRaw), message: message, detail: detail)
  true

proc writeCapabilities*(w: var BinaryWriter; caps: CapabilityRecord) =
  w.writeU16(caps.protocolMajor)
  w.writeU16(caps.protocolMinor)
  w.writeString(caps.platform)
  w.writeString(caps.transport)
  w.writeU32(caps.maxFrameBytes)
  w.writeU32(caps.maxInflightRequests)
  w.writeU32(caps.cpuSlots.value)
  w.writeU64(caps.memoryBytes.value)
  w.writeBool(caps.hardMemoryLimitEnforced)
  w.writeU32(uint32(ord(caps.hardMemoryLimitMode)))
  w.writeBool(caps.processTelemetry)
  w.writeBool(caps.memoryPressureAvailable)
  w.writeBool(caps.memoryPressureRequired)

proc readCapabilities*(r: var BinaryReader; caps: var CapabilityRecord): bool =
  var protocolMajor: uint16
  var protocolMinor: uint16
  var platform: string
  var transport: string
  var maxFrameBytes: uint32
  var maxInflightRequests: uint32
  var cpuSlots: uint32
  var memoryBytes: uint64
  var hardMemoryLimitEnforced: bool
  var hardMemoryLimitModeRaw: uint32
  var processTelemetry: bool
  var memoryPressureAvailable: bool
  var memoryPressureRequired: bool
  if not r.readU16(protocolMajor): return false
  if not r.readU16(protocolMinor): return false
  if not r.readString(platform): return false
  if not r.readString(transport): return false
  if not r.readU32(maxFrameBytes): return false
  if not r.readU32(maxInflightRequests): return false
  if not r.readU32(cpuSlots): return false
  if not r.readU64(memoryBytes): return false
  if not r.readBool(hardMemoryLimitEnforced): return false
  if not r.readU32(hardMemoryLimitModeRaw): return false
  if hardMemoryLimitModeRaw > uint32(ord(high(MemoryLimitMode))):
    r.error = codecUnknownTag
    return false
  if not r.readBool(processTelemetry): return false
  if not r.readBool(memoryPressureAvailable): return false
  if not r.readBool(memoryPressureRequired): return false
  caps = CapabilityRecord(
    protocolMajor: protocolMajor,
    protocolMinor: protocolMinor,
    platform: platform,
    transport: transport,
    maxFrameBytes: maxFrameBytes,
    maxInflightRequests: maxInflightRequests,
    cpuSlots: MilliCpu(cpuSlots),
    memoryBytes: Bytes(memoryBytes),
    hardMemoryLimitEnforced: hardMemoryLimitEnforced,
    hardMemoryLimitMode: MemoryLimitMode(hardMemoryLimitModeRaw),
    processTelemetry: processTelemetry,
    memoryPressureAvailable: memoryPressureAvailable,
    memoryPressureRequired: memoryPressureRequired
  )
  true

proc writeMetadata*(w: var BinaryWriter; metadata: DynamicMetadata) =
  w.writeU32(uint32(ord(metadata.kind)))
  w.writeBytes(metadata.bytes)

proc readMetadata*(r: var BinaryReader; metadata: var DynamicMetadata): bool =
  var kindRaw: uint32
  var bytes: string
  if not r.readU32(kindRaw): return false
  if kindRaw > uint32(ord(high(DynamicMetadataKind))):
    r.error = codecUnknownTag
    return false
  if not r.readBytes(bytes): return false
  metadata = DynamicMetadata(kind: DynamicMetadataKind(kindRaw), bytes: bytes)
  true

proc encodeEnvelope*(envelope: BinaryEnvelope): string =
  var w = writer()
  w.data.add(EnvelopeMagic)
  w.writeU16(EnvelopeVersion)
  w.writeU16(uint16(ord(envelope.tag)))
  w.writeU16(envelope.version)
  w.writeMetadata(envelope.metadata)
  w.writeBytes(envelope.payload)
  w.data

proc decodeEnvelope*(data: string; envelope: var BinaryEnvelope): CodecError =
  if data.len < EnvelopeMagic.len:
    return codecShortRead
  if data.substr(0, EnvelopeMagic.len - 1) != EnvelopeMagic:
    return codecBadMagic
  var r = reader(data.substr(EnvelopeMagic.len))
  var version: uint16
  var tagRaw: uint16
  var schemaVersion: uint16
  var metadata: DynamicMetadata
  var payload: string
  if not r.readU16(version): return r.error
  if version != EnvelopeVersion: return codecBadVersion
  if not r.readU16(tagRaw): return r.error
  if tagRaw < uint16(ord(low(EnvelopeTag))) or tagRaw > uint16(ord(high(EnvelopeTag))):
    return codecUnknownTag
  if not r.readU16(schemaVersion): return r.error
  if not r.readMetadata(metadata): return r.error
  if not r.readBytes(payload): return r.error
  if r.remaining != 0: return codecBadLength
  envelope = BinaryEnvelope(
    tag: EnvelopeTag(tagRaw),
    version: schemaVersion,
    metadata: metadata,
    payload: payload
  )
  codecOk

proc jsonEscape*(value: string): string =
  result = "\""
  for ch in value:
    case ch
    of '"': result.add("\\\"")
    of '\\': result.add("\\\\")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    else:
      if ord(ch) < 32:
        result.add("\\u")
        result.add(toHex(ord(ch), 4))
      else:
        result.add(ch)
  result.add('"')

proc inspectionResourceJson*(resources: ResourceVector): string =
  var namedPools = "["
  for i, demand in resources.namedPools:
    if i > 0:
      namedPools.add(",")
    namedPools.add("{\"name\":" & jsonEscape(demand.name) & ",\"units\":" & $demand.units & "}")
  namedPools.add("]")
  "{" &
    "\"cpu_milli\":" & $resources.cpu.value & "," &
    "\"memory_bytes\":" & $resources.memory.value & "," &
    "\"hard_memory_limit_bytes\":" & $resources.hardMemoryLimit.value & "," &
    "\"io_class\":" & jsonEscape($resources.ioClass) & "," &
    "\"process_count\":" & $resources.processCount & "," &
    "\"named_pools\":" & namedPools &
  "}"

proc inspectionDiagnosticJson*(diagnostic: Diagnostic): string =
  "{" &
    "\"code\":" & jsonEscape($diagnostic.code) & "," &
    "\"message\":" & jsonEscape(diagnostic.message) & "," &
    "\"detail\":" & jsonEscape(diagnostic.detail) &
  "}"

proc inspectionCapabilitiesJson*(caps: CapabilityRecord): string =
  "{" &
    "\"protocol_major\":" & $caps.protocolMajor & "," &
    "\"protocol_minor\":" & $caps.protocolMinor & "," &
    "\"platform\":" & jsonEscape(caps.platform) & "," &
    "\"transport\":" & jsonEscape(caps.transport) & "," &
    "\"max_frame_bytes\":" & $caps.maxFrameBytes & "," &
    "\"max_inflight_requests\":" & $caps.maxInflightRequests & "," &
    "\"cpu_milli\":" & $caps.cpuSlots.value & "," &
    "\"memory_bytes\":" & $caps.memoryBytes.value & "," &
    "\"hard_memory_limit_enforced\":" & $caps.hardMemoryLimitEnforced & "," &
    "\"process_telemetry\":" & $caps.processTelemetry &
  "}"
