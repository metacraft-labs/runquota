import runquota_host_macos/types

export types

const libraryName* = "runquota_host_macos"

proc libraryInfo*(): LibraryInfo =
  LibraryInfo(name: libraryName)
