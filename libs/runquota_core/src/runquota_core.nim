import runquota_core/types

export types

when defined(posix):
  # Descriptor hygiene is shared by the IPC and process layers, both of which
  # sit above runquota_core, so the primitives live here rather than being
  # duplicated on either side.
  import runquota_core/fd_hygiene
  export fd_hygiene

const RunQuotaVersion* = "0.1.0"

proc versionString*(): string =
  RunQuotaVersion
