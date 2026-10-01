# Daemon-start fixture creates an endpoint directory with mode 0755

Status: open. Observed at `c21dc75` in native macOS job `109259095146`
and Linux ARM64 job `109259094889`, and ARM64 Reprobuild job `109259094336`.

The new `t_daemon_start_detaches_streams.nim` fixture uses `createTempDir`
without setting permissions. Under the CI umask it creates mode 0755, so the
real daemon refuses the endpoint before the stream-detachment assertions run.
The log explicitly says `refusing mode 0755, required 0700`.

The [endpoint contract](../docs/database.md)
and `runquota_ipc.ensureEndpointDirectory` require private endpoint
storage. Set the fixture's directory permissions explicitly, retaining the
real daemon, EOF deadline, process identity and log assertions. Do not relax
the production mode check.

Refreshed dev `e9f9011`, merged it into the candidate, and searched current
and deleted issues for daemon-start and endpoint mode failures before filing.

## Final application qualification (2026-10-01)

The real daemon-start fixture passes on Linux and macOS with its private endpoint and unchanged production permission check.

These results are measured at `d6ee4588f71604376a4cc41ef281d6c479395efc`
in [run 36823482913](https://github.com/metacraft-labs/runquota/actions/runs/36823482913).
All application test programs pass on the five development hosts. The ARM
workflow still fails its subsequent, separate static-helper ACL gate; that
issue remains open and is not attributed to this repaired defect.
Ordinary [CI at `2d07c5d`](https://github.com/metacraft-labs/runquota/actions/runs/36846644651)
passes all ten jobs with unchanged application sources and fixtures.
