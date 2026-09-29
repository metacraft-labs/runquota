# Windows child environment overrides can duplicate case variants

| | |
| --- | --- |
| Status | in-progress; native regression control pending |
| Recorded | 2026-09-29 |
| Observed in | RunQuota `11548ab`; `windowsChildEnv` |
| Area | libs/runquota_process/src/runquota_process.nim |

## Observed

`windowsChildEnv` calls `newStringTable()` with its case-sensitive default,
copies inherited variables, then inserts overrides under their given spelling.
An inherited `Path` and a `PATH` override therefore coexist in that table.
This is a source-level finding; a native child-process control is pending.

Ordinary Windows job `109349836299` at `2efa366` passes 150/196 actions and
reports `findExe("sqlite3").len was 0` despite explicit tarball provisioning.
The hosted diagnostic at `7511801` finds SQLite and passes 186/196 actions.
Those runs enter through PowerShell and Bash respectively. Case-variant
environment inheritance is a candidate explanation, not an established cause.

## Expected

Not specified explicitly in the RunQuota protocol spec. Proposed: retain the
existing process-contract test's rule that overrides replace inherited values
without duplicate entries, applying Windows' case-insensitive name semantics.
[Microsoft documents that distinction](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_environment_variables).
The parent environment must remain unchanged.

## Repair and validation

Use `modeCaseInsensitive` for the Windows child table. Add a real child-process
regression that inherits a mixed-case name, applies differently cased repeated
overrides and reads the child's actual environment block. Require exactly one
entry with the last value and an unchanged parent. Compile/run the same test
against old and repaired launchers on Windows before claiming the cause fixed.

Refreshed dev `e9f9011` and searched current/deleted issues for environment,
PATH and case-insensitive overrides; no prior issue was found.
