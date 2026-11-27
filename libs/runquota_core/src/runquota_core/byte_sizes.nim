## Memory sizes as people type and read them.
##
## ONE PARSER AND ONE RENDERING for every place a size crosses the boundary
## between RunQuota and a person: `--mem SIZE`, `RUNQUOTA_MEMORY_CAP=<size>`,
## `runquota expect-growth --to SIZE`, and the memory-cap report. Binary
## units throughout, because memory is allocated in pages and every tool a
## reader compares against (`free -h`, `memory.peak` read by hand, Task
## Manager) speaks them: `K`, `M`, `G` and `T` are KiB, MiB, GiB and TiB.
##
## Standard library free (no imports at all), so the static helper libraries
## and the host-file reader can use it alike.

const
  KiB* = 1024'u64
  MiB* = KiB * 1024'u64
  GiB* = MiB * 1024'u64
  TiB* = GiB * 1024'u64

proc endsWithText(text, suffix: string): bool =
  text.len >= suffix.len and text[text.len - suffix.len .. ^1] == suffix

proc parseByteSize*(raw: string; value: var uint64): bool =
  ## A positive whole number of bytes, or one with a binary suffix: `K`, `M`,
  ## `G`, `T`, or the same with `iB` (`KiB`, `MiB`, `GiB`, `TiB`). Leading
  ## and trailing blanks are ignored. Zero, a fraction, a sign, a decimal
  ## unit (`GB`) and a value that does not fit in 64 bits are refused: each
  ## is a size spelled wrongly, and a guess at what was meant would be a
  ## different size from the one written. `value` is untouched on refusal.
  var first = 0
  var last = raw.len - 1
  while first <= last and raw[first] in {' ', '\t'}: inc first
  while last >= first and raw[last] in {' ', '\t'}: dec last
  if first > last:
    return false
  var digits = raw[first .. last]
  var multiplier = 1'u64
  for (suffix, factor) in [("KiB", KiB), ("MiB", MiB), ("GiB", GiB),
      ("TiB", TiB), ("K", KiB), ("M", MiB), ("G", GiB), ("T", TiB)]:
    if digits.endsWithText(suffix):
      digits = digits[0 ..< digits.len - suffix.len]
      multiplier = factor
      break
  if digits.len == 0 or digits.len > 20:
    return false
  var number = 0'u64
  for ch in digits:
    if ch notin {'0' .. '9'}:
      return false
    let digit = uint64(ord(ch) - ord('0'))
    if number > (high(uint64) - digit) div 10'u64:
      return false
    number = number * 10'u64 + digit
  if number == 0'u64 or number > high(uint64) div multiplier:
    return false
  value = number * multiplier
  true

proc formatBinaryBytes*(bytes: uint64): string =
  ## `2.0 GiB`, `512.0 MiB`, `1.5 KiB`: the largest binary unit the value
  ## reaches, with one decimal (rounded half up); below 1 KiB, `N bytes`.
  ## One decimal because the report this serves compares a cap with a peak
  ## and with the peak before it, and those differ in the first decimal far
  ## more often than in the integer part.
  if bytes < KiB:
    return $bytes & " bytes"
  var unit = KiB
  var name = "KiB"
  for (factor, label) in [(MiB, "MiB"), (GiB, "GiB"), (TiB, "TiB")]:
    if bytes >= factor:
      unit = factor
      name = label
  # Tenths of the unit, rounded half up, without floating point: exact for
  # every 64-bit value. Nothing here overflows: the remainder is below the
  # largest unit (2^40), so ten times it is below 2^44, and the whole part
  # of a 64-bit value in TiB is below 2^24.
  let whole = bytes div unit
  let rest = bytes mod unit
  let tenths = whole * 10'u64 + (rest * 10'u64 + unit div 2'u64) div unit
  $(tenths div 10'u64) & "." & $(tenths mod 10'u64) & " " & name
