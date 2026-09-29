# Windows ARM-host tests cannot launch their real system-tool fixtures

Status: open. Observed at RunQuota `8add804` in the x64-emulation lane.

## Observed

[Windows ARM-host job 109446771063](https://github.com/metacraft-labs/runquota/actions/runs/36580081181/job/109446771063)
finishes 198 actions with 179 successes, 15 failures and four blocked actions.
The ACL fixture fails at `currentUserSid`: `whoami /user failed:` with no
output. All fourteen directory ACL cases then fail before their intended
assertions. Owner identity also fails its independent system-tool comparison.
Other failures include child lease lifecycle, retention, read-only mapping,
and test process timeouts. Their shared cause is not established.

This job uses an x64 Reprobuild/monitor/compiler on Windows ARM64. io-mon
`af1af0f` has a separate real control showing that x64 injection fixtures fail
when they launch the ARM64 System32 shell and pass with an x64 child. This
suggests a cross-architecture monitoring limitation here, but does not yet
attribute RunQuota's failures or prove its native ARM64 behavior.

## Expected and investigation

[Release validation](../../metacraft-specs/infrastructure/gosti-io-mon-runquota-releases.md)
requires real native payload checks on every shipped target. Windows ARM64
RunQuota remains in scope; io-mon's native Windows ARM64 backend is explicitly
deferred. Keep the ACL fixtures independent of RunQuota: compare the same
real system tools and test binaries with and without the enclosing monitor.
Retain their exit codes, output, architecture and exact source identities.
Do not replace the independent owner check with the implementation it tests,
or reinterpret a failed monitored run as success.

Fetched dev `e9f9011` before filing. Searched current and deleted issue history
for `whoami /user failed` and `emulation`; no existing record covers this
ARM-host failure. The downloaded failure report is retained under
`/tmp/runquota-8add-windows-arm-repro-artifacts/`.
