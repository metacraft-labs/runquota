## Pair a real host CPU snapshot with its clock reading, or report no sample.
## Other host metrics must not move a CPU snapshot's timestamp. An overwide
## read is not repaired by inventing a midpoint or accepting the last attempt.
import std/[monotimes, times]
import ./ids

const
  cpuClockMaxBracketMillis* = 20'i64
  cpuClockBracketAttempts* = 8

type
  CpuCounters* = object
    available*: bool
    busyMillis*, totalMillis*: int64
  CpuClockPair* = object
    available*: bool
    counters*: CpuCounters
    atUnixMillis*: int64

proc captureCpuClockPair*(readCounters: proc(): CpuCounters {.closure.}): CpuClockPair =
  ## The callback performs the platform's REAL CPU read. Keeping that boundary
  ## explicit also lets a regression control delay a genuine read without
  ## replacing counters, clocks, scheduling identities or availability facts.
  for attempt in 0 ..< cpuClockBracketAttempts:
    let openedMono = getMonoTime()
    let openedWall = unixMillisNow()
    let counters = readCounters()
    let closedWall = unixMillisNow()
    let closedMono = getMonoTime()
    if not counters.available:
      return
    let elapsedNanos = (closedMono - openedMono).inNanoseconds
    let elapsedWall = closedWall - openedWall
    if elapsedNanos >= 0 and
        elapsedNanos <= cpuClockMaxBracketMillis * 1_000_000 and
        elapsedWall >= 0 and elapsedWall <= cpuClockMaxBracketMillis:
      return CpuClockPair(available: true, counters: counters,
        atUnixMillis: closedWall)
  # Explicit refusal on exhaustion: no stale/wide pair becomes a measurement.
  CpuClockPair()
