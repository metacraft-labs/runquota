import runquota_core/types

export types

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
