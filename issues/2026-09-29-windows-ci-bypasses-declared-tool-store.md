# Windows CI bypasses RunQuota's declared tool-store environment

Status: open. Observed at RunQuota `822c3c5` with Reprobuild `c14b1e61`.

[Windows Reprobuild job 109318839771](https://github.com/metacraft-labs/runquota/actions/runs/36541698901/job/109318839771)
reports 148 successful actions, 47 failures and one blocked action. Database
tests cannot find `sqlite3`; observation stores enter `degraded-no-sqlite-tool`.
The CI command forces `--tool-provisioning=path` even though `repro.nim`
declares Windows tarball provisioning and `sqlite3 >=3`. The bootstrap's
SQLite DLL is not the CLI used by the observation store.

[Dependency provisioning](../../reprobuild-specs/Dependency-Provisioning-In-Build-Graph.md)
requires the declared tools to be realized. Honor the product's Windows
archive provisioning in both build and test commands, while retaining Nix
on POSIX. The catalog's SQLite archive is pinned by hash. Keep all tests;
an intentionally degraded store is not a successful persistence test.

Other failures need separate attribution after tool provisioning is repaired:
the service account cannot create one NULL-DACL fixture without
`SeSecurityPrivilege`, its segment group fixtures cannot express group bits,
the saturated-load fixture reaches only 39–58% busy, and the benchmark test
tries to overwrite `runquotad.exe` while other tests are using it. These are
not all established consequences of the missing SQLite CLI.

Diagnostic `36545657599` runs the unchanged candidate with tarball provisioning
on a fresh Windows 2025 host. It will verify SQLite execution before the full
graph. Ordinary CI and its legacy cross-check remain required.

Refreshed dev `e9f9011` and agents `822c3c5`; searched current and deleted
issues for SQLite and provisioning before recording. The earlier POSIX
override issue concerned a different platform and retained Windows PATH mode.

The benchmark fixture now builds the real copied source in a private temporary
tree and verifies the shared daemon's hash is unchanged. It retains the real
compiler, benchmark, daemon and all output assertions. This addresses the
observed attempt to overwrite an executable used by concurrent tests; the
Windows rerun remains required.

The NULL-DACL fixture also used the one-argument .NET SDDL setter, which marks
the audit ACL for persistence. At `822c3c5`, job `109318839771` fails exactly
there with `SeSecurityPrivilege` missing. The fixture now selects only
`AccessControlSections.Access`; it still creates the same permissive DACL
and retains the daemon-refusal assertion. This matches the
[Microsoft API contract](https://learn.microsoft.com/en-us/dotnet/api/system.security.accesscontrol.objectsecurity.setsecuritydescriptorsddlform?view=netframework-4.8.1)
and needs a native Windows rerun. No account privileges are changed.

Hosted Windows diagnostic `36547956528` at `7511801` with the real bootstrap
daemon and declared SQLite passes 186 of 196 actions (nine fail, one blocks).
The two child-identity fixtures call `findExe("cmd")` and receive an empty
path. Use the test executable itself as the real exited/live child; retain
the OS process identity and reaping assertions. The ACL helper finds cmd by
absolute path, but the verbatim operator command cannot find `icacls` in its
child PATH. Give only that child the resolved Windows system directory,
preserving the printed command and all independent ACL checks.

The atomicity fixture records 109 samples but only three distinct values,
the same incomplete-coverage wait recorded in
`2026-09-29-atomicity-stress-test-assumes-ten-second-throughput.md`.
The remaining failures need attribution: one daemon startup misses its
four-second bound; the completion latency control measures 2.0199 ms against
2 ms; storage class is unknown on the hosted disk; the benchmark subprocess
exits with access violation. The host-load fixture prints all three passing
cases but its monitored shell exits 127. Its capacity and saturation assertions
pass on this four-core host. These results do not validate the old service
account's group ACL or 24-core saturation failures.

The recipe currently permits the CPU-saturating host-load and atomicity
programs to overlap the latency control and ordinary compiler/test work.
Extend its existing end-of-suite scheduling for ambient-load attribution to
all four measurement programs: finish all compilations and ordinary tests
first, then run these programs sequentially. Retain every assertion and
latency/coverage threshold. A new native run must establish whether this
removes the observed interference; it is not evidence about the unexplained
exit statuses or disk classification.

At `c99e76d`, ordinary Windows x64 job `109388919586` now gets through
SQLite provisioning. The NetworkService runner cannot express `0640` or
`0660` over files whose primary group is also their owner, so six segment
publication/scope programs fail. This refusal is intentional under
[Segment files and their mode on Windows](../../reprobuild-specs/RunQuota-Shared-Memory-Structures.md):
the optional stats table remains unpublished in that account context.
Use the same shared runner selector as the other public CI lanes for Windows
x64 (`windows-2025`, with the existing self-hosted fallback). Preserve all
publication and access assertions on the distinct-owner/group native account.
The separate 50-handle increase in the connection-abort test still needs
attribution; the runner selection does not establish that it is fixed.

The `292e578` PowerShell diagnostic completes at `36558849865`: SQLite works,
and direct/timeout controls of the four measurement programs mostly pass.
Completion latency uses an unsuitable wall clock (recorded separately).
The benchmark fails with an access violation inside the full monitored graph
and exit 1 in both controls; retain stdout too and compare pinned PortableGit
against the hosted Git Bash before attributing that difference.

## Atomicity process exit at `8add804`

[Windows x64 job 109446770868](https://github.com/metacraft-labs/runquota/actions/runs/36580081181/job/109446770868)
now passes 194 of 198 actions, including all 100 cached build actions. The
atomicity program prints its sole passing assertion: 81 checked rows, 457
steps, seven distinct self values and zero violations. Its monitored
`sh -c 'timeout --kill-after=10 600 ... </dev/null'` action nevertheless exits
127, blocking the three subsequent measurement programs. There is no stderr.
This repeats the unexplained shell-exit shape previously seen in the host-load
fixture; it does not establish a failed atomicity assertion or its cause.

Preserve every measurement and deadline. Compare real unchanged binaries
through native execution, the declared shell/timeout, and the monitored graph,
recording hashes and each process's actual exit status. The failed graph
remains failed even when a direct control passes. Refreshed dev `e9f9011` and
searched open/deleted exit-127 issues before extending this record. The report
is retained locally in `/tmp/runquota-8add-windows-repro-artifacts/`.
