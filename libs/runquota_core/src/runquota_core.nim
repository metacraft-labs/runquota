import runquota_core/types
import runquota_core/memory_cap

export types, memory_cap

when defined(posix):
  # Descriptor hygiene is shared by the IPC and process layers, both of which
  # sit above runquota_core, so the primitives live here rather than being
  # duplicated on either side.
  import runquota_core/fd_hygiene
  export fd_hygiene

const RunQuotaVersion* = "0.1.3"

proc versionString*(): string =
  RunQuotaVersion

const InteractiveSessionGroup* = "interactive"
  ## The group a session joins when its client names none: one per user,
  ## keyed by the owner uid the daemon reads from peer credentials, so two
  ## users' unlabelled sessions never share one.

const MaxSessionGroupBytes* = 128
  ## The longest session group name the protocol carries. A group name is a
  ## launcher's session handle (for example `<host>:<window>`), far shorter
  ## than this.

proc sessionPriorityName*(priority: SessionPriority): string =
  ## The spelling used by `RUNQUOTA_SESSION_PRIORITY`, `runquota session
  ## set --priority`, and the inspection JSON.
  case priority
  of sessionPriorityLow: "low"
  of sessionPriorityNormal: "normal"
  of sessionPriorityHigh: "high"
  of sessionPriorityUrgent: "urgent"

proc parseSessionPriority*(text: string; priority: var SessionPriority): bool =
  ## The inverse of `sessionPriorityName`. Exact, lower-case spellings only:
  ## a launcher that writes `HIGH` or `hi` is told so by its caller rather
  ## than silently given a level it did not ask for.
  for candidate in SessionPriority:
    if text == sessionPriorityName(candidate):
      priority = candidate
      return true
  false

const MaxClassNameBytes* = 64
  ## The longest class name (`RUNQUOTA_CLASS`).

proc classNameProblem*(name: string): string =
  ## Why `name` cannot be a class name, or "" when it can: 1 to
  ## `MaxClassNameBytes` bytes of ASCII letters, digits, `_` and `-`. A class
  ## is named by a launcher and by the host file's `[reservation.<class>]`
  ## table header, so the rule is the bare-key rule of that file: every class
  ## a client can name can be given a reservation. (The host file's reader,
  ## `runquota_daemon/host_config`, states the same rule for itself, since
  ## it imports only the standard library.)
  if name.len == 0:
    return "a class name must not be empty"
  if name.len > MaxClassNameBytes:
    return "a class name is at most " & $MaxClassNameBytes & " bytes, got " &
      $name.len
  for ch in name:
    if ch notin {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '_', '-'}:
      return "a class name may hold only ASCII letters, digits, `_` and `-`"
  ""

proc sessionGroupNameProblem*(name: string): string =
  ## Why `name` cannot be a session group name, or "" when it can. Empty is
  ## not a name (it means "no group" on the wire); control bytes would make
  ## the name unprintable in `runquota status`.
  if name.len == 0:
    return "a session group name must not be empty"
  if name.len > MaxSessionGroupBytes:
    return "a session group name is at most " & $MaxSessionGroupBytes &
      " bytes, got " & $name.len
  for ch in name:
    if ord(ch) < 0x20 or ord(ch) == 0x7f:
      return "a session group name must not contain control characters"
  ""
