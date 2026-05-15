import runquota_host_linux/types

export types

const libraryName* = "runquota_host_linux"

proc libraryInfo*(): LibraryInfo =
  LibraryInfo(name: libraryName)
