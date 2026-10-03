# Release authoring does not carry the current host-configuration contract

| | |
|---|---|
| Status | in-progress |
| Recorded | 2026-10-03 |
| Observed in | RunQuota `f5623f9ad4fed076f58835813a12617ecf7e33b3` |
| Area | `flake.nix`, `packaging/release_metadata.nim`, shared release packaging |

## Observed

Release rehearsal [37141581538](https://github.com/metacraft-labs/runquota/actions/runs/37141581538)
fails on Windows x64 after successfully building both shipping executables:

```text
packaging/runquota_dist.nim(119, 56) Error: undeclared identifier: 'HostDirectory'
Compilation failed: packaging/release_metadata.nim
```

The pinned packaging source is Reprobuild `a04cf4d2`, before `HostDirectory`
and `HostSeedFile` were introduced in `fb9f2e76`. The regular product tests
check the packaging contract structurally but do not compile this release
entry point against that pin.

Two further source mismatches are present at the same candidate:

- Host seed paths such as `etc/runquotad.toml` are relative to the packaging
  recipe directory. The release renderer runs from the repository root and
  passes them unchanged to WiX, where that file is absent.
- `packaging/repro.nim` declares the POSIX configuration component, but
  `release_metadata.nim` emits only the executable and license components.
  Shared release tooling `96ac63b9` copies no external configuration files and
  emits no Debian conffiles, RPM config flags or Arch backup entry for them.

## Expected

`docs/database.md`, **The host budget file**, requires the canonical template
at `/etc/runquota/runquotad.toml` in Linux packages and a protected,
Permanent/NeverOverwrite seed under CommonAppDataFolder in the MSI.
`docs/releasing.md`, **Targets and checks**, requires release formats to use
RunQuota's existing Distribution authoring. Reprobuild's
`Distribution-And-Packaging.md` §6 requires one runtime contract across formats.

Pin packaging sources that implement the declared API. Resolve seed input
paths from the canonical packaging directory. Share the POSIX configuration
component declaration and carry it through release metadata into every Linux
package, preserving operator edits. Verify actual generated authoring,
package contents/config flags and MSI tables; retain all existing gates.

## Evidence and search

Fetched current `origin/agents` (`f5623f9a`) before filing. Searched current
issues and issue history for `HostDirectory`, `release_metadata`,
`release-packaging-src`, packaging and host-budget findings. The earlier
Windows template-byte issue was resolved by `020e695`; this is a separate
release-authoring path and dependency mismatch.
