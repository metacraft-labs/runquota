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
## `defaultDaemonConfig`. The file is read at daemon start and again whenever a
## client sends `ReloadHostConfig` (`runquota config reload`, and `runquota
## config set` / `unset` after they write it). A flag still wins after a
## reload, because it pins the value for the daemon's whole launch.
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

when defined(posix):
  import std/posix

# Standard library only, on purpose: reprobuild imports this module to learn
# which budget flags its auto-spawn must NOT pass (a flag overrides the file),
# and it does not link the daemon. Applying the file to a `DaemonConfig` is
# `resolveBudget` in `runquota_daemon` (at start and on every reload).

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

  DefaultMemoryBudgetPercent* = 75'u64
    ## The memory budget of a host whose file sets no `memory_bytes`: this
    ## share of physical memory (decided 2026-09-30; see "Built-in default"
    ## in `reprobuild-specs/RunQuota-Host-Configuration.md`).
    ##
    ## A fraction and not a constant, because a constant is wrong in both
    ## directions at once: the 16 GiB it replaced refused a provider compile
    ## on a 125.6 GiB workstation, and oversubscribes an 8 GiB laptop. 75%
    ## leaves a quarter for what RunQuota does not lease -- the OS, editors,
    ## browsers, the daemons themselves -- and lands where an operator did:
    ## on that 125.6 GiB host it is 94 GiB, beside the 96 GiB written into
    ## its host file by hand.

  FallbackMemoryBudgetBytes* = 16'u64 * 1024'u64 * 1024'u64 * 1024'u64
    ## The budget when physical memory cannot be read at all. The old flat
    ## default, kept only for that case.

  HostConfigTemplate* = """# RunQuota host budget. One file per host: every workspace and every user on
# this machine shares the one runquotad that reads it.
#
# Every key is optional; an absent key keeps the built-in default. A runquotad
# flag (--memory-bytes, --cpu-milli, --pool) overrides the file for that launch.
# Change it with `runquota config set KEY VALUE` (or `unset KEY`), which checks
# the result with the daemon's own reader, writes it atomically and asks the
# running daemon to reload it. After editing by hand, run `runquota config
# reload`. See reprobuild-specs/RunQuota-Host-Configuration.md.
schema = "runquota.host-config.v1"

[machine]
# memory_bytes = 103_079_215_104   # default: 75% of physical memory
# cpu_milli    = 16000             # default: logical processors x 1000

[pools]
# compile = 8
"""
    ## What `runquota config set` starts from when there is no file yet, and
    ## what the installers seed (`packaging/runquota_dist.nim` carries a copy,
    ## and `tests/unit/t_packaging_contract` refuses a drift). It parses to
    ## the empty configuration, so seeding it changes no budget.

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

proc defaultMemoryBudgetBytes*(physicalBytes: uint64): uint64 =
  ## `DefaultMemoryBudgetPercent` of `physicalBytes`, or
  ## `FallbackMemoryBudgetBytes` when physical memory could not be read (0).
  if physicalBytes == 0:
    return FallbackMemoryBudgetBytes
  # Divided before it is multiplied, so no host size can overflow it.
  (physicalBytes div 100'u64) * DefaultMemoryBudgetPercent +
    (physicalBytes mod 100'u64) * DefaultMemoryBudgetPercent div 100'u64

proc humanBytes*(value: uint64): string =
  ## `96 GiB`, `512 MiB`, or the byte count when neither divides it.
  const
    MiB = 1024'u64 * 1024'u64
    GiB = MiB * 1024'u64
  if value >= GiB and value mod GiB == 0: $(value div GiB) & " GiB"
  elif value >= MiB and value mod MiB == 0: $(value div MiB) & " MiB"
  else: $value & " bytes"

# ---------------------------------------------------------------------------
# Writing it: `runquota config set` / `unset`
#
# EDITED AS TEXT, LINE BY LINE, NOT RE-SERIALISED. The file is the operator's:
# a comment saying why a budget is 96 GiB is worth as much as the number, and a
# writer that round-tripped through `HostConfig` would delete it. So an edit
# replaces or removes exactly one `key = value` line, or inserts one line (and
# at most one table header) when the key is new. The edited text is then read
# back by `parseHostConfig` -- the daemon's own reader -- before anything is
# written, so the CLI can never write a file the daemon would refuse.
# ---------------------------------------------------------------------------

type
  HostConfigKey* = object
    section*: string ## `machine` or `pools`
    name*: string

proc isBareKey(name: string): bool =
  if name.len == 0:
    return false
  for ch in name:
    if ch notin {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '_', '-'}:
      return false
  true

proc parseHostConfigKey*(key: string): HostConfigKey =
  ## `machine.memory_bytes`, `machine.cpu_milli` or `pools.NAME`.
  let dot = key.find('.')
  if dot <= 0 or dot == key.len - 1:
    raise newException(HostConfigError, "unknown key `" & key &
      "`; expected machine.memory_bytes, machine.cpu_milli or pools.NAME")
  result = HostConfigKey(section: key[0 ..< dot], name: key[dot + 1 .. ^1])
  case result.section
  of "machine":
    if result.name notin ["memory_bytes", "cpu_milli"]:
      raise newException(HostConfigError, "unknown key `" & key &
        "`; [machine] has memory_bytes and cpu_milli")
  of "pools":
    # A pool name is a bare TOML key. Anything else would need quoting, and
    # the reader does not model quoted keys.
    if not result.name.isBareKey:
      raise newException(HostConfigError, "pool name `" & result.name &
        "` must be letters, digits, `_` or `-`")
  else:
    raise newException(HostConfigError, "unknown table `" & result.section &
      "` in `" & key & "`; expected machine or pools")

proc `$`*(key: HostConfigKey): string = key.section & "." & key.name

proc parseHostConfigValue*(key: HostConfigKey; raw: string): uint64 =
  ## The integer a `config set` VALUE names. `machine.memory_bytes` also takes
  ## a binary or decimal unit (`96GiB`, `512MiB`, `64GB`), because a 12-digit
  ## byte count is where typos live. Range and positivity are left to
  ## `parseHostConfig`, which checks the edited file as a whole.
  let text = raw.strip().replace("_", "")
  var digits = text
  var multiplier = 1'u64
  if key.section == "machine" and key.name == "memory_bytes":
    let lower = text.toLowerAscii()
    for (suffix, factor) in [("gib", 1024'u64 * 1024'u64 * 1024'u64),
                             ("mib", 1024'u64 * 1024'u64),
                             ("kib", 1024'u64),
                             ("gb", 1_000_000_000'u64),
                             ("mb", 1_000_000'u64),
                             ("kb", 1_000'u64)]:
      if lower.endsWith(suffix):
        digits = text[0 ..< text.len - suffix.len].strip()
        multiplier = factor
        break
  if digits.len == 0:
    raise newException(HostConfigError, "`" & $key &
      "` needs a non-negative integer, got `" & raw & "`")
  for ch in digits:
    if ch notin {'0' .. '9'}:
      raise newException(HostConfigError, "`" & $key &
        "` needs a non-negative integer, got `" & raw & "`")
  let base =
    try:
      parseBiggestUInt(digits).uint64
    except ValueError:
      raise newException(HostConfigError, "`" & raw & "` is out of range")
  if multiplier > 1'u64 and base > high(uint64) div multiplier:
    raise newException(HostConfigError, "`" & raw & "` is out of range")
  base * multiplier

type
  LineShape = object
    header: string ## the table a `[name]` line opens, else ""
    key: string    ## the key a `key = value` line sets, else ""

proc shapeOf(rawLine: string): LineShape =
  let line = stripComment(rawLine).strip()
  if line.startsWith("[") and line.endsWith("]") and not line.startsWith("[["):
    result.header = line[1 .. ^2].strip()
  else:
    let eq = line.find('=')
    if eq > 0:
      result.key = line[0 ..< eq].strip()

proc renderEntry(key: HostConfigKey; value: uint64): string =
  result = key.name & " = " & $value
  if key.section == "machine" and key.name == "memory_bytes":
    let human = humanBytes(value)
    if not human.endsWith("bytes"):
      result.add("   # " & human)

proc linesOf(text: string): seq[string] =
  ## `splitLines`, without the empty last element text ending in a newline
  ## produces; `joinLines` puts that newline back once.
  result = text.splitLines()
  if result.len > 0 and result[^1].len == 0:
    result.setLen(result.len - 1)

proc joinLines(lines: seq[string]): string =
  lines.join("\n") & "\n"

proc setHostConfigValue*(text: string; key: HostConfigKey;
                         value: uint64): string =
  ## `text` with `key` set to `value`: the key's line replaced when it has one
  ## (its old trailing comment goes with it, because it described the old
  ## value), otherwise a line added at the end of the key's table, and the
  ## table appended when the file has none. Not validated here; see
  ## `editHostConfig`.
  var lines = linesOf(text)
  let entry = renderEntry(key, value)
  var section = ""
  var sectionEnd = -1 # index after the last non-blank line of `key.section`
  for i, raw in lines:
    let shape = shapeOf(raw)
    if shape.header.len > 0:
      section = shape.header
      if section == key.section:
        sectionEnd = i + 1
      continue
    if section != key.section:
      continue
    if shape.key == key.name:
      lines[i] = entry
      return joinLines(lines)
    if raw.strip().len > 0:
      sectionEnd = i + 1
  if sectionEnd >= 0:
    lines.insert(entry, sectionEnd)
  else:
    if lines.len > 0 and lines[^1].strip().len > 0:
      lines.add("")
    lines.add("[" & key.section & "]")
    lines.add(entry)
  joinLines(lines)

proc unsetHostConfigValue*(text: string; key: HostConfigKey;
                           removed: var bool): string =
  ## `text` without `key`'s line. `removed` says whether it had one.
  removed = false
  var section = ""
  var kept: seq[string] = @[]
  for raw in linesOf(text):
    let shape = shapeOf(raw)
    if shape.header.len > 0:
      section = shape.header
    elif section == key.section and shape.key == key.name:
      removed = true
      continue
    kept.add(raw)
  joinLines(kept)

proc editHostConfig*(path, key, value: string; unset: bool;
                     changed: var bool): string =
  ## The text `path` would hold after `runquota config set KEY VALUE` (or
  ## `unset KEY`), CHECKED BY THE DAEMON'S OWN READER. Raises
  ## `HostConfigError` for a key or value the file cannot hold, and for a
  ## current file that does not parse (naming its line, which the operator
  ## fixes by hand). Starts from `HostConfigTemplate` when there is no file.
  let exists = fileExists(path)
  let before = if exists: readFile(path) else: HostConfigTemplate
  if exists:
    discard parseHostConfig(before, path)
  let parsedKey = parseHostConfigKey(key)
  if unset:
    var removed = false
    result = unsetHostConfigValue(before, parsedKey, removed)
  else:
    result = setHostConfigValue(before, parsedKey,
      parseHostConfigValue(parsedKey, value))
  discard parseHostConfig(result, path)
  changed = result != before or (not exists and not unset)

proc writeHostConfigAtomically*(path, text: string) =
  ## Replace `path` with `text` so that a reader sees the old file or the new
  ## one and never a prefix of either: written beside it, flushed, renamed
  ## over it.
  ##
  ## THE DIRECTORY IS NEVER CREATED HERE. The install step provisions it (the
  ## MSI, the deb and rpm, the Nix modules) with the documented owner and ACL;
  ## see "Provisioning the host-wide state directory" in `docs/database.md`.
  ## A missing directory is an unprovisioned host, and creating it here would
  ## give it the owner and ACL of whoever ran this first.
  ##
  ## A SYMBOLIC LINK IS REFUSED. Under NixOS and nix-darwin the file is
  ## declared by `services.runquotad.hostConfig` and links into the store; a
  ## rename over it would be undone, silently, by the next activation.
  ##
  ## On Windows the new file inherits the directory's ACL (the documented one
  ## is inheritable), so the rename leaves the file with the access the
  ## install step gave the directory. On POSIX it is `0644`: the daemon's
  ## account reads it, and a budget is not a secret.
  let dir = parentDir(path)
  if dir.len > 0 and not dirExists(dir):
    raise newException(HostConfigError, dir & " does not exist. It is " &
      "created by the install step (the runquota package or the Nix " &
      "module), never by `runquota config`; see \"Provisioning the " &
      "host-wide state directory\" in runquota's docs/database.md")
  if symlinkExists(path):
    raise newException(HostConfigError, path & " is a symbolic link: it " &
      "is managed declaratively (services.runquotad.hostConfig under Nix), " &
      "so change it there")
  let temp = (if dir.len > 0: dir else: ".") /
    ("." & extractFilename(path) & ".tmp-" & $getCurrentProcessId())
  try:
    var file: File
    if not open(file, temp, fmWrite):
      raise newException(IOError, "cannot create " & temp)
    try:
      file.write(text)
      file.flushFile()
      when defined(posix):
        discard fsync(file.getOsFileHandle())
    finally:
      file.close()
    when defined(posix):
      setFilePermissions(temp, {fpUserRead, fpUserWrite, fpGroupRead,
        fpOthersRead})
    moveFile(temp, path)
  except CatchableError as err:
    try:
      removeFile(temp)
    except CatchableError:
      discard
    raise newException(HostConfigError, "cannot write " & path & ": " &
      err.msg & ". The host file needs the rights the install step gave " &
      "its directory: an elevated prompt on Windows (Administrators or " &
      "SYSTEM), root on Linux and macOS")
