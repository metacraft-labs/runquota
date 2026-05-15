import runquota_process/types

export types

const libraryName* = "runquota_process"

proc libraryInfo*(): LibraryInfo =
  LibraryInfo(name: libraryName)
