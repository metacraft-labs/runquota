## Parse the host aggregate in /proc/stat. Guest counters overlap user/nice;
## summing them again overstates both capacity and busy time on VM hosts.
import std/strutils

type LinuxCpuTicks* = object
  busy*, idle*: int64

func parseLinuxCpuTicks*(text: string): LinuxCpuTicks =
  for line in text.splitLines():
    let fields = line.splitWhitespace()
    if fields.len < 5 or fields[0] != "cpu": continue
    # user nice system idle iowait irq softirq steal. The remaining guest
    # and guest_nice counters are already included in user and nice.
    for i in 1 .. min(8, fields.high):
      let value =
        try: parseBiggestInt(fields[i])
        except ValueError: 0'i64
      if i == 4 or i == 5: result.idle += value
      else: result.busy += value
    return
