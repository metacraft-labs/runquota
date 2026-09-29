# Second-UID fixture starts before observation capture is ready

- Status: in progress; release validation
- Observed in: RunQuota `94e349f`, Linux x64 job `109427678702`
- Test: `tests/integration/t_shared_endpoint_second_uid.nim`

The native suite passes 97 of 98 test programs. The second-UID fixture passes
its kernel permission, member admission and spoofed-owner checks, then finds
no persisted `executions.owner_uid` after 100 read-only SQLite polls. Its
startup wait tests only socket existence. The daemon log shows capture enabled
later; the successful client can register during store verification.

## Expected

[Database documentation, When the endpoint appears](../docs/database.md#when-the-endpoint-appears)
explicitly separates endpoint readiness from capture readiness. Sessions
registered while the store is `verifying` are served and not recorded. A test
that needs persistence must consume the capture-enabled startup signal or
inspect observation status before opening its measured session.
[Observation Store, owner_uid](../../reprobuild-specs/RunQuota-Observation-Store.md)
requires attribution from real peer credentials. Preserve all three real UIDs,
the kernel EACCES boundary, the spoof refusal and the persisted owner assertions.
Wait for capture readiness within the existing bounded startup wait; retain
the existing persistence polling limit. Validate against deliberately delayed
real SQLite startup and retain a negative control with the old socket-only wait.

Refreshed `origin/dev` at `e9f9011` and searched current and deleted issues for
second-UID, capture-ready and socket-readiness records. The original endpoint
startup issue is resolved by `f4f0f93`; this is a fixture that still assumes the
previous startup ordering. The separate learned-estimate timeout remains
unattributed and is not closed by this finding.

## Regression control

At `2d8a790` plus the repair, a wrapper delays the first real SQLite
invocation for this fixture by three seconds, then passes its arguments and
streams unchanged to the pinned SQLite executable. No query result or UID is
simulated. The original socket-only wait reproduces the CI failure:
`owners.len was 0`. The repaired fixture passes all three cases under the
same delay, including kernel refusal, spoof refusal and persisted attribution.
The existing 60-second startup bound and 100 persistence polls are unchanged.
Native Linux validation and the complete ordinary suite remain required.
