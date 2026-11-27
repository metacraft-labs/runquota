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
## a `schema` string, a `[machine]` table of integers, a `[pools]` table of
## integers, and an `[admission]` table of plain strings and one one-line
## array of strings (the admission order). Rather than guess at syntax it does
## not model -- an inline table, a float, a string with escapes, a multi-line
## array -- the reader rejects it with the file and line, and the daemon does
## not start. A budget file that is silently half-read is worse
## than none, because it looks configured.
##
## A MISSING FILE IS NOT AN ERROR and is never created here. The directory it
## lives in is provisioned by the install step and by nothing else, for the
## reason `hostWideStateDir` and `windowsServiceLogFile` record: a path any
## caller can create is a path any caller can create differently.

import std/[options, os, strutils, tables]

import runquota_core/memory_cap
import ./cpu_pressure

when defined(posix):
  import std/posix

# Standard library only, on purpose: reprobuild imports this module to learn
# which budget flags its auto-spawn must NOT pass (a flag overrides the file),
# and it does not link the daemon. Applying the file to a `DaemonConfig` is
# `resolveBudget` in `runquota_daemon` (at start and on every reload).
# `./cpu_pressure`, imported for the threshold defaults, is standard-library
# only as well, and so is `runquota_core/memory_cap`, imported for the cap's
# mode and factor bounds (it imports nothing at all).

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

  AdmissionOrderKeys* = ["starvation", "priority", "cache-deadline",
    "fair-share", "arrival"]
    ## The keys `[admission] order` may list, spelled as the file spells
    ## them. They are `runquota_admission.AdmissionKey`'s spellings, repeated
    ## here because this module stays standard-library only (see above);
    ## `libs/runquota_daemon/tests/t_host_config_admission` refuses a drift.

  DefaultBenchmarkMaxQueueWaitMillis* = 10'i64 * 60_000'i64
    ## A queued benchmark gates every other lease while it waits for the
    ## host to drain, so the wait is bounded: past this it is denied and
    ## normal admission resumes. Host-wide daemon, many users: no benchmark
    ## may hold the host unbounded.
  DefaultBenchmarkMaxHoldMillis* = 60'i64 * 60_000'i64
    ## A granted benchmark gates admission for at most this long; after it,
    ## the lease keeps its resources (RunQuota never kills a client) but no
    ## longer blocks other grants.

  ShareBetweenUsersValues* = ["drf", "none"]
    ## `[admission] share-between-users`; `runquota_admission.ShareBetweenUsers`.

  MaxOversubscriptionPermille* = 1000'u32
    ## The largest `admission.oversubscription` the file may set: 1.0, i.e.
    ## grants of up to twice the CPU budget. A larger value is far more
    ## likely a percentage written where a fraction belongs (`"10"` for
    ## ten percent) than a target anybody means, so it is refused.

  MaxReservationClassBytes = 64
    ## The longest class name in a `[reservation.<class>]` header: the same
    ## bound as `runquota_core.MaxClassNameBytes`, restated here because
    ## this module imports only the standard library.

  ReservationKeys* = ["cpu-milli", "memory-bytes", "lend", "socket-owner",
    "socket-group", "socket-mode", "allowed-users", "allowed-groups"]
    ## The keys of a `[reservation.<class>]` table, of every platform: the
    ## reader parses them all everywhere and refuses the other platform's
    ## (`PosixClassSocketKeys`, `WindowsClassSocketKeys`).
  PosixClassSocketKeys* = ["socket-owner", "socket-group", "socket-mode"]
    ## Who may claim a class on Linux and macOS: its socket's owner, group
    ## and mode. Refused in a file read for Windows.
  WindowsClassSocketKeys* = ["allowed-users", "allowed-groups"]
    ## Who may claim a class on Windows: the principals the class pipe's DACL
    ## allows. Refused in a file read for Linux or macOS.
  ClassSocketModes* = ["0600", "0660", "0666"]
    ## The `socket-mode` values. `connect(2)` on a Unix socket needs write
    ## permission on it, so these are the three meaningful choices: the
    ## owner only, the owner and the group, every local user who can reach
    ## the rendezvous. Read and execute bits decide nothing, so a mode such
    ## as `0644` -- through which no group member could connect -- is a
    ## mistake to refuse, not a setting.
  DefaultClassSocketMode* = 0o600
    ## Owner only: a host that declares a reservation and nothing else has
    ## reserved capacity only the daemon's own account (and root) can claim.

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
  HostConfigPlatform* = enum
    ## Which platform's class-socket keys a file is read for. The keys of
    ## both are parsed everywhere, and the other platform's are refused
    ## naming it, so a file written for one host fails loudly on another
    ## instead of granting nothing.
    hcpPosix    ## Linux and macOS: `socket-owner`, `socket-group`, `socket-mode`
    hcpWindows  ## Windows: `allowed-users`, `allowed-groups`

  ClassReservation* = object
    ## `[reservation.<class>]`: the capacity a class of work holds that
    ## other work cannot be granted. An absent key reserves nothing of that
    ## dimension; `lend` (default true) lets the class's idle reserved CPU
    ## go to other work until the class asks for it. Reserved memory is
    ## never lent.
    ##
    ## Every table is also a CLASS SOCKET (`class-<class>.sock` beside the
    ## daemon's endpoint), and the socket keys say who may claim the class
    ## by connecting to it. Build them with `newClassReservation`, which
    ## gives the owner-only defaults.
    cpuMilli*: uint64
    memoryBytes*: uint64
    lend*: bool
    socketOwner*: string
      ## `socket-owner` as written (a user name or a decimal uid), or "" for
      ## the default: the daemon's own user.
    socketOwnerUid*: int64
      ## `socketOwner` resolved, or -1 for the default.
    socketGroup*: string
      ## `socket-group` as written (a group name or a decimal gid), or "" for
      ## the default: the daemon's primary group.
    socketGroupGid*: int64
      ## `socketGroup` resolved, or -1 for the default.
    socketMode*: int
      ## `socket-mode`: one of `ClassSocketModes`, as a number;
      ## `DefaultClassSocketMode` when absent.
    allowedUsers*: seq[string]
      ## Windows: `allowed-users`, names or SIDs the pipe's DACL allows.
    allowedGroups*: seq[string]
      ## Windows: `allowed-groups`.

  HostConfig* = object
    memoryBytes*: Option[uint64]
    cpuMilli*: Option[uint64]
    writeBytesPerSec*: Option[uint64]
      ## `[machine] write_bytes_per_sec`: what this host's storage sustains,
      ## in bytes per second. REPORTED, NOT ENFORCED: `status`, `profile` and
      ## `sizing` show it beside the measured write rates, and admission
      ## does not read it.
    pools*: OrderedTable[string, uint32]
    admissionOrder*: Option[seq[string]]
      ## `[admission] order`, validated: each key one of
      ## `AdmissionOrderKeys`, none twice, at least one.
    admissionMaxWaitMillis*: Option[int64]
      ## `[admission] max-wait`; 0 turns the starvation bound off.
    shareBetweenUsers*: Option[string]
      ## `[admission] share-between-users`, one of `ShareBetweenUsersValues`.
    admissionPredictive*: Option[bool]
      ## `[admission] predictive`, `"on"` or `"off"`.
    admissionHorizonMillis*: Option[int64]
      ## `[admission] horizon`, a positive duration.
    enforcementCgroups*: Option[bool]
      ## `[enforcement] cgroups`, `"on"` or `"off"`: whether RunQuota's
      ## launchers on this host place the trees they start in cgroups (Linux).
      ## Read by the LAUNCHING CLIENT, not by `runquotad`, which never touches
      ## a cgroup; the daemon only validates it with the rest of the file. Off
      ## when absent.
    enforcementJobPriority*: Option[bool]
      ## `[enforcement] job-priority`, `"on"` or `"off"`: whether RunQuota's
      ## launchers on this host force each leased tree's Job Object to its
      ## group's priority class below admission (Windows). Read by the
      ## LAUNCHING CLIENT, not by `runquotad`, which spawns no trees; the
      ## daemon only validates it. Off when absent (the Windows analogue of
      ## `[enforcement] cgroups`, off until the overhead gate passes it).
    enforcementQos*: Option[bool]
      ## `[enforcement] qos`, `"on"` or `"off"`: whether RunQuota's launchers
      ## on this host apply their group's priority policy to each leased tree
      ## below admission (macOS: the background policy for a reclaimed tree and
      ## for a `low` group's tree). Read by the LAUNCHING CLIENT, not
      ## by `runquotad`, which spawns no trees; the daemon only validates
      ## it. Off when absent (the macOS analogue of `[enforcement] cgroups`,
      ## off until the overhead gate passes it).
    enforcementMemoryCap*: Option[MemoryCapMode]
      ## `[enforcement] memoryCap`, `"off"`, `"advisory"` or `"kill"`: what
      ## RunQuota's launchers on this host do with each grant's memory cap
      ## (every OS). Read by the LAUNCHING CLIENT, which enforces the cap; the
      ## daemon only validates it. Off when absent, until the overhead gate
      ## lets it on.
    memoryCapFactorMilli*: Option[uint32]
      ## `[enforcement] memoryCapFactor`, a number of at least 1.5, kept in
      ## thousandths: the factor `runquotad` multiplies a command's largest
      ## successful tree peak by to compute its cap. Read by the DAEMON, which
      ## computes every grant's cap.
    pressureHighPct*: Option[float64]
    pressureLowPct*: Option[float64]
      ## `[admission] pressure-high` / `pressure-low`, percentages 0..100,
      ## low not above high once the defaults fill an absent one.
    benchmarkAllowedUsers*: seq[string]
      ## `[benchmark] allowed-users`: user names or decimal uids (Windows:
      ## SID strings) that may take a `purpose = benchmark` lease besides the
      ## daemon's own user and root.
    benchmarkAllowedGroups*: seq[string]
      ## `[benchmark] allowed-groups`: group names whose members (or primary
      ## group) may take a benchmark lease.
    benchmarkMaxQueueWaitMillis*: Option[int64]
      ## `[benchmark] max-queue-wait`: how long a benchmark may sit queued,
      ## gating every other lease, before it is denied.
    benchmarkMaxHoldMillis*: Option[int64]
      ## `[benchmark] max-hold`: how long a granted benchmark gates
      ## admission before normal admission resumes.
    oversubscriptionPermille*: Option[uint32]
      ## `[admission] oversubscription`: the CPU oversubscription target as
      ## a fraction of the budget, kept in thousandths (`"0.1"` is 100). The
      ## sum of CPU grants may reach the budget x (1 + target).
    reservations*: OrderedTable[string, ClassReservation]
      ## `[reservation.<class>]` tables, in file order.
    sourcePath*: string
      ## Where it was read from; empty when no file existed. Kept so a denial
      ## can say whose budget it enforced.

  HostConfigError* = object of ValueError

proc fail(path: string; lineNo: int; msg: string) {.noreturn.} =
  raise newException(HostConfigError,
    path & ":" & $lineNo & ": " & msg & " (runquota host configuration; see " &
    "reprobuild-specs/RunQuota-Host-Configuration.md)")

proc isBareKey(name: string): bool =
  ## A bare TOML key: letters, digits, `_` and `-`
  ## (https://toml.io/en/v1.0.0#keys). It is the only key form the file's
  ## subset has. A pool name outside it (`a.b`, `host/linker`) would need a
  ## quoted or dotted key, which the subset does not model, so the reader and
  ## `runquota config set` both refuse it, and such a pool is sized only by a
  ## `--pool` flag or by its declared capacity (*Limitation* under *Pools a
  ## build declares* in RunQuota-Host-Configuration.md).
  if name.len == 0:
    return false
  for ch in name:
    if ch notin {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '_', '-'}:
      return false
  true

const PoolNameRule = "must be letters, digits, `_` or `-`"

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

proc parseFactorMilli*(raw: string; milli: var uint32): bool =
  ## A plain decimal number with at most three decimals (`2`, `1.5`,
  ## `2.25`), in thousandths. TOML writes an integer and a float the same
  ## way for these values, and the subset reads both; a quoted string, a
  ## sign, an exponent or a fourth decimal is not a factor. The floor is
  ## the caller's to apply, so it can say what the floor is.
  let text = raw.strip()
  let dot = text.find('.')
  let whole = if dot < 0: text else: text[0 ..< dot]
  let fraction = if dot < 0: "" else: text[dot + 1 .. ^1]
  if whole.len == 0 or whole.len > 6 or fraction.len > 3 or
      (dot >= 0 and fraction.len == 0):
    return false
  for ch in whole & fraction:
    if ch notin {'0' .. '9'}:
      return false
  var value = 0'u64
  for ch in whole:
    value = value * 10'u64 + uint64(ord(ch) - ord('0'))
  value = value * 1000'u64
  var scale = 100'u64
  for ch in fraction:
    value += uint64(ord(ch) - ord('0')) * scale
    scale = scale div 10'u64
  if value > uint64(high(uint32)):
    return false
  milli = uint32(value)
  true

proc parseQuoted(raw, path: string; lineNo: int): string =
  ## A double-quoted TOML basic string WITHOUT escapes: the subset has no use
  ## for them, and a reader that half-modelled them would misread one.
  let text = raw.strip()
  if text.len < 2 or text[0] != '"' or text[^1] != '"':
    fail(path, lineNo, "expected a double-quoted string, got `" & text & "`")
  result = text[1 .. ^2]
  if '"' in result or '\\' in result:
    fail(path, lineNo, "unsupported string `" & text & "`: quotes and " &
      "escapes inside a string are outside the supported subset")

proc parseStringArray(raw, path: string; lineNo: int): seq[string] =
  ## A one-line array of `parseQuoted` strings: `["a", "b"]`. A trailing
  ## comma is allowed, as TOML allows it.
  let text = raw.strip()
  if text.len < 2 or text[0] != '[' or text[^1] != ']':
    fail(path, lineNo, "expected a one-line array of strings, got `" & text &
      "`")
  let inner = text[1 .. ^2].strip()
  if inner.len == 0:
    return @[]
  var items = inner.split(',')
  if items[^1].strip().len == 0:
    items.setLen(items.len - 1)
  for item in items:
    result.add(parseQuoted(item, path, lineNo))

proc parseDurationMillis*(raw: string; millis: var int64): bool =
  ## `1500ms`, `120s` or `2m` (a non-negative whole number and a unit) as
  ## milliseconds. Used by the file reader and by `runquota config set`.
  let text = raw.strip()
  var digits = ""
  var factor = 0'i64
  if text.endsWith("ms"):
    digits = text[0 ..< text.len - 2]
    factor = 1
  elif text.endsWith("s"):
    digits = text[0 ..< text.len - 1]
    factor = 1000
  elif text.endsWith("m"):
    digits = text[0 ..< text.len - 1]
    factor = 60_000
  else:
    return false
  if digits.len == 0:
    return false
  for ch in digits:
    if ch notin {'0' .. '9'}:
      return false
  try:
    let value = parseBiggestInt(digits)
    if value > high(int64) div factor:
      return false
    millis = value * factor
    true
  except ValueError:
    false

proc validateAdmissionOrder(keys: seq[string]; path: string; lineNo: int) =
  ## Refuse an empty order, an unknown key and a key listed twice (reprobuild-
  ## specs Build-Engine-And-Scheduler.md, "Configuring the order").
  if keys.len == 0:
    fail(path, lineNo, "admission order is empty; list at least one key " &
      "(arrival order alone is [\"arrival\"])")
  var seen: seq[string] = @[]
  for key in keys:
    if key notin AdmissionOrderKeys:
      fail(path, lineNo, "unknown admission order key `" & key &
        "`; expected " & AdmissionOrderKeys.join(", "))
    if key in seen:
      fail(path, lineNo, "admission order lists `" & key & "` twice")
    seen.add(key)

proc reservationClassProblem*(name: string): string =
  ## Why `name` cannot be a class in `[reservation.<class>]`, or "" when it
  ## can: 1 to 64 bytes of letters, digits, `_` and `-`. The rule
  ## `runquota_core.classNameProblem` applies to `RUNQUOTA_CLASS`, restated
  ## (this module imports only the standard library), so every class a
  ## client can name can be given a reservation, and the reverse.
  if name.len == 0:
    return "a class name is empty"
  if name.len > MaxReservationClassBytes:
    return "a class name is longer than " & $MaxReservationClassBytes &
      " bytes"
  for ch in name:
    if ch notin {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '_', '-'}:
      return "a class name may hold only letters, digits, `_` and `-`"
  ""

proc parseOversubscriptionPermille*(raw: string; permille: var uint32): bool =
  ## A decimal fraction from 0 to 1 with at most three decimal places
  ## (`"0"`, `"0.1"`, `"0.125"`, `"1"`), in thousandths. Anything else --
  ## a sign, an exponent, a percent sign, a fourth decimal -- is refused.
  let text = raw.strip()
  if text.len == 0:
    return false
  let dot = text.find('.')
  let whole = if dot < 0: text else: text[0 ..< dot]
  let frac = if dot < 0: "" else: text[dot + 1 .. ^1]
  if whole.len == 0 or (dot >= 0 and frac.len == 0) or frac.len > 3:
    return false
  for ch in whole & frac:
    if ch notin {'0' .. '9'}:
      return false
  if whole.len > 4:
    return false
  var value = uint32(parseInt(whole)) * 1000'u32
  if frac.len > 0:
    value += uint32(parseInt(frac & repeat('0', 3 - frac.len)))
  if value > MaxOversubscriptionPermille:
    return false
  permille = value
  true

proc oversubscriptionText*(permille: uint32): string =
  ## The fraction as the file spells it: `0`, `0.1`, `0.125`, `1`.
  result = $(permille div 1000'u32)
  var frac = $(permille mod 1000'u32)
  if frac != "0":
    frac = align(frac, 3, '0')
    while frac.endsWith("0"):
      frac.setLen(frac.len - 1)
    result.add("." & frac)

proc newClassReservation*(): ClassReservation =
  ## A `[reservation.<class>]` table with no keys: no reservation, lending,
  ## and a socket only the daemon's account (and root) may claim.
  ClassReservation(lend: true, socketOwnerUid: -1, socketGroupGid: -1,
    socketMode: DefaultClassSocketMode)

proc currentHostConfigPlatform*(): HostConfigPlatform =
  when defined(windows): hcpWindows else: hcpPosix

proc platformText(platform: HostConfigPlatform): string =
  case platform
  of hcpPosix: "Linux and macOS"
  of hcpWindows: "Windows"

proc classSocketModeOf*(text: string; mode: var int): bool =
  ## `"0660"` -> `0o660`, for the three `ClassSocketModes` only.
  if text notin ClassSocketModes:
    return false
  mode = 0
  for ch in text:
    mode = mode * 8 + (ord(ch) - ord('0'))
  true

proc classSocketModeText*(mode: int): string =
  ## `0o660` -> `"0660"`.
  "0" & toOct(mode and 0o777, 3)

const MaxAccountId* = 4294967294'i64
  ## The largest uid or gid a socket can be given: `(uid_t)-1` is chown's
  ## "leave unchanged".

proc resolveAccountId(raw: string; group: bool): int64 =
  ## A decimal id as written, or the id of the user (group) of that name,
  ## or -1 when there is none. A decimal id is taken without a lookup: an id
  ## need not have a name (a host whose directory service is down, a
  ## systemd dynamic user), and the daemon still judges whether it can apply
  ## it.
  var allDigits = raw.len > 0
  for ch in raw:
    if ch notin {'0' .. '9'}:
      allDigits = false
  if allDigits:
    if raw.len > 12:
      return MaxAccountId + 1
    try:
      return int64(parseBiggestUInt(raw))
    except ValueError:
      return MaxAccountId + 1
  when defined(posix):
    if group:
      let entry = getgrnam(raw.cstring)
      if entry == nil: -1 else: int64(entry.gr_gid)
    else:
      let entry = getpwnam(raw.cstring)
      if entry == nil: -1 else: int64(entry.pw_uid)
  else:
    -1

proc reservationClassOf(section: string): string =
  ## The class a `reservation.<class>` table header names, or "" when the
  ## header is not one.
  if section.startsWith("reservation.") and section.len > "reservation.".len:
    section["reservation.".len .. ^1]
  else:
    ""

proc parseHostConfig*(text, path: string;
                      platform = currentHostConfigPlatform()): HostConfig =
  ## The file at `path` (its text), read for `platform` -- this host's,
  ## unless a test reads it as another platform would.
  result.pools = initOrderedTable[string, uint32]()
  result.reservations = initOrderedTable[string, ClassReservation]()
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
      let reserved = reservationClassOf(section)
      if reserved.len > 0:
        let problem = reservationClassProblem(reserved)
        if problem.len > 0:
          fail(path, lineNo, "table `[" & section & "]`: " & problem)
        if result.reservations.hasKey(reserved):
          fail(path, lineNo, "table `[" & section & "]` appears twice")
        result.reservations[reserved] = newClassReservation()
        continue
      if section notin ["machine", "pools", "admission", "benchmark",
          "enforcement"]:
        fail(path, lineNo, "unknown table `[" & section & "]`; expected " &
          "[machine], [pools], [admission], [benchmark], [enforcement] or " &
          "[reservation.<class>]")
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
      of "write_bytes_per_sec":
        let v = parseInteger(value, path, lineNo)
        if v == 0:
          fail(path, lineNo, "write_bytes_per_sec must be positive")
        if v > uint64(high(int64)):
          fail(path, lineNo, "write_bytes_per_sec out of range: " & $v)
        result.writeBytesPerSec = some(v)
      else:
        fail(path, lineNo, "unknown key `" & key & "` in [machine]; " &
          "expected memory_bytes, cpu_milli or write_bytes_per_sec")
    of "pools":
      # Checked before the value: the key is what the subset cannot hold,
      # and a hand edit must not size a pool `runquota config set` refuses.
      if not key.isBareKey:
        fail(path, lineNo, "pool name `" & key & "` " & PoolNameRule)
      let v = parseInteger(value, path, lineNo)
      # A zero cap admits nothing: `possible` refuses every lease in a pool
      # whose cap is 0.
      if v == 0:
        fail(path, lineNo, "pool `" & key & "` must be positive")
      if v > uint64(high(uint32)):
        fail(path, lineNo, "pool size out of range: " & $v)
      result.pools[key] = uint32(v)
    of "admission":
      case key
      of "order":
        let keys = parseStringArray(value, path, lineNo)
        validateAdmissionOrder(keys, path, lineNo)
        result.admissionOrder = some(keys)
      of "max-wait":
        var millis = 0'i64
        if not parseDurationMillis(parseQuoted(value, path, lineNo), millis):
          fail(path, lineNo, "max-wait must be a duration such as \"120s\", " &
            "\"1500ms\" or \"2m\", got " & value)
        result.admissionMaxWaitMillis = some(millis)
      of "share-between-users":
        let share = parseQuoted(value, path, lineNo)
        if share notin ShareBetweenUsersValues:
          fail(path, lineNo, "share-between-users must be " &
            ShareBetweenUsersValues.join(" or ") & ", got " & value)
        result.shareBetweenUsers = some(share)
      of "predictive":
        let raw = parseQuoted(value, path, lineNo)
        case raw
        of "on": result.admissionPredictive = some(true)
        of "off": result.admissionPredictive = some(false)
        else:
          fail(path, lineNo, "predictive must be \"on\" or \"off\", got " &
            value)
      of "horizon":
        var millis = 0'i64
        if not parseDurationMillis(parseQuoted(value, path, lineNo), millis) or
            millis <= 0:
          fail(path, lineNo, "horizon must be a positive duration such as " &
            "\"10s\" or \"1500ms\", got " & value)
        result.admissionHorizonMillis = some(millis)
      of "pressure-high", "pressure-low":
        let raw = parseQuoted(value, path, lineNo)
        var pct = -1.0
        try:
          pct = parseFloat(raw)
        except ValueError:
          discard
        if pct < 0.0 or pct > 100.0 or pct != pct:
          fail(path, lineNo, key & " must be a percentage from 0 to 100 " &
            "such as \"10\" or \"2.5\", got " & value)
        if key == "pressure-high": result.pressureHighPct = some(pct)
        else: result.pressureLowPct = some(pct)
      of "oversubscription":
        var permille = 0'u32
        if not parseOversubscriptionPermille(parseQuoted(value, path, lineNo),
            permille):
          fail(path, lineNo, "oversubscription must be a fraction of the " &
            "CPU budget from \"0\" to \"1\" with at most three decimals, " &
            "such as \"0.1\" for ten percent, got " & value)
        result.oversubscriptionPermille = some(permille)
      else:
        fail(path, lineNo, "unknown key `" & key & "` in [admission]; " &
          "expected order, max-wait, share-between-users, predictive, " &
          "horizon, pressure-high, pressure-low or oversubscription")
    of "benchmark":
      case key
      of "allowed-users":
        result.benchmarkAllowedUsers = parseStringArray(value, path, lineNo)
      of "allowed-groups":
        result.benchmarkAllowedGroups = parseStringArray(value, path, lineNo)
      of "max-queue-wait", "max-hold":
        var millis = 0'i64
        if not parseDurationMillis(parseQuoted(value, path, lineNo), millis) or
            millis <= 0:
          fail(path, lineNo, key & " must be a positive duration such as " &
            "\"10m\" or \"90s\", got " & value)
        if key == "max-hold": result.benchmarkMaxHoldMillis = some(millis)
        else: result.benchmarkMaxQueueWaitMillis = some(millis)
      else:
        fail(path, lineNo, "unknown key `" & key & "` in [benchmark]; " &
          "expected allowed-users, allowed-groups, max-queue-wait or max-hold")
    of "enforcement":
      case key
      of "cgroups":
        let raw = parseQuoted(value, path, lineNo)
        case raw
        of "on": result.enforcementCgroups = some(true)
        of "off": result.enforcementCgroups = some(false)
        else:
          fail(path, lineNo, "cgroups must be \"on\" or \"off\", got " &
            value)
      of "job-priority":
        let raw = parseQuoted(value, path, lineNo)
        case raw
        of "on": result.enforcementJobPriority = some(true)
        of "off": result.enforcementJobPriority = some(false)
        else:
          fail(path, lineNo, "job-priority must be \"on\" or \"off\", got " &
            value)
      of "qos":
        let raw = parseQuoted(value, path, lineNo)
        case raw
        of "on": result.enforcementQos = some(true)
        of "off": result.enforcementQos = some(false)
        else:
          fail(path, lineNo, "qos must be \"on\" or \"off\", got " & value)
      of "memoryCap":
        let raw = parseQuoted(value, path, lineNo)
        case raw
        of "off": result.enforcementMemoryCap = some(mcmOff)
        of "advisory": result.enforcementMemoryCap = some(mcmAdvisory)
        of "kill": result.enforcementMemoryCap = some(mcmKill)
        else:
          fail(path, lineNo, "memoryCap must be \"off\", \"advisory\" or " &
            "\"kill\", got " & value)
      of "memoryCapFactor":
        # A FACTOR BELOW 1.5 IS REFUSED, NOT RAISED TO 1.5: a cap that close
        # to the largest successful peak would kill healthy runs on ordinary
        # run-to-run noise, and an operator who wrote 1.2 meant something
        # this file cannot give them. Better the file does not parse and
        # says why than a cap other than the one written down.
        var milli = 0'u32
        if not parseFactorMilli(value, milli):
          fail(path, lineNo, "memoryCapFactor must be a number such as 2 " &
            "or 1.5 (at most three decimals), got " & value)
        if milli < MinMemoryCapFactorMilli:
          fail(path, lineNo, "memoryCapFactor must be at least 1.5 (a " &
            "smaller factor kills healthy runs on run-to-run noise), got " &
            value)
        result.memoryCapFactorMilli = some(milli)
      else:
        fail(path, lineNo, "unknown key `" & key & "` in [enforcement]; " &
          "expected cgroups, job-priority, qos, memoryCap or memoryCapFactor")
    else:
      let reserved = reservationClassOf(section)
      if reserved.len == 0:
        discard
      else:
        var entry = result.reservations[reserved]
        case key
        of "cpu-milli":
          let v = parseInteger(value, path, lineNo)
          if v > uint64(high(uint32)):
            fail(path, lineNo, "cpu-milli out of range: " & $v)
          entry.cpuMilli = v
        of "memory-bytes":
          entry.memoryBytes = parseInteger(value, path, lineNo)
        of "lend":
          case value
          of "true": entry.lend = true
          of "false": entry.lend = false
          else:
            fail(path, lineNo, "lend must be true or false, got " & value)
        of "socket-owner", "socket-group", "socket-mode", "allowed-users",
            "allowed-groups":
          # THE OTHER PLATFORM'S KEY IS REFUSED, naming the platform: a
          # file written for a Windows host would otherwise leave a class
          # here claimable by nobody, silently.
          let windowsKey = key in WindowsClassSocketKeys
          if windowsKey != (platform == hcpWindows):
            let keyPlatform = if windowsKey: hcpWindows else: hcpPosix
            fail(path, lineNo, "`" & key & "` in [" & section & "] is a " &
              platformText(keyPlatform) & " key, and this file is read " &
              "for " & platformText(platform) & ", where who may claim a " &
              "class is set with " &
              (if platform == hcpWindows: WindowsClassSocketKeys.join(", ")
               else: PosixClassSocketKeys.join(", ")))
          case key
          of "socket-owner", "socket-group":
            let raw = parseQuoted(value, path, lineNo)
            let isGroup = key == "socket-group"
            let id = resolveAccountId(raw, isGroup)
            if id > MaxAccountId:
              fail(path, lineNo, key & " " & value & " in [" & section &
                "] is out of range: an id is at most " & $MaxAccountId &
                " (4294967295 means \"unchanged\" to chown)")
            if id < 0:
              fail(path, lineNo, key & " " & value & " in [" & section &
                "] names no " & (if isGroup: "group" else: "user") &
                " on this host; give a " &
                (if isGroup: "group name or decimal gid"
                 else: "user name or decimal uid"))
            if isGroup:
              entry.socketGroup = raw
              entry.socketGroupGid = id
            else:
              entry.socketOwner = raw
              entry.socketOwnerUid = id
          of "socket-mode":
            var mode = 0
            if not classSocketModeOf(parseQuoted(value, path, lineNo), mode):
              fail(path, lineNo, "socket-mode must be one of \"" &
                ClassSocketModes.join("\", \"") & "\" (owner only, owner " &
                "and group, every local user), got " & value &
                "; connecting to a Unix socket needs write permission, " &
                "so other modes grant nothing they seem to")
            entry.socketMode = mode
          of "allowed-users":
            entry.allowedUsers = parseStringArray(value, path, lineNo)
          else:
            entry.allowedGroups = parseStringArray(value, path, lineNo)
        else:
          fail(path, lineNo, "unknown key `" & key & "` in [" & section &
            "]; expected " & ReservationKeys.join(", "))
        result.reservations[reserved] = entry
  # THE THRESHOLDS ARE JUDGED TOGETHER, after the defaults fill an absent
  # one: a gate that closes above 4 and opens only below 5 would reopen at
  # once, which is a mistake about the other key's default, not a setting.
  let high = result.pressureHighPct.get(DefaultPressureHighPct)
  let low = result.pressureLowPct.get(DefaultPressureLowPct)
  if low > high:
    fail(path, lineNo, "admission pressure-low (" & $low &
      ") is above pressure-high (" & $high & "); the gate opens below " &
      "pressure-low and closes above pressure-high")

proc readHostConfig*(path = hostConfigPath;
                     platform = currentHostConfigPlatform()): HostConfig =
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
  parseHostConfig(text, path, platform)

proc enforcementCgroupsOn*(problem: var string;
                           path = hostConfigPath): bool =
  ## `[enforcement] cgroups` of the host file, for a LAUNCHING CLIENT
  ## (RunQuota's CLI launchers, Reprobuild's build header): true only when
  ## the file turns it on. A file that cannot be read or parsed answers
  ## false with `problem` set: a launcher never fails over a setting it
  ## only consults.
  problem = ""
  try:
    readHostConfig(path).enforcementCgroups.get(false)
  except CatchableError as failure:
    problem = failure.msg
    false

proc enforcementJobPriorityOn*(problem: var string;
                               path = hostConfigPath): bool =
  ## `[enforcement] job-priority` of the host file, for a LAUNCHING CLIENT
  ## (RunQuota's CLI launchers on Windows): true only when the file turns it
  ## on. A file that cannot be read or parsed answers false with `problem`
  ## set: a launcher never fails over a setting it only consults. Mirrors
  ## `enforcementCgroupsOn`.
  problem = ""
  try:
    readHostConfig(path).enforcementJobPriority.get(false)
  except CatchableError as failure:
    problem = failure.msg
    false

proc enforcementQosOn*(problem: var string;
                       path = hostConfigPath): bool =
  ## `[enforcement] qos` of the host file, for a LAUNCHING CLIENT (RunQuota's
  ## CLI launchers on macOS): true only when the file turns it on. A file
  ## that cannot be read or parsed answers false with `problem` set: a
  ## launcher never fails over a setting it only consults. Mirrors
  ## `enforcementCgroupsOn`.
  problem = ""
  try:
    readHostConfig(path).enforcementQos.get(false)
  except CatchableError as failure:
    problem = failure.msg
    false

proc enforcementMemoryCapMode*(problem: var string;
                               path = hostConfigPath): MemoryCapMode =
  ## `[enforcement] memoryCap` of the host file, for a LAUNCHING CLIENT
  ## (RunQuota's CLI launchers, Reprobuild): `mcmOff` unless the file turns
  ## the cap on. A file that cannot be read or parsed answers `mcmOff` with
  ## `problem` set: a launcher never fails over a setting it only consults.
  ## Mirrors `enforcementCgroupsOn`.
  problem = ""
  try:
    readHostConfig(path).enforcementMemoryCap.get(mcmOff)
  except CatchableError as failure:
    problem = failure.msg
    mcmOff

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
    section*: string
      ## `machine`, `pools`, `admission`, `enforcement` or
      ## `reservation.<class>`
    name*: string

proc parseHostConfigKey*(key: string): HostConfigKey =
  ## `machine.memory_bytes`, `machine.cpu_milli`, `pools.NAME`,
  ## `admission.order`, `admission.max-wait`,
  ## `admission.share-between-users`, `admission.predictive`,
  ## `admission.horizon`, `admission.pressure-high` or
  ## `admission.pressure-low`, `admission.oversubscription`, or
  ## `reservation.<class>.cpu-milli` / `memory-bytes` / `lend`.
  if key.startsWith("reservation."):
    # `reservation.<class>.<key>`: the table is `[reservation.<class>]`.
    let last = key.rfind('.')
    let section = key[0 ..< max(0, last)]
    let class = reservationClassOf(section)
    if last <= 0 or class.len == 0 or last == key.len - 1:
      raise newException(HostConfigError, "unknown key `" & key &
        "`; a reservation is set as reservation.CLASS.KEY, KEY one of " &
        ReservationKeys.join(", "))
    let problem = reservationClassProblem(class)
    if problem.len > 0:
      raise newException(HostConfigError, "`" & key & "`: " & problem)
    result = HostConfigKey(section: section, name: key[last + 1 .. ^1])
    if result.name notin ReservationKeys:
      raise newException(HostConfigError, "unknown key `" & key &
        "`; [" & section & "] has " & ReservationKeys.join(", "))
    return
  let dot = key.find('.')
  if dot <= 0 or dot == key.len - 1:
    raise newException(HostConfigError, "unknown key `" & key &
      "`; expected machine.memory_bytes, machine.cpu_milli, pools.NAME or " &
      "admission.order, admission.max-wait, admission.share-between-users, " &
      "admission.predictive, admission.horizon, admission.pressure-high, " &
      "admission.pressure-low, admission.oversubscription, " &
      "reservation.CLASS.cpu-milli, reservation.CLASS.memory-bytes, " &
      "reservation.CLASS.lend, enforcement.cgroups, enforcement.job-priority, " &
      "enforcement.qos, enforcement.memoryCap, enforcement.memoryCapFactor")
  result = HostConfigKey(section: key[0 ..< dot], name: key[dot + 1 .. ^1])
  case result.section
  of "machine":
    if result.name notin ["memory_bytes", "cpu_milli", "write_bytes_per_sec"]:
      raise newException(HostConfigError, "unknown key `" & key &
        "`; [machine] has memory_bytes, cpu_milli and write_bytes_per_sec")
  of "pools":
    # A pool name is a bare TOML key; the reader applies the same rule.
    if not result.name.isBareKey:
      raise newException(HostConfigError, "pool name `" & result.name &
        "` " & PoolNameRule)
  of "admission":
    if result.name notin ["order", "max-wait", "share-between-users",
        "predictive", "horizon", "pressure-high", "pressure-low",
        "oversubscription"]:
      raise newException(HostConfigError, "unknown key `" & key &
        "`; [admission] has order, max-wait, share-between-users, " &
        "predictive, horizon, pressure-high, pressure-low and " &
        "oversubscription")
  of "enforcement":
    if result.name notin ["cgroups", "job-priority", "qos", "memoryCap",
        "memoryCapFactor"]:
      raise newException(HostConfigError, "unknown key `" & key &
        "`; [enforcement] has cgroups, job-priority, qos, memoryCap and " &
        "memoryCapFactor")
  else:
    raise newException(HostConfigError, "unknown table `" & result.section &
      "` in `" & key & "`; expected machine, pools, admission, enforcement or " &
      "reservation.CLASS")

proc `$`*(key: HostConfigKey): string = key.section & "." & key.name

proc parseHostConfigValue*(key: HostConfigKey; raw: string): uint64 =
  ## The integer a `config set` VALUE names. `machine.memory_bytes` also takes
  ## a binary or decimal unit (`96GiB`, `512MiB`, `64GB`), because a 12-digit
  ## byte count is where typos live. Range and positivity are left to
  ## `parseHostConfig`, which checks the edited file as a whole.
  let text = raw.strip().replace("_", "")
  var digits = text
  var multiplier = 1'u64
  if (key.section == "machine" and
      key.name in ["memory_bytes", "write_bytes_per_sec"]) or
      (key.section.startsWith("reservation.") and key.name == "memory-bytes"):
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
  if (key.section == "machine" and key.name == "memory_bytes") or
      (key.section.startsWith("reservation.") and key.name == "memory-bytes"):
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

proc renderAdmissionEntry(key: HostConfigKey; raw: string): string =
  ## The `[admission]` line a `config set` VALUE stands for. VALUES ARE
  ## SPELLED AS THE DAEMON PRINTS THEM, not as TOML: `starvation,fair-share`
  ## for the order, `90s` for the bound, `none` for the division. The quoting
  ## is added here; whether the result is acceptable is `parseHostConfig`'s
  ## decision, over the edited file as a whole.
  let text = raw.strip()
  if '"' in text or '\\' in text:
    raise newException(HostConfigError, "`" & $key &
      "` takes a plain value without quotes, got `" & raw & "`")
  case key.name
  of "order":
    var quoted: seq[string] = @[]
    for part in text.split(','):
      if part.strip().len > 0:
        quoted.add("\"" & part.strip() & "\"")
    key.name & " = [" & quoted.join(", ") & "]"
  else:
    key.name & " = \"" & text & "\""

proc classSocketEntry(key: HostConfigKey; raw: string): string =
  ## The line for a class-socket key: `socket-owner = "runquota"`,
  ## `socket-mode = "0660"`, `allowed-groups = ["CI Runners", "Builders"]`
  ## (from the comma-separated `CI Runners,Builders`). Whether the value is
  ## acceptable -- a mode outside the three, an unknown user, a key of the
  ## other platform -- is `parseHostConfig`'s decision over the edited file.
  let text = raw.strip()
  if '"' in text or '\\' in text:
    raise newException(HostConfigError, "`" & $key &
      "` takes a plain value without quotes, got `" & raw & "`")
  if text.len == 0:
    raise newException(HostConfigError, "`" & $key & "` needs a value")
  if key.name in WindowsClassSocketKeys:
    var quoted: seq[string] = @[]
    for part in text.split(','):
      if part.strip().len > 0:
        quoted.add("\"" & part.strip() & "\"")
    if quoted.len == 0:
      raise newException(HostConfigError, "`" & $key &
        "` needs at least one name or SID")
    key.name & " = [" & quoted.join(", ") & "]"
  else:
    key.name & " = \"" & text & "\""

proc hostConfigEntry*(key: HostConfigKey; raw: string): string =
  ## The `key = value` line `runquota config set KEY VALUE` writes.
  if key.section.startsWith("reservation.") and
      (key.name in PosixClassSocketKeys or key.name in WindowsClassSocketKeys):
    return classSocketEntry(key, raw)
  if key.section.startsWith("reservation.") and key.name == "lend":
    # A TOML boolean, bare: `lend = true`.
    let text = raw.strip()
    if text notin ["true", "false"]:
      raise newException(HostConfigError, "`" & $key &
        "` takes true or false, got `" & raw & "`")
    return key.name & " = " & text
  if key.section == "enforcement" and key.name == "memoryCapFactor":
    # A bare TOML number, as the spec writes it (`memoryCapFactor = 2`): the
    # factor is a number, and the reader refuses a quoted one.
    let text = raw.strip()
    var milli = 0'u32
    if not parseFactorMilli(text, milli):
      raise newException(HostConfigError, "`" & $key &
        "` takes a number such as 2 or 1.5, got `" & raw & "`")
    return key.name & " = " & text
  if key.section in ["admission", "enforcement"]:
    # `[enforcement] cgroups` is a quoted `on` / `off`, like
    # `[admission] predictive`.
    renderAdmissionEntry(key, raw)
  else:
    renderEntry(key, parseHostConfigValue(key, raw))

proc setHostConfigEntry(text: string; key: HostConfigKey;
                        entry: string): string =
  ## `text` with `key` set by `entry` (its `key = value` line): the key's
  ## line replaced when it has one (its old trailing comment goes with it,
  ## because it described the old value), otherwise a line added at the end of the key's table, and the
  ## table appended when the file has none. Not validated here; see
  ## `editHostConfig`.
  var lines = linesOf(text)
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

proc setHostConfigValue*(text: string; key: HostConfigKey;
                         value: uint64): string =
  ## `setHostConfigEntry` for an integer key (`[machine]`, `[pools]`).
  setHostConfigEntry(text, key, renderEntry(key, value))

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
    result = setHostConfigEntry(before, parsedKey,
      hostConfigEntry(parsedKey, value))
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
