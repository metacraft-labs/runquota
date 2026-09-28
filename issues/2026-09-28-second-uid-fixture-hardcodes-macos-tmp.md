# Second-uid test uses a macOS-only temporary directory on Linux

| | |
|---|---|
| Status | open |
| Recorded | 2026-09-28 |
| Observed in | runquota @ `906800c` |
| Area | `tests/integration/t_shared_endpoint_second_uid.nim` |

## Observed

The preflight assigns `toolDir = "/private/tmp" / ...` on all POSIX hosts. On Linux it fails with `Read-only file system`, `Additional info: /private/`. The later cross-user checks cannot run because the probe was never built.

## Expected

[RunQuota Observation Store, scope boundaries](https://github.com/metacraft-labs/reprobuild-specs/blob/latest/RunQuota-Observation-Store.md) requires a real kernel-enforced group boundary. The fixture must use a host-appropriate directory that a second uid can traverse, then execute both permitted and refused cases. Preserve the permission checks and assertions.

## Evidence

[Linux test job at 906800c](https://github.com/metacraft-labs/runquota/actions/runs/36377535682/job/108786338190).
The suite ran 93 tests: 87 passed, six failed, no skips or timeouts.
These are normal-suite findings; the release payload checks passed separately.

Refreshed `origin/dev` (`f4f0f93`) and `origin/agents` (`906800c`). Searched
open issues, issue history and RunQuota milestone records before recording.

## Linux follow-up at 28d1fbb

The hosted Linux diagnostic reaches the Nix build user, but that build cannot
open the fixture script under host `/tmp`: Linux sandboxing supplies a private
temporary directory. These fixtures must share a filesystem and Unix socket
while retaining distinct credentials. Pass `--option sandbox false` only to
their Nix invocations; this does not change global Nix settings, build users,
group membership, the positive client control or kernel refusal assertions.
The native Linux rerun remains required.

## Linux primary-group follow-up at 1cc64a3

[The native diagnostic](https://github.com/metacraft-labs/runquota/actions/runs/36430831818/job/108956273767)
now reaches a distinct build uid. Its supplementary group list is empty;
Linux does not include the effective primary group in `getgroups()`. The
fixture must include `getegid()` in both sides' credential sets and require
a nonempty group list before indexing. The member connection and the
nonmember's raw kernel `EACCES` remain the assertions.

## Owner-side audit follow-up at d3b2a54

[The next Linux run](https://github.com/metacraft-labs/runquota/actions/runs/36433103226/job/108964048627)
passes the distinct-UID preflight, permitted client, spoof refusal and raw
kernel denial. Its remaining failures are fixture observations: the socket
audit uses BSD `stat -f`, and opening the store from the outsider account
disables that reader's capture. Use `lstat` in the existing owner-side probe
and execute a read-only SQLite attribution audit as the daemon's owner. Put
the selected SQLite executable on that builder's PATH; do not depend on a
host `/usr/bin/sqlite3`. Keep all mode, owner and group assertions, require
persisted rows, and compare their owners with all three real credentials.
