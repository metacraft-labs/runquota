## Linux mount identity and block-device classification. Mount sources such
## as /dev/root or UUID aliases are display names; major:minor identifies sysfs.
import std/[os, strutils]
import ./types

type LinuxMount* = tuple[fsType, device, deviceNumber: string]

proc unescapeMount(field: string): string =
  var i = 0
  while i < field.len:
    if field[i] == '\\' and i + 3 < field.len and
        field[i + 1] in {'0'..'7'} and field[i + 2] in {'0'..'7'} and
        field[i + 3] in {'0'..'7'}:
      result.add(char((ord(field[i + 1]) - ord('0')) * 64 +
        (ord(field[i + 2]) - ord('0')) * 8 + ord(field[i + 3]) - ord('0')))
      i += 4
    else:
      result.add(field[i])
      inc i

proc linuxMountForPath*(mountInfo, path: string): LinuxMount =
  result = ("unknown", "", "")
  var bestLength = -1
  for line in mountInfo.splitLines():
    let halves = line.split(" - ", maxsplit = 1)
    if halves.len != 2: continue
    let left = halves[0].splitWhitespace()
    let right = halves[1].splitWhitespace()
    if left.len < 5 or right.len < 2: continue
    let mountPoint = unescapeMount(left[4])
    if path != mountPoint and not path.startsWith(
        if mountPoint.endsWith("/"): mountPoint else: mountPoint & "/"):
      continue
    if mountPoint.len > bestLength:
      bestLength = mountPoint.len
      result = (right[0], unescapeMount(right[1]), left[2])

proc linuxBlockDiskClass*(deviceNumber: string;
    sysDevBlock = "/sys/dev/block"): DiskClass =
  result = dcUnknown
  let numbers = deviceNumber.split(':')
  if numbers.len != 2: return
  for number in numbers:
    if number.len == 0: return
    for digit in number:
      if digit notin {'0'..'9'}: return
  try:
    let link = sysDevBlock / deviceNumber
    if not dirExists(link): return
    var device = expandFilename(link)
    # Partition directories have no queue of their own. The parent device
    # retains its numeric suffix (nvme0n1, mmcblk0, md0), without name guessing.
    if fileExists(device / "partition"):
      device = device.parentDir
    let queue = device / "queue" / "rotational"
    if not fileExists(queue): return
    case readFile(queue).strip()
    of "1": result = dcHdd
    of "0":
      result = if device.extractFilename().startsWith("nvme"): dcNvme else: dcSsd
    else: discard
  except CatchableError:
    discard
