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
    maxObservedPeakBytes*: uint64
      ## The largest tree peak of a SUCCESSFUL finish whose peak was measured
      ## by the memory cap's own mechanism: what the learned cap multiplies.
      ## Never fed by `ru_maxrss` or tree sampling, which are lower bounds of
      ## another mechanism; never raised by a breach or an OOM kill.
    declaredCapBytes*: uint64
    declaredByUid*: uint64
    declaredUnixMillis*: uint64
      ## A growth declaration (`runquota expect-growth --to`): the cap the
      ## command's next grants carry at least, who declared it (peer
      ## credentials) and when. All 0 when none.
    lastBreachCapBytes*: uint64
    lastBreachPeakBytes*: uint64
    lastBreachUnixMillis*: uint64
      ## The last run that passed its cap: the cap, its peak and the time,
      ## so a report can say "exceeded its cap of N at T". All 0 when none.

  EstimateStore* = ref object
    mode*: PersistenceMode
    dbPath*: string
    queueCapacity*: int
