# Daemon-start fixture creates an endpoint directory with mode 0755

Status: open. Observed at `c21dc75` in native macOS job `109259095146`
and Linux ARM64 job `109259094889`, and ARM64 Reprobuild job `109259094336`.

The new `t_daemon_start_detaches_streams.nim` fixture uses `createTempDir`
without setting permissions. Under the CI umask it creates mode 0755, so the
real daemon refuses the endpoint before the stream-detachment assertions run.
The log explicitly says `refusing mode 0755, required 0700`.

The [endpoint contract](../docs/book-isonim/content/usage_guide/daemon.md)
and existing `tests/support/daemon_endpoint.nim` require private endpoint
storage. Set the fixture's directory permissions explicitly, retaining the
real daemon, EOF deadline, process identity and log assertions. Do not relax
the production mode check.

Refreshed dev `e9f9011`, merged it into the candidate, and searched current
and deleted issues for daemon-start and endpoint mode failures before filing.
