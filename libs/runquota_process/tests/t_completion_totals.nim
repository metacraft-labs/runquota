## The completion totals the launcher gets from `wait4` for a real child:
## CPU time, duration and, the unit-sensitive one, the peak resident set.
##
## WHY THE PEAK IS PINNED HERE. `ru_maxrss` is in KiB on Linux and in BYTES
## on macOS (getrusage(2) on each). A launcher that multiplies by 1024 on
## both reports a macOS child 1024 times larger than it was, and the daemon
## stores that as the command's peak memory -- the figure admission sizes
## the next run with. The child below touches a known amount of memory, so
## the reported peak must land between that amount and a few times it.
## Falsifying mutation: scale `ru_maxrss` by 1024 on macOS (or leave it
## unscaled on Linux) and the peak is off by three orders of magnitude, far
## outside the window.
##
## NO MOCKS: the real launcher, a real child (this binary re-executed), the
## kernel's own accounting. The window is wide on purpose (the allocator and
## the runtime add some resident memory); the bug it catches is 1000x.
import std/[os, strutils, unittest]

import runquota_process

const
  TouchMiB = 192
  AllocateArgument = "--touch-and-burn"

when defined(posix):
  if paramCount() == 1 and paramStr(1) == AllocateArgument:
    var block1 = newSeq[byte](TouchMiB * 1024 * 1024)
    # Touch every page so the memory is resident, not merely mapped.
    for i in countup(0, block1.high, 4096):
      block1[i] = byte(i and 0xff)
    var x = 0'u64
    for i in 0 ..< 60_000_000:
      x = x * 6364136223846793005'u64 + 1442695040888963407'u64
    # Keep the pages and the loop live past the optimiser.
    quit(if (x xor uint64(block1[4096])) == 12345'u64: 3 else: 0)

when defined(posix):
  suite "completion totals":
    test "a child's totals carry its CPU, duration and peak in bytes":
      var child = launchProcess(commandSpec([getAppFilename(),
        AllocateArgument]))
      let completion = child.waitForCompletion(60_000)
      child.close()
      check completion.exited
      check completion.exitCode == 0
      check completion.totals.known
      let touched = uint64(TouchMiB) * 1024'u64 * 1024'u64
      checkpoint "maxRssBytes " & $completion.totals.maxRssBytes
      check completion.totals.maxRssBytes >= touched
      check completion.totals.maxRssBytes <= touched * 4'u64
      # The loop is tens of milliseconds of CPU at the least; the touch of
      # 192 MiB adds system time. Zero would mean the rusage was dropped.
      check completion.totals.cpuUserMicros + completion.totals.cpuSysMicros >
        20_000'u64
      check completion.totals.durationMillis > 0'u64
      check completion.totals.durationMillis < 60_000'u64
