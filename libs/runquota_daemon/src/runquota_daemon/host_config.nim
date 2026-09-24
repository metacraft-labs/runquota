## Per-host RunQuota budget, read from one TOML file.
##
## RunQuota serves the whole host from one daemon on one fixed endpoint (see
## `windowsHostWideEndpointPath`), so every workspace and every user shares its
## budget -- and whoever started it set that budget for all of them. Before this
## file existed the budget came from `runquotad` flags, which reprobuild's
## auto-spawn filled from a 16 GiB constant or a per-invocation environment
## variable. That is a property of whichever shell spawned the daemon first, not
## of the host. The design is `reprobuild-specs/RunQuota-Host-Configuration.md`.
##
## Precedence, applied by `runquotad`: explicit flags, then this file, then
## `defaultDaemonConfig`. The file is read once, at daemon start.
##
## THE READER ACCEPTS A DOCUMENTED SUBSET OF TOML AND REFUSES EVERYTHING ELSE.
## runquota carries no TOML library, and the file has one small, fixed shape:
## a `schema` string, a `[machine]` table of integers and a `[pools]` table of
## integers. Rather than guess at syntax it does not model -- an array, an
## inline table, a float -- the reader rejects it with the file and line, and
## the daemon does not start. A budget file that is silently half-read is worse
## than none, because it looks configured.
##
## A MISSING FILE IS NOT AN ERROR and is never created here. The directory it
## lives in is provisioned by the install step and by nothing else, for the
## reason `hostWideStateDir` and `windowsServiceLogFile` record: a path any
## caller can create is a path any caller can create differently.

import std/[options, os, strutils, tables]

# Standard library only, on purpose: reprobuild imports this module to learn
# which budget flags its auto-spawn must NOT pass (a flag overrides the file),
# and it does not link the daemon. Applying the file to a `DaemonConfig` is
# `applyHostConfig` in `runquota_daemon`.

const
  HostConfigSchema* = "runquota.host-config.v1"

  # Spelled as literals, like `hostWideStateDir`, and for the same reason: an
  # environment reference in a service-visible path is how a directory
  # literally called `%ProgramData%` gets made. POSIX puts configuration under
  # `/etc`, beside the `/run/runquota` rendezvous; Windows has no config/state
  # split, so it shares the host-wide state directory.
  hostConfigPath* =
    when defined(windows):
      r"C:\ProgramData\runquota\runquotad.toml"
    else:
      "/etc/runquota/runquotad.toml"

type
  HostConfig* = object
    memoryBytes*: Option[uint64]
    cpuMilli*: Option[uint64]
    pools*: OrderedTable[string, uint32]
    sourcePath*: string
      ## Where it was read from; empty when no file existed. Kept so a denial
      ## can say whose budget it enforced.

  HostConfigError* = object of ValueError

proc fail(path: string; lineNo: int; msg: string) {.noreturn.} =
  raise newException(HostConfigError,
    path & ":" & $lineNo & ": " & msg & " (runquota host configuration; see " &
    "reprobuild-specs/RunQuota-Host-Configuration.md)")

proc stripComment(line: string): string =
  ## A `#` outside a double-quoted string starts a comment.
  var inString = false
  for i, ch in line:
    if ch == '"':
      inString = not inString
    elif ch == '#' and not inString:
      return line[0 ..< i]
  line

proc parseInteger(raw, path: string; lineNo: int): uint64 =
  ## TOML integers may carry `_` between digits. Signs, hex, floats and
  ## anything else are outside the subset.
  let text = raw.strip()
  if text.len == 0 or text[0] == '_' or text[^1] == '_' or "__" in text:
    fail(path, lineNo, "expected an integer, got `" & raw.strip() & "`")
  let digits = text.replace("_", "")
  for ch in digits:
    if ch notin {'0' .. '9'}:
      fail(path, lineNo, "expected a non-negative integer, got `" & text & "`")
  try:
    result = parseBiggestUInt(digits).uint64
  except ValueError:
    fail(path, lineNo, "integer out of range: `" & text & "`")

proc parseHostConfig*(text, path: string): HostConfig =
  result.pools = initOrderedTable[string, uint32]()
  result.sourcePath = path
  var section = ""
  var lineNo = 0
  for rawLine in text.splitLines():
    inc lineNo
    let line = stripComment(rawLine).strip()
    if line.len == 0:
      continue
    if line.startsWith("["):
      if not line.endsWith("]") or line.startsWith("[["):
        fail(path, lineNo, "unsupported table header `" & line & "`")
      section = line[1 .. ^2].strip()
      if section notin ["machine", "pools"]:
        fail(path, lineNo, "unknown table `[" & section & "]`; expected " &
          "[machine] or [pools]")
      continue
    let eq = line.find('=')
    if eq <= 0:
      fail(path, lineNo, "expected `key = value`, got `" & line & "`")
    let key = line[0 ..< eq].strip()
    let value = line[eq + 1 .. ^1].strip()
    case section
    of "":
      if key != "schema":
        fail(path, lineNo, "unknown top-level key `" & key & "`")
      if value != "\"" & HostConfigSchema & "\"":
        fail(path, lineNo, "schema must be \"" & HostConfigSchema &
          "\", got " & value)
    of "machine":
      case key
      of "memory_bytes":
        let v = parseInteger(value, path, lineNo)
        if v == 0:
          fail(path, lineNo, "memory_bytes must be positive")
        result.memoryBytes = some(v)
      of "cpu_milli":
        let v = parseInteger(value, path, lineNo)
        if v == 0:
          fail(path, lineNo, "cpu_milli must be positive")
        if v > uint64(high(uint32)):
          fail(path, lineNo, "cpu_milli out of range: " & $v)
        result.cpuMilli = some(v)
      else:
        fail(path, lineNo, "unknown key `" & key & "` in [machine]; " &
          "expected memory_bytes or cpu_milli")
    of "pools":
      let v = parseInteger(value, path, lineNo)
      # A zero cap admits nothing: `possible` refuses every lease in a pool
      # whose cap is 0.
      if v == 0:
        fail(path, lineNo, "pool `" & key & "` must be positive")
      if v > uint64(high(uint32)):
        fail(path, lineNo, "pool size out of range: " & $v)
      result.pools[key] = uint32(v)
    else:
      discard

proc readHostConfig*(path = hostConfigPath): HostConfig =
  ## The empty config when the file does not exist.
  if not fileExists(path):
    result.pools = initOrderedTable[string, uint32]()
    return
  let text =
    try:
      readFile(path)
    except IOError as err:
      raise newException(HostConfigError,
        path & ": cannot read runquota host configuration: " & err.msg)
  parseHostConfig(text, path)
