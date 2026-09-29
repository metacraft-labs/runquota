# Windows hardware fixture requires a disk type the virtual disk does not expose

| | |
|---|---|
| Status | in-progress; fix/release-validation-failures |
| Recorded | 2026-09-29 |
| Observed in | RunQuota `292e578`, diagnostic `36558849865` |
| Area | `t_observation_store_host_profile.nim` |

## Observed

The real hardware detector returns a stable CPU, OS and NTFS filesystem profile,
but the test rejects `diskClass == dcUnknown`. Both unchanged-binary reruns fail
the same assertion. Independent PowerShell storage queries report two
`Msft Virtual Disk` devices, SAS bus, and `MediaType: Unspecified`.
The source API documents `VolumeFacts.solidState == -1` as unavailable.

## Expected

The observation library's documented detection contract permits honest unknown
fields. The shared observation-store spec requires stable hardware identity,
versioning and reuse; its disk-class table omits the unavailable case.
Proposed clarification: preserve unknown media type when Windows cannot supply
it. The stability test must continue checking CPU, OS, filesystem, profile hash,
row reuse and versioning, without requiring every virtual disk to expose a
physical media type. Keep the detector unchanged.

## Evidence

Artifact `runquota-windows-toolstore-292e578` contains the direct and wrapped
test logs plus `physical-disks.json`, `disks.json` and `logical-disks.json`.
Refreshed `origin/dev` at `e9f9011` and searched current/deleted disk-class
issues. The previous Linux issue concerns absent sysfs block devices; the
Windows provisioning issue lists this symptom but has no media-type diagnosis.
The observation library README also incorrectly says Windows detection does
not exist; update it to describe the implemented native API and unknown fields.
