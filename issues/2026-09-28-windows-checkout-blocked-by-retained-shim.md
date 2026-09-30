# Persistent Windows runner cannot clean a retained monitor DLL

- Status: open
- Observed in: RunQuota CI at `e9e487a` and `939c38a`

## Observed

The Windows compile gate fails in actions/checkout before building anything:
EPERM unlinking reprobuild/build/lib/librepro_monitor_shim.dll in the reused
workspace on win-ci-bare-001. A file from an earlier job remains loaded.

## Expected and repair

The repository's native compile gate must start from a clean checkout.
For 0.1.0 validation, use a fresh GitHub-hosted windows-2025 VM. Owner: zah.
Both self-hosted Windows x64 VM pools are declaratively paused: win-hms for
metacraft-labs in win-hms-pause.nix, and win-wincibare pending its lifecycle
canary. An eph-win-x64 alias would therefore queue indefinitely. Return this
gate to the self-hosted pool when its lifecycle canary passes and the pool is
enabled. Keep checkout cleanup enabled. This removes dependence on the
persistent runner's previous jobs; the underlying orphan process needs a
separate runner investigation and is not claimed fixed by this routing change.

Evidence: [job at 939c38a](https://github.com/metacraft-labs/runquota/actions/runs/36425395712/job/108937990253).
Fleet contract: infra/docs/runbooks/Ephemeral-Runner-Fleet.runbook.md and
infra/machines/server/high-mem-server/central-garm.nix Windows pool tags.
Refreshed origin/dev and agents; searched open and archived issues for retained
monitor DLLs before recording.
