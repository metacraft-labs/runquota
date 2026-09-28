## Linux /proc/cpuinfo model identity. ARM64 exposes MIDR fields instead of
## a marketing name. Preserve those facts without maintaining a vendor table.
## Pure parsing keeps architecture-specific inputs testable on every host.

import std/[algorithm, strutils]

proc field(text, key: string): string =
  for line in text.splitLines():
    let parts = line.split(':', maxsplit = 1)
    if parts.len == 2 and parts[0].strip() == key:
      return parts[1].strip()

proc hexField(value: string; digits: int): string =
  let raw = value.toLowerAscii()
  if not raw.startsWith("0x") or raw.len <= 2 or raw.len > digits + 2:
    return ""
  for ch in raw[2 .. ^1]:
    if ch notin {'0'..'9', 'a'..'f'}:
      return ""
  try:
    let number = parseHexInt(raw)
    if number >= 0 and number < (1 shl (digits * 4)):
      return "0x" & toHex(number, digits).toLowerAscii()
  except ValueError:
    discard

proc armIdentity(blockText: string): string =
  let implementer = hexField(field(blockText, "CPU implementer"), 2)
  let part = hexField(field(blockText, "CPU part"), 3)
  if implementer.len == 0 or part.len == 0:
    return ""
  result = "ARM implementer " & implementer & " part " & part
  let variant = hexField(field(blockText, "CPU variant"), 1)
  if variant.len > 0:
    result.add(" variant " & variant)
  let revision = field(blockText, "CPU revision")
  if revision.len > 0 and revision.allCharsInSet({'0'..'9'}):
    try:
      let number = parseInt(revision)
      if number in 0..15:
        result.add(" revision " & $number)
    except ValueError:
      discard

proc linuxCpuModel*(cpuinfo: string): string =
  ## Empty means no usable identity. The caller supplies its unknown sentinel.
  for key in ["model name", "Model", "Hardware", "cpu model", "cpu"]:
    let value = field(cpuinfo, key)
    if value.len > 0:
      return value

  var identities: seq[string]
  var cpuBlock = ""
  proc finishBlock() =
    let identity = armIdentity(cpuBlock)
    if identity.len > 0 and identity notin identities:
      identities.add(identity)
    cpuBlock.setLen(0)
  for line in cpuinfo.splitLines():
    if line.strip().len == 0:
      finishBlock()
    else:
      cpuBlock.add(line & "\n")
  finishBlock()
  identities.sort()
  identities.join("; ")
