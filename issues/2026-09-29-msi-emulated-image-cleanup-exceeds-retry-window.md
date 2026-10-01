# Windows ARM64 retains the extracted x64 image beyond thirty seconds

Status: open. Observed at release candidate `d6d65ad`, job `109159274425`.

The x64 MSI passes ICE validation, all 20 table assertions, administrative
extraction, every payload hash and the real client/daemon/lease smoke. No
payload process remains according to the CIM census. Deleting the extracted
x64 runquota.exe still reports access denied after thirty retries, so the
ARM64 MSI checks and assembly do not run.

The earlier resolved cleanup issue recorded the same OS image-retention
symptom clearing after 22 seconds at `939c38a`. Its thirty-second retry was
therefore insufficient on this run; it is not evidence of a new MSI payload
failure. Keep every check and make cleanup failure fatal after a bounded
120 attempts. Record elapsed time, ACLs and actual Restart Manager file users
to distinguish delayed image release from an active owner. Do not kill other
processes or weaken payload verification.

The [release specification](../../metacraft-specs/infrastructure/gosti-io-mon-runquota-releases.md)
requires full MSI evidence before assembly. Refreshed dev `e9f9011`, searched
open and deleted issues, and read the resolved
`2026-09-28-msi-validation-cleanup-hides-original-error.md` at `a889665^`.
