import runquota_protocol/types

export types

const libraryName* = "runquota_protocol"

proc libraryInfo*(): LibraryInfo =
  LibraryInfo(name: libraryName)
