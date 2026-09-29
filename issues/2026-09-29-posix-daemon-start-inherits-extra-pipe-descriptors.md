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
