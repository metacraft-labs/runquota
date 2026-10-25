## Scoped owner selection for a private broker launched by this test process.
## Bind before private startup and restore with defer. A broker under another
## real UID must select that owner inside the child, not use the outer caller.
import std/os
when defined(posix):
  import std/posix

type PrivateBrokerOwnerBinding* = object
  hadPrevious: bool
  previous: string

proc bindPrivateBrokerOwnerToCaller*(): PrivateBrokerOwnerBinding =
  when defined(posix):
    result.hadPrevious = existsEnv("RUNQUOTA_ENDPOINT_OWNER_UID")
    result.previous = getEnv("RUNQUOTA_ENDPOINT_OWNER_UID")
    putEnv("RUNQUOTA_ENDPOINT_OWNER_UID", $getuid())

proc restorePrivateBrokerOwner*(binding: PrivateBrokerOwnerBinding) =
  when defined(posix):
    if binding.hadPrevious:
      putEnv("RUNQUOTA_ENDPOINT_OWNER_UID", binding.previous)
    else:
      delEnv("RUNQUOTA_ENDPOINT_OWNER_UID")
