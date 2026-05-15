import runquota_client/types

export types

const libraryName* = "runquota_client"

proc libraryInfo*(): LibraryInfo =
  LibraryInfo(name: libraryName)
