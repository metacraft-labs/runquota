## The macOS CPU pressure reader: the run queue estimated from the load
## average (`getloadavg(3)`), normalized onto the gate's 0..100 scale, and the
## `--cpu-pressure-file` override read as PSI text exactly as on every other
## platform.
##
## NO MOCKS. The normalization is pure and tested at its boundaries on any
## platform (no mock: it is arithmetic on two numbers). The native reader is
## checked on macOS against the operating system's own `getloadavg`, read
## beside it: the value itself depends on host load and is not pinned, only
## that it is available, in range, and the same function of the load the
## kernel reports. That the signal genuinely rises under contention is a
## load-dependent measurement, recorded in the spec and the milestone, not a
## threshold pinned here.

import std/[os, strutils, tempfiles, unittest]

import runquota_daemon/cpu_pressure

when defined(macosx):
  import std/cpuinfo

  proc getloadavg(loadavg: ptr cdouble; nelem: cint): cint
    {.importc: "getloadavg", header: "<stdlib.h>".}

proc writePsi(path: string; pct: float64) =
  writeFile(path, "some avg10=" & formatFloat(pct, ffDecimal, 2) &
    " avg60=0.00 avg300=0.00 total=0\n" &
    "full avg10=0.00 avg60=0.00 avg300=0.00 total=0\n")

suite "run-queue pressure from the load average":

  test "a load at or below the core count is an empty queue":
    for load in [0.0, 1.0, 8.0, 16.0]:
      let s = queuePressureFromLoad(load, 16)
      check s.available
      check s.someAvg10Pct == 0.0

  test "one waiting thread per core reads the default close point":
    # 16 cores, 32 threads running or ready: 16 wait, one per core.
    let s = queuePressureFromLoad(32.0, 16)
    check s.available
    check abs(s.someAvg10Pct - DefaultPressureHighPct) < 1e-9
    # Half that reads the default reopen point.
    check abs(queuePressureFromLoad(24.0, 16).someAvg10Pct -
      DefaultPressureLowPct) < 1e-9

  test "the scale ties the shared defaults to the queue":
    check QueuePressureScale == DefaultPressureHighPct

  test "the reading is clamped to 100":
    check queuePressureFromLoad(10_000.0, 16).someAvg10Pct == 100.0

  test "an impossible load or core count is unavailable, never a number":
    check not queuePressureFromLoad(-1.0, 16).available
    check not queuePressureFromLoad(0.0 / 0.0, 16).available
    check not queuePressureFromLoad(1.0e300, 16).available
    check "range" in queuePressureFromLoad(-1.0, 16).detail
    check not queuePressureFromLoad(5.0, 0).available
    check "processors" in queuePressureFromLoad(5.0, 0).detail

suite "the macOS CPU pressure source":

  test "a --cpu-pressure-file override is read as PSI text":
    let dir = createTempDir("rqpsi", "")
    defer: removeDir(dir)
    let path = dir / "psi"
    writePsi(path, 42.0)
    let sample = readCpuPressure(path)
    check sample.available
    check sample.someAvg10Pct == 42.0
    writePsi(path, 3.0)
    check readCpuPressure(path).someAvg10Pct == 3.0

  test "a malformed or missing override file is unavailable, with a reason":
    let dir = createTempDir("rqpsi", "")
    defer: removeDir(dir)
    let gone = readCpuPressure(dir / "nope")
    check not gone.available
    check "cannot read" in gone.detail
    let bad = dir / "bad"
    writeFile(bad, "some avg10=not-a-number avg60=0 avg300=0 total=0\n")
    check not readCpuPressure(bad).available
    let high = dir / "high"
    writeFile(high, "some avg10=250.00 avg60=0 avg300=0 total=0\n")
    check not readCpuPressure(high).available

  when defined(macosx):
    test "with no override the reader answers from the load average, in range":
      # The default path names no file on macOS (there is no
      # /proc/pressure/cpu); it must go to getloadavg, not fail to read a file.
      let cores = max(1, countProcessors())
      var matched = false
      var last = ""
      # The load average moves only when the kernel samples it (every few
      # seconds); two reads beside each other agree unless one straddles a
      # sample, so a straddle is retried rather than the comparison loosened.
      for _ in 0 ..< 5:
        var avg: array[3, cdouble]
        check getloadavg(addr avg[0], 1) >= 1
        let expected = queuePressureFromLoad(float64(avg[0]), cores)
        let sample = readCpuPressure(DefaultCpuPressureFile)
        check sample.available
        check sample.someAvg10Pct >= 0.0 and sample.someAvg10Pct <= 100.0
        last = "load " & $avg[0] & " cores " & $cores & " read " &
          $sample.someAvg10Pct & " expected " & $expected.someAvg10Pct
        if sample.someAvg10Pct == expected.someAvg10Pct:
          matched = true
          break
        sleep(50)
      checkpoint last
      check matched
      echo "native run-queue pressure now: ", last
