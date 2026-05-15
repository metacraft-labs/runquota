import runquota_admission/types

export types

const libraryName* = "runquota_admission"

proc libraryInfo*(): LibraryInfo =
  LibraryInfo(name: libraryName)
