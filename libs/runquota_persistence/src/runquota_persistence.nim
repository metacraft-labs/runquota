import runquota_persistence/types

export types

const libraryName* = "runquota_persistence"

proc libraryInfo*(): LibraryInfo =
  LibraryInfo(name: libraryName)
