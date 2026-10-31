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

# Opt-in model for PRIVATE fixtures declaring the inspected endpoint GID.
# A fresh directory may inherit its parent's group on BSD; the caller's primary
# GID is not a portable substitute for the actual endpoint's group. Shared/foreign/default-group tests keep their explicit policy
# and the owner-only binding above; this is not a suite-wide environment setup.
type PrivateBrokerCallerPolicyBinding* = object
  active: bool
  owner: PrivateBrokerOwnerBinding
  hadPreviousGroup: bool
  previousGroup: string

proc restorePrivateBrokerPolicy*(binding: PrivateBrokerCallerPolicyBinding) =
  when defined(posix):
    if not binding.active: return
    try:
      if binding.hadPreviousGroup:
        putEnv("RUNQUOTA_ENDPOINT_GROUP", binding.previousGroup)
      else:
        delEnv("RUNQUOTA_ENDPOINT_GROUP")
    finally:
      restorePrivateBrokerOwner(binding.owner)

proc bindPrivateBrokerPolicyToCaller*(fixtureGid: int64): PrivateBrokerCallerPolicyBinding =
  when defined(posix):
    if fixtureGid < 0:
      raise newException(ValueError, "private fixture group must be nonnegative")
    result.owner.hadPrevious = existsEnv("RUNQUOTA_ENDPOINT_OWNER_UID")
    result.owner.previous = getEnv("RUNQUOTA_ENDPOINT_OWNER_UID")
    result.hadPreviousGroup = existsEnv("RUNQUOTA_ENDPOINT_GROUP")
    result.previousGroup = getEnv("RUNQUOTA_ENDPOINT_GROUP")
    result.active = true
    try:
      putEnv("RUNQUOTA_ENDPOINT_OWNER_UID", $getuid())
      putEnv("RUNQUOTA_ENDPOINT_GROUP", $fixtureGid)
    except:
      restorePrivateBrokerPolicy(result)
      raise

proc privateEndpointGroup*(endpointDir: string): int64 =
  ## Inspect only an endpoint just created by this fixture, before setting its
  ## policy-derived mode. Foreign paths under test must never supply policy.
  when defined(posix):
    var info: Stat
    if lstat(endpointDir.cstring, info) != 0:
      raiseOSError(osLastError())
    if not S_ISDIR(info.st_mode) or info.st_uid != getuid():
      raise newException(ValueError, "private endpoint must be a caller-owned directory")
    result = int64(info.st_gid)
