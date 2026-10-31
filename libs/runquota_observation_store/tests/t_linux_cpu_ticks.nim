## No mocks: /proc/stat is a byte format, and this tests its parser directly.
## Live host capacity and saturation checks remain in t_host_load_reading_invariants.
import std/[os, unittest]
import runquota_observation_store/[cpu_clock_pair, ids]
import runquota_observation_store/linux_cpu_ticks

suite "Linux CPU accounting":
  test "guest time is already included in user and nice":
    let sample = parseLinuxCpuTicks("cpu  100 20 30 400 50 6 7 8 60 10\n")
    check sample.busy == 171
    check sample.idle == 450
    let noGuests = parseLinuxCpuTicks("cpu 100 20 30 400 50 6 7 8 0 0\n")
    check sample == noGuests

  test "older kernels can omit trailing fields":
    let sample = parseLinuxCpuTicks("cpu 100 20 30 400\n")
    check sample.busy == 150
    check sample.idle == 400

  test "only the aggregate line contributes":
    let sample = parseLinuxCpuTicks("cpu 100 20 30 400\ncpu0 100 20 30 400\n")
    check sample.busy == 150
    check sample.idle == 400
    check parseLinuxCpuTicks("cpu0 100 20 30 400\n") == LinuxCpuTicks()

when defined(linux):
  proc realCpuCounters(): CpuCounters =
    let cpu = parseLinuxCpuTicks(readFile("/proc/stat"))
    CpuCounters(available: cpu.busy + cpu.idle > 0,
      busyMillis: cpu.busy * 10'i64,
      totalMillis: (cpu.busy + cpu.idle) * 10'i64)

  suite "real CPU counter clock pairing":
    test "a genuine timely kernel read is timestamped inside its call":
      let opened = unixMillisNow()
      let pair = captureCpuClockPair(realCpuCounters)
      let closed = unixMillisNow()
      check pair.available
      check pair.counters.available
      check pair.counters.totalMillis > 0
      check pair.counters.busyMillis >= 0
      check pair.counters.busyMillis <= pair.counters.totalMillis
      check pair.atUnixMillis >= opened
      check pair.atUnixMillis <= closed

    test "every overwide genuine kernel read is refused after the bound":
      # No mock counter or clock: each call reads the live /proc/stat, then
      # an actual sleep holds its return beyond the allowed bracket. This
      # makes the old late-timestamp/accept-last-wide behavior falsifiable
      # without depending on a coincidental scheduler interruption.
      var calls = 0
      let pair = captureCpuClockPair(proc(): CpuCounters =
        inc calls
        result = realCpuCounters()
        sleep(int(cpuClockMaxBracketMillis) + 5))
      check calls == cpuClockBracketAttempts
      check not pair.available
      check not pair.counters.available
      check pair.atUnixMillis == 0
