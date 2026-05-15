type
  LibraryInfo* = object
    name*: string
  PersistenceMode* = enum
    pmInMemory
    pmSqlite
