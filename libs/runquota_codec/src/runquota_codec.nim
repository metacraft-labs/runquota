import runquota_codec/types

export types

const libraryName* = "runquota_codec"

proc libraryInfo*(): LibraryInfo =
  LibraryInfo(name: libraryName)
