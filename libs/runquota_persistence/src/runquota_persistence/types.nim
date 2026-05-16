type
  LibraryInfo* = object
    name*: string
  PersistenceMode* = enum
    pmInMemory
    pmSqlite

  LearnedEstimateRow* = object
    scope*: string
    commandStatsId*: string
    conservativeMemoryBytes*: uint64
    recentPeakMemoryBytes*: uint64
    sampleCount*: uint32
    lastOutcome*: uint32
    updatedUnixMillis*: uint64

  EstimateStore* = ref object
    mode*: PersistenceMode
    dbPath*: string
    queueCapacity*: int
