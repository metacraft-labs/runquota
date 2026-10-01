# POSIX daemon start retains the caller's output through extra descriptors

Status: open. Observed at `571e2cb` plus the endpoint fixture permission repair.

The real daemon starts after fixing the fixture's 0755 directory, but the
stream-detachment test still fails its 60-second EOF deadline on macOS.
`lsof` shows the detached daemon has stdout/stderr redirected to its log while
also retaining inherited pipe descriptors 3, 5, 6, 8–12. Killing this exact
daemon releases EOF. The failure is independent of directory permissions.

The [daemon command contract](../docs/book-isonim/content/usage_guide/daemon.md)
requires the start command to return without keeping the caller's streams open.
`std/osproc.startProcess` replaces standard streams but does not close every
inherited descriptor. Reuse `runquota_process.launchProcess` on POSIX, whose
fork/exec path already closes inherited descriptors without allocating in the
child. Keep the Windows no-handle-inheritance launcher and the existing real
EOF/log/identity test assertions.

Refreshed dev `e9f9011` and searched current/deleted issues for daemon-start,
stream detachment and inherited descriptors. This records the product defect
exposed after the separate fixture permission defect.

Local macOS verification at `571e2cb` plus the repair: both real daemon-start
cases pass. The endpoint-only control fails the EOF deadline; the original
fixture fails before daemon startup. Logs: `/tmp/runquota-daemon-start-control.log`,
`/tmp/runquota-daemon-start-fixed.log`, `/tmp/runquota-daemon-start-hygiene.log`.
Native Linux CI remains required.

## Final application qualification (2026-10-01)

The real POSIX daemon-start stream-detachment checks pass on Linux and macOS.

These results are measured at `d6ee4588f71604376a4cc41ef281d6c479395efc`
in [run 36823482913](https://github.com/metacraft-labs/runquota/actions/runs/36823482913).
All application test programs pass on the five development hosts. The ARM
workflow still fails its subsequent, separate static-helper ACL gate; that
issue remains open and is not attributed to this repaired defect.
Ordinary [CI at `2d07c5d`](https://github.com/metacraft-labs/runquota/actions/runs/36846644651)
passes all ten jobs with unchanged application sources and fixtures.
