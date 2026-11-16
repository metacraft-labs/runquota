## The daemon's build-wait pressure aggregation, as pure functions of the
## reports fed to it and the clock passed in: how reports are clamped, how
## the decaying averages behave, and how waits are binned and counted as
## long.
##
## WHY AN INJECTED CLOCK. The long-wait case is a request held for 310 s,
## and the averages are defined over 10 to 300 s; reproducing either in
## real time would make the suite minutes longer and still only sample the
## clock at the moments the host scheduled the test. The module takes the
## monotonic time as a parameter (the daemon passes its own), so the test
## states the times exactly. The real daemon, real sockets and a real
## queued `runquota run` are exercised in
## `tests/integration/t_build_wait_pressure`.
##
## WHAT IS GUARDED, and the mutation each check fails under:
##
## * A wait of 310 s counts as long for its group and for the host; one of
##   299.999 s does not, and one of exactly 300 s does. Mutations: compare
##   with `>` instead of `>=`, or count long waits on the host only, and a
##   check fails.
## * A wait is no longer than the session that reports it has existed:
##   a 310 s wait from a session 10 s old is counted as 11 s (the slack).
##   Mutation: drop the clamp, and it is counted as long.
## * The averages converge to the held-up rate: reports every second of
##   0.4 s held up converge on 0.4 in every window. Mutation: add each
##   report's held-up time without spreading it over the time it covers
##   (weight 1 instead of (W/c)(1-exp(-c/W))), and the 10 s average of a
##   report covering 60 s is six times too high.
## * Some is clamped to the wall time and full to some, saturating.
##   Mutation: drop either clamp.
## * The wall-time budget is cumulative over a session's reports: a
##   thousand reports from a 2 s old session are credited 3 s in all.
##   Mutation: grant the budget per report (ignore what was credited), and
##   the session is credited 3000 s.

import std/[math, strutils, tables, unittest]

import runquota_daemon/capacity_metrics
import runquota_daemon/pressure_metrics

proc near(a, b, tolerance: float64): bool = abs(a - b) <= tolerance

suite "long waits":
  test "a request held 310 s increments the over-300-s counter for its group and host":
    var ledger = CapacityLedger()
    let key = "1000/agent-a"
    ledger.touchGroup(key, 0)
    let now = 400_000'i64
    let sample = clampReport(1_000_000, 0, 0, elapsedLimitMicros(1000), true)
    ledger.notePressureReport(key, sample, now)
    # The session has existed for 400 s, so the 310 s wait stands.
    let length = clampWaitMillis(310_000, 400_000)
    check length == 310_000
    ledger.notePressureWait(key, 0, length, DefaultLongWaitMillis)
    check ledger.hostPressure.waits[0].longWaits == 1
    check ledger.groups[key].pressure.waits[0].longWaits == 1
    check ledger.groups[key].pressure.waits[0].count == 1
    # The 300 s bucket holds it no more: it is in the 600 s one.
    check ledger.groups[key].pressure.waits[0].buckets[7] == 0
    check ledger.groups[key].pressure.waits[0].buckets[8] == 1

  test "a wait just under the threshold is not long":
    var figures = PressureFigures()
    figures.noteWait(0, 299_999, DefaultLongWaitMillis)
    check figures.waits[0].longWaits == 0
    figures.noteWait(0, 300_000, DefaultLongWaitMillis)
    check figures.waits[0].longWaits == 1

  test "a wait longer than its session's life is cut to that life":
    check clampWaitMillis(310_000, 10_000) == 11_000
    var figures = PressureFigures()
    figures.noteWait(0, clampWaitMillis(310_000, 10_000), DefaultLongWaitMillis)
    check figures.waits[0].longWaits == 0

suite "clamping and saturation":
  test "some is clamped to wall and full to some":
    let s = clampReport(5_000_000, 9_000_000, 9_500_000, 10_000_000, false)
    check s.wallMicros == 5_000_000
    check s.someMicros == 5_000_000
    check s.fullMicros == 5_000_000
    let t = clampReport(5_000_000, 2_000_000, 3_000_000, 10_000_000, false)
    check t.someMicros == 2_000_000
    check t.fullMicros == 2_000_000

  test "wall is clamped to what the session may still claim":
    let s = clampReport(high(uint64), high(uint64), high(uint64),
      elapsedLimitMicros(2_000), false)
    check s.wallMicros == 3_000_000

  test "the wall budget is cumulative: many reports earn the slack once":
    # A session 2 s old that sends report after report claiming far more
    # than it has lived is credited with its age plus one second in all,
    # not plus one second per report.
    var credited = 0'u64
    for i in 0 ..< 1000:
      let s = clampReport(high(uint64), high(uint64), high(uint64),
        remainingWallMicros(2_000, credited), false)
      credited += s.wallMicros
    check credited == 3_000_000
    check remainingWallMicros(2_000, credited) == 0
    # An honest client that claimed less keeps the rest for later.
    check remainingWallMicros(5_000, 1_000_000) == 5_000_000

  test "totals saturate instead of wrapping":
    var figures = PressureFigures()
    let big = PressureSample(wallMicros: high(uint64) - 10,
      someMicros: high(uint64) - 10, fullMicros: high(uint64) - 10)
    figures.noteReport(big, 1)
    figures.noteReport(big, 2)
    check figures.wallMicros == high(uint64)
    check figures.someMicros == high(uint64)
    for i in 0 ..< 3:
      figures.noteWait(1, high(uint64) div 2, DefaultLongWaitMillis)
    check figures.waits[1].sumMillis == high(uint64)

suite "decaying averages":
  test "reports at a steady held-up rate converge on that rate":
    var figures = PressureFigures()
    var now = 1_000'i64
    for i in 0 ..< 1500:
      now += 1000
      figures.noteReport(PressureSample(wallMicros: 1_000_000,
        someMicros: 400_000, fullMicros: 100_000), now)
    let some = figures.some.averages(now)
    let full = figures.full.averages(now)
    for i in 0 ..< PressureWindowsSeconds.len:
      check near(some[i], 0.4, 0.01)
      check near(full[i], 0.1, 0.01)

  test "a report covering a long stretch is spread over it, not a spike":
    var figures = PressureFigures()
    # One report covering 60 s, all of it held up.
    figures.noteReport(PressureSample(wallMicros: 60_000_000,
      someMicros: 60_000_000, fullMicros: 60_000_000), 100_000)
    let avg = figures.some.averages(100_000)
    # Spread over 60 s, the 10 s window sees about its last 10 s held up.
    check near(avg[0], 1.0, 0.01)
    check avg[0] <= 1.0 + 1e-9
    # The 300 s window: (1 - exp(-60/300)) of a full window.
    check near(avg[2], 1.0 - exp(-60.0 / 300.0), 0.01)

  test "averages decay when nothing is reported":
    var figures = PressureFigures()
    figures.noteReport(PressureSample(wallMicros: 10_000_000,
      someMicros: 10_000_000, fullMicros: 0), 50_000)
    let early = figures.some.averages(50_000)
    let late = figures.some.averages(50_000 + 30_000)
    check late[0] < early[0] * exp(-3.0) + 1e-9
    check late[2] > 0.0

suite "rendering":
  test "the JSON carries cumulative buckets ending in +Inf":
    var figures = PressureFigures()
    figures.noteReport(PressureSample(wallMicros: 1_000_000), 10)
    figures.noteWait(0, 1500, DefaultLongWaitMillis)
    figures.noteWait(0, 310_000, DefaultLongWaitMillis)
    let text = "{" & pressureFiguresJson(figures, 10) & "}"
    check "\"le_seconds\":2,\"count\":1" in text
    check "\"le_seconds\":\"+Inf\",\"count\":2" in text
    check "\"long_waits\":1" in text
