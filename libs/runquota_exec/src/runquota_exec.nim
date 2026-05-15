import runquota_exec/types

export types

const libraryName* = "runquota_exec"

proc libraryInfo*(): LibraryInfo =
  LibraryInfo(name: libraryName)
