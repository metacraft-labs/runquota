import runquota_ipc/types

export types

const libraryName* = "runquota_ipc"

proc libraryInfo*(): LibraryInfo =
  LibraryInfo(name: libraryName)
