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

## Verified repair (2026-10-01)

Candidate `2d07c5de63a24c4869ceddda78c14bbf38b76271` passes all four
expected outcomes on Windows x64 and the ARM host in
[run 36852276089](https://github.com/metacraft-labs/metacraft-github-actions/actions/runs/36852276089),
using diagnostic tooling `61f68e8ce2a8adef8ba9053d33346343edd78b8f`.
Independent .NET ACL reads show the explicit Authenticated Users grant remains
under the original sequence and disappears under the repair; the resulting
protected DACL grants only the owning account access. Adding that real grant
back makes the unchanged gate refuse it with the original privacy diagnostic.
The complete repaired gate then passes all 86 scanner regressions and builds
all 12 manifest-listed libraries with ARC and no refs in their closures.
No control times out. The full gates take 81.73 seconds on x64 and 166.50
seconds on ARM; these are individual runs, not a performance comparison.

Downloaded evidence is `/tmp/runquota-acl-61f-x64` and
`/tmp/runquota-acl-61f-arm`. Independent verification compares the actual source,
guard and patch bytes with Git, checks every pinned dependency, reads each
DACL and checks the negative-refusal and complete-gate logs. Results SHA256:

- x64: `1b19bbcafe692c47e129fc8956980fcc1aab22589ce76ca044d3f31a3d2a971d`
- ARM: `5dd8970be405a1c9d59eab7a30dc399fd24ec8e2b6f36e6b3ffea1fefb365cec`

Earlier tooling `3a9f164` fails on both hosts while loading `Get-Acl`;
`cb7a2f6` fixes the reader and confirms the original grant survives on both,
then hits a CRLF-sensitive fragment extraction assertion. `61f68e8` preserves
committed line endings during checkout and verifies their exact hashes.
These are diagnostic corrections; the product remains at `2d07c5d`.
Ordinary CI `36846644651` passes all ten jobs. Application sources and fixtures
are identical to qualified `d6ee458`; that earlier overall workflow remains
failed at its separate ACL gate and is not relabelled as successful.
