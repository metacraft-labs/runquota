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
