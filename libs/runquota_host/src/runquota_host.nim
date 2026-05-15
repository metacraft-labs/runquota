import runquota_host/types

export types

const libraryName* = "runquota_host"

proc libraryInfo*(): LibraryInfo =
  LibraryInfo(name: libraryName)
