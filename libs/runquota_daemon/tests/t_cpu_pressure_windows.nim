## The Windows CPU pressure reader: the `--cpu-pressure-file` override reads a
## PSI-format file here as on every other platform, and with no override the
## native `\System\Processor Queue Length` reader (PDH) supplies a value in the
## same 0..100 units to the same gate.
##
## These checks are DETERMINISTIC and CI-safe: the file-override cases pin the
## pure parse, and the native-reader case asserts only that the PDH path
## produces an available, in-range reading -- not a particular value, which
## depends on the host's load. That the native reading genuinely RISES under
## contention is a load-dependent measurement, taken by hand and recorded in
## the spec amendment and the milestone note rather than pinned here, where a
## contention threshold would be flaky.

when defined(windows):
  import std/[os, strutils, tempfiles, unittest]

  import runquota_daemon/cpu_pressure

  proc writePsi(path: string; pct: float64) =
    writeFile(path, "some avg10=" & formatFloat(pct, ffDecimal, 2) &
      " avg60=0.00 avg300=0.00 total=0\n" &
      "full avg10=0.00 avg60=0.00 avg300=0.00 total=0\n")

  suite "windows cpu pressure reader":

    test "a --cpu-pressure-file override is read as PSI text on Windows":
      # The same injection every other platform's tests use: the file-reading
      # path is pure, portable text and is no longer excluded on Windows.
      let dir = createTempDir("rqpsi", "")
      defer: removeDir(dir)
      let path = dir / "psi"
      writePsi(path, 42.0)
      let sample = readCpuPressure(path)
      check sample.available
      check sample.someAvg10Pct == 42.0
      # A fresh value is read each time, so a test can move the gate.
      writePsi(path, 3.0)
      check readCpuPressure(path).someAvg10Pct == 3.0

    test "a malformed or missing override file is unavailable, with a reason":
      let dir = createTempDir("rqpsi", "")
      defer: removeDir(dir)
      let missing = dir / "nope"
      let gone = readCpuPressure(missing)
      check not gone.available
      check "cannot read" in gone.detail
      let bad = dir / "bad"
      writeFile(bad, "some avg10=not-a-number avg60=0 avg300=0 total=0\n")
      check not readCpuPressure(bad).available
      let high = dir / "high"
      writeFile(high, "some avg10=250.00 avg60=0 avg300=0 total=0\n")
      check not readCpuPressure(high).available

    test "with no override the native PDH reader answers, in range":
      # The production default: the default path is a sentinel (there is no
      # `/proc/pressure/cpu` to read on Windows), so the reader goes to PDH
      # rather than failing to read a file. The value depends on host load;
      # only availability and range are deterministic.
      let sample = readCpuPressure(DefaultCpuPressureFile)
      check sample.available
      check sample.someAvg10Pct >= 0.0
      check sample.someAvg10Pct <= 100.0
      checkpoint "native queue-length pressure now: " &
        formatFloat(sample.someAvg10Pct, ffDecimal, 2)

    test "the normalization scale ties the shared defaults to the queue":
      # Documents the chosen scale next to the thresholds it is designed for:
      # one ready thread per core reads exactly the default close point, and
      # half that the default reopen point.
      check WindowsQueuePressureScale == DefaultPressureHighPct
      check WindowsQueuePressureScale / 2.0 == DefaultPressureLowPct
else:
  echo "t_cpu_pressure_windows: Windows only"
