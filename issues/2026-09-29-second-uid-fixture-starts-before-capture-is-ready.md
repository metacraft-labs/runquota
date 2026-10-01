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

## Final application qualification (2026-10-01)

The Linux x64 log confirms all three cases actually run and pass: distinct uid 30001 versus runner uid 1001, member admission, and non-member kernel refusal. Evidence: /tmp/runquota-d6-linux-x64-repro.log.

These results are measured at `d6ee4588f71604376a4cc41ef281d6c479395efc`
in [run 36823482913](https://github.com/metacraft-labs/runquota/actions/runs/36823482913).
All application test programs pass on the five development hosts. The ARM
workflow still fails its subsequent, separate static-helper ACL gate; that
issue remains open and is not attributed to this repaired defect.
Ordinary [CI at `2d07c5d`](https://github.com/metacraft-labs/runquota/actions/runs/36846644651)
passes all ten jobs with unchanged application sources and fixtures.
