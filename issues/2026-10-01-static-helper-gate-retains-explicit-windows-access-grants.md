# Windows static-helper gate retains a foreign access grant

Status: open. Observed at RunQuota `d6ee4588f71604376a4cc41ef281d6c479395efc`.

## Observed

Windows ARM job [110244105805](https://github.com/metacraft-labs/runquota/actions/runs/36823482913/job/110244105805)
passes compilation, the complete monitored graph and all 100 conventional test
programs. Its final static-helper gate refuses `build/static-helper-gate`
because the DACL grants `S-1-5-11` (Authenticated Users) access. The expected
account is `S-1-5-21-2615846702-2260884330-149277722-500`.
The log does not retain the offending ACE's inheritance flag.

The shell script recreates the directory, disables inheritance with
`icacls /inheritance:r`, and grants the current account full control with
`/grant:r`. Neither command removes grants explicitly held by other accounts.
Microsoft's [icacls contract](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/icacls)
says `/inheritance:r` removes inherited ACEs, while `/reset` first replaces the
DACL with its default inherited entries. A surviving explicit grant is the
source-level explanation to test; its origin in this failed run is not measured.

## Expected and repair

[Repository requirements](../docs/repository-requirements.md) requires the full
static-helper gate under both authorities. Its Windows authority uses owner-only
DACLs as the equivalent of POSIX mode 0700. The existing `requirePrivate` guard
must keep rejecting any grant outside the account, SYSTEM and Administrators.

Reset the newly recreated, empty scratch root's ACL before disabling inheritance
and granting the owner access. Do this before extracting or compiling anything.
Preserve every authority, compiler identity, snapshot, scanner and static-library
check. The daemon's existing provisioning command already uses this sequence.

Validate on both Windows hosts using real directories with an explicit foreign
grant: the original sequence must retain it and the repaired sequence must
remove it. Record DACL entries and inheritance flags independently. Run the full
unchanged static-helper gate on each host, and retain a negative control that
puts a real foreign grant back before the existing privacy check.

## Evidence and scope

Downloaded log: `/tmp/runquota-d6-arm-repro.log`. The monitored graph checks
203 actions, executes 101 and reuses 102; its observed concurrency peak is two.
The conventional suite reports `all 100 test(s) passed` before the separate
privacy refusal. This does not turn the failed workflow into a passing one.

Refreshed `dev@2c50aaf` and searched open and archived issues for this SID,
static-helper ACLs and the gate-work-root refusal. No existing issue covers it.
