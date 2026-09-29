# macOS telemetry fixture loses the reason its sentinel did not become ready

Status: open. Observed at RunQuota `8add804`.

## Observed

[macOS Reprobuild job 109446771064](https://github.com/metacraft-labs/runquota/actions/runs/36580081181/job/109446771064)
passes 193 of 198 actions and fails
`t_runquota_host_macos_native_process_telemetry`. Its first two assertions
pass. The process-tree case reaches the sentinel wait after the root/branch
readiness files appear, then fails the existing five-second deadline:
`fixture did not report ready: .../sentinel.ready`. Four subsequent measurement
programs are blocked. The native workflow passes all 486 checks at the same
source commit, but that does not establish this failure's cause.

`startFixture` captures child stdout/stderr in a pipe. The failed readiness
wait neither records whether the sentinel exited nor reads its output, and
cleanup deletes the fixture directory. The retained action report therefore
cannot distinguish slow startup, an exited child, or a blocked child.

## Expected and investigation

[The release validation spec](../../metacraft-specs/infrastructure/gosti-io-mon-runquota-releases.md)
requires both ordinary build/test paths and their original assertions. Preserve
the process-tree, CPU-time, memory and untouched-sentinel checks. Before changing
a deadline, compare native and monitored real-child startup and retain child
output, process identity/exit status and readiness evidence on failure. No
telemetry implementation defect or timeout repair is established yet.

Refreshed dev `e9f9011`; searched current issues and deleted issue history for
telemetry and `sentinel.ready`. No earlier record was found. The failure report
is retained in `/tmp/runquota-8add-macos-repro-artifacts/`.

## Focused controls

At `8add804`, hosted diagnostic
[36591592367](https://github.com/metacraft-labs/metacraft-github-actions/actions/runs/36591592367)
passes the original monitored target, five instrumented monitored repetitions,
and direct execution of the same instrumented binary. Instrumentation sends
child output to the parent's log and reports child mode/PID/exit status at the
unchanged readiness deadline. No control reproduces the failure. Local native
and monitored controls also pass. The next control keeps this instrumentation
inside the complete ordinary graph, preserving its concurrent work.

## Complete-graph control

At `8add804`, control
[36598252254](https://github.com/metacraft-labs/metacraft-github-actions/actions/runs/36598252254)
reproduces the sentinel timeout inside the complete graph. Both recorded root
and sentinel processes are still alive (`peekExitCode == -1`) at the unchanged
five-second deadline. Original focused execution, three later instrumented
focused runs and direct execution all pass. No child crash was observed.

The instrumentation edit also makes the prebuilt daemon older than a file
under `libs/`; 29 other programs refuse that stale binary before testing. Those
are diagnostic setup failures. Rebuild the apps after editing the diagnostic
fixture in any repeated complete-graph control.

Place this CPU/memory process-tree measurement with the existing serialized
measurement programs, after compilation and ordinary tests. Preserve every
assertion and the five-second deadline. Retain child output and report its
PID/exit status on failed readiness. A complete rerun must establish whether
this removes the observed interference; the alive status alone does not
separate slow startup from a blocked child.
