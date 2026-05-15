import runquota_core/types

export types

const RunQuotaVersion* = "0.1.0"

proc versionString*(): string =
  RunQuotaVersion
