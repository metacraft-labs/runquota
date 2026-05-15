import runquota_host_windows/types

export types

const libraryName* = "runquota_host_windows"

proc libraryInfo*(): LibraryInfo =
  LibraryInfo(name: libraryName)
