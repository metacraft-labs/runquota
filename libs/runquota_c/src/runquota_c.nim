import runquota_c/types

export types

const libraryName* = "runquota_c"

proc libraryInfo*(): LibraryInfo =
  LibraryInfo(name: libraryName)
