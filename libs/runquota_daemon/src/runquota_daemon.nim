import runquota_daemon/types

export types

const libraryName* = "runquota_daemon"

proc libraryInfo*(): LibraryInfo =
  LibraryInfo(name: libraryName)
