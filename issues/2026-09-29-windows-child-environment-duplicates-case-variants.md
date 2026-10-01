# Windows child environment overrides can duplicate case variants

| | |
| --- | --- |
| Status | in-progress; native old/fixed control passes; full consumer validation pending |
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

## Native Windows result

Shared-actions run `36557091691` executes the same real-child regression
against `11548ab` and `292e578`. The old launcher produces `matches=3` and
`lookup=first-override`; the repaired launcher passes every assertion,
including a single entry containing the last override. The regression uses
the actual OS environment block and leaves the parent unchanged.

Shared-actions PR 38 adds an explicit bootstrap dependency input and passes
all seven contract CI jobs at `d966f7a`. This candidate selects `292e578`
for the separately built Reprobuild launcher as well. Full Windows graph
validation remains required before attributing the missing SQLite to it.

## Final application qualification (2026-10-01)

The actual Windows child-environment regression passes. The earlier missing-SQLite failure remains unattributed; closing this source defect does not assign that cause.

These results are measured at `d6ee4588f71604376a4cc41ef281d6c479395efc`
in [run 36823482913](https://github.com/metacraft-labs/runquota/actions/runs/36823482913).
All application test programs pass on the five development hosts. The ARM
workflow still fails its subsequent, separate static-helper ACL gate; that
issue remains open and is not attributed to this repaired defect.
Ordinary [CI at `2d07c5d`](https://github.com/metacraft-labs/runquota/actions/runs/36846644651)
passes all ten jobs with unchanged application sources and fixtures.
