# Windows test watchdog only terminates the direct child

| | |
| --- | --- |
| Status | open |
| Recorded | 2026-10-01 |
| Observed in | RunQuota `2d3897c` (same helper at dev `2c50aaf`) |
| Area | `tests/support/child_watchdog.nim` |

## Observed

The helper documents whole-tree cleanup, including wedged grandchildren.
`killProcessTree` sends a group signal only under `defined(posix)`; its
Windows path calls `kill(process)` and waits for that direct child only.
`survivingProcesses` invokes `ps -axo pid=,command=` on every platform;
it does not establish that its Windows inventory covers native children.
These are source observations, not a newly reproduced Windows leak.

## Expected

Not specified for Windows. Proposed: make the helper's documented whole-tree
cleanup and survivor-check contract hold for native Windows children too,
or state the narrower coverage explicitly. The implementation's introductory
contract says a deadlock test must clean up its own grandchildren and verify
that no survivors remain. The existing Windows implementation does not
provide the same mechanism as the POSIX path.

## Evidence and scope

Read `startSupervisedChild`, `killProcessTree` and `survivingProcesses` at
`2d3897c`. Refreshed dev `2c50aaf`; searched current issues and the issue
archive for `child_watchdog` and `killProcessTree`. The existing issue
`2026-09-29-windows-arm-host-system-children-fail-under-monitor.md` records
SQLite survivors after an older diagnostic, but does not attribute them to
this helper. Do not infer that attribution from this source gap.

Add a real Windows parent/grandchild control with an independently checked
grandchild PID before choosing a process-tree supervision mechanism. This is
a test helper; `runquotad` must remain a lease authority and must not acquire
responsibility for terminating client process trees.
